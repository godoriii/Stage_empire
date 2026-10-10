# 공연 (show.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-030 (game-designer) |
| 구현 티켓 | SE-035 (sim-engineer) — `project/sim/show_config.gd`(`ShowConfig`), `project/sim/show_system.gd`(`ShowSystem`), 짝 테스트 `project/tests/sim/test_show_config.gd`, `project/tests/sim/test_show_system.gd`. 마감 리포트 UI 는 SE-039 (render-engineer) |
| 데이터 | [`project/data/show/show.json`](../../project/data/show/show.json) (version 1), 스키마 [`show.schema.json`](../../project/data/schemas/show.schema.json). 읽기 참조: [`artist.json`](../../project/data/artist/artist.json) `show_grades`(등급 id 의 단일 출처), [`audience.json`](../../project/data/audience/audience.json) `satisfaction`(만족 가중치의 단일 출처)·`reference_scenarios`, [`economy.json`](../../project/data/economy/economy.json) `rate_scale`·`rows[tier_1].ticket_price_default` |
| 이벤트 | [events.md](events.md)의 `show.*` 3행. 이 문서에 나오는 이벤트 이름은 전부 거기 표에 있다 |
| 짝 문서 | [reputation.md](reputation.md) — `show.started`·`show.ended`를 받아 명성을 갱신한다 |
| 근거 | PRD "핵심 시스템 상세"(공연 행: 만족도 = 라인업 궁합 × 음향 × 시야 × 편의 − 혼잡 − 대기, 입력 라인업·공간 상태·관객 구성, 출력 만족도·수익·사고 이벤트), "핵심 게임플레이 루프"(공연 = 하루의 클라이맥스, 마감 리포트: 수익·만족도·명성·관계 변화·해금 알림), [audience.md](audience.md) #만족·#공연-끝·Q7, [artist.md](artist.md) #성장·Q10, [tick.md](tick.md) #명령-큐와-틱-순서 |

## 목적

