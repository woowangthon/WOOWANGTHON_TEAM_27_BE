import 'dart:convert';
import 'dart:io';

/// API 키: 환경 변수(GitHub Actions Secrets)가 우선이고, 없으면 로컬 `env.json`.
/// 키 값은 로그에 출력하지 않는다.
Map<String, dynamic> loadKeys({String path = 'env.json'}) {
  final file = File(path);
  final fromFile = file.existsSync() ? (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>) : <String, dynamic>{};
  const names = ['UTIC_ENABLED', 'UTIC_API_KEY', 'UTIC_API_URL', 'UTIC_TIMEOUT_SECONDS', 'UTIC_POLL_INTERVAL_MINUTES', 'UTIC_FRESH_MINUTES', 'UTIC_CACHE_MAX_HOURS', 'UTIC_SNAPSHOT_URL', 'UTIC_SNAPSHOT_READ_TOKEN', 'SEOUL_OPEN_API_KEY', 'DATA_GO_KR_KEY', 'GEMINI_API_KEY', 'ITS_API_KEY', 'KOPIS_API_KEY', 'NAVER_API_KEY_ID', 'NAVER_API_KEY'];
  return {
    ...fromFile,
    for (final n in names)
      if ((Platform.environment[n] ?? '').isNotEmpty) n: Platform.environment[n],
  };
}
