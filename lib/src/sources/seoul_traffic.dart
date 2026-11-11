/// 서울시 실시간 돌발 정보 (서울 열린데이터광장 `AccInfo`, 서울시 TOPIS).
/// 집회·행사·공사 등으로 인한 도로 통제. 라이선스: 공공누리 — [sourceName].
/// 순수 Dart — 수집 스크립트와 테스트에서 사용한다. API가 XML과 http만 제공하므로
/// 앱이 아니라 GitHub Actions가 수집한다.
library;

import 'dart:math' as math;

import 'package:liferadar_core/liferadar_core.dart';
import 'package:xml/xml.dart';
import 'seoul_culture.dart' show SourceException;
import 'tagger.dart' show unescapeHtml;

class SeoulTraffic {
  static const source = 'seoul-topis';
  static const sourceName = '서울시 TOPIS · 실시간 돌발정보';
  static const sourceUrl = 'https://topis.seoul.go.kr';

  static Uri uri(String key, {int from = 1, int to = 1000}) =>
      Uri.parse('http://openapi.seoul.go.kr:8088/$key/xml/AccInfo/$from/$to/');

  /// 일정과 관련 있는 유형만. 사고, 차량 고장처럼 짧은 돌발은 수집 주기(시간 단위)에
  /// 맞지 않아 낡은 정보가 되므로 제외한다.
  static TrafficKind? kindOf(String type, String subtype) => switch (type) {
    'A10' => switch (subtype) {
      '10B02' => TrafficKind.rally,
      '10B03' => TrafficKind.event,
      '10B01' => TrafficKind.drill,
      _ => TrafficKind.event,
    },
    'A04' => TrafficKind.construction,
    'A09' => TrafficKind.weather,
    _ => null,
  };

  /// XML 응답 → 행 목록 (단순한 평면 구조). 오류 코드면 [SourceException].
  static List<Map<String, String>> rows(String xml) {
    final root = XmlDocument.parse(xml).rootElement;
    final code = root.findAllElements('CODE').firstOrNull?.innerText ?? '';
    if (code == 'INFO-200') return const [];
    if (code != 'INFO-000' || root.name.qualified != 'AccInfo') {
      throw const SourceException('TOPIS incomplete envelope');
    }
    final count = int.tryParse(root.getElement('list_total_count')?.innerText ?? '');
    if (count == null || count < 0) throw const SourceException('TOPIS missing count');
    return [
      for (final row in root.findElements('row'))
        {for (final field in row.childElements) field.name.qualified: field.innerText},
    ];
  }

  static bool isComplete(String xml, List<Map<String, String>> records) {
    final root = XmlDocument.parse(xml).rootElement;
    if (root.findAllElements('CODE').firstOrNull?.innerText == 'INFO-200') return true;
    final count = int.tryParse(root.getElement('list_total_count')?.innerText ?? '');
    return count == records.length &&
        !records.any((r) => kindOf(r['acc_type'] ?? '', r['acc_dtype'] ?? '') != null && parse(r) == null);
  }

  /// 행 하나 → [TrafficNotice]. 대상 유형이 아니거나 위치·시작 시각이 없으면 null.
  static TrafficNotice? parse(Map<String, String> r) {
    final kind = kindOf(r['acc_type'] ?? '', r['acc_dtype'] ?? '');
    if (kind == null) return null;
    final start = _at(r['occr_date'], r['occr_time']);
    final x = double.tryParse(r['grs80tm_x'] ?? '');
    final y = double.tryParse(r['grs80tm_y'] ?? '');
    if (start == null ||
        x == null ||
        y == null ||
        !x.isFinite ||
        !y.isFinite ||
        (x == 0 && y == 0) ||
        (r['acc_id'] ?? '').trim().isEmpty) {
      return null;
    }
    final point = tmToWgs84(x, y);
    if (!point.lat.isFinite ||
        !point.lng.isFinite ||
        point.lat < 33 ||
        point.lat > 39 ||
        point.lng < 124 ||
        point.lng > 132) {
      return null;
    }
    final end = _at(r['exp_clr_date'], r['exp_clr_time']);

    final detail = unescapeHtml(
      r['acc_info'] ?? '',
    ).split(RegExp(r'[\r\n]+')).map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
    if (detail.isEmpty) return null;
    return TrafficNotice(
      id: 'topis-${r['acc_id']}',
      kind: kind,
      title: detail.split('\n').first,
      detail: detail,
      start: start,
      // 출처에서 종료가 시작보다 앞서면 잘못된 값 — 추정하지 않는다.
      end: end != null && end.isAfter(start) ? end : null,
      location: point,
      source: source,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
      sourceUrlKind: 'center',
      sourceRecordId: r['acc_id'],
      timePrecision: 'minute',
      controlEvidence: explicitRoadControl(detail) ? 'confirmed' : 'unconfirmed',
      evidenceText: detail,
      evidenceMethod: 'literal-road-control-v2',
      locationText: r['road_name'],
    );
  }

