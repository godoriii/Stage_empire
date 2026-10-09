# 이벤트 버스 계약 (events.md)

`core/event_bus.gd`를 지나는 모든 이벤트의 단일 출처. sim 은 **상태 이벤트**를 발행하고, view/ui 는 **명령 이벤트**를 발행한다. 이름은 `<domain>.<past_tense>`(상태) / `<domain>.<verb>_requested`(명령).

규칙:
- 페이로드는 Dictionary, 키는 스네이크 케이스, 값은 기본형·배열·Dictionary 만(객체 참조 금지 — 세이브·리플레이 때문). 허용 타입 목록과 위반 시 동작은 [tick.md#이벤트-순서](tick.md#이벤트-순서) E4.
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
| `time.speed_rejected` | `{speed: <요청 값, 없으면 null>, reason: "invalid"\|"not_allowed", phase: String}` | 배속 요청 거부(경계). `invalid` = 정수가 아님, `not_allowed` = 현재 구간 `speeds`에 없음. 상태 불변 | SE-006 |
| `economy.cash_changed` | `{cash: int, delta: int, reason: String}` | 현금 변동 | 골격 |
| `build.placed` | `{entity_id: String, furniture_id: String, cell: [x, z], rotation: int}` | 배치 확정 | 골격 |
| `build.rejected` | `{furniture_id: String, cell: [x, z], reason: String}` | 배치 실패 | 골격 |

## 명령 이벤트 (view/ui → sim)

| 이름 | 페이로드 | 처리 시스템 | 티켓 |
|---|---|---|---|
| `build.place_requested` | `{furniture_id: String, cell: [x, z], rotation: int}` | world/build | 골격 |
| `time.speed_requested` | `{speed: 0\|1\|2\|3}` — 정수(정수값 float 허용). 결과는 `time.speed_changed` 또는 `time.speed_rejected` | core/tick (`TickLoop`) | SE-006 |
| `time.next_day_requested` | `{}` | core/tick (`TickLoop`). close 에서만 유효, 다른 구간에서는 무시(이벤트 없음) | SE-006 |

"골격" 행은 아키텍처 골격 예시다. 첫 구현 티켓에서 game-designer가 확정한다. "SE-006" 행의 상세 규칙은 [tick.md](tick.md).
