# SE-032-bug 64비트 `cell` 좌표가 int32 로 잘려 맵 밖 배치가 통과한다 (B5/RS4 우회)

| 항목 | 값 |
|---|---|
| 상태 | 해결 (fa1c624) |
| 담당 에이전트 | sim-engineer (수정), game-designer (스펙 문구 확인: 좌표 범위 한 줄) |
| 마일스톤 | MVP |
| 의존 티켓 | SE-032 (구현), SE-028 (스펙 build.md B1·B5·RS4) |
| 스펙 | docs/gdd/build.md#배치-규칙 B1·B5, #스냅샷 RS4, #좌표·회전·점유 G3 |
| 브랜치 | feature/SE-032-build-system 에 후속 커밋(또는 별도 fix 브랜치) |
| 심각도 | 낮음~중간. UI 가 만드는 좌표로는 도달 불가, 퍼저·봇·손상된 세이브·악의적 명령에서만. 단 시뮬레이션 상태와 이벤트가 어긋나 렌더(SE-037)가 틀린 위치에 모델을 그린다 |

## 재현 절차

- 새 게임(`BuildConfig.load()`, `BuildSystem` + `Economy` 한 버스, 시작 현금 5,000, 낮).
- 입력: `build.place_requested {furniture_id:"speaker_floor", cell:[4294967301, 5], rotation:0}` → `bus.dispatch_commands()`. (4294967301 = 2^32 + 5)
- 틱 번호: 해당 없음(`TickLoop` 없이 버스 직접. TickLoop.advance(0) 경로도 같은 핸들러).
- 재현 도구: 임시 GUT 테스트로 측정 후 삭제(`project/tests/sim/test_zz_probe_tmp.gd`, 저장소에 남기지 않음). 재현 테스트를 `known bug` 로 추가하는 것은 수정 티켓의 AC2.

측정값 (Godot 4.7, `check_place` 와 실제 명령 비교):

| `cell` | `check_place` | 명령 결과 | 비고 |
|---|---|---|---|
| `[4294967301, 5]` | `""`(통과) | **`build.placed {cell:[4294967301, 5], cells:[[5,5]]}`**, cash 4,800 | x 가 2^32+5 → int32 로 5 |
| `[5, 4294967301]` | `overlap` | `rejected · overlap` | z 가 5 로 잘려 위 인스턴스와 겹침(맵 밖으로 판정되지 않음) |
| `[-4294967291, 5]` | `overlap` | `rejected · overlap` | x 가 5 로 잘림 |
| `[4294967307, 0]` | `blocked_tile` | `rejected · blocked_tile` | x 11, z 0 = 입구로 잘림(맵 밖 아님) |
| `[9223372036854775807, 5]` | `out_of_bounds` | `rejected · out_of_bounds` | 2^63−1 은 int32 로 −1 → 정상 거절(우연) |

설치 직후 `instances[0].cell == [4294967301, 5]`, 점유 셀은 `[5,5]`. `snapshot()` → JSON 왕복 → `restore()` 도 `true` (RS4 도 같은 잘림을 거친다).

## 기대 / 실제

- 기대: B5 "점유 셀 중 하나라도 맵 밖(`x < 0`, `z < 0`, `x ≥ width`, `z ≥ depth`)이면 `out_of_bounds`". 어떤 `int` 좌표든 `[0, 24)` 밖이면 거절. `build.placed.cell` 과 `cells` 는 항상 일치(G3: `cells` 의 최소 모서리 == `cell`).
- 실제: `GridOccupancy.rect_of()` 가 `Rect2i(int(cell[0]), int(cell[1]), …)` 로 만들고 `Rect2i`/`Vector2i` 의 성분이 32비트 정수라 GDScript 의 64비트 `int` 가 잘린다. `_check_rules` 의 B5·B6·B7 이 잘린 좌표로 판정하고, 이벤트·인스턴스·스냅샷에는 원래 64비트 좌표가 그대로 기록된다. `restore` RS4 도 `GridOccupancy.cells_of` 를 쓰므로 같은 우회가 열려 있다.

## 영향

- 실제 UI(타일 클릭)는 `[0, 24)` 범위 좌표만 만든다. 영향은 퍼저·봇·손상된 세이브·악의적 모드뿐이다.
- 일단 통과하면 모델 위치(`cell` 로 그리는 G5)와 점유(`cells`)가 달라져, 렌더는 24×24 밖 먼 곳에 그리고 시뮬레이션은 `[5,5]` 를 점유한다. 리플레이·스냅샷 해시는 결정적이라 "조용히 틀린 상태"가 된다.

## 수정 제안 (구현은 sim-engineer)

