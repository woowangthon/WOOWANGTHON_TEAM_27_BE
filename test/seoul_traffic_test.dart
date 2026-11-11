import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('SeoulTraffic parser', () {
    // 실제 응답(2026-11-07)을 줄인 예시.
    const xml =
        '<?xml version="1.0" encoding="UTF-8"?><AccInfo><list_total_count>2</list_total_count>'
        '<RESULT><CODE>INFO-000</CODE><MESSAGE>정상 처리되었습니다</MESSAGE></RESULT>'
        '<row><acc_id>1107886</acc_id><occr_date>20261107</occr_date><occr_time>1400</occr_time>'
        '<exp_clr_date>20261108</exp_clr_date><exp_clr_time>220000</exp_clr_time><acc_type>A10</acc_type>'
        '<acc_dtype>10B03</acc_dtype><grs80tm_x>198481.948238959</grs80tm_x><grs80tm_y>452136.8686872072</grs80tm_y>'
        '<acc_info>[통제] 청계천로 차 없는 거리 행사(청계광장~삼일교, 양방향) &#13;(토) 14:00 ~ (일) 22:00</acc_info></row>'
        '<row><acc_id>9</acc_id><occr_date>20261107</occr_date><occr_time>0900</occr_time><acc_type>A01</acc_type>'
        '<acc_dtype>01B01</acc_dtype><grs80tm_x>198000</grs80tm_x><grs80tm_y>452000</grs80tm_y><acc_info>추돌사고</acc_info></row>'
        '</AccInfo>';

    test('XML → 공지; 사고 같은 짧은 돌발은 제외', () {
      final notices = [for (final r in SeoulTraffic.rows(xml)) ?SeoulTraffic.parse(r)];
      expect(notices, hasLength(1));
      final n = notices.single;
      expect(n.id, 'topis-1107886');
      expect(n.kind, TrafficKind.event);
      expect(n.start, trafficInstant('2026-11-07T14:00:00'));
      expect(n.end, trafficInstant('2026-11-08T22:00:00'));
      expect(n.title, '[통제] 청계천로 차 없는 거리 행사(청계광장~삼일교, 양방향)');
      expect(n.detail, contains('(토) 14:00 ~ (일) 22:00'));
      // 청계천로, 청계광장 근처.
      expect(RouteMatcher.haversineKm(n.location, const GeoPoint(37.5688, 126.9829)), lessThan(0.2));
    });

    test('오류 코드 → exception; 데이터 없음 → 빈 목록', () {
      expect(() => SeoulTraffic.rows('<RESULT><CODE>ERROR-500</CODE><MESSAGE>x</MESSAGE></RESULT>'), throwsException);
      expect(SeoulTraffic.rows('<RESULT><CODE>INFO-200</CODE></RESULT>'), isEmpty);
    });

    test('TM → WGS84: 서울시청', () {
      // EPSG:5181에서 서울시청 ≈ (198,000, 451,900) — ~ (37.566, 126.977).
      final p = SeoulTraffic.tmToWgs84(197990, 451880);
      expect(p.lat, closeTo(37.566, 0.003));
      expect(p.lng, closeTo(126.977, 0.003));
    });
  });
  test('negative and ambiguous TOPIS originals cannot produce confirmed control metadata', () {
    final row = <String, String>{
      'acc_id': 'synthetic-negative',
      'acc_type': 'A10',
      'acc_dtype': '10B03',
      'occr_date': '20261111',
      'occr_time': '0900',
      'exp_clr_date': '20261111',
      'exp_clr_time': '1200',
      'grs80tm_x': '198000',
      'grs80tm_y': '452000',
    };
    for (final text in ['행사 중 도로 통제는 없습니다', '도로 통제가 없습니다', '도로 통제는 하지 않습니다']) {
      final parsed = SeoulTraffic.parse({...row, 'acc_info': text})!;
      expect(parsed.hasControlEvidence, isFalse);
      final ledger = TrafficLedger()..accept('seoul-topis', [parsed], DateTime.utc(2026, 11, 11), complete: true);
      final active = [
        for (final j in ledger.feed(DateTime.utc(2026, 11, 11))['notices'] as List)
          TrafficNotice.fromJson((j as Map).cast<String, dynamic>()),
      ];
      final cards = const InsightEngine().build(
        plans: [
          Plan(
            id: 'p',
            title: '방문',
            start: DateTime.utc(2026, 11, 11, 2),
            end: DateTime.utc(2026, 11, 11, 3),
            location: const GeoPoint(37.57, 126.98),
            locationText: '시청',
            city: '서울',
          ),
        ],
        events: [],
        interests: {},
        now: DateTime.utc(2026, 11, 11),
        traffic: active,
      );
      expect(cards, isEmpty, reason: text);
    }
  });
  test('TOPIS malformed/truncated XML is not a normal empty source snapshot', () {
    expect(() => SeoulTraffic.rows('<AccInfo><RESULT><CODE>INFO-000</CODE></RESULT>'), throwsA(anything));
    expect(() => SeoulTraffic.rows('<AccInfo><RESULT><CODE>INFO-000</CODE></RESULT></AccInfo>'), throwsA(anything));
    const partial = '<AccInfo><list_total_count>1</list_total_count><RESULT><CODE>INFO-000</CODE></RESULT></AccInfo>';
    final rows = SeoulTraffic.rows(partial);
    expect(rows, isEmpty);
    expect(SeoulTraffic.isComplete(partial, rows), isFalse);
    const empty = '<AccInfo><list_total_count>0</list_total_count><RESULT><CODE>INFO-000</CODE></RESULT></AccInfo>';
    expect(SeoulTraffic.isComplete(empty, SeoulTraffic.rows(empty)), isTrue);
  });
}
