import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liferadar_pipeline/src/sources/sotong_contest.dart';
import 'package:liferadar_pipeline/src/contests/collector.dart';
import 'package:liferadar_pipeline/src/contests/store.dart';
import 'package:liferadar_pipeline/src/contests/feed.dart';
import 'package:test/test.dart';

const first = '75a49f54e62349c681559e0624e8a533';
const garden = 'f2754a2aa7aa4ad0863cc1cf7ae424f1';
const empty = '16fb8760be314506a45bde167c52c146';
const media = 'bc239c48e8be4a58b4b397526cc41d73';
const recruitment = '6db01801bf20496e88db64e91f7122a6';
class HangingSotongClient extends http.BaseClient {
  final aborted=Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final stream=StreamController<List<int>>();
    (request as http.Abortable).abortTrigger!.then((_) async {
      aborted.complete();
      await stream.close();
    });
    return http.StreamedResponse(stream.stream,200);
  }
}
final now = DateTime.parse('2026-11-12T00:00:00Z');
String fixture(String file) => File('test/fixtures/sotong/$file.html').readAsStringSync();
Map<String, dynamic> row(String id) =>
    SotongContest.list(fixture('list-1'), 1).rows.singleWhere((r) => r['sourceId'] == id);
Map<String, dynamic> detail(String id, {String? body, Map<String, dynamic>? override}) =>
    SotongContest.detail({...row(id), ...?override}, body ?? fixture(id), now);
