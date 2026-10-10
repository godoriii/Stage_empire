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
	# SE-002 의 표시 전용 코드는 이벤트 버스를 쓰지 않는다. SE-037 부터 배치 UI(view/build, ui/build)와
	# 그것을 붙이는 샌드박스만 EventBus 를 쓴다(구독 + *_requested 발행, test_build_ui_boundary_ac6 이 검사).
	# SE-038: 군중·무대 연출(view/crowd, view/stage)도 구독용으로 EventBus 를 쓴다(발행 0, test_crowd_stage_boundary_se038).
	var emits: PackedStringArray = PackedStringArray()
	for h: String in ViewTestUtil.grep(srcs, "EventBus|event_bus"):
		if not _is_build_ui_file(h) and not _is_se038_file(h) and not _is_se039_file(h) and not _is_se040_file(h):
			emits.append(h)
	assert_eq(emits.size(), 0, "배치 UI·군중/무대 연출·HUD 패널(SE-039) 밖에서는 이벤트 버스 사용 없음: %s" % ", ".join(emits))


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


# --- SE-037 AC6 -------------------------------------------------------------

## EventBus 를 쓸 수 있는 view/ui 파일(배치 UI + 그것을 붙이는 샌드박스).
const BUILD_UI_PREFIXES: Array[String] = ["res://view/build/", "res://ui/build/", "res://view/scenes/grid_sandbox.gd"]
const SE037_SHOT: String = "res://tests/view/screenshots/SE-037/build_baseline_yaw45_zoom2.png"


## grep 결과 줄("경로:줄: 내용")이 배치 UI 파일인가.
func _is_build_ui_file(hit: String) -> bool:
	for p: String in BUILD_UI_PREFIXES:
		if hit.begins_with(p):
			return true
	return false


## res://sim·core·world 의 class_name 전부(현재 리포지토리 기준으로 읽는다 — 새 클래스가 생겨도 검사가 따라간다).
func _sim_class_names() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	var re: RegEx = RegEx.create_from_string("^class_name\\s+([A-Za-z_][A-Za-z0-9_]*)")
	for path: String in ViewTestUtil.list_sources(["res://sim", "res://core", "res://world"], "gd"):
		for line: String in FileAccess.get_file_as_string(path).split("\n"):
			var m: RegExMatch = re.search(line)
			if m != null:
				names.append(m.get_string(1))
	return names


