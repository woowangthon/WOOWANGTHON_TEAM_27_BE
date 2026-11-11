"""Synthetic articles and reference IDs. Never presented as real news or routes."""
from .common import digest

DEMO_NOW = '2026-11-07T16:00:00+09:00'
REFERENCES = [
    dict(raw='101번 버스', region='서울', id='demo:seoul:bus:101', source='synthetic reference v1 / 2026-11-07', demo=True),
    dict(raw='세종대로', region='서울', id='demo:seoul:road:sejong', source='synthetic reference v1 / 2026-11-07', demo=True),
    dict(raw='201번 버스', region='부산', id='demo:busan:bus:201', source='synthetic reference v1 / 2026-11-07', demo=True),
]


def article(body, stamp='2026-11-07T10:00:00+09:00', name='strike'):
    return dict(title='[고정 데모 기사] ' + name, body=body, source_url='https://www.fnnews.com/demo-fixture/' + name,
                source_id='demo:' + name, source_revision=digest(body), published_at=stamp, updated_at=None,
                collected_at=DEMO_NOW, demo=True)


ARTICLES = {
    'scheduled': article('서울 서울버스노조는 2026-11-10 08:00부터 11:00까지 101번 버스 파업을 예고했다.'),
    'withdrawn': article('서울 서울버스노조는 2026-11-10 08:00부터 11:00까지 101번 버스 파업을 철회했다.', '2026-11-07T12:00:00+09:00'),
    'ended': article('서울 서울버스노조는 2026-11-10 08:00부터 11:00까지 101번 버스 파업을 종료했다.\n서울 101번 버스는 운행 복구 중이다.', '2026-11-07T12:00:00+09:00'),
    'marathon': article('서울 한강마라톤은 2026-11-10 09:00부터 15:00까지 개최될 예정이다.\n이에 따라 서울 세종대로는 07:00부터 11:00까지 차량 도로 통제 예정이다.', name='marathon'),
    'teardown': article('서울 한강마라톤은 2026-11-10 개최 취소를 확정했다.\n행사로 서울 세종대로는 2026-11-10 07:00부터 11:00까지 시설 철거를 위한 도로 통제를 유지한다.', '2026-11-07T12:00:00+09:00', name='marathon'),
    'cancelled': article('서울 한강마라톤은 2026-11-10 개최 취소를 확정했다.', '2026-11-07T13:00:00+09:00', name='marathon'),
    'released': article('서울 한강마라톤은 2026-11-10 개최 취소를 확정했다.\n이에 따라 서울 세종대로는 2026-11-10 07:00부터 11:00까지 도로 통제를 해제했다.', '2026-11-07T14:00:00+09:00', name='marathon'),
}


def schedule(id='demo-schedule'):
    return dict(id=id, title='[데모] 오전 미팅', start='2026-11-10T10:00:00+09:00', end='2026-11-10T11:00:00+09:00',
                attendance='ONSITE', destination='서울 · 사용자가 지정한 장소', region='서울', verified_point=None, demo=True,
                trip=dict(origin='사용자가 지정한 출발지', mode='bus', departure='2026-11-10T09:00:00+09:00',
                          arrival='2026-11-10T09:40:00+09:00', passage_at=None, facility_ids=['demo:seoul:bus:101'],
                          route_raw='101번 버스', section=None, direction=None, stop=None, station=None,
                          source='manual_demo_reference', updated_at=DEMO_NOW))
