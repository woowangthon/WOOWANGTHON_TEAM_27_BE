/// LifeRadar 데이터 파이프라인 — 공공 API 수집기와 정규화.
///
/// - 행사: 서울 열린데이터광장 문화행사, 한국관광공사 TourAPI 축제, 창업진흥원 K-Startup 공고
/// - 교통: 서울시 TOPIS 실시간 돌발정보 + 국가교통정보센터(ITS) 전국 돌발상황 (행사·공사·기상·재난)
/// 결과는 `bin/` 스크립트가 JSON으로 저장하고 GitHub Actions가 `data` 브랜치에 게시한다.
library;

export 'src/config.dart';
export 'src/sources/kstartup.dart';
export 'src/sources/seoul_culture.dart';
export 'src/sources/seoul_traffic.dart';
export 'src/sources/tagger.dart';
export 'src/sources/tour_festival.dart';
