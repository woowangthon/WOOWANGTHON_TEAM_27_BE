import 'package:liferadar_core/liferadar_core.dart';

/// Reviewed factual metadata only. Never infer an onsite venue from a sponsor's
/// address, or an onsite schedule from reception dates. No network side effects.
class PortalReview {
  static const hosts = {
    'linkareer': 'linkareer.com',
    'thinkgood': 'thinkcontest.com',
    'allforyoung': 'allforyoung.com',
  };

  static String _text(Map<String, dynamic> r, String key) {
    final value = r[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Missing $key');
    }
    return value.trim();
  }

  static Uri _url(String value) {
    final u = Uri.parse(value);
    if (u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty) {
      throw const FormatException('Expected public HTTPS source URL');
    }
    return u;
  }

  static DateTime _day(Map<String, dynamic> r, String key) {
    final s = _text(r, key);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) {
      throw FormatException('$key must be a civil KST date');
    }
    final d = DateTime.parse(s);
    if (d.toIso8601String().substring(0, 10) != s) {
      throw FormatException('Invalid $key');
    }
    return d;
  }

  static void _evidence(Map<String, dynamic> r, String key) {
    final evidence = (r['evidence'] as Map?)?[key];
    if (evidence is! Map ||
        evidence['quote'] is! String ||
        (evidence['quote'] as String).trim().isEmpty) {
      throw FormatException('Missing $key evidence');
    }
    _url(evidence['url'] as String);
  }

  /// One record per physical session, with a shared canonical contest ID.
  /// A hybrid contest must list only its physical days, not its online interval.
  static RadarEvent event(Map<String, dynamic> r, DateTime now) {
    if (r['reviewed'] != true) throw const FormatException('Review required');
    final portal = _text(r, 'portal');
    final source = _url(_text(r, 'sourceUrl'));
    final host = source.host.replaceFirst(RegExp(r'^www\.'), '');
    if (hosts[portal] != host) {
      throw const FormatException('Portal host mismatch');
    }
    final id = _text(r, 'contestId');
    final sessionId = _text(r, 'sessionId');
    if (![
      id,
      sessionId,
    ].every((s) => RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(s))) {
      throw const FormatException('IDs must be stable ASCII identifiers');
    }
    final verified = DateTime.parse(_text(r, 'verifiedAt'));
    if (!verified.isUtc || verified.isAfter(now.toUtc())) {
      throw const FormatException('verifiedAt must be a past UTC instant');
    }
    for (final key in ['application', 'eligibility']) {
      _evidence(r, key);
    }
    final begin = _day(r, 'applicationStart');
    final deadline = _day(r, 'deadline');
    if (deadline.isBefore(begin)) {
      throw const FormatException('Reversed reception');
    }
    final mode = _text(r, 'participationMode');
    if (!['onsite', 'online', 'hybrid', 'unknown'].contains(mode)) {
      throw const FormatException('Invalid participationMode');
    }
    final onsite = r['onsite'] == true;
    var start = begin;
    var end = deadline;
    var location = const GeoPoint(0, 0); // placeless sentinel, never mapped
    var venue = _text(r, 'organizer');
    var city = '미확인';
    if (onsite) {
      if (!['onsite', 'hybrid'].contains(mode)) {
        throw const FormatException('Online session cannot be mapped');
      }
      for (final key in ['schedule', 'venue', 'coordinates']) {
        _evidence(r, key);
      }
      start = _day(r, 'start');
      end = _day(r, 'end');
      if (end.isBefore(start)) {
        throw const FormatException('Reversed onsite dates');
      }
      venue = _text(r, 'venue');
      city = _text(r, 'city');
      final lat = (r['lat'] as num).toDouble();
      final lng = (r['lng'] as num).toDouble();
      if (!lat.isFinite ||
          !lng.isFinite ||
          lat < 33 ||
          lat > 39 ||
          lng < 124 ||
          lng > 132) {
        throw const FormatException('Invalid Korean venue coordinates');
      }
      location = GeoPoint(lat, lng);
    }
    final status = r['applicationStatus'] as String? ?? 'open';
    if (!['open', 'upcoming', 'closed', 'cancelled'].contains(status)) {
      throw const FormatException('Invalid application status');
    }
    final title = _text(r, 'title');
    final summary = '${_text(r, 'organizer')}\n${_text(r, 'summary')}';
    return RadarEvent(
      id: 'contest-$portal-$id-$sessionId',
      title: LocalizedText(ko: title, en: title),
      description: LocalizedText(ko: summary, en: summary),
      category: EventCategory.contest,
      tags: [
        for (final t in r['tags'] as List? ?? ['contest']) t as String,
      ],
      start: start,
      end: end,
      deadline: deadline,
      applicationStart: begin,
      eventDatePrecision: onsite ? 'date' : null,
      venue: venue,
      city: city,
      location: location,
      placeless: !onsite,
      source: 'contest-$portal',
      sourceName: '${r['portalName'] ?? portal} · 수동 확인',
      url: source.toString(),
      registerUrl: r['registerUrl'] == null
          ? null
          : _url(r['registerUrl'] as String).toString(),
      applicationStatus: status,
      deadlinePrecision: 'date',
      lastVerifiedAt: verified,
      eligibilityText: _text(r, 'eligibility'),
      participationMode: mode,
    );
  }
}
