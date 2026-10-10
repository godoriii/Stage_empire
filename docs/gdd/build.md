# 건설·배치 (build.md)

| 항목 | 값 |
|---|---|
| 상태 | v0 |
| 스펙 티켓 | SE-028 (game-designer) |
| 구현 티켓 | SE-032 (sim-engineer, build 시스템·커버리지·짝 테스트), SE-037 (render-engineer, 배치 UI·오버레이), SE-041 (art-pipeline, 가구 에셋) |
| 데이터 | [`project/data/furniture/furniture.json`](../../project/data/furniture/furniture.json) (version 1, 20행), 스키마 [`furniture.schema.json`](../../project/data/schemas/furniture.schema.json) · [`project/data/maps/tier1_club.json`](../../project/data/maps/tier1_club.json) (version 1), 스키마 [`maps.schema.json`](../../project/data/schemas/maps.schema.json). 읽기 참조: [`tiers.json`](../../project/data/tiers/tiers.json) `grid_size`·`capacity_max`, [`economy.json`](../../project/data/economy/economy.json) `rate_scale`·`starting_cash`·`demolish_refund_rate_bp`·`reference_scenarios[tier1_baseline]`, [`sim.json`](../../project/data/sim/sim.json) `phases`·`system_order` |
| 이벤트 | [events.md](events.md)의 `build.*` 6행. 이 문서에 나오는 이벤트 이름은 전부 거기 표에 있다 |
| 근거 | PRD "핵심 시스템 상세"(건설·배치 행), "아이소메트릭 렌더링과 UX 요구사항"(그리드·배치 규칙·오버레이 행), "콘텐츠 범위"(MVP 가구 20), [economy.md#입력-계약](economy.md#입력-계약), [tick.md](tick.md), [materials.md](materials.md) Q1, `docs/style-guide.md` "타일 점유 표기"·"폴리곤 예산", `tools/assets/GLTF_SPEC.md` §1 |

## 목적

티어 1 지하 클럽(24×24)에 가구를 놓고 치우는 규칙과, 그 배치에서 공연·관객·경제가 받는 수치(커버리지·수용 인원·피난 용량·유지비)를 공식 하나로 고정한다.
build 는 가구 인스턴스 목록만 소유한다. 현금은 economy 가 바꾸고, build 는 `economy.charge_proposed`/`economy.refund_proposed`/`economy.upkeep_reported`로 **제안·보고**만 한다.
이 문서와 데이터 두 파일만 보고 sim-engineer 가 build 시스템(SE-032)을, render-engineer 가 배치 UI(SE-037)를, art-pipeline 이 에셋(SE-041)을 질문 없이 시작할 수 있어야 한다.

v0 범위: 고정 맵 1개, 단일 타일 클릭 배치(가구 1개 = 명령 1개), 회전 4방향, 철거, 커버리지 5종 + 보조 3종, economy 핸드셰이크, 스냅샷.
범위 밖: 방 드래그 지정(PRD "드래그로 방 영역" — v0 는 클릭 배치만, Q1), 스태프·구역(버티컬 슬라이스), 가구 이동(철거 + 재배치로 대신), 고장·상태 변형(`events_crisis.md`), 만족도 공식에서 커버리지를 쓰는 법(`show.md`), 관객 이동(`audience.md`), 티어 2+ 맵.

PRD 결정(그리드 1타일 = 1m, 티어 1 24×24, 회전 R·취소 Esc·철거 환불 70%, 고정 틱)은 바꾸지 않는다. 환불률은 `economy.json` `demolish_refund_rate_bp`(스키마 enum 7000 고정)를 그대로 쓴다.

## 규칙

### 좌표·회전·점유

| # | 규칙 |
|---|---|
| G1 | 타일 좌표는 `[x, z]` 정수. 원점 `[0, 0]`은 맵 `tiles[0]`의 첫 글자, `x`는 문자열 안 인덱스(오른쪽 +), `z`는 `tiles` 배열 인덱스(아래쪽 +). 렌더 규약(`IsoGridMath`)과 같다: 타일 `(x, z)`는 월드 `[x, x+1) × [z, z+1)` m |
| G2 | 가구의 `footprint [w, d]`는 회전 0 에서 x 방향 `w`칸, z 방향 `d`칸이다(style-guide `w×d`). 회전 90·270 에서는 `[W', D'] = [d, w]`, 0·180 에서는 `[w, d]` |
| G3 | 명령의 `cell`은 **회전 후 점유 사각형의 최소 모서리**(x 최소, z 최소)다. 점유 셀 = `x ∈ [cell.x, cell.x + W')`, `z ∈ [cell.z, cell.z + D')`. 회전은 `cell`을 바꾸지 않는다 |
| G4 | `rotation`은 도 단위 `int`, `build_rules.allowed_rotations`(0, 90, 180, 270) 중 하나. 방향은 Godot `rotation_degrees.y`와 같다(위에서 볼 때 반시계). 모델 정면은 회전 0 에서 −z(GLTF_SPEC §1) |
| G5 | 렌더 배치: 위치 = 월드 `((cell.x + W'/2) × t, 0, (cell.z + D'/2) × t)`(`t` = `sim.json.tile_size_m`), `rotation_degrees.y = rotation`. 피벗이 점유 영역 중앙(GLTF_SPEC §1)이라 이 식으로 모델이 점유 셀에 정확히 겹친다 |
| G6 | 점유 셀 목록의 순서는 z 오름차순, 같은 z 에서 x 오름차순(이벤트 `cells`, 테스트 비교 모두 이 순서) |

회전별 방향표(사각형 `x0..x1`, `z0..z1`은 점유 셀의 최소·최대 좌표):

| `rotation` | 정면 방향 | `[W', D']` | 등면 이웃(B8 검사 셀) | 앞 행(B10 (b), 커버리지 관람 반평면 경계) | 앞 반평면(관람 타일 후보) | 초점 셀 후보(정면 가장자리, 정렬 기준) |
|---|---|---|---|---|---|---|
| 0 | −z | `[w, d]` | `(x, z1+1)`, `x ∈ x0..x1` | `(x, z0−1)`, `x ∈ x0..x1` | `z < z0` | `(x, z0)`, `x` 오름차순 |
| 90 | −x | `[d, w]` | `(x1+1, z)`, `z ∈ z0..z1` | `(x0−1, z)`, `z ∈ z0..z1` | `x < x0` | `(x0, z)`, `z` 오름차순 |
| 180 | +z | `[w, d]` | `(x, z0−1)`, `x ∈ x0..x1` | `(x, z1+1)`, `x ∈ x0..x1` | `z > z1` | `(x, z1)`, `x` 오름차순 |
| 270 | +x | `[d, w]` | `(x0−1, z)`, `z ∈ z0..z1` | `(x1+1, z)`, `z ∈ z0..z1` | `x > x1` | `(x1, z)`, `z` 오름차순 |

예: `bar_counter`(`[3, 1]`)를 `cell [20, 4]`, `rotation 90`으로 놓으면 `[W', D'] = [1, 3]`, 점유 셀 `[20,4] [20,5] [20,6]`, 정면 −x(방 안쪽), 등면 이웃 `[21,4] [21,5] [21,6]`.

### 맵

맵은 데이터 파일 하나(`project/data/maps/<id>.json`)다. v0 는 `tier1_club` 하나이고 새 게임은 이 맵으로 시작한다.

**타일 종류.** `tile_kinds[]`의 id 는 5종으로 고정(규칙이 id 로 참조), 속성은 데이터다. `tier1_club` 값:

| id | 글자 | `buildable` | `walkable` | `standing` | `blocks_sight` | `mountable` | `evac_capacity` | 뜻 |
|---|---|---|---|---|---|---|---|---|
| `floor` | `.` | true | true | true | false | false | 0 | 바닥. 가구를 놓을 수 있고 관객이 선다 |
| `wall` | `#` | false | false | false | true | **true** | 0 | 외곽 벽. 벽 필요 가구가 등을 붙인다 |
| `pillar` | `P` | false | false | false | true | false | 0 | 지하 기둥. 시야를 막고 등을 붙일 수 없다 |
| `entrance` | `E` | false | true | false | false | false | **40** | 입구(고정, 철거 불가 — 가구가 아니라 entity 가 없다). 도달 가능성 BFS 의 시작점 |
| `apron` | `a` | false | true | false | false | false | 0 | 입구 안쪽 완충 타일. 배치 불가라 입구가 직접 막히지 않는다 |

맵 밖 좌표는 종류가 없다: 배치는 B5(`out_of_bounds`), 등면 이웃이면 `mountable` 아님, 걷기·시야 계산에는 나오지 않는다(외곽이 벽이라).

**`tier1_club` (24×24).** 외곽 벽, 북쪽 벽 가운데 입구 2칸 `[11,0] [12,0]`, 그 안쪽 완충 2칸 `[11,1] [12,1]`, 기둥 4개 `[7,8] [16,8] [7,15] [16,15]`.

```
     000000000011111111112222
     012345678901234567890123
z 0  ###########EE###########
z 1  #..........aa..........#
z 2  #......................#
z 3  #......................#
z 4  #......................#
z 5  #......................#
z 6  #......................#
z 7  #......................#
z 8  #......P........P......#
z 9  #......................#
z10  #......................#
z11  #......................#
z12  #......................#
z13  #......................#
z14  #......................#
z15  #......P........P......#
z16  #......................#
z17  #......................#
z18  #......................#
z19  #......................#
z20  #......................#
z21  #......................#
z22  #......................#
z23  ########################
```

| 값 | 수 | 계산 |
|---|---|---|
| 내부(외곽 벽 안) | 484 | 22 × 22 |
| `floor` | 478 | 484 − 기둥 4 − 완충 2 |
| `entrance` | 2 | 피난 용량 2 × 40 = 80 |
| 입구 → 중앙 경로 | 있음 | `x = 11` 열: `[11,0]`(E) → `[11,1]`(a) → `[11,2]` … `[11,12]` 전부 `floor`. 빈 맵의 걷기 가능 타일 482 개(바닥 478 + 완충 2 + 입구 2)가 모두 입구와 4방향으로 연결된다(MK6) |

`persons_per_tile_bp` 2,500(자유 바닥 1칸당 0.25명, C4)도 맵 값이다. 지하 클럽의 좁은 동선·기둥·바 대기 공간을 뭉뚱그린 계수이고 티어마다 맵 파일이 따로 갖는다.

### 가구 카테고리와 필드

| 카테고리 | id | v0 행 | 역할 |
|---|---|---|---|
| 무대 | `stage` | 2 | 관람 방향·시야 초점·기본 음향. 맵당 1개(`category_max_count.stage`) |
| 음향 | `sound` | 3 | 음향 커버리지(`sound_radius`) |
| 조명 | `light` | 4 | 연출 등급(`light_grade`) |
| 바 | `bar` | 2 | 바 서비스 커버리지(`bar_service_radius`) |
| 편의 | `amenity` | 4 | 수용 인원 가산, 만족도 가산 |
| 안전 | `safety` | 3 | 피난 용량(`evac_capacity`) |
| 장식 | `decor` | 2 | 만족도 가산 |

행 필드(전부 필수, `model`만 선택). 스키마가 타입·범위를 강제하고, 아래 "설정 로드 검사"가 교차 규칙을 강제한다.

| 필드 | 타입 | 뜻 |
|---|---|---|
| `id` | String `^[a-z][a-z0-9_]*$` | 가구 id. 명령·이벤트·스냅샷이 쓴다 |
| `name` | String | 표시 이름(한국어 v0). 로컬라이즈 키 분리는 후속 content 티켓 |
| `category` | enum 7종 | 위 표 |
| `footprint` | `[w, d]` int 1~8 | 회전 0 점유(G2). SE-027 `META.json`과 같은 이름 |
| `height_m` | number | 모델 높이 m. 에셋 AABB 검사·렌더 전용. **시뮬레이션은 읽지 않는다**(시야 차단은 `effects.sight_block`) |
| `build_cost` | int ≥ 1 | 건설비 = `economy.charge_proposed.amount` |
| `upkeep_per_day` | int ≥ 0 | 1일 유지비 = `economy.upkeep_reported.total`의 항 |
| `rotatable` | bool | false 면 `rotation 0`만 |
| `wall_required` | bool | true 면 등면 이웃이 전부 `mountable`(B8) |
| `poly_budget` | `furniture_small` \| `equipment_large` | style-guide "폴리곤 예산"의 칸(값은 style-guide 에만, GLTF_SPEC §7) |
| `slots` | `{base, accent?, emissive?, glass?}` | 슬롯별 색. 임시 hex `#RRGGBB` 또는 팔레트 id `pal_*`(materials.md Q1 (a)). 키가 있는 슬롯 = 그 서피스가 있는 모델 |
| `effects` | 7키 전부 필수 | 커버리지 입력(#커버리지). 0/false = 효과 없음 |
| `model` | String(선택) | **예약.** `res://assets/models/<id>.glb`. 없거나 `""`이면 플레이스홀더. 값이 있어도 그 경로에 리소스가 없으면(검수 전) 플레이스홀더(FurnitureView `ResourceLoader.exists` 분기, 경고 없음). SE-041: `stage_medium`·`bar_counter`·`speaker_floor`·`bar_fridge`·`light_spot` 5행 등록(테스트용 에셋, 교체 시 파일만 바꾸고 경로는 그대로), 나머지 15행은 키 없음 |

### 상태

build 가 소유하는 상태. 스냅샷 대상은 `instances`·`next_entity`·`phase`다. 나머지는 파생값이거나 경계에서 항상 비어 있다.

| 필드 | 타입 | 새 게임 값 | 설명 |
|---|---|---|---|
| `instances` | Array | `[]` | 설치 인스턴스, entity 번호 오름차순(= 설치 순). 원소 `{entity_id: String, furniture_id: String, cell: [x, z], rotation: int, paid: int}`. `paid` = 설치 때 승인된 건설비(철거 환불 기준, economy F3) |
| `next_entity` | int | 1 | 다음 entity 번호. entity id 는 `"f" + str(n)`(예: `"f1"`). 거절된 배치는 번호를 쓰지 않는다. 철거된 번호는 재사용하지 않는다 |
| `phase` | String | `"day"` | `time.phase_changed.to`를 따라온 구간(B2·D2 판정). economy `phase`와 같은 방식으로 스냅샷에 넣는다(Q6). `to`가 `sim.json` `phases[].id`가 아니면 `push_error` 1회 후 무시(`phase` 불변, `sync` 없음 — 바꾸면 자기 스냅샷이 RS1 에 걸린다, SE-044) |
| `occupancy` | 파생 | — | 셀 → entity. `instances`에서 다시 만든다 |
| `pending` | Dictionary 또는 `null` | `null` | 승인 대기 중인 배치 1건(H1~H4). 같은 경계 안에서 반드시 비워진다 |

### 배치 규칙

`build.place_requested {furniture_id: String, cell: [x: int, z: int], rotation: int}` (명령, 경계 처리에서 적용). 위에서부터 **처음 맞는 행 하나**만 적용한다. B1~B10 은 상태를 바꾸지 않는다.

| # | 조건 | 결과(이벤트 · `reason`) |
|---|---|---|
| B1 | 페이로드 형식 오류: `furniture_id`가 `String` 아님, `cell`이 길이 2 의 `int` 배열 아님, `rotation`이 `int` 아님(키 없음 포함). `float`는 버스가 먼저 거부해 오지 않는다(tick.md E4) | `build.rejected` · `invalid` |
| B2 | `phase ∉ build_rules.allowed_phases`(v0: 낮만, economy P2 와 같은 규칙) | `build.rejected` · `not_allowed` |
| B3 | `furniture_id`가 `furniture.json` 행에 없음 | `build.rejected` · `unknown_furniture` |
| B4 | `rotation ∉ allowed_rotations`, 또는 `rotatable == false`이고 `rotation != 0` | `build.rejected` · `bad_rotation` |
| B5 | 점유 셀(G3) 중 하나라도 맵 밖(`x < 0`, `z < 0`, `x ≥ width`, `z ≥ depth`) | `build.rejected` · `out_of_bounds` |
| B6 | 점유 셀 중 하나라도 `buildable == false`인 타일(벽·기둥·입구·완충) | `build.rejected` · `blocked_tile` |
| B7 | 점유 셀 중 하나라도 이미 다른 인스턴스가 점유 | `build.rejected` · `overlap` |
| B8 | `wall_required == true`이고 등면 이웃(회전 방향표) 중 하나라도 `mountable`이 아님(맵 밖 포함). 다중 타일 가구는 등면 가장자리 셀마다 하나씩, 전부 벽이어야 한다 | `build.rejected` · `wall_required` |
| B9 | `category_max_count[category]`가 있고 그 카테고리 설치 수 ≥ 그 값(v0: 무대 1) | `build.rejected` · `limit_reached` |
| B10 | 경로 규칙. 배치 전 도달 집합 `R₀`, 배치했다고 가정한 뒤 도달 집합 `R₁`(C0)에 대해 (a) `R₀`에서 새 점유 셀을 뺀 타일 중 `R₁`에 없는 것이 있다(어딘가를 가둠), 또는 (b) 배치 뒤 무대가 있는데 무대 앞 행 셀 중 `R₁`에 든 것이 하나도 없다(입구에서 무대 앞까지 경로 없음) | `build.rejected` · `path_blocked` |
| B11 | 그 밖 | 지출 제안(#경제-핸드셰이크 H1). 결과는 H2~H4 |

- B8 의 "등면"은 정면의 반대쪽이다. 예: `poster_board`를 `[5,22]` 회전 0 으로 놓으면 정면 −z, 등면 이웃 `[5,23]`(벽) → 통과. `[5,1]` 회전 0 이면 등면 이웃 `[5,2]`(바닥) → 거절, 회전 180 이면 등면 이웃 `[5,0]`(벽) → 통과. 기둥은 `mountable`이 아니다.
- B10 (a)는 배치로 새로 생기는 고립만 막는다. 이미 도달 불가인 빈 타일(철거로 생긴 구멍, D4 참고)에 놓는 것은 막지 않는다. (b)는 무대를 놓을 때와, 무대 앞 행을 채우는 배치 둘 다에 걸린다.
- 거절 페이로드는 #이벤트-페이로드. 상태 불변, 지출 제안 없음.

### 철거 규칙

`build.demolish_requested {entity_id: String}` (명령). 처음 맞는 행 하나.

| # | 조건 | 결과(이벤트 · `reason`) |
|---|---|---|
| D1 | `entity_id`가 `String` 아님(키 없음 포함) | `build.rejected {action:"demolish"}` · `invalid` |
| D2 | `phase ∉ allowed_phases` | `build.rejected` · `not_allowed` |
| D3 | 그 `entity_id`의 인스턴스가 없음(철거된 id, 입구처럼 가구가 아닌 것 포함) | `build.rejected` · `not_found` |
| D4 | 그 밖 | 인스턴스 제거(상태 먼저) → `build.demolished` → `economy.refund_proposed {request_id: "build:demolish:<entity_id>", reason: "demolish", base_amount: paid}` → `economy.upkeep_reported {total}` → `build.coverage_changed {cause:"demolished"}` |

- 철거는 경로 규칙을 검사하지 않는다(타일을 비우기만 한다). 사방이 막힌 가구를 치우면 그 자리는 도달 불가 빈 타일이 되고 C0 에 따라 수용·관람에서 빠진다.
- 환불액은 economy 가 정한다(F3: `⌊paid × demolish_refund_rate_bp ÷ rate_scale⌋`, 1,000 → 700). 파산 뒤에는 economy 가 무시하지만(F1) build 는 철거를 그대로 한다.
- 무대를 철거하면 관람 타일이 0 이 되고 B9 한도가 풀린다.

### 경제 핸드셰이크

economy.md #입력-계약 "같은 경계 안의 핸드셰이크"를 그대로 쓴다. build 는 `cash`를 읽지 않는다.

| # | 시점 | 동작 |
|---|---|---|
| H1 | B11 | `pending = {request_id, furniture_id, cell, rotation, cells, cost}`, `request_id = "build:place:f" + str(next_entity)`, `cost = build_cost` → `economy.charge_proposed {request_id, reason: "build", amount: cost}` 발행 |
| H2 | `economy.charge_resolved` 수신, `reason == "build"`이고 `request_id == pending.request_id`, `approved == true` | `instances`에 `{entity_id: "f<next_entity>", furniture_id, cell, rotation, paid: amount}` 추가, `next_entity += 1`, `pending = null` → `build.placed` → `economy.upkeep_reported {total}` → `build.coverage_changed {cause:"placed"}`. B1~B10 을 다시 검사하지 않는다(E5: 한 명령의 연쇄가 끝나기 전에 다른 명령이 끼지 않는다) |
| H3 | 같은 조건, `approved == false` | `pending = null` → `build.rejected`, `reason` = `decline_reason`이 `"insufficient_cash"`면 `insufficient_cash`, `"bankrupt"`면 `bankrupt`, 그 밖(`"invalid"`)이면 `charge_invalid` |
| H4 | `economy.charge_resolved`의 `reason != "build"` 또는 `request_id`가 `pending`과 다름 | 무시(개런티 등 다른 시스템의 지출) |
| H5 | `update(ctx)`(단계 2) 시작 시 `pending != null` | economy 가 응답하지 않은 계약 위반(economy 미등록 테스트 등). `push_warning` 1회, `pending = null` → `build.rejected` · `charge_unresolved` |

**이벤트 순서(economy 등록 시, 한 경계 안).** 배치 성공: `economy.charge_proposed` → `economy.cash_changed {reason:"build", delta: −cost}` → `economy.charge_resolved {approved:true}` → `build.placed` → `economy.upkeep_reported` → `build.coverage_changed`.
배치 자금 부족: `economy.charge_proposed` → `economy.charge_resolved {approved:false, decline_reason:"insufficient_cash"}` → `build.rejected {reason:"insufficient_cash"}`.
철거: `build.demolished` → `economy.refund_proposed` → `economy.upkeep_reported` → `build.coverage_changed` → `economy.cash_changed {reason:"demolish_refund"}`(환불 > 0 일 때. refund 이벤트를 economy 가 처리하며 낸 이벤트가 큐 끝에 붙는다, tick.md E2).

**유지비 보고.** `total = Σ furniture[i.furniture_id].upkeep_per_day` (설치 인스턴스마다). 설치 목록이 바뀔 때마다(H2, D4) 1회. 새 게임·복원은 보고하지 않는다(economy 스냅샷이 자기 `upkeep_per_day`를 갖는다).

### 커버리지

설치 목록이 바뀔 때마다 아래를 다시 계산한다(전체 재계산, 증분 없음 — 24×24 에서 충분히 싸다). 모든 값은 정수, 비율은 `economy.json` `rate_scale`(10,000) 분의 bp.

**C0 (보조) 도달 집합·자유 바닥·관람 타일.**

| 출력 | 입력 | 식 |
|---|---|---|
| `blocked_cells` | `instances` | 모든 인스턴스의 점유 셀(G3) 합집합 = 아래 `R`의 BFS 가 지나가지 못하게 막는 셀. 배열, G6 순서. 매번 전체 목록(증분 아님) |
| `R` (도달 집합) | 맵, `occupancy` | 모든 `entrance` 타일에서 시작하는 4방향 BFS. 지나갈 수 있는 타일 = `walkable == true`이고 점유되지 않은 타일. 결과는 집합(순회 순서 무관) |
| `floor_free` | `R` | `count({t ∈ R : standing(t)})` (도달 가능한 빈 `floor`) |
| 무대 `S` | `instances` | `category == "stage"`인 인스턴스(B9 로 0 또는 1 개). 없으면 `has_stage = false`, 관람 타일 ∅ |
| `viewing_tiles` | `R`, `S` | `{t ∈ R : standing(t)` 이고 `t`가 `S`의 앞 반평면(회전 방향표)에 있음`}` |
| `viewing_count` | | `count(viewing_tiles)` |
| 초점 셀 `g` | `S` | `S`의 정면 가장자리 셀을 방향표의 정렬 기준으로 나열한 목록 `E`(길이 `n`)에서 `E[⌊n/2⌋]`. 예: `stage_small` `[10,20]` 회전 0 → `E = [10,20] [11,20] [12,20] [13,20]`, `g = [12,20]` |

`count(X)` = 집합 `X`의 원소 수.

**거리.** 타일 `t`와 인스턴스 `i`(점유 사각형 `x0..x1`, `z0..z1`) 사이 `d²(t, i) = dx² + dz²`, `dx = max(x0 − t.x, 0, t.x − x1)`, `dz = max(z0 − t.z, 0, t.z − z1)`. 반경 `r`인 효과는 `r > 0`이고 `d² ≤ r²`이면 `t`를 덮는다. 정수 연산뿐이다. 벽·기둥은 음향·바 반경을 막지 않는다(v0).

**공식 5종.**

| # | 출력 | 입력 | 식 |
|---|---|---|---|
| C1 | `sound_tiles`, `sound_bp` | `viewing_tiles`, 인스턴스 `effects.sound_radius` | `sound_tiles = {t ∈ viewing_tiles : ∃ i, sound_radius(i) > 0 ∧ d²(t,i) ≤ sound_radius(i)²}`<br>`sound_bp = ⌊count(sound_tiles) × rate_scale ÷ viewing_count⌋`, `viewing_count == 0`이면 0 |
| C2 | `sight_tiles`, `sight_bp` | `viewing_tiles`, `g`, 맵 `blocks_sight`, 인스턴스 `effects.sight_block` | `sight_tiles = {t ∈ viewing_tiles : line(t, g)의 처음·끝을 뺀 셀 중 차단 셀이 없음}`. 차단 셀 = `blocks_sight` 타일, 또는 `sight_block == true`인 인스턴스가 점유한 셀(**무대 `S` 자신은 제외**)<br>`sight_bp = ⌊count(sight_tiles) × rate_scale ÷ viewing_count⌋`, 0 이면 0 |
| C3 | `bar_tiles`, `bar_bp` | `viewing_tiles`, 인스턴스 `effects.bar_service_radius` | C1 과 같은 꼴, 반경만 `bar_service_radius` |
| C4 | `capacity` | `floor_free`, 맵 `persons_per_tile_bp`, 인스턴스 `effects.capacity_add`, `tiers[map.tier].capacity_max` | `capacity = min(capacity_max, ⌊floor_free × persons_per_tile_bp ÷ rate_scale⌋ + Σ capacity_add)` |
| C5 | `evac_capacity`, `evac_shortfall` | 맵 타일 `evac_capacity`, 인스턴스 `effects.evac_capacity`, `capacity` | `evac_capacity = Σ_맵 타일 kind.evac_capacity + Σ_인스턴스 evac_capacity`<br>`evac_shortfall = max(0, capacity − evac_capacity)` |

**보조 출력.**

| # | 출력 | 식 |
|---|---|---|
| C6 | `light_grade` | `Σ effects.light_grade` (설치 인스턴스) |
| C7 | `satisfaction_bonus_bp` | `min(build_rules.satisfaction_bonus_cap_bp, Σ effects.satisfaction_bonus_bp)` |
| C8 | `upkeep_per_day` | `Σ furniture.upkeep_per_day` (= `economy.upkeep_reported.total`) |

**시야 레이 `line(a, b)`** — 정수 브레젠험, 이 의사코드와 비트 단위로 같아야 한다(대각 한 걸음 허용, 출발 `a`에서 초점 `b` 방향으로만 계산).

```
func line(a: [x0, z0], b: [x1, z1]) -> Array:   # a 와 b 를 포함한 셀 목록
    dx = abs(x1 - x0); sx = 1 if x0 < x1 else -1
    dz = -abs(z1 - z0); sz = 1 if z0 < z1 else -1
    err = dx + dz
    x = x0; z = z0; out = []
    loop:
        out.append([x, z])
        if x == x1 and z == z1: break
        e2 = 2 * err
        if e2 >= dz: err += dz; x += sx
        if e2 <= dx: err += dx; z += sz
    return out
```

- 대각 걸음은 두 대각 차단 셀 사이를 빠져나갈 수 있다(v0 허용, 셀 단위 근사).
- 피난 부족(`evac_shortfall > 0`)의 결과(만족도 감점·사고 확률)는 show.md / events_crisis.md 가 정한다. build 는 값만 낸다.
- `capacity`는 `tiers.capacity_min`(50)보다 작아질 수 있다(가구로 방을 채우면). 하한은 규칙이 아니라 수치 목표다(#수용-기준 DT5).

**발행.** `build.coverage_changed {cause, …}`(#이벤트-페이로드). `cause`:

| `cause` | 시점 |
|---|---|
| `"placed"` | H2, `economy.upkeep_reported` 뒤 |
| `"demolished"` | D4, `economy.upkeep_reported` 뒤 |
| `"sync"` | (a) `time.phase_changed {to: "evening"}` 수신 시 1회(설치 목록이 그대로여도) — 관객·공연 시스템은 매일 저녁 개장 직전에 이 값으로 동기화한다. (b) **새 세계 생성 직후 1회(SE-058)** — `GameSession` 이 시스템 생성·구독 등록을 마친 뒤 첫 틱 전에 낸다(난수 소비 0). 설치 0 이어도 빈 맵 값(티어 1 `capacity` 119 등)을 싣는다. 그래서 첫 저녁·첫 설치 전에도 audience·show 의 coverage 가 이 시스템과 같다. (c) 불러오기·새 게임의 `session.loaded` 뒤 재발행 1회(SE-036 AC6, events.md `build.coverage_changed` 행) — 상태를 바꾸지 않는다. 스냅샷 훅 자체(`restore`)는 이벤트를 내지 않는다(SH4) |

`blocked_cells`(SE-044): 모든 `cause`의 페이로드에 점유 셀 전체(C0, G6 순서, 증분 아님)를 싣는다 — 복원 뒤 첫 저녁 `"sync"`에도 실리므로 이 이벤트 하나로 점유 상태가 완전히 재구성된다. 소비자는 SE-034 관객 경로(자기 `TilePath`를 받을 때마다 이 목록으로 맞춘다, `BuildSystem`을 직접 부르지 않는다). SE-037 오버레이는 이 키를 쓰지 않는다(무시).

### 이벤트 페이로드

명령 페이로드 숫자는 `int`만(tick.md E4). 좌표는 `[x, z]` 2원소 `int` 배열, 좌표 목록은 G6 순서.

| 이벤트 | 페이로드 |
|---|---|
| `build.place_requested` | `{furniture_id: String, cell: [x, z], rotation: int}` |
| `build.demolish_requested` | `{entity_id: String}` |
| `build.placed` | `{entity_id: String, furniture_id: String, cell: [x, z], rotation: int, cells: Array[[x, z]], cost: int}` — `cost` = 승인된 건설비(= `paid`) |
| `build.rejected` | `{action: "place"\|"demolish", reason: String, furniture_id, cell, rotation, entity_id}` — `reason`은 B·D·H 표의 값 15종(`invalid`, `not_allowed`, `unknown_furniture`, `bad_rotation`, `out_of_bounds`, `blocked_tile`, `overlap`, `wall_required`, `limit_reached`, `path_blocked`, `insufficient_cash`, `bankrupt`, `charge_invalid`, `charge_unresolved`, `not_found`). `action:"place"`: `furniture_id`·`cell`·`rotation`은 **받은 값 그대로**(키가 없으면 `null`), `entity_id`는 `null`. `action:"demolish"`: `entity_id`는 받은 값(없으면 `null`), 나머지 셋은 인스턴스가 있으면 그 값, 없으면 `null`. 타입: 네 필드는 **받은 값 그대로(any)**, 키가 없으면 `null`. `reason != "invalid"`이면 각각 `String`·`[x, z]`(`int` 2개)·`int`·`String`(또는 `null`)으로 좁혀진다(`invalid` 거절은 `cell: "5,5"`, `rotation: "0"`, `entity_id: 5` 같은 값을 그대로 돌려준다, BC3·BC17) |
| `build.demolished` | `{entity_id: String, furniture_id: String, cell: [x, z], rotation: int, cells: Array[[x, z]], base_amount: int}` — `base_amount` = `paid` |
| `build.coverage_changed` | `{cause: "placed"\|"demolished"\|"sync", has_stage: bool, floor_free: int, viewing_count: int, viewing_tiles: Array[[x, z]], sound_tiles: Array[[x, z]], sight_tiles: Array[[x, z]], bar_tiles: Array[[x, z]], sound_bp: int, sight_bp: int, bar_bp: int, capacity: int, evac_capacity: int, evac_shortfall: int, light_grade: int, satisfaction_bonus_bp: int, upkeep_per_day: int, blocked_cells: Array[[x, z]]}` — 타일 배열 4개는 관객 시스템 입력(관람 위치)과 오버레이(SE-037) 입력. `blocked_cells`(마지막 키)는 점유 셀 전체(C0, G6 순서, 증분 아님), 관객 경로(SE-034) 입력이고 오버레이는 무시 |

### 결정성과 RNG

- build 는 **난수를 쓰지 않는다.** `world` 스트림을 한 번도 뽑지 않는다(`rng.get_state()["world"]`가 배치·철거 전후로 같다). 배치 변형(같은 가구의 랜덤 외형 등)이 필요해지면 그때 `world` 스트림·호출 지점(명령 처리, 단계 1)·횟수를 이 문서에 먼저 적는다.
- 순회는 `instances` 배열(설치 순)과 맵 좌표(z, x 오름차순)뿐이다. Dictionary 순회에 기대는 결과가 없다(BFS 결과는 집합이고 출력 배열은 G6 으로 정렬).
- 같은 시드·같은 명령 열이면 같은 `instances`와 같은 `build.*` 이벤트 열이 나온다.

### 스냅샷

`TickLoop.register_system("build", build.update, build.snapshot, build.restore)`로 **반드시** 등록한다(economy 와 같은 이유: 등록하지 않으면 설치 목록이 세이브에서 사라진다). `system_order`의 첫 시스템이라 구독도 가장 먼저다(tick.md "시스템 등록").

`BuildSystem.snapshot() -> Dictionary` = `{instances: [{entity_id, furniture_id, cell: [x, z], rotation, paid}, …], next_entity: int, phase: String}`(깊은 복사본, 기본형만). `pending`·파생값은 넣지 않는다.

`BuildSystem.restore(d) -> bool`. 정수 필드는 `int`로 정규화(JSON 왕복의 `float`). 아래 검사를 **전부 끝낸 뒤** 적용한다(SH3). 첫 위반에서 `push_error` 1회, `false`, 상태 불변, 이벤트 0.

| # | 검사 |
|---|---|
| RS1 | `instances` Array, `next_entity` 정수 ≥ 1, `phase`가 `sim.json` `phases[].id` 중 하나, 원소마다 5키가 있고 타입이 맞음 |
| RS2 | `entity_id`가 `"f<n>"`(n 은 1 이상 정수, 앞자리 0 없음), `n < next_entity`, 배열 안에서 n 이 엄격히 증가 |
| RS3 | `furniture_id`가 테이블에 있음, `rotation ∈ allowed_rotations`이고 B4 를 통과 |
| RS4 | 점유 셀이 전부 맵 안이고 `buildable` (B5·B6) |
| RS5 | 인스턴스끼리 겹치지 않음 (B7) |
| RS6 | `category_max_count` 이하 (B9) |
| RS7 | `paid` 정수 ≥ 0 |

검사하지 않는 것: B8(벽)·B10(경로). 데이터가 바뀌어 옛 세이브가 그 규칙을 어겨도 복원은 되고 다음 배치부터 규칙이 적용된다. 복원 성공 뒤 `pending = null`이고 커버리지를 내부에서 다시 계산한다(이벤트 없음, 다음 `"sync"`에서 알림).
복원 후 진행 = 연속 진행, SH1~SH7 준수. `sim.json.snapshot_schema_version`은 바꾸지 않는다(최상위 키 형식 불변, `systems.build` 항목 추가만).

### 설정 로드 검사

`BuildConfig.load()`가 스키마로 못 하는 교차 검사를 한다. 실패하면 `push_error`, `null`.

| # | 검사 |
|---|---|
| MK1 | `tiles` 행 수 == `depth`, 각 행 길이 == `width` |
| MK2 | `width == depth == tiers[tier].grid_size` (tier1_club: 24) |
| MK3 | `tile_kinds`의 `id`·`char` 각각 유일, `tiles`의 모든 글자가 어떤 `char`와 같음 |
| MK4 | `entrance` 타일 ≥ 1 |
| MK5 | 맵 가장자리(`x = 0`, `z = 0`, `x = width−1`, `z = depth−1`) 타일은 `walkable == false`이거나 `entrance` (닫힌 방) |
| MK6 | 빈 맵에서 모든 `walkable` 타일이 C0 의 `R`에 듦(입구와 연결) |
| FC1 | 행 `id` 유일(validate_data 도 검사) |
| FC2 | 모든 행 `⌊build_cost × (rate_scale − demolish_refund_rate_bp) ÷ rate_scale⌋ > upkeep_per_day` (economy.md 유지비 규칙. 철거·재설치로 유지비를 피하는 것보다 그냥 두는 편이 항상 싸다) |
| FC3 | `allowed_rotations`가 0 을 포함 |
| FC4 | `model`이 있고 비어 있지 않으면 `== "res://assets/models/" + id + ".glb"` |
| FC5 | `reference_sets[].items[].furniture_id`, `reference_layouts[].placements[].furniture_id`가 행에 있음 |

FC6(economy 가정 목록 `reference_sets[economy_tier1_baseline]`의 합 == `economy.json` `reference_scenarios[tier1_baseline]`의 `upkeep_per_day`·`initial_build_spend`)와 FC7(`starter_max_trio` 건설비 ≤ `starting_cash` < `all_rows_once` 건설비, 각 `expected.affordable_with_starting_cash`와 일치)은 로드 검사가 아니라 테스트다(BC20). 데이터를 바꿀 때 game-designer 가 지킨다.

### 공개 API (SE-032 구현, SE-044 에서 구현 이름으로 정리)

파일은 `project/world/`(CLAUDE.md "World: 그리드, 배치 규칙, 경로 탐색, 커버리지 계산"). 짝 테스트 `project/tests/sim/test_<이름>.gd`.

| 클래스 | 멤버 | 설명 |
|---|---|---|
| `BuildConfig` | `static load(furniture_path := "res://data/furniture/furniture.json", map_path := "res://data/maps/tier1_club.json") -> BuildConfig`, `static from_dicts(furniture: Dictionary, map: Dictionary, tiers: Dictionary, economy: Dictionary) -> BuildConfig` | MK·FC 검사. `tiers.json`·`economy.json`은 기본 경로에서 읽는다(읽기 전용) |
| | `furniture(id) -> Dictionary`, `has_furniture(id) -> bool`, `tile_kind(cell) -> Dictionary`(맵 밖 `{}`), `layout(id) -> Dictionary`, `reference_set(id) -> Dictionary`, `capacity_max`, `rate_scale` | 읽기 전용, 깊은 복사 |
| | `static rotated_size(footprint: Array, rotation: int) -> Array`, `static cells_of(footprint, cell, rotation) -> Array`, `static line(a: Array, b: Array) -> Array` | 순수 함수(G2·G3·시야 레이). 단위 테스트용 |
| `BuildSystem` | `new(config: BuildConfig, bus: EventBus)` | `build.place_requested`, `build.demolish_requested`, `economy.charge_resolved`, `time.phase_changed` 구독. 이벤트를 내지 않는다 |
| | `update(ctx)`, `snapshot()`, `restore(d)` | H5, #스냅샷 |
| | `coverage() -> Dictionary` | 마지막 계산 결과(= `build.coverage_changed` 페이로드에서 `cause` 뺀 것). 읽기 전용 |
| | `check_place(furniture_id: String, cell: Array, rotation: int) -> String` | B1·B3~B10 판정만(구간 B2·자금 제외), 통과면 `""`. **상태 불변, 이벤트 없음.** UI 배치 미리보기(유효/무효 타일 색)용(Q4) |
| | `find_path(from: Array, to: Array) -> Array`, `path_from_entrance(to: Array) -> Array` | 현재 점유 기준 4방향 타일 경로(`[x, z]` 목록, 도달 불가·맵 밖이면 `[]`). **UI·테스트용 읽기 쿼리, sim 시스템은 부르지 않는다**(원칙 4 — 관객 경로는 `build.coverage_changed.blocked_cells`로 자기 `TilePath`를 맞춘다). 상태 불변, 이벤트 없음(BC32) |

### UI 계약 (SE-037)

| 동작 | 규칙 |
|---|---|
| 배치 | 팔레트에서 가구 선택 → 커서 타일 = `cell`(G3 의 최소 모서리) → 클릭 시 `build.place_requested`. 미리보기는 `check_place`의 결과로 유효(녹)/무효(적) 표시, 무효면 `reason`을 툴팁에 |
| 회전 R | 선택 중인 가구의 `rotation`을 +90(270 다음 0). `rotatable == false`면 무시 |
| 취소 Esc | 선택 해제. 이벤트 없음 |
| 철거 | 철거 도구로 인스턴스 셀 클릭 → `build.demolish_requested {entity_id}`. 확인창의 환불액 표시는 `⌊paid × demolish_refund_rate_bp ÷ rate_scale⌋`(`economy.json` 읽기) |
| 구간 | 낮이 아니면 팔레트·철거 도구를 비활성으로 보여도 된다. 그래도 보낸 명령은 B2/D2 로 거절된다 |
| 오버레이 | 음향·시야·바 = `build.coverage_changed`의 `sound_tiles`·`sight_tiles`·`bar_tiles`(관람 타일 중 덮인 것) vs `viewing_tiles`. 설비 반경 미리보기 = 선택 가구의 `effects.*_radius`를 C1 의 거리식으로 그린다 |
| 렌더 | 위치·회전 = G5. 모델이 없으면(`model` 없음, 또는 경로에 리소스 없음) `footprint × height_m` 상자 플레이스홀더, 색은 `slots.base` |

## 수치표

모든 값은 [`furniture.json`](../../project/data/furniture/furniture.json)(version 1)과 [`tier1_club.json`](../../project/data/maps/tier1_club.json)(version 1)의 값이다. 색(`slots`)은 임시 hex 라 표에서 뺐다(팔레트 티켓에서 교체, Q5).

### 가구 20종

| id | 이름 | 카테고리 | 점유 w×d | 높이 m | 건설비 | 유지비/일 | ⌊비×0.3⌋ | 회전 | 벽 | 폴리곤 | 슬롯 | 효과 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `stage_small` | 소형 무대 | stage | 4×3 | 0.6 | 1,000 | 45 | 300 | O | — | large | base, accent | 음향 5, 시야차단 |
| `stage_medium` | 중형 무대 | stage | 6×4 | 0.8 | 2,200 | 80 | 660 | O | — | large | base, accent, emissive | 음향 6, 시야차단, 만족 200, 연출 1 |
| `speaker_floor` | 바닥 스피커 | sound | 1×1 | 1.2 | 200 | 15 | 60 | O | — | small | base, emissive | 음향 7 |
| `speaker_stack` | 스피커 스택 | sound | 2×1 | 2.2 | 550 | 25 | 165 | O | — | large | base, accent | 음향 10, 시야차단 |
| `stage_monitor` | 모니터 스피커 | sound | 1×1 | 0.4 | 120 | 5 | 36 | O | — | small | base | 음향 2, 만족 100 |
| `light_spot` | 스포트 조명 | light | 1×1 | 2.4 | 100 | 10 | 30 | O | — | small | base, emissive | 연출 1 |
| `light_moving_head` | 무빙 헤드 | light | 1×1 | 2.4 | 400 | 20 | 120 | O | — | small | base, accent, emissive | 연출 3 |
| `fog_machine` | 포그 머신 | light | 1×1 | 0.5 | 180 | 8 | 54 | — | — | small | base | 연출 1 |
| `led_panel` | LED 패널 | light | 2×1 | 2.4 | 900 | 35 | 270 | O | — | large | base, emissive | 연출 2, 시야차단 |
| `bar_counter` | 바 카운터 | bar | 3×1 | 1.1 | 500 | 40 | 150 | O | — | large | base, accent | 바 8 |
| `bar_fridge` | 음료 냉장고 | bar | 1×1 | 1.9 | 300 | 12 | 90 | O | O | small | base, emissive, **glass** | 바 3, 시야차단 |
| `toilet_booth` | 화장실 칸 | amenity | 1×2 | 2.2 | 250 | 15 | 75 | O | O | large | base, accent | 만족 300, 시야차단 |
| `locker` | 물품보관함 | amenity | 2×1 | 1.8 | 220 | 6 | 66 | O | O | small | base, accent | 만족 150, 시야차단 |
| `bench` | 벤치 | amenity | 2×1 | 0.45 | 120 | 4 | 36 | O | — | small | base | 수용 +4, 만족 50 |
| `standing_table` | 스탠딩 테이블 | amenity | 1×1 | 1.1 | 80 | 3 | 24 | — | — | small | base, accent | 수용 +2, 만족 50 |
| `fire_extinguisher` | 소화기 | safety | 1×1 | 0.6 | 60 | 2 | 18 | O | O | small | base | 피난 5 |
| `exit_sign` | 비상구 표지 | safety | 1×1 | 2.2 | 80 | 3 | 24 | O | O | small | base, emissive | 피난 20 |
| `exit_door` | 비상 출구 | safety | 2×1 | 2.2 | 200 | 15 | 60 | O | O | large | base, accent | 피난 60, 시야차단 |
| `poster_board` | 포스터 보드 | decor | 1×1 | 1.6 | 40 | 1 | 12 | O | O | small | base, accent | 만족 50 |
| `neon_sign` | 네온 사인 | decor | 1×1 | 1.8 | 200 | 6 | 60 | O | O | small | base, emissive | 만족 100 |

요약(AC2): 카테고리 7종 전부 ≥ 1(무대 2·음향 3·조명 4·바 2·편의 4·안전 3·장식 2). `glass` 1(`bar_fridge`). `emissive` 8(`stage_medium`, `speaker_floor`, `light_spot`, `light_moving_head`, `led_panel`, `bar_fridge`, `exit_sign`, `neon_sign`). 벽 필요 8. 2칸 이상 9(`stage_small`, `stage_medium`, `speaker_stack`, `led_panel`, `bar_counter`, `toilet_booth`, `locker`, `bench`, `exit_door`). 회전 불가 2(`fog_machine`, `standing_table` — 위에서 보아 대칭이고 벽이 필요 없다). `poly_budget` large 7 / small 13.
FC2 여유(`⌊비×0.3⌋ − 유지비`)의 최솟값은 `poster_board` 11. 전부 > 0.

### 가격 근거

| 기준 | 값 | 근거 |
|---|---|---|
| economy 가정 목록(소형 무대 1, 바 카운터 1, 스피커 2, 조명 4, 화장실 2, 비상구 1) | 유지비 200, 건설비 3,000 | `economy.json` `reference_scenarios[tier1_baseline]`의 `upkeep_per_day` 200·`initial_build_spend` 3,000 과 **정확히** 같게 맞췄다. 그래서 economy 기대값(순이익 1,142, 티어 2 자금 25일)을 바꾸지 않는다. 계산: 유지비 45 + 40 + 2×15 + 4×10 + 2×15 + 15 = 200, 건설비 1,000 + 500 + 2×200 + 4×100 + 2×250 + 200 = 3,000 (`reference_sets[economy_tier1_baseline]`) |
| 시작 자금 5,000 으로 "무대 + 스피커 1 + 바 1" | 가장 비싼 조합 2,900 ≤ 5,000 | `stage_medium` 2,200 + `speaker_floor` 200 + `bar_counter` 500 (`reference_sets[starter_max_trio]`) |
| 20종 1개씩 | 7,700 > 5,000 | 첫날 전부는 못 산다. 유지비 합 350 (`reference_sets[all_rows_once]`) |
| 무대 등급 | `stage_medium` = `stage_small`의 2.2배 | 기준 순이익 1,142/일 기준 약 2일치. 만족 200·연출 1·음향 6 을 더 준다 |
| 스피커 | `speaker_floor` 200(반경 7), `speaker_stack` 550(반경 10) | 기준 배치(스피커 2)의 음향 23.7% → 같은 스피커 2개를 더하면 77.66%(BC21). 음향은 "돈으로 사는 커버리지"의 첫 축 |
| 피난 | 입구 80 + `exit_door` 60 + `exit_sign` 20 = 160 ≥ 150 | 수용 상한 150 을 피난 부족 없이 받으려면 안전 가구 ≥ 280 을 써야 한다(PRD 티어 1 압박 "화재 규정") |

### 맵 수치

| 값 | 데이터 | 결과 |
|---|---|---|
| 크기 | `width` 24, `depth` 24 | `tiers[tier_1].grid_size` 24 와 같음(MK2) |
| `persons_per_tile_bp` | 2,500 | 빈 방 수용 ⌊478 × 0.25⌋ = 119 (`capacity_min` 50 ~ `capacity_max` 150 사이) |
| 입구 피난 | `entrance.evac_capacity` 40 × 2칸 | 80. 빈 방 수용 119 보다 작다 → 안전 가구가 필요 |
| `satisfaction_bonus_cap_bp` | 1,500 | 장식·편의만 쌓아 만족도를 끝없이 올리지 못하게. 화장실 2 + 보관함 + 네온 2 + 포스터 4 ≈ 1,150 |

## 수용 기준

구현 티켓(SE-032)의 테스트 케이스 목록이다. 파일은 SE-032 가 정하는 `project/tests/sim/test_build*.gd`. 기대 수치는 테스트에 하드코딩하지 않고 `tier1_club.json` `reference_layouts[].expected`와 `furniture.json` `reference_sets[].expected`, 행 값에서 읽는다(수치가 바뀌어도 테스트 코드는 그대로). 아래 리터럴은 현재 데이터 값이다.

공통 전제: 새 게임(`starting_cash` 5,000, `phase "day"`, 설치 0), `BuildSystem`과 `Economy`를 `system_order` 순으로 같은 버스에 구독, 명령은 `bus.publish` 후 `dispatch_commands()`(또는 `TickLoop.advance(0)`).

### 배치·철거 판정 (유효/무효 케이스)

| # | 준비 | 명령 | 기대 |
|---|---|---|---|
| BC1 | — | place `stage_small` `[10,20]` r0 | `build.placed {entity_id:"f1", cells: [10..13]×[20..22] 12칸, cost:1000}`, cash 4,000, 이벤트 순서 #경제-핸드셰이크 "배치 성공" 6개 |
| BC2 | `time.phase_changed {to:"evening"}` | place `speaker_floor` `[5,5]` r0 | `rejected · not_allowed`, 지출 제안 0 |
| BC3 | — | place `{furniture_id:"speaker_floor", cell:"5,5", rotation:0}` / `cell` 키 없음 / `rotation:"0"` | 각각 `rejected · invalid`, `cell`·`rotation`은 받은 값(없으면 `null`) |
| BC4 | — | place `stage_huge` `[5,5]` r0 | `rejected · unknown_furniture` |
| BC5 | — | place `speaker_floor` `[5,5]` r45 / `standing_table` `[5,5]` r90 | 둘 다 `rejected · bad_rotation` |
| BC6 | — | place `stage_small` `[21,5]` r0 (x 21..24) / `speaker_floor` `[-1,5]` r0 | 둘 다 `rejected · out_of_bounds` |
| BC7 | — | place `speaker_floor` at `[7,8]`(기둥), `[11,1]`(완충), `[0,5]`(벽), `[11,0]`(입구) | 4개 모두 `rejected · blocked_tile` |
| BC8 | BC1 | place `speaker_floor` `[11,21]` r0 | `rejected · overlap` |
| BC9 | — | `poster_board` `[5,5]` r0 → `[5,22]` r0 → `[5,1]` r0 → `[5,1]` r180 → `[7,9]` r180(등이 기둥) → `toilet_booth` `[1,21]` r0 → `[1,19]` r90 → `[1,19]` r270 | `wall_required`, placed, `wall_required`, placed, `wall_required`, placed, `wall_required`, placed (`[1,19]` r270 점유 `[1,19] [2,19]`, 등면 이웃 `[0,19]`) |
| BC10 | BC1 | place `stage_medium` `[2,2]` r0 | `rejected · limit_reached` |
| BC11 | — | `speaker_floor` `[2,1]` → `speaker_floor` `[1,2]` | placed, `rejected · path_blocked` (`[1,1]`이 갇힌다, B10 (a)) |
| BC12 | — | `bench` `[11,2]` r0 → `speaker_floor` `[10,1]` → `speaker_floor` `[13,1]` | placed, placed, `rejected · path_blocked` (입구·완충만 남고 방 전체가 끊긴다) |
| BC13 | BC1 | `bench` `[10,19]` r0 → `bench` `[12,19]` r0 | placed, `rejected · path_blocked` (무대 앞 행 `[10..13,19]`이 다 막힘, B10 (b)) |
| BC14 | economy `cash` 100 (`Economy.restore` 로 설정) | place `bar_counter` `[2,2]` r0 | `economy.charge_resolved {approved:false, decline_reason:"insufficient_cash"}` → `rejected · insufficient_cash`. `instances`·`next_entity`·cash 불변 |
| BC15 | economy `bankrupt: true` | place `speaker_floor` `[5,5]` r0 | `rejected · bankrupt` |
| BC16 | BC1 | demolish `"f1"` | `build.demolished {base_amount:1000}` → `economy.refund_proposed {request_id:"build:demolish:f1", base_amount:1000}` → `economy.upkeep_reported {total:0}` → `build.coverage_changed {cause:"demolished", has_stage:false}` → `economy.cash_changed {delta:700}`. cash 4,700 |
| BC17 | BC16 | demolish `"f1"` / demolish `"f99"` / demolish `{entity_id: 5}` | `not_found`, `not_found`, `invalid` |
| BC18 | BC1, `time.phase_changed {to:"show"}` | demolish `"f1"` | `rejected · not_allowed`, 인스턴스 유지 |
| BC19 | BC1 → BC16 → place `speaker_floor` `[5,5]` r0 | — | 새 인스턴스 id `"f2"`(번호 재사용 없음) |

### 기준 배치·합계

| # | 내용 | 기대 |
|---|---|---|
| BC20 | `furniture.json` `reference_sets` 3개: 항목 합 | `economy_tier1_baseline`: 건설비 3,000 == `economy.json` `initial_build_spend`, 유지비 200 == 그 시나리오 `upkeep_per_day`(FC6). `starter_max_trio` 2,900 ≤ `starting_cash`, `all_rows_once` 7,700 > `starting_cash`(FC7). 각 `expected`와 같음 |
| BC21 | `reference_layouts[baseline_plus_two_speakers]` 레이아웃 데이터(= `baseline_show` 6개 + `speaker_floor` `[5,10]` r0, `[18,10]` r0) 8개를 순서대로 place | 8개 모두 placed(f1~f8). `coverage()`·마지막 `build.coverage_changed`가 그 레이아웃의 `expected`와 같음(테스트에 리터럴을 두지 않는다): `viewing_count` 403, 음향 313칸·7,766 bp(스피커 2 → 4 로 23.70% → 77.66%), `floor_free` 455, 시야 362칸·8,982 bp, 바 121칸·3,002 bp, 수용 121, 피난 80, 부족 41, 유지비 153, 건설비 합 2,540, cash 2,460, 시야 차단 41칸(새 바닥 스피커는 `sight_block` 아님 — `baseline_show`와 같은 41칸) |
| BC22 | `reference_layouts[empty_room]` | `coverage()`가 `expected`와 같음: 무대 없음, `floor_free` 478, 관람 0, 음향·시야·바 0, 수용 119, 피난 80, 부족 39, 연출 0, 만족 0, 유지비 0, 건설비 0, cash 5,000 |
| BC23 | `reference_layouts[baseline_show]` 6개를 순서대로 place | 6개 모두 placed(f1~f6). 마지막 `build.coverage_changed`가 `expected`와 같음: `floor_free` 457, `viewing_count` 405, 음향 96칸·2,370 bp, 시야 364칸·8,987 bp, 바 122칸·3,012 bp, 수용 122, 피난 80, 부족 42, 연출 0, 만족 100, 유지비 123, 건설비 합 2,140, cash 2,860, 시야 차단 41칸 = `expected.sight_blocked_cells`. 마지막 `economy.upkeep_reported.total` 123 |
| BC24 | 순수 함수 | `rotated_size([3,1], 90) == [1,3]`, `cells_of([3,1],[20,4],90) == [[20,4],[20,5],[20,6]]`, `line([4,1],[12,20])`가 `[7,8]`을 지남(기둥 → 시야 차단), `line([12,1],[12,20])`은 x = 12 직선 20칸 |
| BC25 | FC2 | 20행 전부 `⌊build_cost × 3000 ÷ 10000⌋ > upkeep_per_day`. 한 행의 `upkeep_per_day`를 그 값 이상으로 올린 사본은 `BuildConfig.from_dicts` → `null` |
| BC26 | MK1~MK6 | 정상 맵 로드 성공. 행 하나 23글자, 입구 0개, 가장자리 `.` 하나, 기둥으로 입구 완충을 가둔 사본 각각 `null` |

### 결정성·스냅샷

| # | 내용 | 기대 |
|---|---|---|
| BC27 | `rng.get_state()` | BC23 전후 `world`(와 모든 스트림) 상태 같음 |
| BC28 | 스냅샷 왕복 | BC23 뒤 `TickLoop.snapshot()["systems"]["build"]` = `{instances: 6개(f1~f6, paid 1000/200/200/500/120/120), next_entity: 7, phase: "day"}`. close 경계에서 찍은 스냅샷을 복원한 새 `BuildSystem`은 `phase "close"`라 place 가 `not_allowed`. JSON 왕복 → 새 루프 `restore` → `true`, `coverage()`가 BC23 기대값과 같음, 해시 동일(SH6). 이어서 같은 명령 열 → 연속 진행과 같은 해시 |
| BC29 | 잘못된 스냅샷 | RS1~RS7 을 하나씩 깬 사본(예: `entity_id:"f01"`, 겹치는 두 인스턴스, 벽 위 인스턴스, 무대 2개, `paid: -1`)은 `BuildSystem.restore` → `false`, `push_error` 1회, 상태 불변. `TickLoop.restore` 경로면 `push_error` 2회(tick.md 표의 `Economy` 행과 같은 꼴) |
| BC30 | 저녁 동기화 | `time.phase_changed {to:"evening"}` → `build.coverage_changed {cause:"sync"}` 1회(설치 변화 없어도). 다른 구간 전환에는 없음 |
| BC31 | H5 | economy 를 구독시키지 않고 place → `dispatch_commands()` → `update(ctx)` 호출 시 `push_warning` 1회 + `rejected · charge_unresolved`, `instances` 불변 |

### 수치 목표 (game-design, 데이터가 바뀌어도 지켜야 할 범위)

| # | 목표 | 현재 값 | 확인 |
|---|---|---|---|
| DT1 | 모든 행 FC2 여유 > 0 | 최소 11 (`poster_board`) | BC25 |
| DT2 | economy 가정 목록 합 = economy 시나리오 값(유지비·건설비) | 200 / 3,000 | BC20 |
| DT3 | 가장 비싼 무대 + 스피커 1 + 바 1 ≤ `starting_cash` < 20종 1개씩 | 2,900 ≤ 5,000 < 7,700 | BC20 |
| DT4 | 기준 배치 수용 ≥ economy 기준 입장 100, ≤ `capacity_max` | 122 | BC23 |
| DT5 | 빈 방 수용이 `capacity_min`~`capacity_max` 안 | 119 ∈ [50, 150] | BC22 |
| DT6 | 기준 배치 음향 < 3,000 bp, 스피커 2개 추가 시 ≥ 6,000 bp (스피커가 의미 있는 투자) | 2,370 → 7,766 | BC21 |
| DT7 | 기준 배치 시야 ≥ 8,000 bp (기둥이 사각을 만들지만 기본은 잘 보인다) | 8,987 | BC23 |
| DT8 | 빈 방·기준 배치 모두 `evac_shortfall > 0` (안전 가구 구매 압력), 안전 가구로 150 명 부족 0 가능 | 39, 42 / 80 + 60 + 20 = 160 | BC22·BC23 |

### 문서·데이터 (이 티켓)

- 티켓 AC2 집계: 위 "요약" 문단. AC3 명령(qa):
  `python3 -c "import json;F=json.load(open('project/data/furniture/furniture.json'));E=json.load(open('project/data/economy/economy.json'));s=E['rate_scale'];r=E['demolish_refund_rate_bp'];bad=[x['id'] for x in F['rows'] if not x['build_cost']*(s-r)//s>x['upkeep_per_day']];print(len(F['rows']),'rows, violations:',bad);raise SystemExit(1 if bad else 0)"` → `20 rows, violations: []`, exit 0.

## 테스트 방법

- 헤드리스(SE-032): `tools/run_tests.sh project/tests/sim` — BC1~BC31. 기대값은 데이터의 `expected`에서 읽는다.
- 데이터(이 티켓): `python3 tools/validate_data.py --strict`(새 스키마 2개 포함) exit 0, 위 AC3 명령 exit 0.
- 손계산(reviewer, 이 티켓): 부록 A 의 행별 표를 #커버리지 공식만으로 다시 계산한다. 행 하나의 음향·바 구간은 원 방정식 한 줄, 시야 차단 타일은 표에 적힌 차단 셀을 `line()`으로 확인한다.
- 수동: 없음. UI 확인은 SE-037(헤드리스 캡처).

## 열린 질문

사람 결정 항목은 없다. 아래는 전부 추천안을 채택해 데이터·규칙에 넣었고, 뒤집으려면 표의 "변경 방법"대로 한다.

| # | 질문 | 선택지 | 채택(추천) | 변경 방법 |
|---|---|---|---|---|
| Q1 | 방 드래그 지정(PRD "드래그로 방 영역") | (a) v0 는 클릭 배치만 (b) 방 = 바닥 타일 칠하기 | **(a).** 티어 1 맵은 고정 방 하나라 방 구분이 결과에 영향을 주지 않는다. 방(구역)은 스태프 구역 배정과 함께 버티컬 슬라이스에서 | 새 스펙 절 + 맵 스키마 version 2 |
| Q2 | 벽걸이 가구(포스터·표지·네온·소화기)가 바닥 1칸을 차지하나 | (a) 벽 앞 바닥 1칸 점유(걷기 막음) (b) 벽 타일에 붙고 바닥 점유 0 | **(a).** 점유 모델이 하나라 B5~B10·C0 에 예외가 없다. 1칸 손해는 수용 0.25명이라 작다 | (b)로 가면 `furniture.schema` `mount: "floor"\|"wall"` 추가(version 2), B6·C0 개정 |
| Q3 | 시야·음향을 벽·기둥이 막나 | 시야만 막음 / 둘 다 / 둘 다 안 막음 | **시야만.** 음향 차폐는 반경 오버레이를 읽기 어렵게 만든다 | 음향 차폐를 넣으면 C1 에 `line()` 조건 추가 |
| Q4 | UI 미리보기가 sim 을 직접 읽어도 되나(원칙 1 "구독만") | (a) 읽기 전용 쿼리 `check_place` 허용 (b) `build.preview_requested` 명령 → 결과 이벤트 | **(a).** 상태를 바꾸지 않는 읽기이고, (b)는 다음 경계까지 지연돼 커서 이동마다 깜빡인다. 규칙을 view 에 복제하는 안은 버림(규칙 이중화) | reviewer 가 원칙 위반으로 보면 (b)로 events.md 에 2행 추가 |
| Q5 | 슬롯 색 | 임시 hex / 팔레트 id | **임시 hex**(`#RRGGBB`). 스키마는 `pal_*` id 도 받는다. 팔레트 확정 티켓이 값만 교체(스키마 변경 없음) | 데이터만 |
| Q6 | 복원 직후 `phase` | (a) 새 `BuildSystem`처럼 `"day"`로 두고 다음 `time.phase_changed`를 따른다 (b) 스냅샷에 넣는다 (c) `TickLoop`에서 읽는다 | **(b).** 오토세이브는 close 진입 경계라(tick.md) (a)면 복원 직후 close 동안 배치가 잘못 허용된다. (c)는 시스템이 `TickLoop`을 읽게 만든다. economy 가 `phase`를 자기 스냅샷에 두는 선례를 따른다 | 닫힘 |
| Q7 | 가구 이동 | 철거+재배치 / 이동 명령(무손실) | **철거+재배치**(30% 손실). PRD 환불 70% 와 같은 결 | 이동 명령은 events.md 행 추가 + 비용 규칙 필요 |

## 변경 이력

| 날짜 | 대상 | 티켓 | 내용 |
|---|---|---|---|
| 2026-10-09 | build.md v0, `furniture.json` v1 + `furniture.schema.json` version 1, `tier1_club.json` v1 + `maps.schema.json` version 1 | SE-028 | 신규. 맵(타일 5종), 가구 20종, 배치 B1~B11·철거 D1~D4·핸드셰이크 H1~H5, 커버리지 C0~C8, 스냅샷 RS1~RS7, 로드 검사 MK1~MK6·FC1~FC5, 수용 기준 BC1~BC31·DT1~DT8. events.md 의 `build.*` "골격" 3행을 6행으로 확정(`build.rejected` 페이로드에 `action`·`rotation`·`entity_id` 추가, 명령 `build.demolish_requested`, 상태 `build.demolished`·`build.coverage_changed` 신규). `economy.json`·`tiers.json`·`sim.json` 변경 없음(가정 목록 합을 economy 값에 맞춤) |
| 2026-10-09 | build.md, `tier1_club.json`(파일 `version` 1 유지, 항목 추가만), events.md `build.*` | SE-044 | SE-032 리뷰 후속 A·B. `reference_layouts`에 `baseline_plus_two_speakers` 추가(BC21 기대값을 데이터로, `build_oracle.py --layouts` 18키 일치). `build.coverage_changed`·`coverage()`에 `blocked_cells`(C0 점유 셀 전체, G6, 증분 아님, 마지막 키) 추가. 공개 API 표 `Build` → `BuildSystem`, `find_path`·`path_from_entrance` 행 추가(UI·테스트용, sim 시스템은 부르지 않음). `build.rejected` 필드 타입 문장(any / `reason != invalid`이면 좁혀짐). 스키마 변경 없음 |
| 2026-10-09 | build.md, 데이터·스키마 변경 없음 | SE-044 A2 (SE-044 C 인계 1) | #상태 `phase` 행에 "`to`가 `sim.json` `phases[].id`가 아니면 `push_error` 1회 후 무시(`phase` 불변, `sync` 없음)" 한 줄 — SE-044 C `build_system.gd` `_on_phase_changed`·`test_build_system.gd::test_ac5_unknown_phase_ignored` 와 같은 규칙. 관객이 `blocked_cells`를 스냅샷에 저장하는 쪽 정정은 audience.md(SE-044 A2) |
| 2026-10-10 | build.md, `furniture.json`(파일 `version` 1 유지, 값·선택 필드만), `furniture.schema.json` `model` description 문구만(구조·`version` 불변) | SE-041 | (1) `model` 5행 등록: `stage_medium`·`bar_counter`·`speaker_floor`·`bar_fridge`·`light_spot` → `res://assets/models/<id>.glb`(FC4). 검수 통과 후 사람이 `.glb` 를 옮기기 전까지는 리소스가 없어 FurnitureView 가 프록시로 그린다(`ResourceLoader.exists` false → 경고 없이 Proxy). (2) 슬롯 구성을 테스트용 에셋(art-pipeline 서피스)에 맞춤: `speaker_floor` base+accent → base+**emissive**(`#FFB347`, 앰프 전원 LED 호박색), `bar_fridge` base+accent+glass → base+**emissive**+glass(`#E6F4FF`, 냉장고 내부 조명 냉백색). 근거: 런타임이 쓰는 슬롯 색은 아직 `slots.base` 뿐(프록시 정점색, SE-037)이고 accent 색(`#5A6270`·`#C8423A`)은 어느 코드도 읽지 않는다. materials.md 슬롯 표가 emissive 예로 '앰프 표시등, 냉장고 조명'을 든다. 요약 문단 `emissive` 6 → 8. 수치(비용·유지비·효과·footprint·height_m·poly_budget·category) 변경 없음 |
| 2026-10-10 | build.md(문구), 데이터 변경 없음 | SE-058 | #커버리지 "발행" 표 `"sync"` 행을 (a) 저녁 진입 (b) 새 세계 생성 직후 1회(신규, producer 결정 추천안 1) (c) 불러오기·새 게임 재발행으로 나눠 적었다. 옛 문구 "새 게임·복원 직후에는 이벤트가 없으므로"는 SE-036 재발행 이후 이미 사실과 달라 지웠다. enum·페이로드·공식 변경 0 |

## 부록 A. 기준 배치 손계산

### A1. `empty_room`

- 무대 없음 → 관람 타일 ∅, `viewing_count` 0, C1~C3 은 분모 0 규칙으로 0.
- `R` = 빈 맵의 걷기 가능 타일 482(MK6). `floor_free` = 그중 `floor` 478.
- C4: ⌊478 × 2,500 ÷ 10,000⌋ = ⌊119.5⌋ = **119**, `capacity_add` 0, min(150, 119) = 119.
- C5: 입구 2 × 40 = **80**, 가구 0. 부족 = 119 − 80 = **39**.
- C6~C8: 0, 0, 0. 건설비 0, cash 5,000.

### A2. `baseline_show`

배치(순서 = entity 번호):

| entity | 가구 | cell | 회전 | 점유 셀 | 건설비 | 유지비 |
|---|---|---|---|---|---|---|
| f1 | `stage_small` | [10,20] | 0 | x 10..13, z 20..22 (12) | 1,000 | 45 |
| f2 | `speaker_floor` | [9,20] | 0 | [9,20] | 200 | 15 |
| f3 | `speaker_floor` | [14,20] | 0 | [14,20] | 200 | 15 |
| f4 | `bar_counter` | [20,4] | 90 | [20,4] [20,5] [20,6] | 500 | 40 |
| f5 | `bench` | [1,10] | 270 | [1,10] [1,11] | 120 | 4 |
| f6 | `bench` | [1,13] | 270 | [1,13] [1,14] | 120 | 4 |
| 합 | | | | 21 | **2,140** | **123** |

배치 판정: 6개 모두 B1~B10 통과(벽 필요 가구 없음, 무대 앞 행 `[10..13,19]` 비어 있음, 벤치 사이 `[1,12]`는 `[2,12]`로 연결). cash 5,000 − 2,140 = **2,860**.

맵(숫자 = entity 번호, `^` = 무대 앞 행, `x` = 시야 차단 관람 타일, 초점 `g = [12,20]`):

```
     000000000011111111112222
     012345678901234567890123
z 0  ###########EE###########
z 1  #...x......aa.....xx...#
z 2  #...xx............x....#
z 3  #....x...........xx....#
z 4  #....x...........xx.4..#
z 5  #.....x..........x..4..#
z 6  #.....x..........x..4.x#
z 7  #......x........x.....x#
z 8  #x.....P........P....xx#
z 9  #xx.................xx.#
z10  #5x.................xx.#
z11  #5.x...............xx..#
z12  #...x.............xx...#
z13  #6...x...........xx....#
z14  #6....x..........x.....#
z15  #......P........P......#
z16  #......................#
z17  #......................#
z18  #......................#
z19  #.........^^^^.........#
z20  #........211113........#
z21  #.........1111.........#
z22  #.........1111.........#
z23  ########################
```

**C0.** 점유 21칸은 전부 `floor`라 `floor_free` = 478 − 21 = **457**(갇힌 타일 없음). 무대 앞 반평면 `z < 20`. 관람 타일 = `z 1..19`의 빈 `floor` = 457 − (z 20..22 의 빈 `floor`: z20 22 − 6 = 16, z21 22 − 4 = 18, z22 18 → 52) = **405**.

**C1 음향.** 음향원: f1(사각형 x 10..13, z 20..22, r 5), f2(`[9,20]`, r 7), f3(`[14,20]`, r 7). 관람 타일은 z < 20 이라 `dz = 20 − z`. f2: `(x−9)² ≤ 49 − dz²`, f3: `(x−14)² ≤ 49 − dz²`, f1: `dx² ≤ 25 − dz²`(dx 는 사각형 x 10..13 밖 거리). f1 이 덮는 구간은 모든 행에서 f2∪f3 구간 안이라 합집합에 더하는 칸이 없다.
예: z = 19(dz 1): f2 `|x−9| ≤ 6` → 3..15, f3 → 8..20, 합 3..20 = 18칸. z = 14(dz 6): `|x−9| ≤ 3` → 6..12, `|x−14| ≤ 3` → 11..17, 합 6..17 = 12칸. z = 13(dz 7): x = 9, 14 → 2칸. z ≤ 12 (dz ≥ 8): 0.

**C3 바.** f4(x 20, z 4..6, r 8). `dz = max(4 − z, 0, z − 6)`, 조건 `(x − 20)² ≤ 64 − dz²`, x ≤ 22(벽 안). 예: z = 1(dz 3): `|x−20| ≤ 7` → 13..22 = 10칸. z = 14(dz 8): x = 20 → 1칸.

**C2 시야.** 각 관람 타일 `t`에서 `line(t, [12,20])`의 중간 셀에 기둥(`[7,8] [16,8] [7,15] [16,15]`)이 있으면 차단. 이 배치에 `sight_block` 가구는 무대(제외)뿐이라 차단은 기둥만 만든다. 표의 괄호는 처음 만나는 차단 셀.

| z | 관람 타일 x | 수 | 음향 x | 수 | 바 x | 수 | 시야 차단 x (차단 셀) | 수 |
|---|---|---|---|---|---|---|---|---|
| 1 | 1–10, 13–22 | 20 | — | 0 | 13–22 | 10 | 4 (7,8), 18 (16,8), 19 (16,8) | 3 |
| 2 | 1–22 | 22 | — | 0 | 13–22 | 10 | 4 (7,8), 5 (7,8), 18 (16,8) | 3 |
| 3 | 1–22 | 22 | — | 0 | 13–22 | 10 | 5 (7,8), 17 (16,8), 18 (16,8) | 3 |
| 4 | 1–19, 21–22 | 21 | — | 0 | 12–19, 21–22 | 10 | 5 (7,8), 17 (16,8), 18 (16,8) | 3 |
| 5 | 1–19, 21–22 | 21 | — | 0 | 12–19, 21–22 | 10 | 6 (7,8), 17 (16,8) | 2 |
| 6 | 1–19, 21–22 | 21 | — | 0 | 12–19, 21–22 | 10 | 6 (7,8), 17 (16,8), 22 (16,15) | 3 |
| 7 | 1–22 | 22 | — | 0 | 13–22 | 10 | 7 (7,8), 16 (16,8), 22 (16,15) | 3 |
| 8 | 1–6, 8–15, 17–22 | 20 | — | 0 | 13–15, 17–22 | 9 | 1 (7,15), 21 (16,15), 22 (16,15) | 3 |
| 9 | 1–22 | 22 | — | 0 | 13–22 | 10 | 1 (7,15), 2 (7,15), 20 (16,15), 21 (16,15) | 4 |
| 10 | 2–22 | 21 | — | 0 | 14–22 | 9 | 2 (7,15), 20 (16,15), 21 (16,15) | 3 |
| 11 | 2–22 | 21 | — | 0 | 14–22 | 9 | 3 (7,15), 19 (16,15), 20 (16,15) | 3 |
| 12 | 1–22 | 22 | — | 0 | 15–22 | 8 | 4 (7,15), 18 (16,15), 19 (16,15) | 3 |
| 13 | 2–22 | 21 | 9, 14 | 2 | 17–22 | 6 | 5 (7,15), 17 (16,15), 18 (16,15) | 3 |
| 14 | 2–22 | 21 | 6–17 | 12 | 20 | 1 | 6 (7,15), 17 (16,15) | 2 |
| 15 | 1–6, 8–15, 17–22 | 20 | 5–6, 8–15, 17–18 | 12 | — | 0 | — | 0 |
| 16 | 1–22 | 22 | 4–19 | 16 | — | 0 | — | 0 |
| 17 | 1–22 | 22 | 3–20 | 18 | — | 0 | — | 0 |
| 18 | 1–22 | 22 | 3–20 | 18 | — | 0 | — | 0 |
| 19 | 1–22 | 22 | 3–20 | 18 | — | 0 | — | 0 |
| 합 | | **405** | | **96** | | **122** | | **41** |

- `sound_bp` = ⌊96 × 10,000 ÷ 405⌋ = ⌊2,370.37⌋ = **2,370**
- `sight_count` = 405 − 41 = **364**, `sight_bp` = ⌊3,640,000 ÷ 405⌋ = ⌊8,987.65⌋ = **8,987**
- `bar_bp` = ⌊1,220,000 ÷ 405⌋ = ⌊3,012.35⌋ = **3,012**

**C4.** ⌊457 × 2,500 ÷ 10,000⌋ = ⌊114.25⌋ = 114, `capacity_add` 벤치 2 × 4 = 8 → 122, min(150, 122) = **122**.
**C5.** 입구 80 + 가구 0 = **80**. 부족 122 − 80 = **42**.
**C6~C8.** 연출 0. 만족 벤치 2 × 50 = **100**(상한 1,500 안). 유지비 **123**.

시야 차단 41칸 검증 예 하나: `t = [4,1]` → `g = [12,20]`. `dx = 8`, `dz = −19`, `err = −11`. 걸음마다 `e2 = 2·err`; `e2 ≥ −19`이면 x+1, `e2 ≤ 8`이면 z+1. 셀 열: [4,1] [4,2] [5,3] [5,4] [6,5] [6,6] [7,7] **[7,8]** … → 기둥 `[7,8]`에서 차단.
