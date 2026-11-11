import 'dart:convert';
import 'dart:io';
import 'package:liferadar_core/liferadar_core.dart';

/// Durable source ledger. All read/merge/write operations share an OS file lock.
/// State lives beside the public feed (traffic-state.json); never contains secrets/XML.
class TrafficStore {
  TrafficStore(this.directory, {Future<void> Function(File, Map<String, dynamic>)? writeJson})
    : _writeJson = writeJson ?? atomicJson;
  final Directory directory;
  final Future<void> Function(File, Map<String, dynamic>) _writeJson;

  Future<T> transaction<T>(Future<T> Function(TrafficLedger ledger) action) async {
    directory.createSync(recursive: true);
    final lock = await File('${directory.path}/.traffic.lock').open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    try {
      final state = File('${directory.path}/traffic-state.json');
      final ledger = state.existsSync()
          ? TrafficLedger.fromJson(jsonDecode(state.readAsStringSync()) as Map<String, dynamic>)
          : TrafficLedger();
      final value = await action(ledger);
      // Commit the release ledger before any public file. A publication failure
      // can leave an older feed, but the next publisher cannot revive old facts.
      await _writeJson(state, ledger.toJson());
      for (final entry in ledger._publications) {
        await _writeJson(entry.$1, entry.$2);
      }
      return value;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  static Future<void> atomicJson(File file, Map<String, dynamic> data) async {
    final temp = File('${file.path}.$pid.tmp');
    try {
      await temp.writeAsString(jsonEncode(data), flush: true);
      await temp.rename(file.path);
    } finally {
      if (temp.existsSync()) temp.deleteSync();
    }
  }
}

class TrafficLedger {
  TrafficLedger();
  final List<(File, Map<String, dynamic>)> _publications = [];
  void stagePublication(File file, Map<String, dynamic> data) {
    if (data['schemaVersion'] == 2) validateTrafficV2(data);
    _publications.add((file, jsonDecode(jsonEncode(data)) as Map<String, dynamic>));
  }

  final Map<String, Map<String, dynamic>> states = {};
  final Map<String, List<TrafficNotice>> snapshots = {};
  final Map<String, String> aliases = {};
  final Map<String, Map<String, dynamic>> tombstones = {};
  final Map<String, Map<String, dynamic>> missing = {};

  factory TrafficLedger.fromJson(Map<String, dynamic> j) {
    final l = TrafficLedger();
    for (final e in (j['sourceStates'] as Map? ?? {}).entries) {
      l.states[e.key as String] = (e.value as Map).cast<String, dynamic>();
    }
    for (final e in (j['snapshots'] as Map? ?? {}).entries) {
      l.snapshots[e.key as String] = [
        for (final n in e.value as List) TrafficNotice.fromJson((n as Map).cast<String, dynamic>()),
      ];
    }
    l.aliases.addAll((j['aliases'] as Map? ?? {}).cast<String, String>());
    for (final e in (j['tombstones'] as Map? ?? {}).entries) {
      l.tombstones[e.key as String] = (e.value as Map).cast<String, dynamic>();
    }
    for (final e in (j['missing'] as Map? ?? {}).entries) {
      l.missing[e.key as String] = (e.value as Map).cast<String, dynamic>();
    }
    return l;
  }

  /// Rebase a pending publication on the latest data-branch ledger.
  /// Success snapshots and latest attempts are ordered independently per source.
  void mergeFrom(TrafficLedger other) {
    DateTime? stamp(Map<String, dynamic>? state, String field) =>
        state?[field] == null ? null : trafficInstant(state![field] as String);
    for (final source in {...states.keys, ...other.states.keys}) {
      final local = states[source], remote = other.states[source];
      final localSuccess = stamp(local, 'lastSuccessAt'), remoteSuccess = stamp(remote, 'lastSuccessAt');
      final remoteWins = remoteSuccess != null && (localSuccess == null || !remoteSuccess.isBefore(localSuccess));
      final successState = remoteWins ? remote : local ?? remote;
      if (remoteWins) {
        final oldIds = (snapshots[source] ?? <TrafficNotice>[]).map((n) => n.id).toSet();
        snapshots[source] = [...other.snapshots[source] ?? <TrafficNotice>[]];
        missing.removeWhere((key, value) => key.startsWith('$source:') || oldIds.contains(key));
        final remoteIds = (other.snapshots[source] ?? <TrafficNotice>[]).map((n) => n.id).toSet();
        missing.addEntries(
          other.missing.entries.where((e) => e.key.startsWith('$source:') || remoteIds.contains(e.key)),
        );
      }
      final localAttempt = stamp(local, 'lastAttemptAt'), remoteAttempt = stamp(remote, 'lastAttemptAt');
      final remoteAttemptWins =
          remoteAttempt != null && (localAttempt == null || !remoteAttempt.isBefore(localAttempt));
      final attemptState = remoteAttemptWins ? remote : local ?? remote;
      states[source] = {
        ...?successState,
        ...?attemptState,
        if (successState != null) ...{
          'lastSuccessAt': successState['lastSuccessAt'],
          'snapshotVersion': successState['snapshotVersion'],
          'complete': successState['complete'],
        },
      };
    }
    for (final w in other.withdrawals) {
      _recordWithdrawal(w);
    }
    // The published ledger owns established group identities.
    aliases.addAll(other.aliases);
  }

  void failure(String source, DateTime at, String category) {
    final old = states[source] ?? {};
    final attempted = old['lastAttemptAt'] as String?;
    if (attempted != null && trafficInstant(attempted).isAfter(trafficUtc(at))) return;
    states[source] = {
      ...old,
      'status': 'unavailable',
      'lastAttemptAt': trafficUtc(at).toIso8601String(),
      'errorCategory': category,
    };
  }

  List<TrafficWithdrawal> get withdrawals => [
    for (final e in tombstones.entries)
      TrafficWithdrawal.fromJson({
        'source': e.key.substring(0, e.key.indexOf(':')),
        'sourceRecordId': e.key.substring(e.key.indexOf(':') + 1),
        ...e.value,
        'observedAt': e.value['observedAt'] ?? e.value['version'],
      }),
  ];

  void _recordWithdrawal(TrafficWithdrawal withdrawal) {
    final old = withdrawals.where((w) => w.key == withdrawal.key).firstOrNull;
    if (old != null && (old.explicit && !withdrawal.explicit || old.revision.isAfter(withdrawal.revision))) return;
    tombstones[withdrawal.key] = {...withdrawal.toJson(), 'version': withdrawal.revision.toIso8601String()};
  }

  void accept(
    String source,
    List<TrafficNotice> notices,
    DateTime at, {
    required bool complete,
    List<TrafficWithdrawal> withdrawals = const [],
  }) {
    final instant = trafficUtc(at);
    final old = states[source];
    if (old?['lastAttemptAt'] != null && trafficInstant(old!['lastAttemptAt'] as String).isAfter(instant)) return;
    if (old?['lastSuccessAt'] != null && !instant.isAfter(trafficInstant(old!['lastSuccessAt'] as String))) return;
    if (notices.any(
      (n) =>
          n.source != source ||
          !n.validLocation ||
          (n.sourceUpdatedAt != null && trafficUtc(n.sourceUpdatedAt!).isAfter(instant)),
    )) {
      throw const FormatException('Invalid source snapshot');
    }
    for (final w in withdrawals) {
      TrafficWithdrawal.fromJson(w.toJson());
      if (w.source != source || trafficUtc(w.observedAt).isAfter(instant)) {
        throw const FormatException('Invalid source withdrawal');
      }
    }
    final incoming = TrafficMerger.latestOriginals(notices);
    final previous = {for (final n in snapshots[source] ?? <TrafficNotice>[]) n.id: n};
    final next = complete ? <String, TrafficNotice>{} : {...previous};
    for (final w in withdrawals) {
      _recordWithdrawal(w);
      for (final prior in previous.values.where(w.blocks)) {
        next[prior.id] = prior.withMetadata({
          'status': w.status,
          'lastSeenAt': trafficUtc(w.observedAt).toIso8601String(),
          'sourceUpdatedAt': w.sourceUpdatedAt == null ? null : trafficUtc(w.sourceUpdatedAt!).toIso8601String(),
        });
      }
    }
    for (final n in incoming) {
      final key = '$source:${n.sourceRecordId ?? n.id}';
      final version = trafficUtc(n.sourceUpdatedAt ?? instant);
      final tomb = this.withdrawals.where((w) => w.key == key).firstOrNull;
      if (n.status == 'active' &&
          tomb != null &&
          tomb.blocks(n.withMetadata({'lastSeenAt': instant.toIso8601String()}))) {
        if (previous[n.id]?.status == 'cancelled' || previous[n.id]?.status == 'expired') next[n.id] = previous[n.id]!;
        continue;
      }
      final prior = previous[n.id];
      if (prior?.sourceUpdatedAt != null && version.isBefore(trafficUtc(prior!.sourceUpdatedAt!))) {
        next[n.id] = prior;
        continue;
      }
      missing.remove(key);
      missing.remove(n.id);
      if (n.status == 'cancelled' || n.status == 'expired') {
        _recordWithdrawal(
          TrafficWithdrawal(
            source: source,
            sourceRecordId: n.sourceRecordId ?? n.id,
            status: n.status,
            observedAt: instant,
            sourceUpdatedAt: n.sourceUpdatedAt,
          ),
        );
        next[n.id] = n.withMetadata({'lastSeenAt': instant.toIso8601String(), 'fetchedAt': instant.toIso8601String()});
        continue;
      }
      next[n.id] = n.withMetadata({'fetchedAt': instant.toIso8601String(), 'lastSeenAt': instant.toIso8601String()});
    }
    if (complete) {
      final received = incoming.map((n) => n.id).toSet();
      for (final prior in previous.values.where((n) => !received.contains(n.id))) {
        final key = '$source:${prior.sourceRecordId ?? prior.id}';
        if (next[prior.id]?.status == 'cancelled' || next[prior.id]?.status == 'expired') continue;
        // Omission is not weaker evidence capable of undoing an explicit release.
        if (prior.status == 'cancelled' || prior.status == 'expired') {
          next[prior.id] = prior;
          continue;
        }
        final m = missing[key] ?? missing.remove(prior.id) ?? {'since': instant.toIso8601String(), 'count': 0};
        m['count'] = (m['count'] as int) + 1;
        missing[key] = m;
        if ((m['count'] as int) >= 2 &&
            instant.difference(trafficInstant(m['since'] as String)) >= const Duration(minutes: 30)) {
          _recordWithdrawal(
            TrafficWithdrawal(
              source: source,
              sourceRecordId: prior.sourceRecordId ?? prior.id,
              status: 'missing',
              observedAt: instant,
            ),
          );
        } else {
          next[prior.id] = prior.withMetadata({'status': 'missing'});
        }
      }
    }
    snapshots[source] = next.values.toList();
    states[source] = {
      'status': complete ? 'ok' : 'partial',
      'lastAttemptAt': instant.toIso8601String(),
      'lastSuccessAt': instant.toIso8601String(),
      'complete': complete,
      'snapshotVersion': instant.toIso8601String(),
      'errorCategory': null,
    };
  }

  Map<String, dynamic> feed(DateTime now) {
    final all = snapshots.values.expand((s) => s);
    // Resolve releases and conflicts before relevance filtering.
    final notices = TrafficMerger.merge(
      all,
      aliases: aliases,
      now: now,
      withdrawals: withdrawals,
    ).where((n) => n.isRelevantAt(now)).toList();
    final j = <String, dynamic>{
      'schemaVersion': 2,
      'generatedAt': trafficUtc(now).toIso8601String(),
      'horizonDays': 28,
      'sources': [
        for (final id in states.keys)
          {
            'id': id,
            'name': id == 'utic' ? '경찰청 도시교통정보센터(UTIC)' : (snapshots[id]?.firstOrNull?.sourceName ?? id),
            'license': id == 'utic' ? 'UTIC 신청 목적 및 준수사항 적용' : '공공누리',
            if (id == 'utic') 'termsUrl': 'https://www.utic.go.kr/guide/newUtisDataWrite.do',
          },
      ],
      'sourceStates': states,
      'notices': [for (final n in notices) n.toJson()],
      'withdrawals': [for (final w in withdrawals) w.toJson()],
    };
    validateTrafficV2(j);
    return j;
  }

  Map<String, dynamic> toJson() => {
    'missing': missing,
    'sourceStates': states,
    'snapshots': {
      for (final e in snapshots.entries) e.key: [for (final n in e.value) n.toJson()],
    },
    'aliases': aliases,
    'tombstones': tombstones,
  };
}

void validateTrafficV2(Map<String, dynamic> j) {
  if (j['schemaVersion'] != 2 || j['sourceStates'] is! Map || j['notices'] is! List || j['sources'] is! List) {
    throw const FormatException('Invalid traffic v2 envelope');
  }
  final generated = trafficInstant(j['generatedAt'] as String);
  for (final state in (j['sourceStates'] as Map).values) {
    if (state is! Map || !{'ok', 'partial', 'unavailable', 'disabled'}.contains(state['status'])) {
      throw const FormatException('Invalid source state');
    }
    for (final field in ['lastAttemptAt', 'lastSuccessAt', 'snapshotVersion']) {
      if (state[field] != null && trafficInstant(state[field] as String).isAfter(generated)) {
        throw const FormatException('Future source observation');
      }
    }
  }
  for (final raw in (j['withdrawals'] as List? ?? const [])) {
    final w = TrafficWithdrawal.fromJson((raw as Map).cast<String, dynamic>());
    if (trafficUtc(w.observedAt).isAfter(generated)) throw const FormatException('Future traffic withdrawal');
  }
  for (final raw in j['notices'] as List) {
    final n = TrafficNotice.fromJson((raw as Map).cast<String, dynamic>());
    if (!n.validLocation ||
        n.lastSeenAt == null ||
        trafficUtc(n.lastSeenAt!).isAfter(generated) ||
        !n.isRelevantAt(generated)) {
      throw const FormatException('Invalid traffic observation');
    }
    for (final stamp in [n.fetchedAt, n.sourceUpdatedAt]) {
      if (stamp != null && trafficUtc(stamp).isAfter(generated)) throw const FormatException('Future traffic metadata');
    }
    for (final e in [n.toJson(), ...n.evidenceRefs]) {
      if (e['sourceUrl'] != null && !safeTrafficUrl(e['sourceUrl'] as String)) {
        throw const FormatException('Unsafe traffic source URL');
      }
    }
  }
}

/// v1 remains safe for old apps: KST wall strings and no UTIC/reference groups.
Map<String, dynamic> legacyTrafficFeed(Map<String, dynamic> v2) {
  validateTrafficV2(v2);
  final now = trafficInstant(v2['generatedAt'] as String);
  String wall(DateTime d) => trafficKst(d).toIso8601String().replaceFirst('Z', '');
  final originals = <TrafficNotice>[];
  for (final raw in v2['notices'] as List) {
    final n = TrafficNotice.fromJson((raw as Map).cast<String, dynamic>());
    // Old clients cannot express an evidence conflict as a reference card.
    if (n.conflict) continue;
    final refs = n.evidenceRefs.isEmpty ? [n] : [for (final e in n.evidenceRefs) TrafficNotice.fromJson(e)];
    originals.addAll(refs.where((e) => e.source != 'utic'));
  }
  final withdrawn = [
    for (final raw in (v2['withdrawals'] as List? ?? const []))
      TrafficWithdrawal.fromJson((raw as Map).cast<String, dynamic>()),
  ];
  final safe = TrafficMerger.merge(
    originals,
    now: now,
    withdrawals: withdrawn,
  ).where((n) => n.isRelevantAt(now) && n.hasControlEvidence && !n.referenceAt(now));
  return {
    'generatedAt': v2['generatedAt'],
    'horizonDays': v2['horizonDays'],
    'sources': [
      for (final s in v2['sources'] as List)
        if ((s as Map)['id'] != 'utic') s,
    ],
    'notices': [
      for (final n in safe) {...n.toJson(), 'start': wall(n.start), 'end': n.end == null ? null : wall(n.end!)},
    ],
  };
}