공연 하루를 **등급 하나**로 닫는다. 공연 구간에 들어갈 때 오늘 공연이 열리는지(`show.started`) 아닌지(`show.skipped`) 정하고, 공연이 끝나면 관객이 매긴 평균 만족을 5단계 등급으로 접어 `show.ended`를 낸다. 아티스트 성장(artist.md #성장)과 명성(reputation.md)은 이 등급을 입력으로 쓴다.
show 는 **오늘 공연의 진행 상태**(열렸나, 끝났나)와 등급 판정만 소유한다. 만족도 계산은 audience 가, 라인업은 artist 가, 무대 유무는 build 가 정하고 show 는 그 이벤트를 구독만 한다(CLAUDE.md 원칙 4).
이 문서와 `show.json`만 보고 sim-engineer 가 SE-035 의 show 쪽을, render-engineer 가 SE-039 의 마감 리포트 공연 칸을 질문 없이 시작할 수 있어야 한다.

v0 범위: 공연 시작 조건(라인업·무대), 등급 5단계 임계, `show.started`·`show.skipped`·`show.ended`, 티켓 매출 미리 보기(`revenue_hint`), 스냅샷.
범위 밖: 사고·돌발 이벤트(`events_crisis.md`, MVP 2차 — `incidents`는 빈 배열로 자리만), 공연 중 실시간 반응 수치(view 는 `audience.agent_moved`로 그린다), 다중 무대(티어 4+), 미디어 노출·중계(티어 5).

PRD 결정(고정 틱 10/s, 하루 = 한 공연(티어 1), 세션 4구간)은 바꾸지 않는다.

## 규칙

### 단위

| # | 규칙 |
|---|---|
| U1 | 만족·임계는 `economy.json` `rate_scale`(10,000) 분의 정수 bp. `float` 상태 없음 |
| U2 | 인원·금액·날짜는 `int`. `revenue_hint`는 정수 곱(나눗셈 없음) |

### 만족도와 진실의 출처

PRD 공연 행의 "만족도 = 라인업 궁합 × 음향 × 시야 × 편의 − 혼잡 − 대기"는 **audience 의 에이전트 만족 SF1~SF9 가 정수 가중합으로 이미 계산한다**(audience.md #만족, Q7). show 는 같은 공식을 두 번째로 두지 않는다.

| # | 규칙 |
|---|---|
| SR1 | **진실의 출처.** 공연의 만족도 `satisfaction_bp` = `audience.day_summary.avg_satisfaction_bp`(SF9: 조기 퇴장자 포함 입장자 평균) **하나**다. show 는 이 값을 다시 계산하거나 보정하지 않는다. `show.json` `satisfaction_source`가 이 선택을 고정한다(스키마 `enum` 1값 — 바꾸려면 규칙 개정) |
| SR2 | 가중치를 바꾸고 싶으면 `audience.json` `satisfaction`(`weights_bp`·`penalty_weights_bp`·`skill_*`·`crowd_comfort_bp`)을 고친다. show.json 에는 가중치가 없다 |
| SR3 | **등급** = `show.json` `grades`(나쁜 것 → 좋은 것)에서 `min_bp ≤ satisfaction_bp`인 **마지막** 행의 `id`. 첫 행 `min_bp`가 0 이므로 항상 하나가 고른다 |

PRD 항 → audience 요소 대응(가중치는 `audience.json` `satisfaction`, 값은 v0):

| PRD 항 | audience 요소 | 공식 (audience.md) | 가중치 |
|---|---|---|---|
| 라인업 궁합 = 장르 적합 × 아티스트 실력 | `lineup_bp` | SF2 `⌊fit_t × skill_factor ÷ 10000⌋`, `fit_t` = 유형별 `genre_fit_bp[장르]`(관객 취향 × 아티스트 장르), `skill_factor = min(10000, 5000 + 50 × skill)` | `weights_bp.lineup` 4,000 |
| 음향 | `sound_bp` | SF1, 그 사람이 선 타일이 음향 커버리지 안인 공연 틱 비율(build C1) | `weights_bp.sound` 1,500 |
| 시야 | `sight_bp` | SF1, 시야 커버리지(build C2) | `weights_bp.sight` 1,500 |
| 편의 | `value_bp` + `satisfaction_bonus_bp` | SF3 가격 만족, SF8 편의·장식 가산(build C7 — 화장실 칸 등, 상한 1,500). 바는 대기(바 실패 +30 틱)와 관람 자리 선호로 들어간다 | `weights_bp.value` 3,000, 가산은 그대로 |
| − 혼잡 | `crowd_bp` | SF5, 남은 관객 ÷ 수용이 80% 를 넘는 만큼 | `penalty_weights_bp.crowd` 500 |
| − 대기 | `wait_bp` | SF4, 누적 대기 ÷ 유형 인내 | `penalty_weights_bp.wait` 2,000 |

- 곱이 아니라 가중합인 이유는 audience.md SF 절(기준 배치 음향 23.7% 에서 곱이면 대부분 0)과 같다. "요소가 다 좋아야 높다"는 느낌은 등급 임계(호평 6,000·열광 7,500)가 낸다: 기준 배치에서 라인업만 좋아서는 열광에 닿지 않고 편의 가산(장식·화장실)과 혼잡 관리가 함께 필요하다(#수치표 "열광까지").
- `genres.json` `affinity`(장르 유사도)는 만족에 쓰지 않는다. v0 의 "관객 취향 × 아티스트 장르"는 audience 유형별 `genre_fit_bp`가 맡고, `affinity`는 명성의 장르 집중 판정에 쓴다(reputation.md #장르-집중과-확산).

### 입력 계약

show 가 구독하는 이벤트. 구독 순서는 `system_order`(build, staff, artist, audience, **show**, crisis, economy, reputation) — audience 뒤, reputation 앞.

| 이벤트 | show 동작 |
|---|---|
| `time.phase_changed {from, to, day, tick}` | `phase = to`, `day = day`. `to == "show"`면 #공연-시작 ST0~ST3. `to == "close"`면 CL1 |
| `time.day_started {day}` | `day = day`, `lineup = null`, `lineup_day = 0`, `expected_admissions = 0`, `status = "idle"`. 이벤트 없음 |
| `artist.lineup_set {day, artist_id, genre, grade, popularity, skill}` | LN1~LN3 |
| `audience.admissions_decided {day, admissions, …}` | `day == 상태 day`이고 `admissions`가 `int ≥ 0`이면 `expected_admissions = admissions`. 아니면 `push_warning`, 무시 |
| `build.coverage_changed {has_stage, …}` | `has_stage`가 `bool`이면 저장, 아니면 `push_warning`, 무시. 저녁 진입 틱에 `cause:"sync"`로 반드시 한 번 온다(build.md) |
| `economy.ticket_price_changed {price, from}` | `price`가 `int ≥ 1`이면 `ticket_price = price`, 아니면 `push_warning`, 무시. 새 게임 값 = `economy.json` `rows[tier_1].ticket_price_default`(20) |
| `audience.day_summary {…}` | #공연-끝 DS1~DS5 |

라인업 수신 — 위에서부터 처음 맞는 행.

| # | 조건 | 결과 |
|---|---|---|
| LN1 | `phase != "evening"` 또는 `payload.day != day` | `push_warning`, 무시 |
| LN2 | `artist_id`가 `String`도 `null`도 아님, 또는 `String`인데 `genre`가 `String`이 아님 | `push_error`, 무시(그날은 라인업 없음 → ST1 `no_lineup`) |
| LN3 | 그 밖 | `lineup` = `artist_id == null`이면 `null`, 아니면 `{artist_id, genre}`. `lineup_day = day` |

- show 는 라인업의 인기·실력을 쓰지 않는다(그것은 audience 의 입장·만족 입력). 장르는 `show.started`로 reputation 에 넘긴다.
- artist 가 등록되지 않은 실행(테스트)에서는 `lineup_day`가 오늘이 아니므로 ST1(`no_lineup`)이 된다.

### 상태

ShowSystem 이 소유하는 상태. 전부 스냅샷 대상이다(#스냅샷).

| 필드 | 타입 | 새 게임 값 | 설명 |
|---|---|---|---|
| `day` | int | 1 | `time.*`을 따라온 현재 날 |
| `phase` | String | `"day"` | `time.phase_changed.to` |
| `ticket_price` | int | `ticket_price_default` | `economy.ticket_price_changed.price` |
| `has_stage` | bool | `false` | 마지막 `build.coverage_changed.has_stage` |
| `lineup` | Dictionary 또는 `null` | `null` | 오늘 라인업 `{artist_id: String, genre: String}` |
| `lineup_day` | int | 0 | `lineup`을 받은 날(받지 못했으면 0) |
| `expected_admissions` | int | 0 | 오늘 `audience.admissions_decided.admissions` |
| `status` | String | `"idle"` | `idle`(공연 구간 전) · `running`(`show.started` 뒤) · `skipped`(`show.skipped` 뒤) · `ended`(`show.ended` 뒤 또는 CL1) |

### 공연 시작

`time.phase_changed {to: "show"}`(evening → show, 공연 첫 틱 경계 = 하루 2,400 틱째의 단계 4) 수신 시. 위에서부터 처음 맞는 행.

| # | 조건 | 결과 |
|---|---|---|
| ST0 | `status != "idle"` | `push_warning`, 무시(하루 1회 — 같은 날 `to:"show"`가 두 번 온 계약 위반) |
| ST1 | `lineup_day != day` 또는 `lineup == null` | `status = "skipped"` → `show.skipped {day, reason: "no_lineup"}` |
| ST2 | `has_stage == false` | `status = "skipped"` → `show.skipped {day, reason: "no_stage"}` |
| ST3 | 그 밖 | `status = "running"` → `show.started {day, artist_id: lineup.artist_id, genre: lineup.genre, expected_admissions}` |

- **라인업 없는 날**(ST1): 공연이 없다. 단골 몇 명이 오지만(audience AU1) 그것은 "공연"이 아니라 영업일이다. `show.ended`가 없으므로 아티스트 성장도, 명성 변화도 없다(reputation.md RG0, Q2).
- **무대 없는 날**(ST2): audience 가 아무도 받지 않는다(AD9 `no_stage`). 관객 0 명의 평균 만족(0)으로 등급을 매기면 "참사"가 되어 명성이 깎이는데, 이미 개런티·임대료를 잃은 플레이어에게 이중 벌칙이고 실제로 공연을 본 사람이 없다. 그래서 공연이 열리지 않은 것으로 친다(Q3). 무대는 낮에만 철거할 수 있어(build B2) 저녁 진입의 `sync` 값과 공연 시작 값이 같다.
- 판정 순서: 라인업 → 무대. 둘 다 없으면 `no_lineup`.

### 공연 중

v0 의 show 는 공연 구간에 하는 일이 없다. 만족은 audience 가 틱마다 집계하고(SF0), view 는 `audience.agent_moved`로 반응을 그린다. `ShowSystem.update(ctx)`는 아무것도 하지 않는다(등록은 스냅샷 훅 때문에 필요하다).
돌발 이벤트(장비 고장·민원 등)는 `events_crisis.md`(MVP 2차)가 공연 중 이벤트를 내고, 그 결과를 `show.ended.incidents`에 담는 규칙을 그 티켓이 더한다. v0 `incidents`는 항상 `[]`.

### 공연 끝

`audience.day_summary` 수신 시(공연 마지막 틱 = show → close 전환 틱, 단계 2 의 audience `update` 안). 위에서부터 처음 맞는 행.

| # | 조건 | 결과 |
|---|---|---|
| DS1 | `day`·`admissions`·`audience`·`avg_satisfaction_bp`가 `int`가 아님, 또는 `avg_satisfaction_bp ∉ [0, 10000]`, 또는 `0 ≤ audience ≤ admissions`가 아님 | `push_error`, 무시 |
| DS2 | `payload.day != day` | `push_warning`, 무시 |
| DS3 | `status == "skipped"` | 무시(경고 없음 — audience 는 공연이 없는 날에도 요약을 낸다) |
| DS4 | `status != "running"`(`idle`·`ended`) | `push_warning`, 무시(공연 시작 누락 또는 같은 날 두 번째 요약) |
| DS5 | 그 밖 | 아래 SE1~SE4 → `status = "ended"` → `show.ended` |

| # | 값 | 공식 |
|---|---|---|
| SE1 | `satisfaction_bp` | `avg_satisfaction_bp`(SR1, 그대로) |
| SE2 | `grade` | SR3 |
| SE3 | `revenue_hint` | `admissions × ticket_price` — economy S1 `ticket_revenue`와 같은 값(정산 전 미리 보기). 바 매출·비용·세금은 정산(`economy.day_settled`)에서만 나온다 |
| SE4 | `incidents` | `[]`(v0) |

- `show.ended {day, artist_id: lineup.artist_id, satisfaction_bp, grade, admissions, audience, revenue_hint, incidents}`. `admissions`·`audience`는 요약 값 그대로(조기 퇴장 = `admissions − audience`).
- 요약의 `has_lineup`이 `false`인데 `status == "running"`이면(라인업 이벤트를 audience 와 show 가 다르게 받은 계약 위반) `push_warning` 1회 후 DS5 를 그대로 진행한다. show 의 라인업이 기준이다.

| # | 조건 | 결과 |
|---|---|---|
| CL1 | `time.phase_changed {to: "close"}` 수신 시 `status == "running"` | `push_warning`(요약 누락 — audience 미등록 등), `status = "ended"`. `show.ended`는 내지 않는다(만족을 모르는 공연을 등급으로 접지 않는다) |

**이벤트 순서**(같은 틱, tick.md E2·E6).
- 공연 첫 틱(2,400) 단계 4: `time.phase_changed {evening→show}` → `show.started` 또는 `show.skipped` → (`reputation`이 `show.started` 수신) → `tick.advanced`. (배속은 show 진입에서 1 로 유지되어 보통 `time.speed_changed`가 없다.)
- 공연 마지막 틱(3,300) 단계 2: … → `audience.agent_moved`(전원 `gone`) → `audience.day_summary` → `show.ended` → `artist.grown` → `reputation.changed` → `economy.sales_reported` → (단계 4) `time.phase_changed {show→close}` → `economy.cash_changed` → `economy.day_settled` → (`reputation.tier_unlocked`) → `time.speed_changed {speed:0}` → `tick.advanced`.
- `show.ended`의 구독자 순서는 `system_order`대로 artist(성장) → reputation(명성). 그래서 `artist.grown`이 `reputation.changed`보다 먼저 나온다. SE-035 AC2("`show.ended`는 `audience.day_summary` 뒤·`economy.day_settled` 앞")와 audience.md #공연-끝 순서와 맞는다.

### 이벤트

전부 상태 이벤트(sim → 구독자). 페이로드는 tick.md E4 기본형. 상태를 먼저 갱신하고 낸다(E8).

| 이벤트 | 페이로드 | 발행 시점 | 1일 횟수 |
|---|---|---|---|
| `show.started` | `{day: int, artist_id: String, genre: String, expected_admissions: int}` — `genre`는 `artist.json` `mvp_genres` 중 하나, `expected_admissions` = 그날 `audience.admissions_decided.admissions`(못 받았으면 0) | ST3, 공연 첫 틱 단계 4 | 0~1 |
| `show.skipped` | `{day: int, reason: "no_lineup"\|"no_stage"}` | ST1·ST2, 공연 첫 틱 단계 4 | 0~1 |
| `show.ended` | `{day: int, artist_id: String, satisfaction_bp: int, grade: "disaster"\|"poor"\|"ok"\|"good"\|"rave", admissions: int, audience: int, revenue_hint: int, incidents: Array}` — `grade`는 영문 id(`artist.json` `show_grades`, artist.md Q10), `incidents`는 v0 항상 `[]` | DS5, 공연 마지막 틱 단계 2(`audience.day_summary` 처리 중) | 0~1 |

- 하루에 `show.started`와 `show.skipped` 중 정확히 하나가 나온다(공연 구간에 들어간 날, show 등록 시). `show.ended`는 `show.started`가 나온 날에만, 정확히 1회(audience 등록 시).
- 표시 이름(참사·부진·보통·호평·열광)은 `show.json` `grades[].name`. 이벤트에는 id 만 싣는다.

### 결정성과 RNG

- show v0 는 **난수를 쓰지 않는다.** 어떤 스트림도 뽑지 않는다(전 스트림 상태 불변). tick.md 스트림 표에 `show`를 추가하지 않는다.
- 공식은 비교와 정수 곱뿐이다. 순회는 `grades` 배열(데이터 순서) 하나.
- 같은 입력 이벤트 열이면 같은 `show.*` 이벤트 열과 같은 스냅샷이 나온다.

### 스냅샷

`TickLoop.register_system("show", show.update, show.snapshot, show.restore)`로 **반드시** 등록한다(공연 중 세이브에서 `status`·라인업이 사라지면 복원 뒤 `show.ended`가 나오지 않는다).

`ShowSystem.snapshot() -> Dictionary` = `{day, phase, ticket_price, has_stage, lineup, lineup_day, expected_admissions, status}`(#상태 표의 8개, 깊은 복사본, 기본형만).

`ShowSystem.restore(d) -> bool`. 정수 필드는 `int`로 정규화(JSON 왕복의 `float`, 정수값이 아니면 실패). 아래 검사를 **전부 끝낸 뒤** 적용한다(tick.md SH3). 첫 위반에서 `push_error` 1회, `false`, 상태 불변, 이벤트 0.

| # | 검사 |
|---|---|
| SS1 | 8개 키가 있고 타입이 맞음(`has_stage` `bool`, `lineup` Dictionary 또는 `null`) |
| SS2 | `day ≥ 1`, `phase ∈ sim.json phases[].id`, `ticket_price ≥ 1`, `expected_admissions ≥ 0`, `0 ≤ lineup_day ≤ day` |
| SS3 | `lineup`이 `null` 또는 정확히 `{artist_id: String, genre: String}`이고 `genre ∈ artist.json mvp_genres` |
| SS4 | `status ∈ {idle, running, skipped, ended}`. `running`이면 `phase == "show"`이고 `lineup != null` |

- 복원 뒤 이벤트 없음. 복원 후 진행 = 연속 진행(SH6). `sim.json.snapshot_schema_version`은 바꾸지 않는다(`systems.show` 항목 추가만).

### 설정 로드 검사

`ShowConfig.load()`가 스키마로 못 하는 교차 검사를 한다. 실패하면 `push_error`, `null`.

| # | 검사 |
|---|---|
| SL1 | `version == 1`, `economy.json` `rate_scale == 10000` |
| SL2 | `grades[].id`를 순서대로 늘어놓은 배열 == `artist.json` `show_grades`(등급 id 와 순서의 단일 출처는 artist.json, artist.md Q10) |
| SL3 | `grades[0].min_bp == 0`, `min_bp`가 엄격히 증가, 마지막 `min_bp ≤ 10000` |
| SL4 | `satisfaction_source == "audience.day_summary.avg_satisfaction_bp"`(스키마와 같은 값, 로더도 한 번 더) |

`reference_scenarios`는 런타임이 읽지 않는다(테스트·qa 용). `audience_scenario`가 `audience.json`에 있는지는 qa 스크립트(SH12)가 본다.

### 공개 API (SE-035 구현 대상, 이름 제안)

| 클래스 | 멤버 | 설명 |
|---|---|---|
| `ShowConfig` | `static load(path := "res://data/show/show.json") -> ShowConfig`, `static from_dicts(show: Dictionary, artist: Dictionary, economy: Dictionary) -> ShowConfig` | SL1~SL4. `load`는 나머지를 기본 경로에서 읽는다 |
| | `grade_ids() -> Array[String]`, `grade_name(id) -> String`(없으면 `""`), `min_bp(id) -> int`(없으면 −1), `grade_for(satisfaction_bp: int) -> String`(SR3), `scenario(id) -> Dictionary`(없으면 `{}`, 오류 없음), `ticket_price_default` | 읽기 전용 |
| `ShowSystem` | `new(config: ShowConfig, bus: EventBus)` | #입력-계약의 7개 이벤트 구독. 생성자는 이벤트를 내지 않는다 |
| | `static compute_result(cfg: ShowConfig, summary: Dictionary, ticket_price: int) -> Dictionary` | 순수 함수 SE1~SE4 → `{satisfaction_bp, grade, admissions, audience, revenue_hint, incidents}`. 형식 오류면 `{}`. 테스트·봇이 쓴다(SE-035 범위의 `compute_result(inputs)`) |
| | `update(ctx)`(아무것도 안 함), `snapshot()`, `restore(d)` | #스냅샷 |
| | `status`, `day`, `phase`, `lineup`(깊은 복사), `expected_admissions`, `ticket_price`, `has_stage` | 읽기 전용 |

### SE-035 구현 인계 (show + reputation)

| 항목 | 내용 |
|---|---|
| 파일 | `project/sim/show_config.gd`, `show_system.gd`, `reputation_config.gd`, `reputation_system.gd` + 짝 테스트 4개(`project/tests/sim/test_{show,reputation}_{config,system}.gd`). 전부 `RefCounted`, Node 없음 |
| 등록 | `TickLoop.register_system("show", …4인자)`, `register_system("reputation", …4인자)`. 생성·구독 순서는 `system_order`(show 는 audience 뒤, reputation 은 마지막) |
| 구독 | show 7개(#입력-계약), reputation 4개(reputation.md #입력-계약). 티켓 초안 목록과 다른 점: show 에 `audience.admissions_decided`·`economy.ticket_price_changed`·`time.day_started` 추가, reputation 은 `time.phase_changed` 대신 `show.started`·`time.day_started` |
| 순수 함수 | `ShowSystem.compute_result`(SE1~SE4), `ReputationSystem.compute_delta`(RG2~RG5) — economy `compute_settlement`와 같은 꼴 |
| 데이터 | `show.json`, `reputation.json`, 읽기 `artist.json`·`audience.json`(시나리오)·`genres.json`·`tiers.json`·`economy.json`. 숫자 리터럴 금지 — 기대값은 `reference_scenarios`에서 |
| 수용 기준 | show SH1~SH9 + reputation RP1~RP10 = 19 케이스(SE-035 AC6 "신규 ≥ 18") |
| 난수 | 없음. 전 스트림 상태 불변을 SH9·RP9 가 단언 |

### 마감 리포트 필드 (SE-039 인계)

PRD "마감: 수익·만족도·명성 리포트, 아티스트 관계 변화, 해금 알림". 리포트는 close 진입 틱까지 받은 이벤트를 합성한다(상태를 읽지 않는다). 표시 **순서**는 SE-039 2차(game-designer)가 확정하고, 이 표는 필드와 출처의 전부다.

| # | 항목 | 출처(이벤트.필드) | 공연 없는 날(`show.skipped`) |
|---|---|---|---|
| R1 | 날짜 | `economy.day_settled.day` | 같음 |
| R2 | 아티스트 | `artist.lineup_set.artist_id` → `artists.json` 이름, `genre` → `genres.json` `name`, `grade`(로컬·신인) | "공연 없음" + `show.skipped.reason`(`no_lineup` "섭외 없음", `no_stage` "무대 없음" — 문구는 `ui_ko.json`) |
| R3 | 공연 등급 | `show.ended.grade` → `show.json` `grades[].name`, `show.ended.satisfaction_bp`(÷ 100 = %) | 숨김 |
| R4 | 관객 | `show.ended.admissions`, `show.ended.audience`, 조기 퇴장 `audience.day_summary.left_early` | `audience.day_summary.admissions`(단골만) |
| R5 | 만족 요소 | `audience.day_summary.avg_components`(`lineup_bp`·`sound_bp`·`sight_bp`·`value_bp`·`wait_bp`), `crowd_bp` | 숨김 |
| R6 | 수익 | `economy.day_settled.ticket_revenue`, `bar_revenue`, `revenue` | 같음 |
| R7 | 비용 | `economy.day_settled.rent`, `upkeep`, `guarantee`, `bar_cost`, `tax`, `loan_repayment` | 같음 |
| R8 | 순이익·현금 | `economy.day_settled.net`, `cash` | 같음 |
| R9 | 명성 | `reputation.changed.delta`(부호 표시), `total` | "명성 변화 없음"(Δ 0, `total`은 HUD 값 유지 — reputation.md RG0) |
| R10 | 장르별 명성 | `reputation.changed.by_genre`(장르 이름·강조색 `genres.json`) | 이전 값 유지 |
| R11 | 아티스트 변화 | `artist.grown.popularity_delta`, `skill_delta`, `promoted`(승급 배지) | 숨김 |
| R12 | 해금 알림 | `reputation.tier_unlocked {tier}` → 토스트 + "계속 플레이". 다음 해금 진행도 = `total ÷ tiers[다음].unlock_reputation`, `cash ÷ tiers[다음].unlock_cash` | 같음(공연 없는 날도 정산 현금으로 해금될 수 있다) |
| R13 | 구제·파산 | `economy.bailout_offered`·`economy.bankrupt`(economy.md) | 같음 |

- 돈은 반드시 `economy.day_settled`에서 읽는다. `show.ended.revenue_hint`는 공연 중·직후 HUD 미리 보기용이고 리포트의 티켓 매출(`ticket_revenue`)과 값이 같다.
- 리포트에 필요한 이벤트는 전부 close 진입 틱의 `tick.advanced` 전에 끝난다(#공연-끝 이벤트 순서). 공연 없는 날은 `show.ended`·`reputation.changed`·`artist.grown`이 오지 않으므로 R3·R5·R11 을 숨기고 R9 는 "변화 없음"이다.

#### 표시 순서 (SE-039 2차 확정)

위에서 아래로 한 열. 묶음은 "오늘 무슨 공연이 있었나 → 돈 → 돈의 결과 → 평판 → 다음 목표" 순서다. 문구 키는 `ui_ko.json` `ui.report.r<n>`(공연 없는 날 변형 `_none`·`skip.*`).

| 순서 | 행 | 묶음 | 근거 |
|---|---|---|---|
| 1 | R1 날짜 | 머리 | 제목(`ui.report.title`)과 같은 날 — 불러오기 직후(`show.ended` 재발행 없음)에도 항상 채워지는 행 |
| 2 | R2 아티스트 | 공연 | 오늘의 주인공. 공연 없는 날엔 이 줄이 이유("섭외한 아티스트가 없었다"/"무대가 없었다")를 말한다 |
| 3 | R3 공연 등급 | 공연 | 하루의 클라이맥스 결과(PRD "공연 = 하루의 클라이맥스") |
| 4 | R4 관객 | 공연 | 등급의 규모 |
| 5 | R5 만족 요소 | 공연 | 등급의 원인(다음 날 무엇을 고칠지) |
| 6 | R6 수익 | 돈 | 회계 순서: 수익 → 비용 → 합 |
| 7 | R7 비용 | 돈 | |
| 8 | R8 순이익·현금 | 돈 | 묶음의 합계 줄 |
| 9 | **R13 구제·파산** | 돈의 결과 | **show.md 표 순서에서 옮김.** 구제·파산은 R8 현금이 음수가 된 결과라 바로 아래에 둬야 인과가 읽힌다. 평소엔 "재정 이상 없음" 한 줄 |
| 10 | R9 명성 | 평판 | |
| 11 | R10 장르별 명성 | 평판 | |
| 12 | R11 아티스트 변화 | 평판 | PRD "아티스트 관계 변화" — 명성 다음 |
| 13 | R12 해금 진행도 | 다음 목표 | 마지막 줄 = "다음 날" 버튼 바로 위. 해금 목표를 보고 버튼을 누르게 한다 |

- 배열: `R1, R2, R3, R4, R5, R6, R7, R8, R13, R9, R10, R11, R12`. 1차 초안(`ui_params.tres report_rows` = R1~R13 표 순서)과 다른 곳은 R13 위치 하나. `ui_params.tres` 는 render-engineer 소유라 game-designer 는 바꾸지 않고 SE-039 티켓 결과 절로 인계한다.
- 숨김 규칙(R3·R5·R11)은 순서와 무관하다. 숨긴 행은 자리를 남기지 않는다.

## 수치표

모든 값은 [`show.json`](../../project/data/show/show.json) (version 1). 만족 가중치는 `audience.json`(audience.md #수치표).

### 등급 임계 (`grades`)

| id | 표시 | `min_bp` | 구간 | 성격 | 기준 시나리오(audience) |
|---|---|---|---|---|---|
| `disaster` | 참사 | 0 | 0 ~ 2,999 | 관객 대부분이 불만. 라인업 장르가 관객과 크게 어긋나고 대기·혼잡이 겹친 날 | — |
| `poor` | 부진 | 3,000 | 3,000 ~ 4,999 | "라인업 없는 영업일" 수준(단골만 온 날 4,600). 아티스트를 불렀는데 이 정도면 실패 | (`no_lineup` 4,600 — 공연이 아니라 등급 없음) |
| `ok` | 보통 | 5,000 | 5,000 ~ 5,999 | 무난. 가격을 올렸거나 자리가 나쁜 날 | `local_top_price30` 5,730 |
| `good` | 호평 | 6,000 | 6,000 ~ 7,499 | 기준 배치 + 맞는 라인업의 정상 공연 | `local_top_baseline` 6,732, `rookie_baseline` 6,733 |
| `rave` | 열광 | 7,500 | 7,500 ~ 10,000 | 실력 있는 아티스트 + 편의 가산 + 혼잡 관리까지 된 공연 | — |

- **단조 증가**: 0 < 3,000 < 5,000 < 6,000 < 7,500 (SL3, SH10).
- **기준 시나리오가 경계에서 떨어져 있다**: audience 의 평균 만족 범위(`avg_satisfaction_bp_range`, 손계산 − 300 ~ 손계산)가 등급 안에 통째로 든다. `local_top_baseline` 6,432~6,732 → 전부 호평(경계 6,000 까지 432), `rookie_baseline` 6,433~6,733 → 호평, `local_top_price30` 5,430~5,730 → 보통(경계 5,000 까지 430, 6,000 까지 270). 그래서 시드·경로 동점 처리에 따라 등급이 바뀌지 않는다(`grade_over_range`).
- **실패 등급**(명성이 깎이는 등급)은 `disaster`·`poor`이다(reputation.md RG2). "보통"은 작은 이득이다.
- 호평 하한 6,000 은 audience AT5(기준 시나리오 평균 5,000~8,000 = "보통~호평")의 가운데 위쪽이다. 로컬 상위 공연이 첫날부터 호평이고(성장 +2, artist.md), 가격을 30 으로 올리면 한 단계 내려간다(AU5 → 보통).

### 열광까지 (설계 확인 손계산, 수용 기준 아님)

기준 배치(`satisfaction_bonus_bp` 100)에서 팬(장르 적합 10,000)의 만족 = `0.4 × skill_factor + 3,000(음향·시야) + 1,500(가격 20) + 100 − 혼잡`. 가산 100 에서 팬이 열광(7,500)이 되려면 `skill_factor ≥ 7,250`(실력 45), 장르 적합 8,000 인 단골·뜨내기는 `skill_factor ≥ 9,063`(실력 82)이 필요하다. 그래서 평균 열광은 실력만으로는 늦고 편의 가산(장식·화장실, build C7 상한 1,500)과 함께 온다.

| 경우 | 팬 | 단골 / 뜨내기 | 평균(대략) | 등급 |
|---|---|---|---|---|
| s07(indie) 실력 18, 가산 100, 83명 | 6,960 | 6,488 / 6,488 | 6,732 | 호평 |
| s07 실력 40(공연 15회 — 7회째 신인 승급 뒤 +1씩), 가산 100 | 7,400 | 6,840 / 6,840 | ~7,130 | 호평 |
| s07 실력 40, 가산 700(장식·화장실 +600) | 8,000 | 7,440 / 7,440 | ~7,730 | 열광 |
| s12(electronic rookie) 실력 64, 가산 100, 만석 122(혼잡 10,000, 28명이 음향·시야 하나 놓침) | 7,380 | 6,068 / 7,380 | ~6,960 | 호평 |
| s12 만석, 가산 1,500(상한) | 8,780 | 7,468 / 8,780 | ~8,360 | 열광 |

열광은 "좋은 아티스트 + 투자한 공간"의 보상이다. 수용을 꽉 채우면(입장/수용 > 80%) 혼잡 감점으로 한 단계 아래로 내려갈 수 있다(audience Q9 의도 — reputation.md 부록 C 의 연동 추정에서 만석 s07 은 6,198 로 호평 하한 근처).

## 기준 시나리오

`show.json` `reference_scenarios`(5개). 입력 = `audience.json` 같은 id 시나리오의 `audience.day_summary`(시드 0, 손계산 평균 `avg_satisfaction_bp_hand`) + `build.coverage_changed.has_stage` + 티켓가(audience 시나리오의 `ticket_price`).

| id | audience 시나리오 | 무대 | 결과 | `expected_admissions` | `satisfaction_bp` | `grade` | 범위 양 끝 등급 | `admissions` / `audience` | `revenue_hint` |
|---|---|---|---|---|---|---|---|---|---|
| `no_lineup` | `no_lineup` | 있음 | `show.skipped {reason:"no_lineup"}` | — | — | — | — | — | — |
| `local_top_baseline` | `local_top_baseline` | 있음 | `show.ended` | 83 | 6,732 | `good` | 6,432 / 6,732 → `good` | 83 / 83 | 83 × 20 = **1,660** |
| `rookie_baseline` | `rookie_baseline` | 있음 | `show.ended` | 120 | 6,733 | `good` | 6,433 / 6,733 → `good` | 120 / 120 | 120 × 20 = **2,400** |
| `local_top_price30` | `local_top_price30` | 있음 | `show.ended` | 53 | 5,730 | `ok` | 5,430 / 5,730 → `ok` | 53 / 53 | 53 × 30 = **1,590** |
| `no_stage` | `local_top_baseline`(라인업만) | 없음 | `show.skipped {reason:"no_stage"}` | — | — | — | — | — | — |

손계산: SR3 은 비교만 한다. 6,732 ≥ 6,000 이고 < 7,500 → `good`. 5,730 ≥ 5,000 이고 < 6,000 → `ok`. `revenue_hint`는 economy S1 과 같은 곱이다(`local_top_baseline`의 economy 정산 `ticket_revenue` 1,660 과 일치, audience.md "기준 배치의 하루 손익").

## 수용 기준

### 구현 (SE-035 — `test_show_config.gd`는 SH1, 나머지는 `test_show_system.gd`)

기대 수치는 테스트에 하드코딩하지 않고 `show.json` `grades`·`reference_scenarios`와 `audience.json` `reference_scenarios`에서 읽는다. 이벤트 이름·`reason`·등급 id 는 리터럴로 단언한다. 공통 전제: `EventBus` + `ShowSystem`, 입력 이벤트(`time.*`, `artist.lineup_set`, `audience.admissions_decided`, `build.coverage_changed`, `audience.day_summary`)는 테스트가 직접 발행한다. SH8·SH9 는 `TickLoop`으로 구동한다.

| # | 케이스 | 검증 |
|---|---|---|
| SH1 | `test_config_loads_and_cross_checks` | 실제 데이터로 `ShowConfig.load()` 성공. SL1~SL4 를 하나씩 깬 사본 5건 이상이 `null`(`grades` 순서를 `poor, disaster, …`로, `rave` → `legend`, 첫 `min_bp` 100, `good.min_bp == ok.min_bp`, `satisfaction_source` 다른 문자열(스키마 우회 사본), `version` 2) |
| SH2 | `test_grade_boundaries` | `grades`의 각 행 `k ≥ 1`: `grade_for(min_bp_k − 1) == id_{k−1}`, `grade_for(min_bp_k) == id_k`. `grade_for(0) == "disaster"`, `grade_for(10000) == "rave"` (경계 10건) |
| SH3 | `test_reference_scenarios` | 5개 시나리오 각각 저녁 진입(`artist.lineup_set` — `no_lineup`은 `artist_id: null`, 그 밖은 audience 시나리오 `lineup`의 장르) → `audience.admissions_decided {admissions}` → 공연 진입 → `audience.day_summary {admissions, audience, avg_satisfaction_bp: avg_satisfaction_bp_hand, …}` → `expected`와 같은 이벤트·페이로드(`show.started.expected_admissions`, `show.ended`의 `satisfaction_bp`·`grade`·`admissions`·`audience`·`revenue_hint`, `incidents == []`). `grade_over_range`: 같은 입력에서 만족만 범위 양 끝으로 바꾼 두 실행의 `grade`가 같음 |
| SH4 | `test_skipped_days` | 라인업 없음 → `show.skipped {reason:"no_lineup"}` 1회, `show.started`·`show.ended` 0회(그날 `audience.day_summary`가 와도). 라인업 있고 `has_stage false` → `show.skipped {reason:"no_stage"}`. 둘 다 없으면 `no_lineup`. artist 미등록(라인업 이벤트 없음) → `no_lineup` |
| SH5 | `test_ended_once_and_guards` | DS1(`avg_satisfaction_bp: 10001`, `audience > admissions`, 키 누락) `push_error`·이벤트 0, DS2(다른 날) 경고·무시, DS4(같은 날 두 번째 요약) 경고·`show.ended` 추가 0, ST0(같은 날 두 번째 `to:"show"`) 경고, CL1(요약 없이 close) 경고·`show.ended` 0·`status "ended"`, LN1(낮에 온 라인업) 경고. 각 경우 스냅샷 해시가 기대대로(무시 행은 불변) |
| SH6 | `test_revenue_hint_follows_price` | `economy.ticket_price_changed {price: 30}` 뒤 같은 요약 → `revenue_hint == admissions × 30`. 잘못된 가격(`0`, `"x"`)은 경고·무시 |
| SH7 | `test_compute_result_pure` | `compute_result`가 SH3 의 `show.ended` 페이로드(날짜·`artist_id` 제외)와 같고, 입력 Dictionary 불변, 형식 오류 입력 → `{}` |
| SH8 | `test_event_order_tickloop` | `TickLoop`에 build·artist·audience·show·economy(·reputation 이 있으면 함께)를 훅과 함께 등록, 기준 배치에서 로컬 섭외 후 하루(3,300 틱): `show.started`는 2,400 틱의 `time.phase_changed {to:"show"}` 바로 뒤 1회, `show.ended`는 3,300 틱에 `audience.day_summary` 뒤·`economy.sales_reported` 앞·`economy.day_settled` 앞 1회, `artist.grown`이 `show.ended` 뒤(SE-035 AC2) |
| SH9 | `test_determinism_and_snapshot` | (a) 같은 입력 두 번 → `show.*` 이벤트 열·`snapshot()` 해시 같음, 전 RNG 스트림 상태 불변. (b) 공연 중(`status "running"`)에 `snapshot()` → JSON 왕복 → 새 시스템 `restore()` `true` → 요약 발행 → `show.ended`가 연속 진행과 같음. (c) 거부 사본 ≥ 4건(`status "playing"`, `running`인데 `lineup null`, `lineup_day > day`, `lineup.genre "jazz"`) 각각 `false`, `push_error` 1회, 해시 불변, 이벤트 0 |

### 데이터·문서 (SE-030, qa·reviewer)

| # | 검증 | 방법 |
|---|---|---|
| SH10 | `show.json` 스키마 통과(`--strict`), `grades` id 순서 == `artist.json` `show_grades`, `min_bp` 첫 0·엄격히 증가 | 아래 qa 스크립트 exit 0 |
| SH11 | 만족도 공식이 한 곳(`audience.json` `satisfaction`)에만 있다: `show.json`에 가중치 키 없음, `satisfaction_source` 1값 | reviewer + 스키마 |
| SH12 | 기준 시나리오 `expected`가 `audience.json` 시나리오 값(입장·관람·손계산 평균·범위·가격)과 `show.json` 임계로 재계산한 값과 같음 | 아래 qa 스크립트 |
| SH13 | 이 문서의 이벤트 3개가 events.md 표와 같은 페이로드, `show.ended.grade`가 영문 id | reviewer |

### 수치 목표 (데이터가 바뀌어도 지켜야 할 범위)

| # | 목표 | 현재 값 |
|---|---|---|
| ST1 | 기준 배치 + 로컬 상위(`local_top_baseline`)의 평균 만족 범위 전체가 `good` | 6,432~6,732 → good |
| ST2 | 가격 30(`local_top_price30`)은 가격 20 보다 정확히 한 단계 낮음 | good → ok |
| ST3 | 각 기준 시나리오의 만족 범위가 등급 경계에서 200 bp 이상 떨어짐(시드·경로 동점에 등급이 흔들리지 않음) | 최소 270(price30 상한 5,730 ↔ 6,000) |
| ST4 | 단골만 온 영업일 수준(`no_lineup` 4,600)은 `poor` 구간 — 아티스트를 불러 이 수준이면 실패로 친다 | 3,000 ≤ 4,600 < 5,000 |

## 테스트 방법

- 데이터(이 티켓): `python3 tools/validate_data.py --strict` exit 0.
- qa 재계산(SH10·SH12): 리포 루트에서

```bash
python3 - <<'PY'
import json, sys
D = "project/data/"
S = json.load(open(D + "show/show.json", encoding="utf-8"))
A = json.load(open(D + "audience/audience.json", encoding="utf-8"))
ART = json.load(open(D + "artist/artist.json", encoding="utf-8"))
err = []
ids = [g["id"] for g in S["grades"]]; mins = [g["min_bp"] for g in S["grades"]]
if ids != ART["show_grades"]: err.append(f"grades 순서 {ids} != show_grades {ART['show_grades']}")
if mins[0] != 0 or any(b <= a for a, b in zip(mins, mins[1:])) or mins[-1] > 10000: err.append(f"min_bp 단조 위반 {mins}")
if S["satisfaction_source"] != "audience.day_summary.avg_satisfaction_bp": err.append("satisfaction_source")
grade = lambda s: [g["id"] for g in S["grades"] if g["min_bp"] <= s][-1]
AS = {s["id"]: s for s in A["reference_scenarios"]}
for sc in S["reference_scenarios"]:
    a, x = AS.get(sc["audience_scenario"]), sc["expected"]
    if a is None: err.append(sc["id"] + ": audience 시나리오 없음"); continue
    ax = a["expected"]
    if a["lineup"] is None: got = {"event": "show.skipped", "reason": "no_lineup"}
    elif not sc["has_stage"]: got = {"event": "show.skipped", "reason": "no_stage"}
    else:
        s = ax["avg_satisfaction_bp_hand"]; lo, hi = ax["avg_satisfaction_bp_range"]
        g_lo, g_hi = grade(lo), grade(hi)
        if g_lo != g_hi: err.append(f"{sc['id']}: 범위 안에서 등급이 바뀜 {g_lo}/{g_hi}")
        got = {"event": "show.ended", "expected_admissions": ax["admissions"], "satisfaction_bp": s, "grade": grade(s),
               "grade_over_range": g_hi, "admissions": ax["admissions"], "audience": ax["audience"],
               "revenue_hint": ax["admissions"] * a["ticket_price"]}
    if got != x: err.append(f"{sc['id']}: {x} != {got}")
print("grades:", list(zip(ids, mins)))
print("\n".join(err) or "SH OK"); sys.exit(1 if err else 0)
PY
```

  기대 출력: `grades: [('disaster', 0), ('poor', 3000), ('ok', 5000), ('good', 6000), ('rave', 7500)]` / `SH OK`, exit 0.
- 손계산(reviewer): #기준-시나리오 표를 SR3·SE3 과 audience.md 부록 B 의 값만으로 다시 계산한다.
- 헤드리스(SE-035): `tools/run_tests.sh project/tests/sim` → SH1~SH9. Godot 이 없으면 SKIP → CI(`godot-tests`).
- 변이(qa, SE-035): "SR3 의 `≤`를 `<`로" 패치 → SH2 의 경계(`grade_for(min_bp_k) == id_k`)만 실패. "ST2 제거"(무대 없어도 공연) → SH4 의 `no_stage` 케이스만 실패.

## 열린 질문

> **결정(2026-10-09, 사람 검수 최소화 원칙):** 아래 질문 전부 추천안을 채택해 데이터와 규칙에 넣었다. ADR 이 필요한 변경은 없다. 바꾸려면 새 질문으로 다시 올린다. producer 가 `docs/status/` 결정 로그로 옮긴다.

| # | 질문 | 선택지 | 채택(추천) | 바꾸면 |
|---|---|---|---|---|
| Q1 | 공연 만족도의 진실의 출처 | (a) 관객 평균 `audience.day_summary.avg_satisfaction_bp`가 최종, show 는 등급만 (b) show.md 가 PRD 곱 공식을 따로 계산(커버리지 비율 × 라인업 …) (c) 둘을 섞음(평균 × show 보정) | **(a)**(audience.md Q7 과 같은 결정). 한 공식만 두면 가중치 조정이 한 파일(`audience.json`)에서 끝나고, 에이전트별 위치(음향·시야)·대기를 반영한 값이 커버리지 비율보다 정확하다. (b)는 두 값이 갈라질 때 어느 쪽이 맞는지 정할 수 없다. (c)는 같은 요소를 두 번 센다 | (b)·(c)는 audience SF2 를 빼고 이 문서에 공식을 옮기는 개정(audience.json·show.json 스키마 version 2) |
| Q2 | 등급 임계 | (a) 0 / 3,000 / 5,000 / 6,000 / 7,500 (b) 0 / 3,000 / 5,000 / 6,500 / 8,000 (c) 균등 2,000 간격 | **(a).** 기준 시나리오 평균 범위(6,432~6,733)가 호평 안에 경계에서 400 bp 이상 떨어져 들어간다. (b)는 6,432 가 보통으로 떨어져 같은 배치가 시드에 따라 등급이 바뀐다(ST3 위반). (c)는 "라인업 없는 영업일"(4,600)과 기준 공연(6,732)이 한 등급이 된다 | 데이터만(`grades[].min_bp`) + reputation 기준 시나리오 재계산 |
| Q3 | 라인업은 있는데 무대가 없는 날 | (a) `show.skipped {reason:"no_stage"}`(명성 변화 0, 성장 없음) (b) 공연으로 치고 관객 0 → 참사(명성 감소) | **(a).** 관객 0 명의 평균은 의미가 없고, 개런티·임대료 손실이 이미 벌칙이다. 무대 철거는 낮에만 되므로 플레이어가 고르기 어려운 상황도 아니다 | (b)는 ST2 삭제, DS1 의 `admissions == 0` 처리 추가 |
| Q4 | `show.ended`에 `genre` 를 넣나 | (a) 티켓 페이로드 그대로, reputation 이 `show.started.genre`를 기억 (b) `show.ended`에 `genre` 추가 | **(a)**(티켓 범위 페이로드 유지). reputation 상태에 `show_genre` 1개가 더 생긴다. 리포트(SE-039)는 장르를 `artist.lineup_set`에서 읽는다 | (b)는 events.md 페이로드 1키 추가 + reputation 상태 1개 삭제 |
| Q5 | `revenue_hint`의 뜻 | (a) 티켓 매출 = `admissions × ticket_price`(economy S1 과 같은 값) (b) 바 매출 추정까지 포함 (c) 0(예약) | **(a).** 정산 전에 확정되는 유일한 매출이고 economy 공식과 같은 곱이라 갈라지지 않는다. 바·비용은 정산 리포트가 보여 준다 | (b)는 economy S2~S4 를 show 가 복제하게 되어 피한다 |
| Q6 | 등급 표시 이름의 위치 | (a) v0 는 `show.json` `grades[].name`(audience.json `types[].name`과 같은 관례) (b) `ui_ko.json` | **(a) 지금, (b)는 SE-039 2차가 문자열 테이블을 만들 때 옮긴다.** id 가 이벤트 계약이고 이름은 표시용이라 옮겨도 규칙은 바뀌지 않는다 | 스키마 `name` 필드 제거(version 2) |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-10 | show.md v0.1 (데이터 변경 없음) | SE-039 2차 | 마감 리포트 표시 순서 확정(#표시-순서-se-039-2차-확정): R13 을 R8 바로 아래로. Q6(등급 표시 이름)은 (a) 유지 — `ui_ko.json` 으로 옮기려면 UI 코드가 `ui.show.grade.<id>` 를 읽어야 해 후속 티켓으로 미룬다 |
| 2026-10-09 | show.md v0, `show.json` v1 + `show.schema.json` version 1 | SE-030 | 신규. 만족도 진실의 출처 SR1~SR3(관객 평균 → 등급, PRD 항 대응표), 입력 계약 7개 이벤트·라인업 LN1~LN3, 상태 8필드, 공연 시작 ST0~ST3(`no_lineup`·`no_stage`), 공연 끝 DS1~DS5·SE1~SE4·CL1, 이벤트 3종(`show.started`·`show.skipped`·`show.ended`), 결정성(난수 없음), 스냅샷 SS1~SS4, 로드 검사 SL1~SL4, 마감 리포트 필드 R1~R13(SE-039 인계), 등급 임계 5단계, 기준 시나리오 5개, 수용 기준 SH1~SH13·ST1~ST4. 티켓 초안에서 바꾼 것: 구독에 `audience.admissions_decided`(`expected_admissions`)·`economy.ticket_price_changed`(`revenue_hint`)·`time.day_started`(리셋) 추가, `show.skipped` 페이로드 `{day, reason}` 확정(티켓은 이름만), 무대 없는 날도 `show.skipped`(Q3) |
