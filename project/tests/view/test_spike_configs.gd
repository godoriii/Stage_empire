extends GutTest
## SE-003/SE-013 설정 리소스(spike_configs.tres) 유효성: 구성 A~E 가 티켓 표와 같고, 측정 절차 값이 티켓과 같으며,
## SpikeConfigSet.get_errors() 가 비어 있다. 잘못된 값은 오류로 잡힌다.
## SE-013 AC3: 구성 E = B 와 같되 crowd_shadows 만 false, 관문 구성 E.

const SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"

var _s: SpikeConfigSet


func before_each() -> void:
	_s = load(SETTINGS_PATH) as SpikeConfigSet


func test_settings_resource_is_valid() -> void:
	assert_not_null(_s, "spike_configs.tres 로드")
	var errs: PackedStringArray = _s.get_errors()
	assert_eq(errs.size(), 0, "설정 오류 없음: %s" % ", ".join(errs))


func test_configs_match_ticket_table() -> void:
	# 티켓 SE-003 AC7 표 + SE-013 구성 E: 구성 / 인스턴스 / 라이트 / 셰도우 라이트 / 아틀라스 / 군중 그림자.
	var expected: Dictionary = {
		"A": [5000, 32, 0, 2048, true],
		"B": [5000, 32, 8, 2048, true],
		"C": [5000, 32, 32, 2048, true],
		"D": [10000, 32, 8, 2048, true],
		"E": [5000, 32, 8, 2048, false],
	}
	assert_eq(_s.get_config_ids(), PackedStringArray(["A", "B", "C", "D", "E"]), "구성 순서 A~E")
	for id: String in expected:
		var c: SpikeConfig = _s.get_config(id)
		assert_not_null(c, "구성 %s" % id)
		if c == null:
			continue
		var row: Array = expected[id]
		assert_eq(c.instances, row[0], "%s 인스턴스" % id)
		assert_eq(c.lights, row[1], "%s 라이트" % id)
		assert_eq(c.shadow_lights, row[2], "%s 셰도우 라이트" % id)
		assert_eq(c.shadow_atlas_size, row[3], "%s 아틀라스" % id)
		assert_eq(c.crowd_shadows, row[4], "%s 군중 그림자" % id)
		assert_false(c.note.is_empty(), "%s 비고" % id)
	assert_lte(_s.get_config("E").shadow_atlas_size, 2048, "E: 셰도우 아틀라스 ≤ 2048")
	assert_string_contains(_s.get_config("B").note, "비교용")


func test_config_e_equals_b_except_crowd_shadows() -> void:
	var b: SpikeConfig = _s.get_config("B")
	var e: SpikeConfig = _s.get_config("E")
	assert_not_null(b)
	assert_not_null(e)
	if b == null or e == null:
		return
	assert_eq(e.instances, b.instances, "instances 같음")
	assert_eq(e.lights, b.lights, "lights 같음")
	assert_eq(e.shadow_lights, b.shadow_lights, "shadow_lights 같음")
	assert_eq(e.shadow_atlas_size, b.shadow_atlas_size, "shadow_atlas_size 같음")
	assert_true(b.crowd_shadows, "B 군중 그림자 on")
	assert_false(e.crowd_shadows, "E 군중 그림자 off")
	# 위에 나열하지 않은 속성이 새로 생겨도 id·note·crowd_shadows 외에는 같아야 한다.
	var skip: PackedStringArray = PackedStringArray(["id", "note", "crowd_shadows"])
	for prop: Dictionary in e.get_property_list():
		var pname: String = prop["name"]
		if (int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0 or skip.has(pname):
			continue
		assert_eq(e.get(pname), b.get(pname), "E.%s == B.%s" % [pname, pname])
	# 새 필드 기본값은 true(A~D 는 .tres 에 적지 않아도 on).
	assert_true(SpikeConfig.new().crowd_shadows, "crowd_shadows 기본값 true")


func test_gate_config_is_e() -> void:
	assert_eq(_s.gate_config_id, "E", "관문 구성 E")
	assert_eq(_s.gate_min_avg_fps, 60.0, "관문 평균 60 fps 유지")
	assert_eq(_s.get_errors().size(), 0, "get_errors() 빈 배열")


func test_measurement_procedure_matches_ticket() -> void:
	assert_eq(_s.default_config_id, _s.gate_config_id, "기본 구성 = 관문 구성")
	assert_eq(_s.gate_config_id, "E", "관문 구성 E (SE-013)")
	assert_eq(_s.gate_min_avg_fps, 60.0, "관문 평균 60 fps (PRD)")
	assert_eq(_s.warmup_sec, 10.0, "예열 10초")
	assert_gt(_s.warmup_min_frames, 0, "예열 최소 프레임")
	assert_eq(_s.measure_sec, 30.0, "측정 30초")
	assert_eq(_s.resolution, Vector2i(1920, 1080), "1080p")
	assert_eq(_s.interpolation_tick_hz, 10.0, "고정 틱 10 tick/s 와 같은 보간 경로")


func test_invalid_values_are_reported() -> void:
	var bad: SpikeConfigSet = _s.duplicate(true) as SpikeConfigSet
	bad.get_config("A").shadow_lights = 40
	bad.get_config("C").shadow_atlas_size = 3000
	bad.default_config_id = "Z"
	bad.crowd_fill_ratio = 1.2
	bad.wander_speed_min = 0.0
	bad.stage_prop_count = 0
	bad.stage_prop_size_m = Vector3(1.0, bad.light_height_m, 1.0)
	bad.stage_prop_span_ratio = 1.5
	bad.stage_prop_offset_ratio = -1.0
	var errs: PackedStringArray = bad.get_errors()
	assert_gte(errs.size(), 9, "오류 9개 이상: %s" % ", ".join(errs))
	var joined: String = ", ".join(errs)
	for needle: String in ["stage_prop_count", "라이트보다 낮아야", "stage_prop_span_ratio", "stage_prop_offset_ratio"]:
		assert_string_contains(joined, needle)
	assert_eq(_s.get_errors().size(), 0, "원본은 그대로 유효(duplicate 깊은 복사)")

	var dup: SpikeConfigSet = _s.duplicate(true) as SpikeConfigSet
	dup.configs.append(dup.get_config("A").duplicate())
	assert_true(", ".join(dup.get_errors()).contains("중복"), "id 중복 검출")
