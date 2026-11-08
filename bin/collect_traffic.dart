// 공식 교통 영향 정보를 수집한다: 서울시 TOPIS(서울 시내) + 국가교통정보센터 ITS(전국 고속도로·국도).
//
//   dart run bin/collect_traffic.dart [--out=out/traffic.json]
//
// 키를 앱에 넣지 않도록 앱이 아니라 GitHub Actions가 수집해 `data` 브랜치에 게시한다.
// 키: 환경 변수 또는 env.json → SEOUL_OPEN_API_KEY, ITS_API_KEY (하나만 있어도 동작).
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

/// 이보다 먼 미래의 항목은 수집하지 않는다 (판별 로직 문서의 초기 설정: 28일).
const _horizonDays = 28;

Future<void> main(List<String> args) async {
  final out = args.firstWhere((a) => a.startsWith('--out='), orElse: () => '--out=out/traffic.json').substring(6);
  final env = loadKeys();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final horizon = now.add(const Duration(days: _horizonDays));
  final notices = <TrafficNotice>[];
  final sources = <Map<String, String>>[];
  var failures = 0;

  // ── 서울시 TOPIS (서울 시내 집회·행사·공사) ──
  final seoulKey = (env['SEOUL_OPEN_API_KEY'] as String?)?.trim() ?? '';
  if (seoulKey.isEmpty) {
    stderr.writeln('! SEOUL_OPEN_API_KEY 없음 — TOPIS 건너뜀');
  } else {
    try {
      final res = await http.get(SeoulTraffic.uri(seoulKey)).timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) throw SourceException('${SeoulTraffic.source}: HTTP ${res.statusCode}');
      final rows = SeoulTraffic.rows(utf8.decode(res.bodyBytes));
      final found = [for (final r in rows) ?SeoulTraffic.parse(r)];
      notices.addAll(found);
      sources.add({'id': SeoulTraffic.source, 'name': SeoulTraffic.sourceName, 'url': SeoulTraffic.sourceUrl, 'license': '공공누리'});
      stdout.writeln('✓ ${SeoulTraffic.sourceName}: ${found.length}건 (전체 ${rows.length}행)');
    } catch (e) {
      failures++;
      stderr.writeln('✗ ${SeoulTraffic.sourceName}: $e');
    }
  }

  // ── 국가교통정보센터 ITS (전국 고속도로·국도) ──
  final itsKey = (env['ITS_API_KEY'] as String?)?.trim() ?? '';
  if (itsKey.isEmpty) {
    stderr.writeln('! ITS_API_KEY 없음 — ITS 건너뜀');
  } else {
    try {
      final res = await http.get(ItsTraffic.uri(itsKey)).timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) throw SourceException('${ItsTraffic.source}: HTTP ${res.statusCode}');
      final rows = ItsTraffic.rows(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
      final found = [for (final r in rows) ?ItsTraffic.parse(r)];
      notices.addAll(found);
      sources.add({'id': ItsTraffic.source, 'name': ItsTraffic.sourceName, 'url': ItsTraffic.sourceUrl, 'license': '공공누리'});
      stdout.writeln('✓ ${ItsTraffic.sourceName}: ${found.length}건 (전체 ${rows.length}건)');
    } catch (e) {
      failures++;
      stderr.writeln('✗ ${ItsTraffic.sourceName}: $e');
    }
  }

  if (sources.isEmpty) {
    stderr.writeln('수집한 출처가 없다 — $out을 변경하지 않는다.');
    exit(1);
  }

  // 끝났거나 너무 먼 항목 제외. 종료 시각이 없는 항목은 시작한 날까지만 유효하다고 본다
  // (판별 로직: 종료 미상을 무기한 활성화하지 않는다).
  final kept = {
    for (final n in notices)
      if (n.start.isBefore(horizon) && (n.end == null ? !n.start.isBefore(today) : n.end!.isAfter(now))) n.id: n,
  }.values.toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  final file = File(out)..createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
    'generatedAt': now.toUtc().toIso8601String(),
    'horizonDays': _horizonDays,
    'sources': sources,
    'notices': [for (final n in kept) n.toJson()],
  }));
  stdout.writeln('→ $out: ${kept.length}건${failures > 0 ? ' (출처 $failures개 실패)' : ''}');
  for (final n in kept.take(20)) {
    stdout.writeln('  ${n.source.padRight(12)} ${n.kind.name.padRight(12)} ${n.start} → ${n.end ?? '?'}  ${n.title}');
  }
}
