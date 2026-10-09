# SE-007-bug TickLoop.step() 누적기 int64 오버플로 (delta_s 극단값)

| 항목 | 값 |
|---|---|
| 상태 | 완료 — PR #1 병합(2026-10-09) — reviewer 승인 2026-10-09 |
| 담당 에이전트 | sim-engineer (수정), game-designer (스펙 문구 확인) |
| 마일스톤 | 프리프로덕션 |
| 의존 티켓 | SE-001 (구현), SE-006 (스펙 tick.md#배속 S4~S5) |
| 스펙 | docs/gdd/tick.md#배속 "step(delta_s) 누적기" S4~S5 |
| 브랜치 | feature/SE-007-step-overflow |
| 심각도 | 낮음 (실사용 도달 불가: 배속 3 에서 약 9,700년치 delta). 방어 코드 1줄 수준 |

## 재현 절차

- 시드 42, `TickLoop.new(SimConfig.load(), 42)` (1일차 day, tick 0, 배속 1).
- 입력 순서: `bus.publish("time.speed_requested", {"speed": 3})` → `loop.step(4.0e11)` → `loop.step(0.1)`.
- 틱 번호: 시작 경계 tick 0.
- 재현 테스트: `project/tests/sim/replay/test_replay_qa.gd::test_step_int64_overflow_known_bug` (pending 으로 기록. 원인이 고쳐지면 `pass_test` 분기로 바뀐다). 임계값 조사는 임시 프로브로 측정 후 삭제했다.

측정값 (Godot 4.6.stable, 같은 플랫폼 한 번씩; `step(d)` 반환 / 직후 `step(0.1)` 반환):

| 배속 | delta_s | step(d) | 이어진 step(0.1) | 기대 |
|---|---|---|---|---|
| 1 | 9.0e11 | 30 | 1 | 30 / 1 |
| 1 | 1.0e12 | **0** | **0** | 30 / 1 |
| 1 | 1.0e13 | **0** | 1 | 30 / 1 |
| 3 | 3.0e11 | 30 | 3 | 30 / 3 |
| 3 | 4.0e11 | **0** | **2** | 30 / 3 |
| 3 | 9.0e11 | 30 | 3 | 30 / 3 |
| 3 | 1.0e12 | **0** | **2** | 30 / 3 |
| 3 | 1.0e13 | **0** | 3 | 30 / 3 |

(9.0e11 @배속3 이 우연히 정상인 것은 래핑 결과가 양수가 된 것으로 보인다. 단조롭지 않다.)

## 기대 / 실제

- 기대: tick.md S5 "`budget = min(q, max_ticks_per_step)`, 상한 초과분은 버림". 어떤 큰 `delta_s` 에서도 `step()` 은 최대 `max_ticks_per_step`(30) 틱을 처리하고 `acc` 잔여가 정상 범위(< 1,000,000)여야 한다.
- 실제: `us * s0 * ticks_per_second` (`project/core/tick.gd` 의 `_acc += us * s0 * config.ticks_per_second`)가 int64 를 넘쳐 음수/임의 값이 되고, `q` 가 음수면 `budget` 도 음수라 0틱을 돌려준다. 래핑된 값이 `_acc` 에 남아 이후 `step()` 결과도 어긋난다(배속 3 에서 3틱이어야 할 `step(0.1)` 이 2틱). `acc` 는 스냅샷에 들어가지 않으므로 세이브/로드는 이 상태를 지운다.

## 영향

- 실제 프레임 delta 는 최대 수 초~수 시간이다. 이 한계(≈3×10^11 초)는 도달 불가이므로 플레이 영향 0 에 가깝다. 다만 `step()` 은 "임의 `delta_s` 에서 안전"하다고 스펙이 말하고(S5 상한, 따라잡기 없음), 헤드리스 봇/퍼저가 큰 값을 넣을 수 있다.
- NaN/INF/음수 delta 는 정상 처리됨(`step(NAN)`, `step(INF)`, `step(-1.0)` 모두 0틱, 같은 테스트 파일의 `test_step_extreme_delta` 통과).

## 수정 제안 (구현은 sim-engineer)

- S4 에서 `us` 를 상한으로 자른다. 예: `us = mini(us, max_ticks_per_step * US_PER_S)` 처럼 `max_ticks_per_step` 틱을 만들고도 남는 양(`ceil(max_ticks_per_step × US_PER_S / (s0 × ticks_per_second))`)이면 더 받아도 어차피 버려지므로, `acc` 가 넘치지 않는 값으로 자른다. 숫자 리터럴 없이 `config` 값만으로 계산한다.
- tick.md S4 에 "`us` 는 `max_ticks_per_step` 틱분으로 포화시킨다" 한 줄 추가(game-designer). 상태 해시·리플레이 기대값은 변하지 않는다(정상 범위 delta 는 동일 결과).

## 수용 기준

- [ ] AC1. `step(4.0e11)` @배속 3, `step(1.0e12)` @배속 1·3, `step(1.0e13)` 이 모두 `max_ticks_per_step` 를 돌려주고, 이어진 `step(0.0)` 은 0, 이어진 `step(0.1)` 은 배속과 같은 틱 수를 돌려준다.
- [ ] AC2. `test_replay_qa.gd::test_step_int64_overflow_known_bug` 의 pending 분기를 단언으로 바꾸고 녹색이다. 기존 `test_tick.gd::test_step_accumulator_by_speed`, `::test_step_caps_and_discards`, `replay/test_replay_tick.gd` 는 그대로 녹색(회귀 없음).

## 테스트 방법

- 헤드리스: `tools/run_tests.sh project/tests/sim` 의 `replay/test_replay_qa.gd`.

## 경계 확인

- 쓰는 폴더: `project/core/tick.gd`, `project/tests/sim/`
- 스펙 문구: `docs/gdd/tick.md` (game-designer)
- 필요한 이벤트·데이터 필드: 없음.

## QA / 리뷰

- QA 리포트: docs/reports/SE-001.md

## 결과 (sim-engineer, 2026-10-09)

상태: 구현 완료(qa 대기). 커밋·푸시는 하지 않았다(브랜치 `claude/agent-setup-mqfxoy` 작업 트리, producer/메인 세션이 커밋).

### 수정 내용

- `project/core/tick.gd` `step()` S4: `k = s0 × ticks_per_second`, `sat_s = ceil(max_ticks_per_step / k)`(정수 올림 나눗셈, config 값만 사용, 리터럴 없음)를 구하고, `d > sat_s` 이면 `d = sat_s + fposmod(d, 1.0)` 로 포화시킨 뒤 기존대로 `us = max(0, roundi(d × 10^6))`, `acc += us × k`.
  - `sat_s` 초분이면 이미 `max_ticks_per_step` 틱 이상(`sat_s × k ≥ max_ticks_per_step`)이므로 S5 의 `budget` 은 자르지 않은 계산과 같다(항상 상한).
  - 수정 제안의 단순 포화(`us = min(us, cap)`)와 다른 점: **정수 초만 자르고 소수부는 보존**한다. `acc` 잔여 = `(acc + us×k) mod 10^6` 은 `us mod 10^6` 에만 의존하므로 잔여도 자르지 않은 계산과 같다. 단순 포화는 `step(10.05)`@배속1 처럼 실사용 범위(프레임 정지 3초 이상)에서 잔여 0.5틱분을 지워 기존 동작을 바꾸므로 택하지 않았다.
  - `d ≤ sat_s`(배속 1: 3초, 2: 2초, 3: 1초 이하)는 코드 경로가 그대로라 기존 결과와 비트 단위로 같다. 상태 해시·리플레이 기대값 변화 없음.
  - 포화 후 최대 `us ≈ (sat_s + 1) × 10^6`, `acc < 10^6 + us × k` 라 현재 데이터에서 `acc` 는 10^9 미만. `roundi()` 의 float→int 변환도 범위 안(수정 전에는 `delta_s ≥ ~9.2e12` 에서 `roundi` 자체가 넘쳤다 — 1e13 행이 0틱이던 원인).
- `project/tests/sim/replay/test_replay_qa.gd::test_step_int64_overflow_known_bug`: pending 분기 제거, 실제 단언으로 교체(이름 유지). 배속 1·2·3 × delta {3e11, 4e11, 9e11, 1e12, 1e13, 1e300} 각각 `step(d) == max_ticks_per_step`, 이어진 `step(0.0) == 0`, 이어진 `step(0.1) == 배속`, `tick == max_ticks_per_step + 배속`. 재현 절차(시드 42, 배속 3, `step(4e11)` → `step(0.1)`) = `[30, 3]` 리터럴.
- `project/tests/sim/test_tick.gd`
  - I2(리뷰 발견 4-i): `_invariants()` 의 I2 를 getter 정의와 같은 식(`phase_start + tick_in_phase`)에서 독립 계산 `_tick_in_day_independent()` 로 교체 — `_cfg.phases` 를 앞에서부터 돌며 현재 구간 앞의 `ticks` 를 누적하고 `tick_in_phase` 를 더한다(`phase_start` 를 쓰지 않음). 이 헬퍼를 쓰는 기존 테스트 이름·단언은 그대로.
  - 신규 `test_step_saturation_keeps_fraction`: 배속 1, `step(10.05)` 와 `step(1e13 + 0.25)` 각각 → 30틱, 이어서 `step(0.04)` → 0, `step(0.01)` → 1, `step(0.0)` → 0(잔여 0.5틱분 보존). 단순 포화였다면 실패하는 케이스.

### 발행하는 이벤트

- 변경 없음(새 이벤트·페이로드 없음). 데이터 필드 추가 없음(`project/data/` 변경 0).

### tick.md S4 에 추가할 문장 (game-designer 반영 요청)

> S4 포화: `k = s0 × ticks_per_second`, `sat_s = ⌈max_ticks_per_step ÷ k⌉` 일 때 `delta_s > sat_s` 이면 `delta_s = sat_s + (delta_s mod 1)` 로 바꾼 뒤 `us` 를 계산한다(정수 초만 잘라 int64 오버플로를 막고, 소수부를 남겨 S5 의 `budget`·잔여 `acc` 가 자르지 않은 계산과 같다).

(수용 기준 표에 `test_tick.gd::test_step_saturation_keeps_fraction` 행 추가도 함께 요청.)

### 테스트 결과

- `tools/run_tests.sh project/tests/sim` (Godot 4.6.stable 헤드리스): Scripts 8, Tests 43, Passing 43, Failing 0, Pending 0, Asserts 505. (수정 전: Tests 42, Passing 41, Pending 1, Asserts 424.) 출력의 `ERROR:` 줄은 기존 테스트가 의도적으로 유발하는 `push_error`(개수 단언됨).
- AC2 회귀: `test_tick.gd::test_step_accumulator_by_speed`, `::test_step_caps_and_discards`, `replay/test_replay_tick.gd`, `replay/test_replay_qa.gd::test_step_extreme_delta` 녹색.
- `python3 tools/validate_data.py --strict`: 4개 테이블, 실패 0.

### 남은 질문

1. tick.md S4 문구(위 인용)는 game-designer 반영 대기. 반영 전까지 구현이 스펙보다 한 줄 앞서 있다(동작은 S5 "상한 초과분은 버림"의 결과와 동일).
2. 현재 작업 트리의 `docs/gdd/{tick,events,economy}.md` 변경은 game-designer 가 동시에 수정 중인 것으로 이 티켓의 산출물이 아니다. SE-007-bug 커밋에는 `project/core/tick.gd`, `project/tests/sim/replay/test_replay_qa.gd`, `project/tests/sim/test_tick.gd`, `docs/tickets/SE-007-bug.md` 만 넣을 것.
