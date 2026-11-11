> 후속 수정 반영: 네 경계 결함은 수정했고 내부 전달 스냅샷과 공개 피드를 분리했다. 현재 구현/검증은 루트 `UTIC_REPAIR_RESULT.md` 및 설계 §14를 우선 참조한다. 공식 XLSX/HWP를 확보했지만 CRS/시간대/빈·철회 응답 계약과 실 API는 미검증이다.

# UTIC 적용 절차와 현재 차단 지점

2026-11-11. 로컬 구현은 실제 UTIC API 인증/통제 계약 검증 완료를 뜻하지 않는다.

## 현재 구현

- `collect_traffic.dart`: TOPIS/ITS 별 성공·실패를 내구 원장에 반영. 부분 실패는 이전 출처 데이터를 지우지 않는다. 개별 파싱 오류가 있으면 전체 완료로 보지 않는다.
- `traffic-state.json`: 출처 상태, 마지막 정상 원본 스냅샷, 철회 tombstone, 누락 횟수/최초 시각, 중복 alias. 비밀이나 원본 XML은 저장하지 않는다. 이 파일도 공개 data 브랜치에 게시하므로 공식 원문 공개 허용 범위를 확인해야 한다.
- `traffic-v2.json`: 항목별 관측 시각, sourceStates와 schemaVersion. 동일 디렉터리의 OS lock으로 원장 read/modify/write 및 게시를 직렬화하고 temp+flush+rename으로 파일 하나씩 교체한다. 공개 파일은 stagePublication으로 예약하며 내구 원장을 먼저 저장한 뒤 공개 파일을 교체한다. 여러 파일 전체의 트랜잭션은 아니며 마지막 원자적 원장과 다음 실행으로 복구한다. 동일 호스트/파일시스템 전제다.
- `traffic.json`: UTIC와 불확정 참고 항목을 제외한 구버전용 피드. KST 무오프셋 시간을 유지한다. 새 앱은 v2를 읽는다.
- `publish_traffic.dart --dir=out`: 재수집 없이 만료/병합만 수행한다. `merge_utic_snapshot.dart --snapshot=... --dir=out`: 검증된 내부 v2 UTIC 스냅샷만 병합한다. 게시 시각으로 항목 관측 시각을 갱신하지 않는다.
- UTIC fresh 60분, 최대 6시간 정책은 공용 엔진의 고정 정책이다. 숫자 env 항목은 형식 검증/향후 수집 설정 준비용이며 지금 값을 바꿔 앱 정책이 변경되지는 않는다. 정책 변경 시 AI/FE 동시 버전 갱신 필요. 기존 TOPIS/ITS 앱 캐시는 관측 시각이 있으면 24시간까지 보존한다. 메타 없는 레거시는 통제 근거로 승격하지 않는다.

## 비활성화한 부분

`UTIC_ENABLED=false`가 기본이다. true로 바꿔도 `UticXml.normalizationVerified=false` 때문에 `collect_utic.dart`는 네트워크 호출 없이 종료 코드 2로 차단한다. 미확인 코드·CRS·시간·완전성에 기본값/추정 매핑을 제공하지 않는다. 공개 XML 구조는 읽지만 모든 UTIC 원본은 정규화/운영 게시 대상에서 격리한다. 원본 보관/검토 큐 저장소는 기관 허용과 보존기간 결정 후 연결해야 한다.

`UticHttp`는 fake HTTP로 시험 가능한 별도 transport다. 문서의 HTTP 주소를 운영에서 그대로 호출하지 않는다. HTTPS 호스트/경로 allowlist, redirect 차단, timeout/크기 상한만 구현했으며 해당 HTTPS API 지원은 미검증이다. 실제 성공/오류 코드별 retry, 인증 오류 판별, polling 예산은 기관 계약 확인 후 구현해야 한다. 임의 오류 XML을 정상 빈 응답으로 처리하지 않는다.

`merge-utic.yml`은 수동·변수 조건부 예제다. 15분 schedule은 미설정이고, 승인된 저장소에서 `/tmp/utic-normalized.json`을 전달하는 단계가 없으면 실패한다. `UTIC_SNAPSHOT_URL`/READ_TOKEN은 예약 설정이며 아직 다운로드 구현에 사용하지 않는다. 저장소가 미정이므로 토큰을 임의 호스트로 보내는 downloader를 제공하지 않는다. 두 workflow는 `refresh-data` concurrency를 공유하고 최신 data 원장을 읽는다. 서버는 GitHub 쓰기 토큰을 필요로 하지 않는다.

## 적용 순서 (이번 작업에서는 실행하지 않음)

