extends GutTest
## SE-003 설정 리소스(spike_configs.tres) 유효성: 구성 A~D 가 티켓 표와 같고, 측정 절차 값이 티켓과 같으며,
## SpikeConfigSet.get_errors() 가 비어 있다. 잘못된 값은 오류로 잡힌다.

const SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"

var _s: SpikeConfigSet


func before_each() -> void:
	_s = load(SETTINGS_PATH) as SpikeConfigSet


func test_settings_resource_is_valid() -> void:
	assert_not_null(_s, "spike_configs.tres 로드")
	var errs: PackedStringArray = _s.get_errors()
	assert_eq(errs.size(), 0, "설정 오류 없음: %s" % ", ".join(errs))


func test_configs_match_ticket_table() -> void:
	# 티켓 SE-003 AC7 표: 구성 / 인스턴스 / 라이트 / 셰도우 라이트.
	var expected: Dictionary = {
		"A": [5000, 32, 0],
		"B": [5000, 32, 8],
		"C": [5000, 32, 32],
		"D": [10000, 32, 8],
	}
	assert_eq(_s.get_config_ids(), PackedStringArray(["A", "B", "C", "D"]), "구성 순서 A~D")
	for id: String in expected:
		var c: SpikeConfig = _s.get_config(id)
		assert_not_null(c, "구성 %s" % id)
		var row: Array = expected[id]
		assert_eq(c.instances, row[0], "%s 인스턴스" % id)
		assert_eq(c.lights, row[1], "%s 라이트" % id)
		assert_eq(c.shadow_lights, row[2], "%s 셰도우 라이트" % id)
		assert_false(c.note.is_empty(), "%s 비고" % id)
	assert_lte(_s.get_config("B").shadow_atlas_size, 2048, "B: 셰도우 아틀라스 ≤ 2048")


func test_measurement_procedure_matches_ticket() -> void:
	assert_eq(_s.default_config_id, "B", "기본 구성 = 관문 구성")
	assert_eq(_s.gate_config_id, "B", "관문 구성 B")
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
	var errs: PackedStringArray = bad.get_errors()
	assert_gte(errs.size(), 5, "오류 5개 이상: %s" % ", ".join(errs))
	assert_eq(_s.get_errors().size(), 0, "원본은 그대로 유효(duplicate 깊은 복사)")

	var dup: SpikeConfigSet = _s.duplicate(true) as SpikeConfigSet
	dup.configs.append(dup.get_config("A").duplicate())
	assert_true(", ".join(dup.get_errors()).contains("중복"), "id 중복 검출")
