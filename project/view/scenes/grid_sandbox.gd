class_name GridSandbox
extends Node3D
## SE-002 샌드박스: 티어 1 그리드 + 아이소 카메라 + 타일 커서 + 디버그 HUD.
## SE-003(성능 스파이크), SE-004(셰이더 시안)의 공통 무대.
## 입력은 InputActions 의 액션 이름으로만 받는다. 게임 상태를 바꾸지 않으며 이벤트 버스를 쓰지 않는다.
##
## 실행: godot --path project res://view/scenes/grid_sandbox.tscn
## 스크린샷(사람 검수용): 위 명령 뒤에 -- --se-screenshot=<절대경로.png> [--se-hover=x,z]
##   (GPU/디스플레이가 있는 환경 필요. --headless 에서는 캡처가 안 된다.)
##
## 셰이더 시안(SE-004, SE-018): 시작 시 ShaderPlaceholders(바·무대·캐릭터·벽·컬러 스포트)를 그리드 중심에 만들고
##   시안을 적용한다(바닥·커서·HUD 제외). 기본은 ShaderVariants.DEFAULT_ID(시안 B), 비교용으로
##   -- --material=<plain|a|b|c|ss>(plain = SE-004 이전 정점색 룩, ss = SE-021 스크린스페이스 외곽선 비교 시안 —
##   포스트 패스 노드 1개가 이 노드 직속에 붙는다). 키 1/2/3(shader_variant_1/2/3)으로 a/b/c 전환,
##   HUD 에 "시안: <id>". 없는 id(예전 "default" 포함)면 push_error + 종료 코드 2.
##   -- --se-zoom=<0..3> 은 시작 줌 인덱스(0 = 최근접). 범위 밖이면 push_warning 후 기본 줌 유지.
##
## 배치 UI(SE-037): -- --se-build-preset=<empty|baseline> 일 때만 가구 렌더·고스트·오버레이·하단 팔레트를 붙인다
##   (인자가 없으면 SE-002/SE-004 와 같은 화면 — 기준 캡처 불변). 프리셋이 있으면 시안 플레이스홀더 세트는 숨긴다.
##   이벤트 버스는 이 샌드박스 전용 EventBus 하나(sim 미등록): 클릭한 배치·철거 명령은 명령 큐에 남는다(SE-040 통합 전).
##   baseline = 기준 배치(tier1_club reference_layouts[baseline_show]) + 음향 오버레이(BuildPreset 의 가짜 sim 출력).
##   없는 프리셋 id 면 push_error + 종료 코드 2.
##
## 군중·무대 연출(SE-038): -- --se-crowd-preset=<n> (1 ≤ n ≤ audience.json max_agents) 일 때만 CrowdView·StageLights 를
##   붙인다. 배치 프리셋이 없으면 baseline 을 함께 붙이고, 오버레이는 끈다(군중이 잘 보이게). CrowdPreset 의 가짜 sim 출력
##   (조명 가구 + 관객 n 명 watching + show.started)을 핸들러에 직접 넣는다(버스 발행 없음). 범위 밖·숫자 아님이면
##   push_error + 종료 코드 2. 캡처: -- --se-crowd-preset=150 --se-screenshot=<경로>(줌 기본 = 2).

const SCREENSHOT_ARG: String = "--se-screenshot="
const HOVER_ARG: String = "--se-hover="
const ZOOM_ARG: String = "--se-zoom="
const PLACEHOLDERS_SCENE: String = "res://view/scenes/shader_placeholders.tscn"
## 종료 코드: 없는 시안 id(SpikeMeasure.EXIT_BAD_SETUP 과 같은 값).
const EXIT_BAD_MATERIAL: int = 2
## 종료 코드: 없는 배치 프리셋 id.
const EXIT_BAD_BUILD_PRESET: int = 2
## 종료 코드: 군중 프리셋 값이 틀림(SE-038).
const EXIT_BAD_CROWD_PRESET: int = 2
const BUILD_PALETTE_SCENE: String = "res://ui/build/build_palette.tscn"
## 스크린샷 전 렌더가 안정될 때까지 기다리는 프레임 수(디버그 기능 전용).
const SCREENSHOT_WARMUP_FRAMES: int = 10

@onready var grid: GridView = $GridView
@onready var cursor: TileCursor = $TileCursor
@onready var iso_camera: IsoCamera = $IsoCamera
@onready var hud: DebugHud = $DebugHud

## SE-004/SE-018: 비워 두면 명령줄 --material=<id>, 그것도 없으면 ShaderVariants.DEFAULT_ID.
@export var material_id: String = ""

