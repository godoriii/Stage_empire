# SE-029-bug `pass_tile_cap`(MV2/T8) 머리 맞댐 교착 — 경로 동점 처리에 따라 기준 시나리오에서도 조기 퇴장·AU8/AT6 실패

| 항목 | 값 |
|---|---|
| 상태 | 해결 (ff33a7d, qa 재검증 2026-10-09) |
| 담당 에이전트 | game-designer (규칙 + `audience.json` `flow` 필드 + 스키마), 이후 sim-engineer (SE-034 가 반영) |
| 마일스톤 | MVP |
| 의존 티켓 | SE-029 (같은 브랜치에서 병합 전에 고치거나, 병합 뒤 SE-034 시작 전 후속 티켓으로) |
| 스펙 | docs/gdd/audience.md #상태-기계(T7·T8·T12, MV2, P1), #기준-시나리오("경로 동점 처리가 달라도 평균은 바뀌지 않는다"), 수용 기준 AU6·AU8, 수치 목표 AT6 |
| 심각도 | 중간~높음 (데이터·문서 AC 는 영향 없음. 그러나 스펙대로 구현하면 `TilePath` 동점 처리에 따라 AU8·AT6 이 실패할 수 있고, 150명 스트레스에서는 BFS 에서도 발생한다) |

## 요약

`pass_tile_cap`(2)과 "다른 에이전트는 경로를 막지 않는다"(SP 절)의 조합은 서로 반대로 가는 두 사람이 인접한 두 칸에 2명씩 서 있을 때 **영원히 풀리지 않는 교착**을 만든다. T8 은 막힌 사람에게 대기만 더하고, 풀리는 길은 P1 조기 퇴장(나가는 사람은 cap 무시, T12)뿐이다. 설계자의 프로토타입(BFS, 4방향 x 우선)은 기준 시나리오에서 이 교착이 안 났지만, 경로 동점 처리를 바꾸면 나는 정도가 아니라 **기준 시나리오 4개 중 3개가 조기 퇴장 5~28명으로 무너진다.** SE-034 는 `AStarGrid2D` 래퍼(`TilePath`, SE-032)를 쓰고 그 동점 처리는 스펙이 정하지 않았다.

## 재현 절차

독립 구현 시뮬레이터(`tools/bot/audience_spec_check.py`, audience.md 규칙을 본문만 보고 옮긴 것, 제품 코드 없음). 시드 0, 1일차, 기준 배치 `baseline_show`.

```bash
python3 tools/bot/audience_spec_check.py --bfs-order x    # 설계자 프로토타입과 같은 4방향 순서(+x, −x, +z, −z). 기준 시나리오 조기 퇴장 0, 평균 4600/6731/6725/5727
python3 tools/bot/audience_spec_check.py --bfs-order z    # 4방향 순서만 바꿈(+z, −z, +x, −x)
python3 tools/bot/audience_spec_check.py --bfs-order z --pass-override 10   # 권고안 실험
```

| 경로 동점 처리 | 시나리오 | `left_early` (기대 0) | 최대 대기 틱 | 평균 만족 (기대 범위) | 공연 시작 때 자리에 못 선 사람 |
|---|---|---|---|---|---|
| x 우선 (`--bfs-order x`) | local_top_baseline / rookie_baseline / local_top_price30 | 0 / 0 / 0 | 2 / 12 / 4 | 6731 / 6725 / 5727 (6432~6732 / 6433~6733 / 5430~5730) | 0 |
| **z 우선 (`--bfs-order z`)** | local_top_baseline | **5** | 182 | **6154** (범위 하한 6432 미달) | 8 |
| | rookie_baseline | **28** | 301 | **5616** (하한 6433 미달) | 31 |
| | local_top_price30 | **5** | 301 | **5036** (하한 5430 미달) | 4 |

