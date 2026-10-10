# 명성 (reputation.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-030 (game-designer) |
| 구현 티켓 | SE-035 (sim-engineer) — `project/sim/reputation_config.gd`(`ReputationConfig`), `project/sim/reputation_system.gd`(`ReputationSystem`), 짝 테스트 `project/tests/sim/test_reputation_config.gd`, `project/tests/sim/test_reputation_system.gd`. HUD·해금 토스트·리포트는 SE-039 |
| 데이터 | [`project/data/reputation/reputation.json`](../../project/data/reputation/reputation.json) (version 1), 스키마 [`reputation.schema.json`](../../project/data/schemas/reputation.schema.json). 읽기 참조(복제 금지): [`tiers.json`](../../project/data/tiers/tiers.json) `rows[].unlock_reputation`·`unlock_cash`(티어 해금 임계), [`artist.json`](../../project/data/artist/artist.json) `show_grades`·`mvp_genres`·`grades[].unlock_reputation`(섭외 등급 해금 임계 — artist.md AR14), [`genres.json`](../../project/data/genres/genres.json) `rows[].affinity`(장르 유사도), [`economy.json`](../../project/data/economy/economy.json) `rate_scale`·`reference_scenarios[tier1_baseline]`, [`show.json`](../../project/data/show/show.json) `grades`(기준 시나리오의 만족 → 등급) |
| 이벤트 | [events.md](events.md)의 `reputation.*` 2행. 이 문서에 나오는 이벤트 이름은 전부 거기 표에 있다 |
| 짝 문서 | [show.md](show.md) — `show.started`·`show.ended`의 발행자 |
| 근거 | PRD "핵심 시스템 상세"(명성 행: 장르별 명성 벡터 + 종합 명성, 티어 해금과 섭외 가능 아티스트 등급을 연다, 실패한 공연은 명성을 깎는다, 입력 만족도·미디어 노출, 출력 섭외 풀·스폰서 제안·관객 기대치), "장르 매트릭스"(한 장르 집중 → 정체성 보너스, 섞으면 → 관객 폭 보너스), "성장 티어"(티어 이동은 명성 임계치와 자금을 동시에 충족, 티어 2 = 명성 500·자금 3만, 티어 2까지 약 2시간), [economy.md](economy.md) #입력-계약·#티어-2-해금-자금-도달-추정, [artist.md](artist.md) #명성과의-상호작용·T6·AR14, [audience.md](audience.md) AD1 |

## 목적

공연 결과를 **오래 남는 숫자**로 쌓는다. 공연이 끝날 때마다 등급·입장 수·장르로 명성 변화 Δ 를 정해 장르별 명성 벡터와 종합 명성을 갱신하고(`reputation.changed`), 하루 정산 뒤 명성과 자금이 다음 티어의 임계를 함께 넘으면 해금을 알린다(`reputation.tier_unlocked`).
reputation 은 **명성 값**(종합·장르별)과 **해금 진행**만 소유한다. 현금은 economy 가 정하고 reputation 은 `economy.day_settled.cash`를 읽기만 한다. 명성을 쓰는 쪽(artist 의 섭외 등급 K4, audience 의 입장 AD1)은 `reputation.changed.total`을 구독한다(CLAUDE.md 원칙 4).
이 문서와 `reputation.json`만 보고 sim-engineer 가 SE-035 의 reputation 쪽을, render-engineer 가 SE-039 의 HUD 명성·해금 토스트를 질문 없이 시작할 수 있어야 한다.

