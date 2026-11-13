import 'dart:io';
import 'package:liferadar_pipeline/src/config.dart';
import 'package:test/test.dart';

void main() {
  test('malformed key configuration does not expose source text', () {
    final dir=Directory.systemTemp.createTempSync('keys-test-');
    addTearDown(()=>dir.deleteSync(recursive:true));
    final file=File('${dir.path}/env.json')..writeAsStringSync('{"private":"dummy-secret" "next":"value"}');
    try { loadKeys(path:file.path); fail('Expected invalid JSON'); }
    on FormatException catch(e) {
      expect(e.toString(),isNot(contains('dummy-secret')));
      expect(e.source,isNull);
    }
  });
  test('valid local config remains readable', () {
    final dir=Directory.systemTemp.createTempSync('keys-test-');
    addTearDown(()=>dir.deleteSync(recursive:true));
    final file=File('${dir.path}/env.json')..writeAsStringSync('{"test_key":"dummy-value"}');
    expect(loadKeys(path:file.path)['test_key'],'dummy-value');
  });
}
