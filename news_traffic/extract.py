"""Conservative Korean grammar subset. Unsupported clauses stay unknown.

No LLM is connected. Candidates always pass the same public validation gate.
"""
import re
from copy import deepcopy
from datetime import date, timedelta
from .common import CONFIG, KST, DomainError, digest, dt
from .schemas import validate
from .geography import domestic_subject

MODES = {'버스': 'bus', '지하철': 'subway', '도시철도': 'subway', '철도': 'rail', '열차': 'rail', 'KTX': 'rail'}


def empty_time():
    return dict(raw=None, date=None, time=None, timezone='Asia/Seoul', basis='unknown', assertion='unknown', open_ended=None)


def evidence(a, quote, path, derivation='explicit', reference=None):
    return dict(field_path=path, quote=quote, source_part='body', effective_at=None, derivation=derivation,
                source_id=a['source_id'], source_revision=a['source_revision'], reference_source=reference)


def prepare(a):
    a = deepcopy(a)
    if not a.get('body', '').strip():
        raise DomainError('body_missing')
    if not a.get('source_url') or not a.get('collected_at') or not isinstance(a.get('title'), str):
        raise DomainError('input_invalid', 'source_url, title and collected_at required')
    for k in ['published_at', 'updated_at', 'collected_at']:
        if a.get(k):
            dt(a[k])
    a.setdefault('published_at', None)
    a.setdefault('updated_at', None)
    a.setdefault('source_id', digest(a['source_url']))
    a.setdefault('source_revision', digest(a['body']))
    return a


def sentences(body):
    # Newlines / sentence punctuation separate assertions. Avoid splitting ISO dates.
    body = re.sub(r'\([^)]*=.*?\)', '', body)
    # Split independent explicit subjects, but keep a subject's "planned, then
    # withdrawn" chronology in one assertion group. Every returned clause is
    # still an exact substring of the supplied body.
    subjects = r'(?:서울|부산|인천|대구|광주|울산|대전|세종|[가-힣A-Za-z]+노조)'
    boundary = r'(?<=[.!?。])\s+|[\n;]+|[,，]\s*(?=' + subjects + r'|이에 따라|이로 인해)|(?<=반면)\s+(?=' + subjects + r')|(?<=지만)\s+(?=' + subjects + r')|(?<=며)\s+(?=이에 따라|이로 인해)'
    return [s.strip() for s in re.split(boundary, body) if s.strip()
            and not re.match(r'\s*(?:SYSTEM|ASSISTANT|USER|시스템\s*지시|프롬프트|<\|)', s, re.I)]


def period(text, a, assertion='planned'):
    start, end = empty_time(), empty_time()
    day, basis, raw_day = None, 'unknown', None
    m = re.search(r'(20\d{2})[-년.]\s*(\d{1,2})[-월.]\s*(\d{1,2})일?', text)
    if m:
        day = f'{int(m[1]):04}-{int(m[2]):02}-{int(m[3]):02}'
        raw_day, basis = m[0], 'explicit'
    else:
        m = re.search(r'(오늘|내일|모레)', text)
        if m:
            raw_day, basis = m[0], 'relative'
            # Modified relative statements require a verified per-sentence anchor; do not guess.
            if a.get('published_at') and not a.get('updated_at'):
                day = (dt(a['published_at']).astimezone(KST).date() + timedelta(days={'오늘': 0, '내일': 1, '모레': 2}[m[0]])).isoformat()
    if raw_day:
        start.update(raw=raw_day, date=day, basis=basis, assertion=assertion)
    dates = list(re.finditer(r'20\d{2}-\d{2}-\d{2}', text))
    if len(dates) >= 2 and re.search(r'부터|까지|[~～–—]|익일', text):
        end.update(raw=dates[1][0], date=dates[1][0], basis='explicit', assertion=assertion, open_ended=False)
    times = list(re.finditer(r'(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)|(?:(오전|오후)\s*)?(\d{1,2})시(?:\s*(\d{1,2})분)?', text))
    for target, match in zip((start, end), times):
        if match[1] is not None:
            hh, mm = int(match[1]), int(match[2])
        else:
            hh, mm = int(match[4]), int(match[5] or 0)
            if match[3] == '오후' and hh < 12:
                hh += 12
            elif match[3] == '오전' and hh == 12:
                hh = 0
        target.update(raw=' '.join(x for x in [raw_day, match[0]] if x), time=f'{hh:02}:{mm:02}',
                      basis=basis if basis == 'relative' else 'explicit', assertion=assertion)
        if target is end and not end['date']:
            end['date'] = day
    if '익일' in text and day and end['time']:
        end['date'] = (date.fromisoformat(day) + timedelta(days=1)).isoformat()
    for token, b in [('첫차', 'first_service'), ('막차', 'last_service')]:
        if token in text:
            start.update(raw=' '.join(x for x in [raw_day, token] if x), time=None, basis=b, assertion=assertion)
    if '무기한' in text:
        end.update(raw='무기한', open_ended=True)
    elif end['time']:
        end['open_ended'] = False
    precision = 'EXACT' if day and start['time'] and end['time'] else 'PARTIAL' if day and start['time'] else 'DATE_ONLY' if day else 'UNKNOWN'
    condition = '행사 종료 시까지' if re.search(r'행사\s*종료\s*시까지', text) else '해제 시까지' if '해제 시까지' in text else None
    return dict(start=start, end=end, precision=precision, condition=condition)


