import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final clock = DateTime.utc(2026, 11, 11);
TrafficNotice n({String source = 'utic', String status = 'active'}) => TrafficNotice(
  id: '$source-1',
  sourceRecordId: '1',
  source: source,
  sourceName: source,
  kind: TrafficKind.event,
  title: 'synthetic',
  detail: '부분통제',
  start: clock,
  end: clock.add(const Duration(hours: 12)),
  location: const GeoPoint(37.57, 126.98),
  controlEvidence: 'confirmed',
  evidenceText: '부분통제',
  evidenceMethod: 'synthetic-v1',
  timePrecision: 'minute',
  lastSeenAt: clock,
  status: status,
);

class StreamingFakeClient extends http.BaseClient {
  StreamingFakeClient(this.body);
  final Stream<List<int>> body;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => http.StreamedResponse(body, 200);
}

void main() {
  test('source failure preserves snapshot and observation, partial empty retains, complete empty stops', () {
    final l = TrafficLedger()
      ..accept('utic', [n()], clock, complete: true)
      ..accept('its', [n(source: 'its')], clock, complete: true);
    l.failure('utic', clock.add(const Duration(minutes: 10)), 'timeout');
    expect(l.feed(clock.add(const Duration(minutes: 10)))['notices'], hasLength(2));
    l.accept('utic', [], clock.add(const Duration(minutes: 20)), complete: false);
    expect(l.snapshots['utic']!.single.lastSeenAt, clock);
    l.accept('utic', [], clock.add(const Duration(minutes: 30)), complete: true);
    expect((l.feed(clock.add(const Duration(minutes: 30)))['notices'] as List).length, 1);
  });
  test('late snapshot, withdrawal tombstone, TTL and repost do not revive evidence', () {
    final l = TrafficLedger()..accept('utic', [n()], clock, complete: true);
    l.accept('utic', [n(status: 'cancelled')], clock.add(const Duration(minutes: 1)), complete: true);
    l.accept('utic', [n()], clock, complete: true);
    expect(l.feed(clock.add(const Duration(minutes: 2)))['notices'], isEmpty);
    l.accept('utic', [n()], clock.add(const Duration(minutes: 3)), complete: true);
    expect(l.feed(clock.add(const Duration(minutes: 3)))['notices'], isEmpty);
    final copy = TrafficLedger.fromJson(jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>);
    expect(copy.tombstones, isNotEmpty);
    final fresh = TrafficLedger()..accept('utic', [n()], clock, complete: true);
    expect(fresh.feed(clock.add(const Duration(hours: 6)))['notices'], hasLength(1));
    expect(fresh.feed(clock.add(const Duration(hours: 6, seconds: 1)))['notices'], isEmpty);
  });
  test('durable round trip, atomic publication and concurrent OS writers', () async {
    final dir = Directory.systemTemp.createTempSync('traffic-store-');
    try {
      final store = TrafficStore(dir);
      await store.transaction((l) async {
        l.accept('utic', [n()], clock, complete: true);
      });
      await store.transaction((l) async {
        expect(l.snapshots['utic'], hasLength(1));
        await TrafficStore.atomicJson(File('${dir.path}/traffic-v2.json'), l.feed(clock));
      });
      validateTrafficV2(jsonDecode(File('${dir.path}/traffic-v2.json').readAsStringSync()) as Map<String, dynamic>);
      final writers = await Future.wait([
        for (final id in ['source-a', 'source-b'])
          Process.run(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            'test/traffic_writer_worker.dart',
            dir.path,
            id,
          ]),
      ]);
      for (final result in writers) {
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      await store.transaction((l) async {
        expect(l.states.keys, containsAll(['source-a', 'source-b', 'utic']));
      });
      expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
  test('v2 validation rejects missing observation, future clock, unsafe URL and coordinates', () {
    final l = TrafficLedger()..accept('utic', [n()], clock, complete: true);
    for (final meta in [
      {'lastSeenAt': null},
      {'lastSeenAt': clock.add(const Duration(days: 1)).toIso8601String()},
      {'sourceUrl': 'https://www.utic.go.kr/?key=synthetic'},
      {'lat': 0},
      {'fetchedAt': clock.add(const Duration(seconds: 1)).toIso8601String()},
      {'sourceUpdatedAt': clock.add(const Duration(seconds: 1)).toIso8601String()},
    ]) {
      final j = l.feed(clock);
      (j['notices'] as List)[0] = <String, dynamic>{...(j['notices'] as List)[0] as Map<String, dynamic>, ...meta};
      expect(() => validateTrafficV2(j), throwsFormatException);
    }
  });
  test('documented XML structure/CDATA only; errors never mean empty success', () {
    expect(
      UticXml.records(
        '<result><record><incidentId>x</incidentId><incidentTitle><![CDATA[가 & 나]]></incidentTitle></record></result>',
      ).single['incidentTitle'],
      '가 & 나',
    );
    expect(UticXml.records('<result/>'), isEmpty); // structure only, completeness NOT asserted
    for (final xml in [
      '<html>error</html>',
      '<result><error>auth</error></result>',
      '<result><record>',
      '<!DOCTYPE result><result/>',
    ]) {
      expect(() => UticXml.records(xml), throwsA(anything));
    }
    final unknown = UticXml.records(File('test/fixtures/utic/synthetic-fields.xml').readAsStringSync()).single;
    expect(unknown['controlType'], 'SYNTHETIC-UNKNOWN');
    expect(UticXml.normalizationVerified, isFalse);
  });
  test('strict settings disable malformed inputs and default false', () {
    expect(UticSettings({}).enabled, isFalse);
    expect(UticSettings({'UTIC_ENABLED': 'true', 'UTIC_TIMEOUT_SECONDS': 'bad'}).enabled, isFalse);
    expect(UticSettings({'UTIC_ENABLED': 'yes'}).enabled, isFalse);
    expect(UticSettings({'UTIC_ENABLED': 'true'}).enabled, isTrue);
  });
  test('fake HTTP non-200, redirect, HTML, timeout are isolated from ledger', () async {
    final url = Uri.parse('https://www.utic.go.kr/guide/imsOpenData.do');
    for (final status in [302, 401, 403, 429, 500]) {
      final c = MockClient((request) async => http.Response('synthetic error', status));
      await expectLater(UticHttp(c).fetch(endpoint: url, key: 'synthetic-not-a-key'), throwsFormatException);
      c.close();
    }
    final c = MockClient((request) async {
      expect(request.followRedirects, isFalse);
      return http.Response('<result/>', 200);
    });
    expect(await UticHttp(c).fetch(endpoint: url, key: 'synthetic-not-a-key'), '<result/>');
    c.close();
    await expectLater(
      UticHttp(
        MockClient((_) async => throw const SocketException('synthetic')),
      ).fetch(endpoint: url, key: 'synthetic-not-a-key'),
      throwsA(isA<SocketException>()),
    );
  });
  test(
    'UTIC total deadline covers an endlessly dribbling response and cancels its stream',
    () async {
      Timer? timer;
      var cancelled = false;
      late StreamController<List<int>> controller;
      controller = StreamController<List<int>>(
        onListen: () {
          timer = Timer.periodic(const Duration(milliseconds: 5), (_) => controller.add([32]));
        },
        onCancel: () {
          cancelled = true;
          timer?.cancel();
        },
      );
      final client = StreamingFakeClient(controller.stream);
      try {
        await expectLater(
          UticHttp(client).fetch(
            endpoint: Uri.parse('https://www.utic.go.kr/guide/imsOpenData.do'),
            key: 'synthetic-not-a-key',
            timeout: const Duration(milliseconds: 30),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(cancelled, isTrue);
      } finally {
        timer?.cancel();
        await controller.close();
        client.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 2)),
  );
}
