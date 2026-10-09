# 이벤트 버스 계약 (events.md)

`core/event_bus.gd`를 지나는 모든 이벤트의 단일 출처. sim 은 **상태 이벤트**를 발행하고, view/ui 는 **명령 이벤트**를 발행한다. 이름은 `<domain>.<past_tense>`(상태) / `<domain>.<verb>_requested`(명령).

규칙:
- 페이로드는 Dictionary, 키는 스네이크 케이스, 값은 기본형·배열·Dictionary 만(객체 참조 금지 — 세이브·리플레이 때문). 허용 타입 목록과 위반 시 동작은 [tick.md#이벤트-순서](tick.md#이벤트-순서) E4.
- 명령 페이로드 숫자는 `int`만(tick.md E4). `float`는 정수값(`2.0`)이어도 `publish()`가 `push_error` + `false`로 거부하고 큐에 넣지 않는다(핸들러 도달 없음, 거부 이벤트도 없음). 상태 이벤트는 `float` 허용.
- 전달 순서: 구독 순서대로, 핸들러 안에서 발행한 이벤트는 FIFO 큐잉(재진입 없음). [tick.md#이벤트-순서](tick.md#이벤트-순서) E1~E3, E6~E8.
- 이름이 `_requested`로 끝나는 **명령 이벤트는 즉시 전달되지 않고** 버스의 명령 큐에 쌓였다가 다음 틱 경계(`TickLoop`의 경계 처리)에서 전달된다. 일시정지 중에도 쌓이고 적용된다. [tick.md#명령-큐와-틱-순서](tick.md#명령-큐와-틱-순서).
- `tick.advanced`는 매 틱의 마지막 이벤트다. 그 구독자는 상태 이벤트를 발행하지 않는다(명령만).
- 접두어 `test.`는 테스트 전용이며 이 표에 등록하지 않는다. 그 밖의 이름은 전부 이 표에 있어야 한다.
- 이벤트를 추가·변경하는 에이전트는 이 표를 같은 PR에서 갱신한다. 표에 없는 이벤트는 reviewer가 반려한다.

## 상태 이벤트 (sim → 구독자)

| 이름 | 페이로드 | 발행 시점 | 티켓 |
|---|---|---|---|
| `tick.advanced` | `{tick: int, phase: "day"\|"evening"\|"show"\|"close"}` — `tick`은 방금 끝난 틱 번호(1부터, 전역 누적), `phase`는 그 틱 처리 **후**의 구간 | 매 틱 마지막(단계 5). close 에서는 틱이 없어 발행 안 됨 | SE-006 |
| `time.phase_changed` | `{from: String, to: String, day: int, tick: int}` — `day`·`tick`은 전환 직후 경계 값 | 구간 경계에 도달한 틱의 단계 4(day→evening→show→close), 또는 close 에서 다음 날 명령 처리 시(close→day) | SE-006 |
| `time.day_started` | `{day: int}` — 새 날 번호(2부터) | close 에서 `time.next_day_requested` 처리 시, `time.phase_changed {close→day}` 직전. 새 게임 1일차는 발행 안 함 | SE-006 |
| `time.speed_changed` | `{speed: int, from: int, cause: "requested"\|"phase_enter"}` | 배속 요청이 받아들여져 값이 바뀌었을 때(경계), 또는 구간 진입 클램프로 바뀌었을 때(`time.phase_changed` 바로 뒤). 값이 같으면 발행 안 함 | SE-006 |
| `time.speed_rejected` | `{speed: <요청 값, 없으면 null>, reason: "invalid"\|"not_allowed", phase: String}` | 배속 요청 거부(경계). `invalid` = 키 없음 또는 `int`가 아님(`float`는 버스가 먼저 거부해 여기 오지 않는다, tick.md E4), `not_allowed` = 현재 구간 `speeds`에 없음. 상태 불변 | SE-006 |
| `artist.booked` | `{day: int, artist_id: String, grade: "local"\|"rookie", guarantee: int}` — `grade`는 섭외 시점 등급, `guarantee` = 승인된 개런티(`economy.json` `guarantee_by_grade[grade]`) | 섭외 승인 시: `economy.charge_resolved {reason:"guarantee", approved:true}`(같은 `request_id`) 처리 중, 라인업 확정 직후(경계). [artist.md#경제-핸드셰이크](artist.md#경제-핸드셰이크) H2 | SE-031 |
| `artist.booking_rejected` | `{day: int, artist_id: <받은 값, 키가 없으면 null>, reason: "not_allowed"\|"already_booked"\|"grade_locked"\|"insufficient_cash"\|"unknown_artist"}` | 섭외 명령 거절(K1~K4, 경계), 지출 거절(H3 — economy `insufficient_cash` → `insufficient_cash`, `bankrupt`·`invalid` → `not_allowed`), 응답 없는 지출 정리(H5, 단계 2 → `not_allowed`). artist 상태 불변 | SE-031 |
| `artist.lineup_set` | `{day: int, artist_id: String\|null, genre: String\|null, grade: String\|null, popularity: int, skill: int}` — 섭외가 없으면 `artist_id`·`genre`·`grade`는 `null`, `popularity`·`skill`은 0 | `time.phase_changed {to:"evening"}` 수신 시 하루 1회(저녁 진입 틱 단계 4, 모든 `time.phase_changed` 구독자 뒤 FIFO). audience(입장 수)·show(라인업 궁합)의 입력 — audience 는 저녁 진입 계산을 이 이벤트 수신 시 한다. [artist.md#라인업](artist.md#라인업) | SE-031 |
| `artist.grown` | `{day: int, artist_id: String, grade: String, popularity: int, skill: int, popularity_delta: int, skill_delta: int, shows_played: int, promoted: bool}` — 값은 성장 뒤, 델타는 0~100 으로 자른 뒤의 실제 변화량, `promoted`는 이 공연으로 승급했으면 `true` | `show.ended`(라인업 아티스트, 그날 1회) 처리 중. 공식 [artist.md#성장](artist.md#성장) GR1~GR6 | SE-031 |
| `economy.cash_changed` | `{cash: int, delta: int, reason: "build"\|"guarantee"\|"demolish_refund"\|"settlement"\|"bailout"}` — `cash`는 변동 후 값, `delta ≠ 0` | economy 가 현금을 바꾼 직후(상태 먼저, E8): 지출 승인(`economy.charge_resolved` 직전), 환불, 정산(`economy.day_settled` 직전), 구제 수락(`economy.bailout_taken` 직전). `delta == 0`이면 발행 안 함 | SE-005 |
| `economy.charge_proposed` | `{request_id: String, reason: "build"\|"guarantee", amount: int}` | **economy 입력.** 즉시 지출이 필요한 시스템(build 설치, artist 섭외)이 명령 처리 중 발행. v0 는 테스트가 발행. [economy.md#입력-계약](economy.md#입력-계약) | SE-005 |
| `economy.charge_resolved` | `{request_id: String, reason: String, amount: int, approved: bool, decline_reason: ""\|"bankrupt"\|"invalid"\|"insufficient_cash", cash: int}` | `economy.charge_proposed`마다 정확히 1회(승인이고 금액이 0 이 아니면 `economy.cash_changed` 뒤). 제안한 시스템이 받아 확정/거절 | SE-005 |
| `economy.refund_proposed` | `{request_id: String, reason: "demolish", base_amount: int}` | **economy 입력.** build 가 철거 확정 시. `base_amount` = 설치 때 승인된 건설비. 환불액 = ⌊base × `demolish_refund_rate_bp` ÷ `rate_scale`⌋, 결과는 `economy.cash_changed {reason:"demolish_refund"}`만 | SE-005 |
| `economy.sales_reported` | `{admissions: int, audience: int}` | **economy 입력.** audience/show 가 입장·관람 인원을 보고(회계일 안 여러 번 가능, 합산). v0 는 테스트가 발행. 응답 이벤트 없음 | SE-005 |
| `economy.upkeep_reported` | `{total: int}` — 설치 가구 `upkeep_per_day` 합 | **economy 입력.** build 가 설치 목록이 바뀔 때마다(교체, 누적 아님). 응답 이벤트 없음 | SE-005 |
| `economy.ticket_price_changed` | `{price: int, from: int}` | `economy.ticket_price_requested`가 받아들여져 값이 바뀌었을 때(경계). 같은 값이면 발행 안 함 | SE-005 |
| `economy.ticket_price_rejected` | `{price: <요청 값, 없으면 null>, reason: "invalid"\|"not_allowed"\|"out_of_range", phase: String}` | 가격 요청 거부(경계). `not_allowed` = 낮 구간 아님 또는 파산 뒤. 상태 불변 | SE-005 |
| `economy.day_settled` | `{day, ticket_price, admissions, audience, ticket_revenue, bar_buyers, bar_revenue, bar_cost, revenue, rent, upkeep, guarantee, operating_costs, pretax, tax, net, loan_repayment, settlement_delta, cash}` — 전부 int, `cash`는 정산 후·구제 전 | close 진입 틱 단계 4, `time.phase_changed {to:"close"}` 핸들러에서 날마다 정확히 1회(파산 뒤 없음). 공식 [economy.md#정산](economy.md#정산) | SE-005 |
| `economy.bailout_offered` | `{day: int, kind: "loan", deficit: int, amount: int, interest: int, total_due: int, repay_days: int, first_installment: int, bailouts_left_after: int}` | 정산 뒤 현금이 음수이고 남은 구제가 있을 때, `economy.day_settled` 바로 뒤 | SE-005 |
| `economy.bailout_taken` | `{day: int, kind: "loan", amount: int, total_due: int, repay_days: int, bailouts_left: int, cash: int, auto: bool}` | 제안 중인 구제를 `economy.bailout_accept_requested`로 수락(`auto:false`) 또는 수락 없이 `time.day_started`(`auto:true`). `economy.cash_changed {reason:"bailout"}` 바로 뒤 | SE-005 |
| `economy.bankrupt` | `{day: int, cash: int, bailouts_used: int}` | 정산 뒤 현금이 음수이고 남은 구제가 없을 때, `economy.day_settled` 바로 뒤. 게임당 1회. **게임 오버**(화면·흐름은 후속 UI 티켓) | SE-005 |
| `build.placed` | `{entity_id: String, furniture_id: String, cell: [x, z], rotation: int}` | 배치 확정 | 골격 |
| `build.rejected` | `{furniture_id: String, cell: [x, z], reason: String}` | 배치 실패 | 골격 |

## 명령 이벤트 (view/ui → sim)

| 이름 | 페이로드 | 처리 시스템 | 티켓 |
|---|---|---|---|
| `build.place_requested` | `{furniture_id: String, cell: [x, z], rotation: int}` | world/build | 골격 |
| `time.speed_requested` | `{speed: 0\|1\|2\|3}` — `int`. 결과는 `time.speed_changed` 또는 `time.speed_rejected` | core/tick (`TickLoop`) | SE-006 |
| `time.next_day_requested` | `{}` | core/tick (`TickLoop`). close 에서만 유효, 다른 구간에서는 무시(이벤트 없음) | SE-006 |
| `artist.book_requested` | `{artist_id: String}`. 결과는 `artist.booked`(개런티 지출 승인 뒤) 또는 `artist.booking_rejected` | sim/artist. 판정 K1~K5([artist.md#섭외-규칙](artist.md#섭외-규칙)), 낮 구간만, 하루 1명 | SE-031 |
| `economy.ticket_price_requested` | `{price: int}` — `int`. 결과는 `economy.ticket_price_changed` 또는 `economy.ticket_price_rejected` | sim/economy. 낮 구간에서만 유효, 범위 `ticket_price_min..max` | SE-005 |
| `economy.bailout_accept_requested` | `{}` | sim/economy. 구제 제안 중일 때만 유효, 아니면 무시(이벤트 없음). 결과 `economy.cash_changed` → `economy.bailout_taken` | SE-005 |

"골격" 행은 아키텍처 골격 예시다. 첫 구현 티켓에서 game-designer가 확정한다. "SE-006" 행의 상세 규칙은 [tick.md](tick.md), "SE-005" 행은 [economy.md](economy.md).

`economy.charge_proposed`·`economy.refund_proposed`·`economy.sales_reported`·`economy.upkeep_reported`는 다른 sim 시스템이 발행하고 economy 만 구독하는 **입력 계약** 이벤트다(sim → sim). 이름의 도메인은 받는 쪽(economy)을 따른다.

"SE-031" 행(`artist.*`)의 상세 규칙은 [artist.md](artist.md). artist 는 `economy.charge_proposed {reason:"guarantee"}`를 발행하고 `economy.charge_resolved`·`time.phase_changed`·`time.day_started`·`show.ended`·`reputation.changed`를 구독한다(`show.*`·`reputation.*`는 SE-030 이 등록).
