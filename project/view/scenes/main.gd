class_name MainScene
extends Node3D
## SE-040: 메인 씬. GameSession 하나 + 그리드·카메라·커서(SE-002 재사용) + 가구·고스트·오버레이·팔레트(SE-037) + 군중·스포트
## (SE-038) + HUD·패널(SE-039) + SimDriver(실시간 step). 실행: godot --path project res://view/scenes/main.tscn
##
## 경계(AC1·AC-37a·AC-37b, test_view_boundary 허용 목록): sim 쪽 참조는 GameSession 하나뿐이다(BuildSystem·world 폴더 경로 0).
##   - GameSession.new() + new_game(seed) 는 core 팩토리 호출이다(세계 생성은 core 가 한다). EventBus.new() 를 부르지 않고
##     session.bus(TickLoop 버스)를 하위 뷰에 배포한다.
##   - 고스트 유효성 = Callable(session, "check_place")(build.md Q4 읽기 전용 쿼리) 주입.
##   - 상태 변경은 버스 *_requested 명령으로만. 새 게임은 session.new_game_requested {seed}(SN5 — 뷰는 다시 bind 하지 않는다),
##     불러오기는 session.load_requested(AC-36a — restore() 를 부르지 않는다).
##   - 읽기: session.hud_state()(session.loaded 뒤 HUD·리포트 현금, AC-39a), session.check_place, 섭외 패널 출처
##     (session.artist·session.artist.config·session.reputation — UiRoot sources, SE-039 인계 멤버만 읽는다).
##   - 시간: SimDriver._process → session.step(delta) 하나(원칙 2). 시작 메뉴가 떠 있는 동안은 hold(step(0.0) — 명령만 처리).
##
## 인자(-- 뒤):
##   --se-seed=<int>              새 게임 시드. 없으면 시작 시각에서 1회(0 이상, AC-39c). 메뉴·파산 화면의 "새 게임"도 이 값.
##   --se-load=<slot>             시작하자마자 session.load_requested {slot}(SN1 형식). 실패하면 시작 메뉴.
##   --se-autoplay-seconds=<s>    새 게임 + 기준 배치 + 조명 + 섭외 + 배속 3 을 자동으로 넣고 s 초 실시간으로 돌린 뒤 종료(AC7).
##                                 마감에 닿으면 다음 날을 자동 요청한다.
##   --se-screenshot=<abs.png>    캡처 후 종료. --se-capture=<evening|show>(기본 evening): 자동 배치·섭외 뒤 그 구간 진입 +
##                                 CAPTURE_OFFSET_TICKS 틱까지 고정 델타로 구동하고 시간을 멈춘 채 찍는다(AC5, 결정적).
##   --se-zoom=<0..3>             시작 줌(샌드박스와 같다).
## 인자가 없으면 시작 메뉴(새 게임·불러오기·계속)가 떠 있고, 메뉴가 닫히면 시간이 흐른다.

const SEED_ARG: String = "--se-seed="
const LOAD_ARG: String = "--se-load="
const AUTOPLAY_ARG: String = "--se-autoplay-seconds="
const SCREENSHOT_ARG: String = "--se-screenshot="
const CAPTURE_ARG: String = "--se-capture="
const ZOOM_ARG: String = "--se-zoom="
const BUILD_PALETTE_SCENE: String = "res://ui/build/build_palette.tscn"
## 캡처 시점: 구간 id(events.md 프로토콜 값) → 그 구간 진입 뒤 틱 수(표시 디버그 상수 — 게임 규칙 수치가 아니다).
## evening 300 = 개장 30초(입장 행렬이 들어오는 중), show 450 = 공연 중반.
const CAPTURE_OFFSET_TICKS: Dictionary = {"evening": 300, "show": 450}
const CAPTURE_DEFAULT: String = "evening"
## 캡처 전 렌더 안정 프레임 수(샌드박스 SCREENSHOT_WARMUP_FRAMES 와 같다).
const SCREENSHOT_WARMUP_FRAMES: int = 10
## 자동 배치에 쓰는 맵 reference_layouts id(BuildPreset 과 같은 기준 배치).
const AUTOPLAY_LAYOUT_ID: String = BuildPreset.BASELINE_LAYOUT_ID
## 자동 배속(AC4 "배속 3"). time.speed_requested 의 값 — sim 이 구간 허용(tick.md)을 판정한다.
const AUTOPLAY_SPEED: int = 3
## 구간 id(events.md 프로토콜 값).
const PHASE_CLOSE: String = "close"
## rng.gd 마스터 시드 상한(tick.md 상수 표 2^31 − 1) — 시작 시각 시드를 이 범위로 접는다.
const SEED_MASK: int = 0x7FFFFFFF
## 종료 코드: 세션 생성 실패·잘못된 인자.
const EXIT_BAD_SETUP: int = 2

