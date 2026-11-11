# 본문 근거 기반 파업·행사 교통 영향

사용자가 제공한 두 구현 지침을 BE → AI → FE 경로에 연결했다. 기존 `hack_idea/traffic`의 검증된 도메인 모듈을 BE 패키지로 재사용·확장했다. 별도 HTTP 서버를 실행하지 않는다.

## 입력·출력

`extract_strike_records(article, refs=())`는 **최상위 정확히 11개 필드**를 반환한다. `extract_event_traffic(article, refs=())`는 행사와 교통 영향을 별도 배열·기간·상태로 반환한다. 선언된 중첩 스키마 이외의 키, 없는 인용, 불가능한 시간, 역전 기간, 잘못된 출처 메타데이터, 신뢰하지 않는 참조 ID는 거부한다.

입력 필수: `title`, **실제 본문** `body`, `source_url`, offset이 있는 `collected_at`. `published_at`·`updated_at`은 offset datetime 또는 null이다. `source_id`·`source_revision`이 없으면 URL·본문에서 내부 해시를 발급한다. 예제는 `fixtures/articles.json`, 출력 스키마는 `schemas/*.schema.json`에 있다.

규칙 추출은 지원하는 한국어 술어·절만 처리한다. ‘철회 요구·검토·부정·조건’을 확정 철회로 바꾸지 않으며, 종료를 정상 운행으로 자동 변환하지 않는다. 첫차·막차의 실제 시각을 만들지 않는다. 행사 개최·방문 인원·과거 혼잡만으로 교통 영향을 만들지 않는다. 본문 속 명령은 실행하지 않는다. AI 후보를 향후 연결할 경우에도 `schemas.validate`를 반드시 통과시켜야 한다.

## 키 없이 재현

BE 폴더에서:

```powershell
python -m pip install -r news_traffic/requirements.txt
python -m unittest discover -s news_traffic/tests -v
python -m news_traffic.publish --articles news_traffic/fixtures/articles.json --references news_traffic/fixtures/references.json --db cache/example.sqlite3 --out out/example-news.json
```

`fixtures`는 **합성 기사·참조 자료**이며 실제 뉴스나 실노선으로 표시하면 안 된다. `demo`와 실제 일정의 판별을 분리했다. 같은 DB로 재처리하면 같은 사건·의미 버전을 유지한다.

AI 폴더에서 BE 결과를 실제 Dart 소비자로 검증:

```powershell
dart pub get
dart run tool/verify_news_traffic.dart ../WOOWANGTHON_TEAM_27_BE/out/example-news.json
```

FE 폴더에서 알림 통합 검증:

```powershell
flutter test test/news_traffic_test.dart
```

Windows의 테스트 임시 경로에 비ASCII 문자가 있어 Flutter 엔진이 시작하지 못하면 ASCII 임시 디렉터리를 TEMP/TMP로 지정한다. 샌드박스에서는 Flutter 테스트 엔진의 로컬 루프백 연결도 허용돼야 한다.

## 운영 파이프라인

기존 `collect_news.dart`가 파업·집회·마라톤·행사 통제 검색 결과를 발견한다. 검색 요약은 기존 참고 카드로만 남고 검증된 영향 정보가 되지 않는다. 워크플로가 `python -m news_traffic.publish`를 실행해 허용 출처의 본문을 가져오고 검증한다. 본문 수집 예산은 실행당 12건이며 검색 종류별로 나눠 행사 기사가 파업 기사 뒤로 계속 밀리지 않게 했다.

기존 `news.json`의 `strikes` 계약을 유지하면서 `newsTrafficSchemaVersion`, `trafficImpacts`, `transportReferences`, `extractions`, `extractionFailures`를 추가한다. 수집 실패는 ‘영향 없음’이나 ‘철회’가 아니다. SQLite 원문·추출 시도·사건 이력·의미 버전을 `cache/`에 유지하고, Actions 캐시가 사라져도 이전 data 브랜치의 검증 피드로 버전을 복구한다. 실패한 수집 때문에 기존 영향을 삭제하지 않는다. 본문은 설정된 보존 기간 이후 지운다.

## 참조 자료 연결 조건

`references.json`은 초기 상태 **빈 배열**이다. 검증된 공식 노선·도로 자료가 아직 등록되지 않았음을 명시적으로 표현한다. 허구 노선 ID나 행사장 좌표를 통제 구간으로 넣지 않는다.

신뢰할 수 있는 참조 자료를 확보하면 다음 필드를 등록한다.