func test_build_ui_boundary_ac6() -> void:
	var srcs: PackedStringArray = _gd_sources()
	for must: String in ["res://view/build/furniture_view.gd", "res://view/build/placement_ghost.gd",
			"res://view/build/coverage_overlay.gd", "res://ui/build/build_palette.gd"]:
		assert_true(srcs.has(must), "검사 대상에 %s 포함" % must)
	var files: PackedStringArray = _all_view_files()
	# (1) sim/core/world 스크립트·씬 로드 0건.
	var loads: PackedStringArray = ViewTestUtil.grep(files, "(load|preload)\\(\\s*\"res://(sim|core|world)/")
	assert_eq(loads.size(), 0, "view/ui 가 res://sim·core·world 를 load/preload 하지 않는다: %s" % ", ".join(loads))
	var refs: PackedStringArray = ViewTestUtil.grep(files, "res://(sim|core|world)/")
	assert_eq(refs.size(), 0, "view/ui 에 res://sim·core·world 경로 0건: %s" % ", ".join(refs))
	# (2) EventBus 외 sim/core/world 클래스 참조 0건(주석 제외 코드 부분).
	var names: PackedStringArray = _sim_class_names()
	assert_true(names.has("EventBus"), "class_name 수집이 동작한다(EventBus 포함)")
	var other: PackedStringArray = PackedStringArray()
	for n: String in names:
		if n == "EventBus":
			continue
		for h: String in ViewTestUtil.grep(srcs, "^[^#]*\\b%s\\b" % n):
			# SE-040 AC1: 루트 씬(main.gd)과 실시간 구동기(sim_driver.gd)만 GameSession 타입을 참조한다 —
			# sim+view 를 한 버스에 묶는 조립점이 view 쪽에 하나 있어야 하고(producer 결정, SE-040 티켓 보충), 그 조립점이
			# 아는 sim 타입을 core 팩토리(GameSession) 하나로 제한한다. 다른 sim/core/world 클래스는 여기서도 0건.
			if n == SE040_ALLOWED_CLASS and _is_se040_file(h):
				continue
			other.append(h)
	assert_eq(other.size(), 0, "EventBus 외 sim/core/world 클래스 참조 0건 (%d종 검사): %s" % [names.size() - 1, ", ".join(other)])
	# (3) EventBus 사용 = 타입 표기(: EventBus / -> EventBus)뿐. 생성(EventBus.new)은 샌드박스 전용 버스 1곳만.
	var usage: PackedStringArray = PackedStringArray()
	var news: PackedStringArray = PackedStringArray()
	for h: String in ViewTestUtil.grep(srcs, "^[^#]*\\bEventBus\\b"):
		var code: String = h.get_slice("#", 0)
		var stripped: String = code.replace(": EventBus", "").replace("-> EventBus", "")
		if stripped.contains("EventBus.new()") and h.begins_with("res://view/scenes/grid_sandbox.gd"):
			news.append(h)
			stripped = stripped.replace("EventBus.new()", "")
		if RegEx.create_from_string("\\bEventBus\\b").search(stripped) != null:
			usage.append(h)
	assert_eq(usage.size(), 0, "EventBus 는 타입 참조만: %s" % ", ".join(usage))
	assert_eq(news.size(), 1, "EventBus.new() 는 샌드박스 1곳: %s" % ", ".join(news))
	# (4) 발행은 *_requested 명령만, 문자열 리터럴로(검사 가능하게).
	# SE-039 부터 HUD·패널도 발행한다 — 배치 UI 파일만 세고, 전체는 아래 *_requested 검사로 본다(test_se039_boundary).
	var publishes: PackedStringArray = PackedStringArray()
	for h: String in ViewTestUtil.grep(srcs, "^[^#]*\\.publish\\("):
		if _is_build_ui_file(h):
			publishes.append(h)
	assert_eq(publishes.size(), 2, "배치 UI 발행 지점 2곳(place·demolish): %s" % ", ".join(publishes))
	for h: String in publishes:
		assert_true(RegEx.create_from_string("\\.publish\\(\\s*\"[a-z_]+\\.[a-z_]+_requested\"").search(h) != null,
			"*_requested 명령만 발행: %s" % h)
	# (5) 버스 상태 조작 0건(명령 디스패치·큐 교체는 core/sim 몫).
	var ops: PackedStringArray = ViewTestUtil.grep(srcs, "^[^#]*\\b(dispatch_commands|set_pending_commands|normalize_commands)\\(")
	assert_eq(ops.size(), 0, "view/ui 가 명령 큐를 조작하지 않는다: %s" % ", ".join(ops))
	# 역검증: 같은 정규식이 가짜 줄에서 정확히 잡는다.
	var fake: PackedStringArray = PackedStringArray([
		"_bus.publish(\"build.placed\", {})",
		"_bus.publish(\"build.place_requested\", {})",
		"# _bus.publish(\"build.placed\") 주석",
		"var b: Build = Build.new(cfg, bus)",
	])
	assert_eq(ViewTestUtil.grep_lines(fake, "^[^#]*\\.publish\\(").size(), 2, "대조군: 코드 줄 publish 2건")
	assert_eq(ViewTestUtil.grep_lines(fake, "^[^#]*\\bBuild\\b").size(), 1, "대조군: 클래스 참조 1건")
	assert_null(RegEx.create_from_string("\\.publish\\(\\s*\"[a-z_]+\\.[a-z_]+_requested\"").search(fake[0]), "대조군: build.placed 는 명령 아님")