  /// "20261107" + "1400" | "220000" → 현지(KST) 시각. 시각이 없으면 제외한다.
  static DateTime? _at(String? date, String? time) {
    final d = (date ?? '').trim();
    if (!RegExp(r'^\d{8}$').hasMatch(d)) return null;
    final t = (time ?? '').trim();
    if (!RegExp(r'^(\d{4}|\d{6})$').hasMatch(t)) return null;
    final padded = t.padRight(6, '0');
    try {
      return trafficInstant(
        '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)}T${padded.substring(0, 2)}:${padded.substring(2, 4)}:${padded.substring(4, 6)}+09:00',
      );
    } catch (_) {
      return null;
    }
  }

  /// GRS80 TM (EPSG:5181, Korea 2000 / Central Belt: lat0 38°, lon0 127°, k0 1, FE 200 000, FN 500 000)
  /// → WGS84. Snyder의 역 Transverse Mercator 공식 (GRS80 ≈ WGS84, 차이 < 1 m).
  static GeoPoint tmToWgs84(double x, double y) {
    const a = 6378137.0;
    const f = 1 / 298.257222101;
    const k0 = 1.0;
    const lat0 = 38 * math.pi / 180;
    const lon0 = 127 * math.pi / 180;
    const fe = 200000.0;
    const fn = 500000.0;
    const e2 = f * (2 - f);
    final ep2 = e2 / (1 - e2);

    double meridian(double phi) =>
        a *
        ((1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256) * phi -
            (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * e2 * e2 * e2 / 1024) * math.sin(2 * phi) +
            (15 * e2 * e2 / 256 + 45 * e2 * e2 * e2 / 1024) * math.sin(4 * phi) -
            (35 * e2 * e2 * e2 / 3072) * math.sin(6 * phi));

    final m = meridian(lat0) + (y - fn) / k0;
    final mu = m / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256));
    final e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2));
    final phi1 =
        mu +
        (3 * e1 / 2 - 27 * math.pow(e1, 3) / 32) * math.sin(2 * mu) +
        (21 * e1 * e1 / 16 - 55 * math.pow(e1, 4) / 32) * math.sin(4 * mu) +
        (151 * math.pow(e1, 3) / 96) * math.sin(6 * mu) +
        (1097 * math.pow(e1, 4) / 512) * math.sin(8 * mu);

    final sin1 = math.sin(phi1);
    final cos1 = math.cos(phi1);
    final tan1 = math.tan(phi1);
    final n1 = a / math.sqrt(1 - e2 * sin1 * sin1);
    final t1 = tan1 * tan1;
    final c1 = ep2 * cos1 * cos1;
    final r1 = a * (1 - e2) / math.pow(1 - e2 * sin1 * sin1, 1.5);
    final d = (x - fe) / (n1 * k0);

    final lat =
        phi1 -
        (n1 * tan1 / r1) *
            (d * d / 2 -
                (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ep2) * math.pow(d, 4) / 24 +
                (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * ep2 - 3 * c1 * c1) * math.pow(d, 6) / 720);
    final lon =
        lon0 +
        (d -
                (1 + 2 * t1 + c1) * math.pow(d, 3) / 6 +
                (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ep2 + 24 * t1 * t1) * math.pow(d, 5) / 120) /
            cos1;
    return GeoPoint(lat * 180 / math.pi, lon * 180 / math.pi);
  }
}