- B5 를 Rect2i 로 만들기 **전에** 원래 `int` 로 판정한다: `cell[0]`, `cell[1]` 과 회전된 `[W', D']` 로 `x < 0 or z < 0 or x + W' > width or z + D' > depth` (64비트 비교, 오버플로 없는 범위만 쓰려면 먼저 `abs(cell) ≤ width + depth` 같은 상한을 map 크기에서 계산). 숫자 리터럴 없이 `config.map.width/depth` 만 쓴다.
- `restore` RS4 에도 같은 사전 검사를 적용한다.
- `check_place` 도 같은 경로라 함께 고쳐진다. 스펙 문구 변경은 필요 없다(B5 가 이미 이렇게 읽힌다). 원하면 build.md B1 에 "좌표는 64비트 `int` 전체 범위가 올 수 있고 B5 가 거절한다" 한 줄.
- 추가 점검: `TilePath.find_path(from, to)` 는 `is_passable`(raw int 로 `in_bounds`)을 먼저 거쳐 안전하다(확인함). 같은 패턴(`Vector2i(int(...))`)을 쓰는 곳을 한 번 훑을 것.

## 수용 기준

- [ ] AC1. 위 표의 `[4294967301, 5]`, `[5, 4294967301]`, `[-4294967291, 5]`, `[4294967307, 0]` 이 `check_place` 와 명령 모두 `out_of_bounds`(`wall`/`입구` 같은 다른 이유가 아님), `instances` 불변, `charge_proposed` 0건.
- [ ] AC2. 같은 좌표 4종을 `restore` 의 `instances[].cell` 에 넣은 스냅샷이 `false`·`push_error` 1회·상태 불변(RS4). `project/tests/sim/test_build_system.gd` 의 `_bad_snapshots` 와 `test_bc06_out_of_bounds` 에 케이스 추가(또는 새 테스트).
- [ ] AC3. 기존 `tools/run_tests.sh project/tests/sim` 녹색, 특히 `test_build_oracle_qa.gd`(독립 오라클 차분)와 `replay/test_replay_build.gd` 회귀 없음.

## 테스트 방법

- 헤드리스: `tools/run_tests.sh project/tests/sim` 의 `test_build_system.gd`(AC1·AC2 케이스 추가).

## 경계 확인

- 쓰는 폴더: `project/world/`, `project/tests/sim/` (sim-engineer 범위).
- 읽기만 하는 폴더: `project/data/`, `docs/gdd/`.
- 새 이벤트·데이터 필드 없음.

## 결과

sim-engineer, 2026-10-09.

- 원인: `GridOccupancy.rect_of`/`cells_of` 의 `Rect2i`·`Vector2i` 가 int32 라 64비트 `cell` 이 잘린 뒤 B5~B7·RS4 가 잘린 좌표로 판정했다.
- 수정:
  - `GridOccupancy.rect_in_bounds(footprint, cell, rotation, width, depth)`(신규)는 회전 후 사각형이 `[0, width) × [0, depth)` 안인지 64비트 `int` 그대로 비교한다(`x ≤ width − W'` 꼴이라 덧셈 오버플로 없음, 리터럴 없음).
  - `BuildSystem._check_rules` 의 B5 를 이 검사로 바꿔 `Rect2i` 변환보다 먼저 둔다(명령 핸들러·`check_place` 공통 경로). `_parse_snapshot` 의 RS4 도 `cells_of` 전에 같은 검사를 한다.
- 같은 패턴 점검:
  - `TilePath.find_path` 는 `Vector2i` 로 바꾼 뒤 `is_passable(a.x, a.y)` 를 불러 같은 잘림이 있었다. 리포트의 "안전"과 달리 `[2^32+5, 5]` 를 `[5,5]` 로 봤다. 원래 `int` 로 먼저 검사하도록 고쳤다.
  - `GridOccupancy.is_occupied`/`owner_of` 는 `fits_cell`(Vector2i 왕복 비교)로 표현 불가 좌표를 "셀 아님"으로 본다.
  - 나머지 `Vector2i(...)` 생성은 검사를 통과한 셀이나 맵 루프 좌표만 받는다.
- 테스트(+4):
  - `test_build_system.gd` `test_bug_64bit_cells_out_of_bounds`: 표의 5좌표 + int64 최솟값, `speaker_floor`·`stage_small` 두 가구. `[5,5]` 를 미리 점유해 둔 상태에서 `check_place`·명령 모두 `out_of_bounds`, 받은 `cell` 그대로 거절, `charge_proposed` 0, 상태 불변.
  - `test_bug_64bit_cells_restore_rs4`: 같은 좌표가 든 스냅샷 → `false`·`push_error` 1회("RS4")·상태 불변·이벤트 0. 2^53 미만 좌표는 JSON 왕복 경로도 같다.
  - `test_tile_path.gd` `test_64bit_endpoints_rejected`, `test_grid_occupancy.gd` `test_rect_in_bounds_64bit`.
  - 수정 전 코드로 돌리면 세 동작 테스트가 실패한다(grid 스크립트는 새 함수가 없어 로드 실패). 수정 후 녹색.
- 보너스(qa 발견 3): `test_map_config.gd::test_load_ok` 의 JSON float 비교 3곳을 `int()` 로 접어 GUT "Float/Int comparison" 경고 0.
- 결과: `tools/run_tests.sh project/tests/sim` 23 스크립트 / 175 통과(기존 171 + 4), `validate_data.py --strict` exit 0. 스펙 문구 변경 없음(B5 가 이미 그렇게 읽힌다).

## QA / 리뷰

- QA 리포트: docs/reports/SE-032.md
- 리뷰: docs/reviews/SE-032.md
