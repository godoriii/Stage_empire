extends GutTest
## SE-002 샌드박스 구조 검증(헤드리스라 화면 캡처 대신): 노드 트리, 초기 카메라, 액션 → 카메라 반응.
## SE-004 AC9: --se-zoom=<0..3> 시작 줌 인덱스.

const SANDBOX_SCENE: String = "res://view/scenes/grid_sandbox.tscn"
const EPS: float = 0.0001

var _sandbox: GridSandbox


func before_each() -> void:
	_sandbox = (load(SANDBOX_SCENE) as PackedScene).instantiate() as GridSandbox
	add_child_autofree(_sandbox)


func _press(action: StringName) -> void:
	var ev: InputEventAction = InputEventAction.new()
	ev.action = action
	ev.pressed = true
	_sandbox._unhandled_input(ev)


func test_scene_tree_structure() -> void:
	assert_not_null(_sandbox, "샌드박스 루트는 GridSandbox")
	assert_true(_sandbox.get_node(^"GridView") is GridView)
	assert_true(_sandbox.get_node(^"TileCursor") is TileCursor)
	assert_true(_sandbox.get_node(^"IsoCamera") is IsoCamera)
	assert_true(_sandbox.get_node(^"IsoCamera/Camera3D") is Camera3D)
	assert_true(_sandbox.get_node(^"DebugHud") is DebugHud)
	assert_true(_sandbox.get_node(^"WorldEnvironment") is WorldEnvironment)
	assert_true(_sandbox.get_node(^"Sun") is DirectionalLight3D)
	assert_true(_sandbox.iso_camera.get_camera().current, "샌드박스 카메라가 현재 카메라")


func test_initial_view() -> void:
	var grid: GridView = _sandbox.grid
	var cam: IsoCamera = _sandbox.iso_camera
	assert_eq(grid.get_grid_size(), Vector2i.ONE * ViewTestUtil.expected_grid_size("tier_1"), "티어 1 그리드")
	assert_true(cam.position.is_equal_approx(grid.get_center_world()), "피벗은 그리드 중심")
	assert_almost_eq(cam.get_yaw_deg(), 45.0, EPS)
	assert_eq(cam.get_zoom_index(), cam.params.default_zoom_index)
	assert_eq(cam.get_pan_max(), grid.get_extent_m() + Vector2.ONE * cam.params.pan_margin_m, "팬 경계 = 그리드 + margin")
	for a: StringName in InputActions.ALL:
		assert_true(InputMap.has_action(a), "샌드박스가 %s 를 등록" % a)
	assert_string_contains(_sandbox.hud.get_text(), "타일 (x, z)")
	assert_string_contains(_sandbox.hud.get_text(), "요 45°")


func test_actions_drive_camera() -> void:
	var cam: IsoCamera = _sandbox.iso_camera
	_press(InputActions.CAMERA_ROTATE_CW)
	assert_almost_eq(cam.get_yaw_deg(), 135.0, EPS, "camera_rotate_cw → +90°")
	_press(InputActions.CAMERA_ROTATE_CCW)
	_press(InputActions.CAMERA_ROTATE_CCW)
	assert_almost_eq(cam.get_yaw_deg(), 315.0, EPS, "camera_rotate_ccw ×2 → −180°")
	var z0: int = cam.get_zoom_index()
	_press(InputActions.CAMERA_ZOOM_IN)
	assert_eq(cam.get_zoom_index(), maxi(z0 - 1, 0), "camera_zoom_in")
	_press(InputActions.CAMERA_ZOOM_OUT)
	_press(InputActions.CAMERA_ZOOM_OUT)
	assert_eq(cam.get_zoom_index(), mini(z0 + 1, cam.get_zoom_level_count() - 1), "camera_zoom_out")
	assert_string_contains(_sandbox.hud.get_text(), "요 315°", "HUD 가 카메라 변화를 따른다")


func test_drag_pan_keeps_ground_point_under_mouse() -> void:
	var cam3d: Camera3D = _sandbox.iso_camera.get_camera()
	var start: Vector2 = cam3d.unproject_position(_sandbox.grid.tile_to_world(Vector2i(8, 8)))
	var before: Variant = IsoGridMath.ray_to_ground(cam3d.project_ray_origin(start), cam3d.project_ray_normal(start))
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.relative = Vector2(40.0, -25.0)
	motion.position = start + motion.relative
	_sandbox._drag_pan(motion)
	var after: Variant = IsoGridMath.ray_to_ground(cam3d.project_ray_origin(motion.position), cam3d.project_ray_normal(motion.position))
	assert_true((after as Vector3).is_equal_approx(before as Vector3), "드래그 후 같은 지면 점이 마우스 아래에 있다")
	assert_eq(_sandbox.iso_camera.position.y, 0.0, "피벗 y 불변")


func test_se_zoom_arg_sets_zoom_index() -> void:
	var cam: IsoCamera = _sandbox.iso_camera
	var default_index: int = cam.params.default_zoom_index
	assert_false(_sandbox.apply_zoom_args(PackedStringArray(["--material=a"])), "--se-zoom 없으면 그대로")
	assert_eq(cam.get_zoom_index(), default_index)
	assert_true(_sandbox.apply_zoom_args(PackedStringArray(["--material=b", "--se-zoom=0"])), "--se-zoom=0 적용")
	assert_eq(cam.get_zoom_index(), 0, "줌 인덱스 0")
	assert_almost_eq(cam.get_camera().size, cam.params.zoom_sizes[0], EPS, "size = iso_camera_params.tres 의 첫 값")
	assert_string_contains(_sandbox.hud.get_text(), "줌 1/4", "HUD 가 따른다")
	# 범위 밖·숫자 아님: 기본 줌 유지 + push_warning.
	cam.set_zoom_index(default_index)
	for bad: String in ["4", "-1", "x"]:
		assert_false(_sandbox.apply_zoom_args(PackedStringArray(["--se-zoom=%s" % bad])), "--se-zoom=%s 무시" % bad)
		assert_eq(cam.get_zoom_index(), default_index, "--se-zoom=%s: 기본 줌 유지" % bad)
	assert_push_warning_count(3, "범위 밖 3건 경고")
	assert_true(_sandbox.apply_zoom_args(PackedStringArray(["--se-zoom=3"])), "최대 인덱스 3")
	assert_eq(cam.get_zoom_index(), cam.get_zoom_level_count() - 1)
