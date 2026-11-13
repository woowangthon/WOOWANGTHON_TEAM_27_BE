import 'dart:convert';
import 'dart:io';
import 'package:liferadar_pipeline/src/contests/store.dart';

void main(List<String> args) {
  final feed = (jsonDecode(File(args.isEmpty ? 'out/events.json' : args.first).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  validateContestFeed(feed);
  stdout.writeln(
    'Sotong source validation passed: ${(feed['sources'] as List).where((s) => s['id'] == 'sotong-contest').single}',
  );
}
