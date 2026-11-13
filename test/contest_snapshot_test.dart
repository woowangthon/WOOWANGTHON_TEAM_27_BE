import 'dart:convert';
import 'dart:io';
import 'package:liferadar_pipeline/src/sources/sotong_contest.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.parse('2026-11-12T03:32:09Z');
  Map<String, dynamic> parseBody(String body) => SotongContest.detail({
    'sourceId': 'real-pattern', 'title': '아이디어 발굴대회', 'organizer': '주최기관',
    'sourceUrl': 'https://example.test/contest', 'rawPeriod': '2026-10-01 ~ 2026-12-31',
  }, '<div class="editor-content">$body</div>', now);

  test('actual body contest period needs explicit submission evidence', () {
    const body = '<p>공모기간: 2026.11.5.(목) ~ 12.4.(금) *18:00시까지</p>'
        '<p>참가대상: 전 국민 누구나(개인에 한해 참여 가능)</p>';
    expect(parseBody(body)['applicationEnd'], isNull);
    final d = parseBody('$body<p>제출방법: 작품 및 구비서류 이메일 제출</p>');
    expect(d['applicationEnd'], '2026-12-04T09:00:00.000Z');
    expect(d['publishability'], 'ready');
    expect(d['dateRule'], 'body-contest-period-with-submission-guidance');
    expect(d['eligibilityText'], '전 국민 누구나(개인에 한해 참여 가능)');
  });
  test('explicit receipt wins over announcement/contest period and retains time evidence', () {
    final d = parseBody('<p>공모기간: 2026.9.7 ~ 2027.1.15</p>'
        '<p>공모자격: 만 19세 이상 국민 누구나</p>'
        '<p>접수기간: 2026.10.13 ~ 11.20 (39일간) ※ 마감일 기준 23:59분 도달분까지 인정</p>');
    expect(d['applicationStart'], '2026-10-13T00:00:00.000');
    expect(d['applicationEnd'], '2026-11-20T14:59:00.000Z');
    expect(d['deadlinePrecision'], 'datetime');
    expect(d['eligibilityText'], '만 19세 이상 국민 누구나');
  });
  test('numeric pagination links work when hidden last link has no href', () {
    final raw = File('test/fixtures/sotong/list-1.html').readAsStringSync()
        .replaceAll('<a class="url-paging btn-paging-last" href="?miv_pageNo=1">마지막</a>', '');
    final d = SotongContest.list('$raw<a href="?miv_pageNo=4">4</a><a class="btn-paging-last" hidden></a>', 1);
    expect(d.lastPage, 4);
  });
  test('review snapshot has 17 unique active entries with evidence and no guessed fees', () {
    final j = jsonDecode(File('ops/contest-normalized-20261112.json').readAsStringSync()) as Map;
    final records = (j['normalized'] as List).cast<Map>();
    expect(records, hasLength(17));
    expect(records.map((r) => r['sourceId']).toSet(), hasLength(17));
    for (final r in records) {
      expect(r['publishability'], 'ready', reason: '${r['sourceId']}');
      expect(r['eligibilityText'], isNotEmpty);
      expect(r['dateEvidence'], isNotEmpty);
      expect(r['isFree'], isNull);
      expect(SotongContest.event(r.cast<String, dynamic>(), now), isNotNull);
    }
    expect(records.singleWhere((r) => r['sourceId'] == 'f2754a2aa7aa4ad0863cc1cf7ae424f1')['applicationStatus'], 'upcoming');
    expect(records.singleWhere((r) => r['sourceId'] == 'da99e9a3053a4baa9203d03972465487')['applicationStart'], '2026-10-01T00:00:00.000');
    expect(records.singleWhere((r) => r['sourceId'] == 'kaeri-13142')['deadlinePrecision'], 'date');
    expect(records.singleWhere((r) => r['sourceId'] == '389795afacac4ec296a03cc53bba9a02')['eligibilityText'], contains('개인당 시상 1건'));
  });
}
