import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

final clock = DateTime.utc(2026, 11, 11);
TrafficNotice notice({String id = '1'}) => TrafficNotice(
  id: 'utic-$id',
  sourceRecordId: id,
  source: 'utic',
  sourceName: 'UTIC',
  kind: TrafficKind.event,
  title: 'synthetic',
  detail: '부분통제',
  start: clock,
  end: clock.add(const Duration(hours: 12)),
  location: const GeoPoint(37.57, 126.98),
  controlEvidence: 'confirmed',
  evidenceText: '부분통제',
  evidenceMethod: 'synthetic',
  timePrecision: 'minute',
  lastSeenAt: clock,
);

void main() {
  test('explicit release persists across complete omissions, restart, replay and partial source failure', () {
    final ledger = TrafficLedger()..accept('utic', [notice()], clock, complete: true);
    ledger.accept(
      'utic',
      [
        notice().withMetadata({'status': 'cancelled'}),
      ],
      clock.add(const Duration(minutes: 1)),
      complete: true,
    );
    ledger.accept('utic', [], clock.add(const Duration(minutes: 2)), complete: true);
    ledger.accept('utic', [], clock.add(const Duration(minutes: 33)), complete: true);
    final restored = TrafficLedger.fromJson(jsonDecode(jsonEncode(ledger.toJson())) as Map<String, dynamic>);
    restored.accept('utic', [notice()], clock.add(const Duration(minutes: 34)), complete: true);
    restored.failure('utic', clock.add(const Duration(minutes: 35)), 'timeout');
    expect(restored.withdrawals.single.status, 'cancelled');
    expect(restored.feed(clock.add(const Duration(minutes: 35)))['notices'], isEmpty);
    expect(restored.feed(clock.add(const Duration(minutes: 35)))['withdrawals'], hasLength(1));
  });

  test('partial ID-only release transfers without fabricated geometry and leaves other IDs unchanged', () {
    final at = clock.add(const Duration(minutes: 1));
    final ledger = TrafficLedger()..accept('utic', [notice(), notice(id: '2')], clock, complete: true);
    final source = TrafficSourceSnapshot(
      source: 'utic',
      observedAt: at,
      complete: false,
      withdrawals: [TrafficWithdrawal(source: 'utic', sourceRecordId: '1', observedAt: at)],
    );
    final parsed = TrafficSourceSnapshot.parse(
      jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
      now: at,
    );
    parsed.applyTo(ledger);
    final feed = ledger.feed(at);
    validateTrafficV2(feed);
    expect((feed['notices'] as List).single['sourceRecordId'], '2');
    expect(ledger.snapshots['utic']!.singleWhere((n) => n.sourceRecordId == '2').lastSeenAt, clock);
    expect((feed['withdrawals'] as List).single['sourceRecordId'], '1');
  });

  test('private source records allow release while public active-only validation stays strict', () {
    final at = clock.add(const Duration(minutes: 1));
    final released = notice().withMetadata({
      'status': 'cancelled',
      'lastSeenAt': at.toIso8601String(),
      'end': at.toIso8601String(),
    });
    final source = TrafficSourceSnapshot(source: 'utic', observedAt: at, complete: false, records: [released]);
    final parsed = TrafficSourceSnapshot.parse(source.toJson(), now: at);
    final ledger = TrafficLedger()..accept('utic', [notice()], clock, complete: true);
    parsed.applyTo(ledger);
    expect(ledger.feed(at)['notices'], isEmpty);
    final invalid = <String, dynamic>{
      'schemaVersion': 2,
      'generatedAt': at.toIso8601String(),
      'sources': [],
      'sourceStates': {},
      'notices': [released.toJson()],
    };
    expect(() => validateTrafficV2(invalid), throwsFormatException);
  });

  test('newer verified source revision can supersede release; older revision and observed-only replay cannot', () {
    final at = clock.add(const Duration(minutes: 1));
    final ledger = TrafficLedger()..accept('utic', [notice()], clock, complete: true);
    ledger.accept(
      'utic',
      [],
      at,
      complete: false,
      withdrawals: [TrafficWithdrawal(source: 'utic', sourceRecordId: '1', observedAt: at)],
    );
    ledger.accept('utic', [notice()], at.add(const Duration(minutes: 1)), complete: false);
    expect(ledger.feed(at.add(const Duration(minutes: 1)))['notices'], isEmpty);
    final revised = notice().withMetadata({'sourceUpdatedAt': at.add(const Duration(minutes: 2)).toIso8601String()});
    ledger.accept('utic', [revised], at.add(const Duration(minutes: 2)), complete: false);
    expect(ledger.feed(at.add(const Duration(minutes: 2)))['notices'], hasLength(1));
  });

  test('source snapshot rejects future/stale, cross-source and malformed releases before state mutation', () {
    final good = TrafficSourceSnapshot(source: 'utic', observedAt: clock, complete: false).toJson();
    for (final patch in [
      {'observedAt': clock.add(const Duration(seconds: 1)).toIso8601String()},
      {'observedAt': clock.subtract(const Duration(hours: 7)).toIso8601String()},
      {'source': 'its'},
      {'complete': 'false'},
      {
        'withdrawals': [
          {'source': 'its', 'sourceRecordId': '1', 'status': 'cancelled', 'observedAt': clock.toIso8601String()},
        ],
      },
    ]) {
      expect(() => TrafficSourceSnapshot.parse({...good, ...patch}, now: clock), throwsA(anything));
    }
  });

  test('snapshot import writes recoverable state and a valid public feed under the same store lock', () async {
    final dir = Directory.systemTemp.createTempSync('snapshot-import-');
    try {
      final store = TrafficStore(dir);
      await store.transaction((l) async {
        l.accept('utic', [notice()], clock, complete: true);
      });
      final at = clock.add(const Duration(minutes: 1));
      final source = TrafficSourceSnapshot(
        source: 'utic',
        observedAt: at,
        complete: false,
        withdrawals: [TrafficWithdrawal(source: 'utic', sourceRecordId: '1', observedAt: at)],
      );
      await store.transaction((l) async {
        TrafficSourceSnapshot.parse(source.toJson(), now: at).applyTo(l);
        l.stagePublication(File('${dir.path}/traffic-v2.json'), l.feed(at));
      });
      await store.transaction((l) async {
        expect(l.withdrawals.single.status, 'cancelled');
        expect(l.feed(at)['notices'], isEmpty);
      });
      validateTrafficV2(jsonDecode(File('${dir.path}/traffic-v2.json').readAsStringSync()) as Map<String, dynamic>);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
  test('release ledger commits before public feed; failed publication recovers without resurrection', () async {
    final dir = Directory.systemTemp.createTempSync('release-recovery-');
    try {
      final normal = TrafficStore(dir);
      await normal.transaction((l) async {
        l.accept('utic', [notice()], clock, complete: true);
      });
      final failing = TrafficStore(
        dir,
        writeJson: (file, data) async {
          if (file.path.endsWith('traffic-v2.json')) throw const FileSystemException('synthetic publication failure');
          await TrafficStore.atomicJson(file, data);
        },
      );
      final at = clock.add(const Duration(minutes: 1));
      await expectLater(
        failing.transaction((l) async {
          l.accept(
            'utic',
            [],
            at,
            complete: false,
            withdrawals: [TrafficWithdrawal(source: 'utic', sourceRecordId: '1', observedAt: at)],
          );
          l.stagePublication(File('${dir.path}/traffic-v2.json'), l.feed(at));
        }),
        throwsA(isA<FileSystemException>()),
      );
      await normal.transaction((l) async {
        expect(l.withdrawals.single.status, 'cancelled');
        l.accept('utic', [notice()], at.add(const Duration(minutes: 1)), complete: true);
        l.stagePublication(File('${dir.path}/traffic-v2.json'), l.feed(at.add(const Duration(minutes: 1))));
      });
      final feed = jsonDecode(File('${dir.path}/traffic-v2.json').readAsStringSync()) as Map<String, dynamic>;
      expect(feed['notices'], isEmpty);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
  test('normalized transfer cannot carry arbitrary secret-shaped fields into public JSON', () {
    const sentinel = 'SYNTHETIC_SECRET_SENTINEL';
    final raw = TrafficSourceSnapshot(source: 'utic', observedAt: clock, complete: true, records: [notice()]).toJson();
    raw['UTIC_API_KEY'] = sentinel;
    (raw['records'] as List).single['requestUri'] = sentinel;
    final parsed = TrafficSourceSnapshot.parse(raw, now: clock);
    final ledger = TrafficLedger();
    parsed.applyTo(ledger);
    expect(jsonEncode(ledger.feed(clock)), isNot(contains(sentinel)));
    expect(jsonEncode(ledger.toJson()), isNot(contains(sentinel)));
  });
  test('publication rebase keeps the newest source snapshots, latest attempts and explicit tombstones', () {
    final pending = TrafficLedger()..accept('utic', [notice()], clock, complete: true);
    final topis = notice().withMetadata({'source': 'seoul-topis', 'id': 'topis-1', 'sourceRecordId': 't1'});
    pending.accept('seoul-topis', [topis], clock.add(const Duration(minutes: 2)), complete: true);
    final published = TrafficLedger()..accept('utic', [notice()], clock, complete: true);
    published.accept(
      'utic',
      [],
      clock.add(const Duration(minutes: 1)),
      complete: false,
      withdrawals: [
        TrafficWithdrawal(source: 'utic', sourceRecordId: '1', observedAt: clock.add(const Duration(minutes: 1))),
      ],
    );
    published.accept('seoul-topis', [topis], clock, complete: true);
    published.failure('utic', clock.add(const Duration(minutes: 3)), 'timeout');
    published.states['its'] = {'status': 'disabled'};
    pending.mergeFrom(published);
    final feed = pending.feed(clock.add(const Duration(minutes: 3)));
    expect(pending.states['utic']!['status'], 'unavailable');
    expect(pending.states['seoul-topis']!['lastSuccessAt'], clock.add(const Duration(minutes: 2)).toIso8601String());
    expect(pending.states['its']!['status'], 'disabled');
    expect((feed['notices'] as List).single['source'], 'seoul-topis');
    expect(pending.withdrawals.single.status, 'cancelled');
    expect(legacyTrafficFeed(feed)['notices'], hasLength(1));
  });
  test('v1 preserves independent TOPIS evidence from a co-sourced UTIC group without leaking UTIC', () {
    final u = notice().withMetadata({'roadName': '세종대로', 'direction': '북', 'section': '가~나'});
    final t = u.withMetadata({'source': 'seoul-topis', 'id': 'topis-1', 'sourceRecordId': 't1'});
    final ledger = TrafficLedger()
      ..accept('utic', [u], clock, complete: true)
      ..accept('seoul-topis', [t], clock, complete: true);
    final feed = ledger.feed(clock);
    expect(feed['notices'], hasLength(1));
    final legacy = legacyTrafficFeed(feed);
    expect((legacy['notices'] as List).single['source'], 'seoul-topis');
    expect(jsonEncode(legacy), isNot(contains('"source":"utic"')));
    expect((legacy['notices'] as List).single['start'], '2026-11-11T09:00:00.000');
    ledger.accept(
      'utic',
      [
        u.withMetadata({'status': 'cancelled'}),
      ],
      clock.add(const Duration(minutes: 1)),
      complete: true,
    );
    expect(legacyTrafficFeed(ledger.feed(clock.add(const Duration(minutes: 1))))['notices'], isEmpty);
  });
  test('duplicate original IDs inside one source snapshot resolve by revision, not input order', () {
    final older = notice().withMetadata({
      'sourceUpdatedAt': clock.add(const Duration(minutes: 1)).toIso8601String(),
      'title': 'older',
    });
    final newer = notice().withMetadata({
      'sourceUpdatedAt': clock.add(const Duration(minutes: 2)).toIso8601String(),
      'title': 'newer',
    });
    final staleRelease = older.withMetadata({'status': 'cancelled'});
    final observed = clock.add(const Duration(minutes: 10));
    for (final rows in [
      [newer, older],
      [older, newer],
      [newer, staleRelease],
      [staleRelease, newer],
    ]) {
      final ledger = TrafficLedger()..accept('utic', rows, observed, complete: true);
      final feed = ledger.feed(observed);
      expect(feed['notices'], hasLength(1));
      expect((feed['notices'] as List).single['title'], 'newer');
    }
  });
}
