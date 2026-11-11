import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'utic_codebook.dart';

/// Only the public reference's result/record field structure is known.
/// Code definitions are verified separately; CRS/time-zone/error/completeness are not inferred here.
class UticXml {
  static const documentedFields = {
    'incidentId',
    'incidenteTypeCd',
    'incidenteSubTypeCd',
    'addressJibun',
    'addressJibunCd',
    'addressNew',
    'linkId',
    'locationDataX',
    'locationDataY',
    'locationTypeCd',
    'locationData',
    'incidenteTrafficCd',
    'incidenteGradeCd',
    'incidentTitle',
    'incTrafficCode',
    'incidentRegionCd',
    'startDate',
    'endDate',
    'lane',
    'roadName',
    'sourceCode',
    'lineLinkId',
    'controlType',
    'important',
    'updateDate',
  };
  static List<Map<String, String>> records(String xml) {
    if (xml.contains('<!DOCTYPE') || xml.contains('<!ENTITY')) {
      throw const FormatException('Unsupported XML declaration');
    }
    final root = XmlDocument.parse(xml).rootElement;
    if (root.name.qualified != 'result' || root.childElements.any((e) => e.name.qualified != 'record')) {
      throw const FormatException('Unverified UTIC envelope');
    }
    return [
      for (final r in root.childElements)
        {
          for (final e in r.childElements.where((e) => documentedFields.contains(e.name.qualified)))
            e.name.qualified: e.innerText.trim(),
        },
    ];
  }

  /// No TrafficNotice is emitted until the contract has been independently verified.
  static const normalizationVerified = false;
  static const quarantineReason = 'UTIC_CRS_TIME_COMPLETENESS_UNVERIFIED';
  static List<UticRecord> decode(String xml) => [for (final row in records(xml)) UticRecord(row)];
}

/// Transport deliberately knows nothing about normalization or ledger mutation.
/// Callers log categories only; exception bodies/URIs can contain credentials.
class UticHttp {
  UticHttp(this.client);
  final http.Client client;
  Future<String> fetch({
    required Uri endpoint,
    required String key,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (endpoint.scheme != 'https' ||
        endpoint.host != 'www.utic.go.kr' ||
        endpoint.path != '/guide/imsOpenData.do' ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.port != 443 ||
        key.isEmpty) {
      throw const FormatException('Unapproved UTIC transport');
    }
    // HTTPS here is a transport safety requirement, not a claim of API support.
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final left = timeout - elapsed.elapsed;
      if (left <= Duration.zero) throw TimeoutException('UTIC_REQUEST_TIMEOUT');
      return left;
    }

    final request = http.Request('GET', endpoint.replace(queryParameters: {'key': key}))..followRedirects = false;
    final response = await client.send(request).timeout(remaining());
    if (response.statusCode != 200) throw const FormatException('UTIC_HTTP_FAILURE');
    final bytes = <int>[];
    final body = StreamIterator<List<int>>(response.stream);
    try {
      while (await body.moveNext().timeout(remaining())) {
        bytes.addAll(body.current);
        if (bytes.length > 10 * 1024 * 1024) throw const FormatException('UTIC_RESPONSE_TOO_LARGE');
      }
    } finally {
      await body.cancel();
    }
    return utf8.decode(bytes);
  }
}

class UticSettings {
  UticSettings(Map<String, dynamic> values) {
    bool flag(Object? v) => v == true || v == 'true';
    final enabledValue = values['UTIC_ENABLED'] ?? false;
    valid = {true, false, 'true', 'false'}.contains(enabledValue);
    for (final e in {
      'UTIC_TIMEOUT_SECONDS': 15,
      'UTIC_POLL_INTERVAL_MINUTES': 15,
      'UTIC_FRESH_MINUTES': 60,
      'UTIC_CACHE_MAX_HOURS': 6,
    }.entries) {
      final v = int.tryParse('${values[e.key] ?? e.value}');
      if (v == null || v <= 0) valid = false;
    }
    enabled = valid && flag(enabledValue);
  }
  late final bool enabled;
  late bool valid;
}

/// Review DTO only. No coordinates or wall clock are turned into TrafficNotice.
class UticRecord {
  UticRecord(Map<String, String> input)
    : raw = Map.unmodifiable({
        for (final e in input.entries.where((e) => UticXml.documentedFields.contains(e.key))) e.key: e.value,
      });
  final Map<String, String> raw;
  String get id => raw['incidentId'] ?? '';
  String? get typeLabel => UticCodebook.types[raw['incidenteTypeCd']];
  String? get subtypeLabel => UticCodebook.subtypes['${raw['incidenteTypeCd']}:${raw['incidenteSubTypeCd']}'];
  String? get controlDirectionLabel => UticCodebook.controlDirections[raw['controlType']];
  bool get hasDocumentedControl => {'1', '2'}.contains(raw['controlType']);
  // XLSX calls 0 'none'; HWP calls it a lane-based default. Treat that
  // discrepancy as unknown evidence, never absence of control or a release.
  bool get canPublish => false;
  List<String> get quarantineReasons => [
    if (id.trim().isEmpty) 'MISSING_ORIGINAL_ID',
    if (raw['controlType'] == '0') 'CONTROL_ZERO_MEANING_CONFLICT',
    if (typeLabel == null || subtypeLabel == null) 'UNKNOWN_TYPE_CODE',
    if (controlDirectionLabel == null) 'UNKNOWN_CONTROL_CODE',
    if (!UticCodebook.locationTypes.containsKey(raw['locationTypeCd'])) 'UNKNOWN_LOCATION_CODE',
    if (raw['incidenteTypeCd'] == '5' && raw['controlType'] == '0') 'CONFLICTING_CONTROL_CODES',
    'UTIC_CRS_UNVERIFIED',
    'UTIC_TIMEZONE_UNVERIFIED',
    'UTIC_COMPLETENESS_UNVERIFIED',
  ];
}
