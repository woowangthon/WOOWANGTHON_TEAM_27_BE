# 소통24 수집·검토·운영 전환

2026-11-12. **운영 자동 수집 기본값은 꺼짐**. 공식 OpenAPI가 아닌 소통24 공개 화면의 HTML 조회 경로다. 유료 API/AI 없이 파싱·검토·앱 표시가 동작한다. 운영 피드를 게시하거나 원격 push를 실행하지 않았다.

## 확인한 구조와 제약

- 초기 GET: `https://modu.go.kr/front/epilogue/epilogueNewListPage.do?menu_id=527&pagetype=bbs`
- 화면 AJAX POST: `/front/epilogue/epilogueNewList.do`, `bbsListFrm` serialize. 현재 기본 목록은 9개 카드. 폼 값·세션 쿠키와 제공되는 CSRF hidden/meta를 읽으며 토큰은 고정하지 않는다. 실제 페이지에서 유효 CSRF 토큰을 요구하는지는 미확인이다.
- 목록: `.bs_card_line li.thm_card`, 링크의 `bbs_id`, `.ac_title`, `.ac_instt`, `.ac_period`, `.lf_t`. `a.url-paging`과 `a.btn-paging-last`의 `miv_pageNo`로 페이지 이동/종료를 확인한다. 관찰한 마지막 페이지는 262였다. 정렬을 가정해 조기 종료하지 않는다.
- 상세 GET: `/front/epilogue/epilogueNewViewPage.do?menu_id=527&bbs_id=…&pagetype=bbs`. `.editor-content`에 본문이 있고 `.t_texts`에 기관과 선택적인 `.url-li a` 온라인접수URL이 있다. 별도 상세 API가 필요하지 않았다.
- 목록 ‘기간’은 접수기간으로 사용하지 않는다. 본문의 명시적인 **접수/응모/신청 기간**만 파싱한다. ‘공모기간’ 단독, 이미지/첨부에만 있는 정보, 연도 미상·역전·잘못된 날짜·복수 범위는 검토 대상으로 남긴다. 첨부/OCR/외부 사이트 수집은 하지 않는다.
- 접수URL은 사이트에서 접수용으로 표시한 HTTP(S) 링크만 사용한다. 외부 접수폼에서 실제 제출이 가능한지까지 검증한 것은 아니다. 접수 링크가 없으면 앱에서 원문 확인을 제공한다.
- 대학생/일반 국민/제한 자격을 분리하고 원문 자격을 보존한다. 제한 자격 공고도 탐색에서 확인할 수 있지만 학생 추천에서는 제외한다. 개별 사용자의 지원 가능 여부는 확정하지 않는다. 참가비 미상은 null이다.

**접속 검증 구분:** 공개 브라우저는 초기 화면의 실제 AJAX 목록과 상세 7건을 조회했다. 로컬 Dart/Python의 직접 HTTPS는 타임아웃으로 초기 페이지부터 실패했다. 따라서 수집기 HTTP 세션의 실사이트 종단 검증은 아직 통과하지 않았다. `out/contests-live-preview.json`은 이 실패를 `failed`로 기록한다. fixture replay의 `success`는 편집한 단일 페이지 표본에 대한 결과이며 실사이트 전체 수집 성공을 뜻하지 않는다.

## 이용 조건