func test_build_data_numbers_not_hardcoded() -> void:
	# AC5: 가구 수·카테고리 수는 데이터에서 읽는다. 배치 UI 코드에 행 수 리터럴이 없다.
	var f: Dictionary = ViewTestUtil.read_json("res://data/furniture/furniture.json")
	var row_count: int = (f["rows"] as Array).size()
	var files: PackedStringArray = ViewTestUtil.list_sources(["res://view/build", "res://ui/build"], "gd")
	assert_gt(files.size(), 0)
	var hits: PackedStringArray = ViewTestUtil.grep(files, "^[^#]*(^|[^0-9.%])" + str(row_count) + "($|[^0-9.])")
	assert_eq(hits.size(), 0, "배치 UI 코드에 행 수 리터럴 %d 없음: %s" % [row_count, ", ".join(hits)])
	var row_re: String = "^[^#]*(^|[^0-9.%])" + str(row_count) + "($|[^0-9.])"
	var fake: PackedStringArray = PackedStringArray([
		"for i: int in range(%d):" % row_count, "var a: float = 0.%d" % row_count, "# 가구 %d종" % row_count, "var b: int = 1%d" % row_count,
	])
	assert_eq(ViewTestUtil.grep_lines(fake, row_re).size(), 1, "대조군: 코드 리터럴 1건만")
	# 가구 id 리터럴도 배치 UI 코드에 없다(프리셋은 레이아웃 id 만 쓴다).
	var ids: PackedStringArray = PackedStringArray()
	for r: Dictionary in f["rows"]:
		ids.append(r["id"])
	var id_hits: PackedStringArray = ViewTestUtil.grep(files, "^[^#]*\"(%s)\"" % "|".join(ids))
	assert_eq(id_hits.size(), 0, "가구 id 리터럴 없음: %s" % ", ".join(id_hits))


func test_se037_screenshot_exists_1080p() -> void:
	var abs_path: String = ProjectSettings.globalize_path(SE037_SHOT)
	assert_true(FileAccess.file_exists(abs_path), "SE-037 캡처 존재: %s" % SE037_SHOT)
	if not FileAccess.file_exists(abs_path):
		return
	var img: Image = Image.new()
	assert_eq(img.load(abs_path), OK, "PNG 로드")
	assert_eq(Vector2i(img.get_width(), img.get_height()), Vector2i(1920, 1080), "1920×1080")


# --- SE-038 AC7 -------------------------------------------------------------

## 구독 전용으로 EventBus 를 쓰는 SE-038 폴더.
const SE038_PREFIXES: Array[String] = ["res://view/crowd/", "res://view/stage/"]
const SE038_FILES: Array[String] = [
	"res://view/crowd/crowd_view.gd", "res://view/crowd/crowd_data.gd", "res://view/crowd/crowd_proxy_mesh.gd",
	"res://view/crowd/crowd_preset.gd", "res://view/crowd/crowd_view_params.gd", "res://view/stage/stage_lights.gd",
	"res://view/stage/stage_light_params.gd", "res://view/stage/stage_geometry.gd",
]
const SE038_SHOT: String = "res://tests/view/screenshots/SE-038/crowd150_show_yaw45_zoom2.png"


func _is_se038_file(hit: String) -> bool:
	for p: String in SE038_PREFIXES:
		if hit.begins_with(p):
			return true
	return false


