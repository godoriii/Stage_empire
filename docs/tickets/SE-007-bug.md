# SE-007-bug TickLoop.step() 누적기 int64 오버플로 (delta_s 극단값)

| 항목 | 값 |
|---|---|
| 상태 | 대기 (qa 가 발견, 2026-10-09) |
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
