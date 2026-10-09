extends GutTest
## SE-013 AC5, AC6 (SE-003 AC6 의 헤드리스 부분 포함): 측정 진입점 measure_spike.tscn 을 짧게 돌려 JSON 이
## 필수 키 전부로 생성되는지, 측정기가 SpikeCrowd 를 타입으로 다루는지.
## 실제 fps 는 의미 없다(헤드리스 = 렌더 없음 → run_valid false, 관문 "무효"). GPU 측정은 사람 PC 에서 한다.
## SE-004 AC7: material_id(--material=) → JSON material 키, 기본 출력 파일명, 없는 시안 거부.
## SE-018 AC6: 기본 시안 b, 기본 출력 파일명은 항상 SE-013_<config>_<material>.json, "default" 는 없는 시안.

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
## _run_entry 가 단축 전에 읽은 기본 출력 경로(SE-004 파일명 검사용).
var _default_out_path: String = ""
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
func _run_entry(config_id: String, material_id: String = "") -> Variant:
	var vp: SubViewport = ViewTestUtil.make_viewport(self)
	autofree(vp)
	var m: SpikeMeasure = (load(ENTRY_SCENE) as PackedScene).instantiate() as SpikeMeasure
	assert_not_null(m, "진입점 루트는 SpikeMeasure")
	if m == null:
		return null
	m.config_id = config_id
	m.material_id = material_id
	m.auto_quit = false
	vp.add_child(m)
	_default_out_path = m.out_path
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


# --- SE-004 AC7 -------------------------------------------------------------

func test_material_arg_in_json_and_bad_id_rejected() -> void:
	var data: Variant = await _run_entry("E", "c")
	assert_true(data is Dictionary, "JSON 파싱")
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	assert_eq(d["material"], "c", "JSON material == c")
	assert_eq(d["ticket"], "SE-013", "ticket 값은 SE-013 그대로")
	assert_eq(d["config"], "E")
	assert_false(bool(d["crowd_cast_shadow"]), "E: 군중 그림자 off")
	for k: String in SE003_KEYS:
		assert_true(d.has(k), "SE-003 필수 키 %s" % k)
	for k: String in SE013_KEYS:
		assert_true(d.has(k), "SE-013 키 %s" % k)
	assert_eq(int(d["instance_count_actual"]), 5000, "시안을 씌워도 인스턴스 5000")
	assert_eq(_default_out_path.get_file(), "SE-013_E_c.json", "기본 출력 파일명 SE-013_<config>_<material>.json")
	assert_eq(SpikeMeasure.default_out_path("B", "a").get_file(), "SE-013_B_a.json")

	# 없는 시안(SE-018: 예전 "default" 도 없는 시안): _spawn_spike() 가 false, push_error 1건, 스파이크 자식 없음
	# (auto_quit 이면 종료 코드 2).
	var expected_errors: int = 0
	for bad_id: String in ["zzz", "default"]:
		var bad: SpikeMeasure = (load(ENTRY_SCENE) as PackedScene).instantiate() as SpikeMeasure
		autofree(bad)
		bad.auto_quit = false
		bad.config_id = "E"
		bad.material_id = bad_id
		assert_false(bad._spawn_spike(), "%s: _spawn_spike() == false" % bad_id)
		expected_errors += 1
		assert_push_error_count(expected_errors, "%s: push_error 1건(누적 %d)" % [bad_id, expected_errors])
		assert_null(bad.get_spike(), "%s: 스파이크 없음" % bad_id)
		assert_eq(bad.get_child_count(), 0, "%s: 스파이크 자식이 생기지 않는다" % bad_id)
	assert_eq(SpikeMeasure.EXIT_BAD_SETUP, 2, "종료 코드 2(--config 오류와 같은 경로)")


