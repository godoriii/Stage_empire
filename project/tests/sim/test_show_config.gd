extends GutTest
## SE-035 — ShowConfig. docs/gdd/show.md#수용-기준 SH1(SL1~SL4 교차 검사)과 공개 API 조회를 옮겼다.
## 기대 수치는 show.json(grades)·artist.json(show_grades)·economy.json(ticket_price_default)에서 읽는다.

var _show: Dictionary
var _artist: Dictionary
var _economy: Dictionary


func before_all() -> void:
	_show = JsonUtil.read_json(ShowConfig.DEFAULT_PATH)
	_artist = JsonUtil.read_json(ShowConfig.ARTIST_PATH)
	_economy = JsonUtil.read_json(ShowConfig.ECONOMY_PATH)


func _copies() -> Array:
	return [_show.duplicate(true), _artist.duplicate(true), _economy.duplicate(true)]


## SL1~SL4 를 하나씩 깬 사본: [라벨, push_error 문구 일부, show, artist, economy].
func _broken() -> Array:
	var out: Array = []
	var c: Array
	c = _copies(); c[0]["version"] = 2
	out.append(["version 2", "SL1"] + c)
	c = _copies()
	var g: Array = c[0]["grades"]
	var tmp: Variant = g[0]; g[0] = g[1]; g[1] = tmp
	out.append(["grades 순서 poor, disaster, …", "SL3"] + c)
	c = _copies(); c[0]["grades"][c[0]["grades"].size() - 1]["id"] = "legend"
	out.append(["rave → legend", "SL2"] + c)
	c = _copies(); c[0]["grades"][0]["min_bp"] = 100
	out.append(["첫 min_bp 100", "SL3"] + c)
	c = _copies()
	var ok_i: int = _grade_index("ok")
	c[0]["grades"][ok_i + 1]["min_bp"] = c[0]["grades"][ok_i]["min_bp"]
	out.append(["good.min_bp == ok.min_bp", "SL3"] + c)
	c = _copies(); c[0]["satisfaction_source"] = "show.formula"
	out.append(["satisfaction_source 다른 문자열(스키마 우회)", "SL4"] + c)
	c = _copies(); c[0]["grades"][c[0]["grades"].size() - 1]["min_bp"] = int(_economy["rate_scale"]) + 1
	out.append(["마지막 min_bp > rate_scale", "SL3"] + c)
	c = _copies(); (c[1]["show_grades"] as Array).reverse()
	out.append(["artist.json show_grades 역순", "SL"] + c)
	return out


func _grade_index(id: String) -> int:
	var rows: Array = _show["grades"]
	for i: int in rows.size():
		if rows[i]["id"] == id:
			return i
	return -1


# --- SH1 ------------------------------------------------------------------------

func test_config_loads_and_cross_checks() -> void:
	var cfg: ShowConfig = ShowConfig.load()
	assert_not_null(cfg, "실제 데이터 로드 성공")
	assert_not_null(ShowConfig.from_dicts(_show, _artist, _economy), "from_dicts 도 같은 데이터로 성공")
	var broken: Array = _broken()
	assert_true(broken.size() >= 5, "SL1~SL4 를 깬 사본 5건 이상")
	var errs: int = 0
	for b: Array in broken:
		assert_null(ShowConfig.from_dicts(b[2], b[3], b[4]), "%s → null" % b[0])
		errs += 1
		assert_push_error(b[1], "%s: 의도한 검사(%s)" % [b[0], b[1]])
		assert_push_error_count(errs, "%s: push_error 1회" % b[0])


func test_config_accessors() -> void:
	var cfg: ShowConfig = ShowConfig.load()
	var rows: Array = _show["grades"]
	assert_eq(cfg.grade_ids(), Array(_artist["show_grades"], TYPE_STRING, "", null), "grade_ids == artist.json show_grades")
	for r: Dictionary in rows:
		assert_eq(cfg.grade_name(r["id"]), r["name"])
		assert_eq(cfg.min_bp(r["id"]), int(r["min_bp"]))
	assert_eq(cfg.grade_name("legend"), "")
	assert_eq(cfg.min_bp("legend"), ShowConfig.UNKNOWN_MIN_BP)
	assert_eq(cfg.rate_scale, int(_economy["rate_scale"]))
	var tp: int = -1
	for r: Dictionary in _economy["rows"]:
		if int(r["tier"]) == EconomyConfig.START_TIER:
			tp = int(r["ticket_price_default"])
	assert_eq(cfg.ticket_price_default, tp, "ticket_price_default == economy rows[tier_1]")
	assert_eq(cfg.mvp_genres, Array(_artist["mvp_genres"], TYPE_STRING, "", null))
	assert_eq(cfg.satisfaction_source, _show["satisfaction_source"])
	assert_eq(cfg.scenario("nope"), {}, "없는 시나리오 {} (오류 없음)")
	var sc: Dictionary = cfg.scenario("local_top_baseline")
	assert_eq(sc["expected"]["revenue_hint"], int(_show["reference_scenarios"][1]["expected"]["revenue_hint"]))
	sc["expected"]["grade"] = "x"
	assert_ne(cfg.scenario("local_top_baseline")["expected"]["grade"], "x", "scenario() 는 깊은 복사")
	var ids: Array[String] = cfg.grade_ids()
	ids.clear()
	assert_false(cfg.grade_ids().is_empty(), "grade_ids() 는 복사본")
	assert_push_error_count(0, "조회는 오류 없음")