def locations(text, refs=(), demo=False):
    names = list(CONFIG['regions']) + ['세종', '경기', '강원', '충북', '충남', '전북', '전남', '경북', '경남', '제주', '전국', '수도권']
    regions = [r for r in names if re.search(r'(?<![가-힣])' + re.escape(r) + r'(?:특별자치도|특별자치시|특별시|광역시|시|도)?(?=$|\s|[.,·=/()，~]|[은는의])', text)]
    region = regions[0] if len(regions) == 1 else None
    out = []
    for match in re.finditer(r'(?:\d{1,4}번(?:\s*버스)?|\d+호선|[가-힣A-Za-z0-9]+(?:대로|대교|출입구|정류장|역|로|선)(?:\s*\d+번?\s*출입구)?)', text):
        raw = match[0]
        if raw in ('행사로', '도로', '대체로', '노선', '일부노선') or raw.endswith(('축제로', '마라톤으로', '집회로')):
            continue
        # Never turn a bare city/road string into a verified ID.
        ref = next((r for r in refs if r['raw'] == raw and r['region'] == region and r.get('demo', False) == demo), None)
        out.append(dict(raw=raw, normalized_name=raw, region=region, reference_id=ref['id'] if ref else None,
                        derivation='reference_mapping' if ref else 'article_explicit',
                        reference_source=ref['source'] if ref else None))
    direction = re.search(r'상행|하행|양방향|[가-힣A-Za-z0-9]+\s*방면', text)
    section = re.search(r'[가-힣A-Za-z0-9]+(?:역|정류장)\s*[~～–]\s*[가-힣A-Za-z0-9]+(?:역|정류장)', text)
    if len(out) == 1:
        out[0].update(direction=direction[0] if direction else None, section=section[0] if section else None)
    return regions, out


def region_objects(regions):
    return [dict(raw=r, normalized_name=r, region=r, reference_id=None, derivation='article_explicit', reference_source=None) for r in regions]


def strike_state(text):
    """Recognize predicate clauses, with negated/quoted/hypothetical clauses masked."""
    if re.search(r'작년|지난해|당시', text) and not re.search(r'올해|오늘|내일', text):
        return 'historical'
    clauses = re.split(r'[,，]|(?:었으나|했으나|였으나)|(?:반면)', text)
    states = []
    for c in clauses:
        c = re.sub(r'철회(?:를)?\s*(?:요구|검토|하지|안\s*했|하지\s*않)[^,]*?(?=에도|지만|$)', '', c)
        if re.search(r'(?:결렬|개최).*(?:시|경우)|합의되면|타결되지 않으면', c):
            states.append('conditional' if re.search(r'파업.*(?:예고|예정|돌입|한다)', c) else 'unknown')
        elif re.search(r'(?:파업[을는]?\s*)?(?:계속하고|지속하고|돌입했|돌입했다|진행 중)', c):
            states.append('ongoing')
        elif re.search(r'철회(?:를)?\s*(?:했다|하였다|확정)', c):
            states.append('withdrawn')
        elif re.search(r'유보(?:를)?\s*(?:했다|확정)', c):
            states.append('deferred')
        elif re.search(r'파업(?:을|이)?\s*종료(?:했다|됐다)', c):
            states.append('ended')
        elif re.search(r'파업.*(?:예정|예고)', c):
            states.append('scheduled')
        elif re.search(r'파업(?:을|은|이)?\s*유지(?:한다|했다|하고)', c):
            # A maintained plan is not proof of actual service suspension.
            states.append('scheduled')
        elif re.search(r'찬반투표|쟁의.*투표', c):
            states.append('preparing')
    return states[-1] if states else 'unknown'