[이용약관 제9조](https://modu.go.kr/front/intropage/intropageShow.do?menu_id=376&page_id=2931a43fb2c34484808c72cf44f8dd3d)는 정보 분석에 필요한 게시물 이용에 관한 조항과 작성자의 저작권, 사이트 권리의 배포·상업적 이용 제한을 함께 규정한다. 이것만으로 정기 자동 수집 및 앱 재제공의 허용 범위가 확정되었다고 판단하지 않았다. robots.txt 조회도 확인에 실패했다. **공공누리 라이선스는 확인되지 않았다.** 소통24 메타데이터에는 `license: null`, `reuseConditions: unconfirmed`, `access: public-html-not-openapi`를 기록한다.

운영 전에는 운영기관 안내/답변 등으로 요청 빈도·수집 범위·제목/기관/기간/자격 발췌의 재제공 조건과 출처 표시 조건을 확인하고, 확인일·근거 URL·허용 범위를 기록해야 한다. 로그인·접근 차단을 우회하지 않는다. 포스터와 전체 본문은 앱 피드/상태에 복제하지 않는다.

## 로컬 검토와 앱 확인 (PowerShell)

작업공간 루트에서 시작한다. `dart`/`flutter`가 PATH에 있다면 SDK 설정은 생략할 수 있다. 현재 머신에서 사용한 SDK는 아래 경로다.

```powershell
$workspace = (Get-Location).Path
$sdk = 'C:\Users\Admin\AppData\Local\Temp\liferadar-flutter-sdk'
$env:PATH = "$sdk\bin;C:\Windows\System32;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\Git\cmd;$env:PATH"
$env:PUB_CACHE = 'C:\Users\Admin\AppData\Local\Pub\Cache'

# 이번 변경은 공통 패키지 0.3.0을 사용한다. 원격에는 아직 게시하지 않았다.
Set-Location "$workspace\WOOWANGTHON_TEAM_27_BE"
@'
dependency_overrides:
  liferadar_core:
    path: ../WOOWANGTHON_TEAM_27_AI
'@ | Set-Content -Encoding utf8 pubspec_overrides.yaml
dart pub get --offline

# 관찰한 HTML 최소 fixture replay: 2026-11-12 09:00 KST 시점.
# preview 상태 파일은 운영 contests-state.json과 분리된다.
dart run bin/collect_contests.dart --fixtures=test/fixtures/sotong --now=2026-11-12T00:00:00Z --merge-with=../WOOWANGTHON_TEAM_27_FE/assets/data/events.json
dart run bin/validate_contests.dart out/events-preview.json

# 다른 터미널에서 앱을 실행하는 동안 이 서버를 유지한다 (루프백 전용).
dart run bin/serve_contest_preview.dart
```

별도 터미널에서 FE 디렉터리로 이동하고 같은 SDK/PATH/PUB_CACHE 설정을 적용한다.

```powershell
@'
dependency_overrides:
  liferadar_core:
    path: ../WOOWANGTHON_TEAM_27_AI
'@ | Set-Content -Encoding utf8 pubspec_overrides.yaml
flutter pub get --offline
flutter run -d chrome --dart-define=EVENTS_URL=http://127.0.0.1:8787/events.json --dart-define=NEWS_URL= --dart-define=TRAFFIC_URL=
```

앱에서 게스트로 진입 → 탐색 → 공모전 필터 → 공고 상세를 확인한다. 신규 공모전 관심사도 선택할 수 있다. 실제 앱 시각이 표본의 마감 이후거나 마지막 검증보다 48시간 이상 늦으면 숨김/업데이트 지연 동작이 정상이다. `previewOnly` 피드는 검토 전용이며 운영 피드로 올리지 않는다. 4건만 있는 `contests-preview.json`은 기존 앱의 최소 피드 건수(20)를 충족하지 않으므로 앱 확인에는 기존 행사와 병합한 `events-preview.json`을 쓴다. 기본 오프라인 캐시/새 피드 갱신 기준은 변경하지 않았다.

실사이트 소규모 preview (최대 1페이지/9개 상세; 운영 플래그 필요 없음):

```powershell
dart run bin/collect_contests.dart --max-pages=1 --max-details=9 --out=out/contests-live-preview.json --state=out/contests-live-preview-state.json
```

네트워크 문제를 짧게 확인하려면 `--timeout=5 --retries=0`을 덧붙인다. 기본 요청 간격 1초, 타임아웃 20초, 재시도 2회이며 타임아웃 시 요청을 abort한다. 429/5xx는 Retry-After(숫자/HTTP 날짜)를 우선한다. 60초 초과 대기는 수집을 중단하여 다음 배치로 넘긴다. 401/403/로그인 화면은 즉시 중단한다. 동일 페이지 반복/파서 구조 변경을 정상 0건으로 처리하지 않는다.

## 지속 상태와 장애

- 운영 상태 `out/contests-state.json`, preview 상태 `out/contests-preview-state.json`은 별개다. 게시물별 ID·발견/확인/검증 시각·명시적 근거·본문 해시·파서 버전·검토 사유를 저장한다. 쿠키/CSRF/이메일/전화/전체 HTML은 저장하지 않는다.
- 신규·목록 변경·활성 공고는 상세를 다시 조회한다. 그 외에도 24시간이 지나면 재검증한다. `firstSeenAt`과 ID는 중복 실행에도 유지한다.
- 목록 실패·반복·차단·의심스러운 50% 초과 건수 감소는 이전 정상 상태 전체를 보존한다. 상세 일부 실패는 해당 기존 공고를 보존하며 신규 실패 공고는 게시하지 않는다. 페이지/상세 제한은 `partial`; 제한에 걸렸다고 누락 공고를 삭제하지 않는다. 명시적인 취소와 지난 마감은 게시 대상에서 제외한다.
- 기본 운영 상한은 50페이지/450상세다. 현재 관찰한 전체 262페이지에서는 기본 상한으로 전체 성공이 될 수 없으며 `partial`이 정확한 결과다. 운영기관과 요청 범위를 합의한 후 활성 공고 필터나 상한/주기를 조정하고 다시 검증해야 한다. 이 상태를 success로 둔갑시키지 않았다.
- 본문 파싱이 퇴행하면 기존 ready 공고를 빈 날짜로 덮어쓰지 않는다. 출처별 결과/오류/마지막 성공은 `events.json.sources`에 남긴다. 출처별 검증이 전체 행사 20건 검사와 별도로 실행된다.
- 48시간 초과 검증 데이터는 앱에서 업데이트 지연으로 표시하며 확정 접수 상태·마감 추천/알림·접수/캘린더 행동을 제한한다. 원문은 계속 열 수 있다. 날짜 전용 마감은 다음날 KST 00:00부터 만료되며 임의의 23:59를 안내하지 않는다.
- 다른 출처는 유지하고 같은 출처 ID를 upsert한다. 제목+기관+마감 또는 접수URL+마감이 같은 다른 출처는 `duplicateCandidates`로만 보고하며 자동 병합하지 않는다.
- 워크플로는 data 브랜치에서 기존 행사/상태를 복원하고, 검증에 성공한 행사와 상태만 함께 복사한다. 복원/상태 무결성을 확인할 수 없으면 행사 게시를 건너뛰고 기존 피드를 유지한다. 교통·뉴스 경로와 게시 잠금은 유지했다.

## 검증 명령

각 패키지에서 `dart analyze`, AI/BE는 `dart test`, FE는 `flutter test`. 신규 테스트는 BE `test/sotong_contest_test.dart`, AI/FE `test/contest_test.dart`다. BE의 `test/fixtures/sotong/README.md`에 발췌/합성/편집 범위를 적었다. FE의 `test/fixtures/sotong-preview.json`은 그 파서 출력의 검토용 스냅샷이다.

이 머신에서는 TEMP/TMP를 각 저장소 `.test-tmp`로 지정해 Dart 테스트 임시파일 권한 문제를 해결했다. Flutter 엔진은 한글 절대경로에서 isolate 시작에 실패하여, 원본을 이동하지 않고 임시 영문 junction으로 동일 작업공간을 참조한 뒤 FE 테스트를 통과시켰다. 운영용 코드에서 경로를 하드코딩한 것은 아니다.

## 운영 활성화 순서

1. **이용 조건 및 실제 실행 환경의 접속 검증**을 완료한다. 소규모 live preview를 원문과 대조하고 실사이트 쿠키/폼/CSRF 동작도 확인한다. 페이지 제한/활성 공고 범위를 합의한다.
2. AI `liferadar_core` **0.3.0** 변경을 먼저 원격에 반영한다. BE/FE의 Git 의존성은 `^0.3.0`을 요구하도록 변경했다. 이번 검증은 ignored `pubspec_overrides.yaml`로 실제 인접 AI 코드를 사용했으며 **원격 의존성이 이미 반영되었다는 뜻이 아니다**. 원격 main은 이번 작업에서 변경하지 않았다.
3. 운영 빌드에서는 override를 제거하고, 해당 AI 커밋/태그에 BE/FE의 git ref를 고정한 뒤 `pub get`으로 lock을 갱신하고 CI를 다시 돌린다. 로컬 path override를 운영 lock에 넣지 않는다. 운영 패키지 해석/빌드는 아직 미검증이다.
4. `contest`를 이해하는 **FE를 먼저 배포**하고 구버전 클라이언트 처리 방침을 확정한다. 구버전은 알 수 없는 카테고리를 festival로 해석하므로 신버전 배포만으로 기존 설치본 문제가 사라지지 않는다. 최소 지원 버전 전환/강제 업데이트 또는 v2 EVENTS_URL로 새 앱만 전환하는 별도 피드 전략을 결정한 후 첫 contest 피드를 게시한다.
5. 위 조건이 충족된 후 저장소 Actions variable `SOTONG_ENABLED=true`로 활성화한다. 미설정/false는 네트워크 수집하지 않고 기존 검증 상태만 유지한다. 수동 로컬 통합 검증도 `$env:SOTONG_ENABLED='true'; dart run bin/collect_events.dart --no-ai`로 가능하지만 이 머신에서는 실사이트 연결이 미확인이다.

변수 변경, 원격 push, 앱 배포, data 브랜치 게시는 이 작업에서 실행하지 않았다. 일반 행사·교통·뉴스 수집은 소통24 비활성 상태에서도 기존 흐름으로 동작한다.
# 2026-11-12 수동 확인 공고 확장

`contest-review-20261112.json`은 공개 페이지를 사람이 확인한 근거 요약이다. 자동 수집 성공 결과가 아니다. 소통24 14건과 외부 공식 사이트 3건(매경 AI 광고, 하나증권 금융 아이디어, 한국원자력연구원 체험수기)을 포함한다. 재수집·재제공 조건은 모든 신규 출처에서 미확인이고 license는 null이며 운영 자동 수집은 계속 꺼져 있다.

BE 디렉터리에서 네트워크/API/AI 없이 동일한 검토 결과와 앱용 스냅샷을 생성한다:

```powershell
dart run bin/build_contest_snapshot.dart ops/contest-review-20261112.json ../WOOWANGTHON_TEAM_27_FE/assets/data/contests.json ops/contest-normalized-20261112.json
```

공식 출처: [매경](https://aimk.ai/), [하나증권](https://www.hanaw.com/contest/contest.html), [한국원자력연구원](https://www.kaeri.re.kr/board/view?linkId=13142&menuId=MENU00332). 위비티·링커리어는 발견용으로 사용하고 추가 3건의 접수기간·자격은 공식 HTML에서 확인했다. 별도 자동 크롤러는 연결하지 않았다. 매경 기업부는 참가비 20만원이 별도로 명시되어 있으며 개인 참가까지 유료/무료라고 추정하지 않았다. 연구원 공고는 방문·체험 경험이 필요하다. 하나증권 공고는 만 19세 이상·학력 제한·개인 참여 조건을 보존했다.

공모기간은 본문에 명시된 기간과 제출/접수 방법이 함께 확인될 때만 접수기간으로 사용할 수 있도록 파서를 보완했다. 목록 기간은 계속 대체값으로 쓰지 않는다. 상주시 접수 시작은 목록 9/7이 아닌 본문 10/1이다. 한국도로공사는 목록 마감 11/16보다 본문 11/15를 사용하고 차이를 상세 확인사항에 표시한다. 연장 여부를 확인하지 못한 경북 관광 공고는 제외했다. 숫자 페이지 링크와 숨겨진 마지막 페이지 링크 조합도 처리한다.

FE는 일반 행사 피드 생성 시각과 별도로 각 공모전 출처의 검증 시각을 비교한다. 새 APK의 17건이 기존 3건 캐시에 가려지지 않으며, 신규 출처를 모르는 원격 피드가 와도 보존한다. 해당 출처를 명시한 더 최신의 빈 피드는 삭제 결과로 존중한다.
