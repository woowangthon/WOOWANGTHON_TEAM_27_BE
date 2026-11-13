import unittest
from news_traffic.demo import article, ARTICLES, REFERENCES, schedule, DEMO_NOW
from news_traffic.extract import extract_strike_records, extract_event_traffic
from news_traffic.evaluate import evaluate
from news_traffic.publish import publish
from news_traffic.store import Store


class DomesticScopeTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.db.close)

    def test_spain_nationwide_strike_is_unrelated(self):
        records = extract_strike_records(article('스페인 버스노조는 2026-11-10 전국 버스 파업을 예고했다.'))
        self.assertTrue(all(r['article_relevance'] == 'unrelated' for r in records))

    def test_korean_dateline_does_not_make_overseas_strike_domestic(self):
        records = extract_strike_records(article('서울에서 전한다. 스페인 버스노조는 2026-11-10 전국 파업을 예고했다.'))
        self.assertTrue(all(r['article_relevance'] == 'unrelated' for r in records))

    def test_foreign_rally_has_no_traffic_impact(self):
        self.assertEqual(extract_event_traffic(article('스페인 마드리드 집회는 2026-11-10 개최된다. 이에 따라 차량 교통 혼잡이 예상된다.'))['events'], [])

    def test_event_listing_and_negated_forecast_have_no_impact(self):
        for text in ['서울 한강축제는 2026-11-10 개최된다.',
                     '서울 한강축제는 2026-11-10 개최된다. 이에 따라 서울 교통 혼잡은 예상되지 않는다.']:
            events = extract_event_traffic(article(text))['events']
            self.assertTrue(events)
            self.assertTrue(all(not e['impacts'] for e in events))

    def test_explicit_domestic_forecast_is_kept(self):
        events = extract_event_traffic(article('서울 한강축제는 2026-11-10 개최된다. 이에 따라 서울 차량 교통 혼잡이 예상된다.'))['events']
        self.assertEqual(events[0]['impacts'][0]['impact_type'], 'CONGESTION_FORECAST')

    def test_strike_requires_actual_line_and_mode(self):
        feed = publish({}, self.store, [ARTICLES['scheduled']], REFERENCES)
        impact = feed['trafficImpacts'][0]
        s = schedule()
        s['version'] = s['trip']['version'] = 1
        self.assertTrue(evaluate(s, impact, DEMO_NOW)['notification_eligible'])
        for ids, mode in [([], 'bus'), (['demo:other'], 'bus'), (['demo:seoul:bus:101'], 'car')]:
            s['trip'].update(facility_ids=ids, mode=mode)
            self.assertEqual(evaluate(s, impact, DEMO_NOW)['decision'], 'IGNORE')

    def test_explicit_impact_area_boundary(self):
        impact = publish({}, self.store, [ARTICLES['marathon']], REFERENCES)['trafficImpacts'][0]
        impact.update(verified_point=[37.5663, 126.9779], affected_radius_m=300,
                      area_reference_source='fixture affected road scope')
        s = schedule()
        s['version'] = s['trip']['version'] = 1
        s['trip'].update(mode='car', facility_ids=[])
        s['verified_point'] = [37.5663, 126.9779]
        self.assertTrue(evaluate(s, impact, DEMO_NOW)['notification_eligible'])
        s['verified_point'] = [37.58, 126.9779]
        self.assertFalse(evaluate(s, impact, DEMO_NOW)['notification_eligible'])
        impact.pop('affected_radius_m')
        s['verified_point'] = impact['verified_point']
        self.assertFalse(evaluate(s, impact, DEMO_NOW)['notification_eligible'])

    def test_cached_foreign_impact_never_notifies(self):
        impact = publish({}, self.store, [ARTICLES['scheduled']], REFERENCES)['trafficImpacts'][0]
        impact.update(event_name='스페인 전국 파업', evidence=[{'quote': '스페인 버스 파업 예고'}])
        s = schedule()
        s['version'] = s['trip']['version'] = 1
        self.assertEqual(evaluate(s, impact, DEMO_NOW)['decision'], 'IGNORE')


if __name__ == '__main__':
    unittest.main()
