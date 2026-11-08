import 'package:liferadar_core/liferadar_core.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';
import 'package:test/test.dart';

/// 국가교통정보센터 eventInfo 응답 형식 (2026-11-08 실제 응답을 줄인 예시).
Map<String, dynamic> _item({
  String eventType = '공사',
  String detail = '시설물보수작업',
  String start = '20260824000000',
  String end = '20261130000000',
  String x = '127.3845',
  String y = '36.3504',
  String road = '한밭대로',
  String message = '1차로 부분통제',
  String linkId = '1830012300',
}) =>
    {
      'type': '시군도',
      'eventType': eventType,
      'eventDetailType': detail,
      'startDate': start,
      'endDate': end,
      'coordX': x,
      'coordY': y,
      'linkId': linkId,
      'roadName': road,
      'roadNo': '',
      'roadDrcType': '',
      'lanesBlockType': '',
      'lanesBlocked': '',
      'message': message,
    };

Map<String, dynamic> _response(List<Map<String, dynamic>> items) => {
      'header': {'resultCode': 0, 'resultMsg': 'SUCCESS'},
      'body': {'totalCount': items.length, 'items': items},
    };

void main() {
  test('공사 → 교통 통제 공지: 시간·좌표·제목·원문', () {
    final n = ItsTraffic.parse(ItsTraffic.rows(_response([_item()])).single)!;
    expect(n.kind, TrafficKind.construction);
    expect(n.start, DateTime(2026, 8, 24));
    expect(n.end, DateTime(2026, 11, 30));
    expect(n.location.lat, closeTo(36.3504, 1e-9)); // coordY = 위도
    expect(n.location.lng, closeTo(127.3845, 1e-9)); // coordX = 경도
    expect(n.title, '[한밭대로] 공사 · 시설물보수작업');
    expect(n.detail, contains('1차로 부분통제'));
    expect(n.source, ItsTraffic.source);
    expect(n.id, 'its-1830012300-20260824000000');
  });

  test('일정과 관련 있는 유형만: 정체·사고·고장 제외, 이동 작업은 종료 시각이 있을 때만', () {
    final rows = ItsTraffic.rows(_response([
      _item(eventType: '기타돌발', detail: '차량증가/정체', end: ''),
      _item(eventType: '교통사고', detail: '', end: ''),
      _item(eventType: '기타돌발', detail: '고장', end: ''),
      _item(eventType: '공사', detail: '작업', end: ''), // 이동 작업, 종료 미상
      _item(eventType: '공사', detail: '작업', end: '20261108180000', linkId: '2'),
      _item(eventType: '기상', detail: '강우', end: '', linkId: '3'),
      _item(eventType: '재난', detail: '', end: '', linkId: '4'),
      _item(eventType: '기타', detail: '이벤트/홍보', end: '20261108200000', linkId: '5'),
    ]));
    final kinds = [for (final r in rows) ItsTraffic.parse(r)?.kind];
    expect(kinds, [
      null,
      null,
      null,
      null,
      TrafficKind.construction,
      TrafficKind.weather,
      TrafficKind.other,
      TrafficKind.event,
    ]);
  });

  test('종료 시각이 없거나 시작보다 앞서면 null — 추정하지 않는다', () {
    final noEnd = ItsTraffic.parse(_item(eventType: '기상', detail: '강우', end: ''))!;
    expect(noEnd.end, isNull);
    final reversed = ItsTraffic.parse(_item(start: '20261110000000', end: '20261101000000'))!;
    expect(reversed.end, isNull);
  });

  test('좌표가 없거나 한국 밖이면 버린다', () {
    expect(ItsTraffic.parse(_item(x: '', y: '')), isNull);
    expect(ItsTraffic.parse(_item(x: '0', y: '0')), isNull);
  });

  test('오류 코드 → SourceException', () {
    expect(
      () => ItsTraffic.rows({
        'header': {'resultCode': 99, 'resultMsg': 'INVALID KEY'},
      }),
      throwsA(isA<SourceException>()),
    );
  });
}
