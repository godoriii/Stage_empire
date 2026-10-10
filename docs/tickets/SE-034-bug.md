# SE-034-bug `TickLoop.restore` 가 `SeededRng` 객체를 교체해 audience 의 RNG 가 낡는다 (로드 뒤 다음 날 입장·도착 순서가 달라진다)

| 항목 | 값 |
|---|---|
| 상태 | 대기 (재현됨) |
| 담당 에이전트 | sim-engineer |
| 마일스톤 | MVP |
| 의존 티켓 | SE-034 (발견), SE-001 (`TickLoop`·`SeededRng`), SE-036 (`GameSession` 로드 경로) |
| 스펙 | docs/gdd/tick.md#결정성과-rng · #스냅샷 SH6(복원 후 진행 = 연속 진행), docs/gdd/audience.md#결정성과-rng R5 |
| 브랜치 | 별도 fix 브랜치(권장 `fix/SE-034-bug-restore-rng`). **범위는 `project/core/`**(`tick.gd` 8(b)) + `project/tests/sim/` |
| 심각도 | 중간. 같은 날 안에서는 드러나지 않고(저녁 진입 뒤 뽑기가 없다) 로드 뒤 **다음 날 저녁**부터 저장→로드 경로의 결과가 로드하지 않은 진행과 다르다. 세이브 결정성·리플레이의 핵심 계약(SH6) 위반. 현재 RNG 소비자는 audience 뿐이라 영향이 audience 에 한정되지만 artist·events·economy·world 스트림도 같은 구조다 |

## 재현 절차

- 도구: 저장소 밖 스크래치 프로브 `rng_probe.gd`(SceneTree 스크립트, 제품 코드 변경 없음). 실행 `godot --headless --path project -s <probe.gd>`. 프로브는 저장소에 남기지 않았다(수정 티켓의 AC 로 `project/tests/sim/` 에 정식 테스트를 추가한다).
- 구성: `AudienceHarness.scenario_loop(rookie_baseline)` = 시드 0, 티어 1 기준 배치 `baseline_show`, 라인업 s08(indie rookie 인기 42 실력 60), 명성 150, 가격 20. `build`·`audience`·`economy` 를 훅과 함께 등록.
- 입력 순서:
  1. 1일차를 끝까지 진행: `loop.advance(day_ticks)` → close 정지. 입장 120. 이때 스냅샷 `S = JSON 왕복(loop.snapshot())`(틱 번호 = 1일차 close 진입 틱, `tick = 1500`).
  2. **A (연속 진행)**: 같은 루프에 `time.next_day_requested` → `advance(day_ticks)` → 2일차.
  3. **B (새 루프에 로드)**: 시드 777 로 만든 새 `TickLoop`(구성 동일)에 `restore(S)` → `time.next_day_requested` → `advance(day_ticks)`.
  4. **C (같은 루프에서 이전 저장으로 되돌려 로드)**: 새 루프에서 1일차 → 2일차까지 진행한 뒤 `restore(S)` → `time.next_day_requested` → `advance(day_ticks)`.
- 확인한 사실(B): `restore` 성공 뒤 `loop.rng != restore 전 rng`(객체 교체, `project/core/tick.gd:270` `rng = new_rng`), `AudienceSystem.rng == loop.rng` 는 `false`.

측정값 (Godot 4.7.2, 위 구성 그대로):

| 경로 | 2일차 `noise_bp` | 2일차 입장 | 2일차 `by_type` | 2일차 평균 만족 | 2일차 뽑기 뒤 `loop.rng.audience` |
|---|---|---|---|---|---|
| A 연속 진행 | **413** | 122 | 12 / 68 / 42 | **6,662** | 8446068138391308941 |
| B 새 루프에 로드 | **228** | 122 | 12 / 68 / 42 | **6,666** | −4905547652258290101 (로드 직후 값 그대로, **전진하지 않음**) |
| C 되돌려 로드 | **642** | 122 | 12 / 68 / 42 | **6,667** | −4905547652258290101 (같음) |

