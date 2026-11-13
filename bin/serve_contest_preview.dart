// Local-only reviewed feed server for Flutter EVENTS_URL, without production publication.
import 'dart:io';
import 'dart:convert';
import 'package:liferadar_pipeline/src/contests/store.dart';

Future<void> main(List<String> args) async {
  String arg(String name, String fallback) =>
      args.firstWhere((a) => a.startsWith('--$name='), orElse: () => '--$name=$fallback').split('=').skip(1).join('=');
  final file = File(arg('file', 'out/events-preview.json'));
  final raw = file.readAsStringSync();
  final json = (jsonDecode(raw) as Map).cast<String, dynamic>();
  if (json['previewOnly'] != true) throw const FormatException('Only a preview feed may be served');
  validateContestFeed(json);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, int.parse(arg('port', '8787')));
  stdout.writeln(
    'Local preview: http://127.0.0.1:${server.port}/events.json (${(json['events'] as List).length} events)',
  );
  await for (final request in server) {
    final origin = request.headers.value('origin') ?? '';
    if (RegExp(r'^http://(?:localhost|127\.0\.0\.1)(?::\d+)?$').hasMatch(origin)) {
      request.response.headers.set('Access-Control-Allow-Origin', origin);
      request.response.headers.set('Vary', 'Origin');
    }
    if (request.method == 'GET' && request.uri.path == '/events.json') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(raw);
    } else {
      request.response.statusCode = 404;
    }
    await request.response.close();
  }
}
