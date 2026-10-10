extends GutTest
## SE-028 (qa) — 가구 테이블·티어 1 맵·기준 배치 기대값의 데이터 검증. 제품 코드(BuildConfig 등, SE-032)를 쓰지 않고
## JSON 만 읽는다. docs/gdd/build.md AC2·AC3·AC4·AC6, FC2·FC6·FC7, C0~C8 을 테스트 안의 독립 구현으로 다시 계산한다.
## SE-032 가 BC20~BC26 을 구현해도 이 파일은 "데이터 변경이 규칙과 economy 값을 깨는지" 가드로 남긴다.

const FURNITURE_PATH: String = "res://data/furniture/furniture.json"
const MAP_PATH: String = "res://data/maps/tier1_club.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const TIERS_PATH: String = "res://data/tiers/tiers.json"
const CATEGORIES: Array[String] = ["stage", "sound", "light", "bar", "amenity", "safety", "decor"]

var _furn: Dictionary
var _rows: Dictionary  ## id -> row
var _map: Dictionary
var _econ: Dictionary
var _cap_max: int


## JSON 숫자는 float 로 파싱되므로 Array 비교 전에 재귀적으로 int 로 접는다(스칼라 assert_eq 는 int==float 가 통과한다).
func _ints(v: Variant) -> Variant:
	if v is Array:
		var out: Array = []
		for e: Variant in v:
			out.append(_ints(e))
		return out
	if v is Dictionary:
		var dout: Dictionary = {}
		for k: Variant in v:
			dout[k] = _ints(v[k])
		return dout
	if v is float:
		return int(v)
	return v


func _load(path: String) -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_true(d is Dictionary, "%s 파싱" % path)
	return d as Dictionary


func before_all() -> void:
	_furn = _load(FURNITURE_PATH)
	_map = _load(MAP_PATH)
	_econ = _load(ECONOMY_PATH)
	_rows = {}
	for r: Dictionary in _furn["rows"]:
		_rows[r["id"]] = r
	for t: Dictionary in _load(TIERS_PATH)["rows"]:
		if int(t["tier"]) == 1:
			_cap_max = int(t["capacity_max"])


# --- AC2 -----------------------------------------------------------------------------------------

func test_ac2_row_counts() -> void:
	var rows: Array = _furn["rows"]
	assert_eq(rows.size(), 20, "가구 20행")
	var per_cat: Dictionary = {}
	var glass: int = 0
	var emissive: int = 0
	var wall: int = 0
	var multi: int = 0
	for r: Dictionary in rows:
		per_cat[r["category"]] = int(per_cat.get(r["category"], 0)) + 1
		if (r["slots"] as Dictionary).has("glass"):
			glass += 1
		if (r["slots"] as Dictionary).has("emissive"):
			emissive += 1
		if r["wall_required"]:
			wall += 1
		if int(r["footprint"][0]) * int(r["footprint"][1]) >= 2:
			multi += 1
	for c: String in CATEGORIES:
		assert_gte(int(per_cat.get(c, 0)), 1, "카테고리 %s ≥ 1" % c)
	assert_eq(per_cat.keys().size(), 7, "카테고리 정확히 7종")
	assert_gte(glass, 1, "glass 슬롯 가구 ≥ 1")
	assert_gte(emissive, 2, "emissive 슬롯 가구 ≥ 2")
	assert_gte(wall, 2, "벽 필요 가구 ≥ 2")
	assert_gte(multi, 4, "2칸 이상 가구 ≥ 4")
	assert_gte(int(per_cat.get("stage", 0)), 1, "무대 ≥ 1")
	# build.md 요약 문단의 리터럴(문서-데이터 동기화 가드).
	assert_eq([glass, emissive, wall, multi], [1, 6, 8, 9], "build.md 요약: glass 1 / emissive 6 / 벽 8 / 2칸 이상 9")


