/// 창업진흥원 K-Startup 사업공고 (공공데이터포털 15125364).
/// https://www.data.go.kr/data/15125364/openapi.do
/// 행사가 아니라 접수 기간이 있는 공고: [RadarEvent.placeless] = true, start–end = 접수 기간.
/// 순수 Dart — 수집 스크립트와 테스트에서 사용한다.
library;

import 'package:liferadar_core/liferadar_core.dart';
import 'seoul_culture.dart' show SourceException;
import 'tagger.dart';

class KStartup {
  static const source = 'kstartup';
  static const sourceName = '창업진흥원 K-Startup · 사업공고';

  /// 접수 진행 중인 공고만 (`rcrt_prgs_yn = Y`).
  static Uri listUri(String key, {int page = 1, int perPage = 500}) => Uri.parse(
        'https://apis.data.go.kr/B552735/kisedKstartupService01/getAnnouncementInformation01',
      ).replace(queryParameters: {
        'serviceKey': key,
        'page': '$page',
        'perPage': '$perPage',
        'returnType': 'json',
        'cond[rcrt_prgs_yn::EQ]': 'Y',
      });

  static List<Map<String, dynamic>> rows(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is List) return [for (final r in data) (r as Map).cast<String, dynamic>()];
    final err = (json['OpenAPI_ServiceResponse'] as Map?)?['cmmMsgHeader'] as Map?;
    throw SourceException('$source: ${err?['returnAuthMsg'] ?? json['msg'] ?? 'unknown response'}');
  }

  static int matchCount(Map<String, dynamic> json) => (json['matchCount'] as num?)?.toInt() ?? 0;

  static RadarEvent? parse(Map<String, dynamic> r) {
    String s(String k) => unescapeHtml('${r[k] ?? ''}');

    final sn = s('pbanc_sn');
    final title = s('biz_pbanc_nm').isNotEmpty ? s('biz_pbanc_nm') : s('intg_pbanc_biz_nm');
    final from = _day(s('pbanc_rcpt_bgng_dt'));
    final to = _day(s('pbanc_rcpt_end_dt'));
    if (sn.isEmpty || title.isEmpty || to == null) return null;

    final region = s('supt_regin').isEmpty ? '전국' : s('supt_regin');
    final field = s('supt_biz_clsfc');
    final content = s('pbanc_ctnt');
    final target = s('aply_trgt_ctnt').isNotEmpty ? s('aply_trgt_ctnt') : s('aply_trgt');
    final stage = s('biz_enyy');
    final apply = _url(s('aply_mthd_onli_rcpt_istc')) ?? _url(s('biz_aply_url')) ?? _url(s('biz_gdnc_url'));

    final description = [
      if (content.isNotEmpty) content,
      if (field.isNotEmpty) '분야: $field',
      if (target.isNotEmpty) '대상: $target',
      if (stage.isNotEmpty) '업력: $stage',
    ].join('\n\n');

    final center = _regionCenter[region] ?? _regionCenter['서울']!;
    return RadarEvent(
      id: 'kstartup-$sn',
      title: LocalizedText(ko: title, en: title),
      description: LocalizedText(ko: _clip(description), en: _clip(description)),
      category: EventCategory.startupSupport,
      tags: tagsFor(
        [title, content, field],
        base: [
          'startup',
          if (field.contains('행사') || field.contains('네트워크')) 'networking',
          if (field.contains('인력')) 'career',
        ],
      ),
      start: from ?? to,
      end: DateTime(to.year, to.month, to.day, 23, 59),
      venue: s('pbanc_ntrp_nm'),
      city: region,
      location: center,
      url: _url(s('detl_pg_url')),
      registerUrl: apply,
      deadline: to,
      source: source,
      sourceName: sourceName,
      placeless: true,
    );
  }

  static String? _url(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('http')) return t;
    // "forms.gle/xxx"처럼 scheme이 없는 링크.
    return RegExp(r'^[\w.-]+\.[a-z]{2,}/').hasMatch(t) ? 'https://$t' : null;
  }

  static DateTime? _day(String raw) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(raw);
    return m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  static String _clip(String s, [int max = 600]) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

  /// 지역 중심 (시·도청 위치). 내부 정렬용일 뿐 — 지도에 표시하지 않는다.
  static const _regionCenter = {
    '서울': GeoPoint(37.5665, 126.9780),
    '부산': GeoPoint(35.1796, 129.0756),
    '대구': GeoPoint(35.8714, 128.6014),
    '인천': GeoPoint(37.4563, 126.7052),
    '광주': GeoPoint(35.1595, 126.8526),
    '대전': GeoPoint(36.3504, 127.3845),
    '울산': GeoPoint(35.5384, 129.3114),
    '세종': GeoPoint(36.4800, 127.2890),
    '경기': GeoPoint(37.2752, 127.0095),
    '강원': GeoPoint(37.8813, 127.7298),
    '충북': GeoPoint(36.6424, 127.4890),
    '충남': GeoPoint(36.6588, 126.6728),
    '전북': GeoPoint(35.8242, 127.1480),
    '전남': GeoPoint(34.8161, 126.4629),
    '경북': GeoPoint(36.5760, 128.5056),
    '경남': GeoPoint(35.2383, 128.6924),
    '제주': GeoPoint(33.4996, 126.5312),
  };
}
