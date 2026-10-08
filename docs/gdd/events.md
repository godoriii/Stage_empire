# 이벤트 버스 계약 (events.md)

`core/event_bus.gd`를 지나는 모든 이벤트의 단일 출처. sim 은 **상태 이벤트**를 발행하고, view/ui 는 **명령 이벤트**를 발행한다. 이름은 `<domain>.<past_tense>`(상태) / `<domain>.<verb>_requested`(명령).

규칙:
- 페이로드는 Dictionary, 키는 스네이크 케이스, 값은 기본형·배열·Dictionary 만(객체 참조 금지 — 세이브·리플레이 때문).
- 이벤트를 추가·변경하는 에이전트는 이 표를 같은 PR에서 갱신한다. 표에 없는 이벤트는 reviewer가 반려한다.

## 상태 이벤트 (sim → 구독자)

| 이름 | 페이로드 | 발행 시점 | 티켓 |
|---|---|---|---|
| `tick.advanced` | `{tick: int, phase: "day"\|"evening"\|"show"\|"close"}` | 매 틱 | 골격 |
| `economy.cash_changed` | `{cash: int, delta: int, reason: String}` | 현금 변동 | 골격 |
| `build.placed` | `{entity_id: String, furniture_id: String, cell: [x, z], rotation: int}` | 배치 확정 | 골격 |
| `build.rejected` | `{furniture_id: String, cell: [x, z], reason: String}` | 배치 실패 | 골격 |

## 명령 이벤트 (view/ui → sim)

| 이름 | 페이로드 | 처리 시스템 | 티켓 |
|---|---|---|---|
| `build.place_requested` | `{furniture_id: String, cell: [x, z], rotation: int}` | world/build | 골격 |
| `time.speed_requested` | `{speed: 0\|1\|2\|3}` | core/tick | 골격 |

"골격" 행은 아키텍처 골격 예시다. 첫 구현 티켓에서 game-designer가 확정한다.
