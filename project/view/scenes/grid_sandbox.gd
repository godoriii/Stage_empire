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
##   -- --material=<plain|a|b|c>(plain = SE-004 이전 정점색 룩). 키 1/2/3(shader_variant_1/2/3)으로 a/b/c 전환,
##   HUD 에 "시안: <id>". 없는 id(예전 "default" 포함)면 push_error + 종료 코드 2.
##   -- --se-zoom=<0..3> 은 시작 줌 인덱스(0 = 최근접). 범위 밖이면 push_warning 후 기본 줌 유지.

const SCREENSHOT_ARG: String = "--se-screenshot="
const HOVER_ARG: String = "--se-hover="
const ZOOM_ARG: String = "--se-zoom="
const PLACEHOLDERS_SCENE: String = "res://view/scenes/shader_placeholders.tscn"
## 종료 코드: 없는 시안 id(SpikeMeasure.EXIT_BAD_SETUP 과 같은 값).
const EXIT_BAD_MATERIAL: int = 2
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
	if ShaderVariants.apply(self, wanted, excluded) < 0:
		return false
	_material_id = wanted
	hud.set_shader_variant(wanted)
	return true


## 현재 시안 id(_ready 뒤에는 항상 유효한 id. 인자가 없으면 ShaderVariants.DEFAULT_ID).
func get_material_id() -> String:
	return _material_id


func get_placeholders() -> ShaderPlaceholders:
	return _placeholders


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