def extract_strike_records(article, refs=()):
    a = prepare(article)
    relevant = [s for s in sentences(a['body']) if '파업' in s or '철회' in s or '정상 운행' in s]
    if not relevant:
        relevant = [a['body']]
    # Group by explicit region + direct transport subject; ambiguous multi-subject sentences remain reviewable.
    groups = {}
    for s in relevant:
        direct = re.split(r'증편|대체|권장', s)[0]
        rs, _ = locations(s)
        mode = next((v for k, v in MODES.items() if k in direct), 'unknown')
        actor = re.search(r'[가-힣A-Za-z]+(?:노조|공사|운수)', s)
        actor = actor[0] if actor else None
        if actor is None:
            actor = next((k[2] for k in reversed(groups) if k[:2] == (tuple(rs), mode)), None)
        key = (tuple(rs), mode, actor)
        groups.setdefault(key, []).append(s)
    records = []
    for (rs, mode, actor), ss in groups.items():
        text = ' '.join(ss)
        related = '파업' in text and domestic_subject(text)
        state = strike_state(text) if related else 'unknown'
        p = period(text, a, 'actual' if state in ('ongoing', 'ended') else 'planned')
        direct_text = ' '.join(re.split(r'반면|대체|증편', s)[0] for s in ss if '파업' in s)
        _, routes = locations(direct_text, refs, a.get('demo', False))
        routes = [r for r in routes if re.search(r'\d+번|선|역', r['raw'])]
        service, exceptions, alternatives = [], [], []
        ev = []
        for s in ss:
            assertion = 'planned' if re.search(r'예정|부터 정상', s) else 'actual'
            sp = period(s, a, assertion)
            _, scopes = locations(s, refs, a.get('demo', False))
            for label, pattern in [('suspended', r'운행(?:을)?\s*중단'), ('reduced', r'감축|운행률\s*\d+'), ('recovering', r'복구 중|복구 대기|복구되지|정상화 전'), ('normal', r'정상 운행')]:
                if re.search(pattern, s):
                    if label == 'normal' and re.search(r'정상 운행.*(?:않|아니)', s):
                        continue
                    metrics = [dict(raw=m[0], value=float(m[1]), unit='%') for m in re.finditer(r'운행률\s*(\d+(?:\.\d+)?)%', s)]
                    entry = dict(value=label, assertion=assertion, raw=s, scope=scopes, period=sp, metrics=metrics)
                    if label == 'normal' and re.search(r'만 정상|시간.*정상|제외', s):
                        exceptions.append(entry)
                    else:
                        service.append(entry)
            if re.search(r'증편|대체|셔틀', s):
                altmode = next((v for k, v in MODES.items() if re.search(k + r'\s*(?:증편|이용|대체)', s)), 'unknown')
                alternatives.append(dict(raw=s, mode=altmode, routes=[], period=sp))
        if not related:
            mode, routes, rs = 'unknown', [], []
            p = period('', a)
            service, exceptions, alternatives = [], [], []
        # Each nonempty field is backed by an actual supplied body passage.
        fields = ['article_relevance', 'transport_mode', 'affected_regions', 'affected_routes', 'strike_status', 'service_status', 'normal_service_exceptions', 'alternative_services', 'start', 'end']
        for field in fields:
            for s in ss:
                ev.append(evidence(a, s, '/' + field))
        reasons = []
        if state == 'unknown' and related:
            reasons.append('UNSUPPORTED_OR_AMBIGUOUS_STATUS')
        if not p['start']['date'] and related:
            reasons.append('DATE_UNCONFIRMED')
        if len(rs) > 1:
            state = 'unknown'
            reasons.append('MULTIPLE_SUBJECTS_REQUIRE_REVIEW')
        record = dict(article_relevance='related' if related else 'unrelated', transport_mode=mode,
                      affected_regions=region_objects(rs), affected_routes=routes, start=p['start'], end=p['end'],
                      strike_status=dict(value=state, conditions=[s for s in ss if re.search(r'경우|결렬 시|않으면', s)], scope_raw=text if related else None, effective_at=None),
                      service_status=service, normal_service_exceptions=exceptions, alternative_services=alternatives,
                      evidence_and_timestamps=dict(source_url=a['source_url'], published_at=a['published_at'], updated_at=a['updated_at'],
                                                   collected_at=a['collected_at'], field_evidence=ev, review_reasons=reasons))
        records.append(validate(a, record, 'strike', refs=refs))
    return records


