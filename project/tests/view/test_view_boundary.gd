extends GutTest
## SE-002 AC8(키 리터럴), AC9(경계), AC10(스크린샷 파일): 소스 정적 검사.
## SE-013 AC4: view/ui 가 tests/ 를 참조하지 않는다(측정 진입점은 tests 쪽에서 view 를 인스턴스화).
## SE-004 AC11(셰이더·플레이스홀더가 assets/·tests/ 를 참조하지 않는다), AC12(시안 스크린샷 4장 1080p).
## SE-018 AC3(기본 시안 id 의 출처는 ShaderVariants.DEFAULT_ID 한 곳).

const SCREENSHOT_PATH: String = "res://tests/view/screenshots/SE-002/grid_yaw45_zoom2.png"
const SPIKE_SCRIPT: String = "res://view/perf/spike_crowd.gd"
## 정규식 문자열. 리터럴 그대로 매치된다(특수 문자 없음).
const TESTS_REF_PATTERN: String = "res://tests/"


func _gd_sources() -> PackedStringArray:
	return ViewTestUtil.list_sources(ViewTestUtil.SOURCE_ROOTS, "gd")


func test_sources_found() -> void:
	var srcs: PackedStringArray = _gd_sources()
	assert_gt(srcs.size(), 0, "view/ui 스크립트를 찾는다")
	assert_true(srcs.has("res://view/input/input_actions.gd"), "input_actions.gd 존재")


func test_no_raw_key_checks_outside_input_actions() -> void:
	var pattern: String = "\\b(KEY|MOUSE_BUTTON|JOY_BUTTON|JOY_AXIS)_[A-Z0-9_]+"
	var hits: PackedStringArray = ViewTestUtil.grep(_gd_sources(), pattern, "/input/input_actions.gd")
	assert_eq(hits.size(), 0, "키/버튼 상수는 input_actions.gd 에만: %s" % ", ".join(hits))
	# 반대로 input_actions.gd 에는 기본 바인딩이 있어야 한다(검사 자체가 동작하는지 확인).
	var own: PackedStringArray = ViewTestUtil.grep(PackedStringArray(["res://view/input/input_actions.gd"]), pattern)
	assert_gt(own.size(), 0, "input_actions.gd 에서는 정규식이 걸린다")
	# 원시 입력 폴링 금지: Input.is_key_pressed / is_mouse_button_pressed / is_joy_button_pressed.
	var polls: PackedStringArray = ViewTestUtil.grep(_gd_sources(), "Input\\.is_(key|physical_key|mouse_button|joy_button)_pressed")
	assert_eq(polls.size(), 0, "원시 키 폴링 없음: %s" % ", ".join(polls))


func test_view_does_not_touch_sim_or_data() -> void:
	var srcs: PackedStringArray = _gd_sources()
	var sim_core: PackedStringArray = ViewTestUtil.grep(srcs, "(load|preload)\\(\\s*\"res://(sim|core)/")
	assert_eq(sim_core.size(), 0, "view/ui 가 sim/core 스크립트를 로드하지 않는다(현재 비어 있음): %s" % ", ".join(sim_core))
	var writes: PackedStringArray = ViewTestUtil.grep(srcs, "FileAccess\\.(WRITE|READ_WRITE|WRITE_READ)")
	assert_eq(writes.size(), 0, "view/ui 에 FileAccess 쓰기 모드 없음: %s" % ", ".join(writes))
	var dir_ops: PackedStringArray = ViewTestUtil.grep(srcs, "DirAccess\\.(remove|rename|make_dir|copy)")
	assert_eq(dir_ops.size(), 0, "view/ui 에 파일 시스템 변경 없음: %s" % ", ".join(dir_ops))
	# 씬/리소스가 sim/core 를 참조하지 않는다.
	var scene_files: PackedStringArray = ViewTestUtil.list_sources(ViewTestUtil.SOURCE_ROOTS, "tscn")
	scene_files.append_array(ViewTestUtil.list_sources(ViewTestUtil.SOURCE_ROOTS, "tres"))
	var scene_refs: PackedStringArray = ViewTestUtil.grep(scene_files, "res://(sim|core)/")
	assert_eq(scene_refs.size(), 0, "씬/리소스가 sim/core 참조 없음: %s" % ", ".join(scene_refs))
	# 이 티켓은 이벤트를 발행하지 않는다(표시 전용).
	var emits: PackedStringArray = ViewTestUtil.grep(srcs, "EventBus|event_bus")
	assert_eq(emits.size(), 0, "SE-002 는 이벤트 버스 사용 없음: %s" % ", ".join(emits))


