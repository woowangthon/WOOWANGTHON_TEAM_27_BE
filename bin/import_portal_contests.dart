import 'dart:convert';
import 'dart:io';
import 'package:liferadar_pipeline/src/contests/portal_review.dart';

/// Local, reviewed snapshot merge. Invalid records abort before touching output.
void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      'dart run bin/import_portal_contests.dart REVIEW.json EXISTING.json OUTPUT.json',
    );
    exitCode = 64;
    return;
  }
  final review = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final base = jsonDecode(File(args[1]).readAsStringSync()) as Map;
  final now = DateTime.now().toUtc();
  final records = (review['records'] as List).cast<Map<String, dynamic>>();
  final parsed = [for (final r in records) PortalReview.event(r, now)];
  if (parsed.map((e) => e.id).toSet().length != parsed.length) {
    throw const FormatException('Duplicate contest session IDs');
  }
  final events = {
    for (final e in (base['events'] as List)) (e as Map)['id']: e,
  };
  final sources = {
    for (final s in (base['sources'] as List)) (s as Map)['id']: s,
  };
  var active = 0;
  for (var i = 0; i < parsed.length; i++) {
    final e = parsed[i];
    events.remove(e.id);
    if (e.applicationVisible(now)) {
      events[e.id] = {
        ...e.toJson(),
        'contestId': records[i]['contestId'],
        'sessionId': records[i]['sessionId'],
        'evidence': records[i]['evidence'],
      };
      active++;
    }
    // This is a partial manual snapshot, never an authoritative full crawl.
    sources[e.source] = {
      'id': e.source,
      'name': e.sourceName,
      'status': 'success',
      'coverage': 'reviewed-records-only',
      'access': 'manual-public-page-review',
      'automatedCollectionEnabled': false,
      'reuseConditions': 'unconfirmed',
      'license': null,
    };
  }
  for (final s in sources.values) {
    if (s['access'] == 'manual-public-page-review') {
      s['count'] = events.values.where((e) => e['source'] == s['id']).length;
      final timestamps =
          events.values
              .where((e) => e['source'] == s['id'])
              .map((e) => DateTime.parse(e['lastVerifiedAt'] as String))
              .toList()
            ..sort();
      s['verifiedAt'] = timestamps.isEmpty
          ? parsed
                .where((e) => e.source == s['id'])
                .map((e) => e.lastVerifiedAt!)
                .reduce((a, b) => a.isBefore(b) ? a : b)
                .toUtc()
                .toIso8601String()
          : timestamps.first.toUtc().toIso8601String();
    }
  }
  final result = {
    ...base,
    'sources': sources.values.toList(),
    'events': events.values.toList(),
  };
  final out = File(args[2]);
  out.parent.createSync(recursive: true);
  final tmp = File('${out.path}.tmp');
  tmp.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result)}\n',
  );
  tmp.renameSync(out.path);
  stdout.writeln(
    'Imported $active active sessions; ${events.length} total. Local output only.',
  );
}
