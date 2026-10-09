extends GutTest
## SE-002 AC1~AC4: IsoCamera 직교·고정 각도, 90° 회전, 4단계 줌, 팬 클램프.

const PARAMS_PATH: String = "res://view/camera/iso_camera_params.tres"
const ANGLE_TOL_DEG: float = 0.5
const EPS: float = 0.0001

var _vp: SubViewport
var _cam: IsoCamera


func before_each() -> void:
	_vp = ViewTestUtil.make_viewport(self)
	autofree(_vp)
	_cam = ViewTestUtil.make_camera(_vp)


func _yaw_set() -> Array[float]:
	var base: float = _cam.params.base_yaw_deg
	var out: Array[float] = []
	for i: int in 4:
		out.append(fposmod(base + 90.0 * i, 360.0))
	return out


func test_orthographic_and_fixed_angles() -> void:
	var cam3d: Camera3D = _cam.get_camera()
	assert_not_null(cam3d, "자식 Camera3D 가 있다")
	assert_eq(cam3d.projection, Camera3D.PROJECTION_ORTHOGONAL, "직교 투영")
	assert_eq(_cam.params.resource_path, PARAMS_PATH, "값은 iso_camera_params.tres 에서 읽는다")
	var params: IsoCameraParams = load(PARAMS_PATH) as IsoCameraParams
	assert_almost_eq(params.pitch_deg, -30.0, ANGLE_TOL_DEG, "tres 피치 −30°")
	assert_almost_eq(params.base_yaw_deg, 45.0, ANGLE_TOL_DEG, "tres 요 45°")
	var py: Vector2 = ViewTestUtil.camera_pitch_yaw_deg(cam3d)
	assert_almost_eq(py.x, -30.0, ANGLE_TOL_DEG, "실제 카메라 피치 −30° ±0.5°")
	assert_almost_eq(py.y, 45.0, ANGLE_TOL_DEG, "실제 카메라 요 45° ±0.5°")
	assert_almost_eq(_cam.get_yaw_deg(), 45.0, EPS, "get_yaw_deg 초기값")
	# 카메라는 피벗을 바라본다: 피벗→카메라 방향이 카메라 뒤(+Z)와 같다.
	var to_cam: Vector3 = (cam3d.global_position - _cam.global_position).normalized()
	assert_almost_eq(to_cam.dot(cam3d.global_transform.basis.z), 1.0, EPS, "카메라가 피벗을 향한다")


func test_rotate_90_degree_steps_only() -> void:
	var allowed: Array[float] = _yaw_set()
	var pitch0: float = ViewTestUtil.camera_pitch_yaw_deg(_cam.get_camera()).x
	var prev: float = _cam.get_yaw_deg()
	for i: int in 4:
		_cam.rotate_cw()
		var yaw: float = _cam.get_yaw_deg()
		assert_almost_eq(fposmod(yaw - prev, 360.0), 90.0, EPS, "rotate_cw 는 정확히 +90° (%d회)" % (i + 1))
		assert_true(_in_set(yaw, allowed), "요 %f 는 {45,135,225,315} 중 하나" % yaw)
		var py: Vector2 = ViewTestUtil.camera_pitch_yaw_deg(_cam.get_camera())
		assert_almost_eq(ViewTestUtil.angle_diff_deg(py.y, yaw), 0.0, EPS, "실제 카메라 요 = get_yaw_deg")
		assert_almost_eq(py.x, pitch0, EPS, "회전 중 피치 불변")
		prev = yaw
	assert_almost_eq(_cam.get_yaw_deg(), 45.0, EPS, "rotate_cw 4회 후 원위치")
	assert_eq(_cam.get_yaw_step(), 0)
	for i: int in 4:
		_cam.rotate_ccw()
		var yaw: float = _cam.get_yaw_deg()
		assert_almost_eq(fposmod(prev - yaw, 360.0), 90.0, EPS, "rotate_ccw 는 정확히 −90° (%d회)" % (i + 1))
		assert_true(_in_set(yaw, allowed), "요 %f 는 허용 집합 안" % yaw)
		assert_almost_eq(ViewTestUtil.camera_pitch_yaw_deg(_cam.get_camera()).x, pitch0, EPS, "피치 불변")
		prev = yaw
	assert_almost_eq(_cam.get_yaw_deg(), 45.0, EPS, "rotate_ccw 4회 후 원위치")