func test_view_does_not_reference_tests() -> void:
	var files: PackedStringArray = _gd_sources()
	files.append_array(ViewTestUtil.list_sources(ViewTestUtil.SOURCE_ROOTS, "tscn"))
	files.append_array(ViewTestUtil.list_sources(ViewTestUtil.SOURCE_ROOTS, "tres"))
	assert_true(files.has(SPIKE_SCRIPT), "검사 대상에 spike_crowd.gd 포함")
	assert_true(files.has("res://view/perf/spike_crowd.tscn"), "검사 대상에 .tscn 포함")
	assert_true(files.has("res://view/perf/spike_configs.tres"), "검사 대상에 .tres 포함")
	var hits: PackedStringArray = ViewTestUtil.grep(files, TESTS_REF_PATTERN)
	assert_eq(hits.size(), 0, "view/ui 의 .gd/.tscn/.tres 에 res://tests/ 0건: %s" % ", ".join(hits))
	# spike_crowd.gd 에 옛 측정 진입(--measure 인자, _start_measure)이 남아 있지 않다.
	var spike_src: PackedStringArray = PackedStringArray([SPIKE_SCRIPT])
	var old_entry: PackedStringArray = ViewTestUtil.grep(spike_src, "--measure|_start_measure")
	assert_eq(old_entry.size(), 0, "spike_crowd.gd 에 --measure·_start_measure 없음: %s" % ", ".join(old_entry))
	# 역검증: 같은 grep 이 가짜 줄 배열에서는 정확히 1건을 잡는다.
	var fake: PackedStringArray = PackedStringArray([
		"const OK_PATH: String = \"res://view/perf/spike_crowd.tscn\"",
		"const BAD_PATH: String = \"res://tests/x\"",
		"# tests/view/perf 는 res:// 접두어 없이 적으면 걸리지 않는다",
	])
	assert_eq(ViewTestUtil.grep_lines(fake, TESTS_REF_PATTERN).size(), 1, "대조군: res://tests/x 1건")
	assert_eq(ViewTestUtil.grep_lines(PackedStringArray(["func _start_measure() -> void:"]), "--measure|_start_measure").size(), 1,
		"대조군: _start_measure 1건")


func test_screenshot_exists_1080p() -> void:
	var abs_path: String = ProjectSettings.globalize_path(SCREENSHOT_PATH)
	assert_true(FileAccess.file_exists(abs_path), "스크린샷 파일 존재: %s" % SCREENSHOT_PATH)
	if not FileAccess.file_exists(abs_path):
		return
	var img: Image = Image.new()
	var err: Error = img.load(abs_path)
	assert_eq(err, OK, "PNG 로드")
	assert_eq(Vector2i(img.get_width(), img.get_height()), Vector2i(1920, 1080), "1920×1080")


# --- SE-004 -----------------------------------------------------------------

const SE004_SHOT_DIR: String = "res://tests/view/screenshots/SE-004"
const SE004_SHOTS: Array[String] = ["a_yaw45_zoom2.png", "b_yaw45_zoom2.png", "c_yaw45_zoom2.png", "b_yaw45_zoom0.png"]


func _all_view_files() -> PackedStringArray:
	var files: PackedStringArray = PackedStringArray()
	for ext: String in ["gd", "tscn", "tres", "gdshader"]:
		files.append_array(ViewTestUtil.list_sources(ViewTestUtil.SOURCE_ROOTS, ext))
	return files


func test_shaders_do_not_reference_assets() -> void:
	var files: PackedStringArray = _all_view_files()
	for must: String in ["res://view/shaders/toon.gdshader", "res://view/shaders/outline.gdshader",
			"res://view/shaders/params/toon_b.tres", "res://view/scenes/shader_placeholders.gd",
			"res://view/scenes/shader_placeholders.tres"]:
		assert_true(files.has(must), "검사 대상에 %s 포함" % must)
	var assets: PackedStringArray = ViewTestUtil.grep(files, "res://assets/")
	assert_eq(assets.size(), 0, "view/ui 가 assets/ 를 참조하지 않는다(플레이스홀더는 프리미티브만): %s" % ", ".join(assets))
	var tests_ref: PackedStringArray = ViewTestUtil.grep(files, TESTS_REF_PATTERN)
	assert_eq(tests_ref.size(), 0, ".gdshader 포함 view/ui 에 res://tests/ 0건: %s" % ", ".join(tests_ref))
	var data_ref: PackedStringArray = ViewTestUtil.grep(ViewTestUtil.list_sources(["res://view/shaders"], "gd"), "res://data/")
	assert_eq(data_ref.size(), 0, "셰이더 시안 코드는 data/ 를 읽지 않는다(셰이더 상수는 .tres): %s" % ", ".join(data_ref))
	# 플레이스홀더 메시는 코드 생성 프리미티브(외부 메시 리소스 로드 없음).
	var mesh_loads: PackedStringArray = ViewTestUtil.grep(PackedStringArray(["res://view/scenes/shader_placeholders.gd"]),
		"(load|preload)\\(\\s*\"[^\"]*\\.(glb|gltf|obj|mesh|res)\"")
	assert_eq(mesh_loads.size(), 0, "외부 메시 로드 없음: %s" % ", ".join(mesh_loads))
	# 역검증.
	assert_eq(ViewTestUtil.grep_lines(PackedStringArray(["var m: Mesh = load(\"res://assets/models/bar.glb\")"]), "res://assets/").size(), 1,
		"대조군: res://assets/ 1건")


