import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';
import 'package:test/test.dart';

/// 서울 열린데이터광장 culturalEventInfo 응답의 한 행 (실제 형식).
Map<String, dynamic> seoulRow({
  String codename = '콘서트',
  String title = '2026 카즈미 타테이시 트리오 내한공연 &#39;재즈&#39;',
  String start = '2026-12-24 00:00:00.0',
  String end = '2026-12-24 00:00:00.0',
  String proTime = '19:30',
  String lat = '37.5512204558342',
  String lot = '127.157342546961',
  String target = '성인, 청소년',
  String isFree = '유료',
}) =>
    {
      'CODENAME': codename,
      'GUNAME': '강동구',
      'TITLE': title,
      'DATE': '2026-12-24~2026-12-24',
      'PLACE': '강동아트센터 대극장 한강',
      'ORG_NAME': '기타',
      'USE_TRGT': target,
      'USE_FEE': 'R석 77,000원',
      'PLAYER': 'Piano : Kazumi Tateishi',
      'PROGRAM': 'Let It Snow 등 크리스마스 캐롤',
      'ETC_DESC': '',
      'ORG_LINK': 'https://tickets.interpark.com/goods/26010350',
      'MAIN_IMG': 'https://culture.seoul.go.kr/cmmn/file/getImage.do?atchFileId=x&thumb=Y',
      'RGSTDATE': '2026-07-23',
      'TICKET': '시민',
      'STRTDATE': start,
      'END_DATE': end,
      'THEMECODE': '기타',
      'LOT': lot,
      'LAT': lat,
      'IS_FREE': isFree,
      'HMPG_ADDR': 'https://culture.seoul.go.kr/culture/culture/cultureEvent/view.do?cultcode=158770&menuNo=200008',
      'PRO_TIME': proTime,
    };

