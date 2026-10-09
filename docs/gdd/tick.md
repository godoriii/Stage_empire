# 틱·세션 구간·배속·결정성 (tick.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-006 (game-designer) |
| 구현 티켓 | SE-001 (sim-engineer) — `project/core/{sim_config,event_bus,rng,tick}.gd` |
| 데이터 | [`project/data/sim/sim.json`](../../project/data/sim/sim.json) (version 2), 스키마 [`sim.schema.json`](../../project/data/schemas/sim.schema.json) |
| 이벤트 | [`docs/gdd/events.md`](events.md) — 이 문서에 나오는 이벤트 이름은 전부 거기 표에 있다 |
| 근거 | PRD "핵심 게임플레이 루프"(세션 구조 표), "기술 요구사항"(아키텍처 원칙 2·4, 세이브), ADR-0002 |

## 목적

게임 시간의 규칙을 하나로 고정한다. 시간은 `core/tick.gd`의 `TickLoop`만 진행시키고, 1틱 = 1/10초 게임 시간이다.
하루는 낮→저녁→공연→마감 4구간을 돌고, 배속 0~3은 구간마다 허용 범위가 다르다.
**"같은 시드 + 같은 명령 열 → 같은 상태 + 같은 이벤트 열"**이 보장되어야 하며, 이를 위해 명령은 틱 경계에서만 적용되고
난수는 시드 고정 스트림에서만 나오고, 세이브(스냅샷)는 틱 경계에서만 찍힌다.
이 문서만 보고 SE-001 의 테스트와 구현을 질문 없이 시작할 수 있어야 한다.

이미 결정된 값(10 tick/s, 구간 길이 1,800/600/900/0, 구간별 허용 배속)은 **바꾸지 않고 의미만 고정**한다. 바꾸려면 ADR(producer).

## 규칙

### 틱

**단일 출처.** 틱 속도는 `sim.json.ticks_per_second`(= 10, 스키마가 `enum [10]`으로 고정) 하나뿐이다. 구간 길이는 `sim.json.phases[].ticks`.
`project/core/**/*.gd`(및 이후 `sim/`, `world/`)에 틱·구간 리터럴(`10`, `1800`, `600`, `900`, `3300`, `330`)을 두지 않는다. 필요한 값은 `SimConfig`에서 계산한다.
틱 수·구간 길이 변경은 ADR 필요(데이터만 바꿔도 리플레이 기준값과 세이브 불변식이 깨진다).

코드에 둘 수 있는 상수(매직 넘버가 아니라 단위·알고리즘 정의)는 아래뿐이다.