@onready var grid: GridView = $GridView
@onready var cursor: TileCursor = $TileCursor
@onready var iso_camera: IsoCamera = $IsoCamera

## 테스트·도구가 _ready 전에 넣는다. 비어 있으면 OS.get_cmdline_user_args().
var boot_args: PackedStringArray = PackedStringArray()
var use_cmdline_args: bool = true
## false 면 SimDriver 가 _process 에서 돌지 않는다(헤드리스 테스트가 session.advance 로 직접 진행).
var drive_realtime: bool = true
## 세이브 폴더(비어 있으면 GameSession 기본 user://saves). 테스트가 임시 폴더를 넣는다.
var saves_dir: String = ""

var session: GameSession
var driver: SimDriver
var seed_value: int = 0

var _catalog: BuildCatalog
var _furniture_view: FurnitureView
var _ghost: PlacementGhost
var _overlay: CoverageOverlay
var _palette: BuildPalette
var _crowd_view: CrowdView
var _stage_lights: StageLights
var _ui_root: UiRoot
var _start_menu: bool = false
var _autoplay: bool = false
var _loaded_count: int = 0


func _ready() -> void:
	InputActions.register()
	InputActions.register_build()
	var args: PackedStringArray = OS.get_cmdline_user_args() if use_cmdline_args and boot_args.is_empty() else boot_args
	iso_camera.set_bounds(grid.get_extent_m())
	iso_camera.focus_on(grid.get_center_world())
	cursor.setup(iso_camera.get_camera(), grid)
	_apply_zoom_arg(args)
	seed_value = resolve_seed(args)
	if not _create_session():
		get_tree().quit(EXIT_BAD_SETUP)
		return
	if not _build_views():
		get_tree().quit(EXIT_BAD_SETUP)
		return
	# 첫 세계 초기화도 메뉴와 같은 경로(SN5): new_game_requested → session.loaded → 재발행. step(0.0) 이라 시간은 흐르지 않는다.
	session.bus.publish("session.new_game_requested", {"seed": seed_value})
	driver.drive(SimDriver.HOLD_DELTA_S)
	var slot: String = arg_value(args, LOAD_ARG)
	var shot: String = arg_value(args, SCREENSHOT_ARG)
	var autoplay_s: String = arg_value(args, AUTOPLAY_ARG)
	if not slot.is_empty():
		session.bus.publish("session.load_requested", {"slot": slot})
	elif not shot.is_empty():
		_run_capture(shot, arg_value(args, CAPTURE_ARG))
	elif not autoplay_s.is_empty():
		_run_autoplay(autoplay_s)
	else:
		open_start_menu()
	driver.set_process(drive_realtime)


# --- 조립 -------------------------------------------------------------------

## 시드: --se-seed=<int> 가 있으면 그 값, 없으면 시작 시각(유닉스 초)을 SEED_MASK 로 접은 값(0 이상).
static func resolve_seed(args: PackedStringArray) -> int:
	var raw: String = arg_value(args, SEED_ARG)
	if not raw.is_empty() and raw.is_valid_int():
		return raw.to_int()
	if not raw.is_empty():
		push_warning("MainScene: %s%s is not an int, using start time" % [SEED_ARG, raw])
	return int(Time.get_unix_time_from_system()) & SEED_MASK