```json
{
  "id": "공식 데이터의 실제 식별자",
  "raw": "기사에서 확인할 실제 노선명",
  "aliases": ["경로 API가 반환하는 검증된 동일 노선 표기"],
  "region": "서울",
  "mode": "bus",
  "source": "참조 데이터 URL 및 버전",
  "as_of": "2026-11-10",
  "valid_from": "2026-11-10",
  "valid_until": "2026-11-30",
  "demo": false
}
```

위 JSON은 **형식 설명이며 실제 등록 데이터가 아니다.** 출처·기준일을 확인한 실제 값만 사용한다. 공식 영향 지점이 확인된 자료에 한해 `point: [lat, lng]`를 추가할 수 있다. 도로 전체·일부 구간의 차이를 지점 하나로 대체해서는 안 된다.

앱은 저장한 경로 API의 노선명과 이 참조 자료를 지역·수단·유효기간까지 비교한다. 동명 노선이나 중복 후보는 확정하지 않는다. 데이터가 없거나 매핑되지 않으면 원문을 보존하고 **지역만 일치하는 뉴스는 REFERENCE, 시스템 알림 제외**로 처리한다. 같은 번호의 다른 도시 노선, 역 전체와 특정 출입구, 방향·구간 불일치를 직접 영향으로 확대하지 않는다.

## 일정 판별·알림

- 저장한 이동 시간/통과 시각 → 일정 전 2시간 후보 구간 순으로 검사한다. 2시간은 출발 권고가 아니다.
- 정확한 시간은 `[start, end)`로 비교한다. 명백한 시간·공간·수단 불일치는 UNKNOWN·조건부보다 먼저 제외한다.
- 공식 TOPIS·ITS 통제도 저장한 이동 시간·수단·경로 인근과 비교한다. 폴리라인은 인근 탐지이며 실제 통제 도로를 통과한다고 단정하지 않는다.
- 본문 검증 영향은 IGNORE / NEEDS_REVIEW / REFERENCE / CAUTION / RECOMMEND / RESOLVED로 나누고 버전·근거·이유를 보존한다.
- CAUTION·RECOMMEND 중 가까운 일정의 중요 신호를 시스템 알림으로 전달한다. 지역 참고·미확인·검색 요약은 알림을 보내지 않는다.
- 중복 키는 `(일정, 영향, 의미 버전, 알림 종류)`다. 운영체제 알림 API가 수락한 뒤에만 발송 기록을 저장한다. 사용자에게 실제 표시됐다는 확인과는 다르다.
- 철회·시간/경로 변경은 같은 일정·영향의 기존 안내만 해제한다. 전에 시스템 경고를 보내지 않은 참고 카드의 철회를 새 시스템 경고로 보내지 않는다.
- 앱 실행 중 5분마다, 앱 복귀 시 다시 수집하고 1분마다 판별 시각을 갱신한다. 시각 갱신이 동기화된 캘린더 일정을 초기화하지 않도록 분리했다.

## 범위와 제한

규칙 추출은 자유로운 모든 한국어 뉴스의 의미를 지원하는 LLM이 아니다. 복잡한 중첩 인용·주체 생략, 생략된 연월, 문장별 기준 시점을 확인할 수 없는 수정 기사, 비정형 반복 일정, 근거 없는 후속 사건 연결은 미확인/확인 필요로 남는다. 모든 부정·조건 조합에 대한 일반 정확도를 주장하지 않는다.

출처별 본문 선택자·robots·네트워크 상황에 따라 수집되지 않는 기사가 있다. 검색 후보가 허용 출처에 속하지 않으면 검증된 본문으로 다루지 않는다. 정규화의 정확도와 실제 출처 접속 성공률은 별도 검증 대상이다.

이 변경은 **로컬 구현·테스트**이며 배포하지 않았다. 기존 FE·BE의 git 의존성을 사용해 배포하려면 AI 패키지 변경을 먼저 게시하고 해당 리비전으로 의존성을 갱신해야 한다. 이 작업 폴더에는 로컬 AI 체크아웃을 사용하는 `pubspec_overrides.yaml`을 두었다.

**앱 종료 상태의 FCM/백그라운드 푸시는 이번 추출·판별 어댑터 범위에 포함하지 않았으며 기존 설계 상태다.** 실제 운영 뉴스 전체 정확도, Android/브라우저에서 알림이 화면에 표시되는지, 제공자 API의 실응답은 별도 실기기 검증이 필요하다.
