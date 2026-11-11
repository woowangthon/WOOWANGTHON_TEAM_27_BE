import 'dart:io';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

Future<void> main(List<String> args) async {
  await TrafficStore(Directory(args[0])).transaction((l) async {
    // Force overlap between separate processes, not same-process OS lock semantics.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    l.failure(args[1], DateTime.utc(2026, 11, 11), 'synthetic');
  });
}
