import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import '../sources/sotong_contest.dart';
import 'store.dart';

class SotongBlocked implements Exception {
  const SotongBlocked();
  @override
  String toString() => 'Sotong access denied/authentication required; stopped';
}

/// Single sequential session. Public HTML only; no login or access-limit bypass.
class SotongSession {
  SotongSession(
    this.client, {
    this.interval = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 20),
    this.retries = 2,
    Future<void> Function(Duration)? sleep,
  }) : sleep = sleep ?? Future<void>.delayed;
  final http.Client client;
  final Duration interval, timeout;
  final int retries;
  final Future<void> Function(Duration) sleep;
  final _cookies = <String, String>{};
  final _csrfHeaders = <String, String>{};

  Future<http.Response> _send(Uri uri, Map<String, String> headers, Map<String, String>? form) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(form == null ? 'GET' : 'POST', uri, abortTrigger: abort.future)
      ..headers.addAll(headers);
    if (form != null) request.bodyFields = form;
    try {
      return await (() async => http.Response.fromStream(await client.send(request)))().timeout(timeout);
    } finally {
      // A Future timeout alone does not stop an in-flight HTTP request.
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<String> request(Uri uri, {Map<String, String>? form}) async {
    for (var attempt = 0; ; attempt++) {
      await sleep(interval);
      try {
        final headers = {
          'User-Agent': 'LifeRadar-Sotong-preview/0.1',
          'Referer': SotongContest.initialUri.toString(),
          if (_cookies.isNotEmpty) 'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
          ..._csrfHeaders,
        };
        final res = await _send(uri, headers, form);
        for (final c in (res.headers['set-cookie'] ?? '').split(RegExp(r',(?=\s*[^;,=\s]+=)'))) {
          if (c.trim().isEmpty) continue;
          final cookie = Cookie.fromSetCookieValue(c.trim());
          _cookies[cookie.name] = cookie.value;
        }
        if ([401, 403].contains(res.statusCode) ||
            (res.isRedirect && (res.headers['location'] ?? '').contains('login'))) {
          throw const SotongBlocked();
        }
        if (res.statusCode == 429 || res.statusCode >= 500) {
          if (attempt >= retries) throw HttpException('Sotong HTTP ${res.statusCode}');
          final retry = res.headers['retry-after'];
          final seconds = int.tryParse(retry ?? '');
          var delay = Duration(seconds: seconds ?? 2 * (attempt + 1));
          if (seconds == null && retry != null) {
            try {
              delay = HttpDate.parse(retry).difference(DateTime.now().toUtc());
            } catch (_) {
              /* use backoff */
            }
          }
          // Don't retry earlier than Retry-After; excessive waits stop this run.
          if (delay > const Duration(seconds: 60)) throw const HttpException('Sotong Retry-After exceeds run budget');
          await sleep(delay.isNegative ? Duration.zero : delay);
          continue;
        }
        if (res.statusCode != 200) throw HttpException('Sotong HTTP ${res.statusCode}');
        final raw = utf8.decode(res.bodyBytes);
        if (RegExp(r'<title>[^<]*(?:로그인|접근\s*차단|Access Denied)', caseSensitive: false).hasMatch(raw)) {
          throw const SotongBlocked();
        }
        return raw;
      } on SotongBlocked {
        rethrow;
      } on TimeoutException {
        if (attempt >= retries) rethrow;
        await sleep(Duration(seconds: 2 * (attempt + 1)));
      } on SocketException {
        if (attempt >= retries) rethrow;
        await sleep(Duration(seconds: 2 * (attempt + 1)));
      } on http.ClientException {
        if (attempt >= retries) rethrow;
        await sleep(Duration(seconds: 2 * (attempt + 1)));
      }
    }
  }

  Future<Map<String, String>> initialize() async {
    final raw = await request(SotongContest.initialUri);
    final doc = html.parse(raw);
    final token = doc.querySelector('meta[name="_csrf"]')?.attributes['content'];
    final header = doc.querySelector('meta[name="_csrf_header"]')?.attributes['content'];
    if (token != null && header != null && RegExp(r'^[A-Za-z0-9-]+$').hasMatch(header)) _csrfHeaders[header] = token;
    return SotongContest.form(raw);
  }
}