SotongSession session({
  String? list,
  Set<String> fail = const {},
  String Function(String, String)? change,
  List<http.Request>? requests,
  List<Duration>? delays,
}) => SotongSession(
  MockClient((r) async {
    requests?.add(r);
    if (r.url.path.endsWith('ListPage.do')) {
      return http.Response(
        fixture('initial'),
        200,
        headers: {
          'set-cookie': 'JSESSIONID=fixture-session; Path=/; HttpOnly',
          'content-type': 'text/html; charset=utf-8',
        },
      );
    }
    if (r.url.path.endsWith('List.do')) {
      return http.Response(list ?? fixture('list-1'), 200, headers: {'content-type': 'text/html; charset=utf-8'});
    }
    final id = r.url.queryParameters['bbs_id']!;
    return http.Response(
      fail.contains(id) ? 'temporary error' : change?.call(id, fixture(id)) ?? fixture(id),
      fail.contains(id) ? 500 : 200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }),
  interval: Duration.zero,
  sleep: (d) async {
    delays?.add(d);
  },
);

void main() {
  test('timeout aborts an unfinished HTTP response before further retries',()async{
    final client=HangingSotongClient();
    final session=SotongSession(client,timeout:const Duration(milliseconds:10),retries:0,interval:Duration.zero,sleep:(d)async{});
    await expectLater(session.initialize(),throwsA(isA<TimeoutException>()));
    await client.aborted.future.timeout(const Duration(seconds:1));
  });
  test('real DOM: explicit datetime, general public, no invented fee', () {
    final d = detail(first);
    expect(d['applicationStart'], '2026-11-11T23:00:00.000Z');
    expect(d['applicationEnd'], '2026-11-16T08:00:00.000Z');
    expect(d['deadlinePrecision'], 'datetime');
    expect(d['applicationStatus'], 'open');
    expect(d['audience'], 'general');
    expect(d['isFree'], isNull);
    expect(d['applyUrl'], 'https://m.site.naver.com/2kHcR');
    expect(d['publishability'], 'ready'); // normal warning about awards != cancellation
  });
  test('list period differs from actual application: no substitution', () {
    final d = detail(garden);
    expect(d['rawPeriod'], '2026-11-10 ~ 2026-12-09');
    expect(d['applicationStart'], '2026-12-07T00:00:00.000');
    expect(d['applicationEnd'], '2026-12-09T07:00:00.000Z');
    expect(d['applicationStatus'], 'upcoming');
    expect(d['audience'], 'restricted');
    expect(d['eligibilityText'], contains('상주 가능한 자'));
    expect(d['applyUrl'], isNull);
  });
  test('empty real body remains review, never list-date or free fallback', () {
    final d = detail(empty);
    expect(d['applicationStart'], isNull);
    expect(d['applicationEnd'], isNull);
    expect(d['publishability'], 'review');
    expect(SotongContest.event(d, now), isNull);
  });
  test('date precision and unspecified geography remain unknown', () {
    final d = detail(media);
    expect(d['deadlinePrecision'], 'date');
    expect(d['audience'], 'general');
    expect(d['city'], '미확인');
    expect(d['isFree'], isNull);
    final e = SotongContest.event(d, now)!;
    expect(e.deadlineBoundary, DateTime.parse('2026-11-23T15:00:00Z'));
    expect(e.applicationVisible(DateTime.parse('2026-11-23T14:59:59Z')), isTrue);
    expect(e.applicationVisible(DateTime.parse('2026-11-23T15:00:00Z')), isFalse);
  });
  test('recruitment, jobs and result-only titles are excluded', () {
    expect(detail(recruitment)['publishability'], 'excluded');
    for (final title in ['공모전 결과 발표', '공모전 수상작 공개', '공모전 운영 채용']) {
      expect(detail(first, override: {'title': title})['publishability'], 'excluded');
    }
  });
  test('university and restricted qualifications preserve original text', () {
    final raw = fixture(first);
    final university = detail(first, body: raw.replaceAll('만 14세 이상 국민 누구나(우체국물류지원단 임직원 포함)', '전국 대학생 및 휴학생 (팀 2~4명)'));
    expect(university['audience'], 'university');
    expect(university['eligibilityText'], contains('팀 2~4명'));
    expect(
      detail(first, body: raw.replaceAll('만 14세 이상 국민 누구나(우체국물류지원단 임직원 포함)', '고등학생만 참여 가능'))['audience'],
      'restricted',
    );
  });
  test('invalid, yearless, backwards and ambiguous dates are not guessed', () {
    for (final s in ['11. 1. ~ 11. 10.', '2026. 2. 30. ~ 3. 1.', '2026.12.31 ~ 1.1', '2026.11.1 ~ 11.2 ~ 11.3']) {
      expect(SotongContest.dateRange(s), isNull, reason: s);
    }
  });
  test('applied link must be explicit http(s), login/js rejected', () {
    for (final bad in ['javascript:alert(1)', 'https://example.com/login', 'mailto:a@example.com']) {
      expect(detail(first, body: fixture(first).replaceAll('https://m.site.naver.com/2kHcR', bad))['applyUrl'], isNull);
    }
  });
  test('fees must be explicit and 1000 won is not free', () {
    final raw = fixture(first).replaceFirst('</div>', '<p>참가비: 1000원</p></div>');
    expect(detail(first, body: raw)['isFree'], isFalse);
    expect(detail(first, body: raw.replaceAll('1000원', '무료'))['isFree'], isTrue);
  });
  test('normal collection includes session cookie, CSRF and source validation', () async {
    final requests = <http.Request>[];
    final c = await ContestCollector(session(requests: requests)).collect(ContestState(), now: now);
    expect(c.metadata['status'], 'success');
    expect(c.state.records.length, 6);
    expect(c.state.events(now).length, 4);
    final post = requests.firstWhere((r) => r.method == 'POST');
    expect(post.headers['cookie'], contains('JSESSIONID=fixture-session'));
    expect(post.headers['X-CSRF-TOKEN'], 'fixture-token');
    expect(Uri.splitQueryString(post.body)['miv_pageSize'], '9');
    expect(Uri.splitQueryString(post.body)['_csrf'], 'fixture-token');
    validateContestFeed({
      'sources': [c.metadata],
      'events': c.state.events(now).map((e) => e.toJson()).toList(),
    });
    expect(c.metadata['license'], isNull);
  });
  test('idempotent re-run, extension and body-only updates', () async {
    final a = await ContestCollector(session()).collect(ContestState(), now: now);
    final b = await ContestCollector(
      session(change: (id, s) => id == first ? s.replaceAll('11. 16.(월) 17:00', '11. 30.(월) 17:00') : s),
    ).collect(a.state, now: now.add(const Duration(hours: 1)));
    expect(b.state.records.length, 6);
    expect(b.state.records[first]!['firstSeenAt'], a.state.records[first]!['firstSeenAt']);
    expect(b.state.records[first]!['applicationEnd'], '2026-11-30T08:00:00.000Z');
    expect(b.state.records[first]!['contentHash'], isNot(a.state.records[first]!['contentHash']));
    expect(b.state.events(now).map((e) => e.id).toSet().length, 4);
  });
  test('explicit cancellation removes event while retaining record', () async {
    final a = await ContestCollector(session()).collect(ContestState(), now: now);
    final b = await ContestCollector(
      session(change: (id, s) => id == first ? s.replaceFirst('</div>', '<p>공모전 취소 안내</p></div>') : s),
    ).collect(a.state, now: now);
    expect(b.state.records[first]!['applicationStatus'], 'cancelled');
    expect(b.state.events(now).any((e) => e.id.endsWith(first)), isFalse);
  });
  test('partial detail failure preserves last verified old data and retries bounded', () async {
    final a = await ContestCollector(session()).collect(ContestState(), now: now);
    final delays = <Duration>[];
    final b = await ContestCollector(
      session(fail: {first}, delays: delays),
    ).collect(a.state, now: now.add(const Duration(hours: 1)));
    expect(b.metadata['status'], 'partial');
    expect(b.state.records[first]!['lastVerifiedAt'], a.state.records[first]!['lastVerifiedAt']);
    expect(b.state.events(now).length, 4);
    expect(b.state.lastSuccessAt, a.state.lastSuccessAt);
    expect(delays.where((d) => d > Duration.zero).length, 2);
  });
  test('new failed detail is never published', () async {
    final c = await ContestCollector(session(fail: {first})).collect(ContestState(), now: now);
    expect(c.metadata['status'], 'partial');
    expect(c.state.records.containsKey(first), isFalse);
  });
  test('repeated page rolls back, page limit partial retains previous records', () async {
    final a = await ContestCollector(session()).collect(ContestState(), now: now);
    final list = fixture('list-1').replaceAll('miv_pageNo=1', 'miv_pageNo=2');
    final repeat = await ContestCollector(session(list: list), maxPages: 2).collect(a.state, now: now);
    expect(repeat.metadata['status'], 'failed');
    expect(repeat.state.toJson(), a.state.toJson());
    final capped = await ContestCollector(session(list: list), maxPages: 1).collect(a.state, now: now);
    expect(capped.metadata['status'], 'partial');
    expect(capped.state.records.length, 6);
  });
  test('HTML changes and list failure preserve complete normal state', () async {
    final a = await ContestCollector(session()).collect(ContestState(), now: now);
    final changed = await ContestCollector(session(list: '<html>changed</html>')).collect(a.state, now: now);
    expect(changed.metadata['status'], 'failed');
    expect(changed.state.toJson(), a.state.toJson());
    final detailChanged = await ContestCollector(
      session(change: (id, s) => id == first ? '<html>changed</html>' : s),
    ).collect(a.state, now: now);
    expect(detailChanged.metadata['status'], 'partial');
    expect(detailChanged.state.records[first], a.state.records[first]);
  });
  test('403 stops without retry; 429 respects Retry-After', () async {
    var calls = 0;
    final delays = <Duration>[];
    final blocked = SotongSession(
      MockClient((r) async {
        calls++;
        return http.Response('denied', 403);
      }),
      interval: Duration.zero,
      sleep: (d) async {},
    );
    await expectLater(blocked.initialize(), throwsA(isA<SotongBlocked>()));
    expect(calls, 1);
    calls = 0;
    final retry = SotongSession(
      MockClient((r) async {
        calls++;
        return http.Response(
          calls == 1 ? 'wait' : fixture('initial'),
          calls == 1 ? 429 : 200,
          headers: {'retry-after': '3', 'content-type': 'text/html; charset=utf-8'},
        );
      }),
      interval: Duration.zero,
      sleep: (d) async {
        delays.add(d);
      },
    );
    await retry.initialize();
    expect(calls, 2);
    expect(delays, contains(const Duration(seconds: 3)));
  });
  test('ledger round trip and failure preservation beyond expiry', () async {
    final a = await ContestCollector(session()).collect(ContestState(), now: now);
    final restored = ContestState.fromJson((jsonDecode(jsonEncode(a.state.toJson())) as Map).cast<String, dynamic>());
    expect(restored.toJson(), a.state.toJson());
    expect(restored.events(now.add(const Duration(days: 60))), isEmpty);
    expect(() => ContestState.fromJson({'records': {}}), throwsFormatException);
  });
  test('feed merge preserves other sources, upserts contest IDs and reports duplicates', () async {
    final c = await ContestCollector(session()).collect(ContestState(), now: now);
    final event = c.state.events(now).first;
    final other = {...event.toJson(), 'id': 'another-source-1', 'source': 'other'};
    final base = <String, dynamic>{
      'sources': [
        {'id': 'other', 'name': 'Other', 'count': 1},
      ],
      'events': [other, event.toJson()],
    };
    final feed = mergeContestFeed(base, c.state, c.metadata, now);
    expect((feed['events'] as List).length, 5);
    final meta = (feed['sources'] as List).last as Map;
    expect((meta['duplicateCandidates'] as List), hasLength(1));
    final twice = mergeContestFeed(feed, c.state, c.metadata, now);
    expect(twice, feed);
    final expired = mergeContestFeed(feed, c.state, {
      ...c.metadata,
      'status': 'failed',
      'preservedPrevious': true,
    }, now.add(const Duration(days: 60)));
    expect((expired['events'] as List).single['source'], 'other');
    expect((expired['sources'] as List).last['count'], 0);
  });
  test('source outcome cannot be hidden by unrelated total event count', () async {
    final c = await ContestCollector(session()).collect(ContestState(), now: now);
    final feed = mergeContestFeed({}, c.state, c.metadata, now);
    (feed['sources'] as List).single['status'] = 'missing';
    expect(() => validateContestFeed(feed), throwsFormatException);
  });
}
