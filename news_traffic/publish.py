"""Publish validated public-news impacts into the existing static news.json.

No server or user schedule is involved. Search snippets are discovery hints only.
"""
import argparse
import json
from collections import defaultdict
from urllib.parse import urlsplit
from pathlib import Path
from .collect import Fetcher
from .common import CONFIG, now
from .store import Store


def select_results(results, limit):
    """Round-robin search categories; strikes must not starve event coverage."""
    groups = defaultdict(list)
    allowed = {host for hosts in CONFIG['hosts'].values() for host in hosts}
    for row in results:
        if urlsplit(row['url']).hostname in allowed:
            groups[row.get('query') or 'legacy'].append(row)
    selected, seen = [], set()
    while any(groups.values()) and len(selected) < limit:
        for group in groups.values():
            if group and len(selected) < limit:
                row = group.pop(0)
                if row['url'] not in seen:
                    seen.add(row['url'])
                    selected.append(row)
    return selected


def publish(feed, store, articles, refs=()):
    failures, extractions = [], []
    for article in articles:
        try:
            extractions.append(store.ingest(article, refs))
        except Exception as exc:
            failures.append({'source_url': article.get('source_url'),
                             'status': getattr(exc, 'code', 'extraction_failed')})
    # Do not delete existing verified impacts on failed collection/extraction.
    snapshot = store.snapshot('public-feed-only')
    impacts = []
    for impact in snapshot['impacts']:
        item = {**impact, 'body_verified': True}
        # Coordinates may ONLY enter through a separately supplied trusted reference.
        for scope in item['scope']:
            ref = next((r for r in refs if r['id'] == scope.get('reference_id')
                        and r['source'] == scope.get('reference_source')), None)
            if ref and ref.get('point'):
                item['verified_point'] = ref['point']
                item['point_reference_source'] = ref['source']
                break
        impacts.append(item)
    return {**feed, 'generatedAt': now(), 'newsTrafficSchemaVersion': '1.0',
            'trafficImpacts': impacts, 'extractions': extractions,
            'transportReferences': [r for r in refs if all(r.get(k) for k in ('id', 'raw', 'region', 'mode', 'source', 'as_of'))],
            'extractionFailures': failures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--feed', default='out/news.json')
    parser.add_argument('--articles', help='JSON list of full articles; offline/no keys')
    parser.add_argument('--references', help='server-verified reference JSON list')
    parser.add_argument('--db', default='cache/news-traffic.sqlite3')
    parser.add_argument('--out')
    parser.add_argument('--previous', help='previous published feed from the trusted data branch')
    args = parser.parse_args()
    feed_path = Path(args.feed)
    feed = json.loads(feed_path.read_text(encoding='utf-8')) if feed_path.exists() else {'strikes': []}
    refs = json.loads(Path(args.references).read_text(encoding='utf-8')) if args.references else []
    failures = []
    if args.articles:
        articles = json.loads(Path(args.articles).read_text(encoding='utf-8'))
    else:
        articles, fetcher = [], Fetcher()
        seen = set()
        for result in select_results(feed.get('searchResults', []), CONFIG['max_articles_per_run']):
            url = result['url']
            if url in seen:
                continue
            seen.add(url)
            try:
                articles.append(fetcher.article(url))
            except Exception as exc:
                failures.append({'source_url': url, 'status': getattr(exc, 'code', 'collection_failed')})
    Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    store = Store(args.db)
    try:
        if args.previous and Path(args.previous).exists() and Path(args.previous).stat().st_size:
            store.restore_public_feed(json.loads(Path(args.previous).read_text(encoding='utf-8')))
        output = publish(feed, store, articles, refs)
        output['extractionFailures'] += failures
        store.purge()
        store.db.commit()
        # All state must be in the cached DB before the workflow saves it.
        store.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    finally:
        store.db.close()
    target = Path(args.out or args.feed)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps(output, ensure_ascii=False, indent=1), encoding='utf-8')
    temporary.replace(target)
    print(f'validated impacts: {len(output["trafficImpacts"])}; failures: {len(output["extractionFailures"])}')


if __name__ == '__main__':
    main()
