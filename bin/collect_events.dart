// 공개 API에서 실제 행사를 수집해 앱이 읽는 JSON으로 저장한다.
//
//   dart run bin/collect_events.dart [--days=90] [--out=out/events.json]
//
// 결과: out/events.json — GitHub Actions가 `data` 브랜치에 게시하고 앱이 내려받는다.
// 키는 이 스크립트에서만 사용하며 앱 번들에 들어가지 않는다.
//
// 출처 (키는 환경 변수 또는 env.json):
//   SEOUL_OPEN_API_KEY — 서울 열린데이터광장, 문화행사 (없으면 'sample' → 5행만)
//   DATA_GO_KR_KEY     — 공공데이터포털 (Decoding 키): TourAPI 축제 (전국) + K-Startup 사업공고
//   GEMINI_API_KEY     — 영어 이름/설명 + 더 정확한 태그 (캐시: cache/ai_en.json; --no-ai = 건너뛰기)
//
// 공식 공개 API만 사용한다. 이용 약관에서 스크래핑을 금지한 사이트(예: Dev-Event)는
// 사용하지 않는다.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

String _out = 'out/events.json';
const _userAgent = 'LifeRadar-collector/0.1 (hackathon MVP)';

Future<void> main(List<String> args) async {
  final days = int.tryParse(
        args.firstWhere((a) => a.startsWith('--days='), orElse: () => '--days=90').split('=').last,
      ) ??
      90;
  final env = loadKeys();
  _out = args.firstWhere((a) => a.startsWith('--out='), orElse: () => '--out=$_out').substring(6);

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final until = today.add(Duration(days: days));
  bool inWindow(RadarEvent e) => !e.end.isBefore(today) && e.start.isBefore(until);

  final client = http.Client();
  final events = <String, RadarEvent>{};
  final sources = <Map<String, dynamic>>[];

  // ── 서울시 문화행사 ──
  final seoulKey = (env['SEOUL_OPEN_API_KEY'] as String?)?.trim();
  final key = seoulKey == null || seoulKey.isEmpty ? 'sample' : seoulKey;
  if (key == 'sample') stderr.writeln('! SEOUL_OPEN_API_KEY 없음 — sample 키(5행)를 사용한다');
  try {
    final found = await _collectSeoul(client, key, today, inWindow);
    for (final e in found) {
      events[e.id] = e;
    }
    sources.add({
      'id': SeoulCulture.source,
      'name': SeoulCulture.sourceName,
      'url': 'https://data.seoul.go.kr/dataList/OA-15486/S/1/datasetView.do',
      'license': '공공누리',
      'count': found.length,
    });
    stdout.writeln('✓ ${SeoulCulture.sourceName}: ${found.length}건');
  } catch (e) {
    stderr.writeln('✗ ${SeoulCulture.sourceName}: $e');
  }
  // ── TourAPI 축제 (butun Koreya) ──
  final dataKey = (env['DATA_GO_KR_KEY'] as String?)?.trim() ?? '';
  if (dataKey.isEmpty) {
    stderr.writeln('! DATA_GO_KR_KEY 없음 — TourAPI를 건너뛴다');
  } else {
    try {
      final found = await _collectTour(client, dataKey, today, inWindow);
      for (final e in found) {
        events[e.id] = e;
      }
      sources.add({
        'id': TourFestival.source,
        'name': TourFestival.sourceName,
        'url': 'https://www.data.go.kr/data/15101578/openapi.do',
        'license': '공공누리',
        'count': found.length,
      });
      stdout.writeln('✓ ${TourFestival.sourceName}: ${found.length}건');
    } catch (e) {
      stderr.writeln('✗ ${TourFestival.sourceName}: $e');
    }
  }

  // ── K-Startup 사업공고 (접수 중인 공고) ──
  if (dataKey.isNotEmpty) {
    try {
      final found = await _collectKStartup(client, dataKey, today, until);
      for (final e in found) {
        events[e.id] = e;
      }
      sources.add({
        'id': KStartup.source,
        'name': KStartup.sourceName,
        'url': 'https://www.data.go.kr/data/15125364/openapi.do',
        'license': '공공누리',
        'count': found.length,
      });
      stdout.writeln('✓ ${KStartup.sourceName}: ${found.length}건');
    } catch (e) {
      stderr.writeln('✗ ${KStartup.sourceName}: $e');
    }
  }

  if (events.isEmpty) {
    client.close();
    stderr.writeln('행사를 하나도 찾지 못했다 — $_out을 변경하지 않는다.');
    exitCode = 1;
    return;
  }

  // ── Gemini: 영어 문장 + 태그 ──
  var list = events.values.toList()..sort((a, b) => a.start.compareTo(b.start));
  final geminiKey = (env['GEMINI_API_KEY'] as String?)?.trim() ?? '';
  if (args.contains('--no-ai') || geminiKey.isEmpty) {
    stderr.writeln('! Gemini 건너뜀 (${geminiKey.isEmpty ? 'GEMINI_API_KEY 없음' : '--no-ai'}) — 캐시가 있으면 사용한다');
    list = _applyCache(list, _loadCache());
  } else {
    list = await _enrich(client, geminiKey, list);
  }
  client.close();

  final file = File(_out)..createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
    'generatedAt': DateTime.now().toUtc().toIso8601String(), // Z 포함 — CI(UTC)와 휴대폰이 같은 시각으로 해석한다
    'windowDays': days,
    'sources': sources,
    'enrichedWith': geminiKey.isEmpty || args.contains('--no-ai') ? null : _models.first,
    'events': [for (final e in list) e.toJson()],
  }));
  stdout.writeln('→ $_out: ${list.length}건 (${(file.lengthSync() / 1024).round()} KB)');
}