func test_ac2_rows_internal_consistency() -> void:
	var ids: Dictionary = {}
	for r: Dictionary in _furn["rows"]:
		assert_false(ids.has(r["id"]), "id 유일: %s" % r["id"])
		ids[r["id"]] = true
		assert_true((r["slots"] as Dictionary).has("base"), "%s: base 슬롯 필수" % r["id"])
		assert_true(CATEGORIES.has(r["category"]), "%s: 카테고리 enum" % r["id"])
		if not r["rotatable"]:
			assert_false(r["wall_required"], "%s: 회전 불가 가구는 벽 필요가 아니다(등면 방향이 고정되지 않음)" % r["id"])
		if r["category"] == "bar" and int(r["effects"]["bar_service_radius"]) == 0:
			fail_test("%s: 바 카테고리는 bar_service_radius > 0" % r["id"])
		var model: String = r.get("model", "")
		if model != "":
			assert_eq(model, "res://assets/models/%s.glb" % r["id"], "%s: FC4 model 경로" % r["id"])


# --- AC3 / FC2 -----------------------------------------------------------------------------------

func test_ac3_upkeep_less_than_non_refunded_share() -> void:
	var s: int = int(_econ["rate_scale"])
	var refund: int = int(_econ["demolish_refund_rate_bp"])
	var min_margin: int = 1 << 30
	for r: Dictionary in _furn["rows"]:
		var lost: int = int(r["build_cost"]) * (s - refund) / s  # 정수 나눗셈 = ⌊⌋ (모두 양수)
		var margin: int = lost - int(r["upkeep_per_day"])
		min_margin = mini(min_margin, margin)
		assert_gt(margin, 0, "%s: ⌊%d×0.3⌋=%d > 유지비 %d" % [r["id"], r["build_cost"], lost, r["upkeep_per_day"]])
	assert_eq(min_margin, 11, "최소 여유 11 (poster_board) — build.md DT1")


# --- reference_sets / economy 정합 (BC20, FC6, FC7) ----------------------------------------------

func _sum_set(set_row: Dictionary) -> Dictionary:
	var up: int = 0
	var cost: int = 0
	for it: Dictionary in set_row["items"]:
		assert_true(_rows.has(it["furniture_id"]), "reference_sets 항목이 행에 있음: %s" % it["furniture_id"])
		var r: Dictionary = _rows[it["furniture_id"]]
		up += int(r["upkeep_per_day"]) * int(it["count"])
		cost += int(r["build_cost"]) * int(it["count"])
	return {"upkeep_per_day": up, "build_cost": cost}


func test_reference_sets_match_expected_and_economy() -> void:
	var start: int = int(_econ["starting_cash"])
	var by_id: Dictionary = {}
	for rs: Dictionary in _furn["reference_sets"]:
		by_id[rs["id"]] = rs
		var sums: Dictionary = _sum_set(rs)
		assert_eq(sums["upkeep_per_day"], int(rs["expected"]["upkeep_per_day"]), "%s 유지비 합" % rs["id"])
		assert_eq(sums["build_cost"], int(rs["expected"]["build_cost"]), "%s 건설비 합" % rs["id"])
		assert_eq(int(sums["build_cost"]) <= start, bool(rs["expected"]["affordable_with_starting_cash"]), "%s affordable" % rs["id"])
	# FC6: economy 가정 목록 == economy.json 기준 시나리오.
	var scenario: Dictionary = {}
	for sc: Dictionary in _econ["reference_scenarios"]:
		if sc["id"] == "tier1_baseline":
			scenario = sc
	assert_false(scenario.is_empty(), "economy tier1_baseline 시나리오")
	var base: Dictionary = _sum_set(by_id["economy_tier1_baseline"])
	assert_eq(base["upkeep_per_day"], int(scenario["upkeep_per_day"]), "FC6: 유지비 200")
	assert_eq(base["build_cost"], int(scenario["initial_build_spend"]), "FC6: 건설비 3,000")
	assert_eq([base["upkeep_per_day"], base["build_cost"]], [200, 3000], "리터럴")
	# FC7: 무대 + 스피커 + 바 는 살 수 있고 전부는 못 산다.
	assert_lte(int(_sum_set(by_id["starter_max_trio"])["build_cost"]), start, "starter_max_trio ≤ starting_cash")
	assert_gt(int(_sum_set(by_id["all_rows_once"])["build_cost"]), start, "all_rows_once > starting_cash")
	# starter_max_trio 는 "가장 비싼 무대"여야 한다.
	var max_stage: int = 0
	for r: Dictionary in _furn["rows"]:
		if r["category"] == "stage":
			max_stage = maxi(max_stage, int(r["build_cost"]))
	assert_eq(int(_rows["stage_medium"]["build_cost"]), max_stage, "stage_medium 이 가장 비싼 무대")
	# all_rows_once 는 20행을 정확히 한 번씩.
	var seen: Dictionary = {}
	for it: Dictionary in by_id["all_rows_once"]["items"]:
		seen[it["furniture_id"]] = int(it["count"])
	assert_eq(seen.size(), 20, "all_rows_once 20종")
	for id: String in _rows:
		assert_eq(int(seen.get(id, 0)), 1, "all_rows_once: %s 1개" % id)


