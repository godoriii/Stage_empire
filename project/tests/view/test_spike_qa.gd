extends GutTest
## SE-003 qa 추가 검증(qa 작성). 기존 test_spike_scene.gd / test_perf_stats.gd 의 빈 곳을 메운다.
## - AC2: "전부 화면 안" 검사가 실제로 밖의 인스턴스를 세는지(대조군), 화면 4변 여유를 수치로 확인,
##   군중이 화면을 실제로 채우는지(빈 화면이라 통과하는 것 방지).
## - AC5: 정렬/중복/경계값(n=1, n=101 → k=2) 추가 케이스.

const SPIKE_SCENE: String = "res://view/perf/spike_crowd.tscn"
const SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"
const TOL: float = 0.01
## 군중이 화면 가로·세로 중 적어도 한쪽의 이 비율 이상을 덮어야 "화면 가득"이라 본다.
const MIN_FILL_RATIO: float = 0.8

var _settings: SpikeConfigSet


func before_all() -> void:
	_settings = load(SETTINGS_PATH) as SpikeConfigSet


func _spawn(config_id: String = "") -> SpikeCrowd:
	var vp: SubViewport = ViewTestUtil.make_viewport(self)
	autofree(vp)
	var spike: SpikeCrowd = (load(SPIKE_SCENE) as PackedScene).instantiate() as SpikeCrowd
	spike.config_id = config_id
	vp.add_child(spike)
	return spike


func _origin(buf: PackedFloat32Array, i: int) -> Vector3:
	var o: int = i * SpikeCrowd.FLOATS_PER_INSTANCE
	return Vector3(buf[o + 3], buf[o + 7], buf[o + 11])


## 발/머리 꼭대기 중 하나라도 프러스텀 밖인 인스턴스 수(기존 테스트와 같은 판정 기준).
func _count_outside(spike: SpikeCrowd, cam: Camera3D, top_m: float) -> int:
	var mm: MultiMesh = spike.crowd.multimesh
	var buf: PackedFloat32Array = mm.buffer
	var outside: int = 0
	for i: int in range(mm.instance_count):
		var feet: Vector3 = spike.crowd.global_transform * _origin(buf, i)
		if not cam.is_position_in_frustum(feet) or not cam.is_position_in_frustum(feet + Vector3.UP * top_m):
			outside += 1
	return outside


func test_frustum_check_counts_outside_instances_when_camera_zooms_in() -> void:
	var spike: SpikeCrowd = _spawn()
	var cam: Camera3D = spike.iso_camera.get_camera()
	var top_m: float = _settings.body_height_m + _settings.head_size_m + _settings.bob_height_m
	assert_eq(_count_outside(spike, cam, top_m), 0, "최대 줌아웃: 0")
	spike.iso_camera.set_zoom_index(0)
	var n_out: int = _count_outside(spike, cam, top_m)
	assert_gt(n_out, 0, "줌인하면 같은 계수 함수가 밖의 인스턴스를 센다(대조군): %d" % n_out)
	assert_lt(n_out, spike.get_instance_count(), "중앙 일부는 여전히 안")


func test_vertical_edges_control() -> void:
	var spike: SpikeCrowd = _spawn()
	var cam: Camera3D = spike.iso_camera.get_camera()
	var half_h: float = cam.size * 0.5
	var up: Vector3 = cam.global_transform.basis.y
	var c: Vector3 = spike.get_crowd_center()
	assert_true(cam.is_position_in_frustum(c + up * half_h * 0.98), "세로 98% 안")
	assert_false(cam.is_position_in_frustum(c + up * half_h * 1.02), "세로 102% 밖")
	assert_true(cam.is_position_in_frustum(c - up * half_h * 0.98), "세로 -98% 안")
	assert_false(cam.is_position_in_frustum(c - up * half_h * 1.02), "세로 -102% 밖")


func test_screen_margins_and_fill() -> void:
	var spike: SpikeCrowd = _spawn()
	var cam: Camera3D = spike.iso_camera.get_camera()
	var rect: Rect2 = cam.get_viewport().get_visible_rect()
	assert_eq(rect.size, Vector2(ViewTestUtil.VIEWPORT_SIZE), "1080p 뷰포트")
	var top_m: float = _settings.body_height_m + _settings.head_size_m + _settings.bob_height_m
	var mm: MultiMesh = spike.crowd.multimesh
	var buf: PackedFloat32Array = mm.buffer
	var min_x: float = INF
	var max_x: float = -INF
	var min_y: float = INF
	var max_y: float = -INF
	for i: int in range(mm.instance_count):
		var feet: Vector3 = spike.crowd.global_transform * _origin(buf, i)
		for p: Vector3 in [feet, feet + Vector3.UP * top_m]:
			var s: Vector2 = cam.unproject_position(p)
			min_x = minf(min_x, s.x)
			max_x = maxf(max_x, s.x)
			min_y = minf(min_y, s.y)
			max_y = maxf(max_y, s.y)
	gut.p("화면 여유 px: 좌 %.1f 우 %.1f 상 %.1f 하 %.1f / 점유 가로 %.3f 세로 %.3f" % [
		min_x - rect.position.x, rect.end.x - max_x, min_y - rect.position.y, rect.end.y - max_y,
		(max_x - min_x) / rect.size.x, (max_y - min_y) / rect.size.y])
	assert_gte(min_x, rect.position.x, "좌")
	assert_lte(max_x, rect.end.x, "우")
	assert_gte(min_y, rect.position.y, "상")
	assert_lte(max_y, rect.end.y, "하")
	var fill: float = maxf((max_x - min_x) / rect.size.x, (max_y - min_y) / rect.size.y)
	assert_gte(fill, MIN_FILL_RATIO, "군중이 화면 한 축 이상을 %.0f%% 이상 덮는다(실제 %.3f)" % [MIN_FILL_RATIO * 100.0, fill])


func test_stats_edge_cases() -> void:
	# n = 1: 평균 = 1% low = 최대 = 25 ms → 40 fps.
	var one: PerfStats = PerfStats.from_frame_times([25.0])
	assert_almost_eq(one.avg_fps, 40.0, TOL)
	assert_almost_eq(one.p1_low_fps, 40.0, TOL)
	assert_eq(one.p1_low_count, 1)
	# n = 101: 99 × 10 ms + {40, 20}. 합 1050 ms → 평균 1050/101 = 10.3960 ms → 96.1905 fps.
	# k = ceil(1.01) = 2 → 가장 느린 {40, 20} 평균 30 ms → 33.3333 fps. 최대 40 ms.
	var base: Array = []
	for i: int in range(99):
		base.append(10.0)
	base.insert(7, 40.0)
	base.insert(50, 20.0)
	var s: PerfStats = PerfStats.from_frame_times(base)
	assert_eq(s.sample_count, 101)
	assert_almost_eq(s.avg_frame_ms, 10.3960, TOL)
	assert_almost_eq(s.avg_fps, 96.1905, TOL)
	assert_eq(s.p1_low_count, 2)
	assert_almost_eq(s.p1_low_fps, 33.3333, TOL)
	assert_almost_eq(s.max_frame_ms, 40.0, TOL)
	# 동률(중복) 프레임: 100 × 10 ms → 모두 100 fps, k = 1.
	var flat: Array = []
	for i: int in range(100):
		flat.append(10.0)
	var f: PerfStats = PerfStats.from_frame_times(flat)
	assert_almost_eq(f.avg_fps, 100.0, TOL)
	assert_almost_eq(f.p1_low_fps, 100.0, TOL)
	assert_eq(f.p1_low_count, 1)