1. UTIC에 통제 코드 정의서·CRS/축 순서·시간대/형식·빈 응답/오류·철회/전체 스냅샷 의미·호출 한도·HTTPS 지원을 확인한다. 도시별 예정 집회/행사 제공 범위도 별도 확인한다. 재배포/캐시/익명화 fixture/번역 목적을 신청에 포함한다.
2. 고정 공인 출구 IP와 실행 사용자를 준비하고 IP 등록·키 발급을 진행한다. 키는 서버의 `/etc/liferadar/utic.env`(소유자만 읽기) 또는 비밀 저장소에만 둔다. FE/env/web/JSON/fixture에 넣지 않는다.
3. 등록 환경에서 성공, 정상 빈 응답, 종료/철회, 종료 미상, 오류 응답을 확보한다. 허용된 실응답을 익명화해 synthetic와 분리하고 fixture manifest에 코드표 버전·CRS·획득일을 기록한다. 현재 실제 UTIC 응답 fixture는 0개다.
4. 검증된 규칙으로 UTIC normalizer와 transport orchestration/retry를 완성하고 독립 차단 조건을 검토한다. 설정만으로 차단을 우회하지 않는다. 원본/날짜만/좌표 미확인 정보는 TrafficNotice에 자정·중심점으로 채우지 않는다. 날짜 전용 UTIC 참고 DTO는 아직 제공하지 않으며 격리한다.
5. AI 0.2.0 변경을 검토·게시한 뒤 BE/FE의 `git.ref: main`을 **실제 게시된 immutable SHA**로 바꾼다. 두 pubspec에는 `version: ^0.2.0` gate가 있다. 현재 원격 확보는 검증되지 않았고 로컬 path override로만 성공했다. 추적 중인 BE lock은 기존 원격 b7767d2 / 0.1.0을 가리키므로 그대로는 새 계약을 충족하지 않는다. lock에는 xml/petitparser만 추가하고 오프라인 검증 과정의 무관한 의존성 downgrade와 로컬 path 잠금 변경은 제거했다. override 없는 offline enforce-lockfile probe는 캐시된 원격 AI pubspec의 한글 인코딩/YAML 오류로 실패했다. 실제 새 원격 SHA와 lock을 배포 단계에서 함께 갱신해야 한다. override 없는 깨끗한 환경에서 pub get/analyze/test를 통과해야 배포 가능하다.
6. BE를 고정 SHA로 준비하고 `dart pub get`, `dart compile exe bin/collect_utic.dart -o /opt/liferadar/bin/collect-utic`로 빌드한다. `/var/lib/liferadar`를 liferadar 사용자 전용 내구 디렉터리로 준비한다. `ops` service/timer는 설치 예제이며 실제로 설치/시작하지 않았다. polling 15분은 승인 전 제안이다. 읽기 전용 systemd 보호에 맞춰 빌드/패키지 준비를 먼저 끝낸다.
7. 승인된 비공개 저장소에 정규화 결과만 쓰는 서버 업로드와 Actions 읽기 전용 다운로드를 연결한다. v2를 먼저 게시하고 검증한 뒤 새 FE를 출시한다. 기존 3시간 수집과 UTIC 병합을 분리한다. 15분 schedule은 한도·SLA 승인 후 추가한다.
8. 실 IP smoke test로 실제 통제 한 건의 시간·좌표·출처와 앱 연결, 정상 빈 응답·부분 실패·TTL·철회를 확인한 뒤 활성화한다. UTIC 포함 카드의 푸시는 계속 금지한다.

## 남은 운영 제약

- 설치/운영 배포·키/IP 등록·유료 자원 생성·remote push는 수행하지 않았다.
- GitHub Actions concurrency는 동일 저장소 workflow 사이에만 적용된다. 수동 외부 게시자는 같은 원장/단일 writer 규칙을 지켜야 한다. 브랜치 보호/원격 외부 갱신 충돌은 Git push 실패로 멈추며 force push하지 않는다.
- 전환 전 v1만 있고 원장이 없는 최초 실행은 새 정상 수집부터 원장을 만든다. 관측 시각을 모르는 v1의 generatedAt을 관측 시각으로 위장하지 않는다. 최초 v2 배포 전에 TOPIS 정상 스냅샷을 확인해야 한다.
- 3시간 TOPIS 주기와 raw GitHub 캐시/Actions 지연으로 실시간 SLA는 보장하지 않는다. 링크/방향/명시 구간이 없는 기존 항목은 교차 출처 오병합을 막기 위해 분리된다.
- tombstone/alias/누락 원장 보존기간과 정리 정책, 원본 비공개 보관, 서버 모니터링/NTP/백업은 운영 계약 확인 후 정해야 한다.


## 내부 스냅샷·철회 전송 계약 (후속 수정)

UTIC API 형식이 아닌 우리 서버 간 계약이다. `merge_utic_snapshot.dart`가 사용하는 `TrafficSourceSnapshot`은 다음 입력을 검증한다. `records`는 이번에 실제로 관측한 원본들만 보낸다. 과거 캐시를 새 observedAt으로 재포장하지 않는다. 철회에 위치/시작 정보를 만들 필요가 없다.

```json
{
  "snapshotType": "traffic-source",
  "schemaVersion": 1,
  "source": "utic",
  "observedAt": "2026-11-11T00:01:00Z",
  "complete": false,
  "records": [],
  "withdrawals": [{
    "source": "utic",
    "sourceRecordId": "synthetic-example-id",
    "status": "cancelled",
    "observedAt": "2026-11-11T00:01:00Z"
  }]
}
```

실제로 검증된 원본 갱신 시각이 있으면 withdrawal에 sourceUpdatedAt을 추가한다. 새 관측 시각만으로 명시 철회를 취소하지 않는다. 기존 공개 v2 형식으로 전송하던 정규화 원본 목록은 호환 읽기를 제공하지만, 내부 전송 검증과 공개 활성 feed 검증은 다르다. 공개 feed의 notices는 활성 항목만, withdrawals는 원본 ID 기반 철회/누락 기록을 담는다. FE는 이를 기기 ITS와 병합할 때도 적용하고 원문 갱신 revision이 더 새로 확인된 경우에만 명시 철회를 넘어선다. 정상 전체 누락(missing)은 별도 정책으로 이후 실제 재관측 시 복귀할 수 있다.

2026-11-11 원격 조회 확인: AI main=`24c611effea9410892ae0d4b439c93ada8cdd6be`, 해당 pubspec은 0.1.0. 로컬 새 공용 코드는 0.2.0이며 원격 게시/실제 SHA 고정 전 배포할 수 없다. 앞서 적힌 DNS/캐시 오류는 이전 시도 기록이고, 이번에는 직접 remote ref와 동일 Git 객체 내용을 대조했다.