# --- AC6 / MK ------------------------------------------------------------------------------------

func _kind(x: int, z: int) -> Dictionary:
	if x < 0 or z < 0 or x >= int(_map["width"]) or z >= int(_map["depth"]):
		return {}
	var ch: String = (_map["tiles"][z] as String).substr(x, 1)
	for k: Dictionary in _map["tile_kinds"]:
		if k["char"] == ch:
			return k
	return {}


func _reach(occupied: Dictionary) -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array[Vector2i] = []
	for z: int in range(int(_map["depth"])):
		for x: int in range(int(_map["width"])):
			if _kind(x, z)["id"] == "entrance":
				seen[Vector2i(x, z)] = true
				queue.append(Vector2i(x, z))
	var head: int = 0
	while head < queue.size():
		var p: Vector2i = queue[head]
		head += 1
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = p + d
			var k: Dictionary = _kind(n.x, n.y)
			if not k.is_empty() and k["walkable"] and not seen.has(n) and not occupied.has(n):
				seen[n] = true
				queue.append(n)
	return seen


func test_ac6_map_structure() -> void:
	var w: int = int(_map["width"])
	var d: int = int(_map["depth"])
	assert_eq([w, d], [24, 24], "24×24")
	assert_eq((_map["tiles"] as Array).size(), d, "MK1 행 수")
	var kinds: Dictionary = {}
	var chars: Dictionary = {}
	for k: Dictionary in _map["tile_kinds"]:
		assert_false(kinds.has(k["id"]) or chars.has(k["char"]), "MK3 id·char 유일")
		kinds[k["id"]] = k
		chars[k["char"]] = true
	var count: Dictionary = {}
	for z: int in range(d):
		var row: String = _map["tiles"][z]
		assert_eq(row.length(), w, "MK1 z=%d 길이" % z)
		for x: int in range(w):
			assert_true(chars.has(row.substr(x, 1)), "MK3 (%d,%d) 글자 정의됨" % [x, z])
			var k: Dictionary = _kind(x, z)
			count[k["id"]] = int(count.get(k["id"], 0)) + 1
			if x == 0 or z == 0 or x == w - 1 or z == d - 1:
				assert_true(not k["walkable"] or k["id"] == "entrance", "MK5 가장자리 닫힘 (%d,%d)" % [x, z])
	assert_gte(int(count.get("entrance", 0)), 1, "MK4 입구 ≥ 1")
	assert_eq([count["floor"], count["entrance"], count["apron"], count["pillar"]], [478, 2, 2, 4], "build.md 맵 수치표")
	assert_eq(w, 24, "tiers.grid_size 와 같음")
	# MK6: 빈 맵의 걷기 가능 타일 전부가 입구와 연결.
	var r0: Dictionary = _reach({})
	var walkable: int = 0
	for z: int in range(d):
		for x: int in range(w):
			if _kind(x, z)["walkable"]:
				walkable += 1
	assert_eq(r0.size(), walkable, "MK6 걷기 가능 타일 482 전부 도달")
	assert_eq(walkable, 482, "482")
	# AC6: 입구 → 중앙(11,12) 빈 경로(x=11 열).
	for z: int in range(0, 13):
		assert_true(_kind(11, z)["walkable"], "x=11 열 z=%d 걷기 가능" % z)
	assert_true(r0.has(Vector2i(11, 12)), "중앙 도달")
	# 입구 피난 2×40 = 80.
	var evac: int = 0
	for z: int in range(d):
		for x: int in range(w):
			evac += int(_kind(x, z)["evac_capacity"])
	assert_eq(evac, 80, "입구 피난 80")
	# 수용: 빈 방.
	var cap: int = mini(_cap_max, int(count["floor"]) * int(_map["persons_per_tile_bp"]) / int(_econ["rate_scale"]))
	assert_eq(cap, 119, "빈 방 수용 119")
	var tiers_ok: bool = cap >= 50 and cap <= _cap_max
	assert_true(tiers_ok, "DT5: 119 ∈ [capacity_min, capacity_max]")


