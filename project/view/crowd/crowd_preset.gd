class_name CrowdPreset
extends RefCounted
## SE-038: 샌드박스 --se-crowd-preset=<n> 용 가짜 sim 출력(sim 이 없는 샌드박스에서 군중·스포트를 보이기 위한 고정 데이터).
## 이벤트 버스에 발행하지 않는다. 샌드박스가 CrowdView / StageLights / FurnitureView 의 핸들러에 직접 넣는다
## (BuildPreset 과 같은 방식). SE-034 통합 뒤에는 실제 audience·show 시스템의 이벤트가 같은 자리에 들어온다.
##
## 구성(전부 데이터·리소스에서 계산, 가구 id·좌표 리터럴 없음):
##   가구   = BuildPreset baseline(기준 배치 6) + 조명 가구: furniture.json category "light" 중 1×1 행을 light_grade 내림차순으로
##            Σ light_grade ≥ max_spots 가 될 때까지 무대 정면 가장자리 양 끝 바깥 preset_light_offset_cells 칸, 한 줄 뒤에 좌우 교대로.
##   관객   = n 명, 전원 watching. 자리 = 관람 타일(BuildPreset.coverage_payload) 중 무대 초점 셀 g 에 가까운 순(거리², z, x).
##            유형 = 표시 전용 RNG(preset_seed) 로 audience.json types 중 하나. 좌표 = 타일 중앙 c(t)(audience.md 표시 좌표).
##   공연   = show.started 페이로드(events.md SE-030 형식) 하나.

const ARG: String = "--se-crowd-preset="
const NONE: String = ""
const LIGHT_CATEGORY: String = "light"
const STATE_WATCHING: String = "watching"


## 명령줄에서 프리셋 값(가공 전 문자열). 인자가 없으면 NONE("").
static func resolve(user_args: PackedStringArray) -> String:
	for a: String in user_args:
		if a.begins_with(ARG):
			return a.trim_prefix(ARG).strip_edges()
	return NONE


## 관객 수. 정수이고 1 ≤ n ≤ max_agents 가 아니면 -1.
static func parse_count(raw: String, max_agents: int) -> int:
	if not raw.is_valid_int():
		return -1
	var n: int = raw.to_int()
	return n if n >= 1 and n <= max_agents else -1


## 조명 가구 build.placed 페이로드 열. stage = StageGeometry.from_placed 결과. 첫 entity 번호 = first_entity_n.
static func light_payloads(catalog: BuildCatalog, stage: Dictionary, target_grade: int, offset_cells: int,
		first_entity_n: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if stage.is_empty() or target_grade <= 0:
		return out
	var rows: Array[Dictionary] = []
	for r: Dictionary in catalog.rows_in_category(LIGHT_CATEGORY):
		if BuildCatalog.footprint_of(r) == Vector2i.ONE and _grade_of(r) > 0:
			rows.append(r)
	# light_grade 내림차순, 같으면 테이블 순서(안정 정렬 대신 인덱스 비교).
	var order: Array[int] = []
	for i: int in rows.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var ga: int = _grade_of(rows[a])
		var gb: int = _grade_of(rows[b])
		return ga > gb if ga != gb else a < b)
	var edge: Array[Vector2i] = StageGeometry.front_edge_cells(stage["footprint"], stage["cell"], stage["rotation"])
	var front3: Vector3 = StageGeometry.front_dir(stage["rotation"])
	var back: Vector2i = Vector2i(-roundi(front3.x), -roundi(front3.z))
	var side: Vector2i = (edge[edge.size() - 1] - edge[0]).sign()
	if side == Vector2i.ZERO:
		side = Vector2i(back.y, back.x)
	var total: int = 0
	var k: int = 0
	for idx: int in order:
		if total >= target_grade:
			break
		var r: Dictionary = rows[idx]
		var row_back: int = 1 + k / 2
		var cell: Vector2i
		if k % 2 == 0:
			cell = edge[0] - side * offset_cells + back * row_back
		else:
			cell = edge[edge.size() - 1] + side * offset_cells + back * row_back
		out.append({
			"entity_id": "f%d" % (first_entity_n + k), "furniture_id": str(r["id"]), "cell": BuildCatalog.to_pair(cell),
			"rotation": 0, "cells": [BuildCatalog.to_pair(cell)], "cost": int(r.get("build_cost", 0)),
		})
		total += _grade_of(r)
		k += 1
	return out


## audience.agent_moved 페이로드(n 명, 전원 watching). viewing_tiles = coverage_changed 의 관람 타일 [[x, z], …].
static func agents_payload(data: CrowdData, viewing_tiles: Array, focus: Vector2i, n: int, seed_value: int, tick: int) -> Dictionary:
	var tiles: Array[Vector2i] = []
	for p: Variant in viewing_tiles:
		tiles.append(BuildCatalog.to_cell(p))
	tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da: int = (a - focus).length_squared()
		var db: int = (b - focus).length_squared()
		if da != db:
			return da < db
		return a.y < b.y if a.y != b.y else a.x < b.x)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var agents: Array = []
	for i: int in range(mini(n, tiles.size())):
		var pos: Vector2i = data.tile_center_pos(tiles[i])
		var type_id: String = data.type_ids[rng.randi() % data.type_ids.size()]
		agents.append([i + 1, pos.x, pos.y, STATE_WATCHING, type_id])
	return {"tick": tick, "agents": agents}


## show.started 페이로드(events.md SE-030 형식: {day, artist_id, genre, expected_admissions}). 샌드박스 표시용 빈 값.
static func show_started_payload(expected_admissions: int) -> Dictionary:
	return {"day": 1, "artist_id": "", "genre": "", "expected_admissions": expected_admissions}


static func _grade_of(row: Dictionary) -> int:
	return int((row.get("effects", {}) as Dictionary).get(StageLights.LIGHT_GRADE_FIELD, 0))