## SE-018 AC6: --material 없이 돌리면 시안 b, 기본 파일명 SE-013_E_b.json. plain 도 접미사를 붙인다(특례 없음).
func test_default_material_is_b_and_filename_has_suffix() -> void:
	var data: Variant = await _run_entry("E")
	assert_true(data is Dictionary, "JSON 파싱")
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	assert_eq(d["material"], "b", "--material 없으면 b")
	assert_eq(d["material"], ShaderVariants.DEFAULT_ID, "기본값 출처 = ShaderVariants.DEFAULT_ID")
	assert_eq(_default_out_path.get_file(), "SE-013_E_b.json", "--material 없으면 SE-013_E_b.json")
	assert_eq(SpikeMeasure.default_out_path("E", "b"), "user://perf/SE-013_E_b.json")
	assert_eq(SpikeMeasure.default_out_path("E", "plain"), "user://perf/SE-013_E_plain.json", "plain 도 _plain 접미사")
	assert_false(bool(d["crowd_cast_shadow"]), "E: 군중 그림자 off")
	assert_eq(int(d["instance_count_actual"]), 5000, "인스턴스 5000")
	for k: String in SE003_KEYS:
		assert_true(d.has(k), "SE-003 필수 키 %s" % k)
	for k: String in SE013_KEYS:
		assert_true(d.has(k), "SE-013 키 %s" % k)
	# default_out_path 안에 DEFAULT_ID 특례 분기가 없다(소스 텍스트 검사).
	var src: String = (load(MEASURE_SCRIPT) as GDScript).source_code
	var body_start: int = src.find("static func default_out_path(")
	assert_gt(body_start, -1, "default_out_path 정의")
	var body_end: int = src.find("\nstatic func ", body_start + 1)
	if body_end < 0:
		body_end = src.find("\nfunc ", body_start + 1)
	var body: String = src.substr(body_start, body_end - body_start if body_end > 0 else -1)
	assert_false(body.contains("== ShaderVariants.DEFAULT_ID"), "default_out_path 에 DEFAULT_ID 특례 분기 0건")
	assert_false(body.contains("DEFAULT_OUT_PATTERN %"), "구 SE-013 파일명 패턴을 쓰지 않는다")
	assert_eq(d["ticket"], "SE-013")


# --- SE-021 AC6 -------------------------------------------------------------

## --material=ss: JSON material == ss, 인스턴스 5000, 군중 그림자 off. 스파이크 직속에 포스트 패스 노드 정확히 1개,
## 군중·무대 프록시는 toon_ss(next_pass 없음 → 군중을 두 번 그리지 않는다). primitives 비율은 GPU 실행에서만 의미가
## 있어 results/SE-021.md 표(Xvfb 무효 측정)로 확인한다(헤드리스는 더미 렌더러).
func test_ss_material_json() -> void:
	var data: Variant = await _run_entry("E", "ss")
	assert_true(data is Dictionary, "JSON 파싱")
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	assert_eq(d["material"], "ss", "JSON material == ss")
	assert_eq(int(d["instance_count_actual"]), 5000, "인스턴스 5000")
	assert_false(bool(d["crowd_cast_shadow"]), "E: 군중 그림자 off")
	for k: String in SE003_KEYS:
		assert_true(d.has(k), "SE-003 필수 키 %s" % k)
	assert_eq(_default_out_path.get_file(), "SE-013_E_ss.json", "기본 출력 파일명")


func test_ss_spike_has_one_post_pass_and_no_next_pass() -> void:
	var vp: SubViewport = ViewTestUtil.make_viewport(self)
	autofree(vp)
	var spike: SpikeCrowd = (load("res://view/perf/spike_crowd.tscn") as PackedScene).instantiate() as SpikeCrowd
	spike.config_id = "E"
	spike.material_id = "ss"
	vp.add_child(spike)
	var toon_ss: Material = load("res://view/shaders/params/toon_ss.tres")
	assert_eq(spike.crowd.material_override, toon_ss, "군중 toon_ss")
	assert_null(spike.crowd.material_override.next_pass, "next_pass 없음")
	for mi: MeshInstance3D in spike.get_stage_prop_nodes():
		assert_eq(mi.material_override, toon_ss, "%s toon_ss" % mi.name)
	var passes: Array[Node] = spike.find_children("*", "MeshInstance3D", true, false).filter(
		func(n: Node) -> bool: return n.is_in_group(ShaderVariants.POST_PASS_GROUP))
	assert_eq(passes.size(), 1, "포스트 패스 노드 정확히 1개")
	assert_eq(ShaderVariants.get_post_pass(spike), passes[0] if passes.size() == 1 else null, "스파이크 직속")


# --- SE-024 AC4 (SE-018 후속 A) ----------------------------------------------

## 로드 실패를 만드는 시안 경로 패턴(존재하지 않는 폴더). 측정기가 스파이크에 그대로 넘긴다.
const MISSING_MATERIAL_PATTERN: String = "res://tests/view/missing_params/toon_%s.tres"


## 측정기를 SubViewport 에 띄운다(_ready 가 _spawn_spike 를 부른다). 끝까지 돌리지 않는다.
func _add_measurer(material_id: String, path_pattern: String) -> SpikeMeasure:
	var vp: SubViewport = ViewTestUtil.make_viewport(self)
	autofree(vp)
	var m: SpikeMeasure = (load(ENTRY_SCENE) as PackedScene).instantiate() as SpikeMeasure
	m.config_id = "E"
	m.material_id = material_id
	m.auto_quit = false
	m.material_path_pattern = path_pattern
	vp.add_child(m)
	return m


