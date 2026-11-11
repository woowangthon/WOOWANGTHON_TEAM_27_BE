"""Strict JSON contracts shared by rule candidates and future AI adapters."""
from datetime import date, time, timedelta
import re
from jsonschema import Draft202012Validator, FormatChecker
from .common import DomainError, KST, dt


def obj(**fields):
    return {'type': 'object', 'properties': fields, 'required': list(fields), 'additionalProperties': False}


def enum(*values):
    return {'enum': list(values)}


def arr(item):
    return {'type': 'array', 'items': item}


S = {'type': 'string', 'minLength': 1}
N = {'type': ['string', 'null'], 'minLength': 1}
STAMP = {'type': ['string', 'null'], 'format': 'date-time'}
REQUIRED_STAMP = {'type': 'string', 'format': 'date-time'}
TIME = obj(raw=N, date={'type': ['string', 'null'], 'format': 'date'},
           time={'type': ['string', 'null'], 'pattern': r'^\d{2}:\d{2}(:\d{2})?$'},
           timezone=enum('Asia/Seoul'), basis=enum('explicit', 'relative', 'first_service', 'last_service', 'unknown'),
           assertion=enum('planned', 'actual', 'unknown'), open_ended={'type': ['boolean', 'null']})
EVIDENCE = obj(field_path=S, quote=S, source_part=enum('title', 'body'), effective_at=STAMP,
               derivation=enum('explicit', 'normalized', 'reference_mapping'), source_id=S,
               source_revision=S, reference_source=N)
LOCATION = obj(raw=S, normalized_name=N, region=N, reference_id=N,
               derivation=enum('article_explicit', 'reference_mapping', 'unresolved'), reference_source=N)
LOCATION['properties'].update(section=N, direction=N)
PERIOD = obj(start=TIME, end=TIME, precision=enum('EXACT', 'DATE_ONLY', 'PARTIAL', 'UNKNOWN'), condition=N)
SOURCE = obj(source_id=S, source_url=S, source_revision=S, published_at=STAMP, updated_at=STAMP, collected_at=REQUIRED_STAMP)
SERVICE = obj(value=enum('suspended', 'reduced', 'normal', 'recovering', 'unknown'),
              assertion=enum('planned', 'actual', 'unknown'), raw=S, scope=arr(LOCATION), period=PERIOD,
              metrics=arr(obj(raw=S, value={'type': 'number'}, unit=S)))
STRIKE = obj(article_relevance=enum('related', 'unrelated', 'unknown'), transport_mode=enum('bus', 'subway', 'rail', 'unknown'),
             affected_regions=arr(LOCATION), affected_routes=arr(LOCATION), start=TIME, end=TIME,
             strike_status=obj(value=enum('preparing', 'conditional', 'scheduled', 'ongoing', 'deferred', 'withdrawn', 'ended', 'historical', 'unknown'),
                               conditions=arr(S), scope_raw=N, effective_at=STAMP),
             service_status=arr(SERVICE), normal_service_exceptions=arr(SERVICE),
             alternative_services=arr(obj(raw=S, mode=enum('bus', 'subway', 'rail', 'unknown'), routes=arr(LOCATION), period=PERIOD)),
             evidence_and_timestamps=obj(source_url=S, published_at=STAMP, updated_at=STAMP, collected_at=REQUIRED_STAMP,
                                         field_evidence=arr(EVIDENCE), review_reasons=arr(S)))
IMPACT = obj(impact_ref=S, impact_type=enum('ROAD_CLOSURE', 'BUS_DETOUR', 'STOP_SKIP', 'STATION_RESTRICTION', 'CONGESTION_FORECAST', 'UNKNOWN'),
             impact_status=enum('ANNOUNCED', 'CONDITIONAL', 'WITHDRAWN', 'ENDED', 'UNKNOWN'),
             assertion=enum('planned', 'forecast', 'actual', 'unknown'), period=PERIOD, affected_scope=arr(LOCATION),
             affected_modes=arr(enum('car', 'taxi', 'bus', 'subway', 'rail', 'walk')),
             exceptions=arr(S), conditions=arr(S), source_recommendations=arr(S), evidence=arr(EVIDENCE), review_reasons=arr(S))
