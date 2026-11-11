import json
import unittest
from copy import deepcopy
from news_traffic.demo import article, ARTICLES, REFERENCES
from news_traffic.extract import extract_strike_records, extract_event_traffic
from news_traffic.publish import publish
from news_traffic.publish import select_results
from news_traffic.store import Store
from news_traffic.common import DomainError


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.store = Store()
        self.addCleanup(self.store.db.close)

    def test_old_feed_preserved_and_body_verified_projection_added(self):
        old = {'strikes': [{'id': 'legacy'}]}
        feed = publish(old, self.store, [ARTICLES['scheduled']], REFERENCES)
        self.assertEqual(feed['strikes'], old['strikes'])
        self.assertEqual(len(feed['extractions'][0]['strikes'][0]), 11)
        self.assertTrue(feed['trafficImpacts'][0]['body_verified'])

    def test_failed_body_does_not_erase_old_verified_state(self):
        first = publish({}, self.store, [ARTICLES['scheduled']], REFERENCES)
        bad = {**ARTICLES['scheduled'], 'body': ''}
        second = publish(first, self.store, [bad], REFERENCES)
        self.assertEqual(second['trafficImpacts'][0]['id'], first['trafficImpacts'][0]['id'])
        self.assertEqual(second['extractionFailures'][0]['status'], 'body_missing')

    def test_withdrawal_changes_same_impact_version(self):
        first = publish({}, self.store, [ARTICLES['scheduled']], REFERENCES)
        second = publish(first, self.store, [ARTICLES['withdrawn']], REFERENCES)
        self.assertEqual(len(second['trafficImpacts']), 1)
        self.assertEqual(first['trafficImpacts'][0]['id'], second['trafficImpacts'][0]['id'])
        self.assertEqual(second['trafficImpacts'][0]['status'], 'WITHDRAWN')
        self.assertGreater(second['trafficImpacts'][0]['version'], first['trafficImpacts'][0]['version'])

    def test_non_demo_verified_reference_allowed_without_demo_hardcoding(self):
        a = {**ARTICLES['scheduled'], 'demo': False}
        refs = [{**REFERENCES[0], 'id': 'fixture-reference', 'demo': False, 'as_of': '2026-11-07', 'mode': 'bus'}]
        record = extract_strike_records(a, refs)[0]
        self.assertEqual(record['affected_routes'][0]['reference_id'], 'fixture-reference')

    def test_explicit_date_range_and_reversed_dates(self):
        a = article('서울 서울버스노조는 2026-11-11부터 2026-11-13까지 101번 버스 파업을 예고했다.')
        record = extract_strike_records(a, REFERENCES)[0]
        self.assertEqual(record['start']['date'], '2026-11-11')
        self.assertEqual(record['end']['date'], '2026-11-13')
        self.assertIsNone(record['start']['time'])
        with self.assertRaises(DomainError):
            extract_strike_records({**a, 'body': a['body'].replace('11-13', '11-09')}, REFERENCES)

    def test_unknown_end_not_fabricated_as_same_day_midnight(self):
        record = extract_strike_records(article('서울 버스노조는 2026-11-11 파업을 예고했다.'))[0]
        self.assertIsNone(record['end']['date'])
        self.assertIsNone(record['end']['time'])

    def test_city_name_inside_road_is_not_a_second_affected_region(self):
        result = publish({}, self.store, [ARTICLES['marathon']], REFERENCES)
        scope = result['trafficImpacts'][0]['scope'][0]
        self.assertEqual(scope['region'], '서울')
        self.assertEqual(scope['reference_id'], 'demo:seoul:road:sejong')

    def test_search_categories_share_body_fetch_budget(self):
        rows = [{'url': f'https://www.fnnews.com/strike/{n}', 'query': 'strike'} for n in range(20)]
        rows += [{'url': 'https://www.fnnews.com/event/1', 'query': 'event'}]
        self.assertTrue(any('/event/' in r['url'] for r in select_results(rows, 3)))

    def test_cache_eviction_restores_published_version_and_withdrawal(self):
        first = publish({}, self.store, [ARTICLES['scheduled']], REFERENCES)
        second = publish(first, self.store, [ARTICLES['withdrawn']], REFERENCES)
        replacement = Store()
        self.addCleanup(replacement.db.close)
        replacement.restore_public_feed(second)
        restored = publish(second, replacement, [ARTICLES['withdrawn']], REFERENCES)
        self.assertEqual(restored['trafficImpacts'][0]['version'], second['trafficImpacts'][0]['version'])
        self.assertEqual(restored['trafficImpacts'][0]['status'], 'WITHDRAWN')

    def test_same_sentence_independent_transport_subjects_are_separated(self):
        a = article('서울 서울버스노조는 파업을 철회했다, 부산 부산버스노조는 파업을 진행 중이다.')
        records = extract_strike_records(a)
        self.assertEqual(len(records), 2)
        self.assertEqual([r['strike_status']['value'] for r in records], ['withdrawn', 'ongoing'])

    def test_reference_lookup_changes_version_not_impact_identity(self):
        first = publish({}, self.store, [ARTICLES['marathon']], [])
        second = publish(first, self.store, [ARTICLES['marathon']], REFERENCES)
        self.assertEqual(len(second['trafficImpacts']), 1)
        self.assertEqual(second['trafficImpacts'][0]['id'], first['trafficImpacts'][0]['id'])
        self.assertGreater(second['trafficImpacts'][0]['version'], first['trafficImpacts'][0]['version'])

    def test_event_and_control_hours_in_linked_same_sentence_are_separate(self):
        text = '서울 한강마라톤은 2026-11-10 09:00부터 15:00까지 개최될 예정이며 이에 따라 서울 세종대로는 07:00부터 11:00까지 도로 통제 예정이다.'
        result = extract_event_traffic(article(text), REFERENCES)['events'][0]
        self.assertEqual(result['event_period']['start']['time'], '09:00')
        self.assertEqual(result['impacts'][0]['period']['start']['time'], '07:00')
        self.assertEqual(result['impacts'][0]['period']['end']['time'], '11:00')


if __name__ == '__main__':
    unittest.main()