/// 목록은 등록일이 아니라 시작일 기준 내림차순이다.
/// 그래서 마지막 페이지가 충분히 오래될 때까지 페이지를 읽는다
/// (오래 하는 전시는 훨씬 전에 시작했을 수 있다).
Future<List<RadarEvent>> _collectSeoul(
  http.Client client,
  String key,
  DateTime today,
  bool Function(RadarEvent) inWindow,
) async {
  const pageSize = 1000;
  final maxRows = key == 'sample' ? 5 : 8000;
  final stopBefore = today.subtract(const Duration(days: 365));
  final out = <RadarEvent>[];
  var skipped = 0;

  for (var from = 1; from <= maxRows; from += pageSize) {
    final to = key == 'sample' ? 5 : from + pageSize - 1;
    final res = await client.get(SeoulCulture.pageUri(key, from, to), headers: {'User-Agent': _userAgent});
    if (res.statusCode != 200) throw SourceException('HTTP ${res.statusCode}');
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final rows = SeoulCulture.rows(json);
    if (rows.isEmpty) break;

    DateTime? newestInPage;
    for (final r in rows) {
      final e = SeoulCulture.parse(r);
      if (e == null) {
        skipped++;
        continue;
      }
      if (newestInPage == null || e.start.isAfter(newestInPage)) newestInPage = e.start;
      if (inWindow(e)) out.add(e);
    }
    stdout.writeln('  seoul $from–$to: ${rows.length}행, 해당: ${out.length}');
    if (to >= SeoulCulture.totalCount(json)) break;
    if (newestInPage != null && newestInPage.isBefore(stopBefore)) break;
    await Future<void>.delayed(const Duration(milliseconds: 400)); // 서버에 부담을 주지 않게
  }
  if (skipped > 0) stdout.writeln('  (좌표/날짜 없음: $skipped행 건너뜀)');
  return out;
}

/// 축제 목록 → 각 축제의 설명(detailCommon2)과 시간/요금(detailIntro2).
/// 일일 한도 1000회: 축제 ~110개 × 상세 2회 ≈ 230회.
Future<List<RadarEvent>> _collectTour(
  http.Client client,
  String key,
  DateTime today,
  bool Function(RadarEvent) inWindow,
) async {
  Future<Map<String, dynamic>> getJson(Uri uri) async {
    final res = await client.get(uri, headers: {'User-Agent': _userAgent});
    if (res.statusCode != 200) throw SourceException('HTTP ${res.statusCode}');
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  // 이미 시작해서 아직 진행 중인 축제도 포함한다.
  final from = today.subtract(const Duration(days: 60));
  final list = <Map<String, dynamic>>[];
  for (var page = 1; page <= 10; page++) {
    final json = await getJson(TourFestival.listUri(key, from, page: page));
    final items = TourFestival.items(json);
    list.addAll(items);
    if (items.isEmpty || list.length >= TourFestival.totalCount(json)) break;
  }

  // 먼저 상세 없이 파싱해서 기간 밖의 축제에는 요청하지 않는다.
  final candidates = [
    for (final item in list)
      if (TourFestival.parse(item) case final e? when inWindow(e)) item,
  ];
  stdout.writeln('  tour: 축제 ${list.length}건, 기간 내: ${candidates.length} → 상세 조회…');

  final out = <RadarEvent>[];
  var failed = 0;
  const parallel = 4;
  for (var i = 0; i < candidates.length; i += parallel) {
    final batch = candidates.skip(i).take(parallel);
    final parsed = await Future.wait(batch.map((item) async {
      final id = '${item['contentid']}';
      try {
        final (common, intro) = await (
          getJson(TourFestival.commonUri(key, id)),
          getJson(TourFestival.introUri(key, id)),
        ).wait;
        return TourFestival.parse(
          item,
          common: TourFestival.items(common).firstOrNull,
          intro: TourFestival.items(intro).firstOrNull,
        );
      } catch (_) {
        failed++;
        return TourFestival.parse(item); // 상세가 없어도 목록에는 남긴다
      }
    }));
    out.addAll(parsed.whereType<RadarEvent>().where(inWindow));
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (failed > 0) stdout.writeln('  (tafsiloti olinmagan: $failed ta)');
  return out;
}

/// 오늘부터 [until]까지 마감되는, 접수 중인 공고.
Future<List<RadarEvent>> _collectKStartup(http.Client client, String key, DateTime today, DateTime until) async {
  final out = <RadarEvent>[];
  for (var page = 1; page <= 5; page++) {
    final res = await client.get(KStartup.listUri(key, page: page), headers: {'User-Agent': _userAgent});
    if (res.statusCode != 200) throw SourceException('HTTP ${res.statusCode}');
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final rows = KStartup.rows(json);
    for (final r in rows) {
      final e = KStartup.parse(r);
      if (e != null && !e.deadline!.isBefore(today) && e.deadline!.isBefore(until)) out.add(e);
    }
    if (rows.isEmpty || page * 500 >= KStartup.matchCount(json)) break;
  }
  return out;
}

// ─────────────────────────── Gemini 보강 ───────────────────────────

const _cachePath = 'cache/ai_en.json';

/// 기본 모델 + 바쁠 때 예비 모델 (둘 다 빠르고 저렴한 "lite").
const _models = ['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite'];

Map<String, Enrichment> _loadCache() {
  final f = File(_cachePath);
  if (!f.existsSync()) return {};
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in j.entries)
      if (Enrichment.fromJson((e.value as Map).cast<String, dynamic>()) case final r
          when AiEnrich.isCleanEnglish(r.titleEn, maxHangul: 0) &&
              AiEnrich.isCleanEnglish(r.descriptionEn, maxHangul: 0.15))
        e.key: r, // 이전 버전의 품질 낮은 항목은 다시 요청한다
  };
}

