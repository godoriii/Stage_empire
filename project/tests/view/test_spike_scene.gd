extends GutTest
## SE-003 AC1~AC4: 스파이크 씬 구조(인스턴스·라이트·셰도우 수 = 설정값, 메시 삼각형 예산, 카메라),
## 가시성(최대 줌아웃에서 전 인스턴스가 프러스텀 안), 인스턴스·라이트 애니메이션.
## 헤드리스라 RenderingServer 는 더미지만 MultiMesh.buffer 는 그대로 돌려준다 → 버퍼를 직접 해석해 검사한다.

const SPIKE_SCENE: String = "res://view/perf/spike_crowd.tscn"
const SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"
## style-guide: 캐릭터 ≤ 800 tri (인스턴싱 대상).
const CHARACTER_TRI_BUDGET: int = 800
const ANIM_FRAMES: int = 60
const MOVED_RATIO_MIN: float = 0.99
const LIGHT_MOVE_MIN_M: float = 0.01
const FLOAT_EPS: float = 1e-6
const ANGLE_TOL_DEG: float = 0.5

var _settings: SpikeConfigSet


func before_all() -> void:
	_settings = load(SETTINGS_PATH) as SpikeConfigSet


## 1080p SubViewport 안에 스파이크 씬을 띄운다. config_id 가 비면 기본 구성(B).
func _spawn(config_id: String = "") -> SpikeCrowd:
	var vp: SubViewport = ViewTestUtil.make_viewport(self)
	autofree(vp)
	var spike: SpikeCrowd = (load(SPIKE_SCENE) as PackedScene).instantiate() as SpikeCrowd
	spike.config_id = config_id
	vp.add_child(spike)
	return spike


## MultiMesh 버퍼(행 우선 3×4 + 색 4) → 인스턴스 i 의 Transform3D.
func _instance_xform(buf: PackedFloat32Array, i: int) -> Transform3D:
	var o: int = i * SpikeCrowd.FLOATS_PER_INSTANCE
	var basis: Basis = Basis(
		Vector3(buf[o], buf[o + 4], buf[o + 8]),
		Vector3(buf[o + 1], buf[o + 5], buf[o + 9]),
		Vector3(buf[o + 2], buf[o + 6], buf[o + 10]))
	return Transform3D(basis, Vector3(buf[o + 3], buf[o + 7], buf[o + 11]))


func _lights_in_tree(spike: SpikeCrowd) -> Array[Light3D]:
	var out: Array[Light3D] = []
	for n: Node in spike.find_children("*", "Light3D", true, false):
		out.append(n as Light3D)
	return out


func _count_outside_frustum(spike: SpikeCrowd, cam: Camera3D, top_m: float) -> int:
	var mm: MultiMesh = spike.crowd.multimesh
	var buf: PackedFloat32Array = mm.buffer
	var to_world: Transform3D = spike.crowd.global_transform
	var outside: int = 0
	for i: int in range(mm.instance_count):
		var feet: Vector3 = to_world * _instance_xform(buf, i).origin
		if not cam.is_position_in_frustum(feet) or not cam.is_position_in_frustum(feet + Vector3.UP * top_m):
			outside += 1
	return outside


# --- AC1 ------------------------------------------------------------------

func test_counts_match_spec() -> void:
	var spike: SpikeCrowd = _spawn()
	var b: SpikeConfig = _settings.get_config("B")
	assert_eq(spike.config.id, "B", "인자 없으면 기본 구성 = 관문 구성 B")
	assert_false(spike.measure_mode, "테스트에서는 측정 모드가 아니다")
	assert_eq(spike.crowd.multimesh.instance_count, 5000, "AC1: instance_count == 5000")
	assert_eq(spike.crowd.multimesh.instance_count, b.instances, "= 설정값")
	assert_eq(spike.crowd.multimesh.buffer.size(), b.instances * SpikeCrowd.FLOATS_PER_INSTANCE, "버퍼 크기")
	var lights: Array[Light3D] = _lights_in_tree(spike)
	assert_eq(lights.size(), 32, "AC1: Light3D 노드 수 == 32 (씬 전체, 방향광 없음)")
	assert_eq(lights.size(), b.lights, "= 설정값")
	var shadowed: int = 0
	var omni: int = 0
	var spot: int = 0
	for l: Light3D in lights:
		if l.shadow_enabled:
			shadowed += 1
		if l is OmniLight3D:
			omni += 1
		elif l is SpotLight3D:
			spot += 1
	assert_eq(shadowed, 8, "AC1: 구성 B 셰도우 라이트 8개")
	assert_eq(shadowed, b.shadow_lights, "= 설정값")
	assert_eq(omni + spot, lights.size(), "Omni/Spot 만 쓴다")
	assert_gt(omni, 0, "Omni 포함")
	assert_gt(spot, 0, "Spot(무빙 헤드) 포함")
	assert_lte(spike.get_viewport().positional_shadow_atlas_size, 2048, "B: 셰도우 아틀라스 ≤ 2048")
	assert_eq(spike.get_viewport().positional_shadow_atlas_size, b.shadow_atlas_size)
	assert_eq(spike.crowd.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "군중이 그림자를 드리운다(셰도우 비용 포함)")


