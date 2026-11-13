import 'package:liferadar_core/liferadar_core.dart';
import '../sources/sotong_contest.dart';
import 'store.dart';

/// Exact source IDs are upserts; other sources are never overwritten. Similar
/// cross-source announcements remain separate and are reported for review.
Map<String, dynamic> mergeContestFeed(
  Map<String, dynamic> base,
  ContestState state,
  Map<String, dynamic> metadata,
  DateTime now,
) {
  final other = <String, RadarEvent>{};
  for (final raw in (base['events'] as List? ?? const [])) {
    final e = RadarEvent.fromJson((raw as Map).cast<String, dynamic>());
    if (e.source != SotongContest.source) other[e.id] = e;
  }
  final contests = state.events(now);
  String key(String s) =>
      s.replaceFirst(RegExp(r'^【[^】]*】\s*'), '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9가-힣]'), '');
  final candidates = <Map<String, String>>[];
  for (final a in contests) {
    for (final b in other.values) {
      final sameTitle = key(a.title.ko) == key(b.title.ko);
      final sameOrganizer = a.venue.isNotEmpty && key(a.venue) == key(b.venue);
      final sameLink = a.registerUrl != null && a.registerUrl == b.registerUrl;
      final d = b.deadline;
      final ad = a.applicationDate(a.deadline!);
      final sameDeadline = d != null && ad.year == d.year && ad.month == d.month && ad.day == d.day;
      if ((sameTitle && sameOrganizer && sameDeadline) || (sameLink && sameDeadline)) {
        candidates.add({'sotongId': a.id, 'otherId': b.id, 'action': 'review-only; not auto-merged'});
      }
    }
  }
  final merged = <String, dynamic>{
    ...base,
    'generatedAt': now.toUtc().toIso8601String(),
    'sources': [
      for (final s in (base['sources'] as List? ?? const []))
        if ((s as Map)['id'] != SotongContest.source) s,
      {...metadata, 'count': contests.length, 'duplicateCandidates': candidates},
    ],
    'events': [...other.values, ...contests].map((e) => e.toJson()).toList()
      ..sort((a, b) => (a['start'] as String).compareTo(b['start'] as String)),
  };
  validateContestFeed(merged);
  return merged;
}