var _placeholders: ShaderPlaceholders
var _material_id: String = ""
## SE-037 배치 UI(프리셋이 있을 때만). 없으면 전부 null.
var _build_preset: String = BuildPreset.NONE
var _bus: EventBus
var _catalog: BuildCatalog
var _furniture_view: FurnitureView
var _ghost: PlacementGhost
var _overlay: CoverageOverlay
var _palette: BuildPalette
## SE-038 군중·무대 연출(군중 프리셋이 있을 때만). 없으면 null.
var _crowd_view: CrowdView
var _stage_lights: StageLights


func _ready() -> void:
	InputActions.register()
	InputActions.register_shader_variants()
	iso_camera.set_bounds(grid.get_extent_m())
	iso_camera.focus_on(grid.get_center_world())
	cursor.setup(iso_camera.get_camera(), grid)
	hud.bind(iso_camera, cursor)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	apply_zoom_args(args)
	var wanted: String = ShaderVariants.resolve_material_id(material_id, args, ShaderVariants.DEFAULT_ID)
	if not apply_material(wanted):
		get_tree().quit(EXIT_BAD_MATERIAL)
		return
	var preset: String = BuildPreset.resolve(args)
	if preset != BuildPreset.NONE and not setup_build(preset):
		get_tree().quit(EXIT_BAD_BUILD_PRESET)
		return
	var crowd_raw: String = CrowdPreset.resolve(args)
	if crowd_raw != CrowdPreset.NONE and not setup_crowd(crowd_raw):
		get_tree().quit(EXIT_BAD_CROWD_PRESET)
		return
	_run_screenshot_if_requested()


## SE-004: 시안을 적용한다. 처음 부르면 플레이스홀더 세트를 그리드 중심에 만든다.
## 바닥(GridView)·커서(TileCursor)·HUD 는 제외. 없는 id 면 push_error 후 false(플레이스홀더를 만들지 않는다).
## 시안 머티리얼 로드가 실패하면(ShaderVariants.apply 가 -1, push_error 는 거기서) false, 시안 id·HUD 는 그대로.
func apply_material(id: String) -> bool:
	var wanted: String = id.strip_edges().to_lower()
	if not ShaderVariants.is_valid_id(wanted):
		push_error("GridSandbox: 시안 '%s' 없음 (가능: %s)" % [id, ", ".join(ShaderVariants.IDS)])
		return false
	if _placeholders == null:
		_placeholders = (load(PLACEHOLDERS_SCENE) as PackedScene).instantiate() as ShaderPlaceholders
		_placeholders.position = grid.get_center_world()
		add_child(_placeholders)
	var excluded: Array[Node] = [grid, cursor, hud]
	# SE-037: 고스트·데칼은 반투명 무광 머티리얼 유지(가구 메시만 시안을 받는다).
	for n: Node in [_ghost, _overlay, _palette]:
		if n != null:
			excluded.append(n)
	if ShaderVariants.apply(self, wanted, excluded) < 0:
		return false
	_material_id = wanted
	if _furniture_view != null:
		_furniture_view.set_material_id(wanted)
	if _crowd_view != null:
		_crowd_view.set_material_id(wanted)
	hud.set_shader_variant(wanted)
	return true


## 현재 시안 id(_ready 뒤에는 항상 유효한 id. 인자가 없으면 ShaderVariants.DEFAULT_ID).
func get_material_id() -> String:
	return _material_id


func get_placeholders() -> ShaderPlaceholders:
	return _placeholders


