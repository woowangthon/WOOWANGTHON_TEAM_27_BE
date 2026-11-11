"""HTTPS-only, DNS-pinned fetcher. No proxies, cookies, scripts, or access bypass."""
import http.client
import ipaddress
import socket
import ssl
import time
import urllib.parse
import urllib.robotparser
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from datetime import timedelta
from bs4 import BeautifulSoup
from .common import CONFIG, DomainError, digest, dt, now

AGENT = 'LifeRadarTraffic/0.1'
SELECTORS = {
    'fnnews.com': '#article_content', 'yna.co.kr': '.story-news.article',
    'newsis.com': '#textBody', 'tdaily.co.kr': '#articleBody',
    'newshim.kr': '#article-view-content-div', 'seoul.co.kr': '#atic_txt1',
    'newspim.com': '#news-contents', 'metroseoul.co.kr': '#articleBody',
    'imaeil.com': '#articlebody', 'joongdo.co.kr': '#articleBody',
    'nocutnews.co.kr': '#pnlContent', 'khan.co.kr': '#articleBody',
    'hankyung.com': '#articletxt'
}


def check_url(url, resolver=socket.getaddrinfo):
    p = urllib.parse.urlsplit(url)
    if p.scheme != 'https' or p.username or p.password or p.port not in (None, 443) or not p.hostname or '\\' in url:
        raise DomainError('url_blocked', 'HTTPS public news URL required')
    host = p.hostname.lower()
    domain = next((d for d, hosts in CONFIG['hosts'].items() if host in hosts), None)
    if not domain:
        raise DomainError('domain_blocked', host)
    try:
        ips = list(dict.fromkeys(item[4][0] for item in resolver(host, 443, type=socket.SOCK_STREAM)))
    except OSError as exc:
        raise DomainError('dns_failed', host) from exc
    if not ips or any(not ipaddress.ip_address(ip).is_global for ip in ips):
        raise DomainError('address_blocked', 'non-public DNS address')
    return p, domain, ips


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, ip, timeout):
        super().__init__(host, timeout=timeout, context=ssl.create_default_context())
        self.ip = ip

    def connect(self):
        sock = socket.create_connection((self.ip, 443), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class Fetcher:
    def __init__(self):
        self.cache, self.robots, self.last = {}, {}, {}

    def raw(self, url, redirects=0, policy_request=False):
        if redirects > 4:
            raise DomainError('redirect_limit')
        p, _, ips = check_url(url)
        delay = CONFIG['request_interval_seconds'] - (time.monotonic() - self.last.get(p.hostname, 0))
        if delay > 0:
            time.sleep(delay)
        self.last[p.hostname] = time.monotonic()
        conn = PinnedHTTPS(p.hostname, ips[0], CONFIG['timeout_seconds'])
        try:
            conn.request('GET', urllib.parse.urlunsplit(('', '', p.path or '/', p.query, '')), headers={'User-Agent': AGENT, 'Accept': 'text/html,application/rss+xml,application/xml,text/plain'})
            r = conn.getresponse()
            if r.status in (301, 302, 303, 307, 308):
                target = urllib.parse.urljoin(url, r.getheader('Location') or '')
                check_url(target)
                # The target's robots policy must also permit access.
                if not policy_request:
                    self.policy(target)
                return self.raw(target, redirects + 1, policy_request)
            if r.status != 200:
                raise DomainError('http_failed', f'HTTP {r.status}')
            data = r.read(2_000_001)
            if len(data) > 2_000_000:
                raise DomainError('body_too_large')
            charset = r.headers.get_content_charset() or 'utf-8'
            return data.decode(charset, errors='replace'), r.getheader('Content-Type', ''), url
        finally:
            conn.close()

    def policy(self, url):
        p, _, _ = check_url(url)
        origin = f'https://{p.hostname}'
        cached = self.robots.get(origin)
        if not cached or time.monotonic() - cached[0] > CONFIG['cache_seconds']:
            try:
                text, ctype, _ = self.raw(origin + '/robots.txt', policy_request=True)
                if 'html' in ctype or '<html' in text.lower():
                    raise DomainError('policy_unavailable', 'robots returned HTML instead of a policy')
            except Exception as exc:
                raise DomainError('policy_unavailable', 'robots policy could not be verified: ' + str(exc)[:150]) from exc
            rp = urllib.robotparser.RobotFileParser()
            rp.parse(text.splitlines())
            self.robots[origin] = (time.monotonic(), rp)
        rp = self.robots[origin][1]
        if not rp.can_fetch(AGENT, url):
            raise DomainError('robots_denied')
        # Honor larger advertised crawl delays as well as the configured minimum.
        delay = rp.crawl_delay(AGENT) or rp.crawl_delay('*') or 0
        wait = delay - (time.monotonic() - self.last.get(p.hostname, 0))
        if wait > 0:
            if wait > 30:
                raise DomainError('crawl_delay_deferred', 'publisher asks for >30 second delay')
            time.sleep(wait)

    def get(self, url):
        check_url(url)
        self.policy(url)
        item = self.cache.get(url)
        if item and time.monotonic() - item[0] < CONFIG['cache_seconds']:
            return item[1]
        for attempt in range(CONFIG['retries'] + 1):
            try:
                result = self.raw(url)
                self.cache[url] = (time.monotonic(), result)
                return result
            except (OSError, http.client.HTTPException) as exc:
                if attempt == CONFIG['retries']:
                    raise DomainError('fetch_failed', type(exc).__name__) from exc

    def discover(self, region):
        domains = CONFIG['regions'].get(region, [])
        if not domains:
            return [], [{'region': region, 'status': 'source_unconfigured'}]
        urls, status = [], []
        for domain in domains:
            feeds = CONFIG['feeds'].get(domain, [])
            if not feeds:
                status.append({'domain': domain, 'status': 'discovery_unconfigured', 'detail': 'manual article URL supported; RSS not verified'})
            for feed in feeds:
                try:
                    text, _, _ = self.get(feed)
                    if '<!DOCTYPE' in text.upper() or '<!ENTITY' in text.upper():
                        raise DomainError('unsafe_xml')
                    root = ET.fromstring(text)
                    for item in root.findall('.//item'):
                        published = item.findtext('pubDate')
                        if published:
                            try:
                                if parsedate_to_datetime(published) < dt(now()) - timedelta(days=CONFIG['lookback_days']):
                                    continue
                            except (ValueError, TypeError):
                                pass
                        title = item.findtext('title', '')
                        summary = item.findtext('description', '')
                        if any(k in title + summary for k in CONFIG['keywords']):
                            link = item.findtext('link', '').strip()
                            check_url(link)
                            urls.append(link)
                    status.append({'domain': domain, 'status': 'discovery_success', 'feed': feed})
                except Exception as exc:
                    status.append({'domain': domain, 'status': getattr(exc, 'code', 'feed_failed'), 'detail': str(exc)[:180]})
        # Discovery date limits must never delete active stored impacts.
        return list(dict.fromkeys(urls)), status

    def article(self, url):
        _, domain, _ = check_url(url)
        html, ctype, final_url = self.get(url)
        if 'html' not in ctype:
            raise DomainError('body_fetch_failed', 'article HTML required')
        soup = BeautifulSoup(html, 'html.parser')
        body = soup.select_one(SELECTORS[domain]) or soup.find('article')
        if body is None:
            raise DomainError('body_fetch_failed', 'verified body selector missing; title/summary are insufficient')
        for tag in body.select('script,style,nav,aside,figure,iframe'):
            tag.decompose()
        text = body.get_text(' ', strip=True)
        if len(text) < 80:
            raise DomainError('body_fetch_failed', 'article body too short')
        def meta(*keys):
            for key in keys:
                tag = soup.find('meta', property=key) or soup.find('meta', attrs={'name': key})
                if tag and tag.get('content'):
                    return tag['content']
            return None
        def stamp(value):
            try:
                return dt(value).isoformat() if value else None
            except ValueError:
                return None
        title = meta('og:title') or (soup.title.get_text(strip=True) if soup.title else '제목 미확인')
        return dict(title=title, body=text, source_url=final_url, source_id=digest(final_url), source_revision=digest(text),
                    published_at=stamp(meta('article:published_time', 'datePublished')), updated_at=stamp(meta('article:modified_time', 'dateModified')),
                    collected_at=now(), demo=False)