## user:// 파일의 수정 시각(없으면 -1). JSON 이 새로 쓰이지 않았는지 비교용.
static func _mtime(path: String) -> int:
	return FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else -1


## material_id = "b" 인데 toon_b.tres 로드가 실패하면: _spawn_spike() == false, push_error ≥ 1, 종료 코드 2,
## 스파이크 자식 없음, 측정 진행 없음, JSON 생성 0("라벨은 b, 실제 룩은 plain" 인 결과를 내지 않는다).
func test_material_load_failure_is_bad_setup_without_json() -> void:
	var default_json: String = SpikeMeasure.default_out_path("E", "b")
	var plain_json: String = SpikeMeasure.default_out_path("E", ShaderVariants.PLAIN_ID)
	var before: Array[int] = [_mtime(default_json), _mtime(plain_json), _mtime(OUT_PATH)]
	var m: SpikeMeasure = _add_measurer("b", MISSING_MATERIAL_PATTERN)
	# _ready 의 첫 시도: 로드 실패 → 스파이크 경로 2건 + 측정기 1건.
	assert_push_error("시안 'b' 머티리얼 로드 실패: %s" % (MISSING_MATERIAL_PATTERN % "b"), "ShaderVariants 로드 실패(경로 포함)")
	assert_push_error("SpikeCrowd: 시안 'b' 머티리얼을 적용할 수 없어 plain 로 떨어진다", "스파이크 폴백")
	assert_push_error("SpikeMeasure: 시안 'b' 머티리얼 로드 실패 (스파이크 실제 시안 plain)", "측정기 거부")
	assert_eq(m.exit_code, SpikeMeasure.EXIT_BAD_SETUP, "종료 코드 EXIT_BAD_SETUP")
	assert_eq(SpikeMeasure.EXIT_BAD_SETUP, 2, "EXIT_BAD_SETUP == 2")
	assert_null(m.get_spike(), "스파이크 연결 없음")
	assert_eq(m.get_child_count(), 0, "스파이크 자식을 떼어 냈다")
	assert_false(m.is_processing(), "측정 진행 없음(_process off)")
	assert_eq(m.out_path, "", "setup 이 불리지 않아 출력 경로도 정해지지 않았다")
	# 직접 다시 불러도 false(같은 경로를 한 번 더 탄다).
	assert_false(m._spawn_spike(), "_spawn_spike() == false")
	assert_push_error_count(6, "push_error 6건(≥ 1 충족: 두 번 시도 × 3건)")
	assert_eq(m.exit_code, SpikeMeasure.EXIT_BAD_SETUP, "두 번째도 종료 코드 2")
	assert_eq(m.get_child_count(), 0, "두 번째도 자식 없음")
	# 측정 시간만큼 프레임을 돌려도 JSON 은 생기지 않는다(finished 신호도 없음).
	watch_signals(m)
	await wait_physics_frames(5)
	assert_signal_not_emitted(m, "finished", "finished 신호 없음")
	var after: Array[int] = [_mtime(default_json), _mtime(plain_json), _mtime(OUT_PATH)]
	assert_eq(after, before, "JSON 생성 0(기본 b·plain 파일명, 테스트 경로 모두 그대로)")


## 대조군: plain 은 로드 대상이 아니라 같은 잘못된 경로 패턴이어도 정상 진행(측정기 검사가 plain 을 거부하지 않는다),
## 기본 경로 패턴의 b 도 정상(오류 0, 종료 코드 기록 없음).
func test_material_load_check_control() -> void:
	var plain: SpikeMeasure = _add_measurer(ShaderVariants.PLAIN_ID, MISSING_MATERIAL_PATTERN)
	assert_not_null(plain.get_spike(), "plain: 스파이크 연결")
	assert_eq(plain.get_spike().get_material_id(), ShaderVariants.PLAIN_ID, "plain: 시안 plain")
	assert_eq(plain.exit_code, -1, "plain: _quit 호출 없음")
	plain.set_process(false)
	var b: SpikeMeasure = _add_measurer("b", ShaderVariants.MATERIAL_PATH_PATTERN)
	assert_not_null(b.get_spike(), "b: 스파이크 연결")
	assert_eq(b.get_spike().get_material_id(), "b", "b: 시안 b")
	assert_eq(b.get_spike().crowd.material_override, load("res://view/shaders/params/toon_b.tres"), "b: toon_b.tres")
	assert_eq(b.exit_code, -1, "b: _quit 호출 없음")
	b.set_process(false)
	assert_push_error_count(0, "대조군: push_error 0")