## SE-037: 배치 UI 를 붙이고 프리셋을 적용한다. 이미 붙어 있으면 false. 없는 id 면 push_error 후 false.
func setup_build(preset_id: String) -> bool:
	if not BuildPreset.is_valid_id(preset_id):
		push_error("GridSandbox: 배치 프리셋 '%s' 없음 (가능: %s)" % [preset_id, ", ".join(BuildPreset.IDS)])
		return false
	if _bus != null:
		push_warning("GridSandbox: 배치 UI 가 이미 있다")
		return false
	_catalog = BuildCatalog.load_default()
	if _catalog == null:
		return false
	_build_preset = preset_id
	InputActions.register_build()
	_bus = EventBus.new()
	var t: float = grid.get_tile_size_m()
	_furniture_view = FurnitureView.new()
	_furniture_view.name = "FurnitureView"
	add_child(_furniture_view)
	_furniture_view.bind(_bus, _catalog, t)
	_furniture_view.set_material_id(_material_id if not _material_id.is_empty() else ShaderVariants.DEFAULT_ID)
	_ghost = PlacementGhost.new()
	_ghost.name = "PlacementGhost"
	add_child(_ghost)
	_ghost.bind(_bus, _catalog, _furniture_view, t)
	_overlay = CoverageOverlay.new()
	_overlay.name = "CoverageOverlay"
	add_child(_overlay)
	_overlay.bind(_bus, t)
	_palette = (load(BUILD_PALETTE_SCENE) as PackedScene).instantiate() as BuildPalette
	add_child(_palette)
	_palette.bind(_bus, _catalog, _ghost, _overlay)
	cursor.hovered_tile_changed.connect(_ghost.on_cursor_hover)
	if _placeholders != null:
		_placeholders.visible = false
	if preset_id == BuildPreset.BASELINE:
		var placed: Array[Dictionary] = BuildPreset.placed_payloads(_catalog, BuildPreset.BASELINE_LAYOUT_ID)
		for p: Dictionary in placed:
			_furniture_view.on_placed(p)
		_overlay.on_coverage_changed(BuildPreset.coverage_payload(_catalog, placed, BuildPreset.BASELINE_LAYOUT_ID))
		_overlay.set_mode(BuildPreset.BASELINE_OVERLAY_MODE)
	return true


## SE-038: 군중·스포트를 붙이고 CrowdPreset 을 넣는다. raw = --se-crowd-preset 값. 틀리면 push_error 후 false.
## 이미 붙어 있으면 false. 배치 UI 가 없으면 baseline 을 먼저 붙인다.
func setup_crowd(raw: String) -> bool:
	if _crowd_view != null:
		push_warning("GridSandbox: 군중이 이미 있다")
		return false
	var data: CrowdData = CrowdData.load_default()
	if data == null:
		return false
	var n: int = CrowdPreset.parse_count(raw, data.max_agents)
	if n < 0:
		push_error("GridSandbox: 군중 프리셋 '%s' 는 1..%d 정수여야 한다" % [raw, data.max_agents])
		return false
	if _bus == null and not setup_build(BuildPreset.BASELINE):
		return false
	var t: float = grid.get_tile_size_m()
	_crowd_view = CrowdView.new()
	_crowd_view.name = "CrowdView"
	add_child(_crowd_view)
	if not _crowd_view.bind(_bus, _catalog, data):
		return false
	_crowd_view.set_material_id(_material_id if not _material_id.is_empty() else ShaderVariants.DEFAULT_ID)
	_stage_lights = StageLights.new()
	_stage_lights.name = "StageLights"
	add_child(_stage_lights)
	_stage_lights.bind(_bus, _catalog, t)
	# 가구: 배치 프리셋의 배치(baseline 이면 기준 배치 6) + 조명 가구(CrowdPreset).
	var placed: Array[Dictionary] = []
	if _build_preset == BuildPreset.BASELINE:
		placed = BuildPreset.placed_payloads(_catalog, BuildPreset.BASELINE_LAYOUT_ID)
	var stage: Dictionary = {}
	for p: Dictionary in placed:
		var st: Dictionary = StageGeometry.from_placed(_catalog, p)
		if not st.is_empty():
			stage = st
	var params: CrowdViewParams = _crowd_view.params
	placed.append_array(CrowdPreset.light_payloads(_catalog, stage, _stage_lights.params.max_spots,
		params.preset_light_offset_cells, placed.size() + 1))
	for p: Dictionary in placed:
		if _furniture_view.get_instance(str(p["entity_id"])).is_empty():
			_furniture_view.on_placed(p)
		_crowd_view.on_placed(p)
		_stage_lights.on_placed(p)
	var viewing: Array = BuildPreset.coverage_payload(_catalog, placed).get("viewing_tiles", []) as Array
	var focus: Vector2i = IsoGridMath.INVALID_TILE
	if not stage.is_empty():
		focus = StageGeometry.focus_cell(stage["footprint"], stage["cell"], stage["rotation"])
	var moved: Dictionary = CrowdPreset.agents_payload(data, viewing, focus, n, params.preset_seed, 0)
	_crowd_view.on_agent_moved(moved)
	_stage_lights.on_show_started(CrowdPreset.show_started_payload((moved["agents"] as Array).size()))
	_overlay.set_mode(CoverageOverlay.MODE_OFF)
	return true


func get_crowd_view() -> CrowdView:
	return _crowd_view


func get_stage_lights() -> StageLights:
	return _stage_lights


func get_build_preset() -> String:
	return _build_preset


func get_event_bus() -> EventBus:
	return _bus