void main() {
  group('SeoulCulture.parse', () {
    test('콘서트: 시간, 장소, 카테고리, 태그, 링크', () {
      final e = SeoulCulture.parse(seoulRow())!;
      expect(e.id, 'seoul-158770');
      expect(e.title.ko, "2026 카즈미 타테이시 트리오 내한공연 '재즈'"); // HTML entity 해제됨
      expect(e.category, EventCategory.concert);
      expect(e.tags, contains('music'));
      expect(e.tags, isNot(contains('student')), reason: '"청소년" — 관람 대상이지 관심사가 아니다');
      expect(e.start, DateTime(2026, 12, 24, 19, 30));
      expect(e.end, DateTime(2026, 12, 24, 21, 30));
      expect(e.city, '서울 강동구');
      expect(e.location.lat, closeTo(37.551, 0.001));
      expect(e.url, contains('cultcode=158770'));
      expect(e.registerUrl, contains('interpark'));
      expect(e.isFree, isFalse);
      expect(e.sourceName, SeoulCulture.sourceName);
    });

    test('긴 전시: 시간 범위 "10:00~18:00", 가족 태그', () {
      final e = SeoulCulture.parse(seoulRow(
        codename: '전시/미술',
        title: '어린이 사진 전시',
        start: '2026-11-01 00:00:00.0',
        end: '2027-01-31 00:00:00.0',
        proTime: '화~일 10:00~18:00',
        target: '누구나, 가족 관람 추천',
        isFree: '무료',
      ))!;
      expect(e.category, EventCategory.exhibition);
      expect(e.tags, containsAll(['art', 'photo', 'family']));
      expect(e.start, DateTime(2026, 11, 1, 10));
      expect(e.end, DateTime(2027, 1, 31, 18));
      expect(e.isFree, isTrue);
    });

    test('lat/lng가 뒤바뀌면 고치고, 좌표 없는 행은 버린다', () {
      final swapped = SeoulCulture.parse(seoulRow(lat: '127.0', lot: '37.5'))!;
      expect(swapped.location.lat, 37.5);
      expect(SeoulCulture.parse(seoulRow(lat: '', lot: '')), isNull);
      expect(SeoulCulture.parse(seoulRow(lat: '0', lot: '0')), isNull);
    });

    test('API 오류 코드 → SourceException, 데이터 없음 → 빈 목록', () {
      expect(
        () => SeoulCulture.rows({
          'RESULT': {'CODE': 'INFO-100', 'MESSAGE': '인증키가 유효하지 않습니다.'},
        }),
        throwsA(isA<SourceException>()),
      );
      expect(
        SeoulCulture.rows({
          'culturalEventInfo': {
            'RESULT': {'CODE': 'INFO-200', 'MESSAGE': '해당하는 데이터가 없습니다.'},
          },
        }),
        isEmpty,
      );
    });
  });

  group('TourFestival', () {
    // searchFestival2 / detailCommon2 / detailIntro2 응답 (실제 형식, 축약).
    final listJson = {
      'response': {
        'header': {'resultCode': '0000', 'resultMsg': 'OK'},
        'body': {
          'items': {
            'item': [
              {
                'addr1': '부산광역시 해운대구 APEC로 30 (우동)',
                'contentid': '3360113',
                'eventstartdate': '20261119',
                'eventenddate': '20261122',
                'firstimage': 'https://tong.visitkorea.or.kr/x.png',
                'mapx': '129.1350266435',
                'mapy': '35.1657825587',
                'title': '게임문화축제',
              },
            ],
          },
          'totalCount': 1,
        },
      },
    };
    final common = {
      'overview': "'2026 게임문화축제'는 게임 페스티벌이다.<br>e스포츠 대회",
      'homepage': '<a href="https://kgcf.kr/" target="_blank">https://kgcf.kr/</a>',
    };
    final intro = {
      'playtime': '10:00~18:00',
      'eventplace': '부산 벡스코(BEXCO) 제2전시장',
      'usetimefestival': '무료',
      'program': '게임 IP 전시',
    };

    test('목록 + 상세 → 행사', () {
      final item = TourFestival.items(listJson).single;
      final e = TourFestival.parse(item, common: common, intro: intro)!;
      expect(e.id, 'tour-3360113');
      expect(e.category, EventCategory.festival);
      expect(e.start, DateTime(2026, 11, 19, 10));
      expect(e.end, DateTime(2026, 11, 22, 18));
      expect(e.city, '부산 해운대구');
      expect(e.venue, '부산 벡스코(BEXCO) 제2전시장');
      expect(e.location.lat, closeTo(35.166, 0.001));
      expect(e.url, 'https://kgcf.kr/');
      expect(e.isFree, isTrue);
      expect(e.tags, containsAll(['gaming', 'culture', 'travel']));
      expect(e.description.ko, contains('게임 페스티벌이다.\ne스포츠')); // <br> → 줄바꿈
      expect(e.description.ko, isNot(contains('<')));
    });

    test('상세 없이도 동작하고, item 하나가 Map으로 와도 동작한다', () {
      final single = {
        'response': {
          'header': {'resultCode': '0000'},
          'body': {
            'items': {'item': (listJson['response']!['body'] as Map)['items']['item'][0]},
          },
        },
      };
      final e = TourFestival.parse(TourFestival.items(single).single)!;
      expect(e.start, DateTime(2026, 11, 19, 10));
      expect(e.isFree, isNull);
    });

    test('키 오류 → SourceException; 빈 결과 → []', () {
      expect(
        () => TourFestival.items({
          'OpenAPI_ServiceResponse': {
            'cmmMsgHeader': {'returnAuthMsg': 'SERVICE_KEY_IS_NOT_REGISTERED_ERROR'},
          },
        }),
        throwsA(isA<SourceException>()),
      );
      expect(
        TourFestival.items({
          'response': {
            'header': {'resultCode': '0000'},
            'body': {'items': '', 'totalCount': 0},
          },
        }),
        isEmpty,
      );
    });

    test('도시 이름을 줄여 쓴다', () {
      expect(TourFestival.cityOf('충청남도 공주시 웅진동'), '충남 공주시');
      expect(TourFestival.cityOf('서울특별시 중구 세종대로 110'), '서울 중구');
      expect(TourFestival.cityOf('제주특별자치도 제주시 …'), '제주 제주시');
      expect(TourFestival.cityOf('경기도 수원시 권선구'), '경기 수원시');
    });

    test('유료 요금이 "무료"를 언급해도 무료가 아니다', () {
      final e = TourFestival.parse(
        TourFestival.items(listJson).single,
        intro: {'usetimefestival': '성인 10,000원 / 어린이 무료'},
      )!;
      expect(e.isFree, isFalse);
    });
  });

  group('tagsFor', () {
    test('짧은 라틴 단어는 단어 단위로만', () {
      expect(tagsFor(['AI와 함께하는 미래']), contains('ai'));
      expect(tagsFor(['PAIR 프로그래밍 대회']), isNot(contains('ai')));
      expect(tagsFor(['강동아트센터 콘서트']), isNot(contains('art')));
      expect(tagsFor(['경기도 문화의 날']), isNot(contains('sports')));
      expect(tagsFor(['반려견과 함께 걷기 대회']), containsAll(['pets', 'fitness']));
    });
  });

  test('InsightEngine: 진행 중인 전시 — 카드에 지난 날짜가 아니라 일정 날짜', () {
    final plan = Plan(
      id: 'p3',
      title: 'Visit',
      start: DateTime(2026, 11, 10, 14),
      end: DateTime(2026, 11, 10, 16),
      locationText: '강남역',
      city: 'Seoul',
      location: const GeoPoint(37.55, 127.15),
    );
    final expo = SeoulCulture.parse(seoulRow(
      codename: '전시/미술',
      title: '사진 전시',
      start: '2026-05-01 00:00:00.0',
      end: '2026-12-31 00:00:00.0',
    ))!;
    final card = const InsightEngine()
        .build(plans: [plan], events: [expo], interests: {'art'}, now: DateTime(2026, 11, 7))
        .firstWhere((i) => i.planId == 'p3');
    expect(card.body.en, startsWith('On Nov 10'));
    expect(card.body.ko, startsWith('11월 10일'));
  });

  test('InsightEngine: 행사 위치만으로는 혼잡 카드를 만들지 않는다', () {
    final plan = Plan(
      id: 'p2',
      title: 'Trip',
      start: DateTime(2026, 12, 24, 9),
      end: DateTime(2026, 12, 24, 18),
      locationText: '광화문',
      city: 'Seoul',
      location: const GeoPoint(37.55, 127.15),
    );
    final events = [
      for (var i = 0; i < 3; i++)
        SeoulCulture.parse(seoulRow(codename: '축제-시민화합', lat: '${37.55 + i * 0.002}', title: '축제 $i')
          ..['HMPG_ADDR'] = 'https://x/view.do?cultcode=f$i')!,
    ];
    final insights = const InsightEngine().build(plans: [plan], events: events, interests: {}, now: DateTime(2026, 12, 20));
    expect(insights.where((i) => i.id.startsWith('crowd:')), isEmpty);
  });

  test('InsightEngine: 일정 하나 주변에 행사 수십 개 → 카드 수 제한', () {
    final plan = Plan(
      id: 'p1',
      title: 'Meeting',
      start: DateTime(2026, 12, 24, 14),
      end: DateTime(2026, 12, 24, 16),
      locationText: '강동',
      city: 'Seoul',
      location: const GeoPoint(37.55, 127.15),
    );
    final events = [
      for (var i = 0; i < 20; i++)
        SeoulCulture.parse(seoulRow(lat: '${37.55 + i * 0.001}', title: '콘서트 $i')
          ..['HMPG_ADDR'] = 'https://x/view.do?cultcode=$i')!,
    ];
    final insights = const InsightEngine().build(
      plans: [plan],
      events: events,
      interests: {'music'},
      now: DateTime(2026, 12, 20),
    );
    final forPlan = insights.where((i) => i.planId == 'p1').toList();
    // 작은 공연장의 공연은 "혼잡"이 아니다 → 맞는 기회만, 최대 2개.
    expect(forPlan.where((i) => i.id.startsWith('crowd:')), isEmpty);
    expect(forPlan, hasLength(2));
    expect(forPlan.first.sources.single.title, SeoulCulture.sourceName);
  });
}

