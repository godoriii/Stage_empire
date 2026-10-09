extends GutTest
## SE-012 EC1 — EconomyConfig 로더·교차 검사 K1~K5 (docs/gdd/economy.md#설정-로드와-공개-api).


func _raw() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(EconomyConfig.DEFAULT_PATH))


func test_config_loads_and_cross_checks() -> void:
	var cfg: EconomyConfig = EconomyConfig.load()
	assert_not_null(cfg, "res://data/economy/economy.json 로드")
	if cfg == null:
		return
	var raw: Dictionary = _raw()
	# 읽기 전용 필드 = JSON 값(정수로 정규화).
	assert_eq(cfg.starting_cash, int(raw["starting_cash"]))
	assert_eq(cfg.bailout_count, int(raw["bailout_count"]))
	assert_eq(cfg.rate_scale, int(raw["rate_scale"]))
	assert_eq(cfg.demolish_refund_rate_bp, int(raw["demolish_refund_rate_bp"]))
	assert_eq(cfg.charge_reasons, raw["charge_reasons"])
	assert_eq(cfg.reference_scenarios.size(), (raw["reference_scenarios"] as Array).size())
	assert_typeof(cfg.reference_scenarios[0]["expected"]["net"], TYPE_INT, "기대값은 int 로 정규화")
	# 리터럴 한 번 더(JSON 과 테스트가 함께 틀리는 경우를 잡는다).
	assert_eq([cfg.starting_cash, cfg.bailout_count, cfg.rate_scale], [5000, 2, 10000])

	# row(1) == JSON 행(값은 int).
	var want_row: Dictionary = {}
	for r: Dictionary in raw["rows"]:
		if int(r["tier"]) == 1:
			for k: String in r:
				want_row[k] = r[k] if r[k] is String else int(r[k])
	var row1: Dictionary = cfg.row(1)
	assert_eq(row1, want_row, "row(1) == JSON tier_1 행")
	for k: String in row1:
		if k != "id":
			assert_typeof(row1[k], TYPE_INT, "row(1).%s 는 int" % k)
	assert_eq(cfg.guarantee("local"), int(raw["guarantee_by_grade"]["local"]), "guarantee(local) == JSON")
	assert_eq(cfg.guarantee("local"), 400, "리터럴 400")

	# 정상 설정에서 모르는 등급·티어.
	assert_eq(cfg.guarantee("midlevel"), -1, "v0 표에 없는 등급")
	assert_eq(cfg.guarantee("nope"), -1, "오타")
	assert_eq(cfg.row(9), {}, "없는 티어")
	assert_push_error_count(3, "guarantee 2회 + row 1회")

	# K1~K4 를 하나씩 깬 사본 → null.
	assert_not_null(EconomyConfig.from_dict(_raw()), "원본 사본은 통과")
	var cases: Dictionary = {}
	var d: Dictionary = _raw()
	d["rows"][0]["id"] = "tier_2"
	cases["K1 id != tier_<tier>"] = d
	d = _raw()
	(d["rows"] as Array).append((d["rows"][0] as Dictionary).duplicate(true))
	cases["K1 tier 중복"] = d
	d = _raw()
	d["rows"][0]["id"] = "tier_2"
	d["rows"][0]["tier"] = 2
	cases["K1 tier 1 행 없음"] = d
	d = _raw()
	d["rows"][0]["ticket_price_min"] = d["rows"][0]["ticket_price_default"] + 1
	cases["K2 min > default"] = d
	d = _raw()
	d["rows"][0]["ticket_price_max"] = d["rows"][0]["ticket_price_default"] - 1
	cases["K2 default > max"] = d
	d = _raw()
	d["version"] = 2
	cases["K3 version"] = d
	d = _raw()
	d["rate_scale"] = 1000
	cases["K3 rate_scale"] = d
	d = _raw()
	d["reference_scenarios"][0]["guarantee_grade"] = "midlevel"
	cases["K4 guarantee_grade midlevel"] = d
	d = _raw()
	d["charge_reasons"]["build"] = "operating"
	cases["K5 build = operating (ledger 키 아님)"] = d
	for label: String in cases:
		assert_null(EconomyConfig.from_dict(cases[label]), label + " → null")
	assert_push_error_count(3 + cases.size(), "사본마다 push_error 1회")

	# K5 는 operating 만 제한한다: guarantee = capital 사본은 로드 성공(추가 push_error 0).
	d = _raw()
	d["charge_reasons"]["guarantee"] = "capital"
	var cap: EconomyConfig = EconomyConfig.from_dict(d)
	assert_not_null(cap, "K5 guarantee = capital → 로드 성공")
	if cap != null:
		assert_eq(cap.charge_reasons["guarantee"], "capital")
	assert_push_error_count(3 + cases.size(), "capital 사본은 push_error 없음")
