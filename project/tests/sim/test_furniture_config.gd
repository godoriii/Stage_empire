extends GutTest
## SE-032 — FurnitureConfig. docs/gdd/build.md#설정-로드-검사 FC1~FC5, BC20(reference_sets 합 = expected·economy, FC6·FC7),
## BC25(FC2 위반 사본 → BuildConfig.from_dicts null).

var _raw: Dictionary
var _econ: Dictionary
var _map: Dictionary
var _tiers: Dictionary


func before_all() -> void:
	_raw = JsonUtil.read_json(FurnitureConfig.DEFAULT_PATH)
	_econ = JsonUtil.read_json(BuildConfig.ECONOMY_PATH)
	_map = JsonUtil.read_json(MapConfig.DEFAULT_PATH)
	_tiers = JsonUtil.read_json(MapConfig.TIERS_PATH)


func _scale() -> int:
	return int(_econ["rate_scale"])


func _refund() -> int:
	return int(_econ["demolish_refund_rate_bp"])


func _load(d: Dictionary) -> FurnitureConfig:
	return FurnitureConfig.from_dict(d, _scale(), _refund())


func test_load_ok_and_normalized() -> void:
	var f: FurnitureConfig = _load(_raw.duplicate(true))
	assert_not_null(f)
	assert_eq(f.ids().size(), (_raw["rows"] as Array).size())
	var row: Dictionary = f.furniture("bar_counter")
	assert_eq(row["footprint"], [3, 1])
	assert_eq(typeof(row["build_cost"]), TYPE_INT)
	assert_eq(typeof(row["effects"]["bar_service_radius"]), TYPE_INT)
	assert_eq(f.allowed_phases, ["day"] as Array[String])
	assert_eq(f.allowed_rotations, [0, 90, 180, 270] as Array[int])
	assert_eq(f.category_max_count, {"stage": 1})
	row["build_cost"] = 1
	assert_ne(f.furniture("bar_counter")["build_cost"], 1, "furniture() 는 사본")
	assert_eq(f.furniture("nope"), {})
	assert_false(f.has_furniture("nope"))


func test_bc20_reference_sets() -> void:
	var f: FurnitureConfig = _load(_raw.duplicate(true))
	var cash: int = int(_econ["starting_cash"])
	var sums: Dictionary = {}
	for sid: String in f.reference_set_ids():
		var s: Dictionary = f.reference_set(sid)
		var cost: int = 0
		var upkeep: int = 0
		for it: Dictionary in s["items"]:
			var row: Dictionary = f.furniture(it["furniture_id"])
			cost += int(row["build_cost"]) * int(it["count"])
			upkeep += int(row["upkeep_per_day"]) * int(it["count"])
		assert_eq(cost, s["expected"]["build_cost"], "%s 건설비" % sid)
		assert_eq(upkeep, s["expected"]["upkeep_per_day"], "%s 유지비" % sid)
		assert_eq(cost <= cash, s["expected"]["affordable_with_starting_cash"], "%s 살 수 있음" % sid)
		sums[sid] = cost
	# FC6: economy 가정 목록 합 == economy 시나리오
	var sc: Dictionary = {}
	for x: Dictionary in _econ["reference_scenarios"]:
		if x["id"] == "tier1_baseline":
			sc = x
	var base: Dictionary = f.reference_set("economy_tier1_baseline")
	assert_eq(base["expected"]["build_cost"], int(sc["initial_build_spend"]), "FC6 건설비")
	assert_eq(base["expected"]["upkeep_per_day"], int(sc["upkeep_per_day"]), "FC6 유지비")
	# FC7
	assert_lte(sums["starter_max_trio"], cash, "FC7 무대+스피커+바 ≤ 시작 자금")
	assert_gt(sums["all_rows_once"], cash, "FC7 20종 1개씩 > 시작 자금")
	assert_eq((f.reference_set("all_rows_once")["items"] as Array).size(), f.ids().size(), "모든 행 1개씩")


func test_bc25_fc2_upkeep_rule() -> void:
	var f: FurnitureConfig = _load(_raw.duplicate(true))
	for fid: String in f.ids():
		var row: Dictionary = f.furniture(fid)
		assert_gt(int(row["build_cost"]) * (_scale() - _refund()) / _scale(), int(row["upkeep_per_day"]), "FC2 %s" % fid)
	var bad: Dictionary = _raw.duplicate(true)
	var r0: Dictionary = bad["rows"][0]
	r0["upkeep_per_day"] = int(r0["build_cost"]) * (_scale() - _refund()) / _scale()
	assert_null(BuildConfig.from_dicts(bad, _map.duplicate(true), _tiers, _econ), "유지비를 경계값으로 올린 사본 → null")
	assert_push_error("FC2")
	assert_push_error_count(1)


func test_fc_violations() -> void:
	var cases: Array = []
	var d: Dictionary
	d = _raw.duplicate(true); d["rows"][1]["id"] = d["rows"][0]["id"]; d["rows"][1].erase("model"); cases.append(["FC1 id 중복", d, "FC1"])
	d = _raw.duplicate(true); d["build_rules"]["allowed_rotations"] = [90, 180]; cases.append(["FC3 0 없음", d, "FC3"])
	d = _raw.duplicate(true); d["build_rules"]["allowed_rotations"] = [0, 45]; cases.append(["FC3 방향표 밖 회전", d, "FC3"])
	d = _raw.duplicate(true); d["rows"][0]["model"] = "res://assets/models/other.glb"; cases.append(["FC4 model 경로", d, "FC4"])
	d = _raw.duplicate(true); d["reference_sets"][0]["items"][0]["furniture_id"] = "stage_huge"; cases.append(["FC5 sets", d, "FC5"])
	d = _raw.duplicate(true); d["rows"][0]["footprint"] = [0, 3]; cases.append(["footprint 0", d, "footprint"])
	d = _raw.duplicate(true); d["rows"][0]["effects"].erase("light_grade"); cases.append(["effects 키 누락", d, "light_grade"])
	d = _raw.duplicate(true); d["build_rules"]["allowed_phases"] = ["noon"]; cases.append(["구간 id 아님", d, "allowed_phases"])
	d = _raw.duplicate(true); d["version"] = 2; cases.append(["version", d, "version"])
	var errs: int = 0
	for c: Array in cases:
		assert_null(_load(c[1]), "%s → null" % c[0])
		errs += 1
		assert_push_error(c[2], c[0] + ": 의도한 검사")
		assert_push_error_count(errs, c[0] + ": push_error 1회")
	var ok: Dictionary = _raw.duplicate(true)
	ok["rows"][0]["model"] = "res://assets/models/%s.glb" % ok["rows"][0]["id"]
	assert_not_null(_load(ok), "FC4 규약 경로는 통과")