## 인자 prefix 의 값(없으면 "").
static func arg_value(args: PackedStringArray, prefix: String) -> String:
	for a: String in args:
		if a.begins_with(prefix):
			return a.trim_prefix(prefix).strip_edges()
	return ""


func _create_session() -> bool:
	session = GameSession.new()
	if not saves_dir.is_empty():
		session.saves_dir = saves_dir
	if not session.new_game(seed_value):
		push_error("MainScene: GameSession.new_game(%d) failed" % seed_value)
		return false
	driver = SimDriver.new()
	driver.session = session
	add_child(driver)
	return true


func _build_views() -> bool:
	_catalog = BuildCatalog.load_default()
	var crowd_data: CrowdData = CrowdData.load_default()
	if _catalog == null or crowd_data == null:
		push_error("MainScene: failed to load view data (furniture/map/audience/sim json)")
		return false
	var bus: EventBus = session.bus
	var t: float = grid.get_tile_size_m()
	_furniture_view = FurnitureView.new()
	_furniture_view.name = "FurnitureView"
	add_child(_furniture_view)
	_furniture_view.bind(bus, _catalog, t)
	_furniture_view.set_material_id(ShaderVariants.DEFAULT_ID)
	_ghost = PlacementGhost.new()
	_ghost.name = "PlacementGhost"
	add_child(_ghost)
	_ghost.bind(bus, _catalog, _furniture_view, t, Callable(session, "check_place"))
	_overlay = CoverageOverlay.new()
	_overlay.name = "CoverageOverlay"
	add_child(_overlay)
	_overlay.bind(bus, t)
	_crowd_view = CrowdView.new()
	_crowd_view.name = "CrowdView"
	add_child(_crowd_view)
	if not _crowd_view.bind(bus, _catalog, crowd_data):
		return false
	_crowd_view.set_material_id(ShaderVariants.DEFAULT_ID)
	_stage_lights = StageLights.new()
	_stage_lights.name = "StageLights"
	add_child(_stage_lights)
	_stage_lights.bind(bus, _catalog, t)
	_palette = (load(BUILD_PALETTE_SCENE) as PackedScene).instantiate() as BuildPalette
	add_child(_palette)
	_palette.bind(bus, _catalog, _ghost, _overlay)
	cursor.hovered_tile_changed.connect(_ghost.on_cursor_hover)
	_ui_root = UiRoot.new()
	add_child(_ui_root)
	var params: UiParams = UiParams.load_default().for_session(seed_value)
	_ui_root.bind(bus, UiData.load_default(), UiText.load_default(), params, {
		UiRoot.SRC_ARTIST_CONFIG: session.artist.config,
		UiRoot.SRC_ARTIST_SYSTEM: session.artist,
		UiRoot.SRC_REPUTATION: session.reputation,
	})
	_ui_root.menu_input_blocker = is_ghost_active
	_ui_root.menu.visibility_changed.connect(_on_menu_visibility_changed)
	# UiRoot 다음에 구독: session.loaded 의 패널 초기화가 끝난 뒤 sim 읽기 값으로 덮는다(AC-39a).
	bus.subscribe("session.loaded", _on_session_loaded)
	bus.subscribe("session.load_failed", _on_load_failed)
	bus.subscribe("time.phase_changed", _on_phase_changed)
	_ui_root.apply_session_state(session.hud_state())
	return true


# --- 흐름 -------------------------------------------------------------------

## 시작 메뉴: 메뉴를 열고 시간을 멈춘다(명령은 계속 처리 — 메뉴의 새 게임·불러오기). 메뉴가 닫히면 시간이 흐른다.
func open_start_menu() -> void:
	_start_menu = true
	driver.hold = true
	_ui_root.menu.open()


func is_start_menu_open() -> bool:
	return _start_menu


## 배치 고스트가 선택·철거 모드인가(Esc 는 고스트 취소가 먼저, AC-39b).
func is_ghost_active() -> bool:
	return _ghost != null and _ghost.get_mode() != PlacementGhost.Mode.NONE


func _on_menu_visibility_changed() -> void:
	if _start_menu and not _ui_root.menu.visible:
		_start_menu = false
		driver.hold = false


