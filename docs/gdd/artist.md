# 아티스트 (artist.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-031 (1차 game-designer: 이 문서·스키마·규칙 수치 / 2차 content-writer: 12명 데이터·바이오) |
| 구현 티켓 | SE-033 (sim-engineer) — `project/sim/artist_config.gd`, `project/sim/artist_system.gd`, 짝 테스트 `project/tests/sim/test_artist_config.gd`, `project/tests/sim/test_artist_system.gd`. 섭외 UI 는 SE-039 |
| 데이터 | [`project/data/artist/artist.json`](../../project/data/artist/artist.json) (version 1, 규칙 수치), 스키마 [`artist.schema.json`](../../project/data/schemas/artist.schema.json) · [`project/data/artists/artists.json`](../../project/data/artists/artists.json) (version 1, 명단 — 1차는 구조 예시 2행, 2차가 12행으로 교체), 스키마 [`artists.schema.json`](../../project/data/schemas/artists.schema.json) · `project/data/text/artists_ko.json`(2차), 스키마 [`text.schema.json`](../../project/data/schemas/text.schema.json). 읽기 참조: [`economy.json`](../../project/data/economy/economy.json) `guarantee_by_grade`, [`genres.json`](../../project/data/genres/genres.json) `rows[].id`, [`sim.json`](../../project/data/sim/sim.json) `phases`·`system_order`·`rng_streams` |
| 이벤트 | [events.md](events.md)의 `artist.*` 5행. 이 문서에 나오는 이벤트 이름은 전부 거기 표에 있다(`show.ended`·`reputation.changed`는 SE-030, `build.coverage_changed`는 SE-028 이 등록) |
| 근거 | PRD "핵심 시스템 상세"(아티스트 행: 장르·인기·실력·성격·라이더·관계도, 공연마다 성장, 개런티 요구·관객 흡인력), "아티스트 성장 경로"(로컬 → 신인 → 중견 → 헤드라이너 → 레전드, 발굴 보너스), "콘텐츠 범위"(MVP 아티스트 12·텍스트만, 장르 3), "비목표"·"리스크"(실존 아티스트 연상 금지), [economy.md](economy.md) #비용-개런티·#입력-계약, [tick.md](tick.md) "시스템 등록"·#결정성과-rng |

## 목적

플레이어가 낮 구간에 오늘 공연할 아티스트 1명을 섭외하고(개런티 선지급), 공연이 끝나면 그 아티스트가 자라는 루프를 규칙 하나로 고정한다.
artist 는 명단의 **동적 상태**(등급·인기·실력·공연 수·발굴 여부·관계도)와 오늘 라인업만 소유한다. 현금은 economy 가 바꾸고, artist 는 `economy.charge_proposed`로 **제안**만 한다. 관객 수·만족도·명성은 audience/show/reputation 이 정하고 artist 는 그 입력(라인업과 아티스트 수치)을 낸다.
이 문서와 데이터 두 파일만 보고 sim-engineer 가 SE-033 을, content-writer 가 12명 명단(2차)을, render-engineer 가 섭외 패널(SE-039)을 질문 없이 시작할 수 있어야 한다.

v0 범위: 등급 2단계(`local`·`rookie`), 등급별 고정 개런티(economy 표 그대로), 섭외 규칙과 거절 5종, 하루 1명 라인업, 공연 뒤 성장(인기·실력 정수 증가)과 승급 1회(`local → rookie`), 명성에 따른 등급 가용, 스냅샷.
범위 밖(필드만 예약): 관계도 변화·관계 이벤트, 라이더, 타 베뉴 유출, 발굴 보너스의 개런티 할인(v0 는 등급 잠금 면제만, K4), 동적 개런티(`guarantee_mode`), 휴식·연속 공연 피로, 섭외 취소, `midlevel` 이상 등급, 초상(버티컬 슬라이스).

PRD 결정(성장 경로 5등급 이름과 순서, 8장르, MVP 장르 3, MVP 아티스트 12·텍스트만, 실존 아티스트 연상 금지)은 바꾸지 않는다.

## 규칙

### 용어와 등급

| 등급 id | 표시 | PRD 경로 | v0 |
|---|---|---|---|
| `local` | 로컬 | 1단계 | 섭외 가능(명성 0), 승급 → `rookie` |
| `rookie` | 신인 | 2단계 | 명성 임계 이상이면 섭외 가능, v0 승급 없음 |
| `midlevel` | 중견 | 3단계 | 이름만 예약(스키마 enum). 명단·`grades`에 쓰면 로드 실패(L4) |
| `headliner` | 헤드라이너 | 4단계 | 〃 |
| `legend` | 레전드 | 5단계 | 〃 |

- **인기 `popularity`**(0~100, 정수): 관객 흡인력의 입력. 입장 수 공식은 audience.md(SE-029)가 정한다.
- **실력 `skill`**(0~100, 정수): 라인업 궁합의 입력. 만족도 공식은 show.md(SE-030)가 정한다.
- **성격 `personality`**: 태그 2개(어휘는 `artist.json` `personality_tags`). v0 규칙 효과 없음. 바이오 문장과 버티컬 슬라이스 관계 이벤트의 입력.
- **라이더 `rider`**: 예약. v0 는 빈 배열만.
- **발굴 `discovered_here`**: 이 베뉴에서 한 번이라도 섭외가 확정된 아티스트. v0 효과는 K4 등급 잠금 면제 하나.
- **관계도 `relationship`**: 예약(`relationship_min`~`relationship_max`, 새 게임 0). v0 에서 바뀌지 않는다.

### MVP 장르

`artist.json` `mvp_genres` = **`rock`, `indie`, `electronic`**(결정 로그, Q1). 이 배열이 MVP 장르의 **단일 출처**다.
- 명단의 모든 아티스트 장르는 이 안에 있다(L3). 나머지 5장르(`hiphop`, `jazz`, `pop`, `metal`, `world`)는 `genres.json`에 그대로 남고 MVP 아티스트가 쓰지 않는다.
- audience.json(SE-029)·show.json(SE-030)·`genres.json` `affinity`(SE-030)는 MVP 장르를 이 배열에서 읽거나, 같은 값을 쓴다면 로더가 이 배열과 같은지 교차 검사한다(복제한 값이 갈라지지 않게).

### 상태

