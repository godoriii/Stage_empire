# 관객 (audience.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-029 (game-designer) |
| 구현 티켓 | SE-034 (sim-engineer) — `project/sim/audience_config.gd`(`AudienceConfig`), `project/sim/audience_system.gd`(`AudienceSystem`), 짝 테스트 `project/tests/sim/test_audience_config.gd`, `project/tests/sim/test_audience_system.gd`, 성능 `project/tests/sim/test_audience_perf.gd`. 렌더는 SE-038 (render-engineer, `project/view/crowd/`) |
| 데이터 | [`project/data/audience/audience.json`](../../project/data/audience/audience.json) (version 1), 스키마 [`audience.schema.json`](../../project/data/schemas/audience.schema.json). 읽기 참조: [`artist.json`](../../project/data/artist/artist.json) `mvp_genres`·`roster_plan`, [`genres.json`](../../project/data/genres/genres.json) `rows[].id`, [`economy.json`](../../project/data/economy/economy.json) `rate_scale`·`rows[tier_1].ticket_price_default`, [`sim.json`](../../project/data/sim/sim.json) `phases`·`individual_agent_cap`·`rng_streams`·`system_order`, [`tier1_club.json`](../../project/data/maps/tier1_club.json) 입구 타일·`reference_layouts` |
| 이벤트 | [events.md](events.md)의 `audience.*` 4행과 `economy.sales_reported`(발행 주체 audience). 이 문서에 나오는 이벤트 이름은 전부 거기 표에 있다(`reputation.changed`·`show.ended`는 SE-030, `session.loaded`는 SE-036 이 등록) |
| 근거 | PRD "핵심 시스템 상세"(관객 행: 취향 분포 에이전트, 입장 → 이동 → 관람 → 소비 → 퇴장, 입력 라인업·티켓 가격·명성·홍보, 출력 입장 수·소비·만족도·혼잡), "콘텐츠 범위"(MVP 관객 유형 3, 관객 150), "기술 요구사항" 원칙 5(티어 3 까지 개별 에이전트), [economy.md](economy.md) #입력-계약·#수익-바·Q4, [build.md](build.md) #커버리지, [artist.md](artist.md) #라인업·T5, [tick.md](tick.md) #결정성과-rng·#명령-큐와-틱-순서 |

## 목적

하루의 관객을 결정적으로 만든다. 저녁 진입에 "오늘 몇 명이 오나"(입장 수 공식)를 정하고, 저녁·공연 구간에 에이전트를 틱마다 움직여(입장·이동·바·관람·조기 퇴장) 만족을 쌓고, 공연 끝에 `audience.day_summary`와 `economy.sales_reported`를 낸다.
audience 는 **오늘의 관객**(입장 결정, 에이전트 배열, 하루 집계)만 소유한다. 현금은 economy, 라인업은 artist, 커버리지는 build 가 정하고 audience 는 그 이벤트를 구독만 한다(CLAUDE.md 원칙 4).
이 문서와 `audience.json`만 보고 sim-engineer 가 SE-034 를, render-engineer 가 SE-038 을 질문 없이 시작할 수 있어야 한다.

v0 범위: 유형 3종, 입장 수 공식(라인업 인기·장르 적합·명성·티켓 가격·수용 상한 150, 시드 고정 난수 ±10%), 에이전트 ≤ 150 상태 기계(`queued → entering → moving → at_bar → watching → leaving → gone`), 타일 경로 이동과 혼잡 대기, 바 방문, 에이전트별 만족(라인업·음향·시야·가격·혼잡·대기), 하루 요약과 매출 보고, 스냅샷.
범위 밖: 흐름장·밀도 모델(티어 4+, PRD 원칙 5), 홍보·스폰서, 스태프 대기열 해소(`staff.md`), 사고·민원(`events_crisis.md`), 화장실 방문 상태(Q6), 공연 등급 판정(`show.md`, SE-030), 명성 갱신(`reputation.md`), 바 매출 공식 변경(economy 입력 변경, Q3).

PRD 결정(고정 틱 10/s, 티어 1~3 개별 에이전트, MVP 관객 유형 3·관객 150, 8장르 중 MVP 3)은 바꾸지 않는다.

## 규칙

### 단위

| # | 규칙 |
|---|---|
| U1 | 인원·틱·좌표·금액은 전부 `int`. 비율은 `economy.json` `rate_scale`(10,000) 분의 bp(`*_bp`). `float` 상태 없음(economy R1·R2 와 같은 이유) |
| U2 | 입장 공식의 중간값은 **1/100 명(centi-person)** 단위 정수(`*_centi`). 사람 수로 바꿀 때만 내림 |
| U3 | `⌊a ÷ b⌋`는 정수 나눗셈(내림). 이 문서의 모든 피제수는 0 이상이다(음수가 될 수 있는 곳은 먼저 `max(0, …)` 또는 `clamp`) — GDScript `int / int`와 같다 |
| U4 | 타일 좌표 `[x, z]`는 build.md G1 그대로. 에이전트 표시 좌표는 고정소수 `pos_scale`(100) 배: 타일 `(x, z)`의 중앙 = `[x × 100 + 50, z × 100 + 50]`, 값 ÷ `pos_scale` = m(`sim.json` `tile_size_m` 1.0) |

### 관객 유형

`audience.json` `types`(배열 순서 = 유형 순서, 모든 순회·`by_type` 나머지 배분이 이 순서). 수치는 #수치표.

| id | 이름 | 성격 | 라인업 없는 날 |
|---|---|---|---|
| `regular` | 로컬 단골 | 베뉴를 보고 온다. 인기 무관, 명성에 조금 반응, 록에 가장 맞고 일렉트로닉에 덜 맞음. 가격에 둔감, 바를 자주 들르고 오래 참는다 | 온다(소수) |
| `genre_fan` | 장르 팬 | 오늘 아티스트를 보고 온다. 인기에 크게 반응, 명성 무관. **그날 라인업 장르의 팬**이라 장르 적합이 항상 10,000. 음향 자리를 가장 원한다 | 안 온다 |
| `walk_in` | 뜨내기 | 지나가다 공연이 있으면 들어온다. 명성에 가장 크게 반응, 일렉트로닉(클럽 나이트)에 잘 맞음. 가격에 가장 민감, 바를 좋아하고 금방 지친다 | 안 온다 |

