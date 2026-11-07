// 공식 교통 영향 정보를 수집한다 (현재: 서울시 TOPIS 돌발정보 — 집회·행사·공사·기상).
//
//   dart run bin/collect_traffic.dart [--out=out/traffic.json]
//
// API가 http/XML만 제공하므로 앱이 아니라 GitHub Actions가 수집해 `data` 브랜치에 게시한다.
// 키: 환경 변수 또는 env.json → SEOUL_OPEN_API_KEY.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

/// 이보다 먼 미래의 항목은 수집하지 않는다 (판별 로직 문서의 초기 설정: 28일).
const _horizonDays = 28;

Future<void> main(List<String> args) async {
  final out = args.firstWhere((a) => a.startsWith('--out='), orElse: () => '--out=out/traffic.json').substring(6);
  final env = loadKeys();
  final key = (env['SEOUL_OPEN_API_KEY'] as String?)?.trim() ?? '';
  if (key.isEmpty) {
    stderr.writeln('SEOUL_OPEN_API_KEY 없음 — 수집하지 않음');
    exit(1);
  }

  final now = DateTime.now();
  final horizon = now.add(const Duration(days: _horizonDays));
  final res = await http.get(SeoulTraffic.uri(key)).timeout(const Duration(seconds: 60));
  if (res.statusCode != 200) {
    stderr.writeln('HTTP ${res.statusCode}');
    exit(1);
  }
  final rows = SeoulTraffic.rows(utf8.decode(res.bodyBytes));
  final notices = [
    for (final r in rows) ?SeoulTraffic.parse(r),
  ].where((n) => (n.end == null || n.end!.isAfter(now)) && n.start.isBefore(horizon)).toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  final file = File(out)..createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
    'generatedAt': now.toUtc().toIso8601String(),
    'horizonDays': _horizonDays,
    'sources': [
      {'id': SeoulTraffic.source, 'name': SeoulTraffic.sourceName, 'url': SeoulTraffic.sourceUrl, 'license': '공공누리'},
    ],
    'notices': [for (final n in notices) n.toJson()],
  }));
  stdout.writeln('→ $out: ${notices.length}건 (전체 ${rows.length}행)');
  for (final n in notices) {
    stdout.writeln('  ${n.kind.name.padRight(12)} ${n.start} → ${n.end ?? '?'}  '
        '(${n.location.lat.toStringAsFixed(5)}, ${n.location.lng.toStringAsFixed(5)})  ${n.title}');
  }
}
