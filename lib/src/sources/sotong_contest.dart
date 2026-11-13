/// 소통24 화면의 공개 HTML 조회 경로. 공식 OpenAPI가 아니다.
/// 재이용/정기 수집 조건 미확인: 운영 수집 기본 비활성, ops/SOTONG.md 참고.
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:liferadar_core/liferadar_core.dart';

class SotongListPage {
  const SotongListPage(this.rows, this.lastPage);
  final List<Map<String, dynamic>> rows;
  final int lastPage;
}

abstract final class SotongContest {
  static const source = 'sotong-contest';
  static const name = '소통24 공모전';
  static const parserVersion = 2;
  static final origin = Uri.parse('https://modu.go.kr');
  static final initialUri = origin.resolve('/front/epilogue/epilogueNewListPage.do?menu_id=527&pagetype=bbs');
  static final listUri = origin.resolve('/front/epilogue/epilogueNewList.do');
  static String detailUrl(String id) =>
      origin.resolve('/front/epilogue/epilogueNewViewPage.do?menu_id=527&bbs_id=$id&pagetype=bbs').toString();
  static String clean(String? text) => (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  static String hash(String text) => sha256.convert(utf8.encode(text)).toString();

  static Map<String, String> form(String raw) {
    final doc = html.parse(raw);
    final f = doc.querySelector('form#bbsListFrm');
    if (f == null) throw const FormatException('소통24 bbsListFrm missing (HTML changed or blocked)');
    final out = <String, String>{};
    for (final e in f.querySelectorAll('input[name], select[name], textarea[name]')) {
      if (e.attributes.containsKey('disabled')) continue;
      if (['radio', 'checkbox'].contains(e.attributes['type']) && !e.attributes.containsKey('checked')) continue;
      out[e.attributes['name']!] = e.localName == 'select'
          ? e.querySelector('option[selected]')?.attributes['value'] ??
                e.querySelector('option')?.attributes['value'] ??
                ''
          : e.attributes['value'] ?? '';
    }
    // Same tab and default page size (9 cards) observed in the public UI.
    out.addAll({'pagetype': 'bbs', 'menu_id': '527', 'miv_pageSize': '9'});
    return out;
  }

  static SotongListPage list(String raw, int page) {
    final doc = html.parse(raw);
    final list = doc.querySelector('.bs_card_line');
    if (list == null) throw const FormatException('소통24 bs_card_line missing');
    final rows = <Map<String, dynamic>>[];
    for (final card in list.querySelectorAll('li.thm_card')) {
      final a = card.querySelector('a[href*="epilogueNewViewPage.do"]');
      final id = a == null ? null : origin.resolve(a.attributes['href']!).queryParameters['bbs_id'];
      final title = clean(card.querySelector('.ac_title')?.text).replaceFirst(RegExp(r'^【[^】]*】\s*'), '');
      if (id == null || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id) || title.isEmpty) {
        throw const FormatException('소통24 card fields changed');
      }
      rows.add({
        'sourceId': id,
        'title': title,
        'organizer': clean(card.querySelector('.ac_instt')?.text),
        'rawPeriod': clean(card.querySelector('.ac_period')?.text),
        'rawStatus': clean(card.querySelector('.lf_t')?.text),
        'sourceUrl': detailUrl(id),
      });
    }
    // Never interpret empty/selector-changed markup as a valid zero result.
    if (rows.isEmpty) throw const FormatException('소통24 empty/unverified page');
    final pages = <int>[];
    for (final a in doc.querySelectorAll('a[href]')) {
      if (!a.classes.contains('url-paging') && !RegExp(r'^\d+$').hasMatch(clean(a.text))) continue;
      final n = int.tryParse(origin.resolve(a.attributes['href']!).queryParameters['miv_pageNo'] ?? '');
      if (n != null) pages.add(n);
    }
    // Last-page link is required when a page is full; unknown termination is partial.
    final lastLinks = doc.querySelectorAll('a.btn-paging-last[href]');
    final last = lastLinks.isNotEmpty
        ? int.tryParse(origin.resolve(lastLinks.first.attributes['href']!).queryParameters['miv_pageNo'] ?? '')
        : pages.isNotEmpty
        ? (pages..sort()).last
        : rows.length < 9
        ? page
        : null;
    if (last == null || last < page) throw const FormatException('소통24 pagination changed');
    return SotongListPage(rows, last);
  }

