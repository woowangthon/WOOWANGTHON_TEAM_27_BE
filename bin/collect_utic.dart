import 'dart:io';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

/// Fixed-egress server entry point. Never logs keys, request URIs or raw errors.
Future<void> main(List<String> args) async {
  final settings = UticSettings(loadKeys());
  if (!settings.enabled) {
    stdout.writeln('UTIC disabled');
    return;
  }
  // This lock is intentionally independent of the environment toggle.
  if (!UticXml.normalizationVerified) {
    stderr.writeln(UticXml.quarantineReason);
    exitCode = 2;
    return;
  }
  throw StateError('Verified UTIC normalization must be implemented before enabling collection');
}