func test_se004_screenshots_exist_1080p() -> void:
	for f: String in SE004_SHOTS:
		var abs_path: String = ProjectSettings.globalize_path(SE004_SHOT_DIR.path_join(f))
		assert_true(FileAccess.file_exists(abs_path), "스크린샷 존재: %s" % f)
		if not FileAccess.file_exists(abs_path):
			continue
		var img: Image = Image.new()
		assert_eq(img.load(abs_path), OK, "%s PNG 로드" % f)
		assert_eq(Vector2i(img.get_width(), img.get_height()), Vector2i(1920, 1080), "%s 1920×1080" % f)


# --- SE-018 -----------------------------------------------------------------

const SHADER_VARIANTS_SCRIPT: String = "res://view/shaders/shader_variants.gd"
## 주석(#) 앞의 코드 부분에 "b" 문자열 리터럴이 있는 줄.
const B_LITERAL_PATTERN: String = "^[^#]*\"b\""
const DEFAULT_ID_ENTRY_POINTS: Array[String] = [
	"res://view/scenes/grid_sandbox.gd",
	"res://view/perf/spike_crowd.gd",
	"res://tests/view/perf/measure_spike.gd",
]


func test_default_material_id_has_single_source() -> void:
	var srcs: PackedStringArray = _gd_sources()
	assert_true(srcs.has(SHADER_VARIANTS_SCRIPT), "검사 대상에 shader_variants.gd 포함")
	var outside: PackedStringArray = ViewTestUtil.grep(srcs, B_LITERAL_PATTERN, "/shaders/shader_variants.gd")
	assert_eq(outside.size(), 0, "view/ui .gd 에서 \"b\" 리터럴은 shader_variants.gd 에만: %s" % ", ".join(outside))
	# shader_variants.gd 안에서도 DEFAULT_ID·IDS·SELECTABLE_IDS 선언 3줄뿐.
	var own: PackedStringArray = ViewTestUtil.grep(PackedStringArray([SHADER_VARIANTS_SCRIPT]), B_LITERAL_PATTERN)
	assert_eq(own.size(), 3, "shader_variants.gd 의 \"b\" 리터럴 3줄: %s" % ", ".join(own))
	for line: String in own:
		assert_true(line.contains("const DEFAULT_ID") or line.contains("const IDS") or line.contains("const SELECTABLE_IDS"),
			"선언 줄만: %s" % line)
	# 예전 기본 id "default" 는 view/ui 코드 어디에도 시안 id 로 남아 있지 않다.
	var legacy: PackedStringArray = ViewTestUtil.grep(srcs, "^[^#]*\"default\"")
	assert_eq(legacy.size(), 0, "\"default\" 리터럴 0건: %s" % ", ".join(legacy))
	# 세 진입점이 ShaderVariants.DEFAULT_ID 를 참조한다.
	for path: String in DEFAULT_ID_ENTRY_POINTS:
		var refs: PackedStringArray = ViewTestUtil.grep(PackedStringArray([path]), "^[^#]*ShaderVariants\\.DEFAULT_ID")
		assert_gt(refs.size(), 0, "%s 가 ShaderVariants.DEFAULT_ID 를 참조" % path.get_file())
	# 역검증: 패턴이 코드 줄은 잡고 주석 줄은 거른다.
	var fake: PackedStringArray = PackedStringArray([
		"var wanted: String = resolve(\"\", args, \"b\")",
		"## 기본값은 \"b\"",
		"var x: String = \"bb\"",
	])
	assert_eq(ViewTestUtil.grep_lines(fake, B_LITERAL_PATTERN).size(), 1, "대조군: 코드 줄 \"b\" 1건")


# --- SE-021 AC7 -------------------------------------------------------------

func test_ss_shader_has_no_forward_plus_only_features() -> void:
	var path: String = "res://view/shaders/outline_ss.gdshader"
	var src: PackedStringArray = PackedStringArray([path])
	assert_true(_all_view_files().has(path), "검사 대상에 outline_ss.gdshader 포함")
	assert_eq(ViewTestUtil.grep(src, "hint_normal_roughness_texture").size(), 0, "법선 버퍼(forward_plus 전용) 0건")
	assert_eq(ViewTestUtil.grep(src, "hint_depth_texture").size(), 1, "깊이 텍스처 1건")
	assert_gt(ViewTestUtil.grep(src, "RENDERER_COMPATIBILITY").size(), 0, "Compatibility NDC 분기")
	assert_eq(ViewTestUtil.grep_lines(PackedStringArray(["uniform sampler2D n : hint_normal_roughness_texture;"]),
		"hint_normal_roughness_texture").size(), 1, "대조군")