  /// Text block boundaries are significant: labels may be in a separate p or a
  /// table cell. No scripts, forms, personal contacts or whole HTML in state.
  static String bodyText(Element body) {
    final clone = body.clone(true);
    for (final e in clone.querySelectorAll('script,style,form,input,button')) {
      e.remove();
    }
    for (final e in clone.querySelectorAll('br')) {
      e.replaceWith(Text('\n'));
    }
    for (final e in clone.querySelectorAll('p,div,tr,li,h1,h2,h3,h4')) {
      e.append(Text('\n'));
    }
    return clone.text.split('\n').map(clean).where((s) => s.isNotEmpty).join('\n');
  }

  static final _labels = RegExp(
    r'(공모\s*접수\s*기간|접수\s*기간|응모\s*기간|신청\s*기간|공모\s*기간|참여\s*대상|참가\s*자격|응모\s*자격|공모\s*자격|응모\s*대상|공모\s*대상|참가\s*대상|지원\s*자격|공고\s*기간|결과\s*발표|시상\s*(?:규모|내역|:)|제출\s*방법|참여\s*방법|공모\s*방법|공모\s*주제|공모\s*내용|공모\s*분야|공모\s*과제|작품\s*규격|접수\s*방법|유의\s*사항|공모\s*일정|참가비|참여비|접수비|지역\s*제한)',
  );