- 방향 순서를 바꾼 변형 4개(x, z, 역 x, 역 z)로 보면 x 계열 둘은 조기 퇴장 0, z 계열 둘은 위 표와 같다(기준 시나리오 3개 합계 38명).
- 150명 스트레스(수용 150·인기 100·명성 2,000, `s12` 기준): x 우선에서도 시드 1 이 조기 퇴장 7명·최대 대기 161틱(시드 0~29 중 3개 시드가 발생), z 우선은 30개 시드 전부 발생(평균 27명). 설계자 결과 문구 "150명 스트레스 조기 퇴장 0, 최대 대기 12틱"은 이 변형 어디서도 재현되지 않았다(x 우선 시드 0 은 조기 퇴장 0, 최대 대기 40).
- 교착 실체(x 우선, 150명, 시드 1, 틱 300~400 내내 동일): 타일 `(17,9)`에 에이전트 58·59(목표 `(5,15)`·`(5,19)`)가 서 있고 둘 다 `(16,9)`로 가려 한다. `(16,9)`에는 62·68(목표 `(18,16)`·`(19,19)`)이 서서 둘 다 `(17,9)`로 가려 한다. 두 칸 모두 `occ == 2 ≥ pass_tile_cap`이라 아무도 못 움직이고, 그 뒤로 56·71·72 등이 줄줄이 막혀 `patience_ticks`(뜨내기 150) 초과 → `reason "patience"` 7건(틱 419~481).
- 원인: 관람 자리는 무대 앞 음향 무게중심에서 가까운 순으로 채워지므로(SP1) 군중이 가운데로 몰리고, 들어오는 사람과 바에서 돌아오는 사람이 같은 통로에서 반대로 간다. 경로는 한 번 정해지면 바뀌지 않는다(MV2). 서 있는 사람이 칸마다 1명씩 있어(자리 예약 1) 지나가는 사람은 칸당 1명만 더 들어갈 수 있다.

## 기대 / 실제

- 기대(스펙): 기준 시나리오 조기 퇴장 0(AT6, AU8 `left_early == expected`), 평균 만족이 `[손계산 − 300, 손계산]`(AU8), "경로 동점 처리가 달라도 평균은 바뀌지 않는다"(audience.md 기준 시나리오 절). "교착은 인내로 반드시 풀린다"(T12 설명)는 풀리긴 하나 풀리는 대가가 만족 폭락과 조기 퇴장이다.
- 실제: 위 표. 스펙대로 구현한 SE-034 의 `TilePath` 동점 처리에 따라 AU1·AU8·AT6 이 실패한다. 구현자는 규칙을 어길지 테스트 기대값을 바꿀지 판단할 수 없다(데이터 기대값은 game-designer 소유).

## 제안 (검증한 것)

T8 에 "연속으로 K 틱 막히면 그 틱부터 `pass_tile_cap`을 무시하고 들어간다"(T12 의 나가는 사람 규칙과 같은 방식)를 더한다. 새 필드 `flow.pass_override_ticks`(스키마 version 2, `audience.json` version 2), 막힌 연속 틱 수는 에이전트 레코드의 새 키 `blocked`(스냅샷 RU6 키 수 18 → 19). 시뮬 결과(시드 0, 150명 스트레스는 시드 0~9):

| K (`pass_override_ticks`) | 경로 동점 4변형 모두에서 기준 시나리오 조기 퇴장 | 기준 시나리오 최대 대기 (x / z 우선) | 평균 만족 (z 우선, 기대 범위 안?) | 150명 스트레스 조기 퇴장 합 (x / z 우선) |
|---|---|---|---|---|
| 없음 (현행) | 0 (x 계열) / 38 (z 계열) | 12 / 301 | 6154 / 5616 / 5036 (범위 밖) | 7 / 289 |
| 10 | 0 | 11 / 33 | 6703 / 6695 / 5715 (범위 안) | 0 / 0 |
| 20 | 0 | 12 / 63 | 6675 / 6622 / 5706 (범위 안) | 0 / 0 |
| 40 | 0 | 12 / 137 | 6589 / 6457 / 5674 (범위 안) | 0 / 0 |

- K 는 10(1초) 권장. 칸당 순간 점유가 2를 넘어도 `agent_moved` 표시에는 문제가 없다(좌표는 보간값). 점유 상한은 RU 의 "하지 않는 의미 검사"에 이미 `occ ≤ pass_tile_cap`이 빠져 있다.
- 다른 안: (b) 서로 막고 있는 두 사람 교환 허용(스왑 검출 필요, 3자 이상 사이클은 못 잡음), (c) 경로 비용에 서 있는 사람 칸을 더하기(SP 절의 "다른 에이전트는 경로를 막지 않는다" 번복 + TilePath 비용 지원 필요). K 방식이 SE-034 구현이 가장 단순하고 결정적이다.
- 같이 바꿀 곳: audience.md T8 행, MV2, "경로 동점 처리가 달라도 평균은 바뀌지 않는다" 문장(K=10 적용 뒤에도 평균은 경로 동점 처리에 따라 ~30 bp 달라진다 — 위 표 z 우선 6703 vs x 우선 6731 — 이므로 "범위 안"으로 완화), AU4(T8 케이스에 K 틱 뒤 통과 추가), AU6(현재 "다음 칸을 계속 막아 인내 초과"는 K 틱 뒤에 막힘이 풀려 성립하지 않는다 — 입구가 계속 차 있는 `queued` 대기(T3)나 자리 없음 `no_spot`으로 유발하도록 바꾼다), 변이 확인 문장, 스키마 `flow`.

## 결과