IMPACT_PATTERNS = [
    ('ROAD_CLOSURE', r'(?:도로|차량|[가-힣]+로).*통제', ['car', 'taxi', 'bus']),
    ('BUS_DETOUR', r'버스.*우회', ['bus']),
    ('STOP_SKIP', r'무정차', ['bus']),
    ('STATION_RESTRICTION', r'출입구.*폐쇄|역.*이용 제한', ['walk']),
    ('CONGESTION_FORECAST', r'(?:교통|차량|보행).*혼잡.*(?:예상|전망)', []),
]


def extract_event_traffic(article, refs=()):
    a = prepare(article)
    ss = sentences(a['body'])
    types = [('MARATHON', '마라톤'), ('RALLY', '집회'), ('RALLY', '시위'), ('FESTIVAL', '축제')]
    typed = [(s, typ, token) for s in ss for typ, token in types if token in s]
    events = []
    for index, (s, typ, token) in enumerate(typed):
        if not domestic_subject(s):
            continue
        # A constrained named-event paragraph; independent paragraphs become independent candidates.
        name = re.search(r'([가-힣A-Za-z0-9]+\s*' + token + ')', s)
        name = name[1] if name else token
        status = 'UNKNOWN'
        if re.search(r'취소(?:를)?\s*(?:확정|했다|됐다)', s):
            status = 'CANCELLED'
        elif re.search(r'연기(?:됐다|했다)|변경(?:됐다|했다)', s):
            status = 'CHANGED'
        elif re.search(r'개최.*(?:예정|한다)|열릴 예정|개최된다', s):
            status = 'PLANNED'
        rs, locs = locations(s, refs, a.get('demo', False))
        event_p = period(s, a)
        dates = list(re.finditer(r'20\d{2}-\d{2}-\d{2}', s))
        if len(dates) == 2 and '매일' in s:
            event_p['end']['date'] = dates[-1][0]
        if status == 'CHANGED' and len(dates) == 2:
            event_p = period(s[dates[-1].start():], a)
        impacts = []
        # Only attach continuation clauses with an explicit causal link. Other events are not swept in.
        linked = [s]
        for follow in ss[ss.index(s) + 1:]:
            if any(t in follow for _, t in types):
                break
            if re.search(r'이에 따라|행사로|철거|해당 행사|이로 인해', follow):
                linked.append(follow)
        for clause in linked:
            if not domestic_subject(s + ' ' + clause):
                continue
            for impact_type, pattern, modes in IMPACT_PATTERNS:
                if not re.search(pattern, clause):
                    continue
                if impact_type == 'CONGESTION_FORECAST' and re.search(r'혼잡.*(?:없|않|아니)', clause):
                    continue
                if re.search(r'통제(?:는|를|가)?\s*(?:없|하지 않)|정상 통행', clause) and impact_type == 'ROAD_CLOSURE':
                    continue
                if re.search(r'지난해|작년', clause):
                    continue
                istate = 'ANNOUNCED'
                if re.search(r'(?:우회|통제|무정차|폐쇄)(?:를|는|가)?\s*(?:철회했다|해제했다|해제됐다|종료됐다)', clause):
                    istate = 'WITHDRAWN'
                elif re.search(r'검토|하지 않|요구', clause):
                    istate = 'UNKNOWN'
                elif re.search(r'개최 시|열리면|할 수 있|경우', clause):
                    istate = 'CONDITIONAL'
                assertion = 'forecast' if impact_type == 'CONGESTION_FORECAST' else 'actual' if re.search(r'통제 중|우회 중|유지|발생했다', clause) else 'planned'
                _, scope = locations(clause, refs, a.get('demo', False))
                if impact_type == 'STATION_RESTRICTION' and '출입구' in clause:
                    scope = [x for x in scope if '출입구' in x['raw']]
                if not scope:
                    scope = region_objects(rs)
                ip = period(clause, a, assertion if assertion != 'forecast' else 'planned')
                ambiguous_windows = len(re.findall(r'\d{1,2}:\d{2}|\d{1,2}시', clause)) > 2
                if ambiguous_windows:
                    # Do not reuse event hours as control hours when the grammar
                    # cannot assign multiple windows to their own predicates.
                    ip['start']['time'] = ip['end']['time'] = None
                    ip['precision'] = 'DATE_ONLY' if ip['start']['date'] else 'UNKNOWN'
                if status == 'CHANGED' and len(dates) == 2 and clause == s:
                    ip = period(clause[dates[-1].start():], a)
                # Copy only explicit date context, never event hours.
                if not ip['start']['date'] and event_p['start']['date'] and not re.search(r'내일|모레|오늘|20\d{2}', clause):
                    for edge in ['start', 'end']:
                        ip[edge]['date'] = event_p['start']['date']
                    ip['precision'] = 'EXACT' if ip['start']['time'] and ip['end']['time'] else 'PARTIAL' if ip['start']['time'] else 'DATE_ONLY'
                if impact_type == 'CONGESTION_FORECAST':
                    modes = ['walk'] if '보행' in clause else ['car', 'taxi', 'bus'] if '차량' in clause else []
                # A cancellation does not release explicitly maintained teardown controls.
                if status == 'CANCELLED' and not re.search(r'철거|유지', clause):
                    istate = 'WITHDRAWN'
                # Reference lookup/provenance changes are semantic revisions,
                # not new impacts. Canonicalize absent optional scope fields.
                scope_identity = [{k: x.get(k) for k in ('raw', 'region', 'section', 'direction')} for x in scope]
                impacts.append(dict(impact_ref=digest([impact_type, scope_identity]), impact_type=impact_type, impact_status=istate,
                                    assertion=assertion, period=ip, affected_scope=scope, affected_modes=modes,
                                    exceptions=[], conditions=[clause] if istate == 'CONDITIONAL' else [],
                                    source_recommendations=[clause] if '권장' in clause else [],
                                    evidence=[evidence(a, clause, '/impacts'), evidence(a, s, '/period/date', 'normalized')],
                                    review_reasons=(['UNSUPPORTED_STATUS'] if istate == 'UNKNOWN' else []) + (['MULTIPLE_TIME_WINDOWS_REQUIRE_REVIEW'] if ambiguous_windows else [])))
                recurrence = list(re.finditer(r'20\d{2}-\d{2}-\d{2}', clause))
                if '매일' in clause and len(recurrence) == 2:
                    first, last = date.fromisoformat(recurrence[0][0]), date.fromisoformat(recurrence[1][0])
                    if not 0 <= (last - first).days <= 31:
                        raise DomainError('validation_failed', 'unsupported recurrence period')
                    template = impacts.pop()
                    for n in range((last - first).days + 1):
                        daily = deepcopy(template)
                        day = (first + timedelta(days=n)).isoformat()
                        daily['period']['start']['date'] = daily['period']['end']['date'] = day
                        daily['impact_ref'] = digest([template['impact_ref'], day])
                        impacts.append(daily)
        events.append(dict(event_ref=str(index), event_name=name, event_type=typ, event_status=status,
                           event_period=event_p, event_locations=locs or region_objects(rs), impacts=impacts,
                           evidence=[evidence(a, s, '/event')], review_reasons=['EVENT_IDENTITY_REQUIRES_REVIEW'] if name == token else []))
    unsupported = not events and bool(re.search(r'시위|퍼레이드|행진', a['body']))
    result = dict(schema_version='1.0', article_relevance='related' if events else 'unknown' if unsupported else 'unrelated',
                  processing_status='needs_review' if unsupported else 'partial' if any(e['review_reasons'] or any(i['review_reasons'] for i in e['impacts']) for e in events) else 'success',
                  source={k: a[k] for k in ['source_id', 'source_url', 'source_revision', 'published_at', 'updated_at', 'collected_at']}, events=events, review_reasons=['UNSUPPORTED_EVENT_CONTEXT'] if unsupported else [])
    return validate(a, result, 'event', refs=refs)
