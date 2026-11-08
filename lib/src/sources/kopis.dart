/// KOPIS 공연예술통합전산망 — 전국 공연 (콘서트·클래식·연극·뮤지컬·무용·국악).
/// https://www.kopis.or.kr/por/cs/openapi/openApiInfo.do · 출처 표시: [sourceName].
///
/// 서울 공연은 서울시 문화행사 데이터에 이미 들어 있어, 이 수집기는 **서울 밖 지역**만 받는다
/// (중복 없이 다른 도시의 공연을 채운다). 순수 Dart — 수집 스크립트와 테스트에서 사용한다.
library;

import 'package:liferadar_core/liferadar_core.dart';

import 'seoul_culture.dart' show SourceException;
import 'tagger.dart';

class Kopis {
  static const source = 'kopis';
  static const sourceName = 'KOPIS 공연예술통합전산망';
  static const _base = 'http://www.kopis.or.kr/openApi/restful';

  /// 공연 목록 (기간 내, 공연예정·공연중).
  static Uri listUri(String key, DateTime from, DateTime to, {int page = 1, int rows = 100}) =>
      Uri.parse('$_base/pblprfr?service=$key&stdate=${_ymd(from)}&eddate=${_ymd(to)}&cpage=$page&rows=$rows');

  /// 공연 상세 (요금, 공연 시간, 출연진, 공연장 id).
  static Uri detailUri(String key, String id) => Uri.parse('$_base/pblprfr/$id?service=$key');

  /// 공연장 (주소, 좌표).
  static Uri facilityUri(String key, String id) => Uri.parse('$_base/prfplc/$id?service=$key');

  /// XML의 `<db>` 블록 → 필드 맵 목록. KOPIS는 오류일 때 `<returncode>`를 준다.
  static List<Map<String, String>> rows(String xml) {
    final err = RegExp(r'<returncode>([^<]*)</returncode>').firstMatch(xml);
    if (err != null && err.group(1) != '00') {
      final msg = RegExp(r'<errmsg>([^<]*)</errmsg>').firstMatch(xml)?.group(1) ?? '';
      throw SourceException('$source: ${err.group(1)} $msg'.trim());
    }
    return [
      for (final db in RegExp(r'<db>(.*?)</db>', dotAll: true).allMatches(xml))
        {
          for (final f in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(db.group(1)!)) f.group(1)!: unescapeHtml(f.group(2)!),
        },
    ];
  }

  static bool isSeoul(Map<String, String> listRow) => (listRow['area'] ?? '').startsWith('서울');

  /// 목록 + 상세 + 공연장 → [RadarEvent]. 날짜·좌표가 없으면 null.
  static RadarEvent? parse(Map<String, String> detail, Map<String, String>? facility) {
    String s(Map<String, String>? m, String k) => (m?[k] ?? '').trim();
    final id = s(detail, 'mt20id');
    final title = s(detail, 'prfnm');
    final from = _day(s(detail, 'prfpdfrom'));
    final to = _day(s(detail, 'prfpdto')) ?? from;
    final lat = double.tryParse(s(facility, 'la'));
    final lng = double.tryParse(s(facility, 'lo'));
    if (id.isEmpty || title.isEmpty || from == null || to == null || lat == null || lng == null) return null;
    if (lat < 33 || lat > 39 || lng < 124 || lng > 132) return null;

    final genre = s(detail, 'genrenm');
    final category = switch (genre) {
      '대중음악' || '서양음악(클래식)' || '한국음악(국악)' => EventCategory.concert,
      _ => EventCategory.performance,
    };
    // 공연 시간: "수요일(19:30)" 같은 안내에서 첫 시각. 없으면 날짜만 (00:00 → 화면에 날짜만 표시).
    final time = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(s(detail, 'dtguidance'));
    final start = time == null
        ? from
        : DateTime(from.year, from.month, from.day, int.parse(time[1]!).clamp(0, 23), int.parse(time[2]!).clamp(0, 59));
    final end = DateTime(to.year, to.month, to.day, 23, 59);

    final price = s(detail, 'pcseguidance');
    final cast = s(detail, 'prfcast');
    final runtime = s(detail, 'prfruntime');
    final age = s(detail, 'prfage');
    final description = [
      if (genre.isNotEmpty) genre,
      if (cast.isNotEmpty) '출연: $cast',
      if (runtime.isNotEmpty) '공연 시간: $runtime',
      if (age.isNotEmpty) '관람 연령: $age',
      if (s(detail, 'dtguidance').isNotEmpty) '공연 일정: ${s(detail, 'dtguidance')}',
    ].join(' · ');

    final venue = s(detail, 'fcltynm');
    final area = s(detail, 'area').isNotEmpty ? s(detail, 'area') : s(facility, 'adres').split(' ').first;
    final related = s(detail, 'relateurl');
    final base = <String>{
      if (category == EventCategory.concert) 'music',
      if (genre.contains('뮤지컬')) 'music',
      'culture',
    };
    return RadarEvent(
      id: '$source-$id',
      title: LocalizedText(ko: title, en: title),
      description: LocalizedText(ko: description, en: description),
      category: category,
      tags: tagsFor([title, genre], base: base.toList()),
      start: start,
      end: end,
      venue: venue,
      city: area,
      location: GeoPoint(lat, lng),
      url: related.startsWith('http')
          ? related
          : 'https://www.kopis.or.kr/por/db/pblprfr/pblprfrView.do?menuId=MNU_00020&mt20Id=$id',
      source: source,
      sourceName: sourceName,
      imageUrl: _https(s(detail, 'poster')),
      isFree: price.isEmpty ? null : (price.contains('무료') && !RegExp(r'\d[\d,]*\s*원').hasMatch(price)),
      price: price.isEmpty ? null : price,
    );
  }

  /// KOPIS 이미지는 http로 오며 Android·웹에서 막힌다 → 같은 경로의 https (kopis.or.kr, www 없이).
  static String? _https(String url) {
    if (url.isEmpty) return null;
    return url.replaceFirst(RegExp(r'^https?://(www\.)?kopis\.or\.kr'), 'https://kopis.or.kr');
  }

  static DateTime? _day(String v) {
    final m = RegExp(r'^(\d{4})\.(\d{2})\.(\d{2})$').firstMatch(v);
    return m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  static String _ymd(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
}
