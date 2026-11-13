import 'dart:convert';
import 'dart:io';
import 'package:liferadar_pipeline/src/contests/portal_review.dart';
import 'package:test/test.dart';

void main() {
  final input =
      jsonDecode(File('ops/portal-review-20261113.json').readAsStringSync())
          as Map;
  final records = (input['records'] as List).cast<Map<String, dynamic>>();
  final now = DateTime.parse('2026-11-14T00:00:00Z');
  test('reviewed hybrid sessions separate reception from physical dates', () {
    final events = records.map((r) => PortalReview.event(r, now)).toList();
    expect(events.map((e) => e.id).toSet(), hasLength(2));
    expect(events.map((e) => e.start.day), [7, 11]);
    for (final e in events) {
      expect(e.placeless, isFalse);
      expect(e.applicationStart, DateTime(2026, 11, 10));
      expect(e.applicationStatusAt(e.lastVerifiedAt!), 'open');
      expect(e.deadline, DateTime(2026, 11, 29));
      expect(e.eventDatePrecision, 'date');
    }
  });
  test(
    'missing venue evidence, invalid coordinates/dates and unreviewed records fail closed',
    () {
      final r = records.first;
      for (final bad in [
        {...r, 'reviewed': false},
        {...r, 'lat': 0},
        {...r, 'sourceUrl': 'https://evil.example/activity/363236'},
        {...r, 'deadline': '2026-02-30'},
        {...r, 'end': '2026-12-06'},
        {...r, 'verifiedAt': '2027-01-01T00:00:00Z'},
        {
          ...r,
          'evidence': {...r['evidence'] as Map}..remove('venue'),
        },
        {...r, 'participationMode': 'online'},
      ]) {
        expect(
          () => PortalReview.event(bad, now),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );
  test(
    'online or unknown place stays unmapped, cancelled reception hidden',
    () {
      final e = PortalReview.event({
        ...records.first,
        'onsite': false,
        'participationMode': 'online',
        'applicationStatus': 'cancelled',
      }, now);
      expect(e.placeless, isTrue);
      expect(e.start, e.applicationStart);
      expect(e.applicationVisible(now), isFalse);
    },
  );
  test(
    'all requested portals accept reviewed records with matching source hosts',
    () {
      for (final portal in PortalReview.hosts.entries) {
        final e = PortalReview.event({
          ...records.first,
          'portal': portal.key,
          'sourceUrl': 'https://${portal.value}/reviewed-post',
        }, now);
        expect(e.source, 'contest-${portal.key}');
      }
    },
  );
}
