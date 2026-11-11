import 'package:liferadar_core/liferadar_core.dart';
import 'traffic_store.dart';

/// Our private normalized source-transfer contract, NOT the UTIC API schema.
/// Public feeds contain active notices; transfers can also carry release IDs.
class TrafficSourceSnapshot {
  const TrafficSourceSnapshot({
    required this.source,
    required this.observedAt,
    required this.complete,
    this.records = const [],
    this.withdrawals = const [],
  });

  final String source;
  final DateTime observedAt;
  final bool complete;
  final List<TrafficNotice> records;
  final List<TrafficWithdrawal> withdrawals;

  static TrafficSourceSnapshot parse(Map<String, dynamic> j, {required DateTime now, String expectedSource = 'utic'}) {
    final legacy = j['schemaVersion'] == 2 && j['snapshotType'] == null;
    final sourceStates = j['sourceStates'];
    final rawState = sourceStates is Map ? sourceStates[expectedSource] : null;
    final state = rawState is Map ? rawState : <String, dynamic>{};
    if (legacy) {
      // Compatibility with the earlier normalized v2 active-only snapshot.
      if (!{'ok', 'partial'}.contains(state['status']) ||
          state['complete'] is! bool ||
          (state['status'] == 'partial' && state['complete'] == true) ||
          j['notices'] is! List) {
        throw const FormatException('Invalid legacy source transfer');
      }
    } else if (j['snapshotType'] != 'traffic-source' ||
        j['schemaVersion'] != 1 ||
        j['source'] != expectedSource ||
        j['complete'] is! bool ||
        j['records'] is! List) {
      throw const FormatException('Invalid source transfer');
    }
    final observed = trafficInstant((legacy ? state['lastSuccessAt'] : j['observedAt']) as String);
    final age = trafficUtc(now).difference(observed);
    if (age.isNegative || age > Duration(hours: expectedSource == 'utic' ? 6 : 24)) {
      throw const FormatException('Expired or future source transfer');
    }
    final records = [
      for (final raw in (legacy ? j['notices'] : j['records']) as List)
        TrafficNotice.fromJson((raw as Map).cast<String, dynamic>()),
    ];
    final withdrawals = [
      for (final raw in (j['withdrawals'] as List? ?? const []))
        TrafficWithdrawal.fromJson((raw as Map).cast<String, dynamic>()),
    ];
    for (final n in records) {
      final release = n.status == 'cancelled' || n.status == 'expired';
      if (n.source != expectedSource ||
          n.id.isEmpty ||
          (n.sourceRecordId ?? n.id).isEmpty ||
          n.lastSeenAt != observed ||
          (n.fetchedAt != null && trafficUtc(n.fetchedAt!).isAfter(observed)) ||
          !n.validLocation ||
          (n.sourceUpdatedAt != null && trafficUtc(n.sourceUpdatedAt!).isAfter(observed)) ||
          (!release && (!n.isRelevantAt(observed) || !n.hasControlEvidence))) {
        throw const FormatException('Invalid normalized source record');
      }
      for (final e in [n.toJson(), ...n.evidenceRefs]) {
        if (e['sourceUrl'] != null && !safeTrafficUrl(e['sourceUrl'] as String)) {
          throw const FormatException('Unsafe source transfer URL');
        }
      }
      if (n.evidenceRefs.isNotEmpty) throw const FormatException('Transfer original source records, not merged groups');
    }
    for (final w in withdrawals) {
      if (w.source != expectedSource || trafficUtc(w.observedAt).isAfter(observed)) {
        throw const FormatException('Invalid source transfer withdrawal');
      }
    }
    return TrafficSourceSnapshot(
      source: expectedSource,
      observedAt: observed,
      complete: (legacy ? state['complete'] : j['complete']) as bool,
      records: records,
      withdrawals: withdrawals,
    );
  }

  void applyTo(TrafficLedger ledger) =>
      ledger.accept(source, records, observedAt, complete: complete, withdrawals: withdrawals);

  Map<String, dynamic> toJson() => {
    'snapshotType': 'traffic-source',
    'schemaVersion': 1,
    'source': source,
    'observedAt': trafficUtc(observedAt).toIso8601String(),
    'complete': complete,
    'records': [for (final n in records) n.toJson()],
    'withdrawals': [for (final w in withdrawals) w.toJson()],
  };
}