- 복원 직후 `loop.rng.get_state()["audience"]` = −4905547652258290101, `AudienceSystem` 이 들고 있는 (복원 전) 객체의 `audience` 상태 = −1437828224877311366. 둘이 다르다.
- 입장 수가 같은 것은 이 시나리오의 수용 상한(122)에 걸렸기 때문이다. `noise_bp` 가 다르므로 상한이 없으면 입장 수도 다르다. 도착 순서(AD11 셔플)도 달라 평균 만족이 6,662 / 6,666 / 6,667 로 갈린다.
- 부수 증상: B·C 에서 audience 가 낡은 객체에서 뽑으므로 `loop.rng`(= 세이브에 들어가는 상태)의 `audience` 스트림이 2일차 뽑기에도 전진하지 않는다. 그 뒤 다시 저장하면 틀린 RNG 상태가 세이브에 들어가 오차가 누적된다.

## 기대 / 실제

- 기대: tick.md SH6 "복원 후 진행 = 연속 진행". 같은 스냅샷 `S` 에서 시작한 B·C 의 2일차는 A 와 `noise_bp`·도착 순서·요약이 모두 같다. 저장 후 다시 저장해도 `rng` 상태가 연속이다.
- 실제: `TickLoop.restore` 8(b) 가 `new_rng`(새 `SeededRng`)로 `rng` 필드를 **교체**한다. 시스템 생성자가 `loop.rng` 를 받아 둔 `AudienceSystem` 은 복원 전 객체를 계속 쓴다. `AudienceSystem.restore` 가 RNG 를 다루지 않는 것은 스펙(R3: `restore` 는 난수를 뽑지 않고, RNG 상태는 TickLoop 소유)대로이므로 결함 위치는 core 다.
- 왜 SE-034 테스트가 통과하는가: `test_au10b_tickloop_roundtrip` 은 저녁·공연 중간에 저장하고 같은 날 close 까지만 본다. 뽑기는 저녁 진입 틱에만 있으므로 (복원 시점 이후) 뽑기가 없다. **다음 날을 넘는 로드 테스트가 없다.**

## 영향

- 로드한 게임은 로드하지 않은 게임과 다음 날부터 다른 입장 수·도착 순서·요약을 낸다. 리플레이 해시가 깨지고 "세이브는 결정적이다" 계약이 무너진다.
- RNG 소비자가 늘면(SE-030 이후 events·world·artist 스트림) 같은 결함이 그 시스템에 퍼진다. 시스템이 생성자에서 `SeededRng` 를 받는 설계는 바꾸지 않아도 되도록 core 쪽에서 고치는 것이 맞다.

## 제안 수정 (sim-engineer, core)

- (권장) `restore` 가 기존 `SeededRng` 객체를 유지하고 상태를 적용한다. `master_seed`(복원한 `seed`)가 현재와 다르면 같은 객체의 스트림을 `derive_seed` 로 재시드한 뒤 `set_state`. `SeededRng` 에 `reseed(master_seed)`(스트림 객체는 유지하고 `seed` 만 다시 설정) 같은 메서드를 두면 `new_rng` 를 따로 만들 필요가 없다. 4단계 (b) 의 "검사를 끝낸 뒤 적용"(SH3)은 `new_rng` 로 미리 검증한 뒤 8(b) 에서 `rng.reseed(n_seed)` + `rng.set_state(rng_state)` 로 옮기면 지켜진다. `set_state` 는 이미 검증된 값이라 실패하지 않는다.
- (대안) SE-036 `GameSession` 이 로드 때 시스템을 다시 만든다. 로드 경로가 여러 곳이 되면 같은 문제가 되살아나므로 비추천.

## 수용 기준 (수정 티켓)

- [ ] AC1. `restore` 뒤 `loop.rng` 객체가 복원 전 객체와 같다(`==`), `AudienceSystem.rng == loop.rng`. → `test_tick*.gd` 또는 `test_audience_system.gd`
- [ ] AC2. 위 재현 B·C 가 A 와 같다: 2일차 `admissions_decided`·`day_summary` 해시 동일, 2일차 뽑기 뒤 `loop.rng.get_state()` 동일. → 정식 테스트(`project/tests/sim/`, "로드 → 다음 날 저녁" 케이스; 수정 전에는 실패해야 한다)
- [ ] AC3. 기존 SH 테스트(`restore` 거부 시 상태 불변, 롤백)와 `tools/run_tests.sh project/tests/sim` 녹색.
- [ ] AC4. 거부 케이스(rng 상태 형식 오류, 시드 범위 밖)에서 `loop.rng` 상태·객체가 변하지 않는다(SH3).

## 결과

(수정 담당 기록)
