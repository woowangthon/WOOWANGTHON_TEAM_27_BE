# LifeRadar BE — 실제 데이터 파이프라인

본문 근거 기반 파업·행사 교통 영향 추출, 사건 갱신 및 앱 알림 연결은 [news_traffic/README.md](news_traffic/README.md)에 설명되어 있습니다. 기존 검색 요약 참고 카드와 검증된 교통 영향은 구분합니다.

> **WOOWANGTHON TEAM 27** · 2026 AI 우왕톤 · 주제 *"AI는 동료가 될 수 있을까?"*
>
> 저장소: [FE (Flutter 앱)](https://github.com/woowangthon/WOOWANGTHON_TEAM_27_FE) · **BE (이 저장소)** · [AI (판단 엔진·AI 모듈)](https://github.com/woowangthon/WOOWANGTHON_TEAM_27_AI)

**LifeRadar는 내 일정을 챙기는 AI 동료입니다.** 캘린더 일정과 관심사를 실제 행사·교통 통제·날씨와 연결해 "왜 나에게 중요한지"를 먼저 알려줍니다.

동료가 하는 말은 **실제 정보**여야 합니다. 이 저장소는 공공 API에서 행사와 공식 도로 통제를 **주기적으로 수집·정규화·검증**해서 앱이 받을 JSON으로 게시하는 백엔드입니다.

## 해결하는 문제

| 문제 | BE의 해결 |
|---|---|
| 행사 정보가 여러 기관 사이트에 흩어져 있다 | 4개 공공 API를 하나의 스키마(`RadarEvent`)로 정규화 |
| 앱에 넣은 데이터는 금방 낡는다 | GitHub Actions가 **매일 06:00 KST** 새로 수집, 앱은 실행할 때 최신 파일을 받는다 |
| 서울 데이터에는 영어가 없다 | Gemini로 영어 이름·설명과 관심사 태그를 생성 (사실은 원본 그대로, 새 행사만) |
| 공공 API 키·XML·http를 앱에서 직접 쓰기 어렵다 | 수집은 서버(Actions)에서, 앱은 HTTPS로 정적 JSON만 받는다 — 수집용 키는 앱에 들어가지 않는다 |
| 대중교통 파업 소식은 뉴스에만 있고, 검색하면 해외 시위·드라마·끝난 파업이 섞인다 | 네이버 뉴스를 3시간마다 검색하고 **Gemini가 판독**(상태·날짜·지역), 코드가 기사 원문 인용으로 검증 (`liferadar_core.StrikeExtractor`) |
| 일정 근처의 도로 통제를 알기 어렵다 | 서울시 TOPIS(서울 시내)와 국가교통정보센터 ITS(전국 고속도로·국도) 공식 정보를 **3시간마다** 수집 |

## 구조

```
┌──────────────── GitHub Actions (Refresh data) ────────────────┐
│ 매일 06:00 KST                                                 │
│   서울 문화행사 · TourAPI 축제 · K-Startup 공고 · KOPIS 공연(서울 밖) │
│     → 정규화 (카테고리·좌표·시간·키워드 태그)                        │
│     → Gemini 영어 번역·태그 (새 행사만, liferadar_core.AiEnrich)    │
│     → 검증 (20건 미만이면 게시하지 않음)                            │
│ 3시간마다                                                       │
│   서울시 TOPIS (서울 시내 집회·행사·공사) + ITS (전국 공사·행사·기상·재난) │
│     → 좌표 변환·유형 선별, 끝난 항목·28일 이후 제외                    │
└──────────────────────────────┬─────────────────────────────────┘
                               ▼
              data 브랜치: events.json · traffic.json
                               ▼
     앱(FE): 캐시로 즉시 표시 → 최신 파일 다운로드 → 검증 후 교체
```

게시 주소 (공개, CORS 허용):
- `https://raw.githubusercontent.com/woowangthon/WOOWANGTHON_TEAM_27_BE/data/events.json`
- `https://raw.githubusercontent.com/woowangthon/WOOWANGTHON_TEAM_27_BE/data/traffic.json`
- `https://raw.githubusercontent.com/woowangthon/WOOWANGTHON_TEAM_27_BE/data/news.json`

## 데이터 출처

| 출처 | 내용 | 규모 (11/9) | 갱신 |
|---|---|---|---|
| [서울 열린데이터광장 · 서울시 문화행사](https://data.seoul.go.kr/dataList/OA-15486/S/1/datasetView.do) | 공연·전시·축제·교육 | 303건 | 매일 |
| [한국관광공사 TourAPI 4.0 · 축제·행사](https://www.data.go.kr/data/15101578/openapi.do) | 전국 축제 (상세 설명·요금 포함) | 75건 | 매일 |
| [창업진흥원 K-Startup · 사업공고](https://www.data.go.kr/data/15125364/openapi.do) | 접수 중인 창업 지원 공고와 마감일 | 200건 | 매일 |
| [KOPIS 공연예술통합전산망](https://www.kopis.or.kr) | **서울 밖** 콘서트·클래식·연극·뮤지컬·무용·국악 (서울은 문화행사 데이터와 중복이라 제외), 공연장 좌표·요금·출연진 | 가까운 날짜 순 250건 | 매일 |
| [네이버 뉴스 검색 (NAVER API HUB)](https://www.ncloud.com/product/applicationService/naverApiHub) | "버스·지하철·철도 파업" 최근 14일 기사 → AI 판독 → 파업 사건 (11/9: 기사 150건 → 사건 14건, 예고·조건부 11건 / 11/8 실측: 인용 불일치 6건 차단) | 150건 | 3시간마다 |
| [서울시 TOPIS · 실시간 돌발정보](https://topis.seoul.go.kr) (`AccInfo`) | 서울 시내 집회·행사·훈련·공사·기상 도로 통제 | 32건 | 3시간마다 |
| [국가교통정보센터 ITS · 돌발상황정보](https://www.its.go.kr/opendata/) (`eventInfo`) | 전국 고속도로·국도·지방도의 공사·행사·기상·재난 (정체·사고·고장 제외) | 약 190건 (11/8) | 앱 실행 시 (아래 참고) |

> **ITS는 해외 IP를 차단**해 GitHub Actions(미국 리전)에서는 응답이 없습니다. 그래서 ITS는 **앱이 한국 내 기기에서 직접 조회**하고(같은 파서 `liferadar_core.ItsTraffic`), 이 파이프라인은 한국에서 실행될 때만 ITS를 함께 수집합니다.

**합계 (11/9 게시본)**: 행사 828건 — 공연 327 · 창업 지원 공고 200 · 교육 119 · 축제 100 · 전시 82. 매일 06:00 KST에 새로 수집하고, 하루에 몇 번 수동 실행해도 같은 행사는 다시 번역하지 않는다.

모두 **공공누리** 라이선스이며 앱 상세 화면에 출처를 표시합니다. 이용 약관이 스크래핑을 금지한 사이트는 사용하지 않습니다.

## 출력 형식

**`events.json`**
```jsonc
{
  "generatedAt": "2026-11-07T16:07:37Z",   // UTC
  "windowDays": 90,
  "sources": [{ "id": "seoul-culture", "name": "…", "url": "…", "license": "공공누리", "count": 331 }],
  "enrichedWith": "gemini-3.5-flash-lite",
  "events": [{
    "id": "tour-3481597", "category": "festival", "tags": ["gaming", "culture"],
    "title": { "ko": "2026 게임문화축제", "en": "2026 Game Culture Festival" },
    "description": { "ko": "…", "en": "…" },
    "start": "2026-11-19T10:00:00", "end": "2026-11-22T18:00:00",
    "venue": "벡스코", "city": "부산", "lat": 35.169, "lng": 129.136,
    "url": "…", "imageUrl": "…", "isFree": true, "price": "…",
    "source": "tour-festival", "sourceName": "한국관광공사 TourAPI · 축제·행사"
    // 공고는 "deadline", "registerUrl", "placeless": true 추가
  }]
}
```

**`news.json`** — 뉴스에서 판독한 대중교통 파업 (공식 공지가 아니므로 앱은 참고 카드로만 표시)
```jsonc
{
  "generatedAt": "…", "windowDays": 14, "articles": 150,
  "strikes": [{
    "id": "…", "mode": "rail", "operator": "공항철도", "regions": ["인천", "서울"],
    "status": "scheduled",              // preparing | conditional | scheduled | ongoing | deferred | withdrawn | ended | historical
    "quote": "공항철도가 오는 13일 노동조합의 경고파업 예고",   // 기사 원문에 그대로 있는 근거 (검증됨)
    "start": "2026-11-13", "dateQuote": "오는 13일",
    "articleTitle": "공항철도, 노조 13일 경고파업…", "url": "…", "publishedAt": "…", "sourceCount": 25
  }]
}
```

**`traffic.json`**
```jsonc
{
  "generatedAt": "…", "horizonDays": 28,
  "notices": [{
    "id": "topis-1107886", "kind": "event",            // rally | event | drill | construction | weather | other
    "title": "[통제] 청계천로 차 없는 거리 행사(청계광장~삼일교, 양방향)",
    "detail": "…원문 전체…",                            // 근거로 그대로 표시
    "start": "2026-11-07T14:00:00", "end": "2026-11-08T22:00:00",  // 종료 미상이면 생략
    "lat": 37.5688, "lng": 126.9828, "source": "seoul-topis"   // 또는 "its"
  }]
}
```

## 신뢰성

- **사실은 원본 그대로**: 날짜·장소·요금·링크는 바꾸지 않는다. Gemini는 영어 문장과 허용 목록 안의 태그만 만든다.
- **번역 품질 검사**: 가나·한자가 섞였거나 번역되지 않은 응답은 거부하고 다른 모델로 다시 요청한다.
- **추정하지 않음**: 교통 통제의 종료 시각이 없으면 비워 둔다 (앱은 시작 날짜에만 적용). 좌표·날짜가 없는 행은 버린다.
- **게시 전 검증**: 행사 20건 미만이면 게시하지 않는다. 교통 수집이 실패해도 행사는 게시한다.
- **부분 실패 허용**: 출처 하나가 실패해도 나머지로 계속하고 로그에 남긴다.
- **비용**: 번역·뉴스 판독 모두 캐시(`cache/` + Actions 캐시)로 새 행사·새 기사만 — 하루 수십 건 수준. 뉴스는 같은 기사를 두 번 판독하지 않는다 (관련 없음 판정도 저장).
- **뉴스 판독 검증**: 상태 근거 인용이 기사에 없으면 기사째 버리고, 날짜는 인용에 그 날이 있어야 인정한다 (11/8 실측: 150건 중 6건 차단).

## 실행

```bash
dart pub get
cp env.example.json env.json   # 키 입력 (또는 환경 변수)
dart run bin/collect_events.dart --out=out/events.json   # [--days=90] [--no-ai]
dart run bin/collect_traffic.dart --out=out/traffic.json
dart run bin/collect_news.dart --out=out/news.json      # [--days=14]
```

| 키 | 용도 | 발급 |
|---|---|---|
| `SEOUL_OPEN_API_KEY` | 서울 문화행사, TOPIS 돌발정보 | data.seoul.go.kr → 인증키 신청 |
| `DATA_GO_KR_KEY` | TourAPI, K-Startup (Decoding 키) | data.go.kr → 활용신청 (자동 승인) |
| `GEMINI_API_KEY` | 영어 번역·태그 | aistudio.google.com |
| `ITS_API_KEY` | 전국 돌발상황 (ITS) | its.go.kr → 오픈 API → 인증키 신청 |
| `NAVER_API_KEY_ID`, `NAVER_API_KEY` | 뉴스 검색 | NAVER API HUB (Naver Cloud) — 헤더 `X-NCP-APIGW-API-KEY-ID` / `X-NCP-APIGW-API-KEY` |
| `KOPIS_API_KEY` | 전국 공연 (KOPIS) | kopis.or.kr → 오픈API → 서비스키 신청 |

GitHub Actions에서는 같은 이름의 **Repository secrets**를 사용합니다. 수동 실행: Actions → *Refresh data* → *Run workflow*.

## 테스트

```bash
dart analyze --fatal-infos
dart test
```

23개 테스트 (CI): 출처별 실제 형식 응답 파싱(서울·TourAPI·K-Startup·KOPIS·TOPIS), 오류 코드 처리, lat/lng 뒤바뀜 보정, 무료 판정, 공고의 주소 없음 처리, 좌표 변환(EPSG:5181 → WGS84), 파싱 결과가 판단 엔진(`liferadar_core`)에서 올바른 카드를 만드는지 통합 확인.

## 구조

```
bin/
├── collect_events.dart     # 행사 수집 → out/events.json
├── collect_traffic.dart    # 교통 통제 수집 → out/traffic.json
└── collect_news.dart       # 뉴스 파업 판독 → out/news.json
lib/src/
├── config.dart             # 키: 환경 변수 > env.json
└── sources/                # seoul_culture, tour_festival, kstartup, kopis, seoul_traffic, tagger (ITS 파서는 liferadar_core)
cache/                      # Gemini 캐시 — ai_en.json(번역), news_ai.json(뉴스 판독)
.github/workflows/          # ci.yml, refresh-data.yml
```

모델과 Gemini 번역 로직은 [AI 저장소](https://github.com/woowangthon/WOOWANGTHON_TEAM_27_AI)의 `liferadar_core`를 git 의존성으로 사용합니다.

## 직접 구현 범위와 외부 기술

- **직접 구현**: 수집기 6종과 뉴스 판독 파이프라인, 정규화·태깅, 좌표 변환, 검증, 스케줄 게시 워크플로, 테스트.
- **외부 기술**: 공공 API 6종, NAVER API HUB, Google Gemini API, GitHub Actions(스케줄 실행)와 raw.githubusercontent.com(정적 배포).
- **개발 도구**: AI 코딩 도우미(Claude)를 사용했으며 커밋에 공동 작성자로 표시했습니다.

## 한계와 다음 단계

- 교통 통제: 서울은 시내 도로까지(TOPIS), 그 외 지역은 **고속도로·국도 위주**(ITS). 도시 내부 도로의 집회 통제는 경찰청 UTIC API로 보완할 예정 (키 발급 완료, 접속 IP 등록 대기) — 출력 형식과 판별 규칙은 그대로다.
- 지도·경로·날씨·카드 문장(Gemini) 키는 데모를 위해 아직 앱에 있다. 다음 단계는 이 저장소에 **API 프록시**(예: Cloud Functions)를 두어 키를 서버로 옮기는 것.
- 앱이 닫혀 있을 때의 서버 푸시(FCM)는 설계만 되어 있다 → [FE 문서](https://github.com/woowangthon/WOOWANGTHON_TEAM_27_FE/blob/main/docs/PUSH_NOTIFICATIONS.md).
- 서울 밖 공연은 하루 250건까지 (상세·공연장 조회 수 제한). IT 컨퍼런스·해커톤은 공개 API가 없어 수집하지 않는다 (앱은 `샘플` 배지가 붙은 시연 데이터로 보여준다).

## 개발 기록

2026-11-05 개인 작업 저장소에서 개발을 시작해 2026-11-08 팀 저장소로 이전했습니다. 데이터 게시도 같은 날 이 저장소의 `data` 브랜치로 옮겼습니다.

| 날짜 | 내용 |
|---|---|
| 11/7 | 서울 문화행사·TourAPI·K-Startup 수집기, Gemini 영어 번역·태그 |
| 11/8 | 매일 자동 게시(GitHub Actions), TOPIS·ITS 교통 통제, KOPIS 전국 공연, 네이버 뉴스 파업 판독, 팀 저장소 이전 |
| 11/9 | `liferadar_core` 갱신 반영(AI 비서·자기소개 제안), 테스트 이름 한국어화 |


## UTIC v2 로컬 구현 (운영 비활성)

공용 교통 모델 0.2.0과 `traffic-v2.json`을 사용하는 경로를 추가했습니다. UTIC 실 API 통제 코드·CRS·시간·완전성은 미검증이며 실제 호출은 비활성화되어 있습니다. 기존 TOPIS/ITS 경로는 유지합니다.

실행 예제: `dart run bin/collect_traffic.dart --out=out/traffic.json`, 재수집 없는 게시: `dart run bin/publish_traffic.dart --dir=out`. 내구 상태는 `out/traffic-state.json`으로 복원/백업해야 합니다. 설정은 환경변수 > env.json > 기본값 순서입니다. `UTIC_ENABLED=false`가 기본이며 true여도 계약 차단 조건을 해제하지 않습니다. 실제 비밀키는 BE 고정 IP 수집 서버에서만 사용합니다. [상세 적용 절차와 차단 지점](ops/UTIC_ROLLOUT.md)을 확인하세요.

BE/FE의 로컬 AI path override 테스트와 배포용 원격 패키지 검증은 별개입니다. AI 0.2.0 게시 후 Git 참조를 실제 immutable SHA로 고정하고 override 없는 CI를 실행해야 합니다. 이번 작업은 push/배포하지 않았습니다.
