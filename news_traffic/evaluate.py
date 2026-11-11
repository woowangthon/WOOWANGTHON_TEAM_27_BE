"""Pure tri-state matching; explicit mismatches always win over partial matches."""
from datetime import timedelta
from math import asin, cos, radians, sin, sqrt
from .common import CONFIG, KST, dt


def distance(a, b):
    lat, lon, lat2, lon2 = map(radians, [a[0], a[1], b[0], b[1]])
    return 6371000 * 2 * asin(sqrt(sin((lat2 - lat) / 2) ** 2 + cos(lat) * cos(lat2) * sin((lon2 - lon) / 2) ** 2))


def match_time(s, impact, config):
    t, p = s['trip'], impact['period']
    a, b = p['start'], p['end']
    basis = 'PASSAGE' if t.get('passage_at') else 'WHOLE_TRIP' if t.get('departure') and t.get('arrival') else 'CANDIDATE_WINDOW'
    lo = dt(t['passage_at']) if basis == 'PASSAGE' else dt(t['departure']) if basis == 'WHOLE_TRIP' else dt(s['start']) - timedelta(hours=config['candidate_hours'])
    hi = lo if basis == 'PASSAGE' else dt(t['arrival']) if basis == 'WHOLE_TRIP' else dt(s['start'])
    if not a['date']:
        return 'UNKNOWN', basis
    # Open end is not an indefinite assertion unless explicitly stated.
    first = a['date']
    last = b['date'] or first
    if hi.astimezone(KST).date().isoformat() < first or (not b.get('open_ended') and lo.astimezone(KST).date().isoformat() > last):
        return 'NO_MATCH', basis
    if not a['time']:
        return 'DATE_MATCH', basis
    start = dt(first + 'T' + a['time'] + '+09:00')
    end = dt(last + 'T' + b['time'] + '+09:00') if b['time'] and b['date'] else None
    if hi < start or (hi == start and basis != 'PASSAGE') or (end and lo >= end):
        return 'NO_MATCH', basis
    if end is None:
        return 'POSSIBLE_MATCH', basis
    return ('WINDOW_MATCH' if basis == 'CANDIDATE_WINDOW' else 'EXACT_MATCH'), basis


def match_space(s, impact, config):
    t, scope = s['trip'], impact['scope']
    ids = {x['reference_id'] for x in scope if x.get('reference_id')}
    trip_ids = set(t.get('facility_ids', []))
    if ids and trip_ids:
        if ids & trip_ids:
            return 'ROUTE_MATCH'
        if impact['type'] in ('STRIKE', 'BUS_DETOUR', 'STOP_SKIP', 'STATION_RESTRICTION'):
            return 'NO_MATCH'
    # Coordinates only enter through a separately verified reference adapter.
    if s.get('verified_point') and impact.get('verified_point'):
        if distance(s['verified_point'], impact['verified_point']) <= config['nearby_meters']:
            return 'NEARBY'
    regions = {x['region'] for x in scope if x.get('region')}
    if regions and s.get('region'):
        return 'REGION_ONLY' if s['region'] in regions else 'NO_MATCH'
    return 'UNKNOWN'