- 유형 필드: `color`(군중 인스턴스 색, SE-038 이 읽는다 — 임시 hex, 팔레트 티켓에서 `pal_*` id 로 교체, 스키마가 둘 다 받는다), `needs_lineup`, `base_centi`·`popularity_centi`·`reputation_centi`(흡인), `genre_fit_bp`(장르 선호 벡터 = 장르 적합표), `price_sensitivity_bp`, `bar_visit_bp`(바 구매 성향), `patience_ticks`(대기 허용), `spot_weights_bp`(관람 자리 선호).
- `genre_fit_bp`의 키 집합은 `artist.json` `mvp_genres`(`rock`, `indie`, `electronic`)와 같다(로더 AL3). MVP 장르의 단일 출처는 artist.json 이고 audience.json 은 키로만 쓴다(artist.md #MVP-장르). 나머지 5장르는 `genres.json`에 남고 v0 관객 표에 없다.

### 입력 계약

audience 가 구독하는 이벤트. 구독 순서는 `system_order`(build, staff, artist, **audience**, show, …) — artist 뒤, show 앞.

| 이벤트 | audience 동작 |
|---|---|
| `build.coverage_changed {has_stage, capacity, satisfaction_bonus_bp, viewing_tiles, sound_tiles, sight_tiles, bar_tiles, …}` | 7개 필드를 `coverage`에 저장하고 자리 순위(#자리-선택)를 다시 만든다. 형식 오류(필드 없음·타입 다름·좌표가 int 2원소 배열 아님)면 `push_warning`, 무시. 저녁 진입 틱에 `cause:"sync"`로 반드시 한 번 온다(build.md) |
| `artist.lineup_set {day, artist_id, genre, grade, popularity, skill}` | #입장-수 결정(저녁 진입 틱 단계 4). 아래 LS1~LS4 |
| `reputation.changed {total, …}` (SE-030) | `total`이 `int ≥ 0`이면 `reputation_total = total`, 아니면 `push_warning` 후 무시 |
| `economy.ticket_price_changed {price, from}` | `price`가 `int ≥ 1`이면 `ticket_price = price`, 아니면 `push_warning` 후 무시. 새 게임 값은 `economy.json` `rows[tier_1].ticket_price_default`(20) |
| `time.phase_changed {from, to, day, tick}` | `phase = to`, `day = day`. `to == "close"`인데 에이전트·도착 대기가 남아 있으면 계약 위반(공연 끝 처리 누락)이라 `push_warning` 후 비운다 |
| `time.day_started {day}` | `day = day`, `today = null`, `arrivals = []`, `agents = []`(이미 비어 있어야 한다) |

라인업 수신 판정 — 위에서부터 처음 맞는 행.

| # | 조건 | 결과 |
|---|---|---|
| LS1 | `phase != "evening"` 또는 `payload.day != day` | `push_warning`, 무시 |
| LS2 | `today != null`(오늘 이미 결정) | `push_warning`, 무시(하루 1회) |
| LS3 | `artist_id`가 `String`도 `null`도 아님. 또는 `artist_id`가 `String`인데 `genre`가 `genre_fit_bp` 키가 아니거나 `popularity`·`skill`이 0~100 `int`가 아님 | `push_error`, 무시(그날은 결정 없음 → 입장 0, 요약은 0 으로 나감) |
| LS4 | 그 밖 | `lineup` = `artist_id == null`이면 `null`, 아니면 `{artist_id, genre, grade, popularity, skill}` → #입장-수 AD1~AD12 |

artist 가 등록되지 않은 실행(테스트)에서는 `artist.lineup_set`이 오지 않으므로 결정이 없고 입장은 0 이다. 라인업이 없는 날(`artist_id: null`)은 결정이 **있다**(단골만, LS4).

### 상태

AudienceSystem 이 소유하는 상태. 파생값(자리 순위, 타일 점유 수, 자리 예약 수)을 빼고 전부 스냅샷 대상이다(#스냅샷).

| 필드 | 타입 | 새 게임 값 | 설명 |
|---|---|---|---|
| `day` | int | 1 | `time.*`을 따라온 현재 날 |
| `phase` | String | `"day"` | `time.phase_changed.to`를 따라온 구간 |
| `ticket_price` | int | `ticket_price_default` | `economy.ticket_price_changed`를 따라온 가격 |
| `reputation_total` | int | 0 | `reputation.changed.total` |
| `lineup` | Dictionary 또는 `null` | `null` | 오늘 결정에 쓴 라인업 `{artist_id, genre, grade, popularity, skill}` |
| `coverage` | Dictionary | `{has_stage: false, capacity: 0, satisfaction_bonus_bp: 0, viewing_tiles: [], sound_tiles: [], sight_tiles: [], bar_tiles: []}` | 마지막 `build.coverage_changed`의 7개 필드 |
| `today` | Dictionary 또는 `null` | `null` | 오늘 결정 `{day, admissions, expected, noise_bp, capped_by, has_lineup, by_type, left_early, bar_buyers}`. `left_early`·`bar_buyers`는 진행 중 누적 |
| `arrivals` | Array | `[]` | 아직 도착하지 않은 에이전트 `[id, type, spawn_tick, bar_planned]`, id 오름차순 |
| `agents` | Array | `[]` | 도착한 에이전트(#에이전트-레코드), id 오름차순 |
| `next_id` | int | 1 | 다음 에이전트 id. 게임 전체에서 증가만 한다(재사용 없음) |

**에이전트 레코드**(Dictionary, 키 고정, 값은 기본형):

| 키 | 타입 | 뜻 |
|---|---|---|
| `id` | int | 에이전트 id(≥ 1) |
| `type` | String | 유형 id |
| `state` | String | `queued`·`entering`·`moving`·`at_bar`·`watching`·`leaving`·`gone` |
| `tile` | `[x, z]` 또는 `null` | 서 있는(또는 출발한) 타일. `queued`는 `null`(아직 맵 밖) |
| `next` | `[x, z]` 또는 `null` | 건너가는 중인 타일(이동 중이 아니면 `null`) |
| `progress` | int | 건너기 진행 틱 1~`move_ticks_per_tile`(이동 중이 아니면 0) |
| `target` | `[x, z]` 또는 `null` | 목표 타일 |
| `target_kind` | String | `""`·`"bar"`·`"spot"`·`"exit"` |
| `path` | Array[`[x, z]`] | 목표까지 남은 타일(현재 타일 제외, `next` 제외) |
| `enter_left` | int | `entering` 남은 틱 |
| `bar_left` | int | `at_bar` 남은 틱 |
| `bar_planned` | bool | 아직 바에 들를 예정 |
| `wait` | int | 누적 대기 틱 |
| `show_ticks`, `sound_ticks`, `sight_ticks` | int | 공연 구간 집계(SF1) |
| `left_early` | bool | 조기 퇴장 여부 |
| `sat` | int | 확정 만족 bp. 확정 전 −1 |

**파생값**(스냅샷에 넣지 않고 복원·커버리지 수신 때 다시 만든다): 유형별 관람 자리 순위 `spot_rank[type]`, 바 자리 순위 `bar_rank`, 입구 타일 목록 `entrances`(맵의 `entrance` 타일, z·x 오름차순), 타일 점유 수 `occ(t)`(= `state ∈ {entering, moving, at_bar, watching, leaving}`인 에이전트의 "점유 타일" — `next`가 있으면 `next`, 없으면 `tile` — 이 `t`인 수), 자리 예약 수 `claims(t)`(= `target_kind ∈ {"bar", "spot"}`이고 `target == t`인 에이전트 수).

### 입장 수

LS4 에서 한 번 계산한다(저녁 진입 틱, tick.md 단계 4 의 `time.phase_changed` 연쇄 안, `build.coverage_changed {sync}` 뒤 — artist.md #라인업 "전달 순서"). 결과는 `today`와 `arrivals`에 담고 `audience.admissions_decided`를 낸다.

| 단계 | 값 | 공식 |
|---|---|---|
| AD1 | `rep` | `min(reputation_total, reputation_cap)` |
| AD2 | `draw_t` (centi) | `needs_lineup_t`이고 `lineup == null`이면 0. 아니면 `base_centi_t + (lineup ? popularity_centi_t × popularity : 0) + reputation_centi_t × rep` |
| AD3 | `fit_t` (bp) | `lineup ? genre_fit_bp_t[genre] : 10000` |
| AD4 | `price_t` (bp) | `clamp(10000 − price_sensitivity_bp_t × (ticket_price − price_ref), price_factor_min_bp, price_factor_max_bp)` |
| AD5 | `e_t` (centi) | `⌊⌊draw_t × fit_t ÷ 10000⌋ × price_t ÷ 10000⌋` |
| AD6 | `E` (centi), `expected` (명) | `E = Σ_t e_t`, `expected = ⌊E ÷ 100⌋` |
| AD7 | `noise_bp` | `u = rng.stream("audience").randi()`(uint32), `noise_bp = (u mod (2J + 1)) − J`, `J = noise_bp`(데이터 1,000). **결과와 무관하게 항상 1회 뽑는다** |
| AD8 | `raw` (명) | `⌊E × (10000 + noise_bp) ÷ 1,000,000⌋` |
| AD9 | `admissions`, `capped_by` | `has_stage == false`면 0·`"no_stage"`. 아니면 `min(raw, capacity, max_agents)`, `capped_by` = `raw ≤ min(capacity, max_agents)`면 `"none"`, 아니면 `capacity ≤ max_agents`이면 `"capacity"` 아니면 `"max_agents"` |
| AD10 | `by_type` | 최대 나머지 배분: `n_t = ⌊admissions × e_t ÷ E⌋`(`E == 0`이면 모두 0), 남은 `admissions − Σ n_t`명을 나머지 `(admissions × e_t) mod E`가 큰 유형부터 1명씩, 같으면 유형 순서가 앞인 쪽 |
| AD11 | 도착 순서 | 유형 순서대로 `n_t`개씩 늘어놓은 길이 `N = admissions` 배열 `L`(예: `[regular×10, genre_fan×43, walk_in×30]`)을 Fisher–Yates 로 섞는다: `i = N−1`부터 1 까지 `j = rng.stream("audience").randi() mod (i + 1)`, `L[i] ↔ L[j]`. 뽑기 `max(0, N − 1)`회 |
| AD12 | `arrivals` | `k = 0..N−1`에 대해 `[next_id + k, L[k], ⌊k × arrival_window_ticks ÷ N⌋, bar_planned]`. `bar_planned` = 그 유형 안에서 `k` 순으로 앞의 `⌊n_t × bar_visit_bp_t ÷ 10000⌋`명이면 `true`. 그 뒤 `next_id += N` |

- 상태를 전부 갱신한 뒤(tick.md E8) `audience.admissions_decided {day, admissions, expected, noise_bp, capacity, capped_by, has_lineup, by_type}`를 낸다. 이 이벤트의 구독자 연쇄는 E2 로 `artist.lineup_set` 구독자들 뒤에 전달된다.
- **가격 → 입장 반응**(economy.md Q4 의 답): 가격이 `price_ref`(20)보다 높으면 AD4 가 유형마다 `price_sensitivity_bp`씩 떨어진다. 그래서 가격을 올리면 입장 수가 줄고(AU5), 기준 배치에서 티켓 매출은 20~25 근처가 최대다(#수치표 "가격 반응").
- **수용 상한 150.** `capacity`(build C4, 이미 `tiers.capacity_max` 150 이하)와 `max_agents`(150) 둘 다로 자른다. 그래서 하루 에이전트는 150 을 넘지 않는다(AU6).
- **아티스트 없는 날**: `needs_lineup`인 두 유형은 0 이고 단골만 온다(기준 배치·명성 0 에서 12명, AU1).
- **무대가 없으면**(`has_stage == false`) 관람 타일이 없어 아무도 받지 않는다. 그래도 AD7 은 1회 뽑는다(스트림 소비가 배치에 따라 달라지지 않게).
- 범위: `E`는 유형당 `(3,000 + 100 × 160 + 2,000 × 6) × 10,000 × 20,000` 수준이라 int64 안이다.

### 자리 선택

관람 자리와 바 자리는 `coverage`의 타일 집합에서 고른다. 이 순위는 결정적이고 난수를 쓰지 않는다.

| # | 규칙 |
|---|---|
| SP1 | **관람 자리 순위** `spot_rank[type]` = `viewing_tiles` 전부를 아래 키로 오름차순 정렬: ① `−score(t)`, ② `cdist(t)`, ③ `z`, ④ `x`. `score(t) = sound_w × [t ∈ sound_tiles] + sight_w × [t ∈ sight_tiles] + bar_w × [t ∈ bar_tiles]`(유형의 `spot_weights_bp`) |
| SP2 | `cdist(t)` = 기준 집합 `C`의 무게중심까지 거리의 정수 대리값 `(x·n − Σx)² + (z·n − Σz)²`(`n = |C|`, 합은 `C` 원소). 관람 자리의 `C` = `sound_tiles`(비면 `viewing_tiles`) — 스피커가 무대 앞에 있으므로 "무대 앞 가운데"로 모인다 |
| SP3 | **바 자리 순위** `bar_rank` = `bar_tiles`를 ① `cdist(t)`(`C` = `bar_tiles`), ② `z`, ③ `x` 오름차순 — 바 서비스 반경의 가운데(= 바 카운터 앞)부터 |
| SP4 | **고르기**: 순위에서 처음으로 `claims(t) < spot_tile_cap`이고 `TilePath`가 출발 타일 → `t` 경로를 돌려주는 타일. 고르면 그 타일을 예약(`target = t`, `target_kind`, `path` = 경로). 관람 타일은 build C0 의 도달 집합 안이라 경로는 항상 있다. 없으면(빈 배열) 다음 타일 |
| SP5 | **출구 고르기**: `entrances` 중 출발 타일에서 `TilePath` 경로 길이가 가장 짧은 것, 같으면 입구 순서가 앞인 것. 출발 타일이 입구면 경로는 빈 배열 |

- `TilePath`는 SE-032 의 `AStarGrid2D` 래퍼(4방향, 대각 금지, 같은 입력 같은 경로)다. 걸을 수 있는 타일 = 맵 `walkable`이고 가구가 점유하지 않은 타일(build C0 와 같은 그래프). **다른 에이전트는 경로를 막지 않는다**(혼잡은 이동 단계에서 처리, MV2).
- 경로는 목표가 정해질 때 한 번 구하고(`path`에 저장, 경로 캐시) 그 뒤 앞에서 하나씩 꺼낸다. 커버리지는 낮에만 바뀌므로(build B2) 저녁·공연 중 경로가 낡지 않는다.

### 상태 기계

`AudienceSystem.update(ctx)`(tick.md 단계 2)는 `ctx.phase ∈ {"evening", "show"}`일 때만 일한다. 한 틱의 순서:

| 단계 | 동작 |
|---|---|
| UP1 | (`evening`만) `arrivals` 앞에서부터 `spawn_tick ≤ ctx.tick_in_phase`인 것을 모두 꺼내 `agents` 끝에 붙인다: `state "queued"`, `tile null`, 나머지 0·`null`·`""`, `sat −1`, `bar_planned`는 도착 정보 값 |
| UP2 | `agents`를 **id 오름차순**으로 한 명씩: 그 에이전트의 **틱 시작 상태**로 아래 전이표에서 처음 맞는 행 하나를 적용한다. 앞 에이전트의 결과(점유·예약)는 뒤 에이전트가 바로 본다 |
| UP3 | 같은 에이전트의 행 직후, `ctx.phase == "show"`이고 `left_early == false`이고 `state != "gone"`이면 SF0 집계 |
| UP4 | (`show` 마지막 틱 = `ctx.tick_in_phase == show 구간 틱 수 − 1`만) #공연-끝 FN1~FN3 |
| UP5 | `audience.agent_moved {tick: ctx.tick, agents}` 1회 발행(#이벤트). 그 뒤 `state == "gone"`인 에이전트를 `agents`에서 뺀다 |
| UP6 | (`show` 마지막 틱만) `audience.day_summary` → `economy.sales_reported` 발행(#공연-끝 FN4) |

`ctx.phase`가 `day`면 아무것도 하지 않는다(이벤트 0). close 구간에는 틱이 없다. 그래서 `agent_moved`는 하루에 정확히 `evening 600 + show 900 = 1,500`회다.

**전이표.** "대기 +k" = `wait += k` 후 **P1** 검사. "이동 칸" = MV1~MV3. 만족 변화 열은 그 행이 만족 요소(#만족)에 주는 영향이다.

| # | 상태 | 조건 | 다음 상태 | 동작 | 만족 변화 |
|---|---|---|---|---|---|
| T1 | (도착 전) | UP1 의 `spawn_tick` 도달 | `queued` | `agents`에 추가 | — |
| T2 | `queued` | 빈 입구가 있다: `entrances` 순서로 처음 `occ(e) == 0`인 입구 `e` | `entering` | `tile = e`, `enter_left = entry_ticks` | — |
| T3 | `queued` | 빈 입구 없음 | `queued` | 대기 +1. P1 로 떠나면 맵에 들어온 적이 없으므로 바로 `gone`(T12 경로 없음) | 대기 ↑ |
| T4 | `entering` | `enter_left > 1` | `entering` | `enter_left −= 1` | — |
| T5 | `entering` | `enter_left == 1` | `moving` | `enter_left = 0`. `bar_planned`면 SP4 로 바 자리. 바 자리가 없으면 `bar_planned = false`, 대기 +`bar_fail_wait_ticks`. (떠나지 않았으면) 바 자리가 정해지지 않았을 때 SP4 로 관람 자리. 둘 다 없으면 P1 과 같은 조기 퇴장(`reason "no_spot"`) | 대기 ↑(바 실패) |
| T6 | `moving`·`leaving` | `next != null` | 같은 상태 | `progress += 1`. `progress == move_ticks_per_tile`이면 `tile = next`, `next = null`, `progress = 0` 후 **같은 틱에 T9 검사** | — |
| T7 | `moving` | `next == null`, `path` 비어 있지 않음, `occ(path[0]) < pass_tile_cap` | `moving` | 건너기 시작: `next = path.pop_front()`, `progress = 1` | — |
| T8 | `moving` | `next == null`, `path` 비어 있지 않음, `occ(path[0]) ≥ pass_tile_cap` | `moving` | 제자리. 대기 +1 | 대기 ↑ |
| T9 | `moving` | `next == null`, `path` 빔(도착) | `target_kind`가 `"bar"`면 `at_bar`, `"spot"`이면 `watching` | `at_bar`면 `bar_left = bar_ticks` | 공연 중이면 SF0 의 음향·시야 집계 시작 |
| T10 | `at_bar` | `bar_left > 1` | `at_bar` | `bar_left −= 1` | 공연 중이면 바 자리 타일로 음향·시야 집계 |
| T11 | `at_bar` | `bar_left == 1` | `moving` | 구매 확정: `today.bar_buyers += 1`, `bar_planned = false`, 바 예약 해제, SP4 로 관람 자리. 없으면 조기 퇴장(`"no_spot"`) | — |
| T12 | `leaving` | `next == null`, `path` 비어 있지 않음 | `leaving` | `pass_tile_cap`을 **무시하고** 건너기 시작(T7 과 같은 동작). 나가는 사람은 막히지 않는다 → 교착은 인내로 반드시 풀린다 | — |
| T13 | `leaving` | `next == null`, `path` 빔 | `gone` | 입구에 도착 | — |
| T14 | `watching` | (항상) | `watching` | 제자리. 공연 끝(FN3)까지 | 음향·시야 집계 |
| T15 | `gone` | — | — | UP5 에서 한 번 발행된 뒤 제거 | — |

- **T6 연쇄**: 건너기를 끝낸 틱에 경로가 비었으면 같은 틱에 T9(`moving`) 또는 T13(`leaving`)을 적용한다. 그 밖에는 한 틱에 한 행이다. 행이 상태를 바꾸면(T5 `entering → moving`, T11 등) 새 상태의 행은 **다음 틱**에 적용된다.
- **이동 속도**: 타일 하나에 `move_ticks_per_tile`(4) 틱 = 초속 2.5 m(Q4). 건너기를 시작한 틱이 `progress 1`, 4 번째 틱에 도착.
- **점유**: 건너기를 시작하는 순간 점유 타일이 `next`로 바뀐다(MV1). 그래서 `pass_tile_cap`(2)은 "서 있는 사람 1 + 지나가는 사람 1"을 허용하고, 두 사람이 같은 칸으로 동시에 들어가지는 못한다.

| # | 이동 규칙 |
|---|---|
| MV1 | 점유 타일 = `next ?? tile`. `queued`·`gone`은 점유하지 않는다 |
| MV2 | 혼잡 = 다음 칸의 `occ ≥ pass_tile_cap`. 이때 기다리고(T8) 대기가 쌓인다. 경로는 다시 구하지 않는다(v0) |
| MV3 | 자리 예약(`claims`)은 `spot_tile_cap`(1)까지. 관람·바 자리는 한 칸에 한 사람(입석 1 m²) |

**P1 조기 퇴장(인내 초과).** `wait > patience_ticks_type`이 되는 순간, 또는 T5·T11 에서 자리가 없을 때:
1. 만족을 확정한다: `sat = SF(agent, crowd_bp = 0)`(그 시점 집계 그대로, 대기 요소는 상한 10,000).
2. `left_early = true`, `today.left_early += 1`, 관람·바 예약 해제, `bar_planned = false`.
3. `queued`(맵 밖)면 `state = "gone"`. 아니면 `state = "leaving"`, `target_kind = "exit"`, 출발 타일 = `next ?? tile`에서 SP5 로 출구·경로. 건너는 중이면 그 건너기는 T6 으로 마저 끝낸다.
4. `audience.agent_left {day, tick: ctx.tick, agent_id, type, reason: "patience" | "no_spot", satisfaction_bp: sat}` 발행.

이미 떠난 에이전트(`leaving`)는 대기를 더하지 않는다(T12 는 막히지 않는다).

### 만족

에이전트마다 `satisfaction_bp`(0~10,000)를 하나 만든다. 공연 구간에 요소를 집계하고(SF0), 공연 끝(FN2) 또는 조기 퇴장(P1) 때 한 번 확정한다.

**SF0 집계**(UP3, 공연 구간, 떠나지 않은 에이전트): `show_ticks += 1`. `state ∈ {watching, at_bar}`이면 `sound_ticks += [tile ∈ sound_tiles]`, `sight_ticks += [tile ∈ sight_tiles]`. 줄 서 있거나(`queued`·`entering`) 걷는 중(`moving`)에는 공연을 제대로 못 본 것으로 친다(분모만 증가).

| # | 요소 | 공식 | 입력 |
|---|---|---|---|
| SF1 | `sound_bp`, `sight_bp` | `show_ticks > 0`이면 `⌊sound_ticks × 10000 ÷ show_ticks⌋`(시야도 같은 꼴), 0 이면 0 | 음향·시야 커버리지(build C1·C2) |
| SF2 | `lineup_bp` (라인업 궁합) | `lineup == null`이면 `no_lineup_bp`. 아니면 `⌊fit_t × skill_factor ÷ 10000⌋`, `skill_factor = min(10000, skill_base_bp + skill × skill_bp_per_point)` | 장르 적합(유형 × 장르) × 아티스트 실력 |
| SF3 | `value_bp` (가격) | `clamp(price_value_mid_bp − price_sensitivity_bp_t × (ticket_price − price_ref), 0, 10000)` | 티켓 가격 |
| SF4 | `wait_bp` | `min(10000, ⌊wait × 10000 ÷ patience_ticks_t⌋)` | 누적 대기 |
| SF5 | `crowd_bp` (공통) | 공연 끝에 한 번: `ratio = capacity > 0 ? ⌊audience × 10000 ÷ capacity⌋ : 10000`. `ratio ≤ crowd_comfort_bp`면 0, 아니면 `min(10000, ⌊(ratio − crowd_comfort_bp) × 10000 ÷ (10000 − crowd_comfort_bp)⌋)`. 조기 퇴장자는 0 | 남은 관객 ÷ 수용 |
| SF6 | `pos` | `w.lineup × lineup_bp + w.sound × sound_bp + w.sight × sight_bp + w.value × value_bp` (`weights_bp`, 합 10,000) | |
| SF7 | `neg` | `p.crowd × crowd_bp + p.wait × wait_bp` (`penalty_weights_bp`) | |
| SF8 | `satisfaction_bp` | `min(10000, ⌊max(0, pos − neg) ÷ 10000⌋ + satisfaction_bonus_bp)` | 편의·장식 가산(build C7, 상한 1,500) |
| SF9 | `avg_satisfaction_bp` | `admissions > 0`이면 `⌊Σ satisfaction_bp ÷ admissions⌋`(조기 퇴장자 포함), 아니면 0 | |

- PRD 공연 행 "만족도 = 라인업 궁합 × 음향 × 시야 × 편의 − 혼잡 − 대기"를 정수 가중합으로 옮겼다. 곱 대신 합인 이유: 한 요소가 0 이면 전체가 0 이 되는 곱은 v0 기준 배치(음향 23.7%)에서 대부분의 관객을 0 으로 만든다. 곱의 느낌(요소가 다 좋아야 높다)은 가중치 합 10,000 상한과 감점으로 낸다.
- **진실의 출처**: 공연의 만족도는 `audience.day_summary.avg_satisfaction_bp` 하나다. show.md(SE-030)는 이 값을 등급 임계(`disaster`~`rave`)로 접고, 가중치를 바꾸고 싶으면 `audience.json` `satisfaction`을 고친다(같은 공식을 두 곳에 두지 않는다, Q7).
- 화장실은 v0 에서 방문 상태가 없고 `satisfaction_bonus_bp`(화장실 칸 300)로만 들어간다(Q6).

### 공연 끝

`ctx.phase == "show"`이고 `ctx.tick_in_phase == ticks(show) − 1`인 틱(공연 마지막 틱 = show → close 전환 틱)의 단계 2. 이 틱의 단계 4 에서 close 로 넘어가며 economy 가 정산한다. 그래서 매출 보고는 **같은 틱의 단계 2** 에서 내야 그날 장부에 들어간다(단계 4 의 `time.phase_changed {to:"close"}` 핸들러에서 내면 E2 로 economy 정산 뒤에 전달되어 다음 회계일로 넘어간다).

| # | 동작 |
|---|---|
| FN1 | `audience = admissions − today.left_early`, `crowd_bp` = SF5 |
| FN2 | `left_early == false`인 모든 에이전트: `sat = SF(agent, crowd_bp)`. `arrivals`에 남은 것이 있으면(데이터 오류 — AL6 이 막는다) 도착하지 않은 채 집계에서 빼고 `push_error` |
| FN3 | 모든 에이전트 `state = "gone"`(그 자리에서 사라진다. close 에는 틱이 없어 걸어 나가는 연출은 v0 없음) |
| FN4 | UP5 의 `agent_moved`(모두 `gone`) 다음에 `audience.day_summary {…}` → `economy.sales_reported {admissions, audience}` |

- `economy.sales_reported`는 **하루 정확히 1회**, 입장 0 이어도(`{0, 0}`) 낸다. 결정이 없던 날(LS3·artist 미등록)도 0 으로 낸다.
- `audience`(관람 인원) = 끝까지 남은 사람. 조기 퇴장자는 티켓값은 냈지만(`admissions`) 바 매출 기준(economy S2 `ledger.audience`)에서 빠진다.
- **바 매출은 economy 공식 그대로**(economy S2: `audience × bar_purchase_rate_bp`). audience 가 센 `bar_buyers`(바에 실제로 들른 사람)는 요약·리포트용이고 economy 에 보내지 않는다(Q3, 결정 로그). 기준 배치에서 둘은 비슷하다(시뮬 46 vs economy ⌊83 × 0.6⌋ = 49).
- 이벤트 순서(공연 마지막 틱): [단계 2 앞 시스템] → `audience.agent_left`*(그 틱에 떠난 사람) → `audience.agent_moved` → `audience.day_summary` → (그 구독자 연쇄: `show.ended` → `artist.grown`·`reputation.*` 등, SE-030) → `economy.sales_reported` → [단계 2 뒤 시스템] → 단계 4 `time.phase_changed {to:"close"}` → `economy.cash_changed` → `economy.day_settled` → … → `tick.advanced`. SE-035 AC2("`show.ended`는 `audience.day_summary` 뒤·`economy.day_settled` 앞")와 맞는다.

### 이벤트

전부 상태 이벤트(sim → 구독자). 페이로드는 tick.md E4 기본형(숫자 `int`, 좌표·목록은 배열 중첩). 상태를 먼저 갱신하고 낸다(E8).

| 이벤트 | 페이로드 | 발행 시점 | 1일 횟수 |
|---|---|---|---|
| `audience.admissions_decided` | `{day: int, admissions: int, expected: int, noise_bp: int, capacity: int, capped_by: "none"\|"capacity"\|"max_agents"\|"no_stage", has_lineup: bool, by_type: {<type id>: int, …}}` — `by_type` 키 = `types[].id` 전부 | LS4 → AD12 직후(저녁 진입 틱 단계 4, `artist.lineup_set` 처리 중) | 0~1 |
| `audience.agent_moved` | `{tick: int, agents: Array[[id: int, px: int, pz: int, state: String, type: String]]}` — id 오름차순, `px`·`pz`는 U4 고정소수(#표시-좌표), 도착 전(`arrivals`)은 없음, `gone`은 사라지는 틱에 한 번 | UP5, 저녁·공연 구간의 매 틱 단계 2. 에이전트 0 이어도 `agents: []`로 발행 | 1,500 |
| `audience.agent_left` | `{day: int, tick: int, agent_id: int, type: String, reason: "patience"\|"no_spot", satisfaction_bp: int}` | P1, 그 에이전트를 처리하는 UP2 안 | 0~`admissions` |
| `audience.day_summary` | `{day: int, has_lineup: bool, admissions: int, audience: int, left_early: int, bar_buyers: int, avg_satisfaction_bp: int, crowd_bp: int, avg_components: {lineup_bp, sound_bp, sight_bp, value_bp, wait_bp: int}, by_type: {<type id>: {admissions: int, left_early: int, avg_satisfaction_bp: int}, …}}` | FN4, 공연 마지막 틱 단계 2 | 1 |
| `economy.sales_reported` (발행) | `{admissions: int, audience: int}` — economy.md #입력-계약 그대로 | FN4, `audience.day_summary` 바로 뒤 | 1 |

- `avg_components`의 각 값 = 모든 입장자(조기 퇴장 포함)의 그 요소 확정값 합 ÷ `admissions`(내림, 0 명이면 0). 조기 퇴장자의 집계(`show_ticks`·`sound_ticks`·`sight_ticks`·`wait`)는 퇴장 뒤 바뀌지 않으므로(SF0 제외, `leaving`은 대기를 더하지 않음) 공연 끝에 `crowd_bp = 0`으로 다시 계산한 요소가 P1 확정값과 같다. 그래서 요소를 레코드에 따로 저장하지 않는다. 조기 퇴장자의 `crowd_bp`는 0 이라 `crowd_bp`는 공통값 하나만 싣는다. `by_type[t].avg_satisfaction_bp`는 그 유형만의 SF9(유형 인원 0 이면 0).
- `agent_moved` 크기: 최대 150 × 5. 원소가 배열이고 Dictionary 가 아닌 이유는 버스 깊은 복사·세이브 크기를 줄이기 위해서다(E4 허용 타입만 쓴다).

**표시 좌표**(SE-038 이 보간하는 값). `P = pos_scale`, `c(t) = [t.x × P + P/2, t.z × P + P/2]`.

| 상태 | `[px, pz]` |
|---|---|
| `queued` | `c(entrances[0])`(입구에 줄 선 것으로 표시) |
| 건너는 중(`next != null`) | `c(tile) + (c(next) − c(tile)) × progress ÷ move_ticks_per_tile` (축마다, `P mod move_ticks_per_tile == 0`이라 정확히 나누어떨어진다, AL5) |
| 그 밖 | `c(tile)` |

### 결정성과 RNG

| # | 규칙 |
|---|---|
| R1 | 난수는 `rng.stream("audience")`의 `randi()`만 쓴다(`randf`·`randi_range` 금지 — 정수 축소는 이 문서의 `mod`). 다른 스트림은 한 번도 뽑지 않는다 |
| R2 | 뽑는 곳은 둘뿐이다: AD7(1회), AD11(`max(0, N − 1)`회). 둘 다 `artist.lineup_set` 처리(저녁 진입 틱 단계 4) 안이다 |
| R3 | **틱당 상한**: 저녁 진입 틱 `1 + max(0, N − 1) ≤ max_agents`(150), 그 밖의 모든 틱 0. `update(ctx)`·스냅샷 훅은 난수를 뽑지 않는다 |
| R4 | 순회 순서: `types` 배열 순서, `agents`·`arrivals` id 오름차순, `entrances` z·x 오름차순, 자리 순위는 SP1~SP3 의 전순서 키. Dictionary 순회에 기대는 결과 없음(`by_type`은 `types` 순서로 만든다) |
| R5 | 같은 시드·같은 명령 열·같은 입력 이벤트 열이면 같은 `audience.*`·`economy.sales_reported` 이벤트 열과 같은 스냅샷이 나온다 |

tick.md #결정성과-rng 스트림 표는 `audience`의 사용 단계를 "단계 2"로 적고 있다. v0 는 입장 결정이 artist.md 계약상 `artist.lineup_set` 수신(단계 4) 때라 **단계 4 를 더 쓴다**(Q8, tick.md 표 1칸 갱신 요청 — 결과 절).

### 스냅샷

`TickLoop.register_system("audience", audience.update, audience.snapshot, audience.restore)`로 **반드시** 등록한다(등록하지 않으면 공연 중 세이브에서 관객이 사라진다).

`AudienceSystem.snapshot() -> Dictionary` = `{day, phase, ticket_price, reputation_total, lineup, coverage, today, arrivals, agents, next_id}`(#상태 표의 필드, 깊은 복사본, 기본형만). 파생값은 넣지 않는다.

`AudienceSystem.restore(d) -> bool`. 정수 필드(배열·중첩 포함)는 `int`로 정규화(JSON 왕복의 `float`, 정수값이 아니면 실패). 아래 검사를 **전부 끝낸 뒤** 적용한다(tick.md SH3). 첫 위반에서 `push_error` 1회, `false`, 상태 불변, 이벤트 0.

| # | 검사 |
|---|---|
| RU1 | 10개 키가 있고 타입이 맞음. `phase ∈ sim.json phases[].id`, `day ≥ 1`, `ticket_price ≥ 1`, `reputation_total ≥ 0`, `next_id ≥ 1` |
| RU2 | `coverage` 7키·타입, 타일 배열 원소가 맵 안 `[x, z]` |
| RU3 | `lineup`이 `null` 또는 5키(장르가 `genre_fit_bp` 키, 인기·실력 0~100) |
| RU4 | `today`가 `null` 또는 9키, `by_type` 키 = 유형 id 전부, `0 ≤ left_early ≤ admissions ≤ max_agents` |
| RU5 | `arrivals`·`agents`의 id 가 둘을 합쳐 엄격히 증가하고 전부 `< next_id`, 합 개수 ≤ `max_agents` |
| RU6 | 에이전트마다 18키·타입, `type`이 유형 id, `state`가 7종 중 하나, 좌표가 맵 안, `queued`면 `tile == null`, 그 밖은 `tile != null`, `0 ≤ progress ≤ move_ticks_per_tile`, `next == null ⇔ progress == 0`, `sat`이 −1 또는 0~10,000 |
| RU7 | 예약 수 `claims(t) ≤ spot_tile_cap`(모든 `t`) |

- 하지 않는 의미 검사: 경로가 실제로 이어지는지, `occ ≤ pass_tile_cap`인지(나가는 사람은 넘을 수 있다), `today`와 에이전트 수의 관계.
- 복원 성공 뒤 파생값(자리 순위, `occ`, `claims`)을 다시 만든다. 이벤트 없음. 복원 후 진행 = 연속 진행(SH6), SH1~SH7 준수. `sim.json.snapshot_schema_version`은 바꾸지 않는다(`systems.audience` 항목 추가만).

### 설정 로드 검사

`AudienceConfig.load()`가 스키마로 못 하는 교차 검사를 한다. 실패하면 `push_error`, `null`.

| # | 검사 |
|---|---|
| AL1 | `version == 1`, `economy.json` `rate_scale == 10000` |
| AL2 | `types` 3행, `id` 유일 |
| AL3 | 모든 유형의 `genre_fit_bp` 키 집합 == `artist.json` `mvp_genres`, 그 값이 전부 `genres.json` `rows[].id`에 있음 |
| AL4 | `max_agents ≤ sim.json individual_agent_cap` |
| AL5 | `pos_scale`이 짝수이고 `pos_scale mod move_ticks_per_tile == 0` |
| AL6 | `arrival_window_ticks ≤ ticks(evening)`, `ticks(show) ≥ 1` |
| AL7 | `satisfaction.weights_bp` 4값 합 == 10000 |
| AL8 | `price_factor_min_bp ≤ 10000 ≤ price_factor_max_bp` |
| AL9 | `reference_scenarios[].layout`이 `tier1_club.json` `reference_layouts[].id`에 있고, `lineup.slot`이 `artist.json` `roster_plan.slots[].slot`에 있으며 장르·등급·인기·실력이 그 슬롯과 같음. `checks`의 슬롯도 `roster_plan`에 있음 |

`checks`·`reference_scenarios`는 런타임이 읽지 않는다(테스트·qa 용). 아티스트 id 는 어디에도 쓰지 않는다(명단 id 는 content-writer 가 바꿀 수 있어서 슬롯 번호로 참조한다).

### 공개 API (SE-034 구현 대상, 이름 제안)

| 클래스 | 멤버 | 설명 |
|---|---|---|
| `AudienceConfig` | `static load(path := "res://data/audience/audience.json") -> AudienceConfig`, `static from_dicts(audience, artist, genres, economy, sim, map: Dictionary) -> AudienceConfig` | AL1~AL9. `load`는 나머지를 기본 경로에서 읽는다(읽기 전용) |
| | `type_ids() -> Array[String]`, `type_rule(id) -> Dictionary`, `color(id) -> String`, `max_agents`, `pos_scale`, `admission`, `flow`, `satisfaction`, `entrances() -> Array`, `scenario(id) -> Dictionary`(없으면 `{}`, 오류 없음) | 읽기 전용, 깊은 복사 |
| | `static expected_by_type(cfg, lineup, reputation_total: int, ticket_price: int) -> Dictionary` | 순수 함수 AD1~AD5 → `{type: e_t}`. 테스트·UI 예상치용 |
| | `static admissions_from(e_by_type: Dictionary, u: int, capacity: int, has_stage: bool, cfg) -> Dictionary` | 순수 함수 AD6~AD10 → `{expected, noise_bp, raw, admissions, capped_by, by_type}` |
| | `static agent_satisfaction(cfg, agent: Dictionary, lineup, ticket_price: int, crowd_bp: int, bonus_bp: int) -> Dictionary` | 순수 함수 SF1~SF8 → `{satisfaction_bp, lineup_bp, sound_bp, sight_bp, value_bp, wait_bp}` |
| `AudienceSystem` | `new(config: AudienceConfig, bus: EventBus, rng: SeededRng, path: TilePath)` | #입력-계약의 6개 이벤트 구독. 생성자는 이벤트를 내지 않는다. `TilePath`는 SE-032 것(읽기 전용 질의) |
| | `update(ctx)`, `snapshot()`, `restore(d)` | #상태-기계, #스냅샷 |
| | `agents() -> Array`(깊은 복사), `today`, `day`, `phase`, `ticket_price`, `reputation_total` | 읽기 전용 |

### view 계약 (SE-038)

| 항목 | 규칙 |
|---|---|
| 인스턴스 | `audience.agent_moved.agents`의 원소 하나 = 인스턴스 하나. 키는 `id`(index 0). 보이는 수 = `state != "gone"`인 원소 수 |
| 위치 | `[px, pz]` ÷ `pos_scale`(`audience.json`) = 월드 m(`× tile_size_m`). 직전 틱 → 현재 틱 선형 보간(`t = acc ÷ tick_len`). 새 id 는 첫 틱에 보간 없이 놓는다 |
| 색 | `type`(index 4) → `audience.json` `types[].color`. 알파 1.0(materials.md M3) |
| 상태 | `state`(index 3): `watching` 은 무대 방향(무대 위치는 build 이벤트에서), `at_bar`·`watching`·`queued` 정지, `gone`은 숨김(그 틱 이후 원소가 오지 않는다). 반투명 금지 |
| 복구 | `session.loaded` 뒤 다음 `agent_moved` 한 번으로 전체를 다시 만든다(유형이 원소에 들어 있는 이유, Q5) |
| 그 밖 | `audience.admissions_decided`로 "오늘 N 명" 표시 가능. view 는 audience 상태를 읽지 않는다 |

## 수치표

모든 값은 [`audience.json`](../../project/data/audience/audience.json) (version 1). 이 절의 숫자는 그 파일 값이거나 그 값으로 계산한 파생값이다.

### 유형

| 필드 | `regular` 로컬 단골 | `genre_fan` 장르 팬 | `walk_in` 뜨내기 | 근거 |
|---|---|---|---|---|
| `color` (임시) | `#e0a458` 호박색 | `#4f7cff` 파랑 | `#c2c7d0` 밝은 회청 | 서로 멀고 장르 강조색(`genres.json`)과 겹치지 않음 |
| `needs_lineup` | false | true | true | 아티스트 없는 날은 단골만 |
| `base_centi` | 1,200 (12명) | 0 | 3,000 (30명) | |
| `popularity_centi` | 0 | 160 (인기 1 당 1.6명) | 30 (0.3명) | 신인 흡인 = 팬 |
| `reputation_centi` | 2 (명성 500 → +10명) | 0 | 6 (명성 500 → +30명) | 명성이 오르면 뜨내기가 는다 |
| `genre_fit_bp` rock / indie / electronic | 10,000 / 8,000 / 6,000 | 10,000 / 10,000 / 10,000 | 7,000 / 8,000 / 10,000 | 지하 록 클럽 단골, 팬은 그날 장르의 팬, 뜨내기는 클럽 나이트 |
| `price_sensitivity_bp` (1 단위당) | 200 | 300 | 500 | 가격 +10 → 입장 −20% / −30% / −50% |
| `bar_visit_bp` | 7,000 | 4,000 | 7,500 | 섞으면 약 55~60%(economy `bar_purchase_rate_bp` 6,000 근처) |
| `patience_ticks` | 400 (40초) | 300 (30초) | 150 (15초) | |
| `spot_weights_bp` 음향 / 시야 / 바 | 5,000 / 5,000 / 2,000 | 6,000 / 4,000 / 0 | 4,000 / 3,000 / 3,000 | 셋 다 "음향 + 시야" 칸을 먼저 고른다. 단골·뜨내기는 바 근처를 덤으로 |

### 전역

| 필드 | 값 | 근거 |
|---|---|---|
| `max_agents` | 150 | PRD MVP 관객 150 = `tiers[tier_1].capacity_max` |
| `pos_scale` | 100 | 1 cm 단위. 4 로 나누어떨어짐(AL5) |
| `admission.price_ref` | 20 | economy `ticket_price_default` |
| `admission.reputation_cap` | 2,000 | 티어 3 해금 명성. 티어 1 에서는 닿지 않는다 |
| `admission.noise_bp` | 1,000 | 같은 조건에서 하루 ±10% |
| `admission.price_factor_min_bp` / `max_bp` | 0 / 20,000 | 가격 40 에서 뜨내기 0, 가격 5 에서 최대 1.75배 |
| `flow.arrival_window_ticks` | 400 | 저녁 600 틱 중 앞 40초에 도착. 마지막 도착(399) + 입장 4 + 바 왕복(≈ 12칸 × 4 + 50 + 20칸 × 4) < 600 → 공연 시작 전에 모두 자리에 선다 |
| `flow.entry_ticks` | 4 | 입구 2칸 × (1 ÷ 4) = 틱당 0.5명 > 최대 도착률 150 ÷ 400 = 0.375 |
| `flow.move_ticks_per_tile` | 4 | 초속 2.5 m(Q4) |
| `flow.spot_tile_cap` / `pass_tile_cap` | 1 / 2 | 입석 1칸 1명, 지나가는 사람 1명 더 |
| `flow.bar_ticks` / `bar_fail_wait_ticks` | 50 / 30 | 바 5초, 자리 없어 포기하면 3초 대기로 친다 |
| `satisfaction.weights_bp` 라인업 / 음향 / 시야 / 가격 | 4,000 / 1,500 / 1,500 / 3,000 | 합 10,000(AL7). 라인업이 가장 크다 |
| `satisfaction.penalty_weights_bp` 혼잡 / 대기 | 500 / 2,000 | |
| `skill_base_bp` / `skill_bp_per_point` | 5,000 / 50 | 실력 18 → 5,900, 60 → 8,000, 100 → 10,000 |
| `no_lineup_bp` | 0 | 라인업 없는 날은 라인업 요소 0 |
| `price_value_mid_bp` | 5,000 | 기준 가격에서 가격 만족 중간 |
| `crowd_comfort_bp` | 8,000 | 수용의 80% 까지 혼잡 0 |

### 입장 수 곡선 (기준 배치 `capacity` 122, 티켓 20, 노이즈 0 의 기대 입장 `min(⌊E ÷ 100⌋, 122)`)

| 라인업 (roster_plan 슬롯) | 명성 0 | 150 | 250 | 500 |
|---|---|---|---|---|
| 없음 | 12 | 15 | 17 | 22 |
| s03 rock local 인기 24 | 76 | 85 | 91 | 107 |
| s07 indie local 인기 27 | 83 | 92 | 99 | 115 |
| s10 electronic local 인기 21 | 77 | 87 | 95 | 113 |
| s08 indie rookie 인기 42 | 110 | 120 | 122 | 122 |
| s04 rock rookie 인기 46 / s11 electronic 50 / s12 electronic 55 | 116 / 122 / 122 | 122 / 122 / 122 | 122 | 122 |

- economy.md 의 "30일 안에 평균 입장 91명 이상"은 로컬 상위를 쓰고 명성 250 근처(SE-030 목표 궤적의 중간)에서 닿고, 신인(명성 150 해금)부터는 수용 122 가 상한이 된다. 그 뒤로는 벤치·테이블(`capacity_add`)로 수용을 넓히는 것이 성장 수단이다.
- 기준 배치의 하루 손익(economy 공식, 유지비 123): 로컬 s07·명성 0 83명 → `net` 828(임대료 1.38배), 신인 s08·명성 150 120명 → `net` 1,296(2.16배).

### 신인 손익분기 (artist.md T5)

같은 명성 150·기준 배치·티켓 20 에서 기대 입장 차(신인 − 로컬 상위, 명). 목표 ≥ 17(`checks.rookie_over_local_top_min`), 권장 25~40.

| 신인 \ 로컬 상위 | s03 (85) | s07 (92) | s10 (87) |
|---|---|---|---|
| s04 (122) | 37 | 30 | 35 |
| s08 (120) | 35 | **28** | 33 |
| s11 (122) | 37 | 30 | 35 |
| s12 (122) | 37 | 30 | 35 |

최솟값 28 ≥ 17, 권장 범위 안. 신인 셋은 수용 122 에 걸린다(스피커·벤치를 더 놓을 이유).

### 가격 반응 (로컬 s07, 명성 0, 기준 배치, 노이즈 0)

| 티켓가 | 기대 입장 | 티켓 매출 | 만족 손계산 |
|---|---|---|---|
| 10 | 113 | 1,130 | — |
| 20 | 83 | 1,660 | 6,732 |
| 25 | 68 | 1,700 | — |
| 30 | 53 | 1,590 | 5,730 |

가격을 올리면 입장이 줄고(AU5) 만족도 떨어진다(SF3). 티켓 매출 최대는 25 근처지만 바 매출(관객 수 비례)과 만족(명성)을 합치면 기본가 20 이 무난한 선택이다. 이 표로 economy Q4 의 "UI 잠금" 조건이 풀린다(SE-039 결정 로그와 같은 방향).

## 기준 시나리오

`audience.json` `reference_scenarios`(4개). 공통: `layout` `baseline_show`(build.md 부록 A2 — `capacity` 122, `viewing` 405, 음향 96, 시야 364, 바 122, `satisfaction_bonus_bp` 100), 시드 0, 1일차(그날 `audience` 스트림 첫 뽑기), 마스터 시드 0 의 `audience` 파생 시드 1,688,486,501(tick.md 검증 벡터).

| id | 라인업 | 명성 | 가격 | `E` | 첫 뽑기 `u` | `noise_bp` | `raw` | `admissions` (시드 0) | `by_type` (단골/팬/뜨내기) | 다른 시드 범위 | 평균 만족 (시드 0) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `no_lineup` | 없음 | 0 | 20 | 1,200 | 3,230,427,448 | +42 | 12 | **12** | 12 / 0 / 0 | 10~13 | 4,300~4,600 (손계산 4,600) |
| `local_top_baseline` | s07 indie local 인기 27 실력 18 | 0 | 20 | 8,328 | 〃 | +42 | 83 | **83** | 10 / 43 / 30 | 74~91 | 6,432~6,732 (손계산 6,732) |
| `rookie_baseline` | s08 indie rookie 인기 42 실력 60 | 150 | 20 | 12,048 | 〃 | +42 | 120 | **120** | 12 / 67 / 41 | 108~122 | 6,433~6,733 (손계산 6,733) |
| `local_top_price30` | s07 | 0 | **30** | 5,316 | 〃 | +42 | 53 | **53** | 8 / 30 / 15 | 47~58 | 5,430~5,730 (손계산 5,730) |

- **다른 시드 범위** = `[min(⌊E × (10000 − J) ÷ 10⁶⌋, cap), min(⌊E × (10000 + J) ÷ 10⁶⌋, cap)]`(노이즈 양 끝). 시드 1~100 의 입장은 전부 이 안이다(qa 스크립트가 확인).
- **평균 만족 범위** = `[손계산 − 300, 손계산]`. 손계산은 "대기 0, 모두 공연 시작 전에 자리에 섬"의 값이고, 실제 실행은 대기(SF4)만큼 낮을 수 있다. 상한을 넘으면 공식 구현이 틀린 것이다. 경로 동점 처리(`AStarGrid2D`)가 달라도 평균은 바뀌지 않는다(아래 B2 — 누가 어느 칸을 차지하든 합이 같다).
- 시드 0 리터럴의 출처: Godot `RandomNumberGenerator`(PCG32, `inc = PCG_DEFAULT_INC_64`)를 Python 으로 다시 구현해 계산했다(참조 벡터 `pcg32_srandom_r(42, 54)` → `0xa15c02b7 …` 일치 확인). 이 작업 환경에서 Godot 스크립트를 직접 돌릴 수 없었으므로 **SE-034 의 첫 테스트가 `u == 3230427448`을 확인**한다. 다르면 sim-engineer 가 결과 절에 실제 값을 적고 game-designer 가 `first_draw`·`noise_bp`·`raw`·`admissions`를 고친다(공식은 그대로).

### 부록 B. 손계산

**B0. 노이즈.** `u = 3,230,427,448`, `u mod 2,001 = 1,042`(2,001 × 1,614,406 = 3,230,426,406, 나머지 1,042), `noise_bp = 1,042 − 1,000 = +42`.

**B1. 입장 수.**

`no_lineup`: 단골 `draw = 1,200 + 0 + 2 × 0 = 1,200`, `fit` 10,000, `price` 10,000 → `e = 1,200`. 팬·뜨내기 0(`needs_lineup`). `E = 1,200`, `raw = ⌊1,200 × 10,042 ÷ 10⁶⌋ = ⌊12.05⌋ = 12`, `min(12, 122, 150) = 12`.

`local_top_baseline`(indie 27, 명성 0, 가격 20 → 모든 `price` 10,000):
| 유형 | `draw` | `fit` | `e` |
|---|---|---|---|
| 단골 | 1,200 | 8,000 | 960 |
| 팬 | 160 × 27 = 4,320 | 10,000 | 4,320 |
| 뜨내기 | 3,000 + 30 × 27 = 3,810 | 8,000 | ⌊3,048.0⌋ = 3,048 |

`E = 8,328`, `raw = ⌊8,328 × 10,042 ÷ 10⁶⌋ = ⌊83.63⌋ = 83`. 배분: `83 × 960 = 79,680` → ⌊9.57⌋ = 9 (나머지 4,728), `83 × 4,320 = 358,560` → 43 (나머지 456), `83 × 3,048 = 252,984` → 30 (나머지 3,144). 합 82, 남은 1명 → 나머지가 가장 큰 단골 → **10 / 43 / 30**.

`rookie_baseline`(indie 42, 명성 150): 단골 `(1,200 + 300) × 0.8 = 1,200`, 팬 `160 × 42 = 6,720`, 뜨내기 `(3,000 + 1,260 + 900) × 0.8 = 4,128`. `E = 12,048`, `raw = ⌊120.99⌋ = 120 ≤ 122`. 배분 11 (나머지 11,472) / 66 (나머지 11,232) / 41 (나머지 1,392), 남은 2명 → 단골·팬 → **12 / 67 / 41**.

`local_top_price30`: `price` = 10,000 − 200·10 = 8,000 / 10,000 − 300·10 = 7,000 / 10,000 − 500·10 = 5,000. `e` = ⌊960 × 0.8⌋ = 768, ⌊4,320 × 0.7⌋ = 3,024, ⌊3,048 × 0.5⌋ = 1,524. `E = 5,316`, `raw = ⌊53.38⌋ = 53`. 배분 7 (나머지 3,492) / 30 (나머지 792) / 15 (나머지 1,032) → 남은 1명 단골 → **8 / 30 / 15**.

**B2. 평균 만족.** 기준 배치의 관람 타일 중 음향 ∩ 시야 94칸, 음향만 2칸(`[6,14]`·`[17,14]` — 기둥에 가림), 바 ∩ 음향 0칸. SP1 의 세 유형 모두 "음향 + 시야" 칸이 1순위라 처음 94명은 그 칸에, 그다음은 음향만 또는 시야만 칸에 선다(점수가 같아 `cdist` 순). 모두 공연 전에 자리에 서므로(도착 창 400) `sound_bp`·`sight_bp`는 그 칸 소속 그대로 0 또는 10,000 이다. 음향 또는 시야 하나를 놓친 사람은 정확히 1,500 낮다(가중치 1,500 × 10,000 ÷ 10,000). 그래서 **평균 = (전원 음향·시야 10,000 일 때의 합 − 1,500 × max(0, 남은 관객 − 94)) ÷ 입장**이고, 누가 어느 칸에 섰는지와 무관하다.

| 시나리오 | 유형 | `lineup_bp` | `value_bp` | `crowd_bp` | 만족(음향·시야 모두) | 인원 |
|---|---|---|---|---|---|---|
| `no_lineup` | 단골 | 0 | 5,000 | 0 | ⌊(0 + 15·10⁶ + 15·10⁶ + 15·10⁶) ÷ 10⁴⌋ + 100 = 4,600 | 12 |
| `local_top_baseline` (실력 18 → `skill_factor` 5,900) | 팬 | 5,900 | 5,000 | 0 | ⌊(23.6 + 30 + 15)·10⁶ ÷ 10⁴⌋ + 100 = 6,960 | 43 |
| | 단골·뜨내기 | ⌊8,000 × 5,900 ÷ 10⁴⌋ = 4,720 | 5,000 | 0 | ⌊(18.88 + 30 + 15)·10⁶ ÷ 10⁴⌋ + 100 = 6,488 | 40 |
| `rookie_baseline` (실력 60 → 8,000) | 팬 | 8,000 | 5,000 | 9,180 | ⌊(32 + 30 + 15 − 4.59)·10⁶ ÷ 10⁴⌋ + 100 = 7,341 | 67 |
| | 단골·뜨내기 | 6,400 | 5,000 | 9,180 | ⌊(25.6 + 30 + 15 − 4.59)·10⁶ ÷ 10⁴⌋ + 100 = 6,701 | 53 |
| `local_top_price30` | 팬 | 5,900 | 5,000 − 3,000 = 2,000 | 0 | ⌊(23.6 + 30 + 6)·10⁶ ÷ 10⁴⌋ + 100 = 6,060 | 30 |
| | 단골 | 4,720 | 5,000 − 2,000 = 3,000 | 0 | ⌊(18.88 + 30 + 9)·10⁶ ÷ 10⁴⌋ + 100 = 5,888 | 8 |
| | 뜨내기 | 4,720 | 5,000 − 5,000 = 0 | 0 | ⌊(18.88 + 30 + 0)·10⁶ ÷ 10⁴⌋ + 100 = 4,988 | 15 |

- `rookie_baseline` 혼잡: `ratio = ⌊120 × 10,000 ÷ 122⌋ = 9,836`, `crowd = ⌊(9,836 − 8,000) × 10,000 ÷ 2,000⌋ = 9,180`, 감점 500 × 9,180 = 4.59·10⁶.
- `no_lineup`: 12 × 4,600 ÷ 12 = **4,600**.
- `local_top_baseline`: (43 × 6,960 + 40 × 6,488) ÷ 83 = (299,280 + 259,520) ÷ 83 = 558,800 ÷ 83 = ⌊6,732.5⌋ = **6,732** (83 ≤ 94 라 놓친 사람 0).
- `rookie_baseline`: (67 × 7,341 + 53 × 6,701 − 1,500 × (120 − 94)) ÷ 120 = (491,847 + 355,153 − 39,000) ÷ 120 = 808,000 ÷ 120 = ⌊6,733.3⌋ = **6,733**.
- `local_top_price30`: (30 × 6,060 + 8 × 5,888 + 15 × 4,988) ÷ 53 = (181,800 + 47,104 + 74,820) ÷ 53 = 303,724 ÷ 53 = ⌊5,730.6⌋ = **5,730**.

참고(설계 확인용 프로토타입): 위 규칙을 Python 으로 옮긴 시뮬(BFS 경로, 시드 0)은 4,600 / 6,731 / 6,725 / 5,727 이고 조기 퇴장 0, 최대 대기 12 틱, 공연 시작 때 자리에 없는 사람 0 이었다. 150명 스트레스(수용 150 가정, 인기 55, 명성 500)에서도 조기 퇴장 0, 최대 대기 12 틱이었다. 이 값들은 수용 기준이 아니다(경로 동점 처리가 구현과 다를 수 있다).

## 수용 기준

### 구현 (SE-034 — `test_audience_config.gd`는 AU0, 성능은 `test_audience_perf.gd`, 나머지는 `test_audience_system.gd`)

기대 수치는 테스트에 하드코딩하지 않고 `audience.json` `reference_scenarios`·`checks`와 행 값에서 읽는다. 이벤트 이름·상태 문자열·`reason`은 리터럴로 단언한다. 공통 전제: `TickLoop`(시드 = 시나리오 `seed`)에 economy·audience 를 훅과 함께 등록하고, 커버리지는 `tier1_club.json` `reference_layouts[layout]`대로 build 를 돌리거나 `build.coverage_changed` 페이로드를 테스트가 직접 발행한다. 라인업·명성은 `artist.lineup_set`·`reputation.changed`를 테스트가 발행한다(artist·reputation 미등록 가능).

| # | 케이스 | 검증 |
|---|---|---|
| AU0 | `test_config_loads_and_cross_checks` | 실제 데이터로 `AudienceConfig.load()` 성공. AL1~AL9 를 하나씩 깬 사본 9건 이상이 `null`(예: 유형 2개, `genre_fit_bp`에서 `indie` 제거, `jazz` 추가, `max_agents` 3,001, `pos_scale` 99, `arrival_window_ticks` 601, 가중치 합 9,999, `price_factor_max_bp` 9,000, 시나리오 `slot` 이 roster_plan 과 다른 인기) |
| AU1 | `test_reference_admissions_seed0` | 4개 시나리오 각각: `expected_by_type`가 `e_centi`, 첫 `randi()`가 `first_draw`, `audience.admissions_decided`의 `admissions`·`noise_bp`·`capped_by`·`by_type`·`expected`(= `expected_centi ÷ 100`)가 `expected`와 같음. `no_lineup`은 `by_type`의 팬·뜨내기 0 |
| AU2 | `test_admissions_other_seeds_in_range` | 시드 1~100 각각 같은 시나리오의 `admissions`가 `admissions_range_other_seeds` 안, `by_type` 합 == `admissions` |
| AU3 | `test_admissions_cap` | `capacity` 를 40 으로 바꾼 커버리지 → `admissions == 40`, `capped_by "capacity"`. `capacity` 150·인기 100·명성 2,000 → `admissions == 150`, 에이전트 최대 동시 수 150. `has_stage false` → 0·`"no_stage"`이고 이때도 `audience` 스트림 상태가 정확히 1 뽑기만큼 진행 |
| AU4 | `test_state_transitions`(행마다 1건, T1~T14) | 작은 커버리지(관람 타일 몇 칸)와 손으로 만든 상황: 도착(T1), 입구 비었을 때 입장(T2)·찼을 때 대기(T3), `entering` 4틱(T4·T5), 바 예정자의 바 → `at_bar` 50틱 → 관람 자리(T5·T9·T10·T11, `bar_buyers` +1), 건너기 4틱과 표시 좌표 25 씩 증가(T6·T7), 혼잡 대기(T8 — 다음 칸 `occ 2`), 도착 → `watching`(T9·T14), 조기 퇴장 → 입구 → `gone`(T12·T13), `gone`은 한 번 발행 후 사라짐(T15) |
| AU5 | `test_price_lowers_admissions` | `local_top_price30.admissions` < `local_top_baseline.admissions`(53 < 83)이고 각 유형 `e_t`도 감소. 가격 10 은 20 보다 많음. 평균 만족도 30 < 20 |
| AU6 | `test_early_leave_patience` | 다음 칸을 계속 막아(`pass_tile_cap` 사람 배치) `walk_in` 대기가 `patience_ticks` 를 넘는 틱에 `audience.agent_left {reason:"patience"}` 1건, `state "leaving"`, 그 사람 `sat`이 확정되어 이후 불변, 공연 끝 `left_early` 1·`audience == admissions − 1`. 관람 자리를 다 예약해 둔 상태의 입장자 → `reason "no_spot"`. `queued`에서 인내 초과 → 바로 `gone` |
| AU7 | `test_day_events_once` | `TickLoop` 하루(3,300틱): `audience.admissions_decided` 1회(저녁 진입 틱, `artist.lineup_set` 뒤), `audience.agent_moved` 정확히 1,500회(저녁·공연 틱마다, 낮 0), 각 페이로드의 원소 수 == 그 틱의 에이전트 수, 원소 5개 타입 `[int, int, int, String, String]`, id 오름차순. 공연 마지막 틱에 `agent_moved`(전원 `gone`) → `audience.day_summary` → `economy.sales_reported {admissions, audience}` 각 1회, 그 틱의 `time.phase_changed {to:"close"}`보다 먼저. `economy.day_settled.admissions`·`.audience`가 보고값과 같음 |
| AU8 | `test_reference_satisfaction` | 4개 시나리오를 하루 돌린 `day_summary.avg_satisfaction_bp`가 `avg_satisfaction_bp_range` 안, `crowd_bp`·`left_early`·`audience`가 `expected`와 같음. `agent_satisfaction` 순수 함수로 부록 B2 표의 유형별 값 재현 |
| AU9 | `test_determinism` | 같은 시드·입력 두 번 → `audience.*`·`economy.sales_reported` 이벤트 열 해시와 `snapshot()` 해시 같음. `audience` 외 스트림 상태 불변. 저녁 진입 틱의 `audience` 뽑기 수 == `max(1, admissions)`(1 + N − 1), 다른 틱 0(스트림 상태 비교) |
| AU10 | `test_snapshot_roundtrip` | (a) 저녁 중간(도착 대기 남음)과 공연 중간(건너는 사람·`at_bar` 있음) 두 시점에서 `snapshot()` → JSON 왕복 → 새 시스템 `restore()` `true` → 끝까지 진행한 `day_summary`와 이벤트 열이 연속 진행과 같음. (b) `TickLoop` 수준 `systems.audience` 왕복. (c) 거부 사본 ≥ 6건(RU1~RU7 에서: `phase "noon"`, 모르는 유형, `state "dancing"`, id 가 `next_id` 이상, `queued`인데 `tile` 있음, `progress 5`, 같은 자리 예약 2명) 각각 `false`, `push_error` 1회, 해시 불변, 이벤트 0 |
| AU11 | `test_audience_perf` | 150명(`capacity` 150 커버리지, AU3 의 상한 조건) 900 공연 틱 + 600 저녁 틱 헤드리스 벽시계 측정. 단언은 한 틱 평균 ≤ 5 ms(목표 ≤ 2 ms, 실측은 qa 리포트) |

### 데이터·문서 (SE-029, qa·reviewer)

| # | 검증 | 방법 |
|---|---|---|
| AU12 | `audience.json` 스키마 통과(`--strict`), 유형 3, `genre_fit_bp` 키 = `artist.json` `mvp_genres` ⊆ `genres.json` id, 가중치 합 10,000, 기준 시나리오 입장 리터럴·배분·다른 시드 범위가 공식으로 재계산한 값과 같음, T5 최소 차 ≥ 17 | 아래 qa 스크립트 exit 0 |
| AU13 | 이 문서의 이벤트 5개(`audience.*` 4 + `economy.sales_reported`)가 events.md 표와 같은 페이로드. `agent_moved`가 배열 중첩만 쓴다(E4) | reviewer |
| AU14 | 아티스트 id 리터럴 0(슬롯 번호만), 기존 테이블(`artist.json`·`artists.json`·`furniture.json`·`economy.json`·`genres.json`) diff 0 | reviewer(`git diff --stat`) |

### 수치 목표 (데이터가 바뀌어도 지켜야 할 범위)

| # | 목표 | 현재 값 |
|---|---|---|
| AT1 | 기준 배치·명성 0·라인업 없음 입장 ≤ 20 (소수) | 12 |
| AT2 | 기준 배치·명성 0·로컬 상위 기대 입장 70~95 (첫날 흑자, economy 기준 100 보다 약간 낮음) | 76 / 83 / 77 |
| AT3 | 신인 − 로컬 상위 기대 입장 ≥ 17, 권장 25~40 (artist.md T5) | 최소 28 |
| AT4 | 가격 20 → 30 에서 입장·평균 만족 둘 다 감소 | 83 → 53, 6,732 → 5,730 |
| AT5 | 기준 시나리오 평균 만족 5,000~8,000 (show.md 등급 "보통~호평" 구간이 잡힐 자리) | 6,732 / 6,733 |
| AT6 | 기준 시나리오 조기 퇴장 0 (기본 배치에서 사람이 지쳐 나가지 않는다) | 0 |

## 테스트 방법

- 데이터(이 티켓): `python3 tools/validate_data.py --strict` exit 0. CI 의 내장 부분집합은 `propertyNames`·`oneOf`·`maxItems`를 보지 않으므로 로더 AL2·AL3·AL9 와 아래 스크립트가 그 몫을 한다.
- qa 재계산(AU12): 리포 루트에서

```bash
python3 - <<'PY'
import json, sys
D = "project/data/"
A = json.load(open(D + "audience/audience.json", encoding="utf-8"))
ART = json.load(open(D + "artist/artist.json", encoding="utf-8"))
G = {r["id"] for r in json.load(open(D + "genres/genres.json", encoding="utf-8"))["rows"]}
SIM = json.load(open(D + "sim/sim.json", encoding="utf-8"))
MAP = json.load(open(D + "maps/tier1_club.json", encoding="utf-8"))
M64 = (1 << 64) - 1
def pcg_first(seed):  # Godot RandomNumberGenerator(seed).randi() 첫 값 (PCG32, inc = PCG_DEFAULT_INC_64)
    st = [0, ((1442695040888963407 << 1) | 1) & M64]
    def r():
        old = st[0]; st[0] = (old * 6364136223846793005 + st[1]) & M64
        x = (((old >> 18) ^ old) >> 27) & 0xFFFFFFFF; k = old >> 59
        return ((x >> k) | (x << ((-k) & 31))) & 0xFFFFFFFF
    r(); st[0] = (st[0] + seed) & M64; r(); return r()
def fnv(s):
    h = 2166136261
    for b in s.encode(): h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return h
T, AD = A["types"], A["admission"]; err = []
def e_centi(lu, rep, price):
    out = {}
    for t in T:
        if t["needs_lineup"] and lu is None: out[t["id"]] = 0; continue
        draw = t["base_centi"] + (t["popularity_centi"] * lu["popularity"] if lu else 0) + t["reputation_centi"] * min(rep, AD["reputation_cap"])
        fit = t["genre_fit_bp"][lu["genre"]] if lu else 10000
        pf = max(AD["price_factor_min_bp"], min(AD["price_factor_max_bp"], 10000 - t["price_sensitivity_bp"] * (price - AD["price_ref"])))
        out[t["id"]] = draw * fit // 10000 * pf // 10000
    return out
def split(adm, e):
    E = sum(e.values()); ids = [t["id"] for t in T]
    n = {i: (adm * e[i] // E if E else 0) for i in ids}
    for i in sorted(ids, key=lambda i: (-(adm * e[i] % E if E else 0), ids.index(i)))[: adm - sum(n.values())]: n[i] += 1
    return n
if len(T) != 3: err.append("유형 수 != 3")
for t in T:
    if set(t["genre_fit_bp"]) != set(ART["mvp_genres"]) or not set(t["genre_fit_bp"]) <= G: err.append("장르 키 " + t["id"])
if sum(A["satisfaction"]["weights_bp"].values()) != 10000: err.append("weights 합")
if A["max_agents"] > SIM["individual_agent_cap"]: err.append("max_agents")
ev = [p["ticks"] for p in SIM["phases"] if p["id"] == "evening"][0]
if A["flow"]["arrival_window_ticks"] > ev: err.append("arrival_window")
lay = {l["id"]: l["expected"] for l in MAP["reference_layouts"]}
J = AD["noise_bp"]
for sc in A["reference_scenarios"]:
    x, lu = sc["expected"], sc["lineup"]; cap = min(lay[sc["layout"]]["capacity"], A["max_agents"])
    e = e_centi(lu, sc["reputation_total"], sc["ticket_price"]); E = sum(e.values())
    u = pcg_first(fnv(f"{sc['seed']}:audience")); nb = u % (2 * J + 1) - J
    raw = E * (10000 + nb) // 1000000; adm = min(raw, cap)
    got = {"e_centi": e, "expected_centi": E, "first_draw": u, "noise_bp": nb, "raw": raw, "admissions": adm,
           "capped_by": "none" if raw <= cap else "capacity", "by_type": split(adm, e),
           "admissions_range_other_seeds": [min(E * (10000 - J) // 1000000, cap), min(E * (10000 + J) // 1000000, cap)]}
    for k, v in got.items():
        if x[k] != v: err.append(f"{sc['id']}.{k}: {x[k]} != {v}")
    if lu:
        slot = [s for s in ART["roster_plan"]["slots"] if s["slot"] == lu["slot"]][0]
        if any(slot[k] != lu[k] for k in ("genre", "grade", "popularity", "skill")): err.append(sc["id"] + " lineup != roster_plan")
C = A["checks"]; slots = {s["slot"]: s for s in ART["roster_plan"]["slots"]}; cap = min(lay["baseline_show"]["capacity"], A["max_agents"])
X = lambda s: min(sum(e_centi(slots[s], C["reference_reputation"], AD["price_ref"]).values()) // 100, cap)
diffs = {(r, l): X(r) - X(l) for r in C["rookie_slots"] for l in C["local_top_slots"]}
print("T5 기대 입장:", {s: X(s) for s in C["rookie_slots"] + C["local_top_slots"]}, "최소 차", min(diffs.values()))
if min(diffs.values()) < C["rookie_over_local_top_min"]: err.append("T5 미달")
print("\n".join(err) or "AU OK"); sys.exit(1 if err else 0)
PY
```

  기대 출력: `T5 기대 입장: {'s04': 122, 's08': 120, 's11': 122, 's12': 122, 's03': 85, 's07': 92, 's10': 87} 최소 차 28` / `AU OK`, exit 0.
- 손계산(reviewer): 부록 B 를 이 문서의 공식과 `audience.json` 값만으로 다시 계산한다.
- 헤드리스(SE-034): `tools/run_tests.sh project/tests/sim` → AU0~AU11. Godot 이 없으면 SKIP → CI(`godot-tests`).
- 변이(qa, SE-034): "AD9 의 `min(…, max_agents)` 제거" 패치 → AU3 의 150 상한 케이스만 실패. "T12 의 `pass_tile_cap` 무시 제거"(나가는 사람도 막힘) → AU6 만 실패하거나 교착으로 시간 초과.

## 열린 질문

> **결정(2026-10-09, 사람 검수 최소화 원칙):** 아래 질문 전부 추천안을 채택해 데이터와 규칙에 넣었다. ADR 이 필요한 변경은 없다. 바꾸려면 새 질문으로 다시 올린다. producer 가 `docs/status/` 결정 로그로 옮긴다.

| # | 질문 | 선택지 | 채택(추천) | 바꾸면 |
|---|---|---|---|---|
| Q1 | MVP 관객 유형 3 | (a) 단골 / 장르 팬 / 뜨내기 (b) 장르별 3부족(록·인디·일렉트로닉 팬) | **(a).** "아티스트 없는 날 단골만", "인기는 팬, 명성은 뜨내기"로 세 입력(라인업·명성·가격)이 유형마다 다르게 먹힌다. (b)는 장르 적합만 다르고 나머지가 같아진다. 장르 부족은 버티컬 슬라이스(6유형)에서 더한다 | 데이터 + 스키마 `types` maxItems(version 2) |
| Q2 | MVP 장르 3 | artist.json `mvp_genres` 를 따른다 | **rock / indie / electronic**(artist.md Q1). audience.json 은 목록을 복제하지 않고 `genre_fit_bp` 키로만 쓰며 로더 AL3 이 일치를 검사한다 | artist.json 이 바뀌면 `genre_fit_bp` 키를 같이 바꾼다 |
| Q3 | 바 구매를 유형별로 economy 에 넘기나 | (a) v0 는 economy S2 공식 유지, audience 는 `admissions`·`audience`만 보고 (b) `economy.sales_reported`에 `bar_buyers` 추가 | **(a)**(티켓 결정). 시뮬의 `bar_buyers`는 요약·리포트용. 기준 배치에서 economy 값과 비슷하다(46 vs 49). 바 대기열·반경이 매출에 먹히게 하려면 (b) — economy 입력 변경(스키마 version 2, S2 개정)이라 qa 봇 통계를 보고 별도 티켓 | economy.md S2·events.md 페이로드·economy 스키마 |
| Q4 | 이동 속도 | (a) 틱당 1타일(티켓 초안, 초속 10 m) (b) 4틱당 1타일(초속 2.5 m) + 고정소수 표시 좌표 | **(b).** (a)는 24 m 방을 2.4초에 가로질러 군중이 순간 이동처럼 보인다. (b)는 틱마다 위치가 조금씩 바뀌어 view 의 틱 간 보간이 매끄럽다. 비용은 좌표에 `pos_scale` 하나 | 데이터만(`move_ticks_per_tile`, AL5 를 지키게 `pos_scale`) |
| Q5 | `agent_moved` 원소 | (a) `[id, x, z, state]`(티켓 초안) (b) `[id, px, pz, state, type]` | **(b).** SE-038 은 유형 색이 필요하고 `session.loaded` 뒤 `agent_moved` 한 번으로 전체를 복구해야 한다(SE-038 AC5). 유형을 따로 알리는 이벤트로는 로드 직후 복구가 안 된다. 앞 4칸의 순서는 초안과 같고 5번째에 붙였다 | events.md·view 계약 |
| Q6 | 화장실 방문 상태 | (a) v0 없음, 화장실은 `satisfaction_bonus_bp`로 (b) `at_toilet` 상태 | **(a).** 커버리지 페이로드에 화장실 위치가 없고(build.md), 위치를 받으려면 build 이벤트 개정이 필요하다. 화장실 칸 300 bp 가산이 이미 만족에 들어간다. (b)는 스태프·위생(버티컬 슬라이스)과 함께 | build.md 커버리지 출력 + 이 문서 상태 1개 |
| Q7 | 공연 만족도의 진실의 출처 | (a) audience 평균이 최종(가중치는 audience.json) (b) show.md 가 따로 공식 | **(a)**(SE-030 티켓 추천과 같음). show.md 는 등급 임계만 정한다. 실력·장르 적합(라인업 궁합)도 SF2 에 들어 있다 | SE-030 이 (b)를 택하면 SF2 를 빼고 show.md 와 합치는 방법을 그쪽 문서에 적는다 |
| Q8 | `audience` 스트림 사용 단계 | (a) 입장 결정은 `artist.lineup_set` 수신(단계 4) (b) 다음 틱 단계 2 로 미룸 | **(a).** artist.md 가 "저녁 진입 계산은 `artist.lineup_set` 수신 시"를 계약으로 넘겼고 SE-034 AC3 도 "저녁 진입에 1회"다. tick.md 스트림 표의 `audience` 행 "단계 2"에 "+ `artist.lineup_set` 핸들러(단계 4)"를 더하는 1칸 갱신을 producer 에게 요청(이 티켓 쓰기 범위 밖) | — |
| Q9 | 혼잡 측정 | (a) 공통: 남은 관객 ÷ 수용(공연 끝 1회) (b) 에이전트별 이웃 수 | **(a).** 손계산이 되고 "수용을 꽉 채우면 대가가 있다"를 바로 보여 준다. 길목 혼잡은 대기(SF4)가 따로 잡는다. 혼잡 히트맵(PRD 출력)은 `agent_moved`의 위치로 오버레이가 그린다 | 데이터 필드 추가(스키마 version 2) |
| Q10 | 조기 퇴장자의 집계 | (a) `admissions`(티켓값)에는 넣고 `audience`(바 매출 기준)에서는 뺀다 (b) 환불 | **(a).** 환불 규칙은 events_crisis.md(민원). 만족 평균에는 넣는다(낮은 점수로 끌어내린다) | — |
| Q11 | 성능 예산 | 목표 ≤ 2 ms/틱(티켓), 단언 ≤ 5 ms(SE-034) | 그대로. 비용이 큰 곳은 자리 고르기(순위 앞에서부터 훑기)와 경로 질의(에이전트당 하루 2~3회)이고, 틱마다 하는 일은 에이전트당 상수 | — |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-09 | audience.md v0, `audience.json` v1 + `audience.schema.json` version 1 | SE-029 | 신규. 유형 3(`regular`·`genre_fan`·`walk_in`, 색·장르 적합·가격 민감·바·인내·자리 선호), 입장 수 AD1~AD12, 자리 선택 SP1~SP5, 상태 기계 UP1~UP6·T1~T15·MV1~MV3·P1, 만족 SF0~SF9, 공연 끝 FN1~FN4, 이벤트 4종(`audience.admissions_decided`·`agent_moved`·`agent_left`·`day_summary`) + `economy.sales_reported` 발행, 결정성 R1~R5, 스냅샷 RU1~RU7, 로드 검사 AL1~AL9, 수용 기준 AU0~AU14·AT1~AT6, 기준 시나리오 4개. 티켓 초안에서 바꾼 것: 이동 속도 틱당 1타일 → 4틱당 1타일(Q4), `agent_moved` 원소에 고정소수 좌표와 `type` 추가(Q5), 4번째 `audience.*` 이벤트로 `audience.agent_left` 신설, 화장실 상태 보류(Q6). 기존 테이블 변경 없음 |