| 상수 | 값 | 위치 | 이유 |
|---|---|---|---|
| 마이크로초/초 | 1,000,000 | `tick.gd` | `step()` 누적기 단위(#배속) |
| FNV-1a 32 오프셋·소수·마스크 | 2166136261, 16777619, 0xFFFFFFFF | `rng.gd` | 파생 시드 알고리즘(#결정성과-rng) |
| 마스터 시드 상한 | 2^31 − 1 = 2,147,483,647 | `rng.gd` | JSON 왕복에서 정수 손실 없음(#스냅샷) |

**하루 길이.** `D = Σ phases[].ticks = 1,800 + 600 + 900 + 0 = 3,300틱 = 330초(1배속)`. `SimConfig`가 `day_ticks`로 계산해 제공한다.

**카운터 4개.** 모두 `int`. "경계 상태"란 틱과 틱 사이(=`advance()`/`step()` 바깥)에서 관찰한 값이다.

| 카운터 | 정의 | 새 게임 | 범위 | 세이브 |
|---|---|---|---|---|
| `tick` | 게임 시작부터 처리된 틱 수. 세이브·로드를 넘어 누적. 감소하지 않음 | 0 | 0 ~ int64 | 저장 |
| `day` | 현재 게임일. 1부터 | 1 | ≥ 1 | 저장 |
| `tick_in_day` | 현재 날에 처리된 틱 수 = `phase_start(phase) + tick_in_phase` | 0 | 0 ~ `D` (`D`는 close 에서만) | 파생(저장 안 함) |
| `tick_in_phase` | 현재 구간에 처리된 틱 수 | 0 | 0 ~ `ticks(phase) − 1`, close 는 항상 0 | 저장 |

불변식(모든 경계 상태에서 참, SE-001 테스트가 단언):

| # | 불변식 |
|---|---|
| I1 | `tick == (day − 1) × D + tick_in_day` (close 는 0틱이라 시간 손실이 없다) |
| I2 | `tick_in_day == phase_start(phase) + tick_in_phase` |
| I3 | `ticks(phase) > 0` 이면 `0 ≤ tick_in_phase < ticks(phase)`, `ticks(phase) == 0` 이면 `tick_in_phase == 0` |
| I4 | `speed ∈ phases[phase].speeds` (진입 클램프와 요청 거부가 이를 보장) |

**`SimConfig.load()` 교차 검증.** 스키마가 못 잡는 규칙은 로더가 검사하고, 어기면 `push_error` 후 `null`을 돌려준다.

| # | 검사 | 현재 값으로 |
|---|---|---|
| C1 | `phases[].id` 순서가 정확히 `day, evening, show, close` | 통과 |
| C2 | 마지막 구간만 `ticks == 0`(홀드 구간), 나머지는 `ticks > 0` | 통과 |
| C3 | `speeds`가 오름차순·중복 없음 | 통과 |
| C4 | `default_speed ∈ speeds` | 통과 |
| C5 | `pausable == (0 ∈ speeds)` — `speeds`가 판정 근거, `pausable`은 UI 표시용 사본 | 통과 |
| C6 | `rng_streams`, `system_order` 중복 없음 | 통과 |

### 세션 구간

구간 시작점 `phase_start`는 `phases[]` 앞쪽 `ticks`의 누적합이다. 경계 상태 기준으로 `tick_in_day`가 어느 구간에 속하는지는 아래와 같다.

| 구간 id | 길이 출처 | `phase_start` | 경계 상태의 `tick_in_day` | 진입 조건 | 이탈 조건 | 1배속 실시간 |
|---|---|---|---|---|---|---|
| `day` | `phases[0].ticks` = 1,800 | 0 | 0 ~ 1,799 | 새 게임, 또는 close 에서 `time.next_day_requested` 처리 | `tick_in_phase`가 1,800 에 도달한 틱 | 180초 |
| `evening` | `phases[1].ticks` = 600 | 1,800 | 1,800 ~ 2,399 | day 이탈 틱 | `tick_in_phase` 600 도달 틱 | 60초 |
| `show` | `phases[2].ticks` = 900 | 2,400 | 2,400 ~ 3,299 | evening 이탈 틱 | `tick_in_phase` 900 도달 틱 | 90초 |
| `close` | `phases[3].ticks` = 0 (홀드) | 3,300 | 3,300 | show 이탈 틱 | `time.next_day_requested` 명령 처리. **시간으로는 나가지 않는다** | 무기한 |

**경계 값 확정.** "`tick_in_day` 1,800 은 evening 의 0 이다." 1,800번째 틱을 처리한 직후의 경계 상태는 `phase == "evening"`, `tick_in_phase == 0`이다.
틱은 시작 시점의 구간에서 처리되고(시스템은 그 구간 값을 본다), 처리 직후 경계에서 구간이 바뀐다.

1일차·2일차 경계 상태 예(`D = 3,300`):

| 시점 | `tick` | `day` | `phase` | `tick_in_day` | `tick_in_phase` | 그 틱/경계에서 나는 시간 이벤트 |
|---|---|---|---|---|---|---|
| 새 게임 | 0 | 1 | day | 0 | 0 | 없음(생성자는 이벤트를 내지 않는다) |
| 1틱 후 | 1 | 1 | day | 1 | 1 | `tick.advanced {tick:1, phase:"day"}` |
| 1,799틱 후 | 1,799 | 1 | day | 1,799 | 1,799 | `tick.advanced` |
| 1,800틱 후 | 1,800 | 1 | evening | 1,800 | 0 | `time.phase_changed {from:"day", to:"evening", day:1, tick:1800}` → (배속 2·3이었으면 `time.speed_changed`) → `tick.advanced {tick:1800, phase:"evening"}` |
| 2,400틱 후 | 2,400 | 1 | show | 2,400 | 0 | `time.phase_changed {evening→show}` → `tick.advanced {phase:"show"}` |
| 3,299틱 후 | 3,299 | 1 | show | 3,299 | 899 | `tick.advanced` |
| 3,300틱 후 | 3,300 | 1 | close | 3,300 | 0 | `time.phase_changed {show→close, tick:3300}` → `time.speed_changed {speed:0, from:1, cause:"phase_enter"}` → `tick.advanced {tick:3300, phase:"close"}` |
| close 에서 `advance(k)`/`step(t)` | 3,300 | 1 | close | 3,300 | 0 | 없음(반환값 0) |
| `next_day_requested` 처리 후 | 3,300 | 2 | day | 0 | 0 | `time.day_started {day:2}` → `time.phase_changed {from:"close", to:"day", day:2, tick:3300}` → `time.speed_changed {speed:1, from:0, cause:"phase_enter"}` |
| 그 뒤 1틱 | 3,301 | 2 | day | 1 | 1 | `tick.advanced {tick:3301, phase:"day"}` |
| 2일차 마감 | 6,600 | 2 | close | 3,300 | 0 | 위 3,300 행과 같은 패턴 |

- 다음 날 전환은 틱을 소비하지 않는다(`tick` 불변). 그래서 I1 이 유지된다.
- close 이외의 구간에서 받은 `time.next_day_requested`는 **무시**한다(상태 불변, 이벤트 없음).
- 새 게임은 `phases[0]`(day)·`tick_in_phase 0`·`speed = phases[0].default_speed`로 시작하며 이벤트를 내지 않는다. `time.day_started`는 2일차부터 난다.
- **티어 5~6 원칙:** "하루 = 3일짜리 페스티벌의 하루"가 되어도 같은 4구간·같은 카운터를 쓴다. 다중 무대는 `show` 구간 안의 시스템 문제이며 이 문서의 시간 규칙은 바뀌지 않는다. 상세는 티어 4+ 티켓.

### 배속

**의미.** 배속은 "실시간 1초당 처리할 틱 수"의 배수다. 게임 시간 1틱의 의미(1/10초)는 배속과 무관하다.

| `speed` | 의미 | `step(1.0)`이 처리하는 틱 | `advance(n)` |
|---|---|---|---|
| 0 | 일시정지. 틱 0개. **명령은 계속 받고 경계에서 적용한다**(PRD 접근성 "일시정지 중 모든 조작 가능") | 0 | 0틱(명령만 적용) |
| 1 | 실시간 | `ticks_per_second × 1` = 10 | n틱 |
| 2 | 2배 | 20 | n틱 |
| 3 | 3배 | 30 | n틱 |

- `advance(n)`은 실시간과 무관한 헤드리스 구동기(테스트·봇)다. 배속 1·2·3을 구별하지 않지만 **일시정지(0)와 홀드 구간(close)에서는 멈춘다.** 반환값 = 실제 처리한 틱 수.
- `step(delta_s)`는 실시간 구동기(후속 render 티켓의 Node 가 매 프레임 호출)다. 아래 누적기 규칙을 따른다.

**구간별 허용.** 판정 근거는 `sim.json.phases[].speeds` 하나다.

| 구간 | `speeds` | 1배속 / 최대 배속 실시간 | `pausable` |
|---|---|---|---|
| day | [0, 1, 2, 3] | 180초 / 60초(3배속) | true |
| evening | [0, 1] | 60초 / 60초 | true |
| show | [1] | 90초 / 90초 | false |
| close | [0] | 무기한 | true |
| 하루 합계 | | 330초 / 최소 210초 | |

**배속 요청 처리** (`time.speed_requested {speed}`, 경계에서 적용. #명령-큐와-틱-순서)

| 순서 | 조건 | 상태 | 발행 |
|---|---|---|---|
| 1 | `speed`가 정수가 아님(`int`, 또는 정수값인 `float`만 정수로 인정. 키 없음·문자열·1.5 등은 아님) | 불변 | `time.speed_rejected {speed: <받은 값 또는 null>, reason:"invalid", phase}` |
| 2 | `speed ∉ phases[phase].speeds` | 불변 | `time.speed_rejected {speed, reason:"not_allowed", phase}` |
| 3 | `speed == 현재 speed` | 불변 | 없음 |
| 4 | 그 외 | `speed` 갱신 | `time.speed_changed {speed, from, cause:"requested"}` |

**구간 진입 시 배속.** `phases[].enter_speed_mode`와 `default_speed`로 정한다.

| 모드 | 규칙 |
|---|---|
| `force` | 진입 시 항상 `speed = default_speed` |
| `keep_if_allowed` | 현재 `speed ∈ speeds`면 유지, 아니면 `speed = default_speed` |

바뀌었을 때만 `time.speed_changed {speed, from, cause:"phase_enter"}`를 `time.phase_changed` 바로 뒤에 발행한다. 현재 데이터로 나오는 클램프 표:

| 진입 구간 | 경로 | 모드 / `default_speed` | 진입 전 → 후 |
|---|---|---|---|
| day | 새 게임 | force / 1 | — → 1 (이벤트 없음) |
| day | close 에서 다음 날 | force / 1 | 0 → 1 |
| evening | day 이탈 틱 | keep_if_allowed / 1 | 1 → 1, 2 → 1, 3 → 1 (0 은 도달 불가: 일시정지 중엔 틱이 돌지 않는다) |
| show | evening 이탈 틱 | keep_if_allowed / 1 | 1 → 1 (0·2·3 은 도달 불가지만 규칙상 → 1) |
| close | show 이탈 틱 | force / 0 | 1 → 0 |

**`step(delta_s)` 누적기.** 정수 누적기 `acc`(단위: µs × 틱/초)를 쓴다. 부동소수 누적 오차로 틱이 빠지지 않게 한다.

| 단계 | 동작 |
|---|---|
| S1 | 재진입이면(`advance`/`step` 실행 중이거나 버스가 디스패치 중) `push_error`, 0 반환 |
| S2 | 경계 처리(명령 적용, #명령-큐와-틱-순서의 B) |
| S3 | `s0 = speed`. `s0 == 0`이거나 홀드 구간이면 `acc = 0`, 0 반환(일시정지 중 실시간은 쌓이지 않는다) |
| S4 | `us = max(0, roundi(delta_s × 1,000,000))`, `acc += us × s0 × ticks_per_second` |
| S5 | `q = acc ÷ 1,000,000`(정수 나눗셈), `acc −= q × 1,000,000`, `budget = min(q, max_ticks_per_step)` (상한 초과분은 버림, 따라잡기 없음) |
| S6 | 최대 `budget`틱을 처리. 두 번째 틱부터는 처리 직전에: 홀드 구간이거나 `speed ≠ s0`면 `acc = 0` 후 중단 → 아니면 경계 처리 → 다시 `speed ≠ s0`면 `acc = 0` 후 중단 |
| S7 | 처리한 틱 수 반환 |

검산: 배속 1, `step(0.1)`: `us = 100,000`, `acc += 100,000 × 1 × 10 = 1,000,000` → 1틱. 100회 → 100틱. 배속 3 → 회당 3틱, 100회 → 300틱. `step(0.05)` 2회 = 500,000 + 500,000 → 1틱 = `step(0.1)` 1회.
`acc`는 실시간 잔여물이라 **스냅샷에 넣지 않는다**(복원 시 0). `max_ticks_per_step` = 30 (`sim.json`, 3배속 실시간 1초분).

### 명령 큐와 틱 순서

**명령 이벤트.** 이름이 `_requested`로 끝나는 이벤트(예: `time.speed_requested`, `build.place_requested`). `EventBus.publish()`는 명령을 즉시 전달하지 않고
페이로드를 깊은 복사해 **명령 큐** 끝에 넣고 `true`를 돌려준다. 명령은 `EventBus.dispatch_commands()`가 불릴 때만 구독자에게 전달되며, 이를 부르는 것은 `TickLoop`뿐이다.
따라서 명령의 효과는 언제 보냈든(핸들러 안, 틱 사이, 일시정지 중) **다음 경계 처리**에서 나타난다.

**경계 처리(B).** `dispatch_commands()` 1회. 호출 시점 큐에 있던 명령 `k`개만 FIFO 로 꺼내 하나씩 전달한다(명령 하나의 연쇄 상태 이벤트가 다 끝난 뒤 다음 명령).
처리 중 새로 들어온 명령은 큐 끝에 남아 **다음** 경계 처리로 간다(무한 루프 방지). 구독자가 없는 명령은 버리고 `push_warning`.
경계 처리는 아래 두 시점에만 일어난다.

| 시점 | 설명 |
|---|---|
| B-call | `advance()`/`step()` 호출 시작. 틱을 하나도 못 돌리는 경우(일시정지·close·`n == 0`)에도 일어난다. **`advance(0)` = 명령만 적용** |
| B-tick | 같은 호출 안에서 두 번째 이후 틱을 처리하기 직전(홀드·일시정지로 멈출 상황이면 하지 않는다) |

**`advance(n)` 절차.**

| 단계 | 동작 |
|---|---|
| A1 | 재진입이면 `push_error`, 0 반환. 음수 `n`은 0 으로 취급 |
| A2 | 경계 처리(B-call) |
| A3 | `done = 0`. `done < n`인 동안: ① `speed == 0`이거나 홀드 구간이면 중단 ② `done ≠ 0`이면 경계 처리(B-tick) 후 다시 ① 검사 ③ 틱 처리(아래 표의 단계 2~5), `done += 1` |
| A4 | `done` 반환 |

`step()`은 같은 구조에 #배속의 누적기·배속 변경 중단(S3~S6)이 더해진 것이다.

마지막 틱 뒤에는 경계 처리를 하지 않는다. 그 틱의 핸들러가 보낸 명령은 큐에 남고 스냅샷의 `pending_commands`에 들어간다.
이렇게 하면 `advance(10)`과 `advance(5)` + `advance(5)`가 같은 경계에서 같은 명령을 적용한다(호출 분할에 무관).

**한 틱의 순서.** 경계 상태 `tick = T`에서 틱 `T + 1`을 처리한다.

| 단계 | 동작 | 이 단계에서 나는 이벤트 | RNG |
|---|---|---|---|
| 1. 명령 처리 | 경계 처리(B-call 또는 B-tick). 처리 후 `speed == 0` 또는 홀드 구간이면 **틱을 돌리지 않고** 종료 | 명령 핸들러의 상태 이벤트(`time.speed_changed`, `time.speed_rejected`, `time.day_started`, …) | 명령 핸들러가 쓸 수 있음(해당 시스템 스트림) |
| 2. 시스템 업데이트 | `sim.json.system_order` 순서로, 등록된 시스템의 `update(ctx)` 호출. 등록 안 된 id 는 건너뜀 | 시스템이 발행하는 상태 이벤트(즉시 전달) | 시스템별 스트림만 |
| 3. 카운터 | `tick += 1`, `tick_in_phase += 1` (`tick_in_day`는 파생) | 없음 | 없음 |
| 4. 구간 전환 | `tick_in_phase == ticks(phase)`면: `phase ← 다음 구간`, `tick_in_phase ← 0`, 진입 배속 규칙 적용(상태 먼저 전부 갱신) → `time.phase_changed` 발행 → 바뀌었으면 `time.speed_changed {cause:"phase_enter"}` 발행 | `time.phase_changed`, `time.speed_changed` (+ 그 구독자들의 연쇄 이벤트) | 구독 핸들러가 쓸 수 있음 |
| 5. 틱 완료 | `tick.advanced {tick: T+1, phase: <갱신 후 구간>}` 발행 | `tick.advanced` (그 틱의 마지막 이벤트) | 없음 |

- 단계 2 의 `ctx`는 **틱 시작 시점(경계 T)** 값이다: `{tick: T+1, day, phase, tick_in_day, tick_in_phase}`. 예: 첫 틱 `{tick:1, day:1, phase:"day", tick_in_day:0, tick_in_phase:0}`, 공연 마지막 틱 `{tick:3300, day:1, phase:"show", tick_in_day:3299, tick_in_phase:899}`.
- `tick.advanced`의 `phase`는 **갱신 후** 값이다(그 틱에서 구간이 바뀌었으면 `time.phase_changed.to`와 같다). `advance()`가 끝난 뒤 `snapshot().tick/phase`와 마지막 `tick.advanced`의 페이로드가 같다.
- SE-005(경제)의 정산 "close 진입 틱 1회"는 단계 4 의 `time.phase_changed {to:"close"}` 구독 핸들러에서 한다. 그러면 정산 이벤트가 그 틱의 `tick.advanced` 전에 끝나고 오토세이브(#스냅샷)에 정산 결과가 들어간다.

**시스템 등록.** `TickLoop.register_system(id: String, update: Callable) -> bool`.

| 규칙 | 실패 시 |
|---|---|
| `id ∈ sim.json.system_order` | `push_error`, `false` |
| 같은 id 두 번 등록 불가 | `push_error`, `false` |
| `advance`/`step` 실행 중·디스패치 중 등록 불가 | `push_error`, `false` |
| 호출 순서는 `system_order` 순서. 등록 순서와 무관 | — |

v0 `system_order`: `build → staff → artist → audience → show → crisis → economy → reputation` (입력을 만드는 시스템이 먼저, 결과를 합산하는 시스템이 나중). SE-001 은 시스템을 하나도 등록하지 않는다(테스트용 가짜 시스템만).
시스템은 이벤트 구독도 `system_order` 순서로 생성·구독한다(구독 순서가 전달 순서이고 결정성의 일부다). sim 시스템은 `tick.advanced`를 구독하지 않는다(업데이트는 단계 2로).

**재진입 금지.** `advance`/`step`/`snapshot`/`restore`/`register_system`은 `TickLoop`이 실행 중이거나 버스가 디스패치 중(=어떤 핸들러 안)이면 `push_error` 후 실패 값(0 / `{}` / `false`)을 돌려준다.

**공개 API (SE-001 구현 대상, 이름 고정).**

| 클래스 | 멤버 | 설명 |
|---|---|---|
| `SimConfig` | `static load(path := "res://data/sim/sim.json") -> SimConfig` | 스키마 외 교차 검증 C1~C6, 실패 시 `null` |
| | `ticks_per_second`, `phases: Array[Dictionary]`, `day_ticks`, `max_ticks_per_step`, `snapshot_schema_version`, `rng_streams: Array[String]`, `system_order: Array[String]` | 읽기 전용 |
| | `phase_index(id) -> int`, `phase_start(id) -> int` | 누적 경계 |
| `EventBus` | `subscribe(name, handler: Callable)`, `unsubscribe(name, handler)` | 같은 (이름, 핸들러) 중복 구독은 무시 |
| | `publish(name, payload := {}) -> bool` | 상태 이벤트는 즉시(디스패치 중이면 FIFO 큐), 명령은 명령 큐 |
| | `dispatch_commands() -> int` | 경계 처리. 전달한 명령 수 |
| | `is_dispatching() -> bool`, `get_pending_commands() -> Array`, `set_pending_commands(a: Array)` | 스냅샷용, 깊은 복사 |
| `SeededRng` | `new(master_seed: int, stream_names: Array[String])`, `static derive_seed(master_seed, name) -> int` | |
| | `stream(name) -> RandomNumberGenerator`, `get_state() -> Dictionary`, `set_state(d) -> bool` | |
| `TickLoop` | `new(config: SimConfig, seed: int, bus: EventBus = null)` | `bus`가 `null`이면 자체 생성. 생성자는 이벤트를 내지 않는다. `time.speed_requested`, `time.next_day_requested`를 구독 |
| | `tick`, `day`, `phase: String`, `tick_in_day`, `tick_in_phase`, `speed`, `bus`, `rng` | 읽기 전용 |
| | `advance(n: int) -> int`, `step(delta_s: float) -> int` | `n < 0`은 0 으로 취급 |
| | `register_system(id, update: Callable) -> bool`, `snapshot() -> Dictionary`, `restore(s: Dictionary) -> bool` | |

### 결정성과 RNG

**정의.** 입력 = `(마스터 시드, sim.json 내용, 명령 열)`. 명령 열은 `(적용 경계 tick, 큐 안 순서, 이름, 페이로드)`의 목록이다.
입력이 같으면 모든 경계의 `snapshot()`과 발행된 상태 이벤트 열(이름 + 페이로드, 순서 포함)이 같다. 실시간(`step`의 `delta_s`)은 **틱 수로만** 환산되며 상태에 들어가지 않는다.
보장 범위는 같은 Godot 빌드·같은 플랫폼이다(리플레이 테스트는 한 기계에서 두 번 돌린다). 플랫폼 간 부동소수 일치는 v0 범위 밖이므로 돈·인원 같은 상태는 정수로 둔다.

| 금지 (sim·core·world) | 대신 |
|---|---|
| 전역 `randi()`, `randf()`, `randomize()`, `RandomNumberGenerator.new()` | `tick_loop.rng.stream("<스트림>")` |
| `Time.*`, `OS.get_ticks_*`, `_process`, `_physics_process` | `TickLoop` 카운터 |
| 받은 명령을 핸들러 밖에서 즉시 적용 | 명령 큐 + 경계 처리 |
| Dictionary 순회 순서에 기대는 로직(삽입 순서가 입력에 따라 달라지는 경우) | 키를 정렬해 순회 |
| `randfn()` (플랫폼별 초월함수) | `randf()` 조합 또는 표 |

**스트림.** `SeededRng`은 `sim.json.rng_streams`에 있는 이름만 연다. 모르는 이름으로 `stream()`을 부르면 `push_error`, `null`.
한 스트림의 주인은 한 시스템이다(공유 금지 — 한 시스템이 뽑는 횟수를 바꿔도 다른 시스템의 열이 안 바뀌게).

| v0 스트림 | 주인 시스템 | 쓰는 단계 |
|---|---|---|
| `audience` | audience | 단계 2(유입·취향·이동 선택) |
| `artist` | artist | 단계 2, 섭외 명령 처리(단계 1) |
| `events` | crisis | 단계 2(위기·사고·바이럴 롤) |
| `economy` | economy | 단계 2, 정산 핸들러(단계 4) |
| `world` | build | 명령 처리(단계 1) 시 배치 변형 등 |

staff·show·reputation 이 난수가 필요해지면 그 스펙 티켓에서 이름을 **추가**한다(예: `staff`, `show`). 봇·테스트 하네스의 무작위는 별도 `SeededRng` 인스턴스(다른 마스터 시드)를 쓰고 게임 스트림을 소비하지 않는다(리플레이 테스트의 의도적 소비는 예외).

**파생 시드.** 스트림 시드는 마스터 시드와 스트림 이름만으로 정한다. 그래서 스트림을 추가해도 기존 스트림의 열은 바뀌지 않는다.

| 항목 | 규칙 |
|---|---|
| 마스터 시드 | `int`, 0 ~ 2,147,483,647. 범위 밖이면 `push_error` 후 `posmod(seed, 2147483648)` |
| 키 문자열 | `str(master_seed) + ":" + name` (예: `"42:audience"`) |
| 해시 | FNV-1a 32비트, 키의 UTF-8 바이트: `h = 2166136261`; 바이트 `b`마다 `h = ((h XOR b) × 16777619) AND 0xFFFFFFFF` (64비트 정수로 계산해도 넘치지 않음) |
| 스트림 RNG | `RandomNumberGenerator.new()`; `.seed = h` |
| 상태 | 스트림별 `RandomNumberGenerator.state`(int64). 직렬화는 10진 문자열 `str(state)`, 복원은 `String.to_int()` |

검증 벡터(`derive_seed`가 정확히 이 값을 내야 한다):

| 키 | 10진 | 16진 |
|---|---|---|
| `42:audience` | 2851880905 | 0xA9FC3FC9 |
| `42:artist` | 3021210036 | 0xB41401B4 |
| `42:events` | 564648782 | 0x21A7DB4E |
| `42:economy` | 2295552225 | 0x88D358E1 |
| `42:world` | 2250541393 | 0x86248951 |
| `0:audience` | 1688486501 | 0x64A44265 |
| `0:events` | 468373146 | 0x1BEACE9A |
| `2147483647:audience` | 1028055295 | 0x3D46E0FF |

**상태 해시.** 리플레이·복원 비교의 "같은 상태"는 `JSON.stringify(snapshot(), "", true)`(키 정렬) 문자열이 같은 것이다. 이벤트 열 비교는 `[[이름, 페이로드], …]`를 같은 방식으로 문자열화해 비교한다.

### 스냅샷

`TickLoop.snapshot() -> Dictionary`. 값은 전부 기본형(`int`, `String`, `bool`, `Array`, `Dictionary`, `null`)이고 JSON 왕복(`stringify → parse_string`) 후 `restore()`해도 같은 상태가 된다.
v0 는 시간·RNG·명령 큐만 담는다. 경제·관객 등 시스템 상태는 각 시스템 스펙이 최상위 키를 추가하고 `snapshot_schema_version`을 올린다.

| 키 | 타입 | 값 |
|---|---|---|
| `schema_version` | int | `sim.json.snapshot_schema_version` (= 1) |
| `seed` | int | 마스터 시드 |
| `tick` | int | 경계 상태 |
| `day` | int | 경계 상태 |
| `phase` | String | `"day" \| "evening" \| "show" \| "close"` |
| `tick_in_phase` | int | 경계 상태 (`tick_in_day`는 파생이라 넣지 않는다) |
| `speed` | int | 0~3 |
| `rng` | Dictionary | `{<스트림 이름>: "<state 10진 문자열>"}`, `rng_streams` 전부 |
| `pending_commands` | Array | `[{name: String, payload: Dictionary}, …]` 큐 순서 그대로. 보통 `[]` |

`pending_commands`는 SE-006 이 SE-001 AC10 의 괄호 목록에 **추가**한 필드다(이유: 마지막 틱의 핸들러나 UI 가 보낸 명령이 세이브에서 사라지면 복원 후 진행이 연속 진행과 달라진다). SE-001 은 AC10 의 목록 대신 이 표를 쓴다.
`step()` 누적기 `acc`와 구독자 목록은 상태가 아니므로 넣지 않는다.

**허용 시점.** 경계 상태에서만. `advance`/`step` 실행 중(시스템 `update` 안 포함)이거나 버스 디스패치 중(어떤 핸들러 안)이면 `push_error` 후 `{}`를 돌려준다.

**`restore(s) -> bool`.**

| 순서 | 검사·동작 | 실패 시 |
|---|---|---|
| 1 | 재진입 아님 | `push_error`, `false`, 상태 불변 |
| 2 | `s.schema_version == snapshot_schema_version` (마이그레이션은 후속 세이브 티켓) | 〃 |
| 3 | 숫자 필드는 `int()`로 정규화(JSON 왕복 시 float 로 오므로). `phase`가 유효, `day ≥ 1`, I1·I3 성립 | 〃 |
| 4 | 카운터·`speed`·`seed` 덮어쓰기, `SeededRng`을 `seed`로 다시 만들고 `rng` 상태 적용. 스냅샷에 없는 스트림(데이터에 새로 추가된 것)은 새 파생 시드에서 시작, 데이터에 없는 스트림은 `push_warning` 후 무시 | — |
| 5 | 버스 명령 큐를 `pending_commands`로 교체(`speed` 같은 정수 페이로드는 정수로 정규화), `acc = 0` | — |
| 6 | 이벤트를 발행하지 않는다. `true` | — |

복원 후 진행 = 연속 진행: 상태 A 에서 `s = snapshot()` → 새 `TickLoop`에 `restore(s)` → `advance(N)` 결과의 상태 해시가, A 에서 그대로 `advance(N)`한 결과와 같다.

**오토세이브 시점.** PRD "하루 마감마다" = close 진입 틱이 끝난 경계. 그 틱의 단계 4 에서 `time.phase_changed {to:"close"}`가 나고, close 는 홀드라 `advance`/`step`이 그 경계에서 반환한다(뒤따르는 경계 처리 없음).
세이브 시스템(후속 티켓)은 `time.phase_changed {to:"close"}`를 구독해 플래그만 세우고, 구동기가 `advance`/`step` 반환 뒤 `snapshot()`을 찍는다. 파일 포맷(JSON → gzip)·마이그레이션은 후속 세이브 티켓.

### 이벤트 순서

| # | 규칙 |
|---|---|
| E1 | 같은 이름의 구독자는 **구독한 순서대로** 호출된다. 디스패치 중 `subscribe`/`unsubscribe`는 다음 이벤트부터 반영(진행 중인 이벤트의 호출 목록은 시작 시점 사본) |
| E2 | 디스패치 중(핸들러 안) `publish()`한 상태 이벤트는 즉시 전달되지 않고 버스의 이벤트 큐 끝에 들어간다. 현재 이벤트의 모든 구독자 호출이 끝난 뒤 FIFO 로 전달된다. **재진입 없음** — 핸들러 실행 중에 다른 핸들러가 끼어들지 않는다 |
| E3 | 버스가 쉬고 있을 때의 `publish()`(최외곽)는 그 이벤트와 연쇄된 모든 상태 이벤트가 전달된 뒤 반환한다 |
| E4 | 페이로드는 `Dictionary`. 키는 `String`(또는 `StringName`), 값은 `null`/`bool`/`int`/`float`/`String`/`StringName`/`Array`/`Dictionary`만(재귀). 그 밖(`Object`, `Vector2`, `Callable`, `Packed*Array` 등)이 하나라도 있으면 `push_error`, `false`, 전달·큐잉 안 함. 버스는 페이로드를 깊은 복사해 모든 구독자에게 같은 사본을 준다. 핸들러는 페이로드를 수정하지 않는다(리뷰 규약) |
| E5 | 명령 이벤트(`*_requested`)는 명령 큐로 가서 경계 처리에서 전달된다(#명령-큐와-틱-순서). 경계 처리 안의 명령 하나는 E3 처럼 최외곽 전달로 취급된다 |
| E6 | 상태 이벤트는 그 틱 안에서 발생 순서대로 전달된다. 한 틱의 이벤트 순서 = [단계 1 명령 연쇄] → [단계 2 시스템 순서대로] → [단계 4 `time.phase_changed` → `time.speed_changed`] → [단계 5 `tick.advanced`] |
| E7 | `tick.advanced`는 그 틱에서 `TickLoop`이 마지막으로 발행하는 이벤트다. `tick.advanced` 구독자(view/ui/세이브/테스트 기록기)는 상태 이벤트를 발행하지 않는다(명령만 가능, 다음 경계에서 적용). 위반은 reviewer 반려 대상 |
| E8 | 상태 변경 → 이벤트 순. 한 동작이 여러 이벤트를 낼 때 상태를 먼저 전부 갱신하고 이벤트를 나열된 순서로 낸다. 다음 날: `time.day_started` → `time.phase_changed` → `time.speed_changed`. 구간 진입: `time.phase_changed` → `time.speed_changed` |
| E9 | 이름 접두어 `test.`는 테스트 전용이며 `events.md` 등록 대상이 아니다. 그 외 이름은 전부 `events.md` 표에 있어야 한다 |

## 수치표

모든 수치는 [`project/data/sim/sim.json`](../../project/data/sim/sim.json)(version 2)에 있다. 이 문서의 수치는 그 사본이며 충돌하면 JSON 이 이긴다.

| 필드 | 값 | 의미 | 변경 |
|---|---|---|---|
| `ticks_per_second` | 10 | 1틱 = 0.1초 게임 시간 | ADR |
| `phases[].ticks` | 1,800 / 600 / 900 / 0 | 구간 길이, 합 3,300 | ADR |
| `phases[].speeds` | [0,1,2,3] / [0,1] / [1] / [0] | 구간별 허용 배속 | ADR(PRD 세션 구조 표) |
| `phases[].pausable` | true / true / false / true | `0 ∈ speeds`의 사본(C5) | speeds 와 함께 |
| `phases[].default_speed` | 1 / 1 / 1 / 0 | 진입·새 게임 배속 (v2 신규) | designer |
| `phases[].enter_speed_mode` | force / keep_if_allowed / keep_if_allowed / force | 진입 클램프 규칙 (v2 신규) | designer |
| `max_ticks_per_step` | 30 | `step()` 1회 상한 (v2 신규) | designer |
| `snapshot_schema_version` | 1 | 스냅샷 `schema_version` (v2 신규) | 세이브 티켓과 함께 |
| `rng_streams` | audience, artist, events, economy, world | v0 스트림 (v2 신규) | 추가 자유, 변경·삭제는 리플레이 기준값 갱신 |
| `system_order` | build, staff, artist, audience, show, crisis, economy, reputation | 단계 2 순서 (v2 신규) | designer + 리플레이 기준값 갱신 |

## 수용 기준

SE-001 의 AC 와 1:1 대응하는 테스트 케이스 목록이다. 경로는 전부 `project/tests/sim/` 기준. "SE-006 추가" 표시가 붙은 케이스는 이 문서가 같은 AC 아래에 더한 것으로, SE-001 구현 시 함께 쓴다(producer 가 SE-001 AC 문구에 반영).
SE-001 의 이름을 바꾼 것은 없다. 이벤트 이름도 SE-001 이 쓴 그대로다(`time.day_started`만 신규, `time.speed_changed`는 페이로드에 `from`, `cause` 추가).

| SE-001 AC | 케이스 | 무엇을 단언하나 (이 문서의 근거 절) |
|---|---|---|
| AC1 | `test_sim_config.gd::test_loads_sim_json` | `ticks_per_second == 10`, 구간 4개가 `day, evening, show, close` 순서로 `ticks/pausable/speeds/default_speed/enter_speed_mode`를 가짐, `day_ticks == 3300`, `phase_start`가 0/1800/2400/3300 (#틱, #세션-구간) |
| AC1 | `test_sim_config.gd::test_rejects_invalid_config` (SE-006 추가) | 메모리 상 변형 사본으로 C1~C6 위반 각각 `null` (#틱) |
| AC1 | `test_core_boundary.gd::test_no_tick_literals_in_core` | `project/core/**/*.gd`에서 주석·문자열 리터럴을 지운 뒤 정규식 `(?<![\w.])(10\|1800\|600\|900\|3300\|330)(?![\w.])` 일치 0건 (#틱 상수표의 상수는 걸리지 않는다) |
| AC2 | `test_tick.gd::test_advance_increments_tick` | 새 게임 `advance(1)` 반환 1, `tick == 1`, `tick_in_phase == 1`. 전제 단언: `phases[0].default_speed ≥ 1` (#틱, #배속) |
| AC2 | `test_tick.gd::test_tick_advanced_published_once_per_tick` | `advance(3300)` 반환 3,300, `tick.advanced` 3,300회, `tick` 1..3300 단조 증가, 마지막 페이로드 `{tick:3300, phase:"close"}`, 매 틱 후 I1~I4 (#세션-구간 예시표) |
| AC3 | `test_tick.gd::test_phase_boundaries_from_config` | 경계를 `phase_start`로 계산, Σ = 3,300 단언. `advance(1799)` → day/1799, `advance(1)` → evening/`tick_in_phase` 0, 2,400 → show/0, 3,300 → close/0 (#세션-구간 "경계 값 확정") |
| AC3 | `test_tick.gd::test_phase_changed_events_in_order` | `time.phase_changed` 정확히 3회: `{day→evening, day:1, tick:1800}`, `{evening→show, 2400}`, `{show→close, 3300}`. 각각 같은 틱의 `tick.advanced`보다 먼저 (#이벤트-순서 E6) |
| AC4 | `test_tick.gd::test_close_holds_until_next_day_requested` | close 에서 `advance(10)` 반환 0, `step(1.0)` 반환 0, `tick` 3,300 불변. `time.next_day_requested` 발행 후 `advance(0)` → `day 2`, `phase "day"`, `tick_in_day 0`, `tick 3300`, `speed 1`; 이벤트 `time.day_started {day:2}` → `time.phase_changed {close→day, day:2, tick:3300}` → `time.speed_changed {speed:1, from:0, cause:"phase_enter"}` 순서. 이어서 `advance(1)` → `tick 3301` (#세션-구간, E8) |
| AC4 | `test_tick.gd::test_next_day_ignored_outside_close` (SE-006 추가) | day·evening·show 에서 `time.next_day_requested` → `advance(0)` 후 상태 해시 불변, 시간 이벤트 0개 (#세션-구간) |
| AC5 | `test_tick.gd::test_speed_allowed_per_phase` | 4구간 × 요청 0~3: `∈ speeds`이고 현재와 다르면 적용 + `time.speed_changed {cause:"requested"}` 1회, 현재와 같으면 이벤트 0개, `∉ speeds`면 거부 (#배속 요청 처리 표) |
| AC5 | `test_tick.gd::test_speed_rejected_keeps_state` | show 에서 0/2/3 → `time.speed_rejected {reason:"not_allowed", phase:"show"}`, `"fast"`·1.5·키 없음 → `reason:"invalid"`. 요청 전후 상태 해시 동일 (#배속) |
| AC5 | `test_tick.gd::test_speed_clamped_on_phase_enter` | 클램프 표 전 행: day 3배속 → evening 진입 시 1(`cause:"phase_enter"`), day 2 → 1, show 진입 1 유지(이벤트 없음), close 진입 → 0, 다음 날 → 1 (#배속 클램프 표) |
| AC6 | `test_tick.gd::test_step_accumulator_by_speed` | day 에서 배속 1: `step(0.1)`×100 → 100틱. 배속 3 → 300틱. 배속 0 → 0틱. 새 루프 둘에서 `step(0.05)`×2 와 `step(0.1)`×1 의 상태 해시 동일 (#배속 누적기) |
| AC6 | `test_tick.gd::test_step_caps_and_discards` (SE-006 추가) | 배속 1에서 `step(10.0)` → 30틱(`max_ticks_per_step`) 그리고 이어진 `step(0.0)` → 0틱. day 끝 3배속에서 큰 `step`이 evening 진입(3→1)에서 멈추고 남은 몫을 버림. close 진입 시 멈춤 (#배속 S5·S6) |
| AC7 | `test_tick.gd::test_commands_applied_at_tick_boundary` | 틱 5 의 `tick.advanced` 핸들러가 `time.speed_requested {speed:2}` 발행. (a) `advance(10)`: 핸들러 안에서 `speed` 아직 1, 이벤트 열에서 `time.speed_changed`가 `tick.advanced {tick:5}` 뒤·`tick.advanced {tick:6}` 앞. (b) 새 루프 `advance(5)`: 반환 뒤 `speed` 1, `bus.get_pending_commands()` 1개 → `advance(0)` 뒤 `speed` 2, 0개 (#명령-큐와-틱-순서) |
| AC7 | `test_tick.gd::test_systems_updated_in_config_order` (SE-006 추가) | 가짜 시스템을 `reputation`, `build`, `audience` 순서로 등록 → 매 틱 호출 순서 `build, audience, reputation`, 모두 해당 틱의 `tick.advanced` 이전, `ctx`가 틱 시작 시점 값. `system_order`에 없는 id·중복 등록은 `false` (#명령-큐와-틱-순서) |
| AC7 | `test_tick.gd::test_commands_applied_while_paused` (SE-006 추가) | 배속 0에서 `test.ping_requested` 구독자와 `time.speed_requested {1}`: `advance(0)`/`step(0.016)` 시 명령은 적용되고 `tick` 불변. 이어진 호출부터 틱 진행 (#배속, PRD 접근성) |
| AC8 | `test_event_bus.gd::test_delivery_in_subscription_order` | 구독자 3개가 구독 순서대로 호출, 중복 구독 무시 (E1) |
| AC8 | `test_event_bus.gd::test_nested_publish_is_queued_fifo` | 핸들러 안에서 `test.b`, `test.c` 발행 → 현재 이벤트의 남은 구독자가 먼저, 그다음 `b`, `c` 순서. 핸들러 실행이 겹치지 않음(깊이 카운터 ≤ 1) (E2, E3) |
| AC8 | `test_event_bus.gd::test_unsubscribe_stops_delivery` | `unsubscribe` 후 호출 0회. 디스패치 중 해지는 다음 이벤트부터 (E1) |
| AC8 | `test_event_bus.gd::test_rejects_object_payload` | 값에 `RefCounted.new()`, `Vector2()`, `Callable`, 중첩 배열 안의 `Object` → `false`, 구독자 호출 0회 (E4) |
| AC8 | `test_event_bus.gd::test_commands_deferred_until_dispatch` (SE-006 추가) | `test.x_requested` 발행 → 구독자 0회 → `dispatch_commands()` 반환 1, 구독자 1회. 전달 중 발행한 명령은 이번 호출에 전달되지 않고 다음 호출에 전달 (#명령-큐와-틱-순서) |
| AC9 | `test_rng.gd::test_same_seed_same_sequence` | 시드 42 두 인스턴스 `stream("audience").randi()` 10,000회 일치 |
| AC9 | `test_rng.gd::test_different_seed_differs` | 시드 42 vs 43 첫 100개 중 하나 이상 다름 |
| AC9 | `test_rng.gd::test_streams_independent` | `audience` 1,000회 소비 여부와 무관하게 `events`의 다음 값 동일. `rng_streams`에 스트림을 하나 더한 설정에서도 기존 스트림 열 동일 |
| AC9 | `test_rng.gd::test_state_roundtrip` | `get_state()` → JSON 왕복 → 새 인스턴스 `set_state()` 후 이어지는 100개 일치. 상태 값이 `String` |
| AC9 | `test_rng.gd::test_derived_seed_vectors` (SE-006 추가) | `derive_seed`가 #결정성과-rng 검증 벡터 8개와 일치. 모르는 스트림 이름 → `null` + 오류 |
| AC10 | `test_tick.gd::test_snapshot_restore_equivalence` | 시드 42, `advance(1000)` + `audience` 10회 소비 + `time.speed_requested {3}` 발행(미적용) → `snapshot()`이 #스냅샷 표의 9개 키만 기본형으로 가짐 → JSON 왕복 → 다른 시드로 만든 루프에 `restore` → 양쪽 `advance(1500)` → 상태 해시 동일 |
| AC10 | `test_tick.gd::test_snapshot_rejected_mid_tick` | `tick.advanced` 핸들러 안과 가짜 시스템 `update` 안의 `snapshot()`이 `{}` + `push_error`. 핸들러 안 `restore()`·`advance()`는 `false`/0 |
| AC10 | `test_tick.gd::test_restore_rejects_bad_snapshot` (SE-006 추가) | `schema_version` 불일치, I1 위반(`tick` 조작), 모르는 `phase` → `false`, 상태 불변 |
| AC11 | `replay/test_replay_tick.gd::test_two_runs_identical` | 아래 리플레이 스크립트. 실행 A(`advance`를 목표까지 한 번에)와 B(`advance(37)` 반복)의 최종 상태 해시·이벤트 열·뽑은 난수 열이 완전히 같음. 기대 최종 상태와 이벤트 개수도 단언 |
| AC12 | `test_core_boundary.gd::test_core_has_no_node_or_direct_random` | `project/core/**/*.gd`에 `extends Node`, `_process(`, `_physics_process(`, `get_node(`, `Time.` 0건. `randi(`/`randf(`/`randomize(`/`RandomNumberGenerator`는 `rng.gd`에만. 모든 클래스가 `class_name` + `RefCounted`/`Resource` |
| AC13 | (테스트 아님) qa 실행 로그 | `tools/run_tests.sh project/tests/sim` 녹색, `python3 tools/validate_data.py --strict` 통과 |
| AC14 | (테스트 아님) reviewer 대조 | 코드의 이벤트 이름이 전부 `events.md` 표에 있음(`test.` 접두어 제외, E9) |

**리플레이 스크립트 (AC11).** 시드 42. 기록기는 `tick.advanced`, `time.phase_changed`, `time.day_started`, `time.speed_changed`, `time.speed_rejected`를 구독해 `[이름, 페이로드]`를 쌓고,
`tick.advanced`마다 `rng.stream("events").randi()`를 1회 뽑아 따로 쌓는다(상태에 RNG 를 섞기 위한 의도적 소비).
`run_to(T)` = `tick < T`인 동안 `advance(T − tick)`(B 는 `advance(min(37, T − tick))`)을 반복, 반환 0 이면 중단.

| # | 동작 | 기대 |
|---|---|---|
| 1 | 경계 0 에서 `time.speed_requested {3}` | 다음 호출에서 1→3 |
| 2 | `run_to(1000)`, `time.speed_requested {2}` | 3→2 |
| 3 | `run_to(1800)`, `time.speed_requested {2}` | evening 진입 시 2→1(`phase_enter`), 요청은 `speed_rejected {reason:"not_allowed", phase:"evening"}` |
| 4 | `run_to(2000)`, `time.speed_requested {0}`, `advance(100)` | 반환 0, `tick 2000`, 1→0 |
| 5 | `time.speed_requested {1}` | 0→1 |
| 6 | `run_to(2500)`, `time.speed_requested {0}` | `speed_rejected {reason:"not_allowed", phase:"show"}` |
| 7 | `run_to(3300)`, `time.next_day_requested {}` | close 진입 1→0, 다음 날 day 2, 0→1 |
| 8 | `run_to(3400)`, `time.speed_requested {3}` | 1→3 |
| 9 | `run_to(6600)`, `time.next_day_requested {}` | evening 진입 3→1, close 1→0, day 3 0→1 |
| 10 | `run_to(7100)` 후 `advance(0)` | 최종: `tick 7100`, `day 3`, `phase "day"`, `tick_in_phase 500`, `speed 1`, `pending_commands []` |

기대 이벤트 개수: `tick.advanced` 7,100, `time.phase_changed` 8, `time.day_started` 2, `time.speed_changed` 11, `time.speed_rejected` 2. 시드 43 으로 같은 스크립트를 돌리면 `rng`가 다르다(이벤트 열의 시간 이벤트는 같다).

## 테스트 방법

- 데이터: `python3 tools/validate_data.py --strict` — `sim.json` v2 가 스키마(version `enum [2]`)를 통과.
- 헤드리스(SE-001 이 작성): `tools/run_tests.sh project/tests/sim` — `test_sim_config.gd`, `test_event_bus.gd`, `test_rng.gd`, `test_tick.gd`, `test_core_boundary.gd`, `replay/test_replay_tick.gd`. 케이스는 위 수용 기준 표.
- 로컬에 Godot 이 없으면 `SKIP` → PR 의 CI(`godot-tests`)로 대신한다.
- 스펙 자체의 판정: producer 가 SE-001 AC1~AC14 와 위 표를 대조, reviewer 가 `events.md`와 이 문서의 이벤트 이름 대조(`docs/reviews/SE-006.md`).

## 열린 질문

사람 결정 항목. producer 가 `docs/status/`로 옮긴다. 추천안은 이미 `sim.json`에 반영된 현재 값이다(바꾸면 데이터만 바꾸면 되는 항목과 ADR 이 필요한 항목을 구분).

| # | 질문 | 선택지 | 추천 | 바꾸면 |
|---|---|---|---|---|
| Q1 | 저녁(개장) 구간 2배속 허용? 현재 `[0, 1]` | (a) 유지 `[0,1]` (b) `[0,1,2]` (c) `[0,1,2,3]` | **(a)** PRD 세션 표가 저녁을 "실시간"으로 정했고, 입장 흐름 관찰·긴급 대응 구간이다. 봇 통계에서 저녁이 지루하다는 근거(이탈·무조작 비율)가 나오면 (b) 재검토 | `speeds` 변경 = PRD 결정 변경 → ADR |
| Q2 | 공연 중 일시정지 불가 유지? 현재 `pausable: false`, `[1]` | (a) 유지 (b) `[0,1]`로 허용 (c) 접근성 설정 토글(기본 꺼짐)로만 허용 | **(a)** v0 유지. 공연은 90초로 짧고 실시간 긴장이 핵심. 단 PRD 접근성("일시정지 중 모든 조작 가능")과 충돌 소지가 있어 버티컬 슬라이스 접근성 검토 때 (c)를 후보로 | (b) ADR, (c) 설정을 명령으로 기록하는 별도 티켓 |
| Q3 | close 에서 다음 날로 가는 방식 | (a) `time.next_day_requested` 명령 대기(현재) (b) N초 뒤 자동 (c) 설정으로 선택 | **(a)** close 는 리포트 화면이고 홀드가 오토세이브·정산 시점을 고정한다. 봇은 명령 한 줄로 넘긴다 | (b)/(c) 실시간 타이머는 `step()` 밖의 개념이라 sim 규칙 추가 필요 |
| Q4 | 새 날 시작 배속 | (a) 1 (현재, `force`) (b) 0 — 일시정지로 시작해 준비 (c) 전날 낮 배속 기억 | **(a)** SE-001 AC2 가 "새 게임 `advance(1)` → tick 1"을 전제한다. (c)는 상태 필드 1개 추가로 가능하니 플레이테스트 후 결정 | (b) `default_speed` 0 으로 데이터만, 단 AC2 테스트가 배속 요청을 먼저 보내도록 수정 |
| Q5 | `step()` 1회 상한 `max_ticks_per_step` | 10 / **30** / 90 | **30** 3배속 실시간 1초분. 프레임 끊김 뒤 몰아치기(스파이럴) 방지, 초과분은 버린다 | 데이터만 |
| Q6 | E7(`tick.advanced` 구독자는 상태 이벤트 금지)을 규약으로 둘지 버스가 강제할지 | (a) 리뷰 규약 (b) 버스가 `tick.advanced` 디스패치 중 상태 이벤트 발행을 거부 | **(a)** v0. 위반 사례가 리뷰에서 2회 이상 나오면 (b) | producer 판단(사람 결정 불요) |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-09 | tick.md v0 | SE-006 | 신규 작성 |
| 2026-10-09 | `sim.json` v1 → v2, `sim.schema.json` version 2 | SE-006 | 필드 추가: `max_ticks_per_step`(30), `snapshot_schema_version`(1), `rng_streams`, `system_order`, `phases[].default_speed`, `phases[].enter_speed_mode`. 스키마: 새 필드 필수화, `version` `enum [2]`, `phases` `maxItems 4`, `speeds` `minItems 1`·`uniqueItems`. **기존 값(10 tick/s, 1,800/600/900/0, 허용 배속, pausable)은 변경 없음** |
