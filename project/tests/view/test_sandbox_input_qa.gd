extends GutTest
## SE-002 qa 추가 테스트: 티켓 "수동 확인 절차" 중 헤드리스로 확인 가능한 부분.
## - 키보드(액션) 팬이 _process 로 지면에서만 움직이고 그리드+margin 에서 멈춘다(수동 5번)
## - 그리드 밖 호버 시 HUD 가 "-" 를 표시하고 안으로 돌아오면 좌표를 표시한다(수동 2번)
## - 회전·줌·팬 이후에도 호버 타일이 투영한 타일과 일치한다(수동 6번)

const SANDBOX_SCENE: String = "res://view/scenes/grid_sandbox.tscn"
const EPS: float = 0.0001

var _sandbox: GridSandbox


func before_each() -> void:
	_sandbox = (load(SANDBOX_SCENE) as PackedScene).instantiate() as GridSandbox
	add_child_autofree(_sandbox)


func after_each() -> void:
	for a: StringName in InputActions.ALL:
		Input.action_release(a)


func test_keyboard_pan_moves_on_ground_and_clamps() -> void:
	var cam: IsoCamera = _sandbox.iso_camera
	var y0: float = cam.position.y
	var start: Vector3 = cam.position
	Input.action_press(InputActions.CAMERA_PAN_RIGHT)
	_sandbox._process(0.1)
	var moved: Vector3 = cam.position - start
	assert_gt(moved.length(), 0.0, "camera_pan_right 로 피벗이 움직인다")
	assert_almost_eq(moved.y, 0.0, EPS, "지면에서만")
	assert_almost_eq(moved.normalized().dot(cam.get_camera().global_transform.basis.x), 1.0, 0.001, "화면 오른쪽")
	var expected_len: float = cam.get_zoom_size() * cam.params.pan_speed_screens_per_sec * 0.1
	assert_almost_eq(moved.length(), expected_len, 0.001, "속도 = 줌 size x pan_speed x dt")
	Input.action_release(InputActions.CAMERA_PAN_RIGHT)

	# 4방향 x 오래 눌러도 경계를 넘지 않는다.
	var lo: Vector2 = cam.get_pan_min()
	var hi: Vector2 = cam.get_pan_max()
	for r: int in 4:
		for action: StringName in [InputActions.CAMERA_PAN_RIGHT, InputActions.CAMERA_PAN_DOWN,
				InputActions.CAMERA_PAN_LEFT, InputActions.CAMERA_PAN_UP]:
			Input.action_press(action)
			for i: int in 200:
				_sandbox._process(0.5)
			Input.action_release(action)
			assert_between(cam.position.x, lo.x - EPS, hi.x + EPS, "x 경계 (요 %d, %s)" % [r, action])
			assert_between(cam.position.z, lo.y - EPS, hi.y + EPS, "z 경계 (요 %d, %s)" % [r, action])
			assert_eq(cam.position.y, y0, "y 불변")
		cam.rotate_cw()


func test_hud_dash_outside_and_coords_inside() -> void:
	var cam3d: Camera3D = _sandbox.iso_camera.get_camera()
	_sandbox.cursor.update_hover(cam3d.unproject_position(_sandbox.grid.tile_to_world(Vector2i(7, 9))))
	assert_string_contains(_sandbox.hud.get_text(), "타일 (x, z): 7, 9")
	_sandbox.cursor.update_hover(cam3d.unproject_position(Vector3(-5.0, 0.0, -5.0)))
	assert_string_contains(_sandbox.hud.get_text(), "타일 (x, z): -", "그리드 밖이면 HUD 가 -")
	assert_false(_sandbox.cursor.visible, "그리드 밖이면 커서 숨김")
	_sandbox.cursor.update_hover(cam3d.unproject_position(_sandbox.grid.tile_to_world(Vector2i(0, 0))))
	assert_string_contains(_sandbox.hud.get_text(), "타일 (x, z): 0, 0")


func test_hover_matches_projection_after_rotate_zoom_pan() -> void:
	var cam: IsoCamera = _sandbox.iso_camera
	var cam3d: Camera3D = cam.get_camera()
	var tiles: Array[Vector2i] = [Vector2i(3, 4), Vector2i(20, 11), Vector2i(0, 23), Vector2i(23, 0)]
	for r: int in 4:
		for z: int in cam.get_zoom_level_count():
			cam.set_zoom_index(z)
			cam.pan(Vector2(2.5, -1.5))
			for t: Vector2i in tiles:
				_sandbox.cursor.update_hover(cam3d.unproject_position(_sandbox.grid.tile_to_world(t)))
				assert_eq(_sandbox.cursor.get_hovered_tile(), t, "요 %d 줌 %d 팬 후 타일 %s" % [roundi(cam.get_yaw_deg()), z, t])
				assert_true(_sandbox.cursor.is_hovering())
		cam.rotate_cw()
