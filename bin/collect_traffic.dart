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

Future<void> main(List<String> args) async {
  final out = args.firstWhere((a) => a.startsWith('--out='), orElse: () => '--out=out/traffic.json').substring(6);
  final env = loadKeys();
  final now = DateTime.now().toUtc();
  final outcomes = <String, (List<TrafficNotice>, bool)>{};
  final failed = <String>{};
  final sources = <Map<String, String>>[];

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
      outcomes[SeoulTraffic.source] = (found, SeoulTraffic.isComplete(utf8.decode(res.bodyBytes), rows));
      sources.add({
        'id': SeoulTraffic.source,
        'name': SeoulTraffic.sourceName,
        'url': SeoulTraffic.sourceUrl,
        'license': '공공누리',
      });
      stdout.writeln('✓ ${SeoulTraffic.sourceName}: ${found.length}건 (전체 ${rows.length}행)');
    } catch (e) {
      failed.add(SeoulTraffic.source);
      stderr.writeln('TOPIS collection failed');
    }
  }

  // ── 국가교통정보센터 ITS (전국 고속도로·국도) ──
  final itsKey = (env['ITS_API_KEY'] as String?)?.trim() ?? '';
  if (itsKey.isEmpty) {
    stderr.writeln('! ITS_API_KEY 없음 — ITS 건너뜀');
  } else {
    try {
      // ITS는 해외 IP를 차단한다 — GitHub Actions(미국)에서는 응답이 없어 짧게 기다리고 넘어간다.
      // 앱은 한국 내 기기에서 ITS를 직접 조회하므로 데이터가 빠지지 않는다.
      final res = await http.get(ItsTraffic.uri(itsKey)).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw SourceException('${ItsTraffic.source}: HTTP ${res.statusCode}');
      final rows = ItsTraffic.rows(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
      final found = [for (final r in rows) ?ItsTraffic.parse(r)];
      outcomes[ItsTraffic.source] = (
        found,
        ItsTraffic.isComplete(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>),
      );
      sources.add({
        'id': ItsTraffic.source,
        'name': ItsTraffic.sourceName,
        'url': ItsTraffic.sourceUrl,
        'license': '공공누리',
      });
      stdout.writeln('✓ ${ItsTraffic.sourceName}: ${found.length}건 (전체 ${rows.length}건)');
    } catch (e) {
      failed.add(ItsTraffic.source);
      stderr.writeln('ITS collection failed');
    }
  }

  await TrafficStore(File(out).parent).transaction((ledger) async {
    for (final e in outcomes.entries) {
      ledger.accept(e.key, e.value.$1, now, complete: e.value.$2);
    }
    for (final id in failed) {
      ledger.failure(id, now, 'collection_failed');
    }
    ledger.states.putIfAbsent('utic', () => {'status': 'disabled', 'errorCategory': UticXml.quarantineReason});
    final feed = ledger.feed(now);
    ledger.stagePublication(File('${File(out).parent.path}/traffic-v2.json'), feed);
    if (outcomes.isNotEmpty || ledger.snapshots.isNotEmpty) {
      ledger.stagePublication(File(out), legacyTrafficFeed(feed));
    }
  });
  if (sources.isEmpty) {
    stderr.writeln('새 정상 수집 없음 — 내구 스냅샷의 상태·만료만 반영했습니다.');
    exitCode = 1;
    return;
  }

  stdout.writeln('Traffic source snapshots and v2 feed saved');
}