func test_crowd_stage_boundary_se038() -> void:
	var srcs: PackedStringArray = _gd_sources()
	for must: String in SE038_FILES:
		assert_true(srcs.has(must), "검사 대상에 %s 포함" % must)
	var mine: PackedStringArray = ViewTestUtil.list_sources(SE038_PREFIXES, "gd")
	var res_files: PackedStringArray = ViewTestUtil.list_sources(SE038_PREFIXES, "tres")
	assert_eq(res_files.size(), 2, "룩 상수 .tres 2개(crowd_view_params, stage_light_params)")
	var all_mine: PackedStringArray = mine.duplicate()
	all_mine.append_array(res_files)
	# (1) sim/core/world 경로 0건, EventBus 외 sim 클래스 0건(위 test_build_ui_boundary_ac6 가 전체 view/ui 로 검사 — 여기선 대상 포함만 재확인).
	assert_eq(ViewTestUtil.grep(all_mine, "res://(sim|core|world)/").size(), 0, "res://sim·core·world 0건")
	# (2) 발행 0: publish·dispatch·명령 큐 조작 없음.
	var pubs: PackedStringArray = ViewTestUtil.grep(mine, "^[^#]*\\.(publish|dispatch_commands|set_pending_commands)\\(")
	assert_eq(pubs.size(), 0, "군중·무대 연출은 발행 0: %s" % ", ".join(pubs))
	# (3) EventBus 는 타입 표기뿐(생성 없음).
	for h: String in ViewTestUtil.grep(mine, "^[^#]*\\bEventBus\\b"):
		var code: String = h.get_slice("#", 0).replace(": EventBus", "")
		assert_null(RegEx.create_from_string("\\bEventBus\\b").search(code), "EventBus 타입 참조만: %s" % h)
	# (4) _process 는 표시 진행 함수 하나만 부른다(게임 상태 변경 없음).
	for path: String in ["res://view/crowd/crowd_view.gd", "res://view/stage/stage_lights.gd"]:
		var body: PackedStringArray = _func_body(path, "_process")
		assert_eq(body.size(), 1, "%s _process 본문 1줄: %s" % [path.get_file(), " / ".join(body)])
		if body.size() == 1:
			assert_eq(body[0].strip_edges(), "advance_display(delta)", "%s _process = advance_display 만" % path.get_file())
	# (5) 틱 길이·좌표 단위·유형 색은 데이터에서: crowd_view/crowd_data 에 sim.json 값 리터럴 없음.
	var sim: Dictionary = ViewTestUtil.read_json("res://data/sim/sim.json") as Dictionary
	var tps: String = str(int(sim["ticks_per_second"]))
	var tick_lit: PackedStringArray = ViewTestUtil.grep(PackedStringArray(["res://view/crowd/crowd_view.gd", "res://view/crowd/crowd_data.gd"]),
		"^[^#]*(\\b%s\\b|/\\s*%s(\\.0)?\\b)" % [str(1.0 / float(sim["ticks_per_second"])).replace(".", "\\."), tps])
	assert_eq(tick_lit.size(), 0, "틱 길이 리터럴 없음: %s" % ", ".join(tick_lit))
	var hexes: PackedStringArray = PackedStringArray()
	for t: Dictionary in (ViewTestUtil.read_json("res://data/audience/audience.json") as Dictionary)["types"]:
		hexes.append(str(t["color"]).trim_prefix("#"))
	assert_eq(ViewTestUtil.grep(all_mine, "(?i)(%s)" % "|".join(hexes)).size(), 0, "유형 색 hex 리터럴 없음")
	# 역검증.
	assert_eq(ViewTestUtil.grep_lines(PackedStringArray(["_bus.publish(\"x.y\", {})", "# _bus.publish(\"x\")"]),
		"^[^#]*\\.(publish|dispatch_commands|set_pending_commands)\\(").size(), 1, "대조군: publish 1건")


