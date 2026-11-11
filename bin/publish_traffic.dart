import 'dart:io';
import 'dart:convert';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

Future<void> main(List<String> args) async {
  final dir = args.firstWhere((a) => a.startsWith('--dir='), orElse: () => '--dir=out').substring(6);
  final base = args.where((a) => a.startsWith('--base=')).firstOrNull?.substring(7);
  await TrafficStore(Directory(dir)).transaction((ledger) async {
    if (base != null) {
      final published = File('$base/traffic-state.json');
      if (published.existsSync()) {
        ledger.mergeFrom(TrafficLedger.fromJson(jsonDecode(published.readAsStringSync()) as Map<String, dynamic>));
      }
    }
    final feed = ledger.feed(DateTime.now().toUtc());
    ledger.stagePublication(File('$dir/traffic-v2.json'), feed);
    if (args.contains('--legacy')) ledger.stagePublication(File('$dir/traffic.json'), legacyTrafficFeed(feed));
  });
}
