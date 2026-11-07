/// 텍스트에서 관심사 태그를 찾는다 (모든 출처 공통).
/// 태그는 앱 관심사 목록의 `InterestOption.tag`와 같다.
/// 순수 Dart — 수집 스크립트에서도 사용한다.
library;

const _keywords = <String, List<String>>{
  'ai': ['인공지능', 'AI', '생성형', '챗GPT', 'ChatGPT', '머신러닝', '딥러닝', 'LLM'],
  'developer': ['개발자', '코딩', '프로그래밍', '해커톤', '소프트웨어', 'SW'],
  'data': ['데이터', '빅데이터'],
  'startup': ['창업', '스타트업', '벤처', '사업화', '액셀러레이팅'],
  'design': ['디자인', 'UX', 'UI'],
  'career': ['채용', '취업', '커리어', '일자리', '구직', '인턴'],
  'student': ['대학생', '청년', '캠퍼스'],
  'networking': ['네트워킹', '밋업', '교류회', '커뮤니티'],
  'finance': ['재테크', '투자', '금융', '경제교육', '자산'],
  'language': ['외국어', '영어', '중국어', '일본어', '한국어 교실', '어학'],
  'books': ['도서', '북토크', '강연', '인문학', '작가와', '낭독', '도서관'],
  'music': ['콘서트', '음악', '공연', '클래식', '재즈', '밴드', '오케스트라', '합창', '국악', '뮤지컬', '버스킹'],
  'culture': ['축제', '문화', '전통', '페스티벌'],
  'art': ['전시', '미술', '갤러리', '공예', '사진전', '회화', '조각'],
  'movie': ['영화', '시네마', '상영'],
  'photo': ['사진'],
  'gaming': ['게임', 'e스포츠', '이스포츠'],
  'sports': ['리그', '스포츠', '야구', '축구', '농구', '배구'],
  'fitness': ['러닝', '마라톤', '달리기', '걷기', '요가', '필라테스', '체조'],
  'outdoor': ['등산', '캠핑', '트레킹', '숲', '공원', '생태', '자연', '한강'],
  'travel': ['여행', '투어', '관광', '탐방'],
  'food': ['푸드', '음식', '맛집', '먹거리', '미식', '요리', '쿠킹', '와인', '커피', '빵'],
  'family': ['가족', '어린이', '아이와', '키즈', '유아', '부모'],
  'pets': ['반려', '애견', '강아지', '고양이'],
  'fashion': ['패션', '뷰티', '스타일'],
  'volunteer': ['봉사', '나눔', '기부', '자원봉사'],
};

/// 라틴 문자 단어("AI", "UX")는 단어 단위로만: "AI와" ✓, "PAIR" ✗.
final _patterns = {
  for (final e in _keywords.entries)
    e.key: RegExp(e.value
        .map((w) => RegExp(r'^[A-Za-z]+$').hasMatch(w) ? '(?<![A-Za-z])${RegExp.escape(w)}(?![A-Za-z])' : RegExp.escape(w))
        .join('|')),
};

/// [texts] 안의 키워드로 정한 태그. [base] — 출처 카테고리에서 온 태그.
List<String> tagsFor(Iterable<String?> texts, {Iterable<String> base = const []}) {
  final hay = texts.whereType<String>().join(' ');
  final tags = <String>{...base};
  _patterns.forEach((tag, re) {
    if (re.hasMatch(hay)) tags.add(tag);
  });
  return tags.toList();
}

/// HTML entity를 일반 텍스트로 (공개 API는 &#39; &amp;를 자주 반환한다).
String unescapeHtml(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#039;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
    .trim();

/// 한국 범위의 좌표인지 (일부 출처는 lat/lng가 뒤바뀌어 온다).
({double lat, double lng})? koreaCoord(Object? latRaw, Object? lngRaw) {
  final lat = double.tryParse('${latRaw ?? ''}'.trim());
  final lng = double.tryParse('${lngRaw ?? ''}'.trim());
  if (lat == null || lng == null) return null;
  bool ok(double la, double ln) => la > 33 && la < 39 && ln > 124 && ln < 132;
  if (ok(lat, lng)) return (lat: lat, lng: lng);
  if (ok(lng, lat)) return (lat: lng, lng: lat);
  return null;
}