func test_zoom_four_levels_clamped() -> void:
	var sizes: PackedFloat32Array = _cam.params.zoom_sizes
	assert_eq(sizes.size(), 4, "줌 4단계")
	for i: int in range(1, sizes.size()):
		assert_gt(sizes[i], sizes[i - 1], "size 엄격히 증가 (%d)" % i)
	var cam3d: Camera3D = _cam.get_camera()
	assert_true(sizes.has(cam3d.size), "초기 size 는 4개 값 중 하나")
	for i: int in 6:
		_cam.zoom_in()
		assert_true(sizes.has(cam3d.size), "zoom_in 후 size 는 4개 값 중 하나")
	assert_eq(_cam.get_zoom_index(), 0)
	assert_eq(cam3d.size, sizes[0], "최소 단계")
	_cam.zoom_in()
	assert_eq(cam3d.size, sizes[0], "최소 단계에서 zoom_in 은 불변")
	var seen: Array[float] = [cam3d.size]
	for i: int in 6:
		_cam.zoom_out()
		assert_true(sizes.has(cam3d.size), "zoom_out 후 size 는 4개 값 중 하나")
		if not seen.has(cam3d.size):
			seen.append(cam3d.size)
	assert_eq(seen.size(), 4, "4단계를 모두 지난다")
	assert_eq(_cam.get_zoom_index(), 3)
	assert_eq(cam3d.size, sizes[3], "최대 단계")
	_cam.zoom_out()
	assert_eq(cam3d.size, sizes[3], "최대 단계에서 zoom_out 은 불변")


func test_zoom_level_count_not_four_is_error() -> void:
	var bad: IsoCameraParams = (load(PARAMS_PATH) as IsoCameraParams).duplicate() as IsoCameraParams
	bad.zoom_sizes = PackedFloat32Array([5.0, 10.0, 20.0])
	assert_false(bad.validate(), "3단계는 거부")
	assert_push_error("zoom_sizes")
	var five: IsoCameraParams = bad.duplicate() as IsoCameraParams
	five.zoom_sizes = PackedFloat32Array([5.0, 10.0, 20.0, 30.0, 40.0])
	assert_false(five.validate(), "5단계는 거부")
	assert_push_error("zoom_sizes")
	var unsorted: IsoCameraParams = bad.duplicate() as IsoCameraParams
	unsorted.zoom_sizes = PackedFloat32Array([5.0, 20.0, 10.0, 30.0])
	assert_false(unsorted.validate(), "증가하지 않으면 거부")
	assert_push_error("엄격히 증가")
	# 카메라에 잘못된 params 를 주면 초기화 시 push_error.
	var cam: IsoCamera = IsoCamera.new()
	cam.params = bad
	_vp.add_child(cam)
	assert_push_error("zoom_sizes")
	assert_true((load(PARAMS_PATH) as IsoCameraParams).validate(), "기본 tres 는 유효")


func test_pan_clamped_to_grid() -> void:
	var math: IsoGridMath = GridDataLoader.load_grid_math("tier_1")
	var extent: Vector2 = math.get_extent_m()
	var margin: float = _cam.params.pan_margin_m
	_cam.set_bounds(extent)
	_cam.focus_on(Vector3(extent.x * 0.5, 0.0, extent.y * 0.5))
	var y0: float = _cam.position.y

	# 작은 팬은 화면 축을 따라 지면에서만 정확히 그 거리만큼 움직인다.
	var before: Vector3 = _cam.position
	_cam.pan(Vector2(1.0, 0.0))
	var moved: Vector3 = _cam.position - before
	assert_almost_eq(moved.length(), 1.0, EPS, "pan(1,0) 은 1m 이동")
	assert_almost_eq(moved.y, 0.0, EPS, "y 불변")
	var right_on_screen: Vector3 = _cam.get_camera().global_transform.basis.x
	assert_almost_eq(moved.normalized().dot(right_on_screen), 1.0, EPS, "화면 오른쪽 = 카메라 오른쪽")

	for r: int in 4:
		_cam.pan(Vector2(1e6, 1e6))
		assert_lte(_cam.position.x, extent.x + margin + EPS, "x ≤ grid + margin (요 %d)" % r)
		assert_lte(_cam.position.z, extent.y + margin + EPS, "z ≤ grid + margin (요 %d)" % r)
		assert_gte(_cam.position.x, -margin - EPS)
		assert_gte(_cam.position.z, -margin - EPS)
		assert_eq(_cam.position.y, y0, "y 불변")
		_cam.pan(Vector2(-1e6, -1e6))
		assert_gte(_cam.position.x, -margin - EPS, "x ≥ −margin (요 %d)" % r)
		assert_gte(_cam.position.z, -margin - EPS, "z ≥ −margin (요 %d)" % r)
		assert_lte(_cam.position.x, extent.x + margin + EPS)
		assert_lte(_cam.position.z, extent.y + margin + EPS)
		assert_eq(_cam.position.y, y0, "y 불변")
		_cam.rotate_cw()

	_cam.pan_world(Vector3(1e6, 50.0, 1e6))
	assert_eq(_cam.position, Vector3(extent.x + margin, y0, extent.y + margin), "모서리로 클램프, y 무시")


func _in_set(v: float, allowed: Array[float]) -> bool:
	for a: float in allowed:
		if ViewTestUtil.angle_diff_deg(v, a) < EPS:
			return true
	return false
