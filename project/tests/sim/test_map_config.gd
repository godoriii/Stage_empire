extends GutTest
## SE-032 — MapConfig. docs/gdd/build.md#맵, #설정-로드-검사 MK1~MK6 (BC26), C0 도달 집합.

var _raw: Dictionary
var _tiers: Dictionary


func before_all() -> void:
	_raw = MapConfig.read_json(MapConfig.DEFAULT_PATH)
	_tiers = MapConfig.read_json(MapConfig.TIERS_PATH)


func _copy() -> Dictionary:
	return _raw.duplicate(true)


func _set_char(d: Dictionary, x: int, z: int, c: String) -> void:
	var line: String = d["tiles"][z]
	d["tiles"][z] = line.substr(0, x) + c + line.substr(x + 1)


func test_load_ok() -> void:
	var m: MapConfig = MapConfig.load()
	assert_not_null(m)
	assert_eq(m.width, _raw["width"])
	assert_eq(m.depth, _raw["depth"])
	assert_eq(m.entrances(), [[11, 0], [12, 0]])
	var evac: int = 0
	var walkable: int = 0
	var floor_n: int = 0
	for z: int in m.depth:
		for x: int in m.width:
			var k: Dictionary = m.tile_kind([x, z])
			evac += int(k["evac_capacity"])
			walkable += 1 if k["walkable"] else 0
			floor_n += 1 if k["id"] == "floor" else 0
	assert_eq(m.evac_total, evac)
	assert_eq(m.evac_total, _raw["reference_layouts"][0]["expected"]["evac_capacity"], "빈 방 피난 80")
	assert_eq(floor_n, int(_raw["reference_layouts"][0]["expected"]["floor_free"]), "floor 478")
	assert_eq(m.reachable({}).size(), walkable, "MK6: 걷기 가능 482 전부 연결")
	assert_eq(walkable, floor_n + 4, "바닥 + 완충 2 + 입구 2")


func test_tile_kind_and_queries() -> void:
	var m: MapConfig = MapConfig.load()
	assert_eq(m.tile_kind([-1, 0]), {}, "맵 밖 {}")
	assert_eq(m.tile_kind([24, 3]), {})
	assert_eq(m.tile_kind([7, 8])["id"], "pillar")
	assert_eq(m.tile_kind([11, 1])["id"], "apron")
	var k: Dictionary = m.tile_kind([0, 0])
	k["mountable"] = false
	assert_true(m.is_mountable(0, 0), "tile_kind 는 사본")
	assert_false(m.is_mountable(-1, 5), "맵 밖은 mountable 아님")
	assert_false(m.is_mountable(7, 8), "기둥은 mountable 아님")
	assert_true(m.blocks_sight(7, 8))
	assert_false(m.is_buildable(11, 1))
	assert_true(m.is_buildable(5, 5))


func test_reachable_respects_blocked() -> void:
	var m: MapConfig = MapConfig.load()
	var blocked: Dictionary = {Vector2i(11, 1): true, Vector2i(12, 1): true}
	var r: Dictionary = m.reachable(blocked)
	assert_eq(r.size(), 2, "완충을 막으면 입구 2칸만")
	assert_true(r.has(Vector2i(11, 0)))


func test_layouts_parsed_as_int() -> void:
	var m: MapConfig = MapConfig.load()
	assert_eq(m.layout_ids(), ["empty_room", "baseline_show"])
	var l: Dictionary = m.layout("baseline_show")
	assert_eq(l["placements"][0], {"furniture_id": "stage_small", "cell": [10, 20], "rotation": 0})
	assert_eq(typeof(l["expected"]["floor_free"]), TYPE_INT, "float → int 접기")
	assert_eq(typeof(l["expected"]["sight_blocked_cells"][0][0]), TYPE_INT)
	assert_eq(m.layout("nope"), {})


func test_bc26_mk_violations() -> void:
	var cases: Array = []
	var d: Dictionary
	d = _copy(); d["tiles"][3] = (d["tiles"][3] as String).substr(1); cases.append(["MK1 행 23글자", d, "MK1"])
	d = _copy(); (d["tiles"] as Array).pop_back(); cases.append(["MK1 행 수", d, "MK1"])
	d = _copy(); _set_char(d, 11, 0, "#"); _set_char(d, 12, 0, "#"); cases.append(["MK4 입구 0개", d, "MK4"])
	d = _copy(); _set_char(d, 0, 5, "."); cases.append(["MK5 가장자리 .", d, "MK5"])
	d = _copy(); _set_char(d, 10, 1, "P"); _set_char(d, 13, 1, "P"); _set_char(d, 11, 2, "P"); _set_char(d, 12, 2, "P"); cases.append(["MK6 기둥으로 완충을 가둠", d, "MK6"])
	d = _copy(); d["tier"] = 2; cases.append(["MK2 grid_size", d, "MK2"])
	d = _copy(); _set_char(d, 5, 5, "?"); cases.append(["MK3 모르는 글자", d, "MK3"])
	d = _copy(); d["tile_kinds"][2]["char"] = "#"; cases.append(["MK3 char 중복", d, "MK3"])
	d = _copy(); d["tile_kinds"][2]["id"] = "wall"; cases.append(["MK3 id 중복", d, "MK3"])
	d = _copy(); d["reference_layouts"][1]["placements"][0]["cell"] = [1.5, 2]; cases.append(["layout cell 정수 아님", d, "cell"])
	var errs: int = 0
	for c: Array in cases:
		assert_null(MapConfig.from_dict(c[1], _tiers), "%s → null" % c[0])
		errs += 1
		assert_push_error(c[2], c[0] + ": 의도한 검사")
		assert_push_error_count(errs, c[0] + ": push_error 1회")
	assert_not_null(MapConfig.from_dict(_copy(), _tiers), "원본은 통과")