v0 범위: 종합 명성 + MVP 3장르 벡터(정수), 공연 등급별 기본값 × 입장 계수 × 장르 집중/확산 보정, 실패 공연 감소, 하한 0, 티어 2 해금 판정(게임당 1회 알림), 스냅샷.
범위 밖: 미디어 노출(티어 5), 스폰서 제안(티어 3), 장르별 명성으로 여는 섭외(버티컬 슬라이스 — v0 는 종합 명성만, artist.md #명성과의-상호작용), 시간에 따른 명성 감쇠, 경쟁 베뉴(티어 2), 티어 전환 실행(맵 교체 — 버티컬 슬라이스), 8장르 전체 벡터.

PRD 결정(티어 해금 조건: 명성 임계 ∧ 자금, 티어 2 = 명성 500·자금 30,000, 6티어)은 바꾸지 않는다. 임계 값은 `tiers.json`에만 있다.

## 규칙

### 단위

| # | 규칙 |
|---|---|
| U1 | 명성은 `int`(명성 1 단위). 종합 `total`과 장르별 `by_genre[g]` 모두 0 이상 |
| U2 | 비율은 `economy.json` `rate_scale`(10,000) 분의 bp. `⌊a ÷ b⌋`는 정수 나눗셈(내림), 피제수는 항상 0 이상이다(음수 Δ 는 크기를 먼저 계산하고 부호를 붙인다, RG5) |
| U3 | 장르 유사도 `genres.json` `affinity`(0.0~1.0 실수)는 로드 때 한 번 `affinity_bp[g][h] = roundi(affinity × 10000)`으로 바꾸고, 그 뒤로는 정수만 쓴다 |

### 입력 계약

reputation 이 구독하는 이벤트. 구독 순서는 `system_order`의 마지막(build, staff, artist, audience, show, crisis, economy, **reputation**).

| 이벤트 | reputation 동작 |
|---|---|
| `show.started {day, artist_id, genre, expected_admissions}` | `day`가 `int`이고 `genre ∈ mvp_genres`이면 `show_day = day`, `show_genre = genre`. 아니면 `push_error`, 무시 |
| `show.ended {day, artist_id, satisfaction_bp, grade, admissions, audience, …}` | #명성-갱신 RG0~RG7 |
| `economy.day_settled {day, …, cash}` | #티어-해금 TU1~TU4 |
| `time.day_started {day}` | `show_day = 0`, `show_genre = null`. 이벤트 없음 |

- `show.skipped`는 구독하지 않는다. 공연이 없는 날은 `show.ended`가 오지 않으므로 명성이 바뀌지 않는다(RG0).
- `show.ended`에는 장르가 없어서(show.md Q4) 같은 날의 `show.started.genre`를 기억해 쓴다. 공연 중 세이브가 있으므로 `show_genre`는 스냅샷에 들어간다.

### 상태

ReputationSystem 이 소유하는 상태. 전부 스냅샷 대상이다(#스냅샷).

| 필드 | 타입 | 새 게임 값 | 설명 |
|---|---|---|---|
| `total` | int | 0 | 종합 명성 |
| `by_genre` | Dictionary | `{rock: 0, indie: 0, electronic: 0}` | 장르별 명성. 키 = `artist.json` `mvp_genres`(그 순서로 만든다) |
| `show_day` | int | 0 | 마지막 `show.started.day`(그날 공연이 없었거나 날이 바뀌면 0) |
| `show_genre` | String 또는 `null` | `null` | 마지막 `show.started.genre` |
| `last_applied_day` | int | 0 | 마지막으로 명성을 갱신한 날(하루 1회 보장) |
| `unlocked_tier` | int | 1 | 해금을 알린 가장 높은 티어(시작 티어 1). MVP 에서 2 가 되면 더 오르지 않는다 |

- `total`과 `Σ by_genre`는 같지 않을 수 있다. 둘 다 하한 0 으로 따로 자르기 때문이다(RG6). 종합 명성은 "베뉴 이름값", 장르별 명성은 "이 장르로 쌓은 평판"이다.

### 명성 갱신

`show.ended` 수신 시. 위에서부터 처음 맞는 행 하나.

| # | 조건 | 결과 |
|---|---|---|
| RG0 | (공연이 없는 날) `show.ended`가 오지 않음 | 명성 변화 0, 이벤트 없음(Q2) |
| RG1 | `day`·`admissions`가 `int`가 아님, `admissions < 0`, `grade`가 `String`이 아님 | `push_error`, 무시 |
| RG1a | `grade ∉ show_grades` | `push_error`, 무시 |
| RG1b | `day != show_day` 또는 `show_genre == null` | `push_warning`, 무시(같은 날 `show.started` 없이 온 계약 위반) |
| RG1c | `day == last_applied_day` | 무시(하루 1회 — 중복 이벤트·복원 방어) |
| RG2~RG7 | 그 밖 | 아래 공식 → 상태 갱신 → `reputation.changed` |

**공식.** `g = show_genre`, `b = base_by_grade[grade]`. 이 갱신의 모든 입력은 갱신 **전** 상태다.

| 단계 | 값 | 공식 |
|---|---|---|
| RG2 | `b` (기본값) | `base_by_grade[grade]`. 실패 등급(`disaster`·`poor`)은 음수, 나머지는 양수(RL4) |
| RG3 | `f` (입장 계수, bp) | `clamp(⌊admissions × 10000 ÷ admissions_ref⌋, min_bp, max_bp)` |
| RG4 | `focus`, `bonus_bp` | `b > 0`일 때만 #장르-집중과-확산 FC1~FC4. `b < 0`이면 `focus = "none"`, `bonus_bp = 0` |
| RG5 | `Δ` (계산값) | `b > 0`: `⌊⌊b × f ÷ 10000⌋ × (10000 + bonus_bp) ÷ 10000⌋`. `b < 0`: `−⌊(−b) × f ÷ 10000⌋` |
| RG6 | 적용 | `total' = max(0, total + Δ)`, `by_genre[g]' = max(0, by_genre[g] + Δ)`. 다른 장르는 그대로 |
| RG7 | 장부 | `last_applied_day = day` |

- 상태를 전부 갱신한 뒤(tick.md E8) `reputation.changed {day, delta: total' − total, total: total', by_genre: by_genre'의 복사본}`을 낸다. `delta`는 **하한을 적용한 뒤 실제 변화량**이다(계산값 Δ 는 `compute_delta`로 따로 얻는다). 그래서 명성 0 에서 실패하면 `delta: 0`인 이벤트가 나간다(공연이 있던 날은 항상 1회).
- **실패 공연**: 계산값 Δ 는 항상 음수다. RG3 의 하한 `min_bp`와 RL4(`⌊|b| × min_bp ÷ 10000⌋ ≥ 1`) 때문에 관객이 적어도 0 이 되지 않는다. 장르 보정은 실패에 곱하지 않는다(정체성이 강한 베뉴라서 실패가 덜 아프거나 더 아프지 않다).
- **입장 계수**: 명성은 "몇 명이 봤나"에 비례하되 `admissions_ref`(100, economy 기준 공연)에서 멈춘다(`max_bp` 10,000). 티어 1 에서 100 명을 넘겨 수용을 채우면 돈은 늘지만 명성은 등급(공연 질)으로만 더 오른다 — 만석의 혼잡 감점(audience SF5)과 맞물려 "꽉 채우기"와 "좋은 공연"이 다른 선택이 된다(Q4). 하한 `min_bp`(5,000)는 관객이 적은 날도 등급의 절반은 반영한다.
- 입장 수는 `admissions`(티켓을 산 사람, 조기 퇴장 포함)를 쓴다. 조기 퇴장의 불만은 이미 평균 만족(등급)에 들어 있다.

### 장르 집중과 확산

PRD "한 장르에 집중하면 정체성 보너스, 섞으면 관객 폭 보너스"의 v0 판. `genres.json` `affinity`로 **가까운 장르는 같은 색으로 친다**(록·인디를 섞는 베뉴는 "기타 밴드 클럽"이라는 정체성이 있다).

`G` = `mvp_genres`(순서대로), `S = Σ_{h∈G} by_genre[h]`(갱신 전).

| # | 값 | 공식 |
|---|---|---|
| FC1 | 판정 가능 | `S ≥ min_genre_sum`(50). 아니면 `focus = "none"` |
| FC2 | 유사도 가중 점유율 `eff_bp` | `⌊Σ_{h∈G} by_genre[h] × affinity_bp[g][h] ÷ S⌋` (g = 오늘 장르, `affinity_bp[g][g]` = 10,000) |
| FC3 | 정체성 | `eff_bp ≥ identity_share_bp`(7,000) → `focus = "identity"`, `bonus_bp = identity_bonus_bp`(2,000) |
| FC4 | 관객 폭 | FC3 이 아니고, 모든 `h ∈ G`에서 `by_genre[h] × 10000 ≥ breadth_min_share_bp × S`(각 장르 점유율 ≥ 15%) → `focus = "breadth"`, `bonus_bp = breadth_bonus_bp`(2,000). 둘 다 아니면 `"none"`, 0 |

- 정체성이 관객 폭보다 먼저다(한 공연에 보너스는 하나).
- 두 보너스 값이 같은 이유: PRD 는 두 전략을 모두 열어 둔다. v0 에서 어느 한쪽이 정답이 되지 않게 같은 크기로 시작하고 qa 봇 통계로 나눈다(Q5).
- 어느 쪽도 아닌 경우("한두 장르를 어중간하게 섞음")는 보너스가 없다. 방향을 정하라는 신호다.

`affinity`(MVP 3장르, 대칭, 대각 1.0):

| | rock | indie | electronic |
|---|---|---|---|
| rock | 1.0 | 0.5 | 0.2 |
| indie | 0.5 | 1.0 | 0.4 |
| electronic | 0.2 | 0.4 | 1.0 |

근거: 록·인디는 둘 다 기타 밴드 공연이라 가장 가깝고, 인디·일렉트로닉은 신스 팝으로 이어지며, 록·일렉트로닉이 가장 멀다. audience `genre_fit_bp`(단골 록 10,000·인디 8,000·일렉트로닉 6,000)와 방향이 같다. 나머지 5장르의 `affinity`는 비어 있다(v0 미사용, 스키마 허용).

보정 판정 예(명성 비율 → 오늘 장르별 `eff_bp`와 `focus`, FC1 충족 가정):

| 쌓인 장르 비율 rock / indie / electronic | rock 공연 | indie 공연 | electronic 공연 | 읽기 |
|---|---|---|---|---|
| 0 / 100 / 0 | 5,000 none | 10,000 **identity** | 4,000 none | 순수 인디 클럽. 다른 장르 공연은 보너스 없음 |
| 50 / 50 / 0 | 7,500 **identity** | 7,500 **identity** | 3,000 none | 록·인디 = 기타 밴드 정체성 |
| 0 / 50 / 50 | 3,500 none | 7,000 **identity**(경계) | 7,000 **identity**(경계) | 인디·일렉트로닉도 한 색 |
| 50 / 0 / 50 | 6,000 none | 4,500 none | 6,000 none | 록·일렉트로닉 반반은 정체성도 폭도 아님 |
| 33 / 33 / 33 | 5,666 **breadth** | 6,333 **breadth** | 5,333 **breadth** | 세 장르 고루 = 관객 폭 |
| 20 / 60 / 20 | 5,400 **breadth** | 7,800 **identity** | 4,800 **breadth** | 인디 중심 + 고루: 인디는 정체성, 나머지는 폭 |
| 10 / 90 / 0 | 5,500 none | 9,500 **identity** | 3,800 none | 일렉트로닉 0 → 폭 아님 |

### 티어 해금

`economy.day_settled {day, cash, …}` 수신 시(close 진입 틱 단계 4, 정산 직후). `cash`는 정산 뒤·구제 전 값(economy.md #입력-계약). 그날 공연의 명성은 같은 틱의 단계 2 에서 이미 반영되어 있다(show.md #공연-끝 이벤트 순서).

| # | 조건 | 결과 |
|---|---|---|
| TU1 | `day`·`cash`가 `int`가 아님 | `push_error`, 무시 |
| TU2 | `next = unlocked_tier + 1`이 `tier_unlock.max_tier`(v0: 2)보다 크거나 `tiers.json`에 그 티어 행이 없음 | 아무것도 안 함 |
| TU3 | `cash ≥ tiers[next].unlock_cash` **그리고** `total ≥ tiers[next].unlock_reputation` | `unlocked_tier = next` → `reputation.tier_unlocked {tier: next, day}` |
| TU4 | 그 밖 | 아무것도 안 함 |

- **게임당 1회.** `unlocked_tier`가 스냅샷에 있으므로 복원 뒤에도 다시 알리지 않는다. 한 번의 정산에서 최대 한 티어(TU3 을 반복하지 않는다).
- **MVP 는 알림만**: 티어 전환(맵·economy `tier` 행 교체)은 버티컬 슬라이스다. 알림 뒤에도 티어 1 에서 계속 플레이하고(SE-039 토스트 "계속 플레이"), `max_tier` 2 라서 티어 3 판정은 하지 않는다.
- 파산 뒤에는 `economy.day_settled`가 오지 않으므로 해금 판정도 없다. 구제 대출을 받은 날은 `cash`(구제 전)가 음수라 해금되지 않는다.
- 두 조건 중 하나만 충족하면 알리지 않는다. 진행도 표시(SE-039 R12)는 `total ÷ unlock_reputation`, `cash ÷ unlock_cash`를 UI 가 계산한다.

### 섭외 가능 등급 (참조만)

PRD "명성이 섭외 가능 아티스트 등급을 연다". v0 규칙은 artist.md K4 가 소유한다: `reputation.changed.total ≥ artist.json grades[grade].unlock_reputation`이면 그 등급을 섭외할 수 있다(`local` 0, `rookie` — 값은 `artist.json` 한 곳, **이 문서와 `reputation.json`은 값을 복제하지 않는다**, artist.md AR14). reputation 은 `total`을 알리기만 하고 등급 가용을 판정하지 않는다.
기준 시나리오의 "rookie 해금일"(`day_reach_rookie_unlock`)은 qa 스크립트가 `artist.json`에서 임계를 읽어 계산하고 비교한다(RT2, artist.md T6).

### 관객 기대치 (참조만)

PRD 출력 "관객 기대치"의 v0 판은 audience 입장 공식의 명성 항이다(audience.md AD1~AD2: 단골 +0.02명, 뜨내기 +0.06명 / 명성 1, `reputation_cap` 2,000). audience 는 `reputation.changed.total`을 구독한다. `by_genre`는 v0 에서 아무 시스템도 읽지 않는다(리포트 표시만, show.md R10).

### 이벤트

전부 상태 이벤트(sim → 구독자). 상태를 먼저 갱신하고 낸다(E8).

| 이벤트 | 페이로드 | 발행 시점 | 1일 횟수 |
|---|---|---|---|
| `reputation.changed` | `{day: int, delta: int, total: int, by_genre: {<mvp 장르 id>: int, …}}` — `delta` = 하한 적용 뒤 `total` 변화량(0 가능), `total ≥ 0`, `by_genre` 키 = `artist.json` `mvp_genres` 전부(그 순서) | RG7 직후, `show.ended` 처리 중(공연 마지막 틱 단계 2) | 0~1(공연이 열린 날 1) |
| `reputation.tier_unlocked` | `{tier: int, day: int}` — `tier` = 새로 해금된 티어(v0 는 2 만) | TU3, `economy.day_settled` 처리 중(close 진입 틱 단계 4) | 0~1, 게임당 티어마다 1 |

- 구독자: artist(`reputation.changed.total` → K4), audience(→ AD1), SE-039 HUD·리포트·토스트. 같은 틱 안에서 artist·audience 의 갱신은 다음 날 섭외·입장부터 효과가 있다.
- 새 게임·불러오기 직후에는 이벤트가 없다. HUD 는 `ReputationSystem.total`을 읽어 초기값을 표시한다(economy.md 의 `cash` 읽기와 같은 규약). artist·audience 는 자기 스냅샷의 `reputation_total`을 갖고 있다.

### 결정성과 RNG

- reputation v0 는 **난수를 쓰지 않는다.** 어떤 스트림도 뽑지 않는다(전 스트림 상태 불변). tick.md 스트림 표에 `reputation`을 추가하지 않는다.
- 공식은 정수 곱·내림 나눗셈·`clamp`·`max`뿐이다. 순회는 `mvp_genres` 배열 순서 하나뿐이고 Dictionary 순회 순서에 기대는 결과가 없다(`by_genre` 페이로드도 `mvp_genres` 순서로 만든다).
- 같은 입력 이벤트 열이면 같은 `reputation.*` 이벤트 열과 같은 스냅샷이 나온다.

### 스냅샷

`TickLoop.register_system("reputation", rep.update, rep.snapshot, rep.restore)`로 **반드시** 등록한다(등록하지 않으면 세이브·로드로 명성이 0 이 되고 해금 알림이 다시 나온다). `update(ctx)`는 아무것도 하지 않는다.

`ReputationSystem.snapshot() -> Dictionary` = `{total, by_genre, show_day, show_genre, last_applied_day, unlocked_tier}`(깊은 복사본, 기본형만, `by_genre`는 `mvp_genres` 순서).

`ReputationSystem.restore(d) -> bool`. 정수 필드는 `int`로 정규화(JSON 왕복의 `float`, 정수값이 아니면 실패). 아래 검사를 **전부 끝낸 뒤** 적용한다(tick.md SH3). 첫 위반에서 `push_error` 1회, `false`, 상태 불변, 이벤트 0.

| # | 검사 |
|---|---|
| RR1 | 6개 키가 있고 타입이 맞음(`show_genre` String 또는 `null`) |
| RR2 | `total ≥ 0`, `show_day ≥ 0`, `last_applied_day ≥ 0` |
| RR3 | `by_genre` 키 집합 == `mvp_genres`, 값 전부 `int ≥ 0` |
| RR4 | `show_genre`가 `null`이거나 `mvp_genres` 안. `show_day == 0`이면 `show_genre == null` |
| RR5 | `1 ≤ unlocked_tier ≤ tier_unlock.max_tier` |

- 복원은 `by_genre`를 `mvp_genres` 순서로 다시 만든다(스냅샷의 키 순서를 믿지 않는다). 복원 뒤 이벤트 없음(`reputation.changed`를 다시 내지 않는다 — 구독자는 각자 스냅샷을 가진다). 복원 후 진행 = 연속 진행(SH6). `sim.json.snapshot_schema_version`은 바꾸지 않는다(`systems.reputation` 항목 추가만).
- 하지 않는 의미 검사: `total`과 `Σ by_genre`의 관계(RG6 으로 달라질 수 있다), `unlocked_tier`와 `total`의 관계(해금 뒤 실패로 명성이 임계 아래로 내려가도 해금은 유지된다).

### 설정 로드 검사

`ReputationConfig.load()`가 스키마로 못 하는 교차 검사를 한다. 실패하면 `push_error`, `null`.

| # | 검사 |
|---|---|
| RL1 | `version == 1`, `economy.json` `rate_scale == 10000` |
| RL2 | `base_by_grade` 키 집합 == `artist.json` `show_grades` |
| RL3 | `mvp_genres`의 모든 `g`가 `genres.json` 행에 있고, 모든 `g, h ∈ mvp_genres`에 대해 `affinity[g][h]`가 있음(0~1 수), `affinity_bp[g][g] == 10000`, `affinity_bp[g][h] == affinity_bp[h][g]`(U3 변환 뒤) |
| RL4 | `show_grades` 순서로 `base`가 엄격히 증가. `base < 0`인 등급이 앞쪽에 연속(실패 등급), 그 수 ≥ 1, `base > 0`인 등급 ≥ 1, `base == 0`인 등급 없음. 모든 `base < 0`에 대해 `⌊(−base) × min_bp ÷ 10000⌋ ≥ 1` |
| RL5 | `admissions_ref ≥ 1`, `1 ≤ min_bp ≤ max_bp` |
| RL6 | `min_genre_sum ≥ 1`, `breadth_min_share_bp × |mvp_genres| ≤ 10000`(관객 폭이 닿을 수 있음), `identity_share_bp ≤ 10000` |
| RL7 | `2 ≤ tier_unlock.max_tier`이고 `tiers.json`에 `tier` 2..`max_tier` 행이 모두 있음 |

`checks`·`reference_scenarios`는 런타임이 읽지 않는다(테스트·qa 용). `reputation.json`에는 `unlock_reputation` 키가 없다(티어 임계는 `tiers.json`, 섭외 임계는 `artist.json`).

### 공개 API (SE-035 구현 대상, 이름 제안)

| 클래스 | 멤버 | 설명 |
|---|---|---|
| `ReputationConfig` | `static load(path := "res://data/reputation/reputation.json") -> ReputationConfig`, `static from_dicts(reputation, artist, genres, tiers, economy: Dictionary) -> ReputationConfig` | RL1~RL7. `load`는 나머지를 기본 경로에서 읽는다(읽기 전용) |
| | `genre_ids() -> Array[String]`(`mvp_genres` 순서), `base(grade) -> int`, `admission_factor_bp(admissions: int) -> int`(RG3), `affinity_bp(g, h) -> int`, `tier_threshold(tier) -> Dictionary`(`{unlock_reputation, unlock_cash}`, 없으면 `{}`), `max_tier`, `scenario(id) -> Dictionary`(없으면 `{}`) | 읽기 전용 |
| `ReputationSystem` | `new(config: ReputationConfig, bus: EventBus)` | `show.started`, `show.ended`, `economy.day_settled`, `time.day_started` 구독. 생성자는 이벤트를 내지 않는다 |
| | `static compute_delta(cfg: ReputationConfig, by_genre: Dictionary, genre: String, grade: String, admissions: int) -> Dictionary` | 순수 함수 RG2~RG5 → `{delta, base, factor_bp, focus, eff_bp, bonus_bp}`(`eff_bp`는 FC1 미충족이면 −1. 실패 등급(`b < 0`)에서도 −1 — RG4 가 FC1~FC4 를 건너뛰므로 점유율을 계산하지 않는다, SE-035 결정 5). 입력 불변. 기준 시나리오 테스트·봇이 쓴다(SE-035 범위의 `compute_delta(...)`) |
| | `update(ctx)`(아무것도 안 함), `snapshot()`, `restore(d)` | #스냅샷 |
| | `total`, `by_genre() -> Dictionary`(복사), `unlocked_tier`, `show_day`, `show_genre`, `last_applied_day` | 읽기 전용. HUD 초기값 |

### UI 계약 (SE-039)

| 동작 | 규칙 |
|---|---|
| HUD 명성 | 새 게임·불러오기 직후 `ReputationSystem.total`, 이후 `reputation.changed.total`. Δ 는 `delta`(0 이면 표시 생략 가능) |
| 해금 토스트 | `reputation.tier_unlocked {tier}` → "티어 N 해금 — 계속 플레이"(문구 `ui_ko.json`). 티어 이름은 `tiers.json` `rows[].name`. 게임당 1회라 UI 가 따로 막지 않아도 된다 |
| 진행도(선택) | 다음 티어 = `unlocked_tier + 1`(UI 는 `tier_unlocked`를 받았으면 3 — MVP 에서는 숨김). 값은 `tiers.json` 에서 읽는다(리터럴 500·30,000 금지) |
| 마감 리포트 | show.md #마감-리포트-필드 R9·R10·R12 |

## 수치표

모든 값은 [`reputation.json`](../../project/data/reputation/reputation.json) (version 1). 임계는 `tiers.json`(티어 2: 명성 500, 자금 30,000)과 `artist.json`(신인 섭외 해금).

### 기본값 (`base_by_grade`)

| 등급 | 표시 | `base` | 근거 |
|---|---|---|---|
| `disaster` | 참사 | −30 | 호평 하루치(+22)보다 크다. 참사 한 번이 호평 하루 이상을 지운다 |
| `poor` | 부진 | −10 | 작게 깎는다(PRD "실패한 공연은 명성을 깎는다") |
| `ok` | 보통 | +12 | 호평의 약 절반. 무난한 공연도 쌓이지만 느리다 |
| `good` | 호평 | +22 | 기준 공연. 입장 83 + 정체성 보정에서 하루 +21 → 25일에 500(부록 A) |
| `rave` | 열광 | +32 | 호평의 약 1.5배. 투자(장식·실력)의 보상 |

### 입장 계수 (`admission_factor`)

| 필드 | 값 | 근거 |
|---|---|---|
| `admissions_ref` | 100 | economy 기준 시나리오와 독립인 튜닝값(명성 계수가 포화되는 입장 수). 값은 `reference_scenarios[tier1_baseline].admissions`와 같게 잡았지만 교차 검사는 없다 — economy 시나리오가 바뀌면 재검토(Q4) |
| `min_bp` | 5,000 | 관객 50 명 이하도 등급의 절반. 실패 등급 Δ 가 0 이 되지 않음(RL4: 10 × 0.5 = 5 ≥ 1) |
| `max_bp` | 10,000 | 100 명에서 멈춘다(Q4). 연동 추정에서 명성 500 도달이 자금 30,000 도달보다 1~4일 먼저 오게 하는 값(부록 C) |

### 장르 보정 (`focus`)

| 필드 | 값 | 근거 |
|---|---|---|
| `min_genre_sum` | 50 | 장르 명성 합 50 ≈ 공연 3회. 첫 공연에 "100% 집중"이 되는 것을 막는다 |
| `identity_share_bp` | 7,000 | 순수 한 장르(10,000), 가까운 두 장르 반반(록·인디 7,500, 인디·일렉트로닉 7,000)까지 정체성. 먼 두 장르(록·일렉트로닉 6,000)와 세 장르 고루(5,333~6,333)는 아님 |
| `identity_bonus_bp` | 2,000 | ×1.2. 호평 83명: 18 → 21 |
| `breadth_min_share_bp` | 1,500 | 세 장르 모두 15% 이상. 3장르 순환 중 가장 적은 장르(초반 18/96 = 18.75%)도 넘는다 |
| `breadth_bonus_bp` | 2,000 | 정체성과 같은 크기(Q5) |

### 하루 Δ 표 (계산값, `rate_scale` 10,000)

| 등급 \ 입장 | ≤ 50 | 83 | ≥ 100 | 83 + 보정(×1.2) | ≥ 100 + 보정 |
|---|---|---|---|---|---|
| 참사 | −15 | −24 | −30 | (보정 없음) −24 | −30 |
| 부진 | −5 | −8 | −10 | (보정 없음) −8 | −10 |
| 보통 | +6 | +9 | +12 | +10 | +14 |
| 호평 | +11 | +18 | +22 | +21 | +26 |
| 열광 | +16 | +26 | +32 | +31 | +38 |

예: 호평·83명·보정 = `⌊⌊22 × 8,300 ÷ 10,000⌋ × 12,000 ÷ 10,000⌋ = ⌊18 × 1.2⌋ = ⌊21.6⌋ = 21`. 참사·83명 = `−⌊30 × 8,300 ÷ 10,000⌋ = −⌊24.9⌋ = −24`.

### 티어 해금 (`tier_unlock`)

| 필드 | 값 | 근거 |
|---|---|---|
| `max_tier` | 2 | MVP 는 티어 1 맵만 있고 티어 2 해금을 알림으로만 보여 준다(SE-030 범위). 버티컬 슬라이스에서 올린다 |

## 기준 시나리오

`reputation.json` `reference_scenarios`(4개). 하루 `d`의 공연 입력 = `show_cycle[(d − 1) mod len]`(`null`이면 공연 없음 = `show.skipped`), 등급 = `show.json` 임계로 `satisfaction_bp`를 접은 값, 그날 정산 현금 = `cash.start + cash.per_day × d`. 각 날의 순서: `show.started {genre}` → `show.ended {grade, admissions}` → `economy.day_settled {cash}` → (다음 날) `time.day_started`.

| id | 공연 | 현금 | 명성 150(신인 해금) | 명성 500 | 자금 30,000 | 해금일 | 30일(40일) 끝 |
|---|---|---|---|---|---|---|---|
| `local_daily_good_30` (**AC2 기준**) | 매일 indie, 6,732(호평), 83명 | 2,000 + 1,142·d (economy `tier1_baseline`) | **8일** | **25일** | **25일** | **25일** | 621 (indie 621) |
| `rotation_good_30` | rock → indie → electronic 순환, 같은 입력 | 같음 | 8일 | 25일 | 25일 | 25일 | 621 (207 / 207 / 207) |
| `failure_floor_6` | 호평 83 → 참사 83 → 없음 → 부진 40 → 보통 83 → 열광 122 | 2,000 고정 | — | — | — | 없음 | 6일 끝 41 |
| `reputation_first_40` | `local_daily_good_30`과 같음, 40일 | 2,000 + 800·d | 8일 | 25일 | 35일 | **35일**(1회) | 831 |

- **AC2 판정**: 명성 500 도달 25일 ∈ [20, 30](`checks.tier2_reputation_day_range`), 신인 해금 8일 ∈ [6, 12](artist.md T6), 자금 도달 25일과 차이 0 ≤ 3(`tier2_reputation_cash_gap_max_days`).
- **입력의 출처**: 공연 입력은 audience `local_top_baseline`(시드 0, 손계산)을 30일 고정한 것이고, 현금은 economy 기준 시나리오의 일자 검증(시작 5,000 − 건설 3,000 = 2,000, 매일 `net` 1,142 → 25일 정산 뒤 30,550)을 그대로 붙인 **합성 시나리오**다. 두 기준 시나리오의 가정이 다르다(입장 83 vs 100, 유지비 123 vs 200). 실제 플레이에서는 명성이 오르면 입장이 늘고(AD1) 아티스트가 자라서(artist.md #성장) 둘 다 빨라진다 — 부록 C 의 연동 추정은 명성 500 이 21~24일, 자금 30,000 이 22~28일, 해금이 22~28일이다.

### 부록 A. 손계산 — `local_daily_good_30`

공통: `satisfaction_bp` 6,732 → `show.json`에서 6,000 ≤ 6,732 < 7,500 → `good`, `b = 22`. 입장 83 → `f = clamp(⌊83 × 10,000 ÷ 100⌋, 5,000, 10,000) = 8,300`. `⌊22 × 8,300 ÷ 10,000⌋ = ⌊18.26⌋ = 18`.

| 일 | 갱신 전 `S`(= indie) | FC1 (`S ≥ 50`) | `eff_bp` (indie) | `focus` | Δ | `total` |
|---|---|---|---|---|---|---|
| 1 | 0 | 아니오 | — | none | 18 | 18 |
| 2 | 18 | 아니오 | — | none | 18 | 36 |
| 3 | 36 | 아니오 | — | none | 18 | 54 |
| 4 | 54 | 예 | ⌊54 × 10,000 ÷ 54⌋ = 10,000 ≥ 7,000 | identity | ⌊18 × 12,000 ÷ 10,000⌋ = ⌊21.6⌋ = 21 | 75 |
| 5 ~ 30 | ≥ 75 | 예 | 10,000 | identity | 21 | 75 + 21 × (d − 4) |

- `total(d) = 54 + 21 × (d − 3)` (d ≥ 3). 150 이상: `21 × (d − 3) ≥ 96` → `d − 3 ≥ 4.57` → **d = 8**(159, 7일 138). 500 이상: `21 × (d − 3) ≥ 446` → `d − 3 ≥ 21.24` → **d = 25**(516, 24일 495).
- 30일 계열(`expected.total`): 18, 36, 54, 75, 96, 117, 138, 159, 180, 201, 222, 243, 264, 285, 306, 327, 348, 369, 390, 411, 432, 453, 474, 495, 516, 537, 558, 579, 600, 621.
- 현금: `cash(d) = 2,000 + 1,142 × d` → 24일 29,408(미달), 25일 30,550(도달). 25일 정산에서 `30,550 ≥ 30,000 ∧ 516 ≥ 500` → `reputation.tier_unlocked {tier: 2, day: 25}`. 26~30일은 `unlocked_tier == 2 == max_tier`라 TU2 로 아무것도 하지 않는다.
- 시간 환산(economy.md): 1일 ≈ 4분 → 25일 ≈ 100분. PRD "티어 2 까지 약 2시간" 안.

### 부록 B. 손계산 — 나머지 시나리오

**`rotation_good_30`**: 1~3일은 `S` < 50 → none, 18 씩(rock 18, indie 18, electronic 18). 4일(rock): `S = 54`, `eff_bp = ⌊(18 × 10,000 + 18 × 5,000 + 18 × 2,000) ÷ 54⌋ = ⌊306,000 ÷ 54⌋ = 5,666 < 7,000`, 점유율 각 18 × 10,000 = 180,000 ≥ 1,500 × 54 = 81,000 → breadth, 21. 6일(electronic): `S = 96`, electronic 18 × 10,000 = 180,000 ≥ 1,500 × 96 = 144,000 → breadth(점유율 18.75%). 이후 매일 breadth 21 → 궤적이 `local_daily_good_30`과 같다(두 전략 동등, Q5). 30일 끝 207 / 207 / 207.

**`failure_floor_6`**:

| 일 | 입력 | 등급 | `f` | Δ 계산 | 적용 `delta` | `total` | indie |
|---|---|---|---|---|---|---|---|
| 1 | 6,732·83 | good | 8,300 | 18 | 18 | 18 | 18 |
| 2 | 2,000·83 | disaster | 8,300 | −⌊30 × 0.83⌋ = −24 | −18 (하한 0) | 0 | 0 |
| 3 | 공연 없음 | — | — | — | (이벤트 없음) | 0 | 0 |
| 4 | 4,000·40 | poor | max(5,000, 4,000) = 5,000 | −⌊10 × 0.5⌋ = −5 | 0 (하한) | 0 | 0 |
| 5 | 5,500·83 | ok | 8,300 | ⌊12 × 0.83⌋ = 9 (S = 0 → none) | 9 | 9 | 9 |
| 6 | 7,600·122 | rave | 10,000(상한) | 32 (S = 9 → none) | 32 | 41 | 41 |

**`reputation_first_40`**: 명성은 `local_daily_good_30`과 같다(25일 516, 40일 831). 현금 `2,000 + 800 × d ≥ 30,000` → `d ≥ 35`. 25~34일은 명성만 충족 → 해금 없음(AND). 35일 정산(현금 30,000, 명성 726)에서 1회, 36~40일 없음.

### 부록 C. 연동 추정 (설계 확인, 수용 기준 아님)

기준 시나리오는 입력을 고정했다. 실제 루프에서는 명성 → 입장(AD1), 공연 → 아티스트 인기·실력(GR1·GR2) → 입장·만족이 함께 오른다. 아래는 같은 공식을 이어 붙인 추정이다: 기준 배치(수용 122, 유지비 123, 건설 2,140 → 시작 현금 2,860), 티켓 20, 같은 로컬 아티스트를 매일 섭외(승급 뒤 개런티 800), 노이즈 0, 대기 0·조기 퇴장 0(audience 손계산 B2 의 가정, 94 명 넘는 사람은 음향·시야 하나를 놓침), economy 정산 공식.

| 로컬 슬롯 (장르, 인기) | 명성 150 | 명성 500 | 자금 30,000 | 해금(둘 다) | 승급 공연 | 등급 |
|---|---|---|---|---|---|---|
| s07 (indie, 27) | 7일 | 21일 | 22일 | 22일 | 7회 | 매일 호평 |
| s03 (rock, 24) | 8일 | 21일 | 23일 | 23일 | 8회 | 호평 |
| s10 (electronic, 21) | 7일 | 21일 | 22일 | 22일 | 10회 | 호평 |
| s06 (indie, 18) | 8일 | 22일 | 24일 | 24일 | 11회 | 호평 |
| s02 (rock, 15) | 9일 | 22일 | 25일 | 25일 | 13회 | 호평 |
| s09 (electronic, 12) | 9일 | 22일 | 24일 | 24일 | 14회 | 호평 |
| s05 (indie, 9) | 10일 | 23일 | 26일 | 26일 | 15회 | 호평·열광 |
| s01 (rock, 6) | 10일 | 24일 | 28일 | 28일 | 17회 | 호평 |

- s07 일별(입장 / 평균 만족 / Δ / 명성 / 현금): 1일 83 / 6,732 / 18 / 18 / 3,688 → 4일 97 / 6,803 / 25 / 82 → 7일 113 / 6,397 / 26 / 160(승급) → 10일 122(만석) / 6,198 / 26 / 238 → 21일 122 / 6,403 / 26 / 524 / 29,647 → 22일 550 / 30,986(해금).
- 읽기: 명성 500 이 자금 30,000 보다 1~4일 먼저 온다(자금이 마지막 관문). 신인 해금(150)은 7~10일(artist.md T6 범위 6~12 안). 만석(122)이 되면 혼잡 감점으로 평균 만족이 6,200 근처까지 내려가 호평 하한(6,000)에 가깝다 — 대기가 쌓이면 보통으로 떨어질 수 있다(실측은 qa 봇).
- `max_bp`를 15,000 으로 두면(입장 122 → 계수 12,200) s07 의 명성 500 이 18일로 당겨져 자금(22일)과 4일 벌어진다. 10,000 으로 묶은 이유(Q4).
- 이 추정은 노이즈·대기·다른 아티스트 섞기·가격 변경이 없다. 봇 플레이 통계(qa, SE-042 이후)로 다시 맞춘다.

### 통합 기준 시나리오 (봇 v0, SE-057 승인)

SE-036 30일 리플레이(`replay/test_replay_tier1_loop.gd`, `SE036_LONG=1`)의 첫 실행값을 **통합 기준값**으로 승인한다. 위 `local_daily_good_30`(설계 기준, 입력 고정 합성)과 달리 실제 `GameSession` 이 시스템 7개를 함께 돌린 결과다. 출처: docs/tickets/SE-036.md 결과 절 "30일 첫 실행값", docs/reports/SE-036.md 30일 표(두 경로 값 일치), SE-057 브랜치(HEAD 723a707, SE-046 병합 뒤)에서 재실행해 같은 값을 확인했다.

**봇 v0 명령 열**: 시드 36, 1일차 낮 기준 배치 `baseline_show`(`maps/tier1_club.json` 프리셋) → 매일 낮 같은 로컬 아티스트 `thumbnail_soda`(indie, 인기 27 = 명단 슬롯 s07) 섭외 → close 에서 `time.next_day_requested`. 아티스트 1명 고정, 티켓 가격 20 고정, 건설·철거 추가 없음.

| 일 | 자금(close) | 명성 | 입장 | 개런티 | 순이익 | 비고 |
|---|---|---|---|---|---|---|
| 1 | 3,713 | 18 | 84 | 400 | 853 | |
| 4 | 6,673 | 80 | 95 | 400 | 1,100 | |
| 7 | 11,053 | 158 | 108 | 400 | 1,384 | 7번째 공연 뒤 승급(`local → rookie`), 명성 150(신인 해금) 통과 |
| 8 | 12,059 | 184 | 107 | 800 | 1,006 | 승급 뒤 첫 섭외 — 개런티 `rookie` 800 |
| 10 | 14,514 | 236 | 122 | 800 | 1,339 | 입장 상한 `capacity`(122) 도달, 이후 정상 상태 |
| 21 | 29,243 | 522 | 122 | 800 | 1,339 | **명성 500 도달** |
| 22 | 30,582 | 548 | 122 | 800 | 1,339 | **자금 30,000 도달 → `reputation.tier_unlocked {tier: 2, day: 22}`** |
| 25 | 34,599 | 626 | 122 | 800 | 1,339 | |
| 30 | 41,294 | 756 | 122 | 800 | 1,339 | 30일 끝 |

| 지표 | 통합 기준(봇 v0) | 설계 기준(`local_daily_good_30` + economy `tier1_baseline`) | 차 |
|---|---|---|---|
| 명성 150(신인 해금) | 7일 | 8일 | −1 |
| 명성 500 | **21일** | 25일 | −4 |
| 자금 30,000 | **22일** | 25일 | −3 |
| 티어 2 해금 | **22일**(1회) | 25일 | −3 |
| 30일 끝 자금 / 명성 | **41,294 / 756** | 36,260 / 621 | |
| 정상 상태 하루(10일~) | 입장 122, 매출 3,316, 임대 600, 유지비 123, 개런티 800, 바 원가 306, 세금 148, 순이익 1,339, 명성 +26 | 입장 100(현금)·83(명성), 유지비 200, 개런티 400, 순이익 1,142, 명성 +21 | |
| 구제·파산·섭외 거절 | 0 / 0 / 0 | 0 / 0 / 0 | |

**설계 기준과 다른 원인** (조정은 하지 않는다 — 밸런스 조정은 SE-042 봇 계측 몫):

1. **입장 122 vs 100(현금 가정)·83(명성 가정).** 실제 루프에서는 명성 → 입장(audience AD1)과 아티스트 인기 성장이 겹쳐 1일 84 → 10일 122 로 늘고, 10일부터 기준 배치의 수용 상한 122(`capped_by: capacity`)에 걸린다. 입장이 100 이상이면 명성 입장 계수가 `max_bp` 10,000 에 묶여(#입장-계수) 하루 Δ 가 +21 → +26 이 되고, 이것이 명성 500 을 4일 당긴다.
2. **유지비 123 vs 200.** economy `tier1_baseline` 의 200 은 가구 v0 가정 목록의 합이고, 실제 기준 배치 `baseline_show` 의 `upkeep_per_day` 합은 123 이다(부록 C 와 같은 값). 하루 +77.
3. **개런티 400 → 800(8일부터).** 아티스트 성장의 **승급**이다(artist.md #성장 GR4·GR5): `thumbnail_soda` 는 인기 27, `local` 의 호평 Δ +2 로 7번째 호평 공연 뒤 인기 41 ≥ `promote_at_popularity` 40 → `rookie`. 개런티는 섭외 시점 등급의 `economy.json guarantee_by_grade`(H1, `rookie` 800)라 8일 섭외부터 두 배다. 버그가 아니다(`artist.json` `checks.promotion_shows` s07 `good: 7` 과 같은 회수). 하루 −400.
4. 1·2 의 이득(입장 +22 → 매출 +440 근처, 유지비 +77)이 3 의 손실(−400)보다 커서 순이익 1,339 > 1,142 → 자금 30,000 이 3일 빠르다. 자금이 명성보다 1일 늦어 **자금이 해금의 병목**이다.
5. 부록 C 연동 추정 s07 행(명성 150 7일, 명성 500 21일, 자금·해금 22일, 승급 7회)과 도달일이 모두 같다. 금액은 22일 자금 30,582 vs 추정 30,986(−404 — 추정은 노이즈 0·입장 곡선 단순화).

**판정**: RT1(명성 500 20~30일) 안, 해금 1회, 구제·파산 0 — 승인. 설계 기준(25일)은 고치지 않는다. 설계 기준은 "입력 고정 손계산"이라 공식 회귀 검사(RP12·RP15)에 쓰고, 통합 기준은 "시스템이 함께 돌 때의 궤적" 회귀 검사에 쓴다. 두 값의 차이(해금 22일 vs 25일)는 PRD "티어 2 까지 약 2시간"(1일 ≈ 4분 → 22일 ≈ 88분) 안이다.

**통합 기준의 수용 기준(테스트 단언 — 리터럴 일치가 아니라 범위)**:

| # | 기준 | 데이터 출처 |
|---|---|---|
| IB1 | 30일 안에 `reputation.tier_unlocked` 정확히 1회, `tier == 2`, 해금일 ∈ `reputation.json checks.tier2_reputation_day_range`(현재 20~30) | `reputation.json`, `tiers.json` |
| IB2 | 해금일 정산의 자금 ≥ `tiers.json` tier 2 `unlock_cash`, 명성 ≥ `unlock_reputation`(리터럴 30,000·500 금지 — SE-057 AC3) | `tiers.json` |
| IB3 | 구제 0, 파산 0, 섭외 거절 0, `show.ended` 수 == 공연일 수 == 30 | — |
| IB4 | 같은 시드 2회 상태 해시·이벤트 열 동일 | — |

위 표의 금액·날짜(41,294, 21일 등)는 **기록값**이다. 테스트가 이 리터럴과 일치를 단언하지 않는다 — 데이터 조정(SE-042)마다 깨지기 때문이다. 데이터를 바꿔 이 표가 달라지면 바꾼 티켓의 game-designer 가 30일 모드를 다시 돌려 이 표와 변경 이력을 갱신한다.

## 수용 기준

### 구현 (SE-035 — `test_reputation_config.gd`는 RP1, 나머지는 `test_reputation_system.gd`)

기대 수치는 테스트에 하드코딩하지 않고 `reputation.json` `reference_scenarios`·`base_by_grade`, `tiers.json`, `show.json`에서 읽는다. 이벤트 이름·등급 id·`focus` 문자열은 리터럴로 단언한다. 공통 전제: `EventBus` + `ReputationSystem`, 입력(`show.started`, `show.ended`, `economy.day_settled`, `time.day_started`)은 테스트가 직접 발행한다. RP9(b)는 `TickLoop`으로 구동한다.

| # | 케이스 | 검증 |
|---|---|---|
| RP1 | `test_config_loads_and_cross_checks` | 실제 데이터로 `ReputationConfig.load()` 성공. RL1~RL7 을 하나씩 깬 사본 8건 이상이 `null`(`base_by_grade`에서 `rave` 제거, `ok: 0`, `poor: 15`(증가 위반), `poor: -1`(`min_bp` 5,000 에서 ⌊1 × 0.5⌋ = 0), `min_bp > max_bp`, `genres` 사본에서 `affinity.indie.rock` 0.6(비대칭), `affinity.rock.rock` 0.9, `breadth_min_share_bp: 4000`(× 3 > 10,000), `max_tier: 7`) |
| RP2 | `test_delta_by_grade` | `compute_delta`(빈 `by_genre`, 입장 `admissions_ref`)가 등급마다 `base_by_grade[grade]`와 같음. 입장 0 → 실패 등급은 `−⌊|b| × min_bp ÷ 10000⌋`(< 0), 양수 등급은 `⌊b × min_bp ÷ 10000⌋`. 입장 `2 × admissions_ref` → `admissions_ref`와 같음(상한) |
| RP3 | `test_failure_and_floor` | `failure_floor_6`을 버스로 돌려 날마다 `reputation.changed`의 `delta`·`total`·`by_genre`가 `expected.delta`·`total`과 같고, `compute_delta`가 `expected.computed_delta`와 같음. 공연 없는 날(3일) `reputation.*` 0건. 실패 등급의 계산값 < 0, `total`·`by_genre` 값 ≥ 0 |
| RP4 | `test_focus_identity_breadth` | `local_daily_good_30`·`rotation_good_30`의 `expected.focus` 날별 일치. #장르-집중과-확산 예 표 7행을 `by_genre`로 만들어 `compute_delta`의 `focus`·`eff_bp`가 표와 같음(경계 7,000 은 identity) |
| RP5 | `test_reference_30_days` | `local_daily_good_30`: 30일 `total`이 `expected.total`, 첫 `total ≥ unlock_reputation(tier 2)`인 날 == `expected.day_reach_tier2_reputation`(25), 첫 `total ≥ artist.json rookie unlock`인 날 == `day_reach_rookie_unlock`(8) — 임계는 `tiers.json`·`artist.json`에서 읽는다(SE-035 AC3) |
| RP6 | `test_tier_unlock_once` | `local_daily_good_30`·`reputation_first_40`: `reputation.tier_unlocked {tier: 2, day}`가 `expected.tier_unlocked_days`의 날에만 1회, 그 날 `economy.day_settled` 바로 뒤. 명성만·자금만 충족한 날 0건. 해금 뒤 스냅샷 왕복(JSON) → 새 시스템 복원 → 다음 정산(`cash` 더 큼) 0건(SE-035 AC4). 구제 전 `cash` 음수인 정산 0건 |
| RP7 | `test_guards` | RG1(`grade: 3`, `admissions: -1`), RG1a(`grade: "열광"` → `push_error`), RG1b(`show.started` 없이 `show.ended` → 경고), RG1c(같은 날 두 번째 `show.ended` → 무시, 이벤트 0), `show.started {genre: "jazz"}` → `push_error`, TU1(`cash: "x"`). 각 경우 스냅샷 해시 불변 |
| RP8 | `test_skipped_day_no_change` | `show.started` 없이 `time.day_started` → `economy.day_settled`만 있는 날: `reputation.changed` 0건, `total` 불변(RG0) |
| RP9 | `test_determinism_and_snapshot` | (a) 같은 입력 두 번 → `reputation.*` 이벤트 열·`snapshot()` 해시 같음, 전 RNG 스트림 상태 불변. (b) `TickLoop` 수준: 공연 중(`show.started` 뒤) `systems.reputation` 왕복 → `show.ended` → 연속 진행과 같은 `reputation.changed`. (c) 거부 사본 ≥ 5건(`total: -1`, `by_genre`에 `jazz` 추가, `by_genre.rock: -3`, `show_genre: "jazz"`, `show_day: 0`인데 `show_genre: "rock"`, `unlocked_tier: 3`) 각각 `false`, `push_error` 1회, 해시 불변, 이벤트 0. `by_genre` 키 순서를 바꾼 사본은 `true`이고 복원 뒤 `snapshot()`이 원래와 같음 |
| RP10 | `test_event_order_with_show` | show·reputation·artist 를 함께 등록한 버스에서 `audience.day_summary` 발행 → `show.ended` → `artist.grown` → `reputation.changed` 순서. `economy.day_settled` 발행 → `reputation.tier_unlocked`가 그 뒤(해금 날) |

### 데이터·문서 (SE-030, qa·reviewer)

| # | 검증 | 방법 |
|---|---|---|
| RP11 | `reputation.json` 스키마 통과(`--strict`), `base_by_grade` 키 = `show_grades`·엄격히 증가·실패 등급 음수, `genres.json` MVP 3장르 `affinity` 3×3(대각 1.0, 대칭), 나머지 5장르 `affinity` 없음 | 아래 qa 스크립트 exit 0 |
| RP12 | `reference_scenarios` 전부를 이 문서의 공식과 `show.json`·`tiers.json`·`artist.json`·`genres.json` 값으로 재계산한 값이 `expected`와 같음. `cash_from_economy_scenario`의 현금 계열이 economy 일자 검증과 같음 | 아래 qa 스크립트 |
| RP13 | **AR14**: 섭외 해금 명성은 `artist.json` `grades[].unlock_reputation` 한 곳, 티어 임계는 `tiers.json` 한 곳. `reputation.json`·`show.json`에 `unlock_reputation`·`unlock_cash` 키 없음 | 아래 qa 스크립트 + reviewer |
| RP14 | 이 문서의 이벤트 2개가 events.md 표와 같은 페이로드 | reviewer |
| RP15 | AC2 의 손계산 부록 A 가 `expected.total`과 같음 | reviewer 재계산 |

### 수치 목표 (데이터가 바뀌어도 지켜야 할 범위)

| # | 목표 | 현재 값 |
|---|---|---|
| RT1 | `local_daily_good_30`에서 명성 500(티어 2 임계) 도달일 20~30 | 25 |
| RT2 | 같은 시나리오에서 `rookie` 섭외 해금 명성 도달일 6~12 (artist.md T6) | 8 |
| RT3 | 같은 시나리오에서 명성 도달일과 자금 30,000 도달일(economy `tier1_baseline` 25일) 차 ≤ 3 | 0 |
| RT4 | 실패 등급(참사·부진)의 계산 Δ < 0, 모든 입장 수에서 | −5 이하 |
| RT5 | 집중(`local_daily_good_30`)과 확산(`rotation_good_30`)의 명성 500 도달일 차 ≤ 2 (한 전략이 정답이 되지 않음) | 0 |
| RT6 | 참사 1회의 손실 ≥ 호평 1회의 이득(같은 입장, 보정 없음) — 실패에 무게가 있다 | 24 ≥ 18 (83명) |

## 테스트 방법

- 데이터(이 티켓): `python3 tools/validate_data.py --strict` exit 0.
- qa 재계산(RP11~RP13): 리포 루트에서

```bash
python3 - <<'PY'
import json, sys
D = "project/data/"
L = lambda p: json.load(open(D + p, encoding="utf-8"))
R, S, ART, GEN, TI, ECO = L("reputation/reputation.json"), L("show/show.json"), L("artist/artist.json"), L("genres/genres.json"), L("tiers/tiers.json"), L("economy/economy.json")
G, err = ART["mvp_genres"], []
rows = {r["id"]: r for r in GEN["rows"]}
aff = {g: {h: round(rows[g]["affinity"][h] * 10000) for h in G} for g in G}
for g in G:
    if aff[g][g] != 10000: err.append("affinity 대각 " + g)
    for h in G:
        if aff[g][h] != aff[h][g]: err.append(f"affinity 비대칭 {g}-{h}")
for r in GEN["rows"]:
    if r["id"] not in G and "affinity" in r: err.append("MVP 밖 affinity " + r["id"])
B, A, F = R["base_by_grade"], R["admission_factor"], R["focus"]
bs = [B[g] for g in ART["show_grades"]]
if set(B) != set(ART["show_grades"]) or any(b <= a for a, b in zip(bs, bs[1:])): err.append(f"base 단조 {bs}")
if B["disaster"] >= 0 or B["poor"] >= 0 or min(B["ok"], B["good"], B["rave"]) <= 0: err.append("실패 등급 부호")
if any((-b) * A["min_bp"] // 10000 < 1 for b in bs if b < 0): err.append("실패 Δ 가 0 이 될 수 있음")
for name, t in (("reputation", R), ("show", S)):
    if "unlock_reputation" in json.dumps(t) or "unlock_cash" in json.dumps(t): err.append(f"AR14: {name}.json 에 해금 임계 키")
grade = lambda s: [x["id"] for x in S["grades"] if x["min_bp"] <= s][-1]
tier = {t["tier"]: t for t in TI["rows"]}
rookie = [x for x in ART["grades"] if x["id"] == "rookie"][0]["unlock_reputation"]
def delta(bg, g, gr, adm):
    b = B[gr]; f = max(A["min_bp"], min(A["max_bp"], adm * 10000 // A["admissions_ref"])); S_ = sum(bg[h] for h in G); fo = "none"
    if b < 0: return -((-b) * f // 10000), f, fo
    if S_ >= F["min_genre_sum"]:
        if sum(bg[h] * aff[g][h] for h in G) // S_ >= F["identity_share_bp"]: fo = "identity"
        elif all(bg[h] * 10000 >= F["breadth_min_share_bp"] * S_ for h in G): fo = "breadth"
    bonus = {"identity": F["identity_bonus_bp"], "breadth": F["breadth_bonus_bp"], "none": 0}[fo]
    return (b * f // 10000) * (10000 + bonus) // 10000, f, fo
for sc in R["reference_scenarios"]:
    t, bg, ut, cash = 0, {g: 0 for g in G}, 1, sc["cash"]
    got = {k: [] for k in ("grade", "factor_bp", "focus", "computed_delta", "delta", "total")}; got["tier_unlocked_days"] = []
    for d in range(1, sc["days"] + 1):
        sh = sc["show_cycle"][(d - 1) % len(sc["show_cycle"])]
        if sh is None:
            for k in ("grade", "factor_bp", "focus", "computed_delta", "delta"): got[k].append(None)
        else:
            gr = grade(sh["satisfaction_bp"]); cd, f, fo = delta(bg, sh["genre"], gr, sh["admissions"])
            nt = max(0, t + cd); bg[sh["genre"]] = max(0, bg[sh["genre"]] + cd)
            for k, v in (("grade", gr), ("factor_bp", f), ("focus", fo), ("computed_delta", cd), ("delta", nt - t)): got[k].append(v)
            t = nt
        got["total"].append(t)
        c = cash["start"] + cash["per_day"] * d; nx = ut + 1
        if nx <= R["tier_unlock"]["max_tier"] and c >= tier[nx]["unlock_cash"] and t >= tier[nx]["unlock_reputation"]:
            ut = nx; got["tier_unlocked_days"].append(d)
    first = lambda v: next((i + 1 for i, x in enumerate(got["total"]) if x >= v), None)
    got.update(by_genre_final=bg, day_reach_rookie_unlock=first(rookie), day_reach_tier2_reputation=first(tier[2]["unlock_reputation"]),
               day_reach_tier2_cash=next((d for d in range(1, sc["days"] + 1) if cash["start"] + cash["per_day"] * d >= tier[2]["unlock_cash"]), None))
    for k, v in got.items():
        if sc["expected"][k] != v: err.append(f"{sc['id']}.{k}: {sc['expected'][k]} != {v}")
    e = sc.get("cash_from_economy_scenario")
    if e:
        es = [x for x in ECO["reference_scenarios"] if x["id"] == e][0]
        if cash != {"start": ECO["starting_cash"] - es["initial_build_spend"], "per_day": es["expected"]["net"]}: err.append(sc["id"] + " 현금 != economy " + e)
    print(sc["id"], "150:", got["day_reach_rookie_unlock"], "500:", got["day_reach_tier2_reputation"], "cash:", got["day_reach_tier2_cash"], "unlock:", got["tier_unlocked_days"], "end:", t)
C = R["checks"]; m = [x for x in R["reference_scenarios"] if x["id"] == C["main_scenario"]][0]["expected"]
lo, hi = C["tier2_reputation_day_range"]; rlo, rhi = C["rookie_unlock_day_range"]
if not lo <= m["day_reach_tier2_reputation"] <= hi: err.append("RT1")
if not rlo <= m["day_reach_rookie_unlock"] <= rhi: err.append("RT2")
if abs(m["day_reach_tier2_reputation"] - m["day_reach_tier2_cash"]) > C["tier2_reputation_cash_gap_max_days"]: err.append("RT3")
print("\n".join(err) or "RP OK"); sys.exit(1 if err else 0)
PY
```

  기대 출력:
  ```
  local_daily_good_30 150: 8 500: 25 cash: 25 unlock: [25] end: 621
  rotation_good_30 150: 8 500: 25 cash: 25 unlock: [25] end: 621
  failure_floor_6 150: None 500: None cash: None unlock: [] end: 41
  reputation_first_40 150: 8 500: 25 cash: 35 unlock: [35] end: 831
  RP OK
  ```
  exit 0.
- 손계산(reviewer): 부록 A·B 를 이 문서의 공식과 데이터 값만으로 다시 계산한다(RP15).
- 헤드리스(SE-035): `tools/run_tests.sh project/tests/sim` → RP1~RP10. Godot 이 없으면 SKIP → CI(`godot-tests`).
- 변이(qa, SE-035): "TU3 의 `unlocked_tier` 갱신(1회 가드) 제거" 패치 → RP6 만 실패(SE-035 테스트 방법). "RG6 의 `max(0, …)` 제거" → RP3 만 실패. "FC4 제거" → RP4·`rotation_good_30` 만 실패.

## 열린 질문

> **결정(2026-10-09, 사람 검수 최소화 원칙):** 아래 질문 전부 추천안을 채택해 데이터와 규칙에 넣었다. ADR 이 필요한 변경은 없다(PRD 의 티어 해금 조건·임계는 그대로). 바꾸려면 새 질문으로 다시 올린다. producer 가 `docs/status/` 결정 로그로 옮긴다.

| # | 질문 | 선택지 | 채택(추천) | 바꾸면 |
|---|---|---|---|---|
| Q1 | 명성 Δ 의 꼴 | (a) `base_by_grade × 입장 계수 × 장르 보정`(정수, 난수 없음) (b) 만족 bp 에 비례하는 연속 함수 (c) 등급별 고정값만 | **(a)**(티켓 초안). 등급이 이미 만족을 접었으므로 같은 값을 두 번 쓰지 않는다. 입장 계수로 "몇 명이 봤나", 장르 보정으로 PRD 정체성/관객 폭을 넣는다. (b)는 등급의 경계감이 사라지고, (c)는 관객 5 명 공연과 100 명 공연이 같아진다 | 규칙 개정 |
| Q2 | 라인업 없는 날의 명성 | (a) 0(이벤트 없음) (b) 소폭 감소(예: −2, "잊혀짐") | **(a).** 공연 없는 날은 이미 임대료·유지비만 나가는 적자일이다(economy 기준 −800 근처). 여기에 명성 감소까지 얹으면 초반 자금난 → 공연 포기 → 명성 감소의 악순환이 생긴다. 감쇠가 필요하면 시간 감쇠로 따로(버티컬 슬라이스, 경쟁 베뉴와 함께) | (b)는 `reputation.json`에 `skip_delta` 추가(version 2) + `show.skipped` 구독 |
| Q3 | 등급별 기본값 | (a) −30 / −10 / +12 / +22 / +32 (b) −20 / −5 / +10 / +20 / +30 (c) 실패 0 | **(a).** 호평 + 정체성 + 83명에서 하루 21 → 25일에 500(AC2, economy 자금 도달과 같은 날). 참사 한 번이 호평 하루 이상을 지운다(RT6). (b)는 500 도달이 27일로 밀리고(호평 하루 19) 참사가 가볍다. (c)는 PRD "실패한 공연은 명성을 깎는다" 위반 | 데이터만 + 기준 시나리오 재계산 |
| Q4 | 입장 계수 상한 | (a) 100 명에서 10,000(상한) (b) 150 명까지 비례(15,000) (c) 입장 무관 | **(a).** 연동 추정(부록 C)에서 (b)는 만석 공연이 명성 500 을 18일에 당겨 자금(22일)과 4일 벌어지고, 꽉 채우기만이 정답이 된다. (a)는 1~4일 차이로 "같은 날 근처"를 지키고, 100 명을 넘긴 뒤에는 공연 질(등급)로만 더 오른다. 티어 2+ 는 수용이 달라 `admissions_ref`를 티어 행으로 옮길 때 다시 본다 | 데이터만(`max_bp`) |
| Q5 | 정체성 vs 관객 폭 보너스 크기 | (a) 둘 다 +20% (b) 정체성 +20%, 관객 폭 +10% (c) 정체성만 | **(a).** PRD 가 두 전략을 다 연다. 같은 값이면 v0 에서 어느 쪽도 정답이 아니고(RT5 = 0일 차), qa 봇 통계로 나중에 기울인다. (c)는 "섞으면 관객 폭 보너스" 위반 | 데이터만 |
| Q6 | 장르 유사도의 쓰임 | (a) 정체성 판정의 "가까운 장르는 같은 색"(FC2) (b) 공연 장르의 명성을 이웃 장르로 나눠 쌓기(spillover) (c) v0 미사용 | **(a).** 장르 벡터의 합이 공연 Δ 와 같게 유지되고(나눠 쌓기 없음), 록·인디 반반 같은 자연스러운 베뉴 색을 정체성으로 인정한다. (b)는 `Σ by_genre`가 부풀어 점유율 판정이 흐려진다. 관객 만족의 장르 적합은 audience `genre_fit_bp`가 따로 맡는다 | FC2 개정 |
| Q7 | `total`과 장르 벡터의 관계 | (a) 따로 갱신·따로 하한 0 (b) `total = Σ by_genre` | **(a).** PRD "장르별 명성 벡터 + 종합 명성". (b)는 다른 장르로 쌓은 명성이 0 인 장르의 실패 공연이 종합 명성을 깎지 못한다(장르 하한에 막힘) | 상태·RG6 개정 |
| Q8 | 티어 해금 자금 판정 시점·값 | (a) `economy.day_settled.cash`(정산 뒤·구제 전), 정산마다 (b) 아무 때나 `economy.cash_changed` | **(a)**(economy.md #입력-계약 결정 그대로). 하루 1회, 그날 공연 명성이 반영된 뒤 판정. 낮 건설로 현금이 잠깐 30,000 을 넘었다 내려가는 경우를 잡지 않는다 | — |
| Q9 | MVP 해금 범위 | (a) 티어 2 알림만(`max_tier` 2) (b) 티어 3 까지 판정 | **(a)**(티켓 범위). 티어 2 맵이 없는 MVP 에서 티어 3 알림은 의미가 없다 | 데이터만(`max_tier`) |
| Q10 | 해금 뒤 명성이 임계 아래로 떨어지면 | (a) 해금 유지 (b) 해금 취소 | **(a).** 알림은 사건이고 되돌리지 않는다. 티어 전환 실행(버티컬 슬라이스)에서 "전환 시점 재확인"을 따로 정한다 | — |
| Q11 | 기준 시나리오의 현금 계열 | (a) economy `tier1_baseline`(입장 100 가정) 일자 검증을 그대로 붙임 (b) 입장 83 으로 economy 공식을 다시 계산(유지비 123 → 하루 `net` 828, 자금 30,000 까지 33~34일) | **(a).** 티켓 목표가 "economy 기준 시나리오의 자금 30,000 도달 25일과 같은 날 근처"이고, 두 기준 시나리오를 각자 손계산 가능한 상태로 유지한다. 가정 차이(83 vs 100)는 #기준-시나리오에 적었고, 연동 추정(부록 C)이 실제 궤적(둘 다 22~28일)을 보여 준다 | 시나리오 데이터만 |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-10 | reputation.md v0.2, `reputation.json`·스키마 변경 없음 | SE-042 1차 (SE-035 리뷰 이관) | 공개 API `compute_delta` 행에 "`eff_bp` 는 실패 등급에서도 −1"(SE-035 결정 5, 구현과 같음)을 적었다. 공식·수치·기대값 변경 없음. 선택 항목(RP4 예 표 → `reputation.json checks.focus_examples`)은 이번에 하지 않음(데이터·스키마 변경이라 별도 티켓 후보) |
| 2026-10-10 | reputation.md v0.1, `reputation.json` v1 그대로, `reputation.schema.json` version 1 그대로 | SE-048 A | 문구·스키마 하한만. 스키마 description 의 테스트 번호(RP2·RP3·RP4·RP5)를 규칙 번호 RG2·RG3·RG4(FC1~FC4)·RG5 로 고침. `tier_unlock.max_tier` 스키마 `minimum` 1 → 2(RL7 `2 ≤ max_tier`와 일치, 범위를 좁히는 변경이라 기존 데이터 2 는 그대로 통과 — `version` 유지). `admissions_ref` 100 을 "economy 기준 시나리오와 독립인 튜닝값(교차 검사 없음, economy 시나리오 변경 시 재검토)"으로 수치표·스키마에 명시. 규칙·수치 변경 없음 |
| 2026-10-09 | reputation.md v0, `reputation.json` v1 + `reputation.schema.json` version 1, `genres.json` MVP 3장르 `affinity` | SE-030 | 신규. 상태 6필드(`total`, `by_genre`, `show_day`, `show_genre`, `last_applied_day`, `unlocked_tier`), 명성 갱신 RG0~RG7(등급 기본값 × 입장 계수 × 장르 보정, 실패 감소, 하한 0), 장르 집중/확산 FC1~FC4(유사도 가중 점유율), 티어 해금 TU1~TU4(게임당 1회, MVP `max_tier` 2), 섭외 등급·관객 기대치는 참조만(AR14), 이벤트 2종(`reputation.changed`·`reputation.tier_unlocked`), 결정성(난수 없음), 스냅샷 RR1~RR5, 로드 검사 RL1~RL7, 기준 시나리오 4개 + 손계산 부록 A·B + 연동 추정 부록 C, 수용 기준 RP1~RP15·RT1~RT6. `genres.json`: rock·indie·electronic 행에 `affinity` 3×3(대각 1.0, 대칭) — 데이터 `version` 1 유지(필드는 스키마에 이미 있음), `genres.schema.json`은 `affinity`·최상위 `description` 문구만(구조 불변). 티켓 초안에서 바꾼 것: 구독에 `show.started`(장르, show.md Q4)·`time.day_started` 추가, 구독 목록의 `time.phase_changed`는 쓰지 않음(상태에 구간이 필요 없다), `reputation.changed.delta` = 하한 적용 뒤 값 |
| 2026-10-10 | reputation.md v0 (후속 수정), 데이터 변경 없음 | SE-057 (docs/reviews/SE-036.md 발견 2·5·9, docs/tickets/SE-036.md 결과 절 "30일 첫 실행값", docs/reports/SE-036.md 30일 표) | #기준-시나리오 에 "통합 기준 시나리오 (봇 v0, SE-057 승인)" 절을 더했다: SE-036 30일 리플레이 첫 실행값(명성 500 21일, 자금 30,000·해금 22일, 30일 끝 41,294·756)을 승인하고, 설계 기준 25일과의 차이 원인 5가지(입장 122, 유지비 123, 개런티 800 = `local → rookie` 승급, 순이익 1,339, 부록 C s07 일치)와 범위 단언 IB1~IB4 를 적었다. 설계 기준 `local_daily_good_30`·RT1~RT6·`reputation.json` 값은 바꾸지 않았다(조정은 SE-042) |