# --- 커버리지 독립 재계산 (C0~C8) vs reference_layouts[].expected (AC4, BC22·BC23) -----------------

func _rot_size(fp: Array, rot: int) -> Vector2i:
	if rot == 90 or rot == 270:
		return Vector2i(int(fp[1]), int(fp[0]))
	return Vector2i(int(fp[0]), int(fp[1]))


func _line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var dx: int = absi(b.x - a.x)
	var sx: int = 1 if a.x < b.x else -1
	var dz: int = -absi(b.y - a.y)
	var sz: int = 1 if a.y < b.y else -1
	var err: int = dx + dz
	var p: Vector2i = a
	var out: Array[Vector2i] = []
	while true:
		out.append(p)
		if p == b:
			break
		var e2: int = 2 * err
		if e2 >= dz:
			err += dz
			p.x += sx
		if e2 <= dx:
			err += dx
			p.y += sz
	return out


func _coverage(placements: Array) -> Dictionary:
	var insts: Array = []
	var occ: Dictionary = {}
	for p: Dictionary in placements:
		var row: Dictionary = _rows[p["furniture_id"]]
		var sz: Vector2i = _rot_size(row["footprint"], int(p["rotation"]))
		var cells: Array[Vector2i] = []
		for z: int in range(sz.y):
			for x: int in range(sz.x):
				cells.append(Vector2i(int(p["cell"][0]) + x, int(p["cell"][1]) + z))
		for c: Vector2i in cells:
			assert_false(occ.has(c), "배치 겹침 없음 %s" % str(c))
			occ[c] = true
		insts.append({"row": row, "cells": cells, "rot": int(p["rotation"]), "min": Vector2i(int(p["cell"][0]), int(p["cell"][1])), "size": sz})
	var reach: Dictionary = _reach(occ)
	var floor_free: int = 0
	for t: Vector2i in reach:
		if _kind(t.x, t.y)["standing"]:
			floor_free += 1
	var view: Array[Vector2i] = []
	var focus: Vector2i = Vector2i(-1, -1)
	for i: Dictionary in insts:
		if i["row"]["category"] != "stage":
			continue
		var m: Vector2i = i["min"]
		var sz: Vector2i = i["size"]
		var e: Array[Vector2i] = []
		match int(i["rot"]):
			0:
				for x: int in range(m.x, m.x + sz.x):
					e.append(Vector2i(x, m.y))
			90:
				for z: int in range(m.y, m.y + sz.y):
					e.append(Vector2i(m.x, z))
			180:
				for x: int in range(m.x, m.x + sz.x):
					e.append(Vector2i(x, m.y + sz.y - 1))
			_:
				for z: int in range(m.y, m.y + sz.y):
					e.append(Vector2i(m.x + sz.x - 1, z))
		focus = e[e.size() / 2]
		for z: int in range(int(_map["depth"])):
			for x: int in range(int(_map["width"])):
				var t: Vector2i = Vector2i(x, z)
				if not reach.has(t) or not _kind(x, z)["standing"]:
					continue
				var front: bool = false
				match int(i["rot"]):
					0:
						front = z < m.y
					90:
						front = x < m.x
					180:
						front = z > m.y + sz.y - 1
					_:
						front = x > m.x + sz.x - 1
				if front:
					view.append(t)
	var snd: int = 0
	var bar: int = 0
	for t: Vector2i in view:
		var s_hit: bool = false
		var b_hit: bool = false
		for i: Dictionary in insts:
			var m: Vector2i = i["min"]
			var sz: Vector2i = i["size"]
			var ddx: int = maxi(maxi(m.x - t.x, 0), t.x - (m.x + sz.x - 1))
			var ddz: int = maxi(maxi(m.y - t.y, 0), t.y - (m.y + sz.y - 1))
			var d2: int = ddx * ddx + ddz * ddz
			var sr: int = int(i["row"]["effects"]["sound_radius"])
			var br: int = int(i["row"]["effects"]["bar_service_radius"])
			if sr > 0 and d2 <= sr * sr:
				s_hit = true
			if br > 0 and d2 <= br * br:
				b_hit = true
		snd += 1 if s_hit else 0
		bar += 1 if b_hit else 0
	var blockers: Dictionary = {}
	for i: Dictionary in insts:
		if i["row"]["effects"]["sight_block"] and i["row"]["category"] != "stage":
			for c: Vector2i in i["cells"]:
				blockers[c] = true
	var blocked: Array = []
	for t: Vector2i in view:
		var ln: Array[Vector2i] = _line(t, focus)
		var hit: bool = false
		for k: int in range(1, ln.size() - 1):
			var c: Vector2i = ln[k]
			var kd: Dictionary = _kind(c.x, c.y)
			if kd.is_empty() or kd["blocks_sight"] or blockers.has(c):
				hit = true
				break
		if hit:
			blocked.append([t.x, t.y])
	var n: int = view.size()
	var rs: int = int(_econ["rate_scale"])
	var cap_add: int = 0
	var evac: int = 0
	var light: int = 0
	var sat: int = 0
	var up: int = 0
	var cost: int = 0
	for i: Dictionary in insts:
		var ef: Dictionary = i["row"]["effects"]
		cap_add += int(ef["capacity_add"])
		evac += int(ef["evac_capacity"])
		light += int(ef["light_grade"])
		sat += int(ef["satisfaction_bonus_bp"])
		up += int(i["row"]["upkeep_per_day"])
		cost += int(i["row"]["build_cost"])
	for z: int in range(int(_map["depth"])):
		for x: int in range(int(_map["width"])):
			evac += int(_kind(x, z)["evac_capacity"])
	var capacity: int = mini(_cap_max, floor_free * int(_map["persons_per_tile_bp"]) / rs + cap_add)
	return {
		"has_stage": focus != Vector2i(-1, -1), "floor_free": floor_free, "viewing_count": n,
		"sound_count": snd, "sound_bp": snd * rs / n if n > 0 else 0,
		"sight_count": n - blocked.size(), "sight_bp": (n - blocked.size()) * rs / n if n > 0 else 0,
		"bar_count": bar, "bar_bp": bar * rs / n if n > 0 else 0,
		"capacity": capacity, "evac_capacity": evac, "evac_shortfall": maxi(0, capacity - evac),
		"light_grade": light, "satisfaction_bonus_bp": mini(int(_furn["build_rules"]["satisfaction_bonus_cap_bp"]), sat),
		"upkeep_per_day": up, "build_cost": cost, "cash_after": int(_econ["starting_cash"]) - cost,
		"sight_blocked_cells": blocked,
	}