class ContestCollection {
  const ContestCollection(this.state, this.metadata);
  final ContestState state;
  final Map<String, dynamic> metadata;
}

class ContestCollector {
  ContestCollector(this.session, {this.maxPages = 50, this.maxDetails = 450});
  final SotongSession session;
  final int maxPages, maxDetails;

  Future<ContestCollection> collect(ContestState previous, {DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    var state = previous.copy();
    final errors = <String>[];
    final seen = <String>{};
    final pages = <String>{};
    var complete = false;
    var detailCalls = 0;
    var lists = 0;
    try {
      final form = await session.initialize();
      for (var page = 1; page <= maxPages; page++) {
        final raw = await session.request(SotongContest.listUri, form: {...form, 'miv_pageNo': '$page'});
        final parsed = SotongContest.list(raw, page);
        final signature = (parsed.rows.map((r) => r['sourceId'] as String).toList()..sort()).join(',');
        if (!pages.add(signature) || parsed.rows.every((r) => seen.contains(r['sourceId']))) {
          throw const FormatException('Sotong repeated page');
        }
        lists++;
        for (final row in parsed.rows) {
          final id = row['sourceId'] as String;
          if (!seen.add(id)) continue;
          final old = state.records[id];
          final listHash = SotongContest.hash(jsonEncode(row));
          final verified = DateTime.tryParse(old?['lastVerifiedAt'] as String? ?? '');
          final refresh =
              old == null ||
              old['listHash'] != listHash ||
              old['parserVersion'] != SotongContest.parserVersion ||
              ['open', 'upcoming', 'unknown'].contains(old['applicationStatus']) ||
              verified == null ||
              at.difference(verified) > const Duration(hours: 24);
          if (old != null) old['lastSeenAt'] = at.toIso8601String();
          if (!refresh) continue;
          if (detailCalls >= maxDetails) {
            errors.add('detail_limit');
            continue;
          }
          detailCalls++;
          try {
            final raw = await session.request(Uri.parse(row['sourceUrl'] as String));
            final record = SotongContest.detail(row, raw, at);
            // A formerly valid body becoming empty is a parsing regression,
            // not evidence that its previously verified dates disappeared.
            if (old?['publishability'] == 'ready' &&
                record['applicationStatus'] == 'unknown' &&
                record['kind'] != 'other') {
              errors.add('detail:$id:unverified body; retained previous');
              continue;
            }
            state.records[id] = {
              ...record,
              'firstSeenAt': old?['firstSeenAt'] ?? at.toIso8601String(),
              'lastSeenAt': at.toIso8601String(),
              'listHash': listHash,
            };
          } on SotongBlocked {
            rethrow;
          } catch (e) {
            errors.add('detail:$id:${e.runtimeType}');
          }
        }
        if (page >= parsed.lastPage) {
          complete = true;
          break;
        }
      }
      if (!complete) errors.add('page_limit');
      if (complete && previous.lastCompleteCount != null && seen.length < previous.lastCompleteCount! * 0.5) {
        // Suspect a major structure/filter regression; preserve entire ledger.
        throw const FormatException('Sotong suspicious count drop');
      }
    } catch (e) {
      errors.add('list:${e.runtimeType}:$e');
      // List/auth/HTML failure: whole previous normal snapshot survives.
      state = previous.copy();
      complete = false;
    }
    final status = errors.isEmpty && complete
        ? 'success'
        : lists == 0 || errors.any((e) => e.startsWith('list:'))
        ? 'failed'
        : 'partial';
    if (status == 'success') {
      state.lastSuccessAt = at.toIso8601String();
      state.lastCompleteCount = seen.length;
    }
    return ContestCollection(state, {
      'id': SotongContest.source,
      'name': SotongContest.name,
      'url': SotongContest.initialUri.toString(),
      'access': 'public-html-not-openapi',
      'reuseConditions': 'unconfirmed',
      'license': null,
      'status': status,
      'attemptedAt': at.toIso8601String(),
      'lastSuccessAt': state.lastSuccessAt,
      'pages': lists,
      'seenCount': seen.length,
      'detailRequests': detailCalls,
      'errors': errors,
      'preservedPrevious': status != 'success',
      'count': state.events(at).length,
    });
  }
}
