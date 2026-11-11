import json
import re
import sqlite3
import threading
from contextlib import contextmanager
from copy import deepcopy
from datetime import timedelta
from .common import CONFIG, ROOT, digest, dt, now
from .extract import extract_event_traffic, extract_strike_records, prepare
from .evaluate import evaluate
from .schemas import validate_schedule
from .ports import InAppChannel


def dump(x):
    return json.dumps(x, ensure_ascii=False, sort_keys=True)


class Store:
    def __init__(self, path=':memory:', notification_channel=None):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript((ROOT / 'migrations/001.sql').read_text(encoding='utf-8'))
        self.db.executescript((ROOT / 'migrations/002.sql').read_text(encoding='utf-8'))
        self.channel = notification_channel or InAppChannel()
        self.lock = threading.RLock()

    @contextmanager
    def transaction(self):
        with self.lock, self.db:
            yield self.db

    def attempt(self, a, stage, status, payload):
        self.db.execute('INSERT INTO attempts(article_id,revision,stage,status,payload,created_at) VALUES(?,?,?,?,?,?)',
                        (a.get('source_id'), a.get('source_revision'), stage, status, dump(payload), now()))

    def restore_public_feed(self, feed):
        """Recover monotonic versions when the Actions DB cache was evicted.

        Input is the previous feed from this repository's data branch, never an
        extraction candidate supplied by a model or a public article body.
        """
        if feed.get('newsTrafficSchemaVersion') != '1.0':
            return
        with self.transaction():
            for row in feed.get('trafficImpacts', []):
                if row.get('body_verified') is not True or not isinstance(row.get('version'), int):
                    continue
                impact = {k: v for k, v in row.items() if k not in ('body_verified', 'verified_point', 'point_reference_source')}
                semantic = {k: v for k, v in impact.items() if k not in ('version', 'checked_at', 'source_url', 'published_at', 'updated_at', 'evidence')}
                self.db.execute('INSERT OR IGNORE INTO impacts VALUES(?,?,?,?,?,?)',
                                (impact['id'], impact['event_id'], impact['version'], digest(semantic), dump(impact), impact.get('updated_at') or impact.get('published_at')))
                self.db.execute('INSERT OR IGNORE INTO impact_history VALUES(?,?,?)', (impact['id'], impact['version'], dump(impact)))

    def ingest(self, article, refs=()):
        a = prepare(article)
        with self.transaction():
            raw = deepcopy(a)
            if not CONFIG['store_raw_body']:
                raw['body'] = None
            self.db.execute('INSERT OR IGNORE INTO articles VALUES(?,?,?,?)', (a['source_id'], a['source_revision'], dump(raw), a['collected_at']))
        try:
            strikes = extract_strike_records(a, refs)
            events = extract_event_traffic(a, refs)
        except Exception as exc:
            with self.transaction():
                self.attempt(a, 'validation', getattr(exc, 'code', 'extraction_failed'), {'detail': str(exc)})
            raise
        with self.transaction():
            self.attempt(a, 'extraction', 'success', {'strikes': strikes, 'events': events})
            for r in strikes:
                if r['article_relevance'] != 'related' or r['strike_status']['value'] in ('historical', 'preparing'):
                    continue
                scope = r['affected_routes'] or r['affected_regions']
                subject = re.search(r'[가-힣A-Za-z]+(?:노조|공사|운수)', r['strike_status']['scope_raw'] or '')
                # Missing subject/date never merges unrelated sources: retain as review candidates.
                identity = [subject[0] if subject else a['source_id'], [x['region'] for x in r['affected_regions']], r['transport_mode'],
                            [x['raw'] for x in r['affected_routes']], r['start']['date'], a.get('demo', False)]
                eid = digest(['strike', identity])
                state = r['strike_status']['value']
                service_disrupted = any(x['value'] in ('recovering', 'suspended', 'reduced') for x in r['service_status'])
                status = 'WITHDRAWN' if state in ('withdrawn', 'deferred') and not service_disrupted else 'ANNOUNCED' if state in ('scheduled', 'ongoing', 'ended', 'withdrawn', 'deferred') else 'CONDITIONAL' if state == 'conditional' else 'UNKNOWN'
                # Ended is not restored. Future normal service is only considered in its own time window.
                self._merge(a, dict(id=digest([eid, 'strike']), event_id=eid, type='STRIKE', status=status,
                                   assertion='actual' if state in ('ongoing', 'ended') else 'planned',
                                   period=dict(start=r['start'], end=r['end'], precision='PARTIAL', condition=None),
                                   scope=scope, modes=[r['transport_mode']] if r['transport_mode'] != 'unknown' else [],
                                   exceptions=r['normal_service_exceptions'] + [x for x in r['service_status'] if x['value'] == 'normal'],
                                   service_status=r['service_status'], disruption_confirmed=any(x['value'] in ('recovering', 'suspended', 'reduced') and x['assertion'] == 'actual' for x in r['service_status']),
                                   evidence=r['evidence_and_timestamps']['field_evidence'],
                                   status_effective_at=r['strike_status']['effective_at'],
                                   review_reasons=r['evidence_and_timestamps']['review_reasons'], strike_status=state, event_name=subject[0] if subject else '파업 사건'))
            for e in events['events']:
                regions = sorted(set(x.get('region') for x in e['event_locations'] if x.get('region')))
                identity_scope = sorted(x['raw'] for x in e['event_locations'] if x['raw'] not in CONFIG['regions'])
                if not identity_scope:
                    # Without a venue, cross-source identity is unconfirmed. Only
                    # revisions of this exact source can update one another.
                    identity_scope = ['source:' + a['source_id']]
                eid = digest(['event', e['event_name'], regions, identity_scope, e['event_period']['start']['date'], a.get('demo', False)])
                if e['event_name'] in ('축제', '마라톤', '집회'):
                    eid = digest([eid, a['source_id']])
                event_record = {k: v for k, v in e.items() if k != 'impacts'}
                self.db.execute('INSERT OR REPLACE INTO event_records VALUES(?,?,?,?)', (eid, a['source_id'], a['source_revision'], dump(event_record)))
                # Cancellation / explicit old->new date changes are scoped to the same
                # named event, region set, and date. Ambiguous identity never auto-releases.
                explicit_dates = re.findall(r'20\d{2}-\d{2}-\d{2}', ' '.join(ev['quote'] for ev in e['evidence']))
                retained = {digest([eid, i['impact_ref']]) for i in e['impacts']}
                if e['event_status'] in ('CANCELLED', 'CHANGED') and e['event_name'] not in ('축제', '마라톤', '집회'):
                    for existing in self.db.execute('SELECT payload FROM impacts').fetchall():
                        old = json.loads(existing[0])
                        oldregions = sorted(set(x.get('region') for x in old['scope'] if x.get('region')))
                        olddate = old['period']['start']['date']
                        same = old.get('event_name') == e['event_name'] and oldregions == regions and old['demo'] == a.get('demo', False) and (old.get('event_identity_scope') == identity_scope or old.get('source_url') == a['source_url'])
                        cancels = e['event_status'] == 'CANCELLED' and old['event_id'] == eid and old['id'] not in retained and not old.get('residual_control')
                        moves = e['event_status'] == 'CHANGED' and len(explicit_dates) == 2 and olddate == explicit_dates[0] and explicit_dates[0] != explicit_dates[1]
                        if same and (cancels or moves):
                            closed = {k: v for k, v in old.items() if k not in ('version', 'pending_change')}
                            closed.update(status='WITHDRAWN', evidence=e['evidence'], event_status=e['event_status'])
                            self._merge(a, closed)
                for i in e['impacts']:
                    self._merge(a, dict(id=digest([eid, i['impact_ref']]), event_id=eid, event_name=e['event_name'],
                                       event_identity_scope=identity_scope,
                                       event_status=e['event_status'], type=i['impact_type'], status=i['impact_status'], assertion=i['assertion'],
                                       residual_control=e['event_status'] == 'CANCELLED' and i['impact_status'] not in ('WITHDRAWN', 'ENDED'),
                                       period=i['period'], scope=i['affected_scope'], modes=i['affected_modes'], exceptions=[],
                                       evidence=i['evidence'], review_reasons=e['review_reasons'] + i['review_reasons']))
            self.attempt(a, 'validation', 'success', {'validated': True})
        return {'strikes': strikes, 'events': events}

    def _merge(self, a, impact):
        impact.update(demo=a.get('demo', False), checked_at=a['collected_at'], source_url=a['source_url'],
                      published_at=a['published_at'], updated_at=a['updated_at'], conflict=False)
        stamp = impact.get('status_effective_at') or a['updated_at'] or a['published_at']
        row = self.db.execute('SELECT * FROM impacts WHERE id=?', (impact['id'],)).fetchone()
        old = json.loads(row['payload']) if row else None
        if old and impact['type'] == 'STRIKE' and impact['status'] == 'WITHDRAWN' and old.get('disruption_confirmed'):
            # A plan withdrawal cannot erase independently evidenced service disruption.
            impact.update(status='ANNOUNCED', disruption_confirmed=True,
                          service_status=old.get('service_status', []) + impact.get('service_status', []),
                          evidence=old['evidence'] + impact['evidence'])
        semantic = {k: v for k, v in impact.items() if k not in ('checked_at', 'source_url', 'published_at', 'updated_at', 'evidence')}
        h = digest(semantic)
        if old and old.get('conflict') and old.get('pending_change'):
            pending = {k: v for k, v in old['pending_change'].items() if k not in ('checked_at', 'source_url', 'published_at', 'updated_at', 'evidence')}
            if digest(pending) == h:
                old['checked_at'] = a['collected_at']
                self.db.execute('UPDATE impacts SET payload=? WHERE id=?', (dump(old), old['id']))
                return
        if old and row['semantic_hash'] != h:
            if stamp and row['assertion_at'] and dt(stamp) < dt(row['assertion_at']):
                self.attempt(a, 'reconciliation', 'older_assertion_preserved', impact)
                return
            if not stamp or not row['assertion_at'] or dt(stamp) == dt(row['assertion_at']) or impact['status'] == 'UNKNOWN':
                # Preserve last verified payload with the unconfirmed change alongside it.
                candidate = deepcopy(impact)
                impact = {**old, 'conflict': True, 'pending_change': candidate, 'checked_at': a['collected_at']}
                h = digest([row['semantic_hash'], 'conflict', {k: v for k, v in semantic.items() if k != 'conflict'}])
        if old and row['semantic_hash'] == h:
            # Check time and provenance may change without a semantic version bump.
            impact = {**old, 'checked_at': a['collected_at'], 'evidence': impact['evidence']}
            version = row['version']
        else:
            version = row['version'] + 1 if row else 1
        impact['version'] = version
        self.db.execute('INSERT OR REPLACE INTO impacts VALUES(?,?,?,?,?,?)', (impact['id'], impact['event_id'], version, h, dump(impact), stamp))
        self.db.execute('INSERT OR IGNORE INTO impact_history VALUES(?,?,?)', (impact['id'], version, dump(impact)))

    def save_schedule(self, user, schedule):
        s = deepcopy(validate_schedule(schedule))
        with self.transaction():
            row = self.db.execute('SELECT payload FROM schedules WHERE user_id=? AND id=?', (user, s['id'])).fetchone()
            old = json.loads(row[0]) if row else None
            s.pop('version', None)
            s['trip'].pop('version', None)
            oldtrip = {k: v for k, v in old['trip'].items() if k != 'version'} if old else None
            tripversion = old['trip']['version'] + (oldtrip != s['trip']) if old else 1
            prior = {k: v for k, v in old.items() if k != 'version'} if old else None
            if prior:
                prior['trip'] = oldtrip
            version = old['version'] + (prior != s) if old else 1
            s['version'], s['trip']['version'] = int(version), int(tripversion)
            self.db.execute('INSERT OR REPLACE INTO schedules VALUES(?,?,?)', (user, s['id'], dump(s)))
        return s

    def reevaluate(self, user, at=None, demo_only=None):
        at = at or now()
        with self.transaction():
            for row in self.db.execute('SELECT payload FROM schedules WHERE user_id=?', (user,)).fetchall():
                s = json.loads(row[0])
                if demo_only is not None and bool(s.get('demo')) != demo_only:
                    continue
                for irow in self.db.execute('SELECT payload FROM impacts').fetchall():
                    i = json.loads(irow[0])
                    # Strict demo/live separation: a schedule opts into demo data explicitly.
                    if bool(s.get('demo')) != bool(i['demo']):
                        continue
                    prevrow = self.db.execute('SELECT payload FROM decisions WHERE user_id=? AND schedule_id=? AND impact_id=?', (user, s['id'], i['id'])).fetchone()
                    prev = json.loads(prevrow[0]) if prevrow else None
                    result = evaluate(s, i, at, prev)
                    if prev and prev['decision'] == 'RESOLVED' and result['decision'] == 'IGNORE' and prev['impact_version'] == result['impact_version']:
                        result['decision'], result['message'] = 'RESOLVED', prev['message']
                        result['notification_eligible'] = False
                    self.db.execute('INSERT OR REPLACE INTO decisions VALUES(?,?,?,?)', (user, s['id'], i['id'], dump(result)))
                    if not prev or any(result[k] != prev.get(k) for k in ('schedule_revision', 'impact_version', 'decision')):
                        self.db.execute('INSERT INTO decision_history(user_id,schedule_id,impact_id,payload) VALUES(?,?,?,?)', (user, s['id'], i['id'], dump(result)))
                    if result['notification_eligible']:
                        # Changes due to schedule/trip edits use a distinct kind; edits with identical output do not notify.
                        kind = 'resolved' if result['decision'] == 'RESOLVED' else 'initial' if not prev else 'change' if result['decision'] != prev['decision'] or result['impact_version'] != prev['impact_version'] else None
                        if kind:
                            self.channel.enqueue(self.db, user, result, kind)

    def snapshot(self, user):
        with self.lock:
            def rows(table, where='', args=()):
                return [json.loads(r[0]) for r in self.db.execute(f'SELECT payload FROM {table} {where}', args)]
            notifications = [{**json.loads(r['payload']), 'displayed_at': r['displayed_at']} for r in self.db.execute('SELECT payload,displayed_at FROM notifications WHERE user_id=?', (user,))]
            stages = [{'stage': r['stage'], 'status': r['status'], 'created_at': r['created_at'], 'result': json.loads(r['payload'])}
                      for r in self.db.execute('SELECT stage,status,created_at,payload FROM attempts ORDER BY id DESC LIMIT 20')]
            return dict(schedules=rows('schedules', 'WHERE user_id=?', (user,)), impacts=rows('impacts'),
                        decisions=rows('decisions', 'WHERE user_id=?', (user,)),
                        notifications=notifications,
                        source_runs=rows('source_runs', 'ORDER BY id DESC LIMIT 20'),
                        history=rows('impact_history'), stages=stages)

    def mark_displayed(self, user, schedule_id=None):
        with self.transaction():
            if schedule_id:
                self.db.execute('UPDATE notifications SET displayed_at=? WHERE user_id=? AND schedule_id=? AND displayed_at IS NULL', (now(), user, schedule_id))
            else:
                self.db.execute('UPDATE notifications SET displayed_at=? WHERE user_id=? AND displayed_at IS NULL', (now(), user))

    def purge(self, at=None):
        threshold = (dt(at or now()) - timedelta(days=CONFIG['raw_retention_days'])).isoformat()
        with self.transaction():
            for r in self.db.execute('SELECT * FROM articles WHERE collected_at < ?', (threshold,)).fetchall():
                a = json.loads(r['payload'])
                a['body'] = None
                self.db.execute('UPDATE articles SET payload=? WHERE id=? AND revision=?', (dump(a), r['id'], r['revision']))