  static String? section(String text, String label) {
    final match = RegExp(label).firstMatch(text);
    if (match == null) return null;
    var rest = text.substring(match.end);
    final next = _labels.firstMatch(rest);
    if (next != null) rest = rest.substring(0, next.start);
    // Numbered headings terminate qualifications (e.g. 4. 공모 일정).
    rest = rest.split(RegExp(r'\n\d{1,2}\.\s+(?=[가-힣])')).first;
    rest = rest
        .split('\n')
        .where(
          (line) =>
              !RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|0\d{1,3}[-)]\s*\d{3,4}-\d{4}').hasMatch(line),
        )
        .join('\n');
    final value = rest.replaceFirst(RegExp(r'^[\s:：)]+'), '').replaceFirst(RegExp(r'\n(?:[□○❍ㅇ]|\d{1,2}\.)\s*$'), '').trim();
    return value.isEmpty ? null : value;
  }

  static Map<String, dynamic> detail(Map<String, dynamic> row, String raw, DateTime now) {
    final doc = html.parse(raw);
    final body = doc.querySelector('.editor-content');
    if (body == null) throw const FormatException('소통24 editor-content missing');
    final returnedId = doc.querySelector('input[name="bbs_id"]')?.attributes['value'];
    if (returnedId != null && returnedId.isNotEmpty && returnedId != row['sourceId']) {
      throw const FormatException('Sotong detail ID mismatch');
    }
    final text = bodyText(body);
    final title = row['title'] as String;
    final issues = <String>[];
    var organizer = row['organizer'] as String;
    for (final li in doc.querySelectorAll('.t_texts li')) {
      if (clean(li.text).startsWith('기관명')) organizer = clean(li.querySelector('span')?.text);
    }
    final explicitPeriod = section(text, r'(?:접수|응모|신청)\s*기간');
    // Body 공모기간 is accepted only together with explicit submission guidance.
    // The list's display period is never an application-period fallback.
    final submissionEvidence = RegExp(r'(?:제출|접수|신청|응모|공모)\s*방법|공모전\s*신청').hasMatch(text);
    final period = explicitPeriod ?? (submissionEvidence ? section(text, r'공모\s*기간') : null);
    final dates = period == null ? null : dateRange(period);
    if (dates == null) issues.add('explicit_application_period_missing_or_ambiguous');
    final eligibility = section(text, r'(?:참여\s*대상|참가\s*자격|응모\s*자격|공모\s*자격|응모\s*대상|공모\s*대상|참가\s*대상|지원\s*자격)');
    final studentOnly =
        eligibility != null &&
        RegExp(r'초등|중학생|고등학생|공무원').hasMatch(eligibility) &&
        !RegExp(r'대학생|국민\s*누구나|일반부').hasMatch(eligibility);
    final audience = eligibility == null
        ? 'unknown'
        : studentOnly
        ? 'restricted'
        : RegExp(r'전문가|교원|공무원\s*(?:전용|대상|한정)|(?:초|중|고등)학생\s*(?:전용|만|한정)|거주자|재직자|자격증|전공자').hasMatch(eligibility)
        ? 'restricted'
        : RegExp(r'대학(?:교)?생|대학원생|재학생|휴학생').hasMatch(eligibility)
        ? 'university'
        : RegExp(r'누구나|전\s*국민|일반\s*국민').hasMatch(eligibility)
        ? 'general'
        : 'restricted';
    if (audience == 'unknown') issues.add('eligibility_unconfirmed');
    final kind = RegExp(r'해커톤|hackathon', caseSensitive: false).hasMatch(title)
        ? 'hackathon'
        : RegExp(r'공모|경진대회|콘테스트|아이디어\s*발굴대회').hasMatch(title)
        ? 'contest'
        : 'other';
    final excluded = kind == 'other' || RegExp(r'채용|명예감시원|결과\s*발표|수상작\s*(?:발표|공개)|수상후보작').hasMatch(title);
    // Warnings such as "표절 시 수상 취소" must not cancel a live competition.
    final cancelled =
        RegExp(
          r'(?:공모전|공모|접수|행사)\s*(?:가\s*|를\s*|이\s*)?(?:취소되었|취소합니다|취소\s*안내|취소\s*공고|중단합니다|중단되었습니다)',
        ).hasMatch('$title\n$text') ||
        title.contains('[취소]');
    final start = dates?.$1;
    final end = dates?.$2;
    final precision = dates?.$3 ?? 'unknown';
    final boundary = end == null
        ? null
        : precision == 'date'
        ? DateTime.utc(end.year, end.month, end.day + 1).subtract(const Duration(hours: 9))
        : end.toUtc();
    final startBoundary = start == null
        ? null
        : dates!.$4
        ? start.toUtc()
        : DateTime.utc(start.year, start.month, start.day).subtract(const Duration(hours: 9));
    final status = cancelled
        ? 'cancelled'
        : boundary == null
        ? 'unknown'
        : !now.toUtc().isBefore(boundary)
        ? 'closed'
        : now.toUtc().isBefore(startBoundary!)
        ? 'upcoming'
        : 'open';
    String? apply;
    for (final a in doc.querySelectorAll('.url-li a[href], .editor-content a[href]')) {
      if (!RegExp(r'온라인접수|접수\s*(?:바로가기|하기)|신청\s*(?:바로가기|하기)').hasMatch('${a.text} ${a.attributes['title']}')) continue;
      final uri = Uri.tryParse(a.attributes['href'] ?? '');
      if (uri != null &&
          ['https', 'http'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !RegExp(r'login|signin', caseSensitive: false).hasMatch(uri.path)) {
        apply = uri.toString();
        break;
      }
    }
    final fee = section(text, r'(?:참가비|참여비|접수비)');
    final feeText = fee?.split('\n').first;
    final isFree = feeText == null
        ? null
        : RegExp(r'무료|없음|(?<![0-9])0\s*원').hasMatch(feeText)
        ? true
        : RegExp(r'\d[\d,]*\s*원').hasMatch(feeText)
        ? false
        : null;
    final region = section(text, r'지역\s*제한');
    final regionText = region?.split('\n').first;
    final city = eligibility != null && RegExp(r'전국|대한민국\s*국민|국민\s*누구나|국내\s*거주').hasMatch(eligibility)
        ? '전국'
        : regionText ?? '미확인';
    final mode = RegExp(r'(?:제출방법|접수방법)\s*[:：]?\s*온라인|이메일.*접수').hasMatch(text) ? 'online' : 'unknown';
    if (organizer.isEmpty) issues.add('organizer_unconfirmed');
    final result = <String, dynamic>{
      ...row,
      'id': '$source-${row['sourceId']}',
      'source': source,
      'organizer': organizer,
      'applicationStart': start?.toIso8601String(),
      'applicationEnd': end?.toIso8601String(),
      'deadlinePrecision': precision,
      'applicationStatus': status,
      'eligibilityText': eligibility,
      'eligibilityEvidence': eligibility,
      'audience': audience,
      'dateEvidence': period,
      'dateRule': explicitPeriod != null ? 'explicit-application-period' : 'body-contest-period-with-submission-guidance',
      'regionText': regionText,
      'city': city,
      'participationMode': mode,
      'kind': kind,
      'applyUrl': apply,
      'fee': feeText,
      'isFree': isFree,
      'summary': [
        title,
        organizer,
        if (eligibility != null) '참가자격: $eligibility',
        if (period != null) '접수기간: $period',
      ].join('\n'),
      'lastVerifiedAt': now.toUtc().toIso8601String(),
      'contentHash': hash('$title|$organizer|$text|$apply'),
      'parserVersion': parserVersion,
      'publishability': excluded
          ? 'excluded'
          : issues.isEmpty && !cancelled
          ? 'ready'
          : 'review',
      'issues': issues,
    };
    return result;
  }

  /// Strict explicit ranges only. Supports a second endpoint with omitted year,
  /// apostrophe years, weekdays and 16시/17:00. No guessed year or cross-year rollover.
  static (DateTime, DateTime, String, bool)? dateRange(String raw) {
    final s = raw.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    final parts = s.split(RegExp(r'[~∼～]'));
    if (parts.length != 2) return null;
    final a = _date(parts[0]);
    final b = _date(parts[1], year: a?.$1.year);
    if (a == null || b == null || b.$1.isBefore(a.$1)) return null;
    return (a.$1, b.$1, b.$2 ? 'datetime' : 'date', a.$2);
  }

  static (DateTime, bool)? _date(String text, {int? year}) {
    final re = RegExp(
      r"(?:(\d{4}|['’]\d{2})\s*[.년/\-]\s*)?(\d{1,2})\s*[.월/\-]\s*(\d{1,2})\s*(?:[.일])?(?:\s*\*?\s*(\d{1,2})\s*(?::\s*(\d{2})|시(?:\s*(\d{1,2})분)?))?",
    );
    final m = re.firstMatch(text);
    if (m == null) return null;
    final y = m[1] == null ? year : int.parse(m[1]!.replaceAll(RegExp("['’]"), '')) + (m[1]!.length == 3 ? 2000 : 0);
    if (y == null) return null;
    final month = int.parse(m[2]!);
    final day = int.parse(m[3]!);
    final explicitDeadline = RegExp(r'마감일\s*기준\s*(\d{1,2}):(\d{2})').firstMatch(text.substring(m.end));
    final hour = int.tryParse(m[4] ?? explicitDeadline?[1] ?? '') ?? 0;
    final minute = int.tryParse(m[5] ?? m[6] ?? explicitDeadline?[2] ?? '') ?? 0;
    final check = DateTime.utc(y, month, day, hour, minute);
    if (check.year != y || check.month != month || check.day != day || hour > 23 || minute > 59) return null;
    final timed = m[4] != null || explicitDeadline != null;
    return (timed ? check.subtract(const Duration(hours: 9)) : DateTime(y, month, day), timed);
  }

  static RadarEvent? event(Map<String, dynamic> r, DateTime now) {
    if (r['publishability'] != 'ready' || !['open', 'upcoming'].contains(r['applicationStatus'])) return null;
    final start = DateTime.parse(r['applicationStart'] as String);
    final end = DateTime.parse(r['applicationEnd'] as String);
    final e = RadarEvent(
      id: '$source-${r['sourceId']}',
      title: LocalizedText(ko: r['title'] as String, en: r['title'] as String),
      description: LocalizedText(ko: r['summary'] as String, en: r['summary'] as String),
      category: r['kind'] == 'hackathon' ? EventCategory.hackathon : EventCategory.contest,
      tags: ['contest', if (r['audience'] == 'university') 'student'],
      start: start,
      end: end,
      deadline: end,
      venue: r['organizer'] as String,
      city: r['city'] as String,
      location: const GeoPoint(37.5665, 126.9780),
      placeless: true,
      url: r['sourceUrl'] as String,
      registerUrl: r['applyUrl'] as String?,
      source: source,
      sourceName: name,
      price: r['fee'] as String?,
      isFree: r['isFree'] as bool?,
      applicationStatus: r['applicationStatus'] as String,
      deadlinePrecision: r['deadlinePrecision'] as String,
      lastVerifiedAt: DateTime.parse(r['lastVerifiedAt'] as String),
      eligibilityText: r['eligibilityText'] as String?,
      audience: r['audience'] as String?,
      regionText: r['regionText'] as String?,
      participationMode: r['participationMode'] as String?,
    );
    return e.applicationVisible(now) ? e : null;
  }
}