func test_reference_layouts_expected_values_recomputed() -> void:
	var seen_ids: Array = []
	for lay: Dictionary in _map["reference_layouts"]:
		seen_ids.append(lay["id"])
		var got: Dictionary = _coverage(lay["placements"])
		var exp: Dictionary = lay["expected"]
		for key: String in exp:
			assert_eq(_ints(got[key]), _ints(exp[key]), "%s.%s" % [lay["id"], key])
	# id 목록은 리터럴로 고정하지 않는다(SE-044: 레이아웃이 추가돼도 깨지지 않게). 유일성 + 기준 배치 3종(BC21 레이아웃 포함) 포함만 단언.
	var unique: Dictionary = {}
	for lid: String in seen_ids:
		unique[lid] = true
	assert_eq(unique.size(), seen_ids.size(), "레이아웃 id 유일")
	for lid: String in ["empty_room", "baseline_show", "baseline_plus_two_speakers"]:
		assert_true(seen_ids.has(lid), "기준 배치 %s 포함" % lid)


func test_baseline_literals_match_ticket_and_doc() -> void:
	var lay: Dictionary = {}
	for l: Dictionary in _map["reference_layouts"]:
		if l["id"] == "baseline_show":
			lay = l
	var e: Dictionary = lay["expected"]
	assert_eq(_ints([e["viewing_count"], e["sound_count"], e["sound_bp"], e["sight_count"], e["sight_bp"], e["bar_count"], e["bar_bp"]]),
		[405, 96, 2370, 364, 8987, 122, 3012], "부록 A 리터럴")
	assert_eq(_ints([e["capacity"], e["evac_capacity"], e["evac_shortfall"], e["upkeep_per_day"], e["build_cost"]]),
		[122, 80, 42, 123, 2140], "수용·피난·유지비·건설비 리터럴")
	assert_eq((e["sight_blocked_cells"] as Array).size(), 41, "시야 차단 41칸")
	# DT4·DT6·DT7·DT8
	assert_gte(int(e["capacity"]), 100, "DT4: 수용 ≥ economy 기준 입장 100")
	assert_lt(int(e["sound_bp"]), 3000, "DT6: 기준 음향 < 3,000")
	assert_gte(int(e["sight_bp"]), 8000, "DT7: 시야 ≥ 8,000")
	assert_gt(int(e["evac_shortfall"]), 0, "DT8: 기준 배치 피난 부족 > 0")