## session.loaded(새 게임·불러오기): HUD·리포트 현금을 sim 읽기 값으로(economy 는 재발행되지 않는다, AC-39a).
func _on_session_loaded(_p: Dictionary) -> void:
	_loaded_count += 1
	_ui_root.apply_session_state(session.hud_state())


func _on_load_failed(_p: Dictionary) -> void:
	if not _ui_root.menu.visible and _loaded_count <= 1:
		open_start_menu()


## 자동 플레이: 마감에 닿으면 다음 날(AC4 의 "마감 다음 날" 조작).
func _on_phase_changed(p: Dictionary) -> void:
	if _autoplay and str(p.get("to", "")) == PHASE_CLOSE:
		session.bus.publish("time.next_day_requested", {})


## AC4 의 명령 열(새 게임 뒤 무대·스피커 = 기준 배치, 조명, 섭외, 배속 3)을 버스에 넣는다. 처리는 다음 경계.
## with_lights = 무대 스포트용 조명 가구(CrowdPreset.light_payloads 배치 규칙, check_place 통과분만). 넣은 명령 수.
func publish_autoplay_setup(with_lights: bool = true) -> int:
	var bus: EventBus = session.bus
	var n: int = 0
	var placed: Array[Dictionary] = BuildPreset.placed_payloads(_catalog, AUTOPLAY_LAYOUT_ID)
	var stage: Dictionary = {}
	for p: Dictionary in placed:
		bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
		n += 1
		var st: Dictionary = StageGeometry.from_placed(_catalog, p)
		if not st.is_empty():
			stage = st
	if with_lights:
		var lights: Array[Dictionary] = CrowdPreset.light_payloads(_catalog, stage, _stage_lights.params.max_spots,
			_crowd_view.params.preset_light_offset_cells, placed.size() + 1)
		for p: Dictionary in lights:
			if session.check_place(str(p["furniture_id"]), BuildCatalog.to_cell(p["cell"]), int(p["rotation"])) != "":
				continue
			bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
			n += 1
	var artist_id: String = first_bookable_artist()
	if not artist_id.is_empty():
		bus.publish("artist.book_requested", {"artist_id": artist_id})
		n += 1
	bus.publish("time.speed_requested", {"speed": AUTOPLAY_SPEED})
	return n + 1


## 섭외 패널 순서에서 지금 섭외 가능한(사유 "") 첫 아티스트. 없으면 "".
func first_bookable_artist() -> String:
	for id: String in session.artist.config.artist_ids():
		if _ui_root.artist_panel.book_reason(id) == "":
			return id
	return ""


func _run_autoplay(raw: String) -> void:
	if not raw.is_valid_float() or raw.to_float() <= 0.0:
		push_error("MainScene: %s%s must be a positive number" % [AUTOPLAY_ARG, raw])
		get_tree().quit(EXIT_BAD_SETUP)
		return
	_autoplay = true
	var n: int = publish_autoplay_setup(true)
	print("MainScene: autoplay seed=%d commands=%d seconds=%s" % [seed_value, n, raw])
	get_tree().create_timer(raw.to_float()).timeout.connect(_finish_autoplay)


func _finish_autoplay() -> void:
	var s: Dictionary = session.hud_state()
	print("MainScene: autoplay done day=%d phase=%s cash=%d furniture=%d crowd=%d" % [
		int(s["day"]), str(s["phase"]), int(s["cash"]), _furniture_view.get_instance_count(),
		_crowd_view.get_visible_instance_count()])
	get_tree().quit(0)


