class_name GridSandbox
extends Node3D
## SE-002 샌드박스: 티어 1 그리드 + 아이소 카메라 + 타일 커서 + 디버그 HUD.
## SE-003(성능 스파이크), SE-004(셰이더 시안)의 공통 무대.
## 입력은 InputActions 의 액션 이름으로만 받는다. 게임 상태를 바꾸지 않으며 이벤트 버스를 쓰지 않는다.
##
## 실행: godot --path project res://view/scenes/grid_sandbox.tscn
## 스크린샷(사람 검수용): 위 명령 뒤에 -- --se-screenshot=<절대경로.png> [--se-hover=x,z]
##   (GPU/디스플레이가 있는 환경 필요. --headless 에서는 캡처가 안 된다.)

const SCREENSHOT_ARG: String = "--se-screenshot="
const HOVER_ARG: String = "--se-hover="
## 스크린샷 전 렌더가 안정될 때까지 기다리는 프레임 수(디버그 기능 전용).
const SCREENSHOT_WARMUP_FRAMES: int = 10

@onready var grid: GridView = $GridView
@onready var cursor: TileCursor = $TileCursor
@onready var iso_camera: IsoCamera = $IsoCamera
@onready var hud: DebugHud = $DebugHud


func _ready() -> void:
	InputActions.register()
	iso_camera.set_bounds(grid.get_extent_m())
	iso_camera.focus_on(grid.get_center_world())
	cursor.setup(iso_camera.get_camera(), grid)
	hud.bind(iso_camera, cursor)
	_run_screenshot_if_requested()


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
