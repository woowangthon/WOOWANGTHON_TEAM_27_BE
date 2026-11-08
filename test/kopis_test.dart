import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';
import 'package:test/test.dart';

// KOPIS 응답 형식 (2026-11-08 실제 응답을 줄인 예시).
const _list = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><dbs>
<db><mt20id>PF305692</mt20id><prfnm>황수미X이동규: 이토록 아름다운 겨울 [울산]</prfnm><prfpdfrom>2026.12.23</prfpdfrom><prfpdto>2026.12.23</prfpdto><fcltynm>울산중구문화의전당</fcltynm><area>울산광역시</area><genrenm>서양음악(클래식)</genrenm><prfstate>공연예정</prfstate></db>
<db><mt20id>PF305691</mt20id><prfnm>현대카드 Curated 110, ADOY</prfnm><prfpdfrom>2026.12.19</prfpdfrom><prfpdto>2026.12.20</prfpdto><fcltynm>현대카드 언더스테이지</fcltynm><area>서울특별시</area><genrenm>대중음악</genrenm><prfstate>공연예정</prfstate></db>
</dbs>''';

const _detail =
    '''<dbs><db><mt20id>PF305692</mt20id><prfnm>황수미X이동규: 이토록 아름다운 겨울 [울산]</prfnm>
<prfpdfrom>2026.12.23</prfpdfrom><prfpdto>2026.12.23</prfpdto><fcltynm>울산중구문화의전당 (함월홀 (2층) )</fcltynm>
<prfcast>황수미, 이동규, 문재원</prfcast><prfruntime>1시간 30분</prfruntime><prfage>만 7세 이상</prfage>
<pcseguidance>전석 30,000원</pcseguidance><poster>http://www.kopis.or.kr/upload/pfmPoster/PF_PF305692_261106_143257.jpg</poster>
<area>울산광역시</area><genrenm>서양음악(클래식)</genrenm><mt10id>FC001328</mt10id><dtguidance>수요일(19:30)</dtguidance>
<relateurl>https://artscenter.junggu.ulsan.kr/01_Menu/01_view.do?prcValue=P0001934&amp;sear</relateurl></db></dbs>''';

const _facility =
    '''<dbs><db><fcltynm>울산중구문화의전당</fcltynm><mt10id>FC001328</mt10id>
<adres>울산광역시 중구 종가로 405 (성안동)</adres><la>35.567542200000000</la><lo>129.32153640000000</lo></db></dbs>''';

void main() {
  test('목록: 서울 공연은 제외 대상 (서울시 문화행사 데이터와 중복)', () {
    final rows = Kopis.rows(_list);
    expect(rows, hasLength(2));
    expect(rows.where((r) => !Kopis.isSeoul(r)).single['mt20id'], 'PF305692');
  });

  test('상세 + 공연장 → 행사: 시간·좌표·카테고리·요금·출처·https 포스터', () {
    final e = Kopis.parse(
      Kopis.rows(_detail).single,
      Kopis.rows(_facility).single,
    )!;
    expect(e.id, 'kopis-PF305692');
    expect(e.category, EventCategory.concert);
    expect(e.tags, containsAll(['music', 'culture']));
    expect(e.start, DateTime(2026, 12, 23, 19, 30));
    expect(e.end, DateTime(2026, 12, 23, 23, 59));
    expect(e.location.lat, closeTo(35.5675, 1e-3));
    expect(e.city, '울산광역시');
    expect(e.price, '전석 30,000원');
    expect(e.isFree, isFalse);
    expect(e.description.ko, contains('출연: 황수미'));
    expect(
      e.imageUrl,
      'https://kopis.or.kr/upload/pfmPoster/PF_PF305692_261106_143257.jpg',
    );
    expect(e.url, startsWith('https://artscenter.junggu.ulsan.kr/'));
    expect(e.url, contains('&sear')); // HTML entity 해제
    expect(e.source, Kopis.source);
  });

  test('공연 시간이 없으면 날짜만 (00:00), 공연장 좌표가 없으면 버린다', () {
    final noTime = Kopis.rows(_detail.replaceAll('수요일(19:30)', '')).single;
    expect(
      Kopis.parse(noTime, Kopis.rows(_facility).single)!.start,
      DateTime(2026, 12, 23),
    );
    expect(Kopis.parse(Kopis.rows(_detail).single, null), isNull);
  });

  test('오류 응답 → SourceException', () {
    expect(
      () => Kopis.rows(
        '<dbs><returncode>02</returncode><errmsg>SERVICE KEY IS NOT REGISTERED</errmsg></dbs>',
      ),
      throwsA(isA<SourceException>()),
    );
  });
}
