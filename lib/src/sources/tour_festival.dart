/// 한국관광공사 TourAPI 4.0 (KorService2) — 전국 축제·행사.
/// https://www.data.go.kr/data/15101578/openapi.do
/// 라이선스: 공공누리 (출처 표시 의무; 제3유형 — 이미지 변경 금지).
/// 순수 Dart — 수집 스크립트와 테스트에서 사용한다.
library;

import 'package:liferadar_core/liferadar_core.dart';
import 'seoul_culture.dart' show SourceException;
import 'tagger.dart';

class TourFestival {
  static const source = 'tour-festival';
  static const sourceName = '한국관광공사 TourAPI · 축제·행사';
  static const _base = 'https://apis.data.go.kr/B551011/KorService2';

  static Map<String, String> _common(String key) => {
        'serviceKey': key,
        'MobileOS': 'ETC',
        'MobileApp': 'LifeRadar',
        '_type': 'json',
      };

  /// [from] 이후 시작하는(또는 진행 중인) 축제 목록.
  static Uri listUri(String key, DateTime from, {int page = 1, int rows = 100}) =>
      Uri.parse('$_base/searchFestival2').replace(queryParameters: {
        ..._common(key),
        'eventStartDate': _ymd(from),
        'numOfRows': '$rows',
        'pageNo': '$page',
        'arrange': 'A',
      });

  /// 설명(overview)과 공식 사이트.
  static Uri commonUri(String key, String contentId) =>
      Uri.parse('$_base/detailCommon2').replace(queryParameters: {..._common(key), 'contentId': contentId});

  /// 시간, 장소, 요금, 프로그램.
  static Uri introUri(String key, String contentId) => Uri.parse('$_base/detailIntro2')
      .replace(queryParameters: {..._common(key), 'contentId': contentId, 'contentTypeId': '15'});

  /// 응답 → item 목록. 오류면 [SourceException].
  /// (결과가 하나여도 API는 목록을 반환하며, 결과가 없으면 `items` = "".)
  static List<Map<String, dynamic>> items(Map<String, dynamic> json) {
    final resp = json['response'] as Map<String, dynamic>?;
    if (resp == null) {
      final err = (json['OpenAPI_ServiceResponse'] as Map?)?['cmmMsgHeader'] as Map?;
      throw SourceException('$source: ${err?['returnAuthMsg'] ?? err?['errMsg'] ?? 'unknown response'}');
    }
    final header = resp['header'] as Map<String, dynamic>;
    if (header['resultCode'] != '0000') throw SourceException('$source: ${header['resultCode']} ${header['resultMsg']}');
    final items = (resp['body'] as Map<String, dynamic>?)?['items'];
    if (items is! Map) return const [];
    final item = items['item'];
    if (item is List) return [for (final i in item) (i as Map).cast<String, dynamic>()];
    if (item is Map) return [item.cast<String, dynamic>()];
    return const [];
  }

  static int totalCount(Map<String, dynamic> json) =>
      (((json['response'] as Map?)?['body'] as Map?)?['totalCount'] as num?)?.toInt() ?? 0;