EVENT = obj(event_ref=S, event_name=N, event_type=enum('RALLY', 'MARATHON', 'FESTIVAL', 'UNKNOWN'),
            event_status=enum('PLANNED', 'CONDITIONAL', 'CHANGED', 'CANCELLED', 'ENDED', 'UNKNOWN'),
            event_period=PERIOD, event_locations=arr(LOCATION), impacts=arr(IMPACT), evidence=arr(EVIDENCE), review_reasons=arr(S))
EXTRACTION = obj(schema_version=enum('1.0'), article_relevance=enum('related', 'unrelated', 'unknown'),
                 processing_status=enum('success', 'partial', 'needs_review'), source=SOURCE,
                 events=arr(EVENT), review_reasons=arr(S))


def validate(article, candidate, kind, refs=()):
    schema = STRIKE if kind == 'strike' else EXTRACTION
    errors = sorted(Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(candidate), key=lambda e: str(e.path))
    if errors:
        raise DomainError('validation_failed', '; '.join(f'{list(e.path)}: {e.message}' for e in errors)[:1500])
    metadata = candidate['evidence_and_timestamps'] if kind == 'strike' else candidate['source']
    for field in ('source_url', 'published_at', 'updated_at', 'collected_at'):
        if metadata[field] != article.get(field):
            raise DomainError('validation_failed', 'source metadata changed: ' + field)

    def walk(value):
        if isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, dict):
            if 'quote' in value:
                if value['quote'] not in article.get(value['source_part'], ''):
                    raise DomainError('validation_failed', 'fabricated evidence')
                if value['source_id'] != article['source_id'] or value['source_revision'] != article['source_revision']:
                    raise DomainError('validation_failed', 'wrong evidence revision')
                if value['derivation'] == 'reference_mapping' and not value['reference_source']:
                    raise DomainError('validation_failed', 'missing reference provenance')
            if set(TIME['required']) == set(value):
                if value['date']:
                    extracted_day = date.fromisoformat(value['date'])
                    body = article['body']
                    allowed_dates = set(re.findall(r'20\d{2}-\d{2}-\d{2}', body))
                    for m in re.finditer(r'(20\d{2})[년.]\s*(\d{1,2})[월.]\s*(\d{1,2})일?', body):
                        allowed_dates.add(f'{int(m[1]):04}-{int(m[2]):02}-{int(m[3]):02}')
                    if article.get('published_at') and not article.get('updated_at'):
                        base = dt(article['published_at']).astimezone(KST).date()
                        for token, offset in [('오늘', 0), ('내일', 1), ('모레', 2)]:
                            if token in body:
                                allowed_dates.add((base + timedelta(days=offset)).isoformat())
                    explicit = sorted(allowed_dates)
                    if '익일' in body:
                        allowed_dates.update((date.fromisoformat(d) + timedelta(days=1)).isoformat() for d in explicit)
                    if '매일' in body and len(explicit) == 2 and explicit[0] <= value['date'] <= explicit[1]:
                        allowed_dates.add(value['date'])
                    if value['date'] not in allowed_dates:
                        raise DomainError('validation_failed', 'unsupported normalized date')
                if value['time']:
                    time.fromisoformat(value['time'])
                    hh, mm = map(int, value['time'].split(':')[:2])
                    body = article['body']
                    minute = rf'\s*{mm}분' if mm else r'(?!\s*[1-9]\d?분)'
                    pattern = rf'(?<!\d)0?{hh}:0?{mm}(?!\d)|(?:(?:오전|오후)\s*)?(?:{hh}|{hh-12 if hh>12 else hh})시{minute}'
                    if not re.search(pattern, body):
                        raise DomainError('validation_failed', 'unsupported extracted time')
                if value['raw'] and value['raw'] not in article['body']:
                    # Composite normalized date+time raw must consist of actual source tokens.
                    if not all(token in article['body'] for token in value['raw'].split()):
                        raise DomainError('validation_failed', 'fabricated raw time')
            if set(PERIOD['required']) == set(value):
                a, b = value['start'], value['end']
                if a['date'] and b['date'] and a['date'] > b['date']:
                    raise DomainError('validation_failed', 'reversed date-only period')
                if a['date'] and b['date'] and a['time'] and b['time']:
                    if a['date'] + a['time'] >= b['date'] + b['time']:
                        raise DomainError('validation_failed', 'reversed or empty period')
            if 'reference_id' in value and value['reference_id'] and not value['reference_source']:
                raise DomainError('validation_failed', 'unverified facility ID')
            if 'reference_id' in value:
                if value['raw'] not in article['body']:
                    raise DomainError('validation_failed', 'fabricated scope')
                if value['reference_id']:
                    trusted = list(refs)
                    if article.get('demo'):
                        from .demo import REFERENCES
                        trusted += REFERENCES
                    if not any(r['id'] == value['reference_id'] and r['raw'] == value['raw'] and r['region'] == value['region'] and r['source'] == value['reference_source'] and bool(r.get('demo')) == bool(article.get('demo')) and (r.get('demo') or (r.get('as_of') and date.fromisoformat(r['as_of']))) for r in trusted):
                        raise DomainError('validation_failed', 'untrusted reference mapping')
                for field in ('section', 'direction'):
                    if value.get(field) and value[field] not in article['body']:
                        raise DomainError('validation_failed', 'fabricated route scope')
            for item in value.values():
                walk(item)
    try:
        walk(candidate)
        if kind == 'strike':
            a, b = candidate['start'], candidate['end']
            if a['date'] and b['date'] and (a['date'] > b['date'] or (a['date'] == b['date'] and a['time'] and b['time'] and a['time'] >= b['time'])):
                raise DomainError('validation_failed', 'reversed strike period')
            ev = candidate['evidence_and_timestamps']['field_evidence']
            if candidate['article_relevance'] == 'related' and not ev:
                raise DomainError('validation_failed', 'evidence required')
            for field in ['transport_mode', 'strike_status', 'affected_regions', 'affected_routes', 'service_status', 'normal_service_exceptions', 'alternative_services', 'start', 'end']:
                value = candidate[field]
                meaningful = bool(value) if isinstance(value, list) else value != 'unknown'
                if field == 'strike_status':
                    meaningful = value['value'] != 'unknown'
                if field in ('start', 'end'):
                    meaningful = value['raw'] is not None
                if meaningful and not any(e['field_path'].startswith('/' + field) for e in ev):
                    raise DomainError('validation_failed', f'missing field evidence: {field}')
        else:
            for event in candidate['events']:
                if not event['evidence']:
                    raise DomainError('validation_failed', 'event evidence required')
                for impact in event['impacts']:
                    if not impact['evidence']:
                        raise DomainError('validation_failed', 'impact evidence required')
    except (ValueError, TypeError) as exc:
        if isinstance(exc, DomainError):
            raise
        raise DomainError('validation_failed', str(exc)) from exc
    return candidate


def validate_schedule(s):
    required = ['id', 'title', 'start', 'end', 'attendance', 'destination', 'region', 'trip']
    if any(k not in s for k in required) or not s['id'] or not s['title']:
        raise DomainError('schedule_invalid', 'missing schedule fields')
    if dt(s['end']) <= dt(s['start']):
        raise DomainError('schedule_invalid', 'invalid schedule period')
    if s['attendance'] not in ['ONSITE', 'ONLINE', 'UNKNOWN']:
        raise DomainError('schedule_invalid', 'invalid attendance')
    t = s['trip']
    if t.get('mode') not in ['car', 'taxi', 'bus', 'subway', 'rail', 'walk', 'unknown']:
        raise DomainError('schedule_invalid', 'invalid trip mode')
    if t.get('departure') and t.get('arrival') and dt(t['departure']) >= dt(t['arrival']):
        raise DomainError('schedule_invalid', 'invalid trip period')
    for key in ['departure', 'arrival', 'passage_at']:
        if t.get(key):
            dt(t[key])
    if not isinstance(t.get('facility_ids', []), list):
        raise DomainError('schedule_invalid', 'facility_ids must be a list')
    return s