def evaluate(s, impact, now, prior=None, config=CONFIG):
    tm, basis = match_time(s, impact, config)
    sp = match_space(s, impact, config)
    mode = 'UNKNOWN' if s['trip']['mode'] == 'unknown' or not impact['modes'] else 'APPLICABLE' if s['trip']['mode'] in impact['modes'] else 'NOT_APPLICABLE'
    previous = prior and prior['decision'] in ('RECOMMEND', 'CAUTION', 'REFERENCE', 'NEEDS_REVIEW')
    decision, reason = 'NEEDS_REVIEW', 'INSUFFICIENT_MATCH_DATA'
    if impact['status'] in ('WITHDRAWN', 'ENDED', 'NORMAL') and not impact.get('conflict'):
        decision, reason = ('RESOLVED' if previous else 'IGNORE'), 'IMPACT_RELEASED'
    elif s['attendance'] == 'ONLINE' or dt(s['start']) <= dt(now):
        decision, reason = ('RESOLVED' if previous else 'IGNORE'), 'SCHEDULE_INELIGIBLE'
    elif tm == 'NO_MATCH' or sp == 'NO_MATCH' or mode == 'NOT_APPLICABLE':
        decision, reason = ('RESOLVED' if previous else 'IGNORE'), 'NO_OVERLAP'
    elif impact.get('conflict') or impact['status'] == 'UNKNOWN' or tm == 'UNKNOWN' or sp == 'UNKNOWN':
        decision, reason = 'NEEDS_REVIEW', 'AMBIGUOUS_CORE_FIELDS'
    elif impact['status'] == 'CONDITIONAL':
        decision, reason = 'REFERENCE', 'CONDITION_UNCONFIRMED'
    elif sp == 'REGION_ONLY':
        decision, reason = 'REFERENCE', 'REGION_ONLY'
    elif tm in ('DATE_MATCH', 'POSSIBLE_MATCH') or mode == 'UNKNOWN':
        decision, reason = 'CAUTION', 'TIME_OR_MODE_UNCERTAIN'
    else:
        decision, reason = 'RECOMMEND', 'RELEVANT_TRANSPORT_IMPACT'
    # A scoped normal-service exception requires matching time AND verified facility scope.
    for exception in impact.get('exceptions', []):
        if exception.get('value') != 'normal':
            continue
        ex = {**impact, 'period': exception['period'], 'scope': exception['scope']}
        etm, _ = match_time(s, ex, config)
        ep = exception['period']
        lo = s['trip'].get('passage_at') or s['trip'].get('departure')
        hi = s['trip'].get('passage_at') or s['trip'].get('arrival')
        covers = False
        if lo and hi and ep['start']['date'] and ep['start']['time'] and ep['end']['date'] and ep['end']['time']:
            es = dt(ep['start']['date'] + 'T' + ep['start']['time'] + '+09:00')
            ee = dt(ep['end']['date'] + 'T' + ep['end']['time'] + '+09:00')
            covers = es <= dt(lo) and (dt(hi) < ee if s['trip'].get('passage_at') else dt(hi) <= ee)
        if exception['assertion'] != 'unknown' and covers and etm == 'EXACT_MATCH' and match_space(s, ex, config) == 'ROUTE_MATCH':
            decision, reason = ('RESOLVED' if previous else 'IGNORE'), 'NORMAL_SERVICE_EXCEPTION'
    messages = {
        'IGNORE': '수집 범위와 확인 가능한 근거에서 개인 안내 대상이 아닙니다. 교통 차질이 없음을 보장하지 않습니다.',
        'NEEDS_REVIEW': '날짜·범위·상태 또는 경로 정보가 부족하거나 충돌합니다. 최신 운행 안내를 확인해 주세요.',
        'REFERENCE': '조건부 예고 또는 같은 권역의 참고 정보입니다. 직접 경로 영향은 확정되지 않았습니다.',
        'CAUTION': '관련 교통 영향이 있으나 시간 또는 이동수단 확인이 필요합니다. 출발 전 안내를 확인해 주세요.',
        'RECOMMEND': '이용할 구간과 관련된 교통 영향이 이동 시간과 겹칩니다. 운행·통제 안내를 확인해 주세요.',
        'RESOLVED': '기존 안내의 해당 영향이 해제되었거나 변경된 일정·경로와 무관해졌습니다.'
    }
    text = messages[decision]
    if decision == 'RECOMMEND' and basis == 'CANDIDATE_WINDOW':
        text = '일정 시작 전 탐지 시간대에 관련 교통 영향이 있습니다. 실제 이동 시간을 입력하고 안내를 확인해 주세요.'
    if impact.get('assertion') == 'forecast':
        text = '출처의 혼잡 전망입니다. ' + text
    elif impact.get('assertion') == 'planned':
        text = '예정된 영향입니다. ' + text
    return dict(schedule_id=s['id'], schedule_revision=s['version'], trip_id=s['id'] + ':trip', trip_revision=s['trip']['version'],
                event_id=impact['event_id'], event_version=impact.get('event_version', impact['version']),
                impact_id=impact['id'], impact_version=impact['version'], decision=decision,
                reason_codes=[reason], time_match=tm, time_basis=basis, space_match=sp, mode_match=mode,
                evidence_refs=impact['evidence'], rule_version=config['rule_version'], config_snapshot=config,
                evaluated_at=now, notification_eligible=decision in ('RECOMMEND', 'CAUTION', 'RESOLVED'), message=text)