(해결되면 기록. 재현 안 됨으로 닫지 않는다.)

game-designer, 2026-10-09. producer 결정 = 제안 (a) K = 10(audience.md Q12).

- 규칙: T7 에 "`blocked ≥ pass_override_ticks`이면 `pass_tile_cap`을 무시하고 건너기 시작(`blocked = 0`)", T8 에 "`blocked += 1`, 대기 +1". 에이전트 레코드 `blocked`(RU6 18 → 19키). MV2·점유 설명·T12 설명, AU4(밀고 들어감 케이스), AU6(인내 초과 유발을 `queued` 대기 T3·바 실패·복원 레코드로), 변이 문장, 기준 시나리오의 "평균은 바뀌지 않는다" → "범위 안"(시드 0 한정 명시), 설계 프로토타입 참고 문단을 qa 시뮬 결과로 교체.
- 데이터: `audience.json` `flow.pass_override_ticks: 10`, `version` 1 → 2. `audience.schema.json` 필수 필드 추가, `version` enum `[2]`.
- `expected` 변경 없음: `python3 tools/bot/audience_spec_check.py --bfs-order {x,z,rev,revz} --pass-override 10` 네 변형 모두 `MISMATCH: 없음`, 기준 시나리오 시드 0~39 조기 퇴장 0·미착석 0. 시드 0 평균 x 우선 4,600 / 6,731 / 6,725 / 5,727, z 우선 4,599 / 6,703 / 6,695 / 5,715(전부 `avg_satisfaction_bp_range` 안). 150명 스트레스 시드 0·1 조기 퇴장 0, 최대 대기 x 16·14 / z 40·34.
- qa 낮음 2~5 도 문서로 처리: `time.day_started`가 `lineup = null`(2), view 계약 "무대 방향"(초점 셀, 모르면 +z, 로드 뒤 SE-037 가구 복구 경로)(3), 만족 범위 시드 0 한정(4), 바 방문 수 ↔ economy 바 구매 인원 4개 시나리오 수치와 차이 이유(5).
- **남은 일(qa — game-designer 경계 밖):**
  - `project/tests/sim/test_audience_data.gd` 2곳. 405행 `assert_eq(int(_a["version"]), 1)` → `2`, 420~421행 `flow` 기대 사전에 `"pass_override_ticks": 10` 추가. 이 두 단언 때문에 현재 `tools/run_tests.sh project/tests/sim` 결과는 127 중 125 통과다. 수정 시도를 경계 hook 이 막았다(`project/tests/`는 qa 범위).
  - `tools/bot/audience_spec_check.py` 의 `--pass-override` 기본값을 `flow.pass_override_ticks`에서 읽게 갱신(qa 재검증 방법 문구대로).

- qa 재검증 방법: 수정 후 `python3 tools/bot/audience_spec_check.py --bfs-order z`(과 `--bfs-order x`, `--bfs-order rev`, `--bfs-order revz`) 가 `MISMATCH: 없음`이고 150명 스트레스 두 시드 조기 퇴장 0 이면 닫는다. `--pass-override`는 권고안 실험 옵션이라 규칙이 바뀌면 스크립트를 같이 갱신한다.

- qa 재검증(2026-10-09, HEAD f348386 + qa 후속 수정):
  - 후속 2건 처리: `test_audience_data.gd` `version` 단언 1 → 2, `flow` 기대 사전에 `"pass_override_ticks": 10` 추가, `pass_override_ticks ≥ 1`·`< walk_in.patience_ticks` 단언 추가. `audience_spec_check.py` `--pass-override` 기본값을 `audience.json` `flow.pass_override_ticks`(10)에서 읽게 변경.
  - `python3 tools/bot/audience_spec_check.py --bfs-order {x,z,rev,revz} --seeds 40` 네 변형 전부 `MISMATCH: 없음`. 기준 시나리오 시드 0~39 조기 퇴장 0·미착석 0. 시드 0 평균 x 계열 4,600 / 6,731 / 6,725 / 5,727, z 계열 4,599 / 6,703 / 6,695 / 5,715(전부 `avg_satisfaction_bp_range` 안). 최대 대기 x 계열 11 / z 계열 33틱(시드 0), 시드 0~39 x 18 / z 38.
  - 150명 스트레스(수용 150·인기 100·명성 2,000) 시드 0~9 × 4변형: 조기 퇴장 합 0, 미착석 0, 최대 대기 x 16 / rev 20 / z·revz 46틱. 수정 전 z 우선 289명, x 우선 7명이던 조기 퇴장이 모두 0.
  - `tools/run_tests.sh project/tests/sim` 14 스크립트 127 테스트 전부 통과(어서션 7,592). strict exit 0, audience.md qa 스크립트 `AU OK`.