## 스크립트에서 func <name>( 의 본문 줄(빈 줄 제외, 다음 최상위 줄 전까지).
func _func_body(path: String, fname: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var inside: bool = false
	for line: String in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with("func %s(" % fname):
			inside = true
			continue
		if inside:
			if line.strip_edges().is_empty():
				continue
			if not line.begins_with("\t"):
				break
			out.append(line)
	return out


func test_se038_screenshot_exists_1080p() -> void:
	var abs_path: String = ProjectSettings.globalize_path(SE038_SHOT)
	assert_true(FileAccess.file_exists(abs_path), "SE-038 캡처 존재: %s" % SE038_SHOT)
	if not FileAccess.file_exists(abs_path):
		return
	var img: Image = Image.new()
	assert_eq(img.load(abs_path), OK, "PNG 로드")
	assert_eq(Vector2i(img.get_width(), img.get_height()), Vector2i(1920, 1080), "1920×1080")


# --- SE-039 AC7·경계 ---------------------------------------------------------

## SE-039 HUD·패널 파일(구독 + *_requested 발행).
const SE039_PREFIXES: Array[String] = ["res://ui/hud/top_hud.gd", "res://ui/panels/", "res://ui/ui_"]
const SE039_FILES: Array[String] = [
	"res://ui/hud/top_hud.gd", "res://ui/panels/artist_panel.gd", "res://ui/panels/day_report.gd",
	"res://ui/panels/bailout_modal.gd", "res://ui/panels/game_over.gd", "res://ui/panels/notifications.gd",
	"res://ui/panels/main_menu.gd", "res://ui/ui_root.gd", "res://ui/ui_panel.gd", "res://ui/ui_text.gd", "res://ui/ui_data.gd",
	"res://ui/ui_params.gd", "res://ui/ui_preset.gd", "res://ui/ui_artist_catalog.gd",
]
## SE-039 이전 파일의 한국어 리터럴(캡처 SE-002·SE-037 에 그대로 찍혀 있다). ui_ko.json(2차) 뒤 같은 문장으로 키 전환 —
## 후속 티켓. 이 목록은 줄기만 한다(새 파일 추가 금지).
const KOREAN_LEGACY_FILES: Array[String] = ["res://ui/build/build_palette.gd", "res://ui/hud/debug_hud.gd"]
## SE-039 가 발행하는 명령 전부(events.md 명령 표 + session.* — 2차 등록).
const SE039_COMMANDS: Array[String] = [
	"time.speed_requested", "time.next_day_requested", "artist.book_requested", "economy.ticket_price_requested",
	"economy.bailout_accept_requested", "session.save_requested", "session.load_requested", "session.new_game_requested",
]
## 읽기 전용 sim 객체에서 부를 수 있는 멤버(SE-033·SE-030 인계).
const SE039_READ_MEMBERS: Array[String] = [
	"artist_ids", "artist", "guarantee", "unlock_reputation", "check_book", "roster", "entry", "total",
]
const HANGUL_PATTERN: String = "[가-힣]"


func _is_se039_file(hit: String) -> bool:
	for p: String in SE039_PREFIXES:
		if hit.begins_with(p):
			return true
	return false


## 줄에서 주석(문자열 밖의 첫 #부터)을 뗀 코드 부분.
static func _code_part(line: String) -> String:
	var quote: String = ""
	var i: int = 0
	while i < line.length():
		var c: String = line[i]
		if quote.is_empty():
			if c == "#":
				return line.substr(0, i)
			if c == "\"" or c == "'":
				quote = c
		elif c == "\\":
			i += 1
		elif c == quote:
			quote = ""
		i += 1
	return line


## 파일들에서 주석을 뺀 코드에 정규식이 걸리는 줄("경로:줄: 내용").
static func _grep_code(paths: PackedStringArray, pattern: String) -> PackedStringArray:
	var re: RegEx = RegEx.create_from_string(pattern)
	var out: PackedStringArray = PackedStringArray()
	for path: String in paths:
		var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
		for i: int in range(lines.size()):
			if re.search(_code_part(lines[i])) != null:
				out.append("%s:%d: %s" % [path, i + 1, lines[i].strip_edges()])
	return out


func test_ui_no_korean_literals_ac7() -> void:
	var files: PackedStringArray = ViewTestUtil.list_sources(["res://ui"], "gd")
	for must: String in SE039_FILES:
		assert_true(files.has(must), "검사 대상에 %s 포함" % must)
	var hits: PackedStringArray = PackedStringArray()
	var legacy: Dictionary = {}
	for h: String in _grep_code(files, HANGUL_PATTERN):
		var path: String = h.get_slice(":", 0) + ":" + h.get_slice(":", 1)
		if KOREAN_LEGACY_FILES.has(path):
			legacy[path] = true
		else:
			hits.append(h)
	assert_eq(hits.size(), 0, "project/ui .gd 의 한국어 리터럴(주석 제외) 0건: %s" % ", ".join(hits))
	for path: Variant in legacy:
		assert_true(KOREAN_LEGACY_FILES.has(str(path)), "예외는 SE-039 이전 파일만: %s" % path)
	# SE-039 파일은 주석을 빼면 한글 0, 주석에는 있다(검사가 주석을 실제로 거른다).
	assert_eq(_grep_code(PackedStringArray(SE039_FILES), HANGUL_PATTERN).size(), 0, "SE-039 파일 한글 리터럴 0")
	assert_gt(ViewTestUtil.grep(PackedStringArray(SE039_FILES), HANGUL_PATTERN).size(), 0, "주석의 한글은 걸리지 않는다(대조)")
	# 역검증.
	var fake: PackedStringArray = PackedStringArray([
		"label.text = \"자금\"", "## 자금 라벨", "label.text = t(\"ui.hud.cash\")  # 자금", "var s: String = \"#\" + \"명성\"",
	])
	var n: int = 0
	var re: RegEx = RegEx.create_from_string(HANGUL_PATTERN)
	for line: String in fake:
		if re.search(_code_part(line)) != null:
			n += 1
	assert_eq(n, 2, "대조군: 코드 리터럴 2건(주석 2건 제외)")


func test_se039_boundary() -> void:
	var files: PackedStringArray = PackedStringArray(SE039_FILES)
	# (1) 발행은 정해진 *_requested 명령만, 문자열 리터럴로.
	var pub_re: RegEx = RegEx.create_from_string("\\.publish\\(\\s*\"([a-z_]+\\.[a-z_]+_requested)\"")
	var published: Dictionary = {}
	for h: String in _grep_code(files, "\\.publish\\("):
		var m: RegExMatch = pub_re.search(h)
		assert_not_null(m, "*_requested 리터럴 발행만: %s" % h)
		if m != null:
			assert_true(SE039_COMMANDS.has(m.get_string(1)), "정해진 명령만: %s" % m.get_string(1))
			published[m.get_string(1)] = true
	for c: String in SE039_COMMANDS:
		assert_true(published.has(c), "명령 %s 발행 지점 있음" % c)
	# (2) 명령 큐 조작 0, _process 0(원칙 2), sim 클래스 이름 0(덕 타이핑 — test_build_ui_boundary_ac6 와 같은 수집).
	assert_eq(_grep_code(files, "\\b(dispatch_commands|set_pending_commands|normalize_commands)\\(").size(), 0, "명령 큐 조작 0")
	assert_eq(_grep_code(files, "^func _(physics_)?process\\(").size(), 0, "_process 없음")
	for n: String in ["ArtistSystem", "ArtistConfig", "ReputationSystem", "Economy", "TickLoop", "GameSession"]:
		assert_eq(_grep_code(files, "\\b%s\\b" % n).size(), 0, "%s 이름 참조 0(인계 멤버는 .call 로만)" % n)
	# (3) 읽기 전용 객체 호출(.call("멤버"))은 인계 멤버만.
	var call_re: RegEx = RegEx.create_from_string("\\.call\\(\\s*\"([a-z_]+)\"")
	var called: Dictionary = {}
	for h: String in _grep_code(files, "\\.call\\(\\s*\""):
		for m: RegExMatch in call_re.search_all(h):
			called[m.get_string(1)] = true
			assert_true(SE039_READ_MEMBERS.has(m.get_string(1)), "인계 멤버만 호출: %s" % h)
	assert_true(called.has("check_book") and called.has("roster"), "check_book·roster 호출 검사 동작")
	# (4) 수치 리터럴: 명단 행 수·섭외 임계·티어 해금 조건·티켓 가격 범위가 코드에 없다.
	var nums: Dictionary = {}
	nums[str((ViewTestUtil.read_json("res://data/artists/artists.json") as Dictionary)["rows"].size())] = "artists rows"
	for g: Dictionary in (ViewTestUtil.read_json("res://data/artist/artist.json") as Dictionary)["grades"]:
		if int(g["unlock_reputation"]) > 0:
			nums[str(int(g["unlock_reputation"]))] = "unlock_reputation"
	for r: Dictionary in (ViewTestUtil.read_json("res://data/tiers/tiers.json") as Dictionary)["rows"]:
		for k: String in ["unlock_reputation", "unlock_cash"]:
			if int(r[k]) > 0:
				nums[str(int(r[k]))] = "tiers " + k
	for r: Dictionary in (ViewTestUtil.read_json("res://data/economy/economy.json") as Dictionary)["rows"]:
		for k: String in ["ticket_price_min", "ticket_price_max", "ticket_price_default"]:
			nums[str(int(r[k]))] = "economy " + k
	for v: String in nums:
		var hits: PackedStringArray = _grep_code(files, "(^|[^0-9._a-zA-Z])" + v + "($|[^0-9.])")
		assert_eq(hits.size(), 0, "%s(%s) 리터럴 없음: %s" % [v, nums[v], ", ".join(hits)])


const SE039_SHOTS: Array[String] = [
	"res://tests/view/screenshots/SE-039/hud_day_yaw45_zoom2.png", "res://tests/view/screenshots/SE-039/report_close.png",
]


func test_se039_screenshots_exist_1080p() -> void:
	for shot: String in SE039_SHOTS:
		var abs_path: String = ProjectSettings.globalize_path(shot)
		assert_true(FileAccess.file_exists(abs_path), "SE-039 캡처 존재: %s" % shot)
		if not FileAccess.file_exists(abs_path):
			continue
		var img: Image = Image.new()
		assert_eq(img.load(abs_path), OK, "PNG 로드")
		assert_eq(Vector2i(img.get_width(), img.get_height()), Vector2i(1920, 1080), "1920×1080")


# --- SE-040 메인 씬 ---------------------------------------------------------------

## GameSession 타입 참조를 허용하는 두 파일(허용 사유는 test_build_ui_boundary_ac6 (2) 주석).
const SE040_FILES: Array[String] = ["res://view/scenes/main.gd", "res://view/runtime/sim_driver.gd"]
const SE040_ALLOWED_CLASS: String = "GameSession"
## main.gd 가 session 에서 읽거나 부를 수 있는 멤버(팩토리·버스·읽기 전용 쿼리·섭외 패널 출처·세이브 폴더 주입).
const SE040_SESSION_MEMBERS: Array[String] = [
	"new_game", "bus", "check_place", "hud_state", "artist", "reputation", "saves_dir",
]
## main.gd 가 발행할 수 있는 명령(메뉴 경로 SN5·불러오기 AC-36a·자동 플레이 AC4).
const SE040_COMMANDS: Array[String] = [
	"session.new_game_requested", "session.load_requested", "build.place_requested", "artist.book_requested",
	"time.speed_requested", "time.next_day_requested",
]


func _is_se040_file(hit: String) -> bool:
	for p: String in SE040_FILES:
		if hit.begins_with(p + ":") or hit == p:
			return true
	return false


func test_se040_sim_driver_calls_step_only_ac1() -> void:
	var path: String = "res://view/runtime/sim_driver.gd"
	var calls: PackedStringArray = _grep_code(PackedStringArray([path]), "\\bsession\\.[a-z_]+\\(")
	assert_eq(calls.size(), 1, "sim_driver.gd 의 session.<메서드>( 호출 1건: %s" % ", ".join(calls))
	for h: String in calls:
		assert_true(h.contains("session.step("), "그 1건은 step(: %s" % h)
	# _process 는 drive 하나만 부른다(drive 안의 호출이 위 1건).
	var src: String = FileAccess.get_file_as_string(path)
	assert_true(src.contains("func _process(delta: float) -> void:\n\tdrive(delta)"), "_process → drive(delta) 뿐")
	# 대조군: 다른 메서드 호출은 걸린다.
	var re: RegEx = RegEx.create_from_string("\\bsession\\.[a-z_]+\\(")
	assert_not_null(re.search("session.advance(1)"), "대조군: advance 호출도 정규식에 걸린다")


func test_se040_main_scene_boundary() -> void:
	var main: String = "res://view/scenes/main.gd"
	var srcs: PackedStringArray = _gd_sources()
	for f: String in SE040_FILES:
		assert_true(srcs.has(f), "검사 대상에 %s 포함" % f)
	var files: PackedStringArray = PackedStringArray([main])
	# (1) session 멤버 사용은 허용 목록만.
	# 문자열 안의 이벤트 이름("session.loaded")·다른 객체의 .session 은 제외(앞 글자가 따옴표·단어·점이 아님).
	var re: RegEx = RegEx.create_from_string("(?<![\"\\w.])session\\.([a-z_]+)")
	var used: Dictionary = {}
	for h: String in _grep_code(files, "(?<![\"\\w.])session\\."):
		for m: RegExMatch in re.search_all(_code_part(h.substr(h.find(": ") + 2))):
			used[m.get_string(1)] = true
			assert_true(SE040_SESSION_MEMBERS.has(m.get_string(1)), "허용된 session 멤버만: %s" % h)
	for must: String in ["new_game", "bus", "check_place", "hud_state"]:
		assert_true(used.has(must), "session.%s 사용 확인(검사 동작)" % must)
	# (2) 발행은 정해진 *_requested 명령 리터럴만.
	var pub_re: RegEx = RegEx.create_from_string("\\.publish\\(\\s*\"([a-z_]+\\.[a-z_]+_requested)\"")
	var pubs: PackedStringArray = _grep_code(files, "\\.publish\\(")
	assert_gt(pubs.size(), 0, "main.gd 발행 지점 있음")
	for h: String in pubs:
		var m: RegExMatch = pub_re.search(h)
		assert_not_null(m, "*_requested 리터럴만: %s" % h)
		if m != null:
			assert_true(SE040_COMMANDS.has(m.get_string(1)), "정해진 명령만: %s" % m.get_string(1))
	# (3) AC-37b·AC-36a: EventBus.new() 0, restore( 0, res://world·BuildSystem 0(전체 view/ui).
	assert_eq(_grep_code(files, "EventBus\\.new\\(").size(), 0, "main.gd 는 EventBus.new() 를 부르지 않는다")
	var restores: PackedStringArray = _grep_code(srcs, "\\.restore\\(")
	assert_eq(restores.size(), 0, "view/ui 에 .restore( 호출 0(AC-36a): %s" % ", ".join(restores))
	assert_eq(_grep_code(srcs, "\\bBuildSystem\\b").size(), 0, "view/ui 에 BuildSystem 참조 0(AC-37a)")
	# (4) 고스트 유효성은 check_place 주입.
	assert_eq(_grep_code(files, "Callable\\(session, \"check_place\"\\)").size(), 1, "Callable(session, \"check_place\") 주입 1곳")
	# (5) GameSession 참조는 두 파일에만(다른 view/ui 0).
	for h: String in _grep_code(srcs, "\\bGameSession\\b"):
		assert_true(_is_se040_file(h), "GameSession 참조는 main.gd·sim_driver.gd 만: %s" % h)
	# (6) 명령 큐 조작 0.
	assert_eq(_grep_code(files, "\\b(dispatch_commands|set_pending_commands|normalize_commands)\\(").size(), 0, "명령 큐 조작 0")
