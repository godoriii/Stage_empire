extends GutTest
## SE-002 샌드박스 구조 검증(헤드리스라 화면 캡처 대신): 노드 트리, 초기 카메라, 액션 → 카메라 반응.

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
