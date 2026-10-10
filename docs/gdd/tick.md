# 틱·세션 구간·배속·결정성 (tick.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-006 (game-designer), SE-011 (시스템 스냅샷 훅 — #명령-큐와-틱-순서 "시스템 등록", #스냅샷), SE-057 (#세이브-설정-savejson) |
| 구현 티켓 | SE-001 (sim-engineer) — `project/core/{sim_config,event_bus,rng,tick}.gd`. SE-012 (sim-engineer) — `tick.gd` 시스템 스냅샷 훅 |
| 데이터 | [`project/data/sim/sim.json`](../../project/data/sim/sim.json) (version 3. SE-011 결정, 적용됨(SE-012) — #수치표), 스키마 [`sim.schema.json`](../../project/data/schemas/sim.schema.json) · [`project/data/save/save.json`](../../project/data/save/save.json) (version 1, SE-057 — #세이브-설정-savejson), 스키마 [`save.schema.json`](../../project/data/schemas/save.schema.json) |
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
| 1 | `speed` 키가 없거나 값이 `int`가 아님(문자열·`bool`·`null` 등). `float`(`2.0`·`1.5` 모두)는 버스가 먼저 거부한다(E4: `publish()`가 `false` + `push_error`, 큐잉 안 함) — 핸들러 도달 없음, 이 표의 어느 행에도 오지 않고 이벤트도 없다 | 불변 | `time.speed_rejected {speed: <받은 값 또는 null>, reason:"invalid", phase}` |
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
| S4 | 포화(SE-007): `k = s0 × ticks_per_second`, `sat_s = ⌈max_ticks_per_step ÷ k⌉` 일 때 `delta_s > sat_s` 이면 `delta_s = sat_s + (delta_s mod 1)` (정수 초만 잘라 int64 오버플로를 막고, 소수부를 남겨 S5 의 `budget`·잔여 `acc` 가 자르지 않은 계산과 같다). 그 뒤 `us = max(0, roundi(delta_s × 1,000,000))`, `acc += us × k` |
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

**시스템 등록.** `TickLoop.register_system(id: String, update: Callable, snapshot_hook: Callable = Callable(), restore_hook: Callable = Callable()) -> bool` (SE-011 확장).
기존 2인자 호출 `register_system(id, update)`는 그대로 유효하고, 그렇게 등록한 시스템은 "훅 없는 시스템"(스냅샷에 항목 없음)이 된다. 훅을 주고 등록한 시스템을 이하 "훅 시스템"이라 한다. D1~D7 은 docs/tickets/SE-011.md 의 결정 항목 번호다.

| 인자 | 호출 형태 | 불리는 곳 |
|---|---|---|
| `update` | `update.call(ctx: Dictionary)`, 반환값 무시 | 한 틱의 단계 2 |
| `snapshot_hook` | `snapshot_hook.call() -> Dictionary` (인자 없음) | `snapshot()` 2단계, `restore()` 6단계(사전 스냅샷) |
| `restore_hook` | `restore_hook.call(d: Dictionary) -> bool` | `restore()` 7단계(적용, 롤백) |

검사는 위 행부터 하고 처음 걸린 행에서 멈춘다. 실패하면 `push_error` 정확히 1회, `false`이고 아무것도 등록되지 않는다(그래서 이어지는 정상 호출은 G3 에 걸리지 않는다).

| # | 규칙 | 실패 시 |
|---|---|---|
| G1 | 재진입 아님: `advance`/`step` 실행 중, 버스 디스패치 중, 시스템 훅 실행 중(SH5)에는 등록 불가 | `push_error`, `false` |
| G2 | `id ∈ sim.json.system_order` | 〃 |
| G3 | 같은 id 두 번 등록 불가. 훅만 나중에 덧붙이는 재등록도 불가(훅이 있는 시스템은 처음부터 네 인자로 등록한다) | 〃 |
| G4 | `update.is_valid()` | 〃 |
| G5 | 훅은 둘 다 주거나 둘 다 비운다: `snapshot_hook.is_null() == restore_hook.is_null()`. 하나만 주면 실패. "비운다" = 기본값 `Callable()` | 〃 |
| G6 | 훅을 줬으면 둘 다 `is_valid()`. 예: `Callable(obj, "없는_메서드")`, 해제된 객체의 메서드 | 〃 |
| — | `update`·`snapshot_hook`·`restore_hook` 모두 `system_order` 순서로 불린다. 등록 순서와 무관 | — |

예: 경제는 `loop.register_system("economy", economy.update, economy.snapshot, economy.restore)` (economy.md #정산 "틱 업데이트·등록").

결정 근거(SE-011 D1): 덕 타이핑(`register_system(id, system: Object)` + `has_method("snapshot")`) 대신 선택 인자 Callable 을 쓴다.
기존 호출(`test_tick.gd`의 2인자 등록)이 그대로 돌고, `TickLoop`이 시스템 클래스에 결합하지 않고, 테스트용 가짜 시스템을 `bind()`한 Callable 로 만들 수 있다.
덕 타이핑에서는 메서드 이름 오타가 조용히 "훅 없음"이 된다. G5·G6 은 그런 실수를 등록 시점에 `false`로 드러낸다.
인자 이름은 티켓 초안의 `snapshot`/`restore` 대신 `snapshot_hook`/`restore_hook`으로 정했다. `TickLoop`의 같은 이름 메서드를 가리는(shadowing) GDScript 경고를 피하려는 것이고, 위치 인자라 호출 형태는 같다.

**시스템 훅 규약.** `TickLoop`이 강제하는 것과 리뷰 규약을 나눈다(결정 근거 SE-011 D3·D6).

| # | 규약 | 강제 |
|---|---|---|
| SH1 | `snapshot_hook`은 시스템 상태를 바꾸지 않는다. 같은 상태에서 두 번 부르면 같은 값을 돌려준다 | 리뷰 규약. 테스트: 두 번 호출한 `snapshot()` 해시 동일 |
| SH2 | `snapshot_hook`의 반환값은 `Dictionary`이고 그 안은 E4 기본형 규칙을 따른다(키 `String`/`StringName`, 값 `null`/`bool`/`int`/`float`/`String`/`StringName`/`Array`/`Dictionary`, 재귀). 시스템 상태의 숫자는 `int`로 두기를 권장한다(economy R1). `float`는 검사를 통과하지만 SH6 을 지킬 책임이 시스템에 있다 | `TickLoop`: 위반이면 `snapshot()`이 `push_error` 후 `{}` (D3, 시끄럽게 실패) |
| SH3 | `restore_hook(d)`는 `d`를 전부 검사한 뒤 적용한다. 실패하면 `false`를 돌려주고 **자기 상태를 바꾸지 않는다**(시스템 쪽 원자성). `d`는 JSON 왕복을 거쳐 정수가 `float`로 와 있을 수 있으므로 정수 필드는 시스템이 `int`로 정규화한다. 자기 `snapshot_hook`이 낸 값은 왕복 전·후 모두 반드시 받아들인다(`true`). 이것이 `restore()` 롤백(7단계)의 전제다 | 리뷰 규약. 테스트: 각 시스템의 스냅샷 왕복 케이스(economy EC16) |
| SH4 | 훅은 이벤트를 발행하지 않고, 난수를 뽑지 않고, 다른 시스템을 호출하지 않는다(원칙 4) | 리뷰 규약(`TickLoop`은 막지 않는다) |
| SH5 | 훅 안에서 `TickLoop`의 `advance`/`step`/`snapshot`/`restore`/`register_system`을 부르면 재진입으로 거부된다(`push_error`, 실패 값). `TickLoop`은 훅을 부르는 동안 자신을 "실행 중"으로 표시한다(`advance`와 같은 플래그) | `TickLoop` |
| SH6 | 상태 해시 동치: `restore_hook(JSON 왕복(snapshot_hook()))` 뒤에 부른 `snapshot_hook()`이 `JSON.stringify(…, "", true)` 기준으로 원래 값과 같다 | 각 시스템 스냅샷 테스트 |
| SH7 | 훅은 틱 경계에서만 불린다(`snapshot()`/`restore()`가 경계에서만 허용되므로). `TickLoop`은 `snapshot_hook` 결과를 깊은 복사해 담고 `restore_hook`에는 깊은 복사본을 넘긴다(시스템과 스냅샷이 참조를 공유하지 않는다) | `TickLoop` |

v0 `system_order`: `build → staff → artist → audience → show → crisis → economy → reputation` (입력을 만드는 시스템이 먼저, 결과를 합산하는 시스템이 나중). SE-001 은 시스템을 하나도 등록하지 않는다(테스트용 가짜 시스템만). SE-012 부터 economy 가 훅과 함께 등록된다.
시스템은 이벤트 구독도 `system_order` 순서로 생성·구독한다(구독 순서가 전달 순서이고 결정성의 일부다). sim 시스템은 `tick.advanced`를 구독하지 않는다(업데이트는 단계 2로).

**재진입 금지.** `advance`/`step`/`snapshot`/`restore`/`register_system`은 `TickLoop`이 실행 중(틱 처리 중, 또는 `snapshot()`/`restore()`가 시스템 훅을 부르는 중 — SH5)이거나 버스가 디스패치 중(=어떤 핸들러 안)이면 `push_error` 후 실패 값(0 / `{}` / `false`)을 돌려준다.

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
| | `static is_valid_value(v: Variant, allow_float: bool) -> bool` | E4 기본형 검사(재귀). 키는 `String`/`StringName`, 값은 `null`/`bool`/`int`/`String`/`StringName`/`Array`/`Dictionary`이고 `allow_float`가 `true`면 `float`도 허용. 상태를 바꾸지 않고 오류를 내지 않는다. `TickLoop`이 `snapshot_hook` 반환값 검사(SH2)에 `allow_float = true`로 쓴다 |
| `SeededRng` | `new(master_seed: int, stream_names: Array[String])`, `static derive_seed(master_seed, name) -> int` | |
| | `stream(name) -> RandomNumberGenerator`, `get_state() -> Dictionary`, `set_state(d) -> bool` | |
| `TickLoop` | `new(config: SimConfig, seed: int, bus: EventBus = null)` | `bus`가 `null`이면 자체 생성. 생성자는 이벤트를 내지 않는다. `time.speed_requested`, `time.next_day_requested`를 구독 |
| | `tick`, `day`, `phase: String`, `tick_in_day`, `tick_in_phase`, `speed`, `bus`, `rng` | 읽기 전용 |
| | `advance(n: int) -> int`, `step(delta_s: float) -> int` | `n < 0`은 0 으로 취급 |
| | `register_system(id: String, update: Callable, snapshot_hook: Callable = Callable(), restore_hook: Callable = Callable()) -> bool`, `snapshot() -> Dictionary`, `restore(s: Dictionary) -> bool` | 등록 규칙 G1~G6, 훅 규약 SH1~SH7(#명령-큐와-틱-순서 "시스템 등록", SE-011). 스냅샷 최상위 10개 키, restore 1~9단계(#스냅샷) |

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
| `audience` | audience | 단계 2(유입·취향·이동 선택), 단계 4(`artist.lineup_set` 핸들러 — 저녁 진입 입장 결정, [audience.md](audience.md) R2) |
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

`TickLoop.snapshot() -> Dictionary`. 값은 전부 기본형(`int`, `String`, `bool`, `Array`, `Dictionary`, `null`. `systems` 항목 안은 SH2 에 따라 `float`도 가능)이고 JSON 왕복(`stringify → parse_string`) 후 `restore()`해도 같은 상태가 된다.
최상위 키는 **항상 10개**다: 시간·RNG·명령 큐 9개 + 시스템 상태 묶음 `systems` 1개(SE-011). 경제·관객 등 시스템 상태는 최상위 키를 더하지 않는다. 각 시스템이 훅을 등록하면(#명령-큐와-틱-순서 "시스템 등록") `systems.<id>` 항목으로 들어간다. 그래서 시스템이 늘어도 최상위 키 개수는 10 이다.

| 키 | 타입 | 값 |
|---|---|---|
| `schema_version` | int | `sim.json.snapshot_schema_version` (= 2. SE-011 결정, 적용됨(SE-012)) |
| `seed` | int | 마스터 시드 |
| `tick` | int | 경계 상태 |
| `day` | int | 경계 상태 |
| `phase` | String | `"day" \| "evening" \| "show" \| "close"` |
| `tick_in_phase` | int | 경계 상태 (`tick_in_day`는 파생이라 넣지 않는다) |
| `speed` | int | 0~3 |
| `rng` | Dictionary | `{<스트림 이름>: "<state 10진 문자열>"}`, `rng_streams` 전부 |
| `pending_commands` | Array | `[{name: String, payload: Dictionary}, …]` 큐 순서 그대로. 보통 `[]` |
| `systems` | Dictionary | `{<시스템 id>: Dictionary}`. 훅(`snapshot_hook`/`restore_hook`)을 등록한 시스템만 들어가고, 키 삽입 순서는 `system_order` 순이다(등록 순서 무관). 훅 없는 시스템은 키가 없다. 훅 시스템이 하나도 없으면 `{}`(키 자체는 항상 있다). 값은 그 시스템 `snapshot_hook()` 반환값의 깊은 복사본이다. 반환값이 `Dictionary`가 아니거나 SH2 를 어기면 `snapshot()` 전체가 `push_error` 후 `{}`다 (SE-011 D2·D3) |

`pending_commands`는 SE-006 이 SE-001 AC10 의 괄호 목록에 **추가**한 필드다(이유: 마지막 틱의 핸들러나 UI 가 보낸 명령이 세이브에서 사라지면 복원 후 진행이 연속 진행과 달라진다). SE-001 은 AC10 의 목록 대신 이 표를 쓴다.
`step()` 누적기 `acc`와 구독자 목록은 상태가 아니므로 넣지 않는다.

**허용 시점.** 경계 상태에서만. `advance`/`step` 실행 중(시스템 `update` 안 포함), 시스템 훅 실행 중(SH5)이거나 버스 디스패치 중(어떤 핸들러 안)이면 `push_error` 후 `{}`를 돌려준다.

**`snapshot()` 절차.**

| 단계 | 동작 | 실패 시 |
|---|---|---|
| 1 | 재진입 검사(허용 시점) | `push_error`, `{}` |
| 2 | "실행 중" 표시(SH5). 훅을 등록한 시스템마다 `system_order` 순으로 `snapshot_hook()`을 부르고 검사한다: 훅이 지금 `is_valid()`가 아님, 반환값이 `Dictionary`가 아님, SH2 위반. 통과한 값은 깊은 복사해 `systems[id]`에 넣는다 | 첫 위반에서 `push_error`(시스템 id 포함) 정확히 1회. 뒤 시스템의 훅은 부르지 않는다. 표시 해제, `{}` |
| 3 | 표시 해제. 최상위 10개 키를 돌려준다 | — |

결정 근거(SE-011 D3): 문제 시스템만 빼고 돌려주는 부분 스냅샷은 그 시스템 상태가 세이브에서 조용히 사라지므로 택하지 않았다. 전체 실패 `{}`는 기존 재진입 실패 값과 같아서 호출자(세이브)가 처리할 경우가 하나뿐이다.

**`restore(s) -> bool`.** 1~6단계는 검사(6단계는 시스템 상태를 읽기만 함), 7·8단계가 적용이다. 각 검사 단계에서 처음 걸린 조건 하나로 실패하고 **`TickLoop` 자신의** `push_error`는 정확히 1회다. 하위 구성 요소가 내는 `push_error`(4(b) `SeededRng.set_state`, 6·7단계 시스템 `snapshot_hook`·`restore_hook` 자신)와 7단계 롤백 실패분은 별도로 더해진다(예: `rng` 상태 오류 = `SeededRng` 1 + `TickLoop` 1 = 2회, `Economy` 복원 실패 = 시스템 1 + `TickLoop` 1 = 2회). 세는 법은 아래 "`push_error` 횟수 (SE-017)".

| 단계 | 구분 | 검사·동작 | 실패 시 |
|---|---|---|---|
| 1 | 검사 | 재진입 아님(허용 시점과 같은 조건) | `push_error`, `false`, 상태 불변 |
| 2 | 검사 | `s.schema_version == snapshot_schema_version`. `systems` 키가 없는 v1 스냅샷은 여기서 거부된다. 세이브 파일이 아직 없으므로 마이그레이션은 만들지 않는다(후속 세이브 티켓) | 〃 |
| 3 | 검사 | 숫자 필드(`seed`·`tick`·`day`·`tick_in_phase`·`speed`)는 `int`, 또는 정수값인 `float`(JSON 왕복 산물)를 `int`로 정규화. 그 밖의 값이면 실패. `seed` 0~2^31−1(2,147,483,647), `phase`가 유효, `day ≥ 1`, I1·I3·I4(`speed ∈ phases[phase].speeds`) 성립, `rng`가 Dictionary | 〃 |
| 4 | 검사 | (a) `pending_commands` 정규화·형식 검사: 페이로드 안(재귀, 배열·중첩 Dictionary 포함)의 정수값인 `float`를 `int`로 정규화한다(`EventBus.normalize_commands`). 명령 페이로드 숫자는 원래 `int`뿐이므로(E4) 손실 없는 역변환이다. 정수가 아닌 `float`(예: `1.5`)나 형식 오류(원소가 `{name, payload}`가 아님, 이름이 `*_requested`가 아님, 페이로드가 E4 위반)가 하나라도 있으면 실패. (b) `rng` 상태 형식 검사: `seed`로 **새** `SeededRng`을 만들어 `rng` 상태를 적용해 본다(현재 `rng`는 그대로). 스냅샷에 없는 스트림(데이터에 새로 추가된 것)은 새 파생 시드에서 시작하고, 데이터에 없는 스트림은 `push_warning` 후 무시한다. `SeededRng.set_state`가 `false`면 실패다: 스트림 이름이 문자열이 아니거나 값이 10진 정수 문자열이 아닌 항목이 하나라도 있을 때이고, 이때 `set_state` 자신이 `push_error` 1회를 낸다. 값 형식 검사가 스트림 이름 확인보다 먼저라 데이터에 없는 스트림이라도 값이 틀리면 실패다(SE-017 명문화, 현 구현 그대로). 마지막으로 새 `SeededRng`의 스트림 목록(`stream_names`, 이름·순서)이 현재 `rng`의 것과 다르면 실패다(SE-052 — 8(b) 의 상태 적용이 실패할 수 없게 하는 사전 검사. 둘 다 `sim.json` `rng_streams`로 만들므로 정상 경로에서는 도달하지 않는다) | 〃 (`push_error` 합계: `set_state` 실패 2회 = `SeededRng` 1 + `TickLoop` 1, 스트림 목록 불일치 1회 = `TickLoop` 1) |
| 5 | 검사 | `systems` (SE-011 D5): ① `Dictionary`여야 한다(키 없음·`Array` 등은 실패). ② 모든 값이 `Dictionary`여야 한다(id 등록 여부와 무관). ③ 훅을 등록한 시스템마다 `systems`에 항목이 있어야 한다(없으면 상태 불완전 → 실패). ④ 훅을 등록한 시스템의 두 훅이 지금도 `is_valid()`. ⑤ 훅 시스템이 아닌 id(`system_order` 밖, 미등록, 훅 없이 등록)의 항목은 id 마다 `push_warning` 1회 후 무시한다(4단계 "데이터에 없는 스트림"과 같은 결). 경고는 실패가 아니다 | `push_error`, `false`, 상태 불변 |
| 6 | 검사(사전 스냅샷) | "실행 중" 표시(SH5). 훅 시스템마다 `system_order` 순으로 `prev[id] = snapshot_hook()`을 받아 `snapshot()` 2단계와 같은 검사를 한다. 아직 어떤 시스템도 복원하지 않았다 | `push_error`, 표시 해제, `false`, 상태 불변 |
| 7 | 적용(시스템) | 훅 시스템마다 `system_order` 순으로 `restore_hook(systems[id]의 깊은 복사본)`. 반환이 `true`면 다음 시스템. `false`(또는 `bool`이 아닌 값)면: `push_error`(시스템 id 포함) 1회 → 이 단계에서 이미 성공한 시스템을 **역순**으로 `restore_hook(prev[id]의 깊은 복사본)`으로 되돌린다 → 표시 해제, `false`. 실패한 시스템 자신은 SH3 에 따라 바뀌지 않았으므로 되돌리지 않는다. 롤백의 `restore_hook`이 `false`면 그 시스템마다 `push_error` 1회를 더하고 남은 롤백을 계속한다(복구 불능, 아래) | `push_error`, `false`. 시스템 상태 원복, `TickLoop` 필드 불변 |
| 8 | 적용(`TickLoop`) | 순서대로 (a) 버스 명령 큐를 4단계 정규화 목록으로 바꿔 넣기, (b) 카운터·`speed`·`seed` 덮어쓰기, 4단계에서 검증한 시드·상태를 기존 `rng` 객체에 적용(객체 유지 — `rng.assign(new_rng)`. 시스템이 생성자에서 받아 들고 있는 `SeededRng` 참조가 로드 뒤에도 `loop.rng`와 같은 객체여야 한다. 근거 [SE-034-bug](../tickets/SE-034-bug.md), `78de35a`), `acc = 0`. 4단계가 같은 E4 규칙으로 검사를 끝냈으므로 (a)는 실패하지 않는다. 방어 규칙: 그래도 (a)가 실패하면 7단계와 같은 역순 롤백(모든 훅 시스템)을 하고 `push_error`, `false`. (b)는 4(b) 가 스트림 목록 일치까지 검사했으므로 실패하지 않는다(`assign`의 반환값은 버리지 않고 확인한다 — SE-052) | (도달 불가) |
| 9 | 끝 | 표시 해제. 이벤트를 발행하지 않는다. `true` | — |

결정 근거(SE-011 D4): 시스템을 먼저, `TickLoop` 자기 필드(카운터·`seed`·`rng`·명령 큐)를 마지막에 적용한다. 시스템 복원은 실패할 수 있지만 8단계는 실패하지 않기 때문이다. 그래서 7단계 실패 때 되돌릴 대상이 시스템뿐이고, `TickLoop` 필드는 처음부터 바뀌지 않는다.
부분 복원 허용(D4 (b))은 시간은 새 날인데 경제는 옛 날인 식의 섞인 상태를 만들고 "실패 시 상태 불변"을 깨므로 택하지 않았다.
불일치 결정 근거(SE-011 D5): 훅 시스템 항목이 없으면 그 시스템은 새 게임 값으로 남아 시간·RNG 와 어긋난 상태가 되므로 실패다. 모르는 id 는 데이터에서 시스템을 뺀 뒤 옛 스냅샷을 여는 경우라 버려도 남은 상태가 일관된다. 그래서 경고만 한다.

**실패 시 상태 불변 (시스템 상태 포함, 롤백).** 1~6단계는 어떤 상태도 바꾸지 않는다(검사 → 적용). 그래서 1~6단계에서 실패하면 `TickLoop`의 카운터·`seed`·`rng`·명령 큐와 모든 시스템 상태가 그대로다.
7단계에서 시스템 하나가 실패하면 앞서 복원한 시스템을 사전 스냅샷(6단계)으로 역순 롤백한다. 그래서 시스템 상태도 그대로이고, `TickLoop` 필드는 8단계 전이라 그대로다.
"그대로"의 판정은 상태 해시(`JSON.stringify(snapshot(), "", true)`, `systems` 포함)가 `restore()` 호출 전후로 같은 것이다. 롤백 뒤 해시가 같으려면 SH6 이 필요하다.
**복구 불능(예외).** 롤백의 `restore_hook`이 실패하면(SH3 위반, 버그) 그 시스템 상태는 보장하지 않는다. `push_error`로 알리고 반환값은 `false`다. `TickLoop` 필드는 이 경우에도 바뀌지 않는다.

**`push_error` 횟수 (SE-017).** 실패한 `restore()` 한 번이 내는 `push_error` 합계는 다음 셋의 합이다.
- (i) **`TickLoop` 자신의 실패 원인 1회.** `[TickLoop]` 접두의 메시지로 실패한 단계(1~7, 방어 규칙 8(a))를 알린다. 어느 경로든 정확히 1회다. 1단계 재진입 거부, 6단계 사전 스냅샷 위반(`snapshot()` 2단계와 같은 메시지)도 이 1회다.
- (ii) **하위 구성 요소가 스스로 내는 것.** 4(b) `SeededRng.set_state` 실패 1회. 6·7단계에서 시스템 `snapshot_hook`·`restore_hook`이 실패하며 자신이 내는 것(시스템 구현 몫, 0회 이상. `Economy.restore`는 1회 — economy.md #스냅샷). `EventBus.normalize_commands`(4(a))는 `null`만 돌려주고 `push_error`를 내지 않는다.
- (iii) **7단계 롤백 실패분.** 롤백의 `restore_hook`이 `false`인 시스템마다 `TickLoop`이 1회를 더한다(복구 불능). 롤백 대상 훅이 스스로 내는 것은 (ii)에 들어간다.

| 실패 경로 | (i) `TickLoop` | (ii) 하위 구성 요소 | (iii) 롤백 실패 | 합계 | 고정하는 테스트 |
|---|---|---|---|---|---|
| 1단계 재진입 | 1 | 0 | 0 | 1 | `test_snapshot_rejected_mid_tick`, `test_system_hooks_reject_reentry` |
| 2·3단계, 4(a) `pending_commands`, 5단계 | 1 | 0 | 0 | 1 | `test_restore_rejects_bad_snapshot`(5단계 ①②③), `test_restore_rejects_invalid_hook`(5단계 ④ — 훅 객체 해제 뒤 `restore` false, `push_error` 1회 "더 이상 유효하지 않다", TickLoop 필드 불변, `restore_hook` 0회; `snapshot()` 이 `{}` 라 해시 대신 필드 비교) (SE-022 추가) |
| 4(b) `rng` 상태 값 오류(`rng.audience = "x"`) | 1 | 1 (`SeededRng.set_state`) | 0 | **2** | `test_restore_rejects_bad_snapshot` "rng audience x" (SE-017 추가) |
| 4(b) 스트림 목록 불일치(현재 `rng`를 다른 스트림 목록의 `SeededRng`으로 바꿔 끼운 루프) | 1 | 0 | 0 | 1 | `test_tick.gd` 새 케이스(SE-052 B, sim-engineer): `restore` `false`, `push_error` 1회, 상태 해시 불변 |
| 6단계 사전 스냅샷 위반 | 1 | 훅 자신 (가짜 훅 0) | 0 | 1 | `test_system_snapshot_rejects_invalid_hook_return` |
| 7단계 `restore_hook` `false`, 가짜 시스템 | 1 | 0 | 0 | 1 | `test_system_restore_rolls_back_on_failure` (a) |
| 7단계 `restore_hook` `false`, `Economy` | 1 | 1 (`Economy.restore`) | 0 | **2** | economy.md EC16 (c) `TickLoop` 경로(`test_economy.gd::test_snapshot_roundtrip`) |
| 7단계 실패 + 롤백 실패 k 개, 가짜 시스템 | 1 | 0 | k | 1 + k | `test_system_restore_rolls_back_on_failure` (b): k = 1, 누적 +2 |

결정 근거(SE-017, docs/reviews/SE-012.md 발견 5·후속 제안 D): 하위 구성 요소의 `push_error`를 없애거나 `TickLoop`이 삼키게 하면 `SeededRng`·시스템을 단독으로 쓸 때(시스템 단위 테스트, 세이브 로더) 실패 이유가 사라진다. 두 메시지는 "어느 구성 요소의 무엇이 틀렸나"와 "`restore()`가 어느 단계에서 멈췄나"를 따로 알려 정보 손실이 없고, 코드를 바꾸지 않는다. 그래서 규칙은 `TickLoop` 자신 기준으로 세고 합계는 위 표로 고정한다.

복원 후 진행 = 연속 진행: 상태 A 에서 `s = snapshot()` → 새 `TickLoop`에 `restore(s)` → `advance(N)` 결과의 상태 해시(`systems` 포함)가, A 에서 그대로 `advance(N)`한 결과와 같다.
전제: 복원 대상 `TickLoop`에는 같은 시스템이 같은 방식(훅 유무)으로 `restore()` 전에 등록돼 있어야 한다. 훅 시스템이 빠졌으면 5단계 ⑤(경고 후 무시)로, 더 있으면 5단계 ③(실패)으로 드러난다.

**이벤트.** 스냅샷·복원·훅 등록은 이벤트를 내지 않는다. 새 이벤트 없음(SE-011, `events.md` 변경 0). 시스템 훅도 이벤트를 내지 않는다(SH4).

**결정성·리플레이 영향 (SE-011).**
- (i) **리플레이 기준값은 불변이다.** AC11 의 이벤트 개수(`tick.advanced` 7,100, `time.phase_changed` 8, `time.day_started` 2, `time.speed_changed` 11, `time.speed_rejected` 2), 최종 상태(`tick 7100`, `day 3`, `phase "day"`, `tick_in_phase 500`, `speed 1`, `pending_commands []`), 뽑은 난수 열이 그대로다. 근거: 시스템 훅은 이벤트를 내지 않고 난수를 쓰지 않으며(SH4), `snapshot()`/`restore()` 안에서만 불려 한 틱의 단계 1~5 순서를 바꾸지 않는다. 리플레이 스크립트는 시스템을 등록하지 않으므로 그 스냅샷의 `systems`는 `{}`다.
- (ii) **상태 해시 문자열은 바뀐다.** `JSON.stringify(snapshot(), "", true)`에 `"schema_version":2`와 `"systems":{}`(또는 시스템 항목)가 들어간다. 기준 해시 문자열을 저장해 둔 테스트는 없다. 해시 비교는 전부 같은 실행 안에서 두 루프(또는 복원 전후)를 비교하므로 영향이 없다.
- (iii) **바뀌는 테스트 리터럴 3곳**(SE-012 가 `sim.json` v3 적용과 같은 PR 에서 고친다. SE-012 구현 뒤 실제 위치는 4곳 — `test_tick.gd`의 새 케이스 `test_system_snapshot_hooks_included_in_order` 1곳 추가, 줄 번호는 docs/tickets/SE-012.md 결과 절):
  1. `project/tests/sim/test_sim_config.gd:38` — `assert_eq(cfg.snapshot_schema_version, 1)` → 2.
  2. `project/tests/sim/replay/test_replay_qa.gd:131-132` (`test_snapshot_keys_and_values_pinned_to_spec`) — 정렬 키 리터럴 9개 → `systems`를 더한 10개, 값 목록의 `schema_version` `1` → `2`.
  3. `project/tests/sim/test_tick.gd:450-451` (`test_snapshot_restore_equivalence`) — "9개 키만" 메시지와 `keys.size() == 9` → 10. 비교 대상 `TickLoop.SNAPSHOT_KEYS`(구현 상수)도 `systems`를 더한 10개가 된다.
  그 밖의 단언(`test_restore_rejects_bad_snapshot`의 `snapshot_schema_version + 1` 등)은 설정값 상대라 그대로 통과한다.

**오토세이브 시점.** PRD "하루 마감마다" = close 진입 틱이 끝난 경계. 그 틱의 단계 4 에서 `time.phase_changed {to:"close"}`가 나고, close 는 홀드라 `advance`/`step`이 그 경계에서 반환한다(뒤따르는 경계 처리 없음).
세이브 시스템(후속 티켓)은 `time.phase_changed {to:"close"}`를 구독해 플래그만 세우고, 구동기가 `advance`/`step` 반환 뒤 `snapshot()`을 찍는다. 파일 포맷(JSON → gzip)·마이그레이션은 후속 세이브 티켓.

#### 세이브 설정 (save.json)

[`save.json`](../../project/data/save/save.json)(version 1, SE-057)은 슬롯 수와 오토세이브 보관 수만 담는다. 파일 형식(JSON → gzip, SE-036 `SaveFile`)과 스냅샷 버전(`sim.json` `snapshot_schema_version`)은 이 테이블 밖이다. 난수를 쓰지 않고 게임 상태(스냅샷)에 들어가지 않는다 — 값을 바꿔도 상태 해시·리플레이 기준값은 불변이다.

| 필드 | 값 | 범위 | 뜻 |
|---|---|---|---|
| `manual_slots` | 3 | 1~9 | 수동 저장 슬롯 수. 슬롯 이름 `"1"` … `str(manual_slots)`(events.md SN1 형식). 상한 9 는 메뉴 한 화면·한 자리 이름 기준 |
| `autosave_keep` | 3 | 0~99, 0 = 무제한 | 보관할 오토세이브(`autosave_day<N>`) 파일 수 |

| # | 규칙 |
|---|---|
| SV1 | **읽는 쪽.** `GameSession`(core)이 `new_game`·`load_configs` 때 `<data_root>/save/save.json` 을 읽는다. `manual_slots` 는 메뉴(SE-039/SE-040, AC-39d)가 읽는다. 둘 다 읽기 전용 |
| SV2 | **수동 슬롯은 UI 목록일 뿐.** sim 은 `manual_slots` 로 저장·불러오기를 거부하지 않는다(SN1 형식만 검사). 슬롯 수를 줄여도 기존 `"4"` 파일은 지우지 않고, 메뉴에 안 보일 뿐이다 |
| SV3 | **보관 수 적용.** 오토세이브 파일을 쓴 직후(close 홀드 경계, 위 "오토세이브 시점") `autosave_keep > 0` 이면 `autosave_day<N>` 파일을 `N` 오름차순으로 지워 `autosave_keep` 개만 남긴다. 방금 쓴 파일은 가장 큰 `N` 이라 항상 남는다. 수동 슬롯 파일과 그 밖의 파일은 세지도 지우지도 않는다. `autosave_keep == 0` 이면 지우지 않는다. 오토세이브 쓰기가 실패한 경계에서는 지우지 않는다 |
| SV4 | **파일·필드 없음.** `save/save.json` 이 없거나 `autosave_keep` 키가 없으면 무제한(0, SE-036 의 현재 기본과 같음). `manual_slots` 가 없으면 메뉴 기본값(`ui_params.tres`, SE-040 AC-39d) |
| SV5 | **잘못된 값.** `autosave_keep` 이 `int` 가 아니거나 0 미만이면 `push_error` 1회 후 무제한(0) — 잘못된 데이터로 세이브를 지우지 않는 쪽이 안전하다. `manual_slots` 가 `int` 가 아니거나 1 미만이면 메뉴가 SV4 기본값을 쓴다. 스키마(`validate_data.py --strict`)가 CI 에서 먼저 막으므로 런타임 경로는 손상 대비다 |

수용 기준(SE-057): `autosave_keep: 2` 를 주입한 데이터 루트로 3일 진행하면 3일차 close 뒤 `autosave_day1.sav` 가 없고 `day2`·`day3` 이 있다. 데이터 루트에 `save/` 가 없으면 3일 뒤 세 파일이 다 있다. 수동 슬롯 `"1"` 파일은 어느 경우에도 남는다. → `test_game_session.gd`(sim-engineer).

### 이벤트 순서

| # | 규칙 |
|---|---|
| E1 | 같은 이름의 구독자는 **구독한 순서대로** 호출된다. 디스패치 중 `subscribe`/`unsubscribe`는 다음 이벤트부터 반영(진행 중인 이벤트의 호출 목록은 시작 시점 사본) |
| E2 | 디스패치 중(핸들러 안) `publish()`한 상태 이벤트는 즉시 전달되지 않고 버스의 이벤트 큐 끝에 들어간다. 현재 이벤트의 모든 구독자 호출이 끝난 뒤 FIFO 로 전달된다. **재진입 없음** — 핸들러 실행 중에 다른 핸들러가 끼어들지 않는다 |
| E3 | 버스가 쉬고 있을 때의 `publish()`(최외곽)는 그 이벤트와 연쇄된 모든 상태 이벤트가 전달된 뒤 반환한다 |
| E4 | 페이로드는 `Dictionary`. 키는 `String`(또는 `StringName`), 값은 `null`/`bool`/`int`/`float`/`String`/`StringName`/`Array`/`Dictionary`만(재귀). 그 밖(`Object`, `Vector2`, `Callable`, `Packed*Array` 등)이 하나라도 있으면 `push_error`, `false`, 전달·큐잉 안 함. 버스는 페이로드를 깊은 복사해 모든 구독자에게 같은 사본을 준다. 핸들러는 페이로드를 수정하지 않는다(리뷰 규약). **명령 페이로드 숫자는 `int`만(v0).** 명령(`*_requested`) 페이로드 안(재귀)에 `float`가 하나라도 있으면 정수값(`2.0`)이어도 `publish()`가 `push_error` + `false`를 돌려주고 명령 큐에 넣지 않는다. 상태 이벤트는 `float` 허용. 이유: 명령은 `pending_commands`로 스냅샷에 들어가고 JSON 왕복에서 `int`도 `float`로 돌아오므로, 원래 값이 `int`뿐이어야 restore 4단계(SE-011 이전 번호로 5단계)의 정규화가 원본을 손실 없이 되살린다(#스냅샷 "복원 후 진행 = 연속 진행"). 완화(정수값인 `float` 허용 + 정규형 스냅샷)는 기존 호출자를 깨지 않는 방향이라 필요해지면 나중에 한다 |
| E5 | 명령 이벤트(`*_requested`)는 명령 큐로 가서 경계 처리에서 전달된다(#명령-큐와-틱-순서). 경계 처리 안의 명령 하나는 E3 처럼 최외곽 전달로 취급된다 |
| E6 | 상태 이벤트는 그 틱 안에서 발생 순서대로 전달된다. 한 틱의 이벤트 순서 = [단계 1 명령 연쇄] → [단계 2 시스템 순서대로] → [단계 4 `time.phase_changed` → `time.speed_changed`] → [단계 5 `tick.advanced`] |
| E7 | `tick.advanced`는 그 틱에서 `TickLoop`이 마지막으로 발행하는 이벤트다. `tick.advanced` 구독자(view/ui/세이브/테스트 기록기)는 상태 이벤트를 발행하지 않는다(명령만 가능, 다음 경계에서 적용). 위반은 reviewer 반려 대상 |
| E8 | 상태 변경 → 이벤트 순. 한 동작이 여러 이벤트를 낼 때 상태를 먼저 전부 갱신하고 이벤트를 나열된 순서로 낸다. 다음 날: `time.day_started` → `time.phase_changed` → `time.speed_changed`. 구간 진입: `time.phase_changed` → `time.speed_changed` |
| E9 | 이름 접두어 `test.`는 테스트 전용이며 `events.md` 등록 대상이 아니다. 그 외 이름은 전부 `events.md` 표에 있어야 한다 |

## 수치표

모든 수치는 [`project/data/sim/sim.json`](../../project/data/sim/sim.json)(version 3)에 있다. 이 문서의 수치는 그 사본이며 충돌하면 JSON 이 이긴다.
`snapshot_schema_version` 행의 2 는 SE-011 이 결정하고 SE-012 에서 적용됐다(적용됨(SE-012), `sim.json` version 3). 예외 없음.

| 필드 | 값 | 의미 | 변경 |
|---|---|---|---|
| `ticks_per_second` | 10 | 1틱 = 0.1초 게임 시간 | ADR |
| `phases[].ticks` | 1,800 / 600 / 900 / 0 | 구간 길이, 합 3,300 | ADR |
| `phases[].speeds` | [0,1,2,3] / [0,1] / [1] / [0] | 구간별 허용 배속 | ADR(PRD 세션 구조 표) |
| `phases[].pausable` | true / true / false / true | `0 ∈ speeds`의 사본(C5) | speeds 와 함께 |
| `phases[].default_speed` | 1 / 1 / 1 / 0 | 진입·새 게임 배속 (v2 신규) | designer |
| `phases[].enter_speed_mode` | force / keep_if_allowed / keep_if_allowed / force | 진입 클램프 규칙 (v2 신규) | designer |
| `max_ticks_per_step` | 30 | `step()` 1회 상한 (v2 신규) | designer |
| `snapshot_schema_version` | 2 | 스냅샷 `schema_version` (v2 신규). 2 = 최상위 10개 키(`systems` 포함) 형식 | SE-011 결정, 적용됨(SE-012, `sim.json` v3). 이후 변경은 세이브 티켓과 함께(Q7) |
| `rng_streams` | audience, artist, events, economy, world | v0 스트림 (v2 신규) | 추가 자유, 변경·삭제는 리플레이 기준값 갱신 |
| `system_order` | build, staff, artist, audience, show, crisis, economy, reputation | 단계 2 순서 (v2 신규) | designer + 리플레이 기준값 갱신 |

## 수용 기준

SE-001 의 AC 와 1:1 대응하는 테스트 케이스 목록이다. 경로는 전부 `project/tests/sim/` 기준. "SE-006 추가" 표시가 붙은 케이스는 이 문서가 같은 AC 아래에 더한 것으로, SE-001 구현 시 함께 쓴다(producer 가 SE-001 AC 문구에 반영).
SE-001 의 이름을 바꾼 것은 없다. 이벤트 이름도 SE-001 이 쓴 그대로다(`time.day_started`만 신규, `time.speed_changed`는 페이로드에 `from`, `cause` 추가).
`restore()` 관련 행의 `push_error` 횟수는 `assert_push_error_count` 누적값으로 센 **합계**이고, 규칙은 #스냅샷 "`push_error` 횟수 (SE-017)"다. "1회"라고 적힌 행은 하위 구성 요소가 `push_error`를 내지 않는 경로라 합계가 곧 `TickLoop` 자신의 1회다. economy.md EC16 (c) `TickLoop` 경로의 2회(`Economy.restore` 1 + `TickLoop` 1)와 모순이 없다.

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
| AC5 | `test_tick.gd::test_speed_rejected_keeps_state` | show 에서 0/2/3 → `time.speed_rejected {reason:"not_allowed", phase:"show"}`, `"fast"`·키 없음 → `reason:"invalid"`. 요청 전후 상태 해시 동일. `{speed: 1.5}` → `publish()` `false` + `push_error` 1회, 경계 처리(`advance(0)`) 뒤 `time.speed_rejected` 없음(이벤트 0개), 상태 해시 불변 (#배속 요청 처리 1행, E4) |
| AC5 | `test_tick.gd::test_speed_clamped_on_phase_enter` | 클램프 표 전 행: day 3배속 → evening 진입 시 1(`cause:"phase_enter"`), day 2 → 1, show 진입 1 유지(이벤트 없음), close 진입 → 0, 다음 날 → 1 (#배속 클램프 표) |
| AC6 | `test_tick.gd::test_step_accumulator_by_speed` | day 에서 배속 1: `step(0.1)`×100 → 100틱. 배속 3 → 300틱. 배속 0 → 0틱. 새 루프 둘에서 `step(0.05)`×2 와 `step(0.1)`×1 의 상태 해시 동일 (#배속 누적기) |
| AC6 | `test_tick.gd::test_step_saturation_keeps_fraction` (SE-007 추가) | 배속 1에서 `step(10.05)`·`step(1e13 + 0.25)` 각각 30틱 → `step(0.04)` 0틱 → `step(0.01)` 1틱 (소수부 잔여 보존). `replay/test_replay_qa.gd::test_step_int64_overflow_known_bug`: 배속 1·2·3 × delta {3e11…1e300} 에서 `step` = `max_ticks_per_step`, 이어진 `step(0.1)` = 배속 (#배속 S4) |
| AC6 | `test_tick.gd::test_step_caps_and_discards` (SE-006 추가) | 배속 1에서 `step(10.0)` → 30틱(`max_ticks_per_step`) 그리고 이어진 `step(0.0)` → 0틱. day 끝 3배속에서 큰 `step`이 evening 진입(3→1)에서 멈추고 남은 몫을 버림. close 진입 시 멈춤 (#배속 S5·S6) |
| AC7 | `test_tick.gd::test_commands_applied_at_tick_boundary` | 틱 5 의 `tick.advanced` 핸들러가 `time.speed_requested {speed:2}` 발행. (a) `advance(10)`: 핸들러 안에서 `speed` 아직 1, 이벤트 열에서 `time.speed_changed`가 `tick.advanced {tick:5}` 뒤·`tick.advanced {tick:6}` 앞. (b) 새 루프 `advance(5)`: 반환 뒤 `speed` 1, `bus.get_pending_commands()` 1개 → `advance(0)` 뒤 `speed` 2, 0개 (#명령-큐와-틱-순서) |
| AC7 | `test_tick.gd::test_systems_updated_in_config_order` (SE-006 추가) | 가짜 시스템을 `reputation`, `build`, `audience` 순서로 등록 → 매 틱 호출 순서 `build, audience, reputation`, 모두 해당 틱의 `tick.advanced` 이전, `ctx`가 틱 시작 시점 값. `system_order`에 없는 id·중복 등록은 `false` (#명령-큐와-틱-순서). SE-011: 이 케이스는 2인자 호출(훅 없음)이며 확장 뒤에도 **코드 수정 없이** 통과해야 한다(하위 호환, G2·G3) |
| AC7 | `test_tick.gd::test_commands_applied_while_paused` (SE-006 추가) | 배속 0에서 `test.ping_requested` 구독자와 `time.speed_requested {1}`: `advance(0)`/`step(0.016)` 시 명령은 적용되고 `tick` 불변. 이어진 호출부터 틱 진행 (#배속, PRD 접근성) |
| AC8 | `test_event_bus.gd::test_delivery_in_subscription_order` | 구독자 3개가 구독 순서대로 호출, 중복 구독 무시 (E1) |
| AC8 | `test_event_bus.gd::test_nested_publish_is_queued_fifo` | 핸들러 안에서 `test.b`, `test.c` 발행 → 현재 이벤트의 남은 구독자가 먼저, 그다음 `b`, `c` 순서. 핸들러 실행이 겹치지 않음(깊이 카운터 ≤ 1) (E2, E3) |
| AC8 | `test_event_bus.gd::test_unsubscribe_stops_delivery` | `unsubscribe` 후 호출 0회. 디스패치 중 해지는 다음 이벤트부터 (E1) |
| AC8 | `test_event_bus.gd::test_rejects_object_payload` | 값에 `RefCounted.new()`, `Vector2()`, `Callable`, 중첩 배열 안의 `Object` → `false`, 구독자 호출 0회 (E4) |
| AC8 | `test_event_bus.gd::test_commands_deferred_until_dispatch` (SE-006 추가) | `test.x_requested` 발행 → 구독자 0회 → `dispatch_commands()` 반환 1, 구독자 1회. 전달 중 발행한 명령은 이번 호출에 전달되지 않고 다음 호출에 전달 (#명령-큐와-틱-순서) |
| AC8 | `test_event_bus.gd::test_command_payload_numbers_int_only` (SE-008 추가) | 명령 `{v: 1.5}`와 배열 안 정수값 `{cell: [1.0, 2]}` → 각각 `false`, `push_error` 2회, 명령 큐 0개. 명령 `{cell: [1, 2], n: null, s: "a"}` → `true`. 상태 이벤트 `{v: 1.5}` → `true`(float 허용). 명령 큐를 JSON 왕복한 뒤 `EventBus.normalize_commands` 결과가 원본과 같은 해시이고 `cell[0]`의 타입이 `int`. 정수가 아닌 `float`를 담은 목록·명령 이름이 아닌 원소 → `null` (E4, #스냅샷 restore 4단계(SE-011 이전 번호로 5단계)) |
| AC9 | `test_rng.gd::test_same_seed_same_sequence` | 시드 42 두 인스턴스 `stream("audience").randi()` 10,000회 일치 |
| AC9 | `test_rng.gd::test_different_seed_differs` | 시드 42 vs 43 첫 100개 중 하나 이상 다름 |
| AC9 | `test_rng.gd::test_streams_independent` | `audience` 1,000회 소비 여부와 무관하게 `events`의 다음 값 동일. `rng_streams`에 스트림을 하나 더한 설정에서도 기존 스트림 열 동일 |
| AC9 | `test_rng.gd::test_state_roundtrip` | `get_state()` → JSON 왕복 → 새 인스턴스 `set_state()` 후 이어지는 100개 일치. 상태 값이 `String` |
| AC9 | `test_rng.gd::test_derived_seed_vectors` (SE-006 추가) | `derive_seed`가 #결정성과-rng 검증 벡터 8개와 일치. 모르는 스트림 이름 → `null` + 오류 |
| AC10 | `test_tick.gd::test_snapshot_restore_equivalence` | 시드 42, `advance(1000)` + `audience` 10회 소비 + `time.speed_requested {3}` 발행(미적용) → `snapshot()`이 #스냅샷 표의 10개 키(`systems: {}` 포함, 훅 시스템 없음. SE-011 에서 9개 → 10개)만 기본형으로 가짐 → JSON 왕복 → 다른 시드로 만든 루프에 `restore` → 양쪽 `advance(1500)` → 상태 해시 동일 |
| AC10 | `test_tick.gd::test_snapshot_rejected_mid_tick` | `tick.advanced` 핸들러 안과 가짜 시스템 `update` 안의 `snapshot()`이 `{}` + `push_error`. 핸들러 안 `restore()`·`advance()`는 `false`/0 |
| AC10 | `test_tick.gd::test_restore_rejects_bad_snapshot` (SE-006 추가) | `schema_version` 불일치, I1 위반(`tick` 조작), 모르는 `phase`, `pending_commands`에 `{speed: 1.5}`(SE-008 추가) → 각각 `false`, 상태 불변. **`systems` 불일치(SE-011 추가, restore 5단계 D5):** 훅 없는 `target`에 `systems` 키 삭제, `systems: []`, `systems: {"build": 5}`(값이 Dictionary 아님) → 각각 `false`, `push_error` 1회, 상태 해시 불변. 가짜 `build`를 훅과 함께 등록한 두 번째 대상 `target2`에 `good`(`systems: {}`) → `false`(훅 시스템 항목 없음, ③), `push_error` 1회, `target2` 해시 불변, `build`의 `restore_hook` 호출 0회. `good`에 `systems: {"weather": {}, "staff": {}}`(`system_order` 밖 1개 + 미등록 1개)를 넣은 사본 → `target`이 `true`, `assert_push_warning_count` 2, `push_error` 추가 0, 복원 뒤 `_hash(target) == _hash(loop)`(경고 항목은 버려져 `systems == {}`). **I4·`seed` 범위(SE-009 추가, restore 3단계):** I4 위반(`show` 에서 `speed: 2`), `seed` 범위 밖(`-1`, `2^31`) → 각각 `false`·`push_error` 1회·상태 해시 불변, `seed: 2147483647` 은 통과 (SE-009 추가). 전제 `good["phase"] == "show"`·`good["speed"] == 1`. 라벨 "I4 speed 2 in show"(`speed: 2`), "seed -1"(`seed: -1`), "seed 2^31"(`seed: 2147483648`) 은 `push_error` 누적 카운트로 라벨마다 +1 을 단언한다. "seed max passes"(`seed: 2147483647`) → `true`, `push_error` 추가 0회, `target.master_seed == 2147483647`, `target.snapshot()["seed"] == 2147483647`. 그 뒤 `restore(good)` → `_hash(target) == _hash(loop)` 그대로 성립. 기대값은 리터럴이며 구현 상수(`SeededRng.MASTER_SEED_MAX`)를 쓰지 않는다. **`rng` 상태 오류(SE-017 추가, restore 4(b)):** 전제 `good["rng"].has("audience")`. `good` 사본의 `rng["audience"] = "x"`(10진 정수 문자열 아님), 라벨 "rng audience x" → `false`, `_hash(target)` 불변, `push_error` 누적 **+2**(`SeededRng.set_state` 1 + `TickLoop` 1). I4·`seed` 범위 루프(라벨마다 +1)와 섞지 않고 별도로 단언한다 |
| AC10 | `test_tick.gd::test_register_system_rejects_half_hooks` (SE-011 추가) | 새 루프, 가짜 시스템 `build`. (1) `register_system("build", upd, snap)`(restore 비움) → `false` (G5). (2) `("build", upd, Callable(), rest)` → `false` (G5). (3) `("build", upd, Callable(fake, "no_such_method"), rest)` → `false` (G6). (4) `("build", upd, snap, Callable(fake, "no_such_method"))` → `false` (G6). (5) `("build", Callable(fake, "no_such_method"), snap, rest)` → `false` (G4). 여기까지 `push_error` 누적 5, `snapshot()["systems"] == {}`, `advance(1)`에서 `build` update 호출 0회(등록 안 됨). (6) `("build", upd, snap, rest)` → `true`(앞 실패가 등록을 남기지 않아 G3 에 안 걸림). (7) 같은 id 재등록 `("build", upd, snap, rest)` → `false` (G3). (8) 2인자 `("staff", upd)` → `true`(하위 호환). 최종 `snapshot()["systems"].keys() == ["build"]`, `push_error` 누적 6 (#명령-큐와-틱-순서 "시스템 등록") |
| AC10 | `test_tick.gd::test_system_snapshot_hooks_included_in_order` (SE-011 추가) | (a) 훅 시스템 없는 루프: `snapshot()`의 정렬 키 == 리터럴 `["day", "pending_commands", "phase", "rng", "schema_version", "seed", "speed", "systems", "tick", "tick_in_phase"]`, `systems == {}`. (b) 시드 42 루프에 가짜 `reputation`(훅), `build`(훅), `audience`(2인자, 훅 없음)를 이 순서로 등록, `advance(5)`(가짜 `update`가 `n += 1`) → `snap["systems"].keys() == ["build", "reputation"]`(정렬하지 않은 삽입 순서 = `system_order` 순), `"audience"` 키 없음, `snap["systems"]["build"]["n"] == 5`. `snapshot()`을 한 번 더 부른 해시가 같고 가짜 상태 불변(SH1). `snap["systems"]["build"]`를 수정해도 가짜 상태 불변(SH7 깊은 복사). (c) JSON 왕복 → 시드 7 새 루프에 새 가짜 3개를 같은 방식으로 등록 → `restore` `true`, 공유 로그의 `restore_hook` 호출 == `["build", "reputation"]`(각 1회, `system_order` 순), 복원 직후 해시 동일, 양쪽 `advance(100)` 후 해시 동일·훅 가짜(`build`, `reputation`) `n == 105`. (d) (b)·(c)의 `snapshot()`/`restore()` 동안 기록기(`tick.advanced`, `time.*` 4종) 이벤트 0개 (#스냅샷 `systems` 행, `snapshot()` 절차, restore 7단계) |
| AC10 | `test_tick.gd::test_system_restore_rolls_back_on_failure` (SE-011 추가) | 시드 42 루프에 가짜 `build`, `audience`, `economy`를 훅과 함께 등록. `advance(10)` → `s = JSON 왕복(snapshot())`(가짜 `n == 10`). `advance(20)`(`n == 30`), `time.speed_requested {2}` 발행(미적용, 명령 큐 1개), `before = _hash(loop)`. (a) `economy`가 `restore_hook`에서 `false` → `restore(s)` `false`. 공유 로그의 `restore_hook` 호출 순서 == `["build", "audience", "economy", "audience", "build"]`(적용 2 → 실패 1 → 역순 롤백 2), 롤백 호출이 받은 `n == 30`(사전 스냅샷), 세 가짜 모두 `n == 30`, `_hash(loop) == before`(`tick` 30, `rng`, 명령 큐 1개 포함), `push_error` 누적 1. (b) 그대로 두고 `build`도 "설정한 뒤 두 번째 `restore_hook` 호출부터 `false`"로 바꾼다(적용은 성공, 롤백이 실패) → `restore(s)` `false`, `push_error` 누적 3(시스템 실패 1 + 롤백 실패 1), `systems`를 뺀 스냅샷 해시(`TickLoop` 카운터·`rng`·명령 큐)가 `before`의 것과 같음(복구 불능 시스템 상태는 단언하지 않음). (c) 실패 설정을 모두 끄면 `restore(s)` `true`, 세 가짜 `n == 10`, `loop.tick == 10` (#스냅샷 restore 7단계, "실패 시 상태 불변") |
| AC10 | `test_tick.gd::test_system_snapshot_rejects_invalid_hook_return` (SE-011 추가) | 가짜 `build`(훅) 등록, 정상일 때 `good = snapshot()`. `snapshot_hook` 반환값을 차례로 `[]`, `"x"`, `{"v": Vector2(1, 2)}`, `{"o": RefCounted.new()}`, `{"a": [Callable()]}`, `{1: 2}`(키가 문자열 아님)로 바꿔 각각 `snapshot() == {}`, `push_error` 누적 +1(합 6). 마지막 비정상 반환 상태에서 `restore(good)` → `false`(6단계 사전 스냅샷 실패), `restore_hook` 호출 0회, `tick`·`rng.get_state()`·`bus.get_pending_commands()` 불변, `push_error` 누적 7. 정상 반환으로 되돌리면 `snapshot()` 키 10개, `restore(good)` `true` (D3, SH2, `snapshot()` 2단계, restore 6단계) |
| AC10 | `test_tick.gd::test_system_hooks_reject_reentry` (SE-011 추가) | 가짜 `build`(훅) 등록. 재진입 플래그를 켠 뒤 `snapshot_hook`의 첫 호출에서 `_loop.snapshot()`, `_loop.advance(1)`, `_loop.register_system("staff", upd)`의 결과를, `restore_hook`의 첫 호출에서 `_loop.restore(<미리 찍은 스냅샷>)`의 결과를 기록한다(두 번째 호출부터는 시도하지 않음). 바깥 `snapshot()` → 정상 10개 키, 기록 `[{}, 0, false]`. 바깥 `restore(snap)` → `true`, 기록 `[false]`. `push_error` 누적 4, `tick` 불변. 이어서 `register_system("staff", upd)` → `true`(훅 안 시도가 등록을 남기지 않음) (SH5, G1) |
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

- 데이터: `python3 tools/validate_data.py --strict` — `sim.json` v3 이 스키마(version `enum [3]`)를 통과(적용됨(SE-012), #변경-이력 SE-012 행).
- 헤드리스(SE-001 이 작성): `tools/run_tests.sh project/tests/sim` — `test_sim_config.gd`, `test_event_bus.gd`, `test_rng.gd`, `test_tick.gd`, `test_core_boundary.gd`, `replay/test_replay_tick.gd`. 케이스는 위 수용 기준 표.
- 헤드리스(SE-012 가 작성, SE-011 스펙): `test_tick.gd`에 새 케이스 5개(`test_register_system_rejects_half_hooks`, `test_system_snapshot_hooks_included_in_order`, `test_system_restore_rolls_back_on_failure`, `test_system_snapshot_rejects_invalid_hook_return`, `test_system_hooks_reject_reentry`)와 기존 케이스 갱신 2개(`test_snapshot_restore_equivalence` 10개 키, `test_restore_rejects_bad_snapshot` `systems` 불일치). 가짜 시스템은 테스트 파일 안의 `RefCounted` 내부 클래스로 만든다: 상태 `{n: int}`(필요하면 필드 추가), `update(ctx)`가 `n += 1`, `snapshot_hook()`이 상태의 깊은 복사본, `restore_hook(d)`가 검사·정수 정규화 뒤 교체하고(SH3) 공유 로그에 `[id, d.n]`을 남긴다. 실패 플래그와 반환값 덮어쓰기는 케이스가 필요한 만큼 둔다. 리플레이 기준값(`replay/test_replay_tick.gd`)은 바뀌지 않는다(#스냅샷 "결정성·리플레이 영향").
- 로컬에 Godot 이 없으면 `SKIP` → PR 의 CI(`godot-tests`)로 대신한다.
- 스펙 자체의 판정: producer 가 SE-001 AC1~AC14 와 위 표를 대조, reviewer 가 `events.md`와 이 문서의 이벤트 이름 대조(`docs/reviews/SE-006.md`).

## 열린 질문

> **결정(2026-10-09, 프로덕트 오너):** 아래 질문 전부 추천안 채택. 현재 데이터 값이 확정값이다. 바꾸려면 새 질문으로 다시 올린다.

사람 결정 항목. producer 가 `docs/status/`로 옮긴다. 추천안은 이미 `sim.json`에 반영된 현재 값이다(바꾸면 데이터만 바꾸면 되는 항목과 ADR 이 필요한 항목을 구분).

| # | 질문 | 선택지 | 추천 | 바꾸면 |
|---|---|---|---|---|
| Q1 | 저녁(개장) 구간 2배속 허용? 현재 `[0, 1]` | (a) 유지 `[0,1]` (b) `[0,1,2]` (c) `[0,1,2,3]` | **(a)** PRD 세션 표가 저녁을 "실시간"으로 정했고, 입장 흐름 관찰·긴급 대응 구간이다. 봇 통계에서 저녁이 지루하다는 근거(이탈·무조작 비율)가 나오면 (b) 재검토 | `speeds` 변경 = PRD 결정 변경 → ADR |
| Q2 | 공연 중 일시정지 불가 유지? 현재 `pausable: false`, `[1]` | (a) 유지 (b) `[0,1]`로 허용 (c) 접근성 설정 토글(기본 꺼짐)로만 허용 | **(a)** v0 유지. 공연은 90초로 짧고 실시간 긴장이 핵심. 단 PRD 접근성("일시정지 중 모든 조작 가능")과 충돌 소지가 있어 버티컬 슬라이스 접근성 검토 때 (c)를 후보로 | (b) ADR, (c) 설정을 명령으로 기록하는 별도 티켓 |
| Q3 | close 에서 다음 날로 가는 방식 | (a) `time.next_day_requested` 명령 대기(현재) (b) N초 뒤 자동 (c) 설정으로 선택 | **(a)** close 는 리포트 화면이고 홀드가 오토세이브·정산 시점을 고정한다. 봇은 명령 한 줄로 넘긴다 | (b)/(c) 실시간 타이머는 `step()` 밖의 개념이라 sim 규칙 추가 필요 |
| Q4 | 새 날 시작 배속 | (a) 1 (현재, `force`) (b) 0 — 일시정지로 시작해 준비 (c) 전날 낮 배속 기억 | **(a)** SE-001 AC2 가 "새 게임 `advance(1)` → tick 1"을 전제한다. (c)는 상태 필드 1개 추가로 가능하니 플레이테스트 후 결정 | (b) `default_speed` 0 으로 데이터만, 단 AC2 테스트가 배속 요청을 먼저 보내도록 수정 |
| Q5 | `step()` 1회 상한 `max_ticks_per_step` | 10 / **30** / 90 | **30** 3배속 실시간 1초분. 프레임 끊김 뒤 몰아치기(스파이럴) 방지, 초과분은 버린다 | 데이터만 |
| Q6 | E7(`tick.advanced` 구독자는 상태 이벤트 금지)을 규약으로 둘지 버스가 강제할지 | (a) 리뷰 규약 (b) 버스가 `tick.advanced` 디스패치 중 상태 이벤트 발행을 거부 | **(a)** v0. 위반 사례가 리뷰에서 2회 이상 나오면 (b) | producer 판단(사람 결정 불요) |

아래 Q7 은 위 결정(2026-10-09) 뒤에 SE-011 이 더한 질문이다. 사람 결정은 필요 없고(producer), 세이브 티켓에서 닫는다.

| # | 질문 | 선택지 | 추천 | 바꾸면 |
|---|---|---|---|---|
| Q7 | 훅 시스템을 더하거나 시스템 항목 형식을 바꿀 때 `snapshot_schema_version`을 올리나 | (a) 올린다(세이브 호환을 전역 버전으로 판정) (b) 올리지 않고 restore 5단계 ③(훅 시스템 항목 없음 → 실패)으로만 거부 (c) 시스템 항목별 버전(`systems.<id>` 안에 버전 필드) | **세이브 티켓에서 결정.** 세이브 파일이 없는 v0 에서는 (b)로 충분하다. 옛 스냅샷에 새 훅 시스템 항목이 없으면 ③으로 시끄럽게 실패하기 때문이다. 세이브가 생기면 마이그레이션 단위가 필요하므로 (a) 또는 (c)다. 그때까지 시스템 스펙은 항목 형식을 바꿀 때 이 문서 변경 이력에 한 줄을 남긴다 | (a)/(c) 세이브 티켓이 `sim.json`·각 시스템 스펙 개정 |

## 변경 이력

| 날짜 | 버전 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-09 | tick.md v0 | SE-006 | 신규 작성 |
| 2026-10-09 | `sim.json` v1 → v2, `sim.schema.json` version 2 | SE-006 | 필드 추가: `max_ticks_per_step`(30), `snapshot_schema_version`(1), `rng_streams`, `system_order`, `phases[].default_speed`, `phases[].enter_speed_mode`. 스키마: 새 필드 필수화, `version` `enum [2]`, `phases` `maxItems 4`, `speeds` `minItems 1`·`uniqueItems`. **기존 값(10 tick/s, 1,800/600/900/0, 허용 배속, pausable)은 변경 없음** |
| 2026-10-09 | tick.md v0 (후속 수정), `sim.json` 변경 없음 | SE-008 (SE-001 리뷰 발견 1·2, SE-001 구현 결정 1·2) | E4 에 명령 페이로드 숫자 `int` 전용을 확정했다: 명령의 `float`는 정수값(`2.0`)이어도 `publish()`가 `push_error` + `false`, 큐잉 안 함. 상태 이벤트는 `float` 허용. 배속 요청 처리 1행에서 정수값인 `float` 인정을 지우고 "버스가 먼저 거부(핸들러 도달 없음)"로 바꿨다. restore 3단계에 I4·`seed` 0~2^31−1 검사를, 5단계에 `pending_commands` 재귀 정규화(정수가 아닌 `float`는 복원 실패, 상태 불변)를 확정하고 "검사 → 적용" 순서를 적었다. 수용 기준 표: `test_speed_rejected_keeps_state`의 `1.5`를 "publish false + push_error 1회, speed_rejected 없음, 상태 해시 불변"으로 바꾸고, AC8 에 `test_command_payload_numbers_int_only`, AC10 `test_restore_rejects_bad_snapshot`에 명령 `float` 케이스를 더했다. 이벤트 이름·페이로드 키·수치 변경 없음. SE-001 구현이 이미 이 규칙이라 코드 변경 없음 |
| 2026-10-09 | tick.md v0 (후속 수정). `sim.json` v2 → v3, `sim.schema.json` version 3 **결정**(적용됨(SE-012) — 아래 SE-012 행) | SE-011 (economy.md Q7, 리뷰 SE-001 참고 4·SE-005 "tick.md v0 정합성"·SE-006 참고) | 시스템 상태 스냅샷 훅을 확정했다. (1) "시스템 등록": `register_system(id: String, update: Callable, snapshot_hook: Callable = Callable(), restore_hook: Callable = Callable()) -> bool`, 규칙 G1~G6(기존 4행 + `update` 유효성 명문화 + 훅 쌍 G5 + 훅 유효성 G6), 훅 규약 SH1~SH7, 공개 API 표 `TickLoop` 행을 같은 시그니처로 맞췄다. 인자 이름은 티켓 초안 `snapshot`/`restore`에서 `snapshot_hook`/`restore_hook`으로 바꿨다(메서드 가림 경고 회피, 위치 인자라 호출 형태 동일). (2) 스냅샷: 최상위 키 9 → 10(`systems`, 항상 존재, `system_order` 순, 훅 시스템만), `snapshot()` 절차 3단계(D3: 훅 반환 위반 시 `push_error` 후 `{}`). (3) restore 를 1~9단계로 다시 번호 매겼다: 1~3 그대로, 옛 5단계의 명령 큐 검사와 옛 4단계의 `rng` 형식 검사를 4단계(검사)로, 5단계 `systems` 불일치(D5), 6단계 사전 스냅샷, 7단계 시스템 적용·역순 롤백(D4), 8단계 `TickLoop` 필드 적용(옛 4·5단계의 적용 부분), 9단계 끝. E4 와 AC8 행의 "restore 5단계" 참조를 4단계로 고쳤다. "실패 시 상태 불변"을 시스템 상태까지 넓히고 복구 불능(롤백 실패) 예외를 적었다. (4) "결정성·리플레이 영향": AC11 기준값 불변, 상태 해시 문자열은 바뀌지만 저장된 기준 문자열 없음, 바뀌는 테스트 리터럴 3곳(`test_sim_config.gd:38`, `replay/test_replay_qa.gd:131-132`, `test_tick.gd:450-451`). (5) 수용 기준 표: AC7 `test_systems_updated_in_config_order`에 하위 호환 문구, AC10 `test_snapshot_restore_equivalence` 9 → 10개 키, `test_restore_rejects_bad_snapshot`에 `systems` 불일치 케이스, 새 케이스 5개(`test_register_system_rejects_half_hooks`, `test_system_snapshot_hooks_included_in_order`, `test_system_restore_rolls_back_on_failure`, `test_system_snapshot_rejects_invalid_hook_return`, `test_system_hooks_reject_reentry`). (6) 열린 질문 Q7(시스템 항목 버전 정책, 세이브 티켓). **데이터 diff(SE-012 의 game-designer 2차가 적용):** `sim.json`은 `version` 2 → 3, `snapshot_schema_version` 1 → 2 두 값만 바뀐다. `sim.schema.json`은 `version`의 `enum [2]` → `enum [3]`, `$comment`의 "schema version 2 (SE-006)" → "schema version 3 (SE-011)", `snapshot_schema_version`의 `description`에서 "(마이그레이션 티켓 동반)" → "(세이브 파일이 생긴 뒤에는 마이그레이션 티켓 동반)"만 바뀐다. 그 밖의 필드·값·`required`·제약(`snapshot_schema_version` `minimum: 1` 포함)은 불변이다. **적용은 SE-012 와 같은 PR**: 지금 `snapshot_schema_version`을 2 로 바꾸면 리터럴 테스트 3곳이 빨개져 이 티켓 단독으로 CI 녹색이 될 수 없다. 이벤트 추가 0, `events.md` 변경 0, 코드·테스트 변경 0 |
| 2026-10-09 | tick.md v0 (후속 수정), `sim.json` 변경 없음 | SE-007 (docs/reviews/SE-007.md 발견 1. 누락분을 SE-009 에서 기록) | #배속 S4 포화를 확정했다: `k = s0 × ticks_per_second`, `sat_s = ⌈max_ticks_per_step ÷ k⌉`, `delta_s > sat_s` 이면 정수 초만 `sat_s` 로 자르고 소수부(`delta_s mod 1`)는 보존한다(int64 오버플로 방지, 잘린 뒤에도 S5 `budget`·잔여 `acc` 가 자르지 않은 계산과 같음). 수용 기준 표 AC6 에 `test_tick.gd::test_step_saturation_keeps_fraction`·`replay/test_replay_qa.gd::test_step_int64_overflow_known_bug` 행을 추가했다. `sim.json`·스키마 변경 없음, 이벤트 변경 없음 |
| 2026-10-09 | tick.md v0 (후속 수정), `sim.json` 변경 없음 | SE-009 (docs/reviews/SE-008.md 발견 1, docs/tickets/SE-008.md 남은 질문 1, docs/reviews/SE-007.md 발견 1) | 수용 기준 표 AC10 `test_restore_rejects_bad_snapshot` 행에 restore 3단계 거부 케이스를 더했다: I4 위반(`show` 에서 `speed: 2`), `seed` 범위 밖(`-1`, `2147483648`) → 각각 `false`·`push_error` 1회·상태 해시 불변, 경계값 `seed: 2147483647` 은 통과(`master_seed`·`snapshot()["seed"]` 일치). SE-011 의 `systems` 불일치 케이스는 그대로 둔다. 위 SE-007 행(누락분)을 함께 기록했다. 규칙·수치표·restore 표 변경 없음. 코드·데이터 변경 없음(`project/core/tick.gd` 가 이미 두 검사를 한다), 이벤트 변경 없음 |
| 2026-10-09 | `sim.json` v2 → v3, `sim.schema.json` version 3 (적용) | SE-012 (game-designer 2차) | SE-011 행의 데이터 diff 를 그대로 적용했다: `sim.json` `version` 2 → 3, `snapshot_schema_version` 1 → 2. `sim.schema.json` `version` `enum [2]` → `enum [3]`, `$comment` "schema version 2 (SE-006)" → "schema version 3 (SE-011/SE-012)", `snapshot_schema_version.description` "(마이그레이션 티켓 동반)" → "(세이브 파일이 생긴 뒤에는 마이그레이션 티켓 동반)". 그 밖의 필드·값·`required`·제약 불변. 이 문서의 "적용은 SE-012"·"적용 전 데이터 값 1" 표기(상단 데이터 행, 스냅샷 필드 표, 수치표 머리말·행, 테스트 방법, SE-011 행)를 "적용됨(SE-012)"로 바꿨고, #스냅샷 (iii)에 SE-012 구현 뒤 리터럴 위치가 4곳(`test_tick.gd` 새 케이스 1곳 추가)임을 적었다. 리터럴 교체(`test_sim_config.gd:39`, `replay/test_replay_qa.gd:134`, `test_tick.gd:460`·`:690` → 2)는 `project/tests/` 쓰기 범위라 같은 브랜치의 다음 단계(qa)가 한다. 규칙·이벤트·리플레이 기준값 변경 없음 |
| 2026-10-09 | tick.md v0 (후속 수정), `sim.json` 변경 없음 | SE-017 (docs/reviews/SE-012.md 발견 5·참고 4·후속 제안 D, docs/reports/SE-012.md 리뷰어에게 6) | #스냅샷 `restore` 문단의 "`push_error`는 정확히 1회"를 "**`TickLoop` 자신의** `push_error` 1회, 하위 구성 요소(4(b) `SeededRng.set_state`, 6·7단계 시스템 훅 자신)와 7단계 롤백 실패분은 별도"로 고쳤다. restore 표 4단계에 `set_state` 실패 조건(이름이 문자열 아님·값이 10진 정수 문자열 아님, 값 검사가 스트림 이름 확인보다 먼저)과 합계 2회를 적었다. "복구 불능" 뒤에 "`push_error` 횟수 (SE-017)" 블록(세 항 (i)~(iii), 실패 경로별 합계 표 7행, 결정 근거)을 더했다. 수용 기준 머리말에 "restore 행의 횟수는 누적 합계, '1회' 행은 `TickLoop` 자신 1회와 같다, economy.md EC16 (c) 2회와 모순 없음"을 한 번 적고, AC10 `test_restore_rejects_bad_snapshot` 행에 `rng["audience"] = "x"` → `false`·해시 불변·`push_error` 누적 +2 케이스를 더했다. 기존 단언(I4·`seed` 범위 +1, "seed max passes" +0, `systems` 불일치 +1, 롤백 (a) 1·(b) +2, EC16 (c) +2)은 모두 새 규칙과 일치해 그대로다. economy.md 변경 0. 수치·이벤트·스냅샷 키 변경 0, 코드·데이터 변경 0 |
| 2026-10-09 | tick.md v0 (후속 수정), `sim.json` 변경 없음 | SE-016 (docs/reviews/SE-012.md 발견 4·후속 제안 C) | 공개 API 표 `EventBus`에 `static is_valid_value(v: Variant, allow_float: bool) -> bool`(E4 기본형 재귀 검사, SH2 용, `project/core/event_bus.gd`)을 더했다. 이미 있던 공개 멤버를 표에 올린 것뿐이라 코드·규칙·이벤트·리플레이 기준값 변경 없음 |
| 2026-10-09 | tick.md v0 (후속 수정), `sim.json` 변경 없음 | SE-022 (docs/reviews/SE-017.md 발견 1·후속 E) | #스냅샷 "`push_error` 횟수 (SE-017)" 표 2행의 "고정하는 테스트" 열을 바로잡았다. 기존 `test_restore_rejects_bad_snapshot`은 5단계 ①②③만 때리므로 그 범위를 `(5단계 ①②③)`로 적고, 5단계 ④(훅 시스템 객체 해제로 `Callable.is_valid()`가 아님)를 고정하는 `test_restore_rejects_invalid_hook`(SE-022 1차 sim-engineer 추가)을 덧붙였다. 이 케이스는 `snapshot()`이 같은 무효 훅 때문에 `{}`를 돌려주므로 상태 해시 대신 `TickLoop` 필드 비교로 불변을 단언하고, ④ 분기를 변이에서 구별하는 것은 메시지 단언 "더 이상 유효하지 않다"다(분기를 지우면 6단계 사전 스냅샷이 같은 횟수로 실패한다). 표의 (i)(ii)(iii)·합계 열(1·0·0·1)과 다른 행은 변경 없음. 규칙·수치·이벤트·스냅샷 키 변경 0, 코드·데이터 변경 0 |
| 2026-10-10 | tick.md v0 (후속 수정), `sim.json` 변경 없음 | SE-052 A (docs/reviews/SE-034.md 후속 2·3, SE-034-bug) | #스냅샷 restore 8(b) 문구를 SE-034-bug 수정(`78de35a`, `rng.assign`)에 맞췄다: "4단계에서 만든 `SeededRng`으로 `rng` 교체" → "4단계에서 검증한 시드·상태를 기존 `rng` 객체에 적용(객체 유지)", 근거 링크. 같은 행 (a) 의 "교체"도 "바꿔 넣기"로 고쳐 8단계 행에 "교체" 0건. 4(b) 끝에 "새 `SeededRng`의 스트림 목록이 현재 `rng`와 다르면 실패"(TickLoop 1회)를 더해 8(b) 가 실패할 수 없음을 사전 검사로 보장하고, `push_error` 횟수 표에 그 경로 1행(합계 1)을 더했다. 구현·테스트는 SE-052 B(sim-engineer). 수치·이벤트·스냅샷 키 변경 0, 데이터 변경 0 |
| 2026-10-10 | `save.json` v1 + `save.schema.json` version 1 (신규), tick.md v0 (후속 수정) | SE-057 (docs/reviews/SE-036.md 후속 제안, docs/tickets/SE-036.md 결과 절 "game-designer 요청 필드") | #스냅샷 아래 "세이브 설정 (save.json)" 절(SV1~SV5)을 새로 썼다. 필드 `manual_slots` 3(1~9), `autosave_keep` 3(0~99, 0 = 무제한). SE-036 결과 절 제안 이름 `save_slot_count` 는 SE-057 티켓의 `manual_slots` 로 바꿨다(SE-040 AC-39d 가 이미 이 이름을 참조). `sim.json` 에 넣지 않고 새 테이블로 둔 이유: 세이브 설정은 시뮬레이션 상수가 아니고 상태 해시에 영향이 없으며, `sim.json` 은 버전을 올리면 리플레이 기준값 검토가 따라온다. `sim.json`·스냅샷 키·이벤트 변경 0 |
| 2026-10-10 | tick.md 변경 없음(이력만, Q7 규칙), `sim.json` 변경 없음 | SE-062 | 경제 항목(`systems.economy`) 형식 변경: 선택 키 `last_settlement` 추가(economy.md #스냅샷 LS1~LS4). `snapshot_schema_version` 은 2 그대로 — 키가 없는 구버전 경제 항목은 `{}`로 복원(하위 호환)하고, 형식이 틀린 값만 `Economy.restore` 실패(7단계, `push_error` 2회)로 거부한다. 선택 키 하위 호환은 **공식에 쓰지 않는 표시용 필드**에만 쓰는 예외이고, Q7(전역 버전 vs 항목별 버전)은 그대로 열려 있다. 최상위 10키·restore 1~9단계·리플레이 기준값 변경 0 |