ArtistSystem 이 소유하는 상태. `pending`만 빼고 전부 스냅샷 대상이다(#스냅샷).

| 필드 | 타입 | 새 게임 값 | 설명 |
|---|---|---|---|
| `roster` | Array | `artists.json` 행 순서대로 1원소씩 | 원소 `{id: String, grade: String, popularity: int, skill: int, shows_played: int, discovered_here: bool, relationship: int}`. `grade`·`popularity`·`skill`은 데이터 행 값, `shows_played` 0, `discovered_here` false, `relationship` 0. 정적 필드(이름·장르·성격·바이오 키)는 데이터에서 읽고 상태에 넣지 않는다. 순서는 항상 데이터 행 순서 |
| `lineup_today` | String 또는 `null` | `null` | 오늘 섭외가 확정된 아티스트 id. 하루 1명 |
| `booked_day` | int | 0 | `lineup_today`를 섭외한 날. `lineup_today == null`이면 0 |
| `last_grown_day` | int | 0 | 마지막으로 성장을 적용한 날(G4 하루 1회 보장) |
| `reputation_total` | int | 0 | 마지막 `reputation.changed.total`(K4). reputation 시스템이 없으면(SE-035 전) 0 이라 `local`만 가용 |
| `day` | int | 1 | `time.phase_changed.day`·`time.day_started.day`를 따라온 현재 날 |
| `phase` | String | `"day"` | `time.phase_changed.to`를 따라온 현재 구간(K2) |
| `pending` | Dictionary 또는 `null` | `null` | 개런티 승인 대기 중인 섭외 1건(H1~H5). 같은 경계 안에서 비워지므로 경계 상태에서는 항상 `null`. 스냅샷에 넣지 않는다 |

티켓 초안의 `booked_days`는 `booked_day`(오늘 라인업의 섭외일, 단일 값)로 확정했다(Q7). 섭외 이력 배열은 v0 규칙이 읽지 않고 세이브만 키운다. 아티스트별 누적은 `shows_played`로 충분하다.

### 섭외 규칙

`artist.book_requested {artist_id: String}` (명령, 경계 처리에서 적용). 위에서부터 **처음 맞는 행 하나**만 적용한다. K1~K4 는 상태를 바꾸지 않는다.

| # | 조건 | 결과(이벤트 · `reason`) |
|---|---|---|
| K1 | `artist_id` 키가 없거나 `String`이 아님, 또는 `roster`에 그 id 가 없음 | `artist.booking_rejected` · `unknown_artist` |
| K2 | `phase ∉ booking_phases`(v0: 낮만 — economy P2·build B2 와 같은 규칙) | `artist.booking_rejected` · `not_allowed` |
| K3 | `lineup_today != null`(같은 아티스트를 다시 요청한 경우 포함). v0 는 하루 1명 | `artist.booking_rejected` · `already_booked` |
| K4 | `reputation_total < grades[grade].unlock_reputation`이고 `discovered_here == false`. `grade`는 그 아티스트의 **현재** 등급 | `artist.booking_rejected` · `grade_locked` |
| K5 | 그 밖 | 개런티 지출 제안(#경제-핸드셰이크 H1). 결과는 H2~H5 |

- 거절 이벤트 키: `artist.booking_rejected {day: int, artist_id: <받은 값, 키가 없으면 null>, reason: String}`(events.md 와 같다). `reason`은 아래 5종 중 하나.
- 페이로드 형식 오류를 먼저 본다(K1). 그래서 낮이 아닐 때 모르는 id 를 보내면 `unknown_artist`다. 테스트는 `not_allowed`를 볼 때 명단에 있는 id 를 쓴다.
- K4 면제(발굴 아티스트)는 "내 무대에서 키운 아티스트가 승급하자마자 섭외할 수 없게 되는" 상황을 막는다. 예: `local` 아티스트를 열광 공연으로 5회 만에 `rookie`로 올렸는데 명성이 아직 150 미만인 경우. PRD 발굴 보너스("우선 섭외권")의 v0 최소판이다(Q3). 개런티 할인은 버티컬 슬라이스.
- 파산 여부는 artist 가 알지 못한다. 파산 뒤 섭외는 economy C1 이 거절하고 H3 이 `not_allowed`로 바꾼다.
- 섭외 취소 명령은 v0 에 없다(Q5). 확정된 섭외는 그날 라인업으로 남는다.

### 경제 핸드셰이크

economy.md #입력-계약 "같은 경계 안의 핸드셰이크"와 build.md #경제-핸드셰이크를 그대로 따른다. artist 는 `cash`를 읽지 않는다.

| # | 시점 | 동작 |
|---|---|---|
| H1 | K5 | `amount = guarantee(grade)`(v0 `guarantee_mode == "by_grade"`: `economy.json` `guarantee_by_grade[현재 grade]`, `EconomyConfig.guarantee()`와 같은 값). `pending = {request_id, artist_id, grade, amount}`, `request_id = "artist:book:" + str(day) + ":" + artist_id` → `economy.charge_proposed {request_id, reason: "guarantee", amount}` |
| H2 | `economy.charge_resolved` 수신, `reason == "guarantee"`이고 `request_id == pending.request_id`, `approved == true` | 상태 먼저: `lineup_today = artist_id`, `booked_day = day`, 그 아티스트 `discovered_here = true`, `pending = null` → `artist.booked {day, artist_id, grade, guarantee: amount}` |
| H3 | 같은 조건, `approved == false` | `pending = null` → `artist.booking_rejected`, `reason` = `decline_reason`이 `"insufficient_cash"`면 `insufficient_cash`, 그 밖(`"bankrupt"`, `"invalid"`)이면 `not_allowed`. `"invalid"`는 설정 오류(L4 를 통과했다면 생기지 않음)라 `push_error` 1회를 더한다 |
| H4 | `economy.charge_resolved`의 `reason != "guarantee"` 또는 `request_id`가 `pending`과 다름(`pending == null` 포함) | 무시(건설 등 다른 시스템의 지출) |
| H5 | `update(ctx)`(단계 2) 시작 시 `pending != null` | economy 가 응답하지 않은 계약 위반(economy 미등록 테스트 등). `push_warning` 1회, `pending = null` → `artist.booking_rejected` · `not_allowed`. 다음 `artist.book_requested`를 처리할 때 `pending != null`이어도 같은 정리를 먼저 한다 |

거절 사유는 티켓이 정한 **5종으로 고정**한다(`not_allowed`, `already_booked`, `grade_locked`, `insufficient_cash`, `unknown_artist`). build 의 `bankrupt`·`charge_invalid`·`charge_unresolved`에 해당하는 경우는 `not_allowed`로 합친다(Q4). 이유: 섭외 패널이 보여 줄 문장이 "지금은 섭외할 수 없음" 하나로 충분하고, 파산은 게임 오버 화면이 따로 알린다.

**이벤트 순서(economy 등록 시, 한 경계 안).**
- 섭외 성공: `economy.charge_proposed` → `economy.cash_changed {reason:"guarantee", delta: −amount}` → `economy.charge_resolved {approved:true}` → `artist.booked`. `ledger.guarantee += amount`(economy C4).
- 자금 부족: `economy.charge_proposed` → `economy.charge_resolved {approved:false, decline_reason:"insufficient_cash"}` → `artist.booking_rejected {reason:"insufficient_cash"}`. 현금·장부 불변.
- K1~K4 거절: `artist.booking_rejected` 하나. `economy.*` 이벤트 없음.
- `amount == 0`(데이터가 개런티 0 인 경우)이면 economy 가 `cash_changed`를 내지 않으므로 `charge_proposed → charge_resolved → artist.booked`.

### 라인업

| # | 입력 | 동작 |
|---|---|---|
| LU1 | `time.phase_changed {to: "evening"}` | `artist.lineup_set {day, artist_id, genre, grade, popularity, skill}` 발행. 섭외가 없으면 `artist_id`·`genre`·`grade`는 `null`, `popularity`·`skill`은 0. 값은 발행 시점 상태(장르는 데이터 행). TickLoop 경로에서 하루 정확히 1회 |
| LU2 | `time.day_started {day}` | `lineup_today = null`, `booked_day = 0`. 이벤트 없음 |

- 라인업 페이로드에 아티스트 수치를 싣는 이유: audience(입장 수)와 show(라인업 궁합)가 artist 상태를 직접 읽지 않게 하려는 것이다(CLAUDE.md 원칙 4). 티켓 초안 `{day, artist_id|null}`에 키 4개를 더했다(Q8).
- **전달 순서.** artist 는 `system_order`상 build 뒤, audience 앞에 구독한다. 저녁 진입 틱 단계 4 에서 `time.phase_changed`가 모든 구독자에게 먼저 전달되고, 그동안 발행된 이벤트가 FIFO 로 이어진다(tick.md E2): `time.phase_changed` → `build.coverage_changed {cause:"sync"}` → `artist.lineup_set` → (그 구독자의 연쇄) → `time.speed_changed` → `tick.advanced`. 그래서 audience 는 저녁 진입 계산(입장 수)을 `time.phase_changed`가 아니라 **`artist.lineup_set` 수신 시** 해야 라인업과 커버리지를 둘 다 본다(SE-029 에 넘길 계약).
- 라인업은 공연·마감 내내 유지되고 다음 날 `time.day_started`에서 비운다. 마감 리포트가 그날 아티스트를 표시할 수 있다.

### 성장

`show.ended {day, artist_id, grade, …}`(SE-030 이 정의)를 구독한다. 위에서부터 처음 맞는 행 하나.

| # | 조건 | 결과 |
|---|---|---|
| G1 | `day`가 `int`가 아니거나 `grade`가 `String`이 아님, 또는 `artist_id`가 `String`도 `null`도 아님 | `push_warning`, 무시 |
| G2 | `artist_id == null`(라인업 없는 날) | 무시. 이벤트 없음 |
| G3 | `artist_id != lineup_today` 또는 `day != booked_day` | `push_warning`, 무시(계약 위반) |
| G4 | `day == last_grown_day` | 무시(하루 1회, 중복 이벤트·복원 방어) |
| G5 | `grade ∉ show_grades` | `push_error`, 무시 |
| G6 | 그 밖 | 아래 공식 적용 → `artist.grown` |

**공식(G6).** `r = grades[현재 grade]` (공연 전 등급의 규칙).

| 단계 | 값 | 공식 |
|---|---|---|
| GR1 | `popularity'` | `clamp(popularity + r.popularity_delta_by_show_grade[show_grade], 0, stat_max)` |
| GR2 | `skill'` | `clamp(skill + r.skill_per_show, 0, stat_max)` |
| GR3 | `shows_played'` | `shows_played + 1` |
| GR4 | `promoted` | `r.promote_to != null`이고 `popularity' ≥ r.promote_at_popularity` |
| GR5 | `grade'` | `promoted`면 `r.promote_to`, 아니면 그대로 |
| GR6 | 장부 | `last_grown_day = day` |

- 상태를 먼저 전부 갱신하고(tick.md E8) `artist.grown {day, artist_id, grade: grade', popularity: popularity', skill: skill', popularity_delta: popularity' − popularity, skill_delta: skill' − skill, shows_played: shows_played', promoted}`를 낸다. 델타는 자른 뒤의 실제 변화량이다.
- 승급은 한 공연에 최대 한 단계다. v0 에서 `rookie.promote_to == null`이라 게임 전체에서 아티스트당 최대 1회다.
- 강등은 없다. `rookie`가 참사 공연으로 인기 40 아래가 되어도 `rookie`로 남는다.
- 성장은 공연 등급(`show_grades`)만 본다. 관객 수·만족 bp 는 show 가 등급으로 접어 넣는다(만족도의 진실의 출처는 `audience.day_summary.avg_satisfaction_bp`, 등급 임계는 show.md — show.md SR1).
- 피로·휴식은 없다(v0 범위 밖). 같은 아티스트를 매일 섭외해도 된다.

### 명성과의 상호작용

| 방향 | 이벤트 | 규칙 |
|---|---|---|
| 명성 → 아티스트 | `reputation.changed {total, …}` (SE-030) | `total`이 `int ≥ 0`이면 `reputation_total = total`, 아니면 `push_warning` 후 무시. K4 등급 가용 판정에만 쓴다. v0 는 **종합 명성**만 본다(장르별 명성으로 여는 규칙은 버티컬 슬라이스) |
| 아티스트 → 공연·명성 | `artist.lineup_set` | show 가 라인업 궁합(장르·실력)을, audience 가 입장 수(인기·장르)를 계산한다. 명성 변화는 show 결과로 reputation 이 정한다. artist 는 명성을 직접 바꾸지 않는다 |
| 공연 → 아티스트 | `show.ended {grade}` | #성장 |

**등급 가용 명성 임계의 단일 출처는 `artist.json` `grades[].unlock_reputation`이다**(v0: `local` 0, `rookie` 150). reputation.md(SE-030)는 이 값을 복제하지 않고 참조한다(SE-030 이 참조할 것). SE-039 섭외 패널의 잠김 표시도 이 값과 `reputation.changed.total`을 쓴다(또는 `check_book`).

### 결정성과 RNG

- artist v0 는 **난수를 쓰지 않는다.** `artist` 스트림(tick.md: 단계 2, 섭외 명령 처리 단계 1)을 한 번도 뽑지 않는다. 섭외·라인업·성장 전후로 `rng.get_state()["artist"]`가 같다.
- 공식은 정수 덧셈·비교·`clamp`뿐이다. 순회는 `roster` 배열(데이터 행 순서) 하나뿐이고 Dictionary 순회에 기대는 결과가 없다.
- 같은 시드·같은 명령 열·같은 입력 이벤트 열이면 같은 artist 상태와 같은 `artist.*` 이벤트 열이 나온다.
- 후속에서 난수가 필요해지면(예: 공연 성장 변동, 유출 확률) 스트림은 `artist`만, 호출 지점은 `show.ended` 핸들러 또는 `update`만 쓰고, 한 번에 뽑는 횟수를 이 문서에 먼저 적는다.

### 스냅샷

`TickLoop.register_system("artist", artist.update, artist.snapshot, artist.restore)`로 **반드시** 등록한다(economy·build 와 같은 이유: 등록하지 않으면 성장과 라인업이 세이브에서 사라진다). `update(ctx)`는 H5 만 한다.

`ArtistSystem.snapshot() -> Dictionary` = `{roster: [{id, grade, popularity, skill, shows_played, discovered_here, relationship}, …], lineup_today: String|null, booked_day: int, last_grown_day: int, reputation_total: int, day: int, phase: String}`(깊은 복사본, 기본형만). `roster` 순서는 데이터 행 순서. `pending`은 넣지 않는다.

`ArtistSystem.restore(d) -> bool`. 정수 필드는 `int`로 정규화(JSON 왕복의 `float`, 정수값이 아니면 실패). 아래 검사를 **전부 끝낸 뒤** 적용한다(tick.md SH3). 첫 위반에서 `push_error` 1회, `false`, 상태 불변, 이벤트 0.

| # | 검사 |
|---|---|
| RA1 | 7개 키가 다 있고 타입이 맞음: `roster` Array, `lineup_today` String 또는 `null`, `booked_day`·`last_grown_day`·`reputation_total`·`day` 정수, `phase` String |
| RA2 | `day ≥ 1`, `phase ∈ sim.json phases[].id`, `reputation_total ≥ 0` |
| RA3 | `roster` 원소마다 7키·타입(`discovered_here`는 `bool`), `id`가 명단에 있음, 같은 id 두 번 없음, 명단의 모든 id 가 있음(개수 일치) |
| RA4 | 원소마다 `grade ∈ grades[].id`, `0 ≤ popularity ≤ stat_max`, `0 ≤ skill ≤ stat_max`, `shows_played ≥ 0`, `relationship_min ≤ relationship ≤ relationship_max` |
| RA5 | `lineup_today == null`이면 `booked_day == 0`. 아니면 `lineup_today`가 `roster`에 있고 `booked_day == day` |
| RA6 | `0 ≤ last_grown_day ≤ day` |

- 복원은 `roster`를 **데이터 행 순서로 다시 정렬**해 담는다(스냅샷 순서를 믿지 않는다). 그래서 SH6(왕복 해시 동치)이 성립한다.
- 하지 않는 의미 검사: 인기와 등급의 관계(`rookie`인데 인기 < 40 은 정상 — 강등 없음), `shows_played`와 `discovered_here`의 관계, `reputation_total`과 등급 가용.
- 데이터 명단이 바뀐 옛 세이브(id 추가·삭제)는 RA3 으로 실패한다. 세이브 마이그레이션은 프로덕션 범위(SE-036 이후).
- 복원 성공 뒤 `pending = null`. 복원 후 진행 = 연속 진행, SH1~SH7 준수. `sim.json.snapshot_schema_version`은 바꾸지 않는다(`systems.artist` 항목 추가만).

### 설정 로드 검사

`ArtistConfig.load()`가 스키마로 못 하는 교차 검사를 한다. 실패하면 `push_error`, `null`. CI 는 `jsonschema`를 설치해 스키마 제약(`maxItems`·`maxLength` 포함)을 전부 검사한다(ci.yml 400ce59, Q9). `jsonschema`가 없는 로컬 실행은 내장 부분집합이라 `maxItems`·`maxLength`를 보지 않으므로, 아래 L6·L7 이 런타임에서도 같은 제약을 막는다.

| # | 검사 |
|---|---|
| L1 | `artists.json`·`artist.json` 둘 다 `version == 1`, `stat_max == 100`, `relationship_min ≤ 0 ≤ relationship_max` |
| L2 | `mvp_genres`의 모든 값이 `genres.json` `rows[].id`에 있음 |
| L3 | 명단 행마다 `genre ∈ mvp_genres` |
| L4 | `grades[].id` 유일. 명단 행마다 `grade ∈ grades[].id`. `grades`의 모든 id 가 `economy.json` `guarantee_by_grade`의 키(= `EconomyConfig.guarantee(id) ≥ 0`, economy K4 와 같은 방향) |
| L5 | `grades[0].unlock_reputation == 0`(새 게임에 섭외할 수 있는 등급이 있음). `promote_to == null` ⇔ `promote_at_popularity == null`. `promote_to`가 있으면 `grades[].id` 중 하나이고 자기 자신이 아님 |
| L6 | 명단 행마다 `bio_key == "artist.bio." + id`, `rider`가 빈 배열(v0) |
| L7 | 명단 행마다 `personality`가 서로 다른 2개, 둘 다 `personality_tags`에 있음, `personality_exclusive_pairs`의 어느 쌍과도 같지 않음. `personality_exclusive_pairs`의 태그는 전부 `personality_tags`에 있음 |
| L8 | 명단 행의 등급에 승급 규칙이 있으면 `popularity < promote_at_popularity`(새 게임에 이미 승급 조건을 넘은 로컬이 없음) |

검사하지 않는 것(로더 밖): 명단 구성(12행, 3장르 × 4, 등급 8/4, `roster_plan` 일치)과 `bio_key` 문장 존재. 테스트 사본이 적은 행으로 로드될 수 있게 로더는 막지 않고, qa 스크립트(AR11)와 SE-033 AC6 테스트가 실제 데이터를 검사한다. `roster_plan`·`reference_scenarios`는 런타임이 읽지 않는다(테스트·qa 용).

### 공개 API (SE-033 구현 대상, 이름 제안)

| 클래스 | 멤버 | 설명 |
|---|---|---|
| `ArtistConfig` | `static load(artists_path := "res://data/artists/artists.json", rules_path := "res://data/artist/artist.json") -> ArtistConfig`, `static from_dicts(artists: Dictionary, rules: Dictionary, genres: Dictionary, economy: Dictionary) -> ArtistConfig` | L1~L8. `load`는 `genres.json`·`economy.json`을 기본 경로에서 읽는다(읽기 전용) |
| | `artist_ids() -> Array[String]`(데이터 행 순서), `has_artist(id) -> bool`, `artist(id) -> Dictionary`(행 깊은 복사, 없으면 `{}`), `grade_rule(grade) -> Dictionary`(없으면 `{}`), `guarantee(grade) -> int`(by_grade, 없으면 `push_error` 후 `-1` — economy 와 같은 규약), `unlock_reputation(grade) -> int`, `mvp_genres`, `booking_phases`, `show_grades`, `stat_max`, `relationship_min`, `relationship_max`, `scenario(id) -> Dictionary`(없으면 `{}`, 오류 없음) | 읽기 전용 |
| | `grow(entry: Dictionary, show_grade: String) -> Dictionary` | 순수 함수. GR1~GR5 를 적용한 새 원소(`roster` 원소 형식)에 `promoted: bool`, `popularity_delta`, `skill_delta`를 더해 돌려준다. 입력 불변. `reference_scenarios` 테스트가 쓴다 |
| `ArtistSystem` | `new(config: ArtistConfig, bus: EventBus)` | `artist.book_requested`, `economy.charge_resolved`, `time.phase_changed`, `time.day_started`, `show.ended`, `reputation.changed` 구독. 생성자는 이벤트를 내지 않는다 |
| | `update(ctx)`, `snapshot()`, `restore(d)` | H5, #스냅샷 |
| | `roster() -> Array`(깊은 복사), `entry(id) -> Dictionary`, `lineup_today`, `booked_day`, `last_grown_day`, `reputation_total`, `day`, `phase` | 읽기 전용 |
| | `check_book(artist_id: Variant) -> String` | K1~K4 판정만(자금 제외). 통과면 `""`, 아니면 `reason`. **상태 불변, 이벤트 없음.** 섭외 패널(SE-039)의 버튼 활성·잠김 표시용 |

### UI 계약 (SE-039)

| 동작 | 규칙 |
|---|---|
| 목록 | `ArtistConfig.artist_ids()` 순서로 전부(리터럴 12 금지). 행 = 이름, 장르(`genres.json` `name`), 등급, 인기, 실력, 개런티(`guarantee(현재 grade)`), 바이오(`artists_ko.json` `strings[bio_key]`), 성격 태그 2개(`strings["artist.tag." + tag]`) |
| 동적 값 | 새 게임·불러오기 직후 `ArtistSystem.roster()`를 읽고, 이후 `artist.grown`·`artist.booked`·`artist.lineup_set`으로 갱신한다(상태를 바꾸지 않는 읽기, economy.md 의 `cash` 읽기와 같은 규약) |
| 섭외 버튼 | `check_book(id) == ""`일 때만 활성. `grade_locked`면 "명성 N 필요"(N = `unlock_reputation(grade)`), `already_booked`면 "오늘 공연"/"섭외 완료", `not_allowed`면 비활성. 클릭 → `artist.book_requested {artist_id}` |
| 결과 | `artist.booked` → 행 상태 "오늘 공연". `artist.booking_rejected` → 알림 피드 1건(reason 문자열은 `ui_ko.json`, SE-039 2차) |

## 수치표

모든 값은 [`artist.json`](../../project/data/artist/artist.json) (version 1)과 [`economy.json`](../../project/data/economy/economy.json) `guarantee_by_grade`. 이 절의 숫자는 그 파일 값이거나 그 값으로 계산한 파생값이다.

### 등급 규칙 (`grades`)

| 등급 | 개런티 (economy) | 섭외 가용 명성 `unlock_reputation` | 공연당 실력 `skill_per_show` | 승급 | 근거 |
|---|---|---|---|---|---|
| `local` | 400 | 0 | +2 | 인기 ≥ 40 → `rookie` | 개런티는 economy 기준 시나리오 값. 무명은 무대마다 빨리 는다 |
| `rookie` | 800 | 150 | +1 | 없음(v0) | 150 = 티어 2 명성 500 의 30%. SE-030 기준 시나리오(25일에 500)에서 6~12일째 열리는 값 |

### 공연 등급별 인기 변화 (`popularity_delta_by_show_grade`)

| 공연 등급 id (show.md) | 표시 | `local` | `rookie` |
|---|---|---|---|
| `disaster` | 참사 | −1 | −2 |
| `poor` | 부진 | 0 | 0 |
| `ok` | 보통 | +1 | +1 |
| `good` | 호평 | +2 | +2 |
| `rave` | 열광 | +3 | +3 |

- 공연 등급 id 5개(`show_grades`, 나쁜 것 → 좋은 것)는 이 문서가 먼저 정했다. **show.md(SE-030)는 `show.ended.grade`에 이 id 를 그대로 쓴다**(Q10). SE-033 AC4 의 `"열광"`은 `"rave"`로 읽는다.
- 실패 공연의 인기 감소는 신인이 더 크다(기대치가 있어서). 하한 0, 강등 없음.

### 승급까지 공연 수 (손계산, `local` 8명)

`n = ⌈(40 − popularity) ÷ Δ⌉`, 매 공연 같은 등급일 때. 실력은 승급 시점 값 `skill + 2n`(상한 100).

| 슬롯 | 초기 인기 | 매번 보통(+1) | 매번 호평(+2) | 매번 열광(+3) |
|---|---|---|---|---|
| s07 | 27 | 13 | **7** | **5** |
| s03 | 24 | 16 | 8 | 6 |
| s10 | 21 | 19 | 10 | 7 |
| s06 | 18 | 22 | 11 | 8 |
| s02 | 15 | 25 | 13 | 9 |
| s09 | 12 | 28 | 14 | 10 |
| s05 | 9 | 31 | 16 | 11 |
| s01 | 6 | 34 | **17** | 12 |

판정: 가장 빠른 승급(열광만) 5회 ≥ 하한 5, 가장 느린 승급(호평만) 17회 ≤ 티어 2 목표 25일(economy.md 기준 시나리오). 한 명에게 집중하면 티어 2 전에 누구든 올릴 수 있고, 매일 바꿔 섭외하면 25일 안에 승급이 안 나올 수 있다(설계 의도: "내 무대에서 키운" 선택).
`reference_scenarios`의 `local_top_all_good`(7회 승급)·`local_bottom_all_good`(17회)·`local_top_all_rave`(5회)가 이 표의 세 굵은 값이다.

### `rookie` 섭외의 손익분기 (audience.md 에 넘길 목표)

개런티 차이 800 − 400 = 400 을 메우려면 같은 날·같은 배치에서 `rookie`가 `local`보다 관객을 더 모아야 한다. economy 공식(티어 1 행, 티켓 20)으로 입장 1명당 세전 기여 ≈ 20 + 7.2 × 0.65 = 24.68 → 400 ÷ 24.68 = 16.2.
정수 검산(`admissions = audience`): `local` 100명 `pretax` 1,268. `rookie` 116명 → 티켓 2,320, 바 구매 ⌊69.6⌋ = 69, 바 매출 828, 원가 ⌊289.8⌋ = 289, 비용 289 + 600 + 200 + 800 = 1,889, `pretax` 1,259(미달). 117명 → 2,340, 70, 840, 294, 비용 1,894, `pretax` **1,286**(초과).
**목표(SE-029):** 기준 배치에서 `rookie`(인기 42~55)의 기대 입장 수가 `local` 상위(인기 21~27)보다 **17명 이상** 많다(권장 +25~40 — 신인을 부를 이유가 생기되 첫날부터 무조건 신인이 정답이 되지 않게).

### MVP 명단 설계 (`roster_plan`, content-writer 인계)

12명 = MVP 3장르 × 4명, 등급 `local` 8 / `rookie` 4. 8 이 3 으로 나눠지지 않아 `electronic`이 `rookie` 2명이다(클럽 DJ 는 신인 단계에서 흡인력이 크다는 설정). 인기 12개·실력 12개는 서로 다 다르다(분포 표에서 각 아티스트가 숫자로 구별되게). `local` 인기 6~27(< 승급 40, L8), `rookie` 인기 42~55(≥ 40).

| 슬롯 | 장르 | 등급 | 인기 | 실력 | 개런티 v0 | 성격 태그 | 콘셉트 힌트(자유롭게 바꿔도 됨, 수치·태그는 고정) |
|---|---|---|---|---|---|---|---|
| s01 | rock | local | 6 | 34 | 400 | `diligent`, `shy` | 실력에 비해 안 알려진 3인조 개러지 록 |
| s02 | rock | local | 15 | 22 | 400 | `hothead`, `loyal` | 동네 술집 무대 출신 펑크 2인조 |
| s03 | rock | local | 24 | 40 | 400 | `perfectionist`, `moody` | 공연마다 곡 순서를 갈아엎는 블루스 록 솔로 |
| s04 | rock | rookie | 46 | 52 | 800 | `showman`, `ambitious` | 첫 EP 로 주목받기 시작한 4인조 |
| s05 | indie | local | 9 | 46 | 400 | `perfectionist`, `shy` | 방에서 녹음하는 포크 싱어송라이터, 무대 공포 |
| s06 | indie | local | 18 | 28 | 400 | `easygoing`, `loyal` | 대학가 카페 출신 어쿠스틱 듀오 |
| s07 | indie | local | 27 | 18 | 400 | `showman`, `free_spirit` | 영상으로 먼저 알려진 인디 팝, 라이브는 서툶 |
| s08 | indie | rookie | 42 | 60 | 800 | `moody`, `diligent` | 정규 1집을 낸 몽환적인 기타 팝 밴드 |
| s09 | electronic | local | 12 | 30 | 400 | `free_spirit`, `easygoing` | 버려진 신시사이저를 고쳐 쓰는 앰비언트 DJ |
| s10 | electronic | local | 21 | 38 | 400 | `ambitious`, `diligent` | 메인 시간대를 노리는 오프닝 DJ |
| s11 | electronic | rookie | 50 | 44 | 800 | `showman`, `hothead` | 화려한 무대 의상의 하우스 DJ 듀오 |
| s12 | electronic | rookie | 55 | 64 | 800 | `perfectionist`, `ambitious` | 직접 만든 모듈러 장비로 라이브 셋을 하는 프로듀서 |

태그 사용 횟수: `diligent`·`perfectionist`·`showman`·`ambitious` 3, 나머지 6개 2(합 24). 배타 쌍(`shy`–`showman`, `easygoing`–`hothead`, `loyal`–`ambitious`)을 가진 슬롯 없음.

### 이름과 바이오 규칙 (content-writer 2차)

| # | 규칙 |
|---|---|
| N1 | `artists.json` 12행은 `roster_plan.slots`와 (genre, grade, popularity, skill, personality) 묶음이 일대일로 같다. 행 순서는 슬롯 순서(s01 → s12) |
| N2 | `id`: 영문 소문자·숫자·밑줄(`^[a-z0-9_]+$`), 이름의 로마자 표기나 짧은 별칭. 실존 이름의 로마자가 아니어야 한다. 출시 뒤 바꾸지 않는다(세이브 키) |
| N3 | `name`: 한국어 무대 이름 1~16자(밴드명·DJ 명). 영문 단어를 한글로 적는 것은 허용. **금지:** 실존 아티스트·밴드·DJ·곡·앨범·레이블·공연장·페스티벌 이름과 같거나, 한두 글자만 바꾼 패러디, 실존 인물 실명 |
| N4 | `bio_key`: `"artist.bio." + id`. 문장은 `project/data/text/artists_ko.json` `strings`에 |
| N5 | 바이오: 한국어 **정확히 2문장, 120자 이하**(공백·문장부호 포함, 코드 포인트 수 = Python `len`). 두 성격 태그가 문장에서 읽혀야 한다. 실존 지명은 도시·동네 이름 없이 일반 명사로("지하철역 옆 연습실"). 실존 곡·앨범 인용 금지 |
| N6 | 성격 태그 라벨 10개도 같은 파일에: `artist.tag.<tag>` → 8자 이하 한국어(예: `shy` → "수줍음"). 키 10개 = `personality_tags` |
| N7 | `artists_ko.json` 형식: `{"version": 1, "locale": "ko", "strings": {키: 문장}}`(`text.schema.json`). 키 22개 = 바이오 12 + 태그 10 |
| N8 | 결과 절에 자기 검토 표 12행: `id | name | 유사 실존 이름 | 판정`. 판정은 "유사 실존 이름 없음" 또는 고친 내용. 검토 방법(어떤 목록·검색을 봤는지)을 한 줄 적는다 |

## 수용 기준

### 구현 (SE-033, `test_artist_config.gd`는 AR1, 나머지는 `test_artist_system.gd`)

기대 수치는 테스트에 하드코딩하지 않고 `artist.json`·`economy.json`에서 읽는다(`reference_scenarios`, `grades`, `guarantee_by_grade`). 이벤트 이름·`reason` 문자열은 리터럴로 단언한다.

| # | 케이스 | 검증 |
|---|---|---|
| AR1 | `test_config_loads_and_cross_checks` | 실제 데이터로 `ArtistConfig.load()` 성공. L1~L8 을 하나씩 깬 사본 8건 이상이 `null`(예: `genres` 사본에서 `indie` 행 제거(L2), 행 `genre: "jazz"`(L3), 행 `grade: "midlevel"`, `grades[0].unlock_reputation = 10`, `promote_to: "rookie"` + `promote_at_popularity: null`, `bio_key` 불일치, `rider: ["x"]`, `personality: ["shy","showman"]`, 로컬 인기 40). `guarantee("local") == economy guarantee_by_grade.local`, `guarantee("midlevel") == -1` |
| AR2 | `test_book_success_handshake` | 낮 구간 `artist.book_requested {artist_id: <local>}` → `advance(0)` → 이벤트 열 `economy.charge_proposed {reason:"guarantee", amount: guarantee_by_grade.local}` → `economy.cash_changed` → `economy.charge_resolved {approved:true}` → `artist.booked {day, artist_id, grade:"local", guarantee}`. `cash` 감소량 = 개런티, economy `ledger.guarantee` 증가, `lineup_today`·`booked_day`·`discovered_here` 갱신 |
| AR3 | `test_book_rejections`(5건 이상) | 각 거절이 `artist.booking_rejected {reason}` 정확히 1건, artist·economy 스냅샷 해시 불변(현금 불변): `unknown_artist`(없는 id, `artist_id` 누락, `artist_id: 5`), `not_allowed`(evening 에서 명단 id), `already_booked`(성공 뒤 같은 날 두 번째 — 같은 id·다른 id 둘 다), `grade_locked`(명성 0 에서 `rookie`), `insufficient_cash`(현금 < 개런티 — economy 거절 전달, `charge_proposed`·`charge_resolved {approved:false}` 뒤). K1~K4 거절에는 `economy.*` 이벤트 0 |
| AR4 | `test_grade_unlock_and_discovery_exemption` | `reputation.changed {total: unlock_reputation(rookie) − 1}` → `rookie` 섭외 `grade_locked`. `total: unlock_reputation(rookie)` → 성공. 별도 실행: `local`을 `reference_scenarios[local_top_all_rave]`만큼 성장시켜 `rookie`로 승급시킨 뒤 명성 0 에서 섭외 → 성공(K4 면제), 개런티 = `guarantee_by_grade.rookie`. `check_book`이 각 경우 같은 `reason`을 돌려주고 상태·이벤트 불변 |
| AR5 | `test_lineup_set_once_per_day` | `TickLoop`으로 하루 진행: 섭외한 날 저녁 진입 틱에 `artist.lineup_set {day, artist_id, genre, grade, popularity, skill}`(값 = 상태·데이터) 정확히 1회, `time.phase_changed {to:"evening"}` 뒤·`time.speed_changed`·`tick.advanced` 앞. 섭외 없는 날은 `artist_id: null, genre: null, grade: null, popularity: 0, skill: 0`. `time.next_day_requested` 뒤 `lineup_today == null`, `booked_day == 0` |
| AR6 | `test_growth_reference_scenarios` | `reference_scenarios` 각각: `grow()`를 `show_grades` 순서로 반복한 결과가 `expected`(grade, popularity, skill, shows_played, promoted_on_show)와 같음. 같은 시나리오 하나 이상을 버스로(섭외 → 저녁 → `show.ended {day, artist_id, grade}` 발행) 돌려 `artist.grown` 페이로드(델타 포함)가 같음, `promoted: true`는 승급한 공연에서만 1회 |
| AR7 | `test_growth_guards` | G1~G5: 잘못된 페이로드 경고·무시, `artist_id: null` 무시(이벤트 0), 라인업과 다른 id·다른 날 경고·무시, 같은 날 `show.ended` 두 번째 무시, `grade: "열광"`(id 아님) `push_error`·무시. 각 경우 스냅샷 해시 불변 |
| AR8 | `test_pending_cleanup` | economy 미등록 버스에서 섭외 → `charge_proposed`만 나고 응답 없음 → 다음 틱 `update`에서 `push_warning` 1회 + `artist.booking_rejected {reason:"not_allowed"}`, `pending == null`, `lineup_today == null`(H5). economy 가 `decline_reason:"bankrupt"`로 거절하면 `not_allowed`(H3) |
| AR9 | `test_determinism_no_rng` | 같은 시드·같은 명령/입력 열 두 번 → `artist.*` 이벤트 열·`snapshot()` 해시 같음. 섭외·라인업·성장 전후 `rng.get_state()["artist"]` 불변 |
| AR10 | `test_snapshot_roundtrip` | (a) 섭외·성장 1회 뒤(낮, `lineup_today` 있음) `snapshot()` → JSON 왕복 → 새 시스템 `restore()` `true` → 같은 입력 열 → 연속 진행과 해시 같음. (b) `TickLoop` 수준: `systems.artist == snapshot()`, 왕복 후 `advance(3300)` 동치. (c) 거부 사본(정상 스냅샷 `duplicate(true)` 후 한 필드만): 모르는 id, 명단 id 하나 누락, 같은 id 두 번, `popularity: 101`, `skill: -1`, `grade: "boss"`, `lineup_today: "nobody"`, `lineup_today` 있는데 `booked_day: 0`, `last_grown_day > day`, `discovered_here: 1` — 각각 `false`, `push_error` 1회, 해시 불변, 이벤트 0. `roster` 순서를 뒤섞은 사본은 `true`이고 복원 뒤 `snapshot()`이 원래와 같음 |

### 데이터·문서 (SE-031, qa·reviewer)

| # | 검증 | 방법 |
|---|---|---|
| AR11 | `artists.json` 12행, 장르 `mvp_genres` 3개 × 4, 등급 `local` 8 / `rookie` 4, id 유일, (genre, grade, popularity, skill, 정렬한 personality) 묶음이 `roster_plan.slots`와 일대일 일치, 모든 `bio_key`와 `artist.tag.*` 10개가 `artists_ko.json` `strings`에 있음, 바이오 12개 ≤ 120자 | 테스트 방법의 qa 스크립트 exit 0 |
| AR12 | `validate_data.py --strict` exit 0 | CI |
| AR13 | 이 문서의 이벤트 이름 5개가 events.md 표에 있고 페이로드가 같다. `guarantee_by_grade`를 이 티켓이 바꾸지 않았다(`git diff project/data/economy` 0) | reviewer |
| AR14 | `rookie` 해금 명성 임계가 `artist.json` `grades[rookie].unlock_reputation` 한 곳에만 있다. reputation.md(SE-030)는 값을 복제하지 않고 이 필드를 참조한다 | reviewer(SE-030 리뷰 때 다시 확인) |

### 수치 목표 (데이터가 바뀌어도 지켜야 할 범위)

| # | 목표 | 현재 값 |
|---|---|---|
| T1 | 가장 빠른 `local → rookie` 승급(열광만) ≥ 5 공연 | 5 (s07) |
| T2 | 가장 느린 승급(호평만) ≤ 25 공연(티어 2 목표일) | 17 (s01) |
| T3 | `rookie` 해금 명성은 티어 2 명성(`tiers.json` 500)의 20~40% | 150 = 30% |
| T4 | `rookie` 최저 인기 ≥ 승급 임계, `local` 최고 인기 < 승급 임계 | 42 ≥ 40 > 27 |
| T5 | (SE-029 가 지킬 것) 기준 배치에서 `rookie` 기대 입장 − `local` 상위 기대 입장 ≥ 17 | audience.md 에서 확인 |
| T6 | (SE-030 이 지킬 것) reputation 기준 시나리오에서 `total ≥ 150` 도달일이 6~12일 | reputation.md 에서 확인 |

## 테스트 방법

- 데이터(이 티켓): `python3 tools/validate_data.py --strict` — `artist.json`·`artists.json`(·2차 `artists_ko.json`)이 스키마를 통과. CI 는 `jsonschema`를 설치해 `maxItems`(성격 2개·라이더 0개)와 `maxLength`(바이오 120자)까지 검사한다(ci.yml 400ce59). 명단 구성(12행·장르·등급·슬롯 일치)은 스키마 밖이라 아래 qa 스크립트가 검사한다.
- 명단 검사(qa, 2차 뒤 AR11): 리포 루트에서

```bash
python3 - <<'PY'
import json, sys
from collections import Counter
D = "project/data/"
rules = json.load(open(D + "artist/artist.json", encoding="utf-8"))
rows = json.load(open(D + "artists/artists.json", encoding="utf-8"))["rows"]
import os
plan = rules["roster_plan"]; err = []
T = D + "text/artists_ko.json"
text = json.load(open(T, encoding="utf-8"))["strings"] if os.path.exists(T) else {}
if not text: err.append("artists_ko.json 없음 또는 비어 있음")
key = lambda r: (r["genre"], r["grade"], r["popularity"], r["skill"], tuple(sorted(r["personality"])))
if len(rows) != plan["total"]: err.append(f"행 {len(rows)} != {plan['total']}")
g = Counter(r["genre"] for r in rows)
if set(g) != set(rules["mvp_genres"]) or any(v != plan["per_genre"] for v in g.values()): err.append(f"장르 {dict(g)}")
if dict(Counter(r["grade"] for r in rows)) != plan["grade_counts"]: err.append("등급 수 불일치")
if len({r["id"] for r in rows}) != len(rows): err.append("id 중복")
if sorted(map(key, rows)) != sorted(map(key, plan["slots"])): err.append("roster_plan 슬롯과 수치 불일치")
for r in rows:
    b = text.get(r["bio_key"])
    if b is None: err.append(f"바이오 없음 {r['bio_key']}")
    elif len(b) > 120: err.append(f"바이오 {len(b)}자 {r['id']}")
    if len(r["personality"]) != 2 or r["rider"]: err.append(f"태그·라이더 {r['id']}")
for t in rules["personality_tags"]:
    if "artist.tag." + t not in text: err.append(f"태그 라벨 없음 {t}")
print("\n".join(err) or "AR11 OK"); sys.exit(1 if err else 0)
PY
```
- 헤드리스(SE-033): `tools/run_tests.sh project/tests/sim` → `test_artist_config.gd`(AR1), `test_artist_system.gd`(AR2~AR10). 단위 케이스는 `EventBus` + `Economy`(실제 economy 설정)에 `time.*`·`show.ended`·`reputation.changed`를 테스트가 직접 발행하고, AR5·AR9·AR10(b)는 `TickLoop`으로 구동한다(artist·economy 를 훅과 함께 등록). `show.ended`의 발행 주체(SE-035)가 없어도 테스트가 발행한다. Godot 이 없으면 SKIP → CI(`godot-tests`).
- 변이(qa, SE-033): "K2 구간 검사 제거" 패치 → AR3 의 `not_allowed` 케이스만 실패. "K4 발굴 면제 제거" → AR4 의 면제 케이스만 실패.
- 스펙 대조(reviewer): AR13·AR14, 이 문서의 이벤트 이름·페이로드와 events.md, 수치표와 `artist.json`.

## 열린 질문

> **결정(2026-10-09, 사람 검수 최소화 원칙):** 아래 질문 전부 추천안을 채택해 데이터와 규칙에 넣었다. ADR 이 필요한 변경은 없다. 바꾸려면 새 질문으로 다시 올린다. producer 가 `docs/status/` 결정 로그로 옮긴다.

| # | 질문 | 선택지 | 채택(추천) | 바꾸면 |
|---|---|---|---|---|
| Q1 | MVP 장르 3 | (a) rock/indie/electronic (b) rock/hiphop/pop (c) indie/electronic/jazz | **(a).** 지하 클럽에서 자연스러운 세 장르이고, 밴드 둘(록·인디)과 DJ 하나라 관객 취향·무대 연출이 확실히 갈린다. `genres.json` 강조색(빨강·연두·청록)도 서로 멀다 | `mvp_genres`·`roster_plan` 장르·명단 재작성, SE-029·030 데이터 동반 수정 |
| Q2 | `rookie` 해금 명성 | (a) 0(처음부터) (b) 150 (c) 300 | **(b).** 첫 주는 로컬로 버티고 둘째 주에 신인을 고를 수 있다(T6). (a)는 첫날 신인이 정답이 되고, (c)는 티어 2 직전이라 신인 단계가 짧다 | 데이터만(`grades[rookie].unlock_reputation`) |
| Q3 | 승급한 발굴 아티스트의 등급 잠금 | (a) 면제(발굴 보너스 최소판) (b) 잠금 유지 | **(a).** 키운 아티스트를 승급 직후 못 부르면 성장이 벌이 된다. 개런티 할인 등 나머지 발굴 보너스는 버티컬 슬라이스 | (b)는 K4 조건에서 `discovered_here` 제거 + AR4 수정 |
| Q4 | economy 거절 `bankrupt`·`invalid`와 응답 없음의 `reason` | (a) `not_allowed`로 합침(5종 유지) (b) build 처럼 사유 추가 | **(a).** 티켓이 거절 5종을 계약으로 고정했고, 패널 문장이 하나로 충분하다 | (b)는 events.md 페이로드 enum 추가 |
| Q5 | 섭외 취소 | (a) v0 없음 (b) 낮 구간 취소 + 개런티 환불 X% | **(a)**(티켓 결정 로그). 환불 규칙은 노쇼·취소와 함께 events_crisis.md | (b)는 명령 1개·economy 환불 사유 추가(economy 스키마 version 2) |
| Q6 | 참사 공연의 인기 감소 | (a) 0 (b) −1/−2(로컬/신인) | **(b).** 나쁜 공연에도 비용이 있어야 배치·라인업을 신경 쓴다. 강등은 없다 | 데이터만 |
| Q7 | 티켓 초안 `booked_days` | (a) `booked_day` 단일 값 (b) 섭외 이력 배열 | **(a).** v0 규칙이 이력을 읽지 않는다 | (b)는 스냅샷 형식 변경 |
| Q8 | `artist.lineup_set` 페이로드 | (a) `{day, artist_id}` (b) 장르·등급·인기·실력 포함 | **(b).** 받는 시스템이 artist 상태를 읽지 않게 한다 | — |
| Q9 | CI 검증기가 `maxItems`·`maxLength`·`minProperties`·`propertyNames`를 무시(`jsonschema` 미설치 시 내장 부분집합) | (a) 로더 L6·L7 + qa 스크립트로 보완 (b) `tools/validate_data.py` 부분집합에 키워드 추가 (c) CI 에 `jsonschema` 설치 | **(a) + (c).** CI data job 이 `jsonschema`를 설치해 전체 제약을 검사한다(ci.yml 400ce59). 로더 L6·L7 은 `jsonschema` 없는 로컬 실행·런타임 방어로 유지 | — |
| Q10 | 공연 등급 id | `disaster`/`poor`/`ok`/`good`/`rave` | 이 문서가 먼저 정했다. show.md(SE-030)가 같은 id 를 쓴다. 이름을 바꾸려면 SE-030 이 `artist.json` `show_grades`·`popularity_delta_by_show_grade` 키와 함께 바꾼다(스키마 version 2) | — |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-09 | artist.md v0 | SE-031 1차 | 신규 작성 |
| 2026-10-09 | `artist.json` v1·`artist.schema.json` version 1, `artists.schema.json` version 1, `text.schema.json` version 1, `artists.json` v1(구조 예시 2행) | SE-031 1차 | 신규 테이블. `artist.json`: `mvp_genres`, `booking_phases`, `guarantee_mode`, `stat_max`, 관계도 범위, `show_grades`, `grades`(local·rookie), 성격 태그 어휘·배타 쌍, `roster_plan`(12 슬롯), `reference_scenarios`(성장 7건). `artists.json` 행: `rows` 빈 배열 불허(minItems 1), `rider` 빈 배열만(maxItems 0), `personality` 정확히 2개. `text.schema.json`은 `project/data/text/*.json` 공용(SE-039 `ui_ko.json` 재사용). 티켓 초안에서 바꾼 것: `booked_days` → `booked_day`(Q7), `artist.lineup_set`·`artist.booked`·`artist.grown` 페이로드 키 추가(Q8), economy 거절의 `reason` 매핑(Q4). 기존 테이블(`economy.json`·`genres.json` 등) 변경 없음 |
| 2026-10-09 | artist.md v0 (후속 수정), 스키마 `version` 불변(description 만) | SE-030 (docs/reviews/SE-031.md 낮음 항목 이관) | 참조 번호 정리: `artist.schema.json`의 옛 번호 L9·G5 를 L5·GR4 로, 명단 검사 참조를 AR11 로(`artist.schema.json` 1곳, `artists.schema.json` 2곳, 이 문서 #설정-로드-검사 1곳 — 스냅샷 테스트 AR10 은 그대로). CI 가 `jsonschema`를 설치한다(ci.yml 400ce59)는 사실로 #설정-로드-검사·#테스트-방법·Q9 문구 갱신. 명단 검사 스크립트 뒤의 1차 상태 안내 문장 삭제(2차 완료), 피로·휴식 행의 범위 표기를 "v0 범위 밖"으로. #섭외-규칙에 `artist.booking_rejected {day, artist_id\|null, reason}` 키 목록 한 줄(events.md 와 같음). `relationship_min` 설명을 데이터 −100 에 맞춤. #성장의 만족도 진실의 출처를 `audience.day_summary.avg_satisfaction_bp`로(show.md SR1 — audience.md Q7 과 일치). 규칙·수치·이벤트 변경 없음 |
