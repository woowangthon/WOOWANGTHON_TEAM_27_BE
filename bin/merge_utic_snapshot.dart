import 'dart:convert';
import 'dart:io';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

/// Reads a private-storage *normalized* source snapshot. No UTIC call, no key.
/// The storage download/auth step belongs to the deployment's secret manager.
Future<void> main(List<String> args) async {
  String option(String key, String fallback) =>
      args.firstWhere((a) => a.startsWith('--$key='), orElse: () => '--$key=$fallback').substring(key.length + 3);
  final path = option('snapshot', '');
  final dir = option('dir', 'out');
  if (path.isEmpty) throw const FormatException('Normalized snapshot path required');
  final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final now = DateTime.now().toUtc();
  final snapshot = TrafficSourceSnapshot.parse(j, now: now);
  await TrafficStore(Directory(dir)).transaction((ledger) async {
    snapshot.applyTo(ledger);
    ledger.stagePublication(File('$dir/traffic-v2.json'), ledger.feed(now));
  });
}