  /// 목록 item (+ 선택적 상세 정보) → [RadarEvent]. 좌표·날짜가 없으면 null.
  static RadarEvent? parse(
    Map<String, dynamic> item, {
    Map<String, dynamic>? common,
    Map<String, dynamic>? intro,
  }) {
    String s(Map<String, dynamic>? m, String k) => m == null ? '' : _plain('${m[k] ?? ''}');

    final id = s(item, 'contentid');
    final title = s(item, 'title');
    final coord = koreaCoord(item['mapy'], item['mapx']);
    final startDay = _day(s(item, 'eventstartdate'));
    final endDay = _day(s(item, 'eventenddate')) ?? startDay;
    if (id.isEmpty || title.isEmpty || coord == null || startDay == null || endDay == null) return null;

    // playtime: "10:00~18:00", "18:00", "매일 11시~21시" ...
    final playtime = s(intro, 'playtime');
    final times = RegExp(r'(\d{1,2}):(\d{2})').allMatches(playtime).toList();
    DateTime at(DateTime d, RegExpMatch? m, int h) => m == null
        ? DateTime(d.year, d.month, d.day, h)
        : DateTime(d.year, d.month, d.day, int.parse(m[1]!).clamp(0, 23), int.parse(m[2]!).clamp(0, 59));
    final start = at(startDay, times.firstOrNull, 10);
    var end = at(endDay, times.length > 1 ? times[1] : null, 18);
    if (!end.isAfter(start)) end = start.add(const Duration(hours: 2));

    final overview = s(common, 'overview');
    final program = s(intro, 'program');
    final fee = s(intro, 'usetimefestival');
    final place = s(intro, 'eventplace');
    final addr = s(item, 'addr1');
    final homepage = _href('${intro?['eventhomepage'] ?? ''}') ?? _href('${common?['homepage'] ?? ''}');

    final description = [
      if (overview.isNotEmpty) overview,
      if (program.isNotEmpty) program,
      if (playtime.isNotEmpty) '시간: $playtime',
      if (fee.isNotEmpty) '요금: $fee',
    ].join('\n\n');

    return RadarEvent(
      id: 'tour-$id',
      title: LocalizedText(ko: title, en: title),
      description: LocalizedText(
        ko: _clip(description.isEmpty ? addr : description),
        en: _clip(description.isEmpty ? addr : description),
      ),
      category: EventCategory.festival,
      tags: tagsFor([title, overview, program], base: const ['culture', 'travel']),
      start: start,
      end: end,
      venue: place.isNotEmpty ? _clip(place, 80) : addr,
      city: cityOf(addr),
      location: GeoPoint(coord.lat, coord.lng),
      // 축제 공식 사이트 (신청 페이지가 아님).
      url: homepage,
      source: source,
      sourceName: sourceName,
      imageUrl: s(item, 'firstimage').isEmpty ? null : s(item, 'firstimage'),
      isFree: fee.isEmpty ? null : (fee.contains('무료') && !RegExp(r'\d+\s*원').hasMatch(fee)),
      price: fee.isEmpty ? null : _clip(fee, 80),
    );
  }

  /// "부산광역시 해운대구 APEC로 30" → "부산 해운대구", "충청남도 공주시 …" → "충남 공주시".
  static String cityOf(String addr) {
    final parts = addr.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    final first = parts.first;
    final province = _provinces[first] ??
        first.replaceAll(RegExp(r'(특별자치시|특별자치도|광역시|특별시)$'), '');
    final district = parts.length > 1 && RegExp(r'(시|군|구)$').hasMatch(parts[1]) ? ' ${parts[1]}' : '';
    return '$province$district';
  }

  static const _provinces = {
    '경기도': '경기',
    '강원도': '강원',
    '강원특별자치도': '강원',
    '충청북도': '충북',
    '충청남도': '충남',
    '전라북도': '전북',
    '전북특별자치도': '전북',
    '전라남도': '전남',
    '경상북도': '경북',
    '경상남도': '경남',
    '제주특별자치도': '제주',
    '제주도': '제주',
  };

  /// TourAPI 텍스트는 HTML(`<br>`, `<a href>`)이 섞여 온다.
  static String _plain(String raw) =>
      unescapeHtml(raw.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n').replaceAll(RegExp(r'<[^>]+>'), ''))
          .replaceAll(RegExp(r'\n{3,}'), '\n\n');

  static String? _href(String raw) {
    final m = RegExp(r'''href=["']([^"']+)''').firstMatch(raw) ?? RegExp(r'https?://[^\s"<>]+').firstMatch(raw);
    final url = m == null ? null : (m.groupCount >= 1 && m[1] != null ? m[1]! : m[0]!);
    return url != null && url.startsWith('http') ? url : null;
  }

  static DateTime? _day(String raw) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(raw);
    return m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  static String _ymd(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  static String _clip(String s, [int max = 600]) => s.length <= max ? s : '${s.substring(0, max - 1)}…';
}
