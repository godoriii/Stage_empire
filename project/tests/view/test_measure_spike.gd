extends GutTest
## SE-003 AC6 의 헤드리스 부분: 측정기(SpikeMeasure)를 짧게 돌려 JSON 이 필수 키 전부로 생성되는지.
## 실제 fps 는 의미 없다(헤드리스 = 렌더 없음 → run_valid false, 관문 "무효"). GPU 측정은 사람 PC 에서 한다.

const SPIKE_SCENE: String = "res://view/perf/spike_crowd.tscn"
const OUT_PATH: String = "user://perf_test/SE-003_test.json"
const MAX_WAIT_SEC: float = 20.0

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


func test_short_measure_writes_json_with_required_keys() -> void:
	var vp: SubViewport = ViewTestUtil.make_viewport(self)
	autofree(vp)
	var spike: SpikeCrowd = (load(SPIKE_SCENE) as PackedScene).instantiate() as SpikeCrowd
	vp.add_child(spike)
	var m: SpikeMeasure = SpikeMeasure.new()
	m.setup(spike, spike.settings, spike.config)
	m.auto_quit = false
	m.out_path = OUT_PATH
	m.warmup_sec = 0.0
	m.warmup_min_frames = 2
	m.measure_sec = 0.1
	watch_signals(m)
	spike.add_child(m)
	await wait_for_signal(m.finished, MAX_WAIT_SEC, "측정 종료 대기")
	assert_signal_emitted(m, "finished")
	assert_true(FileAccess.file_exists(OUT_PATH), "JSON 생성: %s" % OUT_PATH)
	var data: Variant = ViewTestUtil.read_json(OUT_PATH)
	assert_true(data is Dictionary, "JSON 파싱")
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	for k: String in SpikeMeasure.REQUIRED_KEYS:
		assert_true(d.has(k), "필수 키 %s" % k)
	assert_eq(d["config"], "B")
	assert_eq(int(d["instances"]), 5000)
	assert_eq(int(d["instance_count_actual"]), 5000, "씬의 실제 인스턴스 수")
	assert_eq(int(d["shadow_lights_actual"]), 8, "씬의 실제 셰도우 라이트 수")
	assert_gt(int(d["sample_count"]), 0, "프레임 샘플 수집")
	assert_gt(float(d["avg_fps"]), 0.0)
	assert_lte(int(d["instance_mesh_tris"]), 800)
	assert_gt(float(d["avg_crowd_update_ms"]), 0.0, "군중 갱신 CPU 시간 수집")
	assert_false(bool(d["run_valid"]), "헤드리스 측정은 무효로 표시")
	assert_eq(d["gate"]["verdict"], "무효")