func get_furniture_view() -> FurnitureView:
	return _furniture_view


func get_placement_ghost() -> PlacementGhost:
	return _ghost


func get_coverage_overlay() -> CoverageOverlay:
	return _overlay


func get_build_palette() -> BuildPalette:
	return _palette


## SE-004: --se-zoom=<인덱스> 가 있으면 시작 줌을 바꾼다. 범위 밖·숫자 아님이면 push_warning 후 기본 줌 유지.
## 적용했으면 true.
func apply_zoom_args(user_args: PackedStringArray) -> bool:
	for a: String in user_args:
		if not a.begins_with(ZOOM_ARG):
			continue
		var raw: String = a.trim_prefix(ZOOM_ARG).strip_edges()
		var count: int = iso_camera.get_zoom_level_count()
		if not raw.is_valid_int() or raw.to_int() < 0 or raw.to_int() >= count:
			push_warning("GridSandbox: %s%s 무시 (0..%d), 기본 줌 유지" % [ZOOM_ARG, raw, count - 1])
			return false
		iso_camera.set_zoom_index(raw.to_int())
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(InputActions.CAMERA_ROTATE_CW):
		iso_camera.rotate_cw()
	elif event.is_action_pressed(InputActions.CAMERA_ROTATE_CCW):
		iso_camera.rotate_ccw()
	elif event.is_action_pressed(InputActions.CAMERA_ZOOM_IN):
		iso_camera.zoom_in()
	elif event.is_action_pressed(InputActions.CAMERA_ZOOM_OUT):
		iso_camera.zoom_out()
	elif event is InputEventMouseMotion and Input.is_action_pressed(InputActions.CAMERA_PAN_DRAG):
		_drag_pan(event as InputEventMouseMotion)
	elif _placeholders != null:
		# 시안 전환은 플레이스홀더가 있을 때만(_ready 가 항상 만든다. 시작 전 입력 방어).
		for i: int in range(InputActions.SHADER_VARIANT_ACTIONS.size()):
			if event.is_action_pressed(InputActions.SHADER_VARIANT_ACTIONS[i]):
				apply_material(ShaderVariants.SELECTABLE_IDS[i])
				break


func _process(delta: float) -> void:
	var dir: Vector2 = Input.get_vector(
		InputActions.CAMERA_PAN_LEFT, InputActions.CAMERA_PAN_RIGHT,
		InputActions.CAMERA_PAN_UP, InputActions.CAMERA_PAN_DOWN)
	if dir != Vector2.ZERO:
		var speed: float = iso_camera.get_zoom_size() * iso_camera.params.pan_speed_screens_per_sec
		iso_camera.pan(dir * speed * delta)


## 드래그한 만큼 지면을 끌어온다: 이전/현재 마우스 위치의 지면 교점 차이만큼 피벗을 옮긴다.
func _drag_pan(motion: InputEventMouseMotion) -> void:
	var cam: Camera3D = iso_camera.get_camera()
	var prev: Vector2 = motion.position - motion.relative
	var a: Variant = IsoGridMath.ray_to_ground(cam.project_ray_origin(prev), cam.project_ray_normal(prev))
	var b: Variant = IsoGridMath.ray_to_ground(cam.project_ray_origin(motion.position), cam.project_ray_normal(motion.position))
	if a == null or b == null:
		return
	iso_camera.pan_world((a as Vector3) - (b as Vector3))


func _run_screenshot_if_requested() -> void:
	var out_path: String = ""
	var hover: Vector2i = IsoGridMath.INVALID_TILE
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with(SCREENSHOT_ARG):
			out_path = arg.trim_prefix(SCREENSHOT_ARG)
		elif arg.begins_with(HOVER_ARG):
			var parts: PackedStringArray = arg.trim_prefix(HOVER_ARG).split(",")
			if parts.size() == 2:
				hover = Vector2i(parts[0].to_int(), parts[1].to_int())
	if out_path.is_empty():
		return
	cursor.track_mouse = false
	for i: int in range(SCREENSHOT_WARMUP_FRAMES):
		await get_tree().process_frame
	if hover != IsoGridMath.INVALID_TILE:
		cursor.update_hover(iso_camera.get_camera().unproject_position(grid.tile_to_world(hover)))
	for i: int in range(SCREENSHOT_WARMUP_FRAMES):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var err: Error = img.save_png(out_path)
	print("GridSandbox: screenshot %s (%dx%d) -> %s" % [out_path, img.get_width(), img.get_height(), error_string(err)])
	get_tree().quit(0 if err == OK else 1)