void _saveCache(Map<String, Enrichment> cache) {
  final keys = cache.keys.toList()..sort();
  File(_cachePath)
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert({for (final k in keys) k: cache[k]!.toJson()}));
}

List<RadarEvent> _applyCache(List<RadarEvent> list, Map<String, Enrichment> cache) => [
      for (final e in list)
        if (cache[AiEnrich.cacheKey(e)] case final r?) AiEnrich.apply(e, r) else e,
    ];

Future<List<RadarEvent>> _enrich(http.Client client, String key, List<RadarEvent> list) async {
  final cache = _loadCache();
  final todo = list.where((e) => !cache.containsKey(AiEnrich.cacheKey(e))).toList();
  stdout.writeln('  gemini: 캐시 ${list.length - todo.length}개, 신규 ${todo.length}개');

  // 1단계: 기본 모델, 20개씩. 2단계: 거부되었거나 남은 것 — 다른 모델, 작은 묶음.
  for (final (pass, models, batchSize) in [(1, _models, 20), (2, _models.reversed.toList(), 5)]) {
    final pending = todo.where((e) => !cache.containsKey(AiEnrich.cacheKey(e))).toList();
    if (pending.isEmpty) break;
    if (pass == 2) stdout.writeln('  gemini 2단계: ${pending.length}건 재요청 (${models.first})');
    var failedBatches = 0;
    for (var i = 0; i < pending.length; i += batchSize) {
      final batch = pending.skip(i).take(batchSize).toList();
      final result = await _callGemini(client, key, batch, models);
      if (result == null) {
        failedBatches++;
        continue;
      }
      for (final e in batch) {
        final r = result[e.id];
        if (r != null) cache[AiEnrich.cacheKey(e)] = r;
      }
      _saveCache(cache); // 중간에 멈춰도 한 작업이 사라지지 않게
      if (pass == 1) stdout.writeln('  gemini ${i + batch.length}/${pending.length}');
      await Future<void>.delayed(const Duration(seconds: 2)); // 무료 요금제 RPM 한도
    }
    if (failedBatches > 0) stderr.writeln('  ! gemini: 묶음 $failedBatches개 실패 (다음 실행에서 다시 시도)');
  }

  // 현재 행사의 항목만 남긴다 (캐시가 끝없이 커지지 않게).
  final live = {for (final e in list) AiEnrich.cacheKey(e)};
  cache.removeWhere((k, _) => !live.contains(k));
  _saveCache(cache);
  final out = _applyCache(list, cache);
  stdout.writeln('✓ Gemini: ${out.where((e) => e.title.en != e.title.ko).length}/${out.length}건 영어');
  return out;
}

/// 429/503이면 기다렸다가 다시 시도하고, 이후 예비 모델로 넘어간다. 실패하면 null.
Future<Map<String, Enrichment>?> _callGemini(
  http.Client client,
  String key,
  List<RadarEvent> batch,
  List<String> models,
) async {
  final body = jsonEncode(AiEnrich.requestBody(batch));
  for (final model in models) {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await client
            .post(
              Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent')
                  .replace(queryParameters: {'key': key}),
              headers: {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(const Duration(seconds: 120));
        if (res.statusCode == 200) {
          return AiEnrich.parseResponse(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>, model: model);
        }
        if (res.statusCode == 429 || res.statusCode >= 500) {
          await Future<void>.delayed(Duration(seconds: 5 * (attempt + 1) * (attempt + 1)));
          continue;
        }
        stderr.writeln('  gemini $model HTTP ${res.statusCode}: ${utf8.decode(res.bodyBytes).split('\n').take(4).join(' ')}');
        break; // 4xx — 다른 모델을 시도한다
      } catch (e) {
        stderr.writeln('  gemini $model: $e');
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
  }
  return null;
}
