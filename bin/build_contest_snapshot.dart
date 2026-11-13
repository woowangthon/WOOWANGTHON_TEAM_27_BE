/// Offline manual-review snapshot builder. Does not collect or publish remotely.
library;
import 'dart:convert';
import 'dart:io';
import 'package:liferadar_pipeline/src/sources/sotong_contest.dart';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln('dart run bin/build_contest_snapshot.dart REVIEW.json SNAPSHOT.json NORMALIZED_REVIEW.json');
    exitCode = 64;
    return;
  }
  final input = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final now = DateTime.parse(input['verifiedAt'] as String);
  final records = <Map<String, dynamic>>[];
  final list = SotongContest.list(File('test/fixtures/sotong/list-1.html').readAsStringSync(), 1);
  for (final id in input['fixtures'] as List) {
    final row = list.rows.singleWhere((r) => r['sourceId'] == id);
    records.add(SotongContest.detail(row, File('test/fixtures/sotong/$id.html').readAsStringSync(), now));
  }
  const escape = HtmlEscape();
  String esc(Object? v) => escape.convert('$v');
  for (final entry in input['entries'] as List) {
    final r = (entry as Map).cast<String, dynamic>();
    final row = {...r, 'sourceUrl': r['sourceUrl'] ?? SotongContest.detailUrl(r['sourceId'] as String)};
    final body = '<div class="editor-content">'
        '<p>${esc(r['periodLabel'] ?? '접수기간')}: ${esc(r['period'])}</p>'
        '<p>참가자격: ${esc(r['eligibility'])}</p><p>${esc(r['method'])}</p>'
        '</div>${r['applyUrl'] == null ? '' : '<div class="url-li"><a href="${esc(r['applyUrl'])}">온라인접수</a></div>'}';
    // Minimal DOM assembled from reviewed evidence, never passed off as live HTML.
    final normalized = SotongContest.detail(row, body, now);
    normalized['source'] = r['source'] ?? SotongContest.source;
    normalized['sourceName'] = r['sourceName'] ?? SotongContest.name;
    if (r['price'] != null) normalized['fee'] = r['price'];
    if (r['note'] != null) normalized['summary'] = '${normalized['summary']}\n확인사항: ${r['note']}';
    records.add(normalized);
  }
  final events = <Map<String, dynamic>>[];
  for (final r in records) {
    final event = SotongContest.event(r, now);
    if (event == null) throw FormatException('Reviewed record failed validation: ${r['sourceId']} ${r['issues']}');
    events.add({...event.toJson(), 'id': '${r['source']}-${r['sourceId']}',
      'source': r['source'], 'sourceName': r['sourceName'] ?? SotongContest.name});
  }
  if (events.map((e) => e['id']).toSet().length != events.length) throw const FormatException('Duplicate IDs');
  final sources = [for (final source in events.map((e) => e['source']).toSet()) {
    'id': source, 'name': events.firstWhere((e) => e['source'] == source)['sourceName'],
    'access': input['access'], 'reuseConditions': 'unconfirmed', 'license': null,
    'count': events.where((e) => e['source'] == source).length, 'verifiedAt': now.toUtc().toIso8601String(),
  }];
  const encoder = JsonEncoder.withIndent('  ');
  File(args[1]).writeAsStringSync('${encoder.convert({'generatedAt': now.toUtc().toIso8601String(),
    'snapshotKind': 'manual-public-html-check', 'automatedCollectionEnabled': false, 'sources': sources, 'events': events})}\n');
  File(args[2]).writeAsStringSync('${encoder.convert({...input, 'normalized': records})}\n');
  stdout.writeln('Validated ${events.length} contests, ${sources.length} sources; local files only.');
}
