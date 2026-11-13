// Preview only. Never publishes or enables production collection.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liferadar_pipeline/src/contests/collector.dart';
import 'package:liferadar_pipeline/src/contests/store.dart';
import 'package:liferadar_pipeline/src/contests/feed.dart';

Future<void> main(List<String> args) async {
  String arg(String key, String fallback) =>
      args.firstWhere((s) => s.startsWith('--$key='), orElse: () => '--$key=$fallback').split('=').skip(1).join('=');
  final out = arg('out', 'out/contests-preview.json');
  final statePath = arg('state', 'out/contests-preview-state.json');
  final fixture = arg('fixtures', '');
  final now = DateTime.tryParse(arg('now', '')) ?? DateTime.now();
  final client = fixture.isEmpty
      ? http.Client()
      : MockClient((r) async {
          final file = r.url.path.endsWith('ListPage.do')
              ? 'initial.html'
              : r.url.path.endsWith('List.do')
              ? 'list-${Uri.splitQueryString(r.body)['miv_pageNo']}.html'
              : '${r.url.queryParameters['bbs_id']}.html';
          final f = File('$fixture/$file');
          return http.Response(
            f.existsSync() ? f.readAsStringSync() : 'fixture missing',
            f.existsSync() ? 200 : 500,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        });
  try {
    final result = await ContestCollector(
      SotongSession(
        client,
        timeout: Duration(seconds: int.parse(arg('timeout', '20'))),
        retries: int.parse(arg('retries', '2')),
        interval: fixture.isEmpty ? const Duration(seconds: 1) : Duration.zero,
      ),
      maxPages: int.parse(arg('max-pages', '1')),
      maxDetails: int.parse(arg('max-details', '9')),
    ).collect(ContestState.load(statePath), now: now);
    writeContestJson(statePath, result.state.toJson());
    final feed = {
      'generatedAt': now.toUtc().toIso8601String(),
      'previewOnly': true,
      'sources': [result.metadata],
      'records': result.state.records.values.toList(),
      'events': result.state.events(now).map((e) => e.toJson()).toList(),
    };
    validateContestFeed(feed);
    writeContestJson(out, feed);
    final mergeWith = arg('merge-with', '');
    if (mergeWith.isNotEmpty) {
      final base = (jsonDecode(File(mergeWith).readAsStringSync()) as Map).cast<String, dynamic>();
      final merged = mergeContestFeed(base, result.state, result.metadata, now)..['previewOnly'] = true;
      writeContestJson(arg('app-feed', 'out/events-preview.json'), merged);
    }
    stdout.writeln(
      '$out: ${result.metadata['status']}, ${feed['events'] is List ? (feed['events'] as List).length : 0} publishable; preview only',
    );
    if (result.metadata['status'] == 'failed') exitCode = 1;
  } finally {
    client.close();
  }
}
