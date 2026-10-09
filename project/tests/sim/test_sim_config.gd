extends GutTest
## SE-001 AC1 — SimConfig 로더. docs/gdd/tick.md#틱 (교차 검증 C1~C6), #수용-기준.


func _raw() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(SimConfig.DEFAULT_PATH))


func test_loads_sim_json() -> void:
	var cfg: SimConfig = SimConfig.load()
	assert_not_null(cfg, "res://data/sim/sim.json 로드")
	if cfg == null:
		return
	assert_eq(cfg.ticks_per_second, 10, "ticks_per_second == 10")
	assert_eq(cfg.phases.size(), 4, "구간 4개")
	var ids: Array = []
	for ph: Dictionary in cfg.phases:
		ids.append(ph["id"])
		for key: String in ["ticks", "pausable", "speeds", "default_speed", "enter_speed_mode"]:
			assert_true(ph.has(key), "구간 %s 에 %s" % [ph["id"], key])
		assert_typeof(ph["ticks"], TYPE_INT, "ticks 는 int")
		assert_typeof(ph["default_speed"], TYPE_INT, "default_speed 는 int")
		for s: Variant in ph["speeds"]:
			assert_typeof(s, TYPE_INT, "speeds 원소는 int")
	assert_eq(ids, ["day", "evening", "show", "close"], "구간 순서")
	assert_eq(cfg.day_ticks, 3300, "day_ticks == 3300")
	assert_eq(cfg.phase_start("day"), 0)
	assert_eq(cfg.phase_start("evening"), 1800)
	assert_eq(cfg.phase_start("show"), 2400)
	assert_eq(cfg.phase_start("close"), 3300)
	assert_eq(cfg.phase_index("show"), 2)
	assert_eq(cfg.phase_index("night"), -1, "모르는 id")
	assert_eq(cfg.phases[0]["speeds"], [0, 1, 2, 3])
	assert_eq(cfg.phases[1]["speeds"], [0, 1])
	assert_eq(cfg.phases[2]["speeds"], [1])
	assert_eq(cfg.phases[3]["speeds"], [0])
	assert_eq(cfg.max_ticks_per_step, 30)
	assert_eq(cfg.snapshot_schema_version, 1)
	assert_eq(cfg.rng_streams, ["audience", "artist", "events", "economy", "world"] as Array[String])
	assert_eq(cfg.system_order[0], "build")
	assert_eq(cfg.system_order[cfg.system_order.size() - 1], "reputation")


func test_rejects_invalid_config() -> void:
	assert_not_null(SimConfig.from_dict(_raw()), "원본 사본은 통과")

	var cases: Dictionary = {}
	var d: Dictionary

	d = _raw()   # C1 순서 바뀜
	var tmp: Variant = d["phases"][1]
	d["phases"][1] = d["phases"][2]
	d["phases"][2] = tmp
	cases["C1 순서"] = d

	d = _raw()   # C1 이름 바뀜
	d["phases"][0]["id"] = "morning"
	cases["C1 이름"] = d

	d = _raw()   # C2 중간 구간 ticks 0
	d["phases"][1]["ticks"] = 0
	cases["C2 중간 0"] = d

	d = _raw()   # C2 마지막 구간 ticks > 0
	d["phases"][3]["ticks"] = 5
	cases["C2 마지막 양수"] = d

	d = _raw()   # C3 오름차순 아님
	d["phases"][0]["speeds"] = [0, 2, 1, 3]
	cases["C3 순서"] = d

	d = _raw()   # C3 중복
	d["phases"][1]["speeds"] = [0, 1, 1]
	cases["C3 중복"] = d

	d = _raw()   # C4
	d["phases"][2]["default_speed"] = 2
	cases["C4"] = d

	d = _raw()   # C5
	d["phases"][2]["pausable"] = true
	cases["C5"] = d

	d = _raw()   # C6 rng_streams
	d["rng_streams"].append("audience")
	cases["C6 rng_streams"] = d

	d = _raw()   # C6 system_order
	d["system_order"].append("build")
	cases["C6 system_order"] = d

	for label: String in cases:
		assert_null(SimConfig.from_dict(cases[label]), "%s 위반 → null" % label)
	assert_push_error_count(cases.size(), "위반마다 push_error 1회")