func test_counts_for_every_config() -> void:
	for id: String in ["A", "B", "C", "D"]:
		var cfg: SpikeConfig = _settings.get_config(id)
		assert_not_null(cfg, "구성 %s 존재" % id)
		var spike: SpikeCrowd = _spawn(id)
		assert_eq(spike.config.id, id)
		assert_eq(spike.get_instance_count(), cfg.instances, "%s 인스턴스 수" % id)
		assert_eq(_lights_in_tree(spike).size(), cfg.lights, "%s 라이트 수" % id)
		assert_eq(spike.get_shadow_light_count(), cfg.shadow_lights, "%s 셰도우 라이트 수" % id)
		assert_eq(spike.get_viewport().positional_shadow_atlas_size, cfg.shadow_atlas_size, "%s 아틀라스" % id)


func test_instance_mesh_within_tri_budget() -> void:
	var spike: SpikeCrowd = _spawn()
	var mesh: Mesh = spike.crowd.multimesh.mesh
	var tris: int = mesh.get_faces().size() / 3
	assert_gt(tris, 0)
	assert_lte(tris, CHARACTER_TRI_BUDGET, "AC1: 인스턴스 메시 %d tri ≤ %d" % [tris, CHARACTER_TRI_BUDGET])
	assert_eq(spike.get_instance_mesh_triangle_count(), tris)
	assert_eq(mesh.get_surface_count(), 1, "한 서피스 → MultiMesh 당 드로우 1회")
	assert_eq(spike.crowd.multimesh.transform_format, MultiMesh.TRANSFORM_3D)
	assert_true(spike.crowd.multimesh.use_colors, "인스턴스 색")


func test_camera_is_se002_iso_camera_at_max_zoom_out() -> void:
	var spike: SpikeCrowd = _spawn()
	var iso: IsoCamera = spike.iso_camera
	var cam: Camera3D = iso.get_camera()
	assert_true(spike.get_node(^"IsoCamera") is IsoCamera, "SE-002 IsoCamera 재사용")
	assert_true(spike.get_node(^"GridView") is GridView, "SE-002 GridView 재사용")
	assert_eq(cam.projection, Camera3D.PROJECTION_ORTHOGONAL, "직교")
	assert_eq(iso.get_zoom_index(), iso.get_zoom_level_count() - 1, "최대 줌아웃")
	assert_almost_eq(cam.size, iso.params.zoom_sizes[iso.params.zoom_sizes.size() - 1], 0.0001)
	var py: Vector2 = ViewTestUtil.camera_pitch_yaw_deg(cam)
	assert_lt(ViewTestUtil.angle_diff_deg(py.x, iso.params.pitch_deg), ANGLE_TOL_DEG, "피치 = SE-002 값")
	assert_lt(ViewTestUtil.angle_diff_deg(py.y, iso.params.base_yaw_deg), ANGLE_TOL_DEG, "요 = SE-002 값")
	assert_true(iso.position.is_equal_approx(spike.get_crowd_center()), "피벗 = 군중 중심")
	assert_true(spike.get_crowd_center().is_equal_approx(spike.grid.get_center_world()), "군중 중심 = 바닥 중심")


# --- AC2 ------------------------------------------------------------------

func test_all_instances_in_frustum() -> void:
	var spike: SpikeCrowd = _spawn()
	var cam: Camera3D = spike.iso_camera.get_camera()
	var top_m: float = _settings.body_height_m + _settings.head_size_m + _settings.bob_height_m
	# 검사 자체가 동작하는지: 화면 가로 절반을 살짝 넘는 점은 프러스텀 밖이어야 한다.
	var half_w: float = cam.size * float(ViewTestUtil.VIEWPORT_SIZE.x) / float(ViewTestUtil.VIEWPORT_SIZE.y) * 0.5
	var right: Vector3 = cam.global_transform.basis.x
	assert_true(cam.is_position_in_frustum(spike.get_crowd_center() + right * half_w * 0.98), "대조군: 가로 98% 지점은 안")
	assert_false(cam.is_position_in_frustum(spike.get_crowd_center() + right * half_w * 1.02), "대조군: 가로 102% 지점은 밖")
	# 배회 궤도 전체(여러 시각)와 4방향 회전 모두에서 발·머리 꼭대기가 프러스텀 안.
	var steps: int = 6
	var step_sec: float = 0.37
	for s: int in range(steps):
		for r: int in range(IsoCamera.ROTATION_STEPS):
			var outside: int = _count_outside_frustum(spike, cam, top_m)
			assert_eq(outside, 0, "AC2: 프러스텀 밖 인스턴스 0 (시각 %.2fs, 요 %.0f°)" % [spike.get_elapsed_sec(), spike.iso_camera.get_yaw_deg()])
			spike.iso_camera.rotate_cw()
		spike.advance(step_sec)


