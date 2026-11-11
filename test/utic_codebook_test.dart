import 'package:test/test.dart';
import 'package:liferadar_pipeline/liferadar_pipeline.dart';

void main() {
  // Developer synthetic records using separately verified official code values.
  Map<String, String> row() => {
    'incidentId': 'synthetic-1',
    'incidenteTypeCd': '3',
    'incidenteSubTypeCd': '3',
    'controlType': '1',
    'locationTypeCd': 'C0101',
    'incidentTitle': 'synthetic 집회',
    'locationDataX': '127',
    'locationDataY': '37.5',
  };
  test('official event/rally codes alone cannot establish road control', () {
    final rally = UticRecord(row());
    expect(rally.typeLabel, '행사');
    expect(rally.subtypeLabel, '집회');
    expect(rally.controlDirectionLabel, '진행방향 통제');
    expect(rally.hasDocumentedControl, isTrue);
    final eventOnly = UticRecord({...row(), 'controlType': '0'});
    expect(eventOnly.hasDocumentedControl, isFalse);
    expect(eventOnly.controlDirectionLabel, '없음');
    expect(eventOnly.canPublish, isFalse);
    expect(eventOnly.quarantineReasons, contains('CONTROL_ZERO_MEANING_CONFLICT'));
  });
  test('codebook direction labels do not turn zero into a release code', () {
    expect(UticCodebook.controlDirections, {'0': '없음', '1': '진행방향 통제', '2': '양방향 통제'});
    expect(UticRecord({...row(), 'controlType': '2'}).controlDirectionLabel, '양방향 통제');
  });
  test('unknown codes and conflicting control evidence are quarantined, CRS remains blocked', () {
    expect(
      UticRecord({...row(), 'controlType': 'SYNTHETIC-UNKNOWN'}).quarantineReasons,
      contains('UNKNOWN_CONTROL_CODE'),
    );
    expect(UticRecord({...row(), 'incidenteSubTypeCd': '999'}).quarantineReasons, contains('UNKNOWN_TYPE_CODE'));
    expect(
      UticRecord({...row(), 'incidenteTypeCd': '5', 'incidenteSubTypeCd': '20', 'controlType': '0'}).quarantineReasons,
      contains('CONFLICTING_CONTROL_CODES'),
    );
    final known = UticRecord(row());
    expect(known.quarantineReasons, contains('UTIC_CRS_UNVERIFIED'));
    expect(known.canPublish, isFalse);
    expect(UticXml.normalizationVerified, isFalse);
  });
}
