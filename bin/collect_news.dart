// 뉴스에서 대중교통 파업 정보를 판독해 게시한다 (네이버 뉴스 검색 → Gemini 판독 → 근거 검증).
//
//   dart run bin/collect_news.dart [--out=out/news.json] [--days=14]
//
// 기사마다 한 번만 판독한다: 결과(관련 없음·거부 포함)를 cache/news_ai.json에 저장해 다음 실행에서는
// 새 기사만 Gemini에 보낸다. 판독·검증 규칙은 liferadar_core의 StrikeExtractor.
// 키: NAVER_API_KEY_ID, NAVER_API_KEY (NAVER API HUB), GEMINI_API_KEY.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

const _queries = ['버스 파업', '지하철 파업', '철도 파업', '파업 예고 운행', '집회 교통 통제', '마라톤 도로 통제', '축제 버스 우회'];
const _cachePath = 'cache/news_ai.json';
const _batch = 15;

Future<void> main(List<String> args) async {
  String arg(String name, String fallback) =>
      args.firstWhere((a) => a.startsWith('--$name='), orElse: () => '--$name=$fallback').split('=').last;
  final out = arg('out', 'out/news.json');
  final days = int.tryParse(arg('days', '14')) ?? 14;
  final env = loadKeys();
  final naverId = (env['NAVER_API_KEY_ID'] as String?)?.trim() ?? '';
  final naverKey = (env['NAVER_API_KEY'] as String?)?.trim() ?? '';
  final geminiKey = (env['GEMINI_API_KEY'] as String?)?.trim() ?? '';
  if (naverId.isEmpty || naverKey.isEmpty) {
    stderr.writeln('NAVER_API_KEY_ID / NAVER_API_KEY 없음 — 수집하지 않음');
    exit(1);
  }

  final now = DateTime.now();
  final since = now.subtract(Duration(days: days));
  final client = http.Client();

  // 1) 검색
  final articles = <String, NewsArticle>{};
  final discoveredBy = <String, String>{};
  for (final q in _queries) {
    final res = await client.get(
      Uri.parse('https://naverapihub.apigw.ntruss.com/search/v1/news').replace(
        queryParameters: {'query': q, 'display': '50', 'start': '1', 'sort': 'date', 'format': 'json'},
      ),
      headers: {'X-NCP-APIGW-API-KEY-ID': naverId, 'X-NCP-APIGW-API-KEY': naverKey},
    ).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      stderr.writeln('✗ 네이버 "$q": HTTP ${res.statusCode}');
      continue;
    }
    final items = (jsonDecode(utf8.decode(res.bodyBytes))['items'] as List).cast<Map<String, dynamic>>();
    for (final item in items) {
      final a = NewsArticle.fromSearchItem(item);
      if (a.publishedAt.isAfter(since)) {
        articles[a.id] = a;
        discoveredBy.putIfAbsent(a.id, () => q);
      }
    }
    stdout.writeln('✓ 네이버 "$q": ${items.length}건');
  }

  // 2) 판독 (새 기사만)
  final cache = _loadCache();
  final todo = [for (final a in articles.values) if (!cache.containsKey(a.id)) a];
  stdout.writeln('  기사 ${articles.length}건 (최근 $days일) · 캐시 ${articles.length - todo.length}건 · 신규 ${todo.length}건');
  if (todo.isNotEmpty && geminiKey.isEmpty) stderr.writeln('! GEMINI_API_KEY 없음 — 신규 기사 판독 생략');
  if (geminiKey.isNotEmpty) {
    final gemini = GeminiClient(apiKey: geminiKey, client: client, timeout: const Duration(seconds: 90));
    for (var i = 0; i < todo.length; i += _batch) {
      final chunk = todo.skip(i).take(_batch).toList();
      try {
        final (json, model) = await gemini.generate(StrikeExtractor.requestBody(chunk));
        final rejected = <String, String>{};
        final kept = StrikeExtractor.parseResponse(
          json,
          articlesById: {for (final a in chunk) a.id: a},
          model: model,
          rejected: rejected,
        );
        final at = now.toUtc().toIso8601String();
        for (final s in kept) {
          cache[s.id] = {'at': at, 'strike': s.toJson()};
        }
        rejected.forEach((id, why) => cache[id] = {'at': at, 'rejected': why});
        // 응답에서 빠진 기사는 캐시하지 않는다 → 다음 실행에서 다시 판독
        stdout.writeln('  gemini ${i + chunk.length}/${todo.length}: 통과 ${kept.length}, 제외 ${rejected.length}');
      } catch (e) {
        stderr.writeln('  ! gemini: $e (다음 실행에서 다시 시도)');
      }
    }
  }

  // 3) 사건으로 묶어 게시
  final strikes = [
    for (final a in articles.values)
      if (cache[a.id]?['strike'] case final Map<String, dynamic> j) TransitStrike.fromJson(j),
  ];
  final merged = StrikeExtractor.merge(strikes);
  _saveCache(cache, keep: now.subtract(const Duration(days: 30)));
  final file = File(out)..createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent(' ').convert({
    'generatedAt': now.toUtc().toIso8601String(),
    'windowDays': days,
    'queries': _queries,
    'sources': [
      {'id': 'naver-news', 'name': '네이버 뉴스 검색 (NAVER API HUB)', 'url': 'https://www.ncloud.com/product/applicationService/naverApiHub'},
    ],
    'articles': articles.length,
    // Discovery only: publish.py must fetch/validate full bodies before producing
    // trafficImpacts. Snippets never become verified impact records.
    'searchResults': [for (final a in articles.values) {'url': a.url, 'title': a.title, 'query': discoveredBy[a.id]}],
    'strikes': [for (final s in merged) s.toJson()],
  }));
  client.close();
  stdout.writeln('→ $out: 파업 사건 ${merged.length}건 (활성 ${merged.where((s) => s.isActive).length}건)');
  for (final s in merged) {
    stdout.writeln('  ${s.status.name.padRight(10)} ${s.mode.name.padRight(6)} ${s.operator} ${s.regions} '
        '${s.start == null ? '-' : s.start!.toIso8601String().substring(0, 10)} (기사 ${s.sourceCount}건)');
  }
}

Map<String, Map<String, dynamic>> _loadCache() {
  final f = File(_cachePath);
  if (!f.existsSync()) return {};
  try {
    return (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as Map<String, dynamic>));
  } catch (_) {
    return {};
  }
}

/// 30일이 지난 판독 결과는 지운다 (캐시가 끝없이 커지지 않게).
void _saveCache(Map<String, Map<String, dynamic>> cache, {required DateTime keep}) {
  final kept = {
    for (final e in cache.entries)
      if ((DateTime.tryParse('${e.value['at']}') ?? keep).isAfter(keep.toUtc()) || e.value['at'] == null) e.key: e.value,
  };
  File(_cachePath)
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(kept));
}