## 캡처: 자동 배치·섭외 → 고정 델타(틱 길이)로 구간 진입 + 오프셋까지 구동 → 시간 정지 → 보간 끝(t = 1) → 찍고 종료.
func _run_capture(out_path: String, capture_raw: String) -> void:
	var target: String = capture_raw if not capture_raw.is_empty() else CAPTURE_DEFAULT
	if not CAPTURE_OFFSET_TICKS.has(target):
		push_error("MainScene: %s%s unknown (%s)" % [CAPTURE_ARG, target, ", ".join(CAPTURE_OFFSET_TICKS.keys())])
		get_tree().quit(EXIT_BAD_SETUP)
		return
	driver.hold = false
	publish_autoplay_setup(target != CAPTURE_DEFAULT)
	var ticks: int = run_until_phase(target, int(CAPTURE_OFFSET_TICKS[target]))
	driver.hold = true
	_crowd_view.advance_display(_crowd_view.get_tick_len_sec())
	cursor.track_mouse = false
	for i: int in range(SCREENSHOT_WARMUP_FRAMES):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var err: Error = img.save_png(out_path)
	var s: Dictionary = session.hud_state()
	print("MainScene: capture %s ticks=%d day=%d phase=%s crowd=%d spots=%d -> %s (%dx%d) %s" % [target, ticks, int(s["day"]),
		str(s["phase"]), _crowd_view.get_visible_instance_count(), _stage_lights.get_active_spot_count(), out_path,
		img.get_width(), img.get_height(), error_string(err)])
	get_tree().quit(0 if err == OK else 1)


## 고정 델타(틱 길이)로 SimDriver 를 돌려 구간 phase 에 들어간 뒤 offset 틱을 더 진행한다(결정적 — 실시간 무관).
## 처리한 틱 수. close 에 막히면(공연 구간이 지나도 목표 구간이 오지 않으면) 거기서 멈춘다.
func run_until_phase(phase: String, offset: int) -> int:
	var dt: float = _crowd_view.get_tick_len_sec()
	var total: int = 0
	var since: int = -1
	while true:
		var cur: String = str(session.hud_state()["phase"])
		if cur == phase and since < 0:
			since = 0
		if since >= offset or cur == PHASE_CLOSE:
			break
		var done: int = driver.drive(dt)
		if done == 0:
			break                                    # 일시정지·hold — 더 진행하지 않는다
		total += done
		if since >= 0:
			since += done
	return total


# --- 조회(테스트) -----------------------------------------------------------

func get_furniture_view() -> FurnitureView:
	return _furniture_view


func get_placement_ghost() -> PlacementGhost:
	return _ghost


func get_coverage_overlay() -> CoverageOverlay:
	return _overlay


func get_build_palette() -> BuildPalette:
	return _palette


func get_crowd_view() -> CrowdView:
	return _crowd_view


func get_stage_lights() -> StageLights:
	return _stage_lights


func get_ui_root() -> UiRoot:
	return _ui_root


# --- 카메라 입력(샌드박스와 같다, 게임 상태 아님) ------------------------------

func _apply_zoom_arg(args: PackedStringArray) -> void:
	var raw: String = arg_value(args, ZOOM_ARG)
	if raw.is_empty():
		return
	if not raw.is_valid_int() or raw.to_int() < 0 or raw.to_int() >= iso_camera.get_zoom_level_count():
		push_warning("MainScene: %s%s ignored (0..%d)" % [ZOOM_ARG, raw, iso_camera.get_zoom_level_count() - 1])
		return
	iso_camera.set_zoom_index(raw.to_int())


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


## 카메라 패닝만(표시 상태). 게임 상태는 SimDriver 가 step 으로만 진행한다.
func _process(delta: float) -> void:
	var dir: Vector2 = Input.get_vector(
		InputActions.CAMERA_PAN_LEFT, InputActions.CAMERA_PAN_RIGHT,
		InputActions.CAMERA_PAN_UP, InputActions.CAMERA_PAN_DOWN)
	if dir != Vector2.ZERO:
		var speed: float = iso_camera.get_zoom_size() * iso_camera.params.pan_speed_screens_per_sec
		iso_camera.pan(dir * speed * delta)


func _drag_pan(motion: InputEventMouseMotion) -> void:
	var cam: Camera3D = iso_camera.get_camera()
	var prev: Vector2 = motion.position - motion.relative
	var a: Variant = IsoGridMath.ray_to_ground(cam.project_ray_origin(prev), cam.project_ray_normal(prev))
	var b: Variant = IsoGridMath.ray_to_ground(cam.project_ray_origin(motion.position), cam.project_ray_normal(motion.position))
	if a == null or b == null:
		return
	iso_camera.pan_world((a as Vector3) - (b as Vector3))
