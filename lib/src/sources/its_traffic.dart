/// 국가교통정보센터(ITS) 돌발상황정보 — 전국 고속도로·국도·지방도의 공사·행사·기상·재난.
/// https://www.its.go.kr/opendata/ · 라이선스: 공공누리 — [sourceName].
/// 순수 Dart — 수집 스크립트와 테스트에서 사용한다.
library;

import 'package:liferadar_core/liferadar_core.dart';

import 'seoul_culture.dart' show SourceException;

class ItsTraffic {
  static const source = 'its';
  static const sourceName = '국가교통정보센터(ITS) · 돌발상황정보';
  static const sourceUrl = 'https://www.its.go.kr';

  static Uri uri(String key) => Uri.parse(
        'https://openapi.its.go.kr:9443/eventInfo?apiKey=$key&type=all&eventType=all&getType=json',
      );

  /// 일정과 관련 있는 유형만. 정체·고장·사고처럼 짧은 돌발은 3시간 수집 주기에 맞지 않아 낡은
  /// 정보가 되므로 제외한다. 이동 중인 도로 작업(`작업`)은 종료 시각이 있을 때만 받는다.
  static TrafficKind? kindOf(String eventType, String detail, {required bool hasEnd}) => switch (eventType) {
        '기상' => TrafficKind.weather,
        '재난' => TrafficKind.other,
        '공사' when detail == '작업' && !hasEnd => null,
        '공사' => TrafficKind.construction,
        _ when detail == '이벤트/홍보' => TrafficKind.event,
        _ => null,
      };

  /// JSON 응답 → 항목 목록. 오류 코드면 [SourceException].
  static List<Map<String, dynamic>> rows(Map<String, dynamic> json) {
    final header = json['header'] as Map<String, dynamic>?;
    final code = header?['resultCode'];
    if (code != 0 && code != '0') {
      throw SourceException('$source: $code ${header?['resultMsg'] ?? 'unknown response'}');
    }
    final body = json['body'] as Map<String, dynamic>?;
    return [for (final i in (body?['items'] as List? ?? const [])) (i as Map).cast<String, dynamic>()];
  }

  /// 항목 하나 → [TrafficNotice]. 대상 유형이 아니거나 위치·시작 시각이 없으면 null.
  static TrafficNotice? parse(Map<String, dynamic> r) {
    String s(String k) => '${r[k] ?? ''}'.trim();
    final start = _at(s('startDate'));
    final end = _at(s('endDate'));
    final kind = kindOf(s('eventType'), s('eventDetailType'), hasEnd: end != null);
    final lng = double.tryParse(s('coordX'));
    final lat = double.tryParse(s('coordY'));
    if (kind == null || start == null || lat == null || lng == null) return null;
    if (lat < 33 || lat > 39 || lng < 124 || lng > 132) return null; // 한국 범위 밖 좌표

    final road = s('roadName');
    final what = [s('eventType'), s('eventDetailType')].where((x) => x.isNotEmpty).toSet().join(' · ');
    final title = road.isEmpty ? what : '[$road] $what';
    final lanes = s('lanesBlocked');
    final detail = [
      title,
      if (s('message').isNotEmpty) s('message'),
      if (lanes.isNotEmpty) '차단 차로: $lanes',
    ].join('\n');
    return TrafficNotice(
      id: 'its-${s('linkId')}-${s('startDate')}',
      kind: kind,
      title: title,
      detail: detail,
      start: start,
      // 출처에서 종료가 시작보다 앞서면 잘못된 값 — 추정하지 않는다.
      end: end != null && end.isAfter(start) ? end : null,
      location: GeoPoint(lat, lng),
      source: source,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
    );
  }

  /// "20261108142724" → 현지(KST) 시각. 형식이 다르면 null.
  static DateTime? _at(String v) {
    if (!RegExp(r'^\d{12,14}$').hasMatch(v)) return null;
    final t = v.padRight(14, '0');
    int p(int a, int b) => int.parse(t.substring(a, b));
    return DateTime(p(0, 4), p(4, 6), p(6, 8), p(8, 10), p(10, 12), p(12, 14));
  }
}
