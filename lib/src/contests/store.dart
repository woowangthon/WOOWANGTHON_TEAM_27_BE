import 'dart:convert';
import 'dart:io';
import 'package:liferadar_core/liferadar_core.dart';
import '../sources/sotong_contest.dart';

class ContestState {
  ContestState({Map<String, Map<String, dynamic>>? records, this.lastSuccessAt, this.lastCompleteCount})
    : records = records ?? {};
  final Map<String, Map<String, dynamic>> records;
  String? lastSuccessAt;
  int? lastCompleteCount;

  factory ContestState.fromJson(Map<String, dynamic> j) {
    if (j['schemaVersion'] != 1 || j['records'] is! Map) throw const FormatException('Invalid contest ledger');
    final records = <String, Map<String, dynamic>>{};
    for (final entry in (j['records'] as Map).entries) {
      final r = (entry.value as Map).cast<String, dynamic>();
      if (r['sourceId'] != entry.key || r['source'] != SotongContest.source) {
        throw const FormatException('Contest ledger ID mismatch');
      }
      records[entry.key as String] = r;
    }
    return ContestState(
      records: records,
      lastSuccessAt: j['lastSuccessAt'] as String?,
      lastCompleteCount: j['lastCompleteCount'] as int?,
    );
  }

  static ContestState load(String path) => File(path).existsSync()
      ? ContestState.fromJson((jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>())
      : ContestState();

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'source': SotongContest.source,
    'lastSuccessAt': lastSuccessAt,
    'lastCompleteCount': lastCompleteCount,
    'records': records,
  };
  List<RadarEvent> events(DateTime now) =>
      records.values.map((r) => SotongContest.event(r, now)).whereType<RadarEvent>().toList();
  ContestState copy() => ContestState.fromJson((jsonDecode(jsonEncode(toJson())) as Map).cast<String, dynamic>());
}

/// Validated JSON is written completely before replacement. No tokens/HTML in ledger.
void writeContestJson(String path, Map<String, dynamic> json) {
  final encoded = const JsonEncoder.withIndent('  ').convert(json);
  jsonDecode(encoded);
  final file = File(path)..parent.createSync(recursive: true);
  final temp = File('$path.tmp');
  temp.writeAsStringSync(encoded, flush: true);
  temp.renameSync(file.path);
}

/// Source-specific checks, independent of the total number of cultural events.
void validateContestFeed(Map<String, dynamic> feed) {
  final sources = (feed['sources'] as List).cast<Map>();
  final meta = sources.where((s) => s['id'] == SotongContest.source).single;
  if (!['disabled', 'success', 'partial', 'failed'].contains(meta['status'])) {
    throw const FormatException('Missing sotong source outcome');
  }
  if (meta['status'] != 'success' && meta['preservedPrevious'] != true) {
    throw const FormatException('Failure preservation missing');
  }
  final rows = (feed['events'] as List).cast<Map>().where((e) => e['source'] == SotongContest.source).toList();
  if (meta['count'] != rows.length) throw const FormatException('Sotong count mismatch');
  final ids = <String>{};
  for (final r in rows) {
    final e = RadarEvent.fromJson(r.cast<String, dynamic>());
    if (!ids.add(e.id) ||
        !e.placeless ||
        e.lastVerifiedAt == null ||
        e.eligibilityText == null ||
        !['date', 'datetime'].contains(e.deadlinePrecision) ||
        e.deadline == null ||
        !e.id.startsWith('${SotongContest.source}-')) {
      throw const FormatException('Invalid Sotong event');
    }
  }
}
