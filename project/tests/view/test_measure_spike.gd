extends GutTest
## SE-013 AC5, AC6 (SE-003 AC6 의 헤드리스 부분 포함): 측정 진입점 measure_spike.tscn 을 짧게 돌려 JSON 이
## 필수 키 전부로 생성되는지, 측정기가 SpikeCrowd 를 타입으로 다루는지.
## 실제 fps 는 의미 없다(헤드리스 = 렌더 없음 → run_valid false, 관문 "무효"). GPU 측정은 사람 PC 에서 한다.

const ENTRY_SCENE: String = "res://tests/view/perf/measure_spike.tscn"
const MEASURE_SCRIPT: String = "res://tests/view/perf/measure_spike.gd"
const OUT_PATH: String = "user://perf_test/SE-013_test.json"
const MAX_WAIT_SEC: float = 20.0
## SE-003 AC6 필수 키 17개(티켓 문구 그대로, 구현 상수와 독립).
const SE003_KEYS: Array[String] = [
	"config", "instances", "lights", "shadow_lights", "avg_fps", "p1_low_fps", "avg_frame_ms",
	"max_frame_ms", "draw_calls", "primitives", "resolution", "vsync", "renderer", "gpu", "cpu",
	"godot_version", "commit",
]
const SE013_KEYS: Array[String] = ["gpu_timing_available", "gpu_timing_note", "crowd_cast_shadow"]

var _saved_max_fps: int = 0
var _saved_root_size: Vector2i = Vector2i.ZERO


func before_each() -> void:
	_saved_max_fps = Engine.max_fps
	_saved_root_size = get_tree().root.size


func after_each() -> void:
	Engine.max_fps = _saved_max_fps
	get_tree().root.size = _saved_root_size
	if FileAccess.file_exists(OUT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT_PATH.get_base_dir()))


## 진입점 씬을 1080p SubViewport 에 띄우고 단축 예열·측정으로 끝까지 돌린다. 끝나면 JSON(Dictionary) 또는 null.
func _run_entry(config_id: String) -> Variant:
	var vp: SubViewport = ViewTestUtil.make_viewport(self)
	autofree(vp)
	var m: SpikeMeasure = (load(ENTRY_SCENE) as PackedScene).instantiate() as SpikeMeasure
	assert_not_null(m, "진입점 루트는 SpikeMeasure")
	if m == null:
		return null
	m.config_id = config_id
	m.auto_quit = false
	vp.add_child(m)
	# _ready 에서 설정값·명령줄로 정한 길이를 첫 _process 전에 단축한다(헤드리스 동작 확인용).
	m.out_path = OUT_PATH
	m.warmup_sec = 0.0
	m.warmup_min_frames = 2
	m.measure_sec = 0.1
	var spike: SpikeCrowd = m.get_spike()
	assert_not_null(spike, "진입점이 스파이크 씬을 인스턴스화한다")
	if spike == null:
		return null
	assert_eq(spike.get_parent(), m, "스파이크는 측정기의 자식")
	assert_eq(spike.config.id, config_id, "@export config_id 로 구성 선택(명령줄 없이)")
	assert_true(spike.measure_mode, "측정기가 measure_mode 를 켠다")
	assert_false(spike.is_processing(), "스파이크 자체 진행은 멈추고 측정기가 advance() 를 호출한다")
	watch_signals(m)
	await wait_for_signal(m.finished, MAX_WAIT_SEC, "측정 종료 대기")
	assert_signal_emitted(m, "finished")
	assert_true(FileAccess.file_exists(OUT_PATH), "JSON 생성: %s" % OUT_PATH)
	return ViewTestUtil.read_json(OUT_PATH)


func test_entry_scene_writes_json_for_config_e() -> void:
	var data: Variant = await _run_entry("E")
	assert_true(data is Dictionary, "JSON 파싱")
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	for k: String in SE003_KEYS:
		assert_true(d.has(k), "SE-003 필수 키 %s" % k)
	for k: String in SE013_KEYS:
		assert_true(d.has(k), "SE-013 키 %s" % k)
	assert_eq(d["config"], "E")
	assert_eq(int(d["instances"]), 5000)
	assert_eq(int(d["instance_count_actual"]), 5000, "씬의 실제 인스턴스 수")
	assert_eq(int(d["shadow_lights_actual"]), 8, "씬의 실제 셰도우 라이트 수")
	assert_typeof(d["crowd_cast_shadow"], TYPE_BOOL)
	assert_false(bool(d["crowd_cast_shadow"]), "E: 군중 그림자 off")
	assert_typeof(d["gpu_timing_available"], TYPE_BOOL)
	assert_typeof(d["gpu_timing_note"], TYPE_STRING)
	assert_gt(int(d["sample_count"]), 0, "프레임 샘플 수집")
	assert_gt(float(d["avg_fps"]), 0.0)
	assert_lte(int(d["instance_mesh_tris"]), 800)
	assert_gt(float(d["avg_crowd_update_ms"]), 0.0, "측정기가 감싼 advance() CPU 시간 수집")
	assert_gte(int(d["stage_prop_count_actual"]), 4, "무대 프록시 수")
	assert_false(bool(d["run_valid"]), "헤드리스 측정은 무효로 표시")
	assert_eq(d["gate"]["verdict"], "무효")
	var issues: String = "\n".join(PackedStringArray(d["run_issues"]))
	assert_string_contains(issues, "헤드리스")
	assert_string_contains(issues, "예열 시간 단축")
	assert_string_contains(issues, "예열 프레임 부족")
	assert_string_contains(issues, "측정 시간 단축")


func test_entry_scene_config_b_keeps_crowd_shadows() -> void:
	var data: Variant = await _run_entry("B")
	assert_true(data is Dictionary, "JSON 파싱")
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	assert_eq(d["config"], "B")
	assert_true(bool(d["crowd_cast_shadow"]), "B: 비교용, 군중 그림자 on")
	assert_false(d["gate"]["applies"], "관문 구성은 E")
	assert_eq(d["gate"]["verdict"], "해당 없음")


func test_measurer_uses_typed_spike() -> void:
	var src: String = FileAccess.get_file_as_string(MEASURE_SCRIPT)
	assert_false(src.is_empty(), "measure_spike.gd 읽기")
	assert_false(src.contains("_spike.get(\""), "덕타이핑 .get(\"…\") 없음")
	assert_false(src.contains("_spike.call(\""), "덕타이핑 .call(\"…\") 없음")
	assert_true(src.contains("var _spike: SpikeCrowd"), "var _spike: SpikeCrowd 선언")
	assert_true(src.contains("setup(spike: SpikeCrowd"), "setup(spike: SpikeCrowd, …) 서명")
	# 역검증: 같은 검사가 덕타이핑 문자열을 실제로 잡는다.
	var fake: String = "var _spike: Node\nvar n: int = int(_spike.call(\"get_instance_count\"))"
	assert_true(fake.contains("_spike.call(\""), "대조군: 덕타이핑 문자열을 잡는다")
	assert_false(fake.contains("var _spike: SpikeCrowd"), "대조군: 타입 선언 없음을 잡는다")