func test_bc21_two_more_speakers_reach_dt6() -> void:
	# SE-044: BC21 기대값(관람·음향·음향 bp)은 리터럴이 아니라 baseline_plus_two_speakers.expected 에서 읽는다.
	# 배치는 baseline_show + 스피커 2(build.md BC21 좌표)로 이 테스트가 직접 조립해, 데이터 레이아웃과 같은지도 대조한다.
	var base: Dictionary = {}
	var plus: Dictionary = {}
	for l: Dictionary in _map["reference_layouts"]:
		if l["id"] == "baseline_show":
			base = l
		elif l["id"] == "baseline_plus_two_speakers":
			plus = l
	assert_false(plus.is_empty(), "baseline_plus_two_speakers 레이아웃이 있다")
	var pl: Array = (base["placements"] as Array).duplicate(true)
	pl.append({"furniture_id": "speaker_floor", "cell": [5, 10], "rotation": 0})
	pl.append({"furniture_id": "speaker_floor", "cell": [18, 10], "rotation": 0})
	assert_eq(_ints(plus["placements"]), _ints(pl), "데이터 레이아웃 = baseline_show + 스피커 2")
	var want: Dictionary = plus["expected"]
	var got: Dictionary = _coverage(pl)
	assert_eq(_ints([got["viewing_count"], got["sound_count"], got["sound_bp"]]), _ints([want["viewing_count"], want["sound_count"], want["sound_bp"]]), "BC21 (데이터 expected)")
	assert_gte(int(got["sound_bp"]), 6000, "DT6: 스피커 2 추가 시 ≥ 6,000")


func test_bc24_pure_function_literals() -> void:
	assert_eq(_rot_size([3, 1], 90), Vector2i(1, 3), "rotated_size([3,1],90)")
	var ln: Array[Vector2i] = _line(Vector2i(4, 1), Vector2i(12, 20))
	assert_true(ln.has(Vector2i(7, 8)), "line([4,1],[12,20]) 이 기둥 [7,8] 을 지남")
	var straight: Array[Vector2i] = _line(Vector2i(12, 1), Vector2i(12, 20))
	assert_eq(straight.size(), 20, "line([12,1],[12,20]) 20칸")
	for k: int in range(straight.size()):
		assert_eq(straight[k], Vector2i(12, 1 + k), "x=12 직선 %d" % k)


func test_baseline_placements_do_not_touch_fixed_tiles() -> void:
	# 배치 전부 buildable 타일 위(B6)이고 벽 필요 가구는 없다 — 기준 배치는 벽 규칙에 기대지 않는다.
	for lay: Dictionary in _map["reference_layouts"]:
		for p: Dictionary in lay["placements"]:
			var row: Dictionary = _rows[p["furniture_id"]]
			assert_false(row["wall_required"], "%s: 기준 배치에 벽 필요 가구 없음" % p["furniture_id"])
			assert_true(row["rotatable"] or int(p["rotation"]) == 0, "%s: 회전 규칙(B4)" % p["furniture_id"])
			var sz: Vector2i = _rot_size(row["footprint"], int(p["rotation"]))
			for z: int in range(sz.y):
				for x: int in range(sz.x):
					var k: Dictionary = _kind(int(p["cell"][0]) + x, int(p["cell"][1]) + z)
					assert_false(k.is_empty(), "B5 맵 안")
					if not k.is_empty():
						assert_true(k["buildable"], "B6 buildable: %s" % str(p["cell"]))
