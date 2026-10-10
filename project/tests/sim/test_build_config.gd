extends GutTest
## SE-032 — BuildConfig. docs/gdd/build.md#공개-api (load·from_dicts·읽기 전용 조회·순수 함수 BC24), FC5(layouts 쪽).

var _f: Dictionary
var _m: Dictionary
var _t: Dictionary
var _e: Dictionary


func before_all() -> void:
	_f = JsonUtil.read_json(FurnitureConfig.DEFAULT_PATH)
	_m = JsonUtil.read_json(MapConfig.DEFAULT_PATH)
	_t = JsonUtil.read_json(MapConfig.TIERS_PATH)
	_e = JsonUtil.read_json(BuildConfig.ECONOMY_PATH)


func test_load_ok() -> void:
	var cfg: BuildConfig = BuildConfig.load()
	assert_not_null(cfg)
	assert_eq(cfg.rate_scale, int(_e["rate_scale"]))
	assert_eq(cfg.starting_cash, int(_e["starting_cash"]))
	assert_eq(cfg.demolish_refund_rate_bp, int(_e["demolish_refund_rate_bp"]))
	var tier_row: Dictionary = {}
	for r: Dictionary in _t["rows"]:
		if int(r["tier"]) == int(_m["tier"]):
			tier_row = r
	assert_eq(cfg.capacity_max, int(tier_row["capacity_max"]))
	assert_true(cfg.has_furniture("stage_small"))
	assert_eq(cfg.furniture("stage_small")["footprint"], [4, 3])
	assert_eq(cfg.tile_kind([11, 0])["id"], "entrance")
	assert_eq(cfg.tile_kind([99, 0]), {})
	assert_eq(cfg.layout("empty_room")["expected"]["capacity"], int(_m["reference_layouts"][0]["expected"]["capacity"]))
	assert_eq(cfg.reference_set("starter_max_trio")["expected"]["build_cost"], int(_f["reference_sets"][1]["expected"]["build_cost"]))
	var l: Dictionary = cfg.layout("baseline_show")
	l["placements"].clear()
	assert_eq((cfg.layout("baseline_show")["placements"] as Array).size(), 6, "layout() 는 깊은 사본")


func test_bc24_pure_functions() -> void:
	assert_eq(BuildConfig.rotated_size([3, 1], 90), [1, 3])
	assert_eq(BuildConfig.cells_of([3, 1], [20, 4], 90), [[20, 4], [20, 5], [20, 6]])
	assert_true(BuildConfig.line([4, 1], [12, 20]).has([7, 8]), "기둥을 지나는 시야 레이")
	var straight: Array = BuildConfig.line([12, 1], [12, 20])
	assert_eq(straight.size(), 20)
	for c: Array in straight:
		assert_eq(c[0], 12)


func test_fc5_layout_unknown_furniture() -> void:
	var m: Dictionary = _m.duplicate(true)
	m["reference_layouts"][1]["placements"][0]["furniture_id"] = "stage_huge"
	assert_null(BuildConfig.from_dicts(_f.duplicate(true), m, _t, _e))
	assert_push_error("FC5")
	assert_push_error_count(1)


func test_bad_economy_or_map_fails() -> void:
	var e: Dictionary = _e.duplicate(true)
	e.erase("rate_scale")
	assert_null(BuildConfig.from_dicts(_f.duplicate(true), _m.duplicate(true), _t, e))
	assert_push_error_count(1)
	var m: Dictionary = _m.duplicate(true)
	m["width"] = 23
	assert_null(BuildConfig.from_dicts(_f.duplicate(true), m, _t, _e))
	assert_push_error_count(2)
	assert_null(BuildConfig.load("res://data/furniture/missing.json"))
	assert_push_error_count(3)