func test_all_instances_in_frustum_config_d() -> void:
	var spike: SpikeCrowd = _spawn("D")
	var cam: Camera3D = spike.iso_camera.get_camera()
	var top_m: float = _settings.body_height_m + _settings.head_size_m + _settings.bob_height_m
	assert_eq(_count_outside_frustum(spike, cam, top_m), 0, "D(10,000)도 전부 화면 안")


# --- AC3 ------------------------------------------------------------------

func test_instances_move_every_frame() -> void:
	var spike: SpikeCrowd = _spawn()
	var n: int = spike.get_instance_count()
	var before: PackedFloat32Array = spike.crowd.multimesh.buffer
	var t0: float = spike.get_elapsed_sec()
	await wait_process_frames(ANIM_FRAMES)
	assert_gt(spike.get_elapsed_sec(), t0, "_process 로 시간이 흘렀다")
	var after: PackedFloat32Array = spike.crowd.multimesh.buffer
	var moved: int = 0
	for i: int in range(n):
		if not _instance_xform(before, i).is_equal_approx(_instance_xform(after, i)):
			moved += 1
	var ratio: float = float(moved) / float(n)
	assert_gte(ratio, MOVED_RATIO_MIN, "AC3: %d 프레임 후 트랜스폼이 바뀐 인스턴스 %.4f (%d/%d) ≥ 99%%" % [ANIM_FRAMES, ratio, moved, n])


func test_interpolation_between_ticks_is_continuous() -> void:
	var spike: SpikeCrowd = _spawn()
	# 틱 경계를 여러 번 넘도록 작은 dt 로 진행하며 프레임 간 이동량이 배회 속도 상한을 넘지 않는지(튀지 않는지).
	# 60 × 1/240 s = 0.25 s → 10 Hz 틱 경계를 두 번 넘는다. 수평 속도 상한 = 배회 반지름 × 최대 각속도.
	var dt: float = 1.0 / 240.0
	var max_step: float = _settings.wander_radius_m * _settings.wander_speed_max * dt * 1.5 + FLOAT_EPS
	var prev: PackedFloat32Array = spike.crowd.multimesh.buffer
	var worst: float = 0.0
	for f: int in range(60):
		spike.advance(dt)
		var cur: PackedFloat32Array = spike.crowd.multimesh.buffer
		for i: int in range(0, spike.get_instance_count(), 97):
			var a: Vector3 = _instance_xform(prev, i).origin
			var b: Vector3 = _instance_xform(cur, i).origin
			worst = maxf(worst, Vector2(a.x - b.x, a.z - b.z).length())
		prev = cur
	assert_lte(worst, max_step, "프레임 간 수평 이동 최대 %.5f m ≤ %.5f m (틱 경계에서 튀지 않음)" % [worst, max_step])


# --- AC4 ------------------------------------------------------------------

func test_all_lights_move() -> void:
	var spike: SpikeCrowd = _spawn()
	var lights: Array[Light3D] = spike.get_light_nodes()
	assert_eq(lights.size(), 32)
	var pos0: Array[Vector3] = []
	var col0: Array[Color] = []
	for l: Light3D in lights:
		pos0.append(l.global_position)
		col0.append(l.light_color)
	await wait_process_frames(ANIM_FRAMES)
	for i: int in range(lights.size()):
		var d: float = lights[i].global_position.distance_to(pos0[i])
		assert_gte(d, LIGHT_MOVE_MIN_M, "AC4: %s 이동 %.4f m ≥ 0.01 m" % [lights[i].name, d])
		assert_false(lights[i].light_color.is_equal_approx(col0[i]), "%s 색 변화" % lights[i].name)


func test_lights_above_crowd_and_spots_aim_down() -> void:
	var spike: SpikeCrowd = _spawn()
	for l: Light3D in spike.get_light_nodes():
		assert_gt(l.global_position.y, _settings.body_height_m + _settings.head_size_m, "%s 는 캐릭터보다 높다" % l.name)
		if l is SpotLight3D:
			var dir: Vector3 = -l.global_transform.basis.z
			assert_lt(dir.y, 0.0, "%s 는 아래를 겨눈다" % l.name)


# --- 기타 -----------------------------------------------------------------

func test_resolve_config_id() -> void:
	assert_eq(SpikeCrowd.resolve_config_id("", PackedStringArray(), "B"), "B", "기본값")
	assert_eq(SpikeCrowd.resolve_config_id("", PackedStringArray(["--measure", "--config=c"]), "B"), "C", "명령줄(대소문자 무시)")
	assert_eq(SpikeCrowd.resolve_config_id("A", PackedStringArray(["--config=D"]), "B"), "A", "@export 우선")
