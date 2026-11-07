/// 서울시 문화행사 정보 (서울 열린데이터광장, `culturalEventInfo`).
/// https://data.seoul.go.kr/dataList/OA-15486/S/1/datasetView.do
/// 라이선스: 공공누리 (출처 표시 의무) — [sourceName].
/// 순수 Dart — 수집 스크립트와 테스트에서 사용한다.
library;

import 'package:liferadar_core/liferadar_core.dart';
import 'tagger.dart';

class SeoulCulture {
  static const source = 'seoul-culture';
  static const sourceName = '서울 열린데이터광장 · 서울시 문화행사';

  /// 요청당 최대 1000행. 키: data.seoul.go.kr → 인증키 신청 ('sample' = 5행).
  static Uri pageUri(String key, int from, int to) =>
      Uri.parse('http://openapi.seoul.go.kr:8088/$key/json/culturalEventInfo/$from/$to/');

  /// 응답 → 행 목록. 오류 코드면 [SourceException].
  static List<Map<String, dynamic>> rows(Map<String, dynamic> json) {
    final root = json['culturalEventInfo'] as Map<String, dynamic>?;
    final result = (root?['RESULT'] ?? json['RESULT']) as Map<String, dynamic>?;
    final code = result?['CODE'] as String? ?? '';
    if (code == 'INFO-200') return const []; // 데이터 없음
    if (root == null || !code.startsWith('INFO-000')) {
      throw SourceException('$source: $code ${result?['MESSAGE'] ?? ''}'.trim());
    }
    return [for (final r in (root['row'] as List? ?? const [])) (r as Map).cast<String, dynamic>()];
  }

  static int totalCount(Map<String, dynamic> json) =>
      ((json['culturalEventInfo'] as Map?)?['list_total_count'] as num?)?.toInt() ?? 0;

  /// 행 하나 → [RadarEvent]. 좌표나 날짜가 없으면 null.
  static RadarEvent? parse(Map<String, dynamic> r) {
    String s(String k) => unescapeHtml('${r[k] ?? ''}');

    final title = s('TITLE');
    final coord = koreaCoord(r['LAT'], r['LOT']);
    final startDay = _day(s('STRTDATE'));
    final endDay = _day(s('END_DATE')) ?? startDay;
    if (title.isEmpty || coord == null || startDay == null || endDay == null) return null;

    // PRO_TIME은 자유 형식 텍스트: "19:30", "화 19:30", "10:00~18:00", "매일 10시~18시"...
    final times = RegExp(r'(\d{1,2}):(\d{2})').allMatches(s('PRO_TIME')).toList();
    DateTime at(DateTime d, RegExpMatch? m, int fallbackHour) => m == null
        ? DateTime(d.year, d.month, d.day, fallbackHour)
        : DateTime(d.year, d.month, d.day, int.parse(m[1]!).clamp(0, 23), int.parse(m[2]!).clamp(0, 59));
    final start = at(startDay, times.firstOrNull, 10);
    // 종료 시각이 없으면: 하루 행사 → 시작 + 2시간, 여러 날 행사 → 마지막 날 18:00.
    var end = times.length > 1
        ? at(endDay, times[1], 18)
        : times.isNotEmpty && endDay == startDay
            ? start.add(const Duration(hours: 2))
            : at(endDay, null, times.isEmpty ? 18 : (start.hour + 2).clamp(0, 23));
    if (!end.isAfter(start)) end = start.add(const Duration(hours: 2));

    final codename = s('CODENAME');
    final (category, baseTags) = _category(codename);
    final program = s('PROGRAM');
    final target = s('USE_TRGT');
    final fee = s('USE_FEE');
    final themes = s('THEMECODE');
    final link = s('HMPG_ADDR');
    final orgLink = s('ORG_LINK');
    final cultcode = Uri.tryParse(link)?.queryParameters['cultcode'];

    final details = [
      if (program.isNotEmpty) program,
      if (s('PLAYER').isNotEmpty) '출연: ${s('PLAYER')}',
      if (target.isNotEmpty) '대상: $target',
      if (fee.isNotEmpty) '요금: $fee',
    ].join('\n');
    final description = details.isEmpty ? '$codename · ${s('PLACE')}' : details;
    final free = switch (s('IS_FREE')) { '무료' => true, '유료' => false, _ => null };

    return RadarEvent(
      id: 'seoul-${cultcode ?? '${title.hashCode.toUnsigned(32)}-${startDay.toIso8601String().substring(0, 10)}'}',
      // 영어 번역이 없으므로 두 언어 모두 원래(한국어) 이름.
      title: LocalizedText(ko: title, en: title),
      description: LocalizedText(ko: _clip(description), en: _clip(description)),
      category: category,
      // 관람 대상(USE_TRGT)은 "가족"에만 사용: "청소년 관람가" 같은 문구가 태그를 만들지 않도록.
      tags: tagsFor(
        [title, program, codename],
        base: [...baseTags, if (RegExp('어린이|가족|유아|키즈').hasMatch('$target $themes')) 'family'],
      ),
      start: start,
      end: end,
      venue: s('PLACE'),
      city: s('GUNAME').isEmpty ? '서울' : '서울 ${s('GUNAME')}',
      location: GeoPoint(coord.lat, coord.lng),
      url: link.isEmpty ? null : link,
      registerUrl: orgLink.isEmpty ? null : orgLink,
      source: source,
      sourceName: sourceName,
      imageUrl: s('MAIN_IMG').isEmpty ? null : s('MAIN_IMG'),
      isFree: free,
      price: fee.isEmpty ? null : _clip(fee, 80),
    );
  }

  static DateTime? _day(String raw) {
    final m = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(raw);
    return m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  static String _clip(String s, [int max = 400]) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

  /// 분류(CODENAME) → 카테고리 + 기본 태그.
  static (EventCategory, List<String>) _category(String c) => switch (c) {
        '콘서트' => (EventCategory.concert, ['music']),
        '클래식' || '국악' || '독주/독창회' => (EventCategory.concert, ['music', 'culture']),
        '뮤지컬/오페라' => (EventCategory.performance, ['music', 'culture']),
        '연극' => (EventCategory.performance, ['culture']),
        '무용' => (EventCategory.performance, ['culture', 'art']),
        '영화' => (EventCategory.performance, ['movie']),
        '전시/미술' => (EventCategory.exhibition, ['art', 'culture']),
        '교육/체험' => (EventCategory.classes, ['culture']), // 주제는 키워드에서 (강연→books, 영화→movie...)
        '축제-자연/경관' => (EventCategory.festival, ['culture', 'outdoor', 'travel']),
        '축제-전통/역사' => (EventCategory.festival, ['culture', 'travel']),
        _ when c.startsWith('축제') => (EventCategory.festival, ['culture']),
        _ => (EventCategory.festival, ['culture']),
      };
}

class SourceException implements Exception {
  const SourceException(this.message);
  final String message;
  @override
  String toString() => message;
}
