extends GutTest
## SE-038 AC1·AC2·AC3·AC5: CrowdView — 가짜 버스에 audience.agent_moved 를 주입해 MultiMesh 인스턴스 수·보간 위치·색·
## 그림자·시안·메시 빌더·로드 복구를 검사한다. 기대값은 데이터(audience.json·sim.json)를 테스트가 직접 읽어 계산한다.
## 헤드리스라 RenderingServer 는 더미지만 MultiMesh.buffer 는 그대로 돌려준다 → 버퍼를 직접 해석한다.
## + 샌드박스 --se-crowd-preset 구조 검사.

const AUDIENCE_PATH: String = "res://data/audience/audience.json"
const SIM_PATH: String = "res://data/sim/sim.json"
const SPIKE_SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"
const SANDBOX_SCENE: String = "res://view/scenes/grid_sandbox.tscn"
## AC1 오차.
const POS_EPS: float = 1e-3
const DIR_EPS: float = 1e-3

var _bus: EventBus
var _view: CrowdView
var _aud: Dictionary
var _sim: Dictionary
var _p: int
var _t: float
var _tick_len: float


func before_each() -> void:
	_aud = ViewTestUtil.read_json(AUDIENCE_PATH) as Dictionary
	_sim = ViewTestUtil.read_json(SIM_PATH) as Dictionary
	_p = int(_aud["pos_scale"])
	_t = float(_sim["tile_size_m"])
	_tick_len = 1.0 / float(_sim["ticks_per_second"])
	_bus = EventBus.new()
	_view = CrowdView.new()
	add_child_autofree(_view)
	assert_true(_view.bind(_bus, BuildTestUtil.catalog()), "bind 성공")


func _type_ids() -> Array[String]:
	var out: Array[String] = []
	for t: Dictionary in _aud["types"]:
		out.append(str(t["id"]))
	return out


## 타일 중앙 표시 좌표(audience.md c(t)).
func _c(x: int, z: int) -> Vector2i:
	return Vector2i(x * _p + _p / 2, z * _p + _p / 2)


func _world(px: int, pz: int) -> Vector3:
	return Vector3(float(px) / _p * _t, 0.0, float(pz) / _p * _t)


## n 명 한 틱. 에이전트 i 는 타일 (i % 20 + 1 + dx, i / 20 + 1 + dz) 중앙에서 state, 유형은 types 순환.
func _tick(tick: int, n: int, dx: int, dz: int, state: String) -> Dictionary:
	var types: Array[String] = _type_ids()
	var agents: Array = []
	for i: int in range(n):
		var c: Vector2i = _c(i % 20 + 1 + dx, i / 20 + 1 + dz)
		agents.append([i + 1, c.x, c.y, state, types[i % types.size()]])
	return {"tick": tick, "agents": agents}


func _origin(slot: int) -> Vector3:
	return _view.get_slot_transform(slot).origin


## 모델 정면(−z)의 수평 방향.
func _facing(slot: int) -> Vector3:
	var f: Vector3 = -_view.get_slot_transform(slot).basis.z
	f.y = 0.0
	return f.normalized()


# --- AC1 --------------------------------------------------------------------

func test_two_ticks_instance_counts_and_midpoint_interpolation() -> void:
	var n: int = int(_aud["max_agents"])
	var a: Dictionary = _tick(1, n, 0, 0, "moving")
	var b: Dictionary = _tick(2, n, 1, 1, "moving")
	_bus.publish("audience.agent_moved", a)
	_bus.publish("audience.agent_moved", b)
	assert_eq(_view.get_instance_count(), int(_aud["max_agents"]), "instance_count = audience.json max_agents")
	assert_eq(_view.get_visible_instance_count(), n, "visible_instance_count = 활성 수")
	assert_eq(_view.get_multimesh_instance().multimesh.visible_instance_count, n, "MultiMesh 에 반영")
	assert_almost_eq(_view.get_tick_len_sec(), _tick_len, 1e-9, "틱 길이 = 1 / sim.json ticks_per_second")
	# 받은 직후(t = 0) = 직전 틱 위치.
	for i: int in [0, n / 2, n - 1]:
		var pa: Array = (a["agents"] as Array)[i]
		assert_true(_origin(_view.get_slot(i + 1)).distance_to(_world(pa[1], pa[2])) < POS_EPS, "t=0 → 직전 틱 위치 (id %d)" % (i + 1))
	# 0.5 틱 → 선형 보간 중간값.
	_view._process(_tick_len * 0.5)
	assert_almost_eq(_view.get_alpha(), 0.5, 1e-6, "t = acc / tick_len")
	var worst: float = 0.0
	for i: int in range(n):
		var pa2: Array = (a["agents"] as Array)[i]
		var pb: Array = (b["agents"] as Array)[i]
		var want: Vector3 = _world(pa2[1], pa2[2]).lerp(_world(pb[1], pb[2]), 0.5)
		worst = maxf(worst, _origin(_view.get_slot(i + 1)).distance_to(want))
	assert_lt(worst, POS_EPS, "모든 인스턴스가 중간값 (최대 오차 %f)" % worst)
	# 버퍼가 MultiMesh 에 올라갔다.
	var buf: PackedFloat32Array = _view.get_multimesh_instance().multimesh.buffer
	assert_eq(buf.size(), int(_aud["max_agents"]) * CrowdView.FLOATS_PER_INSTANCE, "버퍼 크기")
	assert_almost_eq(buf[3], _origin(0).x, 1e-5, "MultiMesh 버퍼 = 표시 값")
	# 한 틱 넘게 지나면 현재 틱 위치에서 멈춘다(clamp).
	_view._process(_tick_len * 3.0)
	var pb0: Array = (b["agents"] as Array)[0]
	assert_true(_origin(_view.get_slot(1)).distance_to(_world(pb0[1], pb0[2])) < POS_EPS, "t ≥ 1 → 현재 틱 위치")


func test_tick_length_comes_from_sim_json_not_literal() -> void:
	var sim2: Dictionary = _sim.duplicate(true)
	sim2["ticks_per_second"] = int(_sim["ticks_per_second"]) * 2
	var data: CrowdData = CrowdData.from_dicts(_aud, sim2)
	assert_not_null(data)
	var v: CrowdView = CrowdView.new()
	add_child_autofree(v)
	v.bind(_bus, null, data)
	assert_almost_eq(v.get_tick_len_sec(), _tick_len * 0.5, 1e-9, "tps ×2 → tick_len ÷2")
	v.on_agent_moved(_tick(1, 1, 0, 0, "moving"))
	v.on_agent_moved(_tick(2, 1, 2, 0, "moving"))
	v._process(_tick_len * 0.25)
	assert_almost_eq(v.get_alpha(), 0.5, 1e-6, "같은 delta 가 두 배 진행")
	var want: Vector3 = _world(_c(1, 1).x, _c(1, 1).y).lerp(_world(_c(3, 1).x, _c(3, 1).y), 0.5)
	assert_true(v.get_slot_transform(0).origin.distance_to(want) < POS_EPS, "보간 위치")


# --- AC2 --------------------------------------------------------------------

func test_type_colors_match_audience_json_alpha_one() -> void:
	var types: Array = _aud["types"]
	assert_eq(types.size(), 3, "유형 3종(audience.md)")
	_bus.publish("audience.agent_moved", _tick(1, types.size() * 2, 0, 0, "watching"))
	for i: int in range(types.size() * 2):
		var want: Color = Color.html(str((types[i % types.size()] as Dictionary)["color"]))
		var got: Color = _view.get_slot_color(_view.get_slot(i + 1))
		assert_true(Color(got.r, got.g, got.b).is_equal_approx(Color(want.r, want.g, want.b)), "id %d 유형 색 %s == %s" % [i + 1, got, want])
		assert_eq(got.a, 1.0, "알파 1.0 (M3)")
	var distinct: Dictionary = {}
	for t: Dictionary in types:
		distinct[str(t["color"])] = true
	assert_eq(distinct.size(), types.size(), "유형 색 3종이 서로 다르다")


func test_gone_is_hidden_and_visible_count_tracks_active() -> void:
	var types: Array[String] = _type_ids()
	_bus.publish("audience.agent_moved", _tick(1, 6, 0, 0, "watching"))
	assert_eq(_view.get_visible_instance_count(), 6)
	var c: Vector2i = _c(2, 2)
	var agents: Array = [
		[1, c.x, c.y, "watching", types[0]], [2, c.x, c.y, "gone", types[1]], [3, c.x, c.y, "leaving", types[2]],
		[4, c.x, c.y, "at_bar", types[0]], [5, c.x, c.y, "gone", types[1]], [6, c.x, c.y, "queued", types[2]],
	]
	_bus.publish("audience.agent_moved", {"tick": 2, "agents": agents})
	assert_eq(_view.get_visible_instance_count(), 4, "gone 2명 숨김 → 보이는 수 4")
	assert_eq(_view.get_slot(2), -1, "gone id 는 슬롯 없음")
	assert_eq(_view.get_slot(5), -1)
	var slots: Array[int] = [_view.get_slot(1), _view.get_slot(3), _view.get_slot(4), _view.get_slot(6)]
	slots.sort()
	assert_eq(slots, [0, 1, 2, 3] as Array[int], "활성 인스턴스가 앞 슬롯을 채운다(visible_instance_count 로 그려지는 칸)")
	# leaving 은 반투명이 아니라 유형 색 그대로.
	var leaving: Color = _view.get_slot_color(_view.get_slot(3))
	assert_eq(leaving.a, 1.0, "leaving 알파 1.0(반투명 금지)")
	assert_true(Color(leaving.r, leaving.g, leaving.b).is_equal_approx(Color.html(str((_aud["types"] as Array)[2]["color"]))), "leaving = 유형 색")
	# 다음 틱에 gone 은 원소가 없다.
	_bus.publish("audience.agent_moved", {"tick": 3, "agents": [agents[0], agents[2]]})
	assert_eq(_view.get_visible_instance_count(), 2)


func test_zero_agents_hides_everything() -> void:
	_bus.publish("audience.agent_moved", _tick(1, 10, 0, 0, "moving"))
	_bus.publish("audience.agent_moved", {"tick": 2, "agents": []})
	assert_eq(_view.get_visible_instance_count(), 0, "agents [] → visible 0")
	_view._process(_tick_len)
	assert_eq(_view.get_visible_instance_count(), 0)
	# 마지막 틱 전원 gone 도 0.
	var g: Dictionary = _tick(3, 5, 0, 0, "gone")
	_bus.publish("audience.agent_moved", g)
	assert_eq(_view.get_visible_instance_count(), 0, "전원 gone → 0")
	# 형식이 틀린 원소는 건너뛴다(나머지는 그린다).
	var ok: Array = (_tick(4, 1, 0, 0, "watching")["agents"] as Array)[0]
	_view.on_agent_moved({"tick": 4, "agents": [[1, 2], "x", ok]})
	assert_eq(_view.get_visible_instance_count(), 1, "형식 오류 원소 무시")


# --- AC3 --------------------------------------------------------------------

func test_shadow_off_default_material_and_shared_proxy_mesh() -> void:
	var mmi: MultiMeshInstance3D = _view.get_multimesh_instance()
	assert_eq(mmi.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "군중 cast_shadow OFF")
	assert_eq(_view.get_material_id(), ShaderVariants.DEFAULT_ID, "기본 시안 = DEFAULT_ID")
	var want_mat: ShaderMaterial = ShaderVariants.load_material(ShaderVariants.DEFAULT_ID)
	assert_not_null(mmi.material_override, "시안 머티리얼 적용")
	assert_eq((mmi.material_override as Resource).resource_path, want_mat.resource_path, "시안 B 머티리얼")
	var mm: MultiMesh = mmi.multimesh
	assert_eq(mm.transform_format, MultiMesh.TRANSFORM_3D)
	assert_true(mm.use_colors, "인스턴스 색 사용")
	# 메시 = 스파이크 프록시와 같은 빌더·같은 치수.
	var spike_set: SpikeConfigSet = load(SPIKE_SETTINGS_PATH) as SpikeConfigSet
	var spike_mesh: ArrayMesh = SpikeCrowd.build_proxy_mesh(spike_set)
	assert_eq(mm.mesh.get_surface_count(), 1, "서피스 1(base)")
	assert_eq(mm.mesh.get_faces(), spike_mesh.get_faces(), "CrowdView 메시 == SpikeCrowd.build_proxy_mesh 정점")
	var p: CrowdViewParams = _view.params
	assert_eq(p.body_radius_m, spike_set.body_radius_m)
	assert_eq(p.body_height_m, spike_set.body_height_m)
	assert_eq(p.body_radial_segments, spike_set.body_radial_segments)
	assert_eq(p.body_rings, spike_set.body_rings)
	assert_eq(p.head_size_m, spike_set.head_size_m)
	assert_eq(p.arm_size_m, spike_set.arm_size_m)
	# 시안 전환.
	assert_true(_view.set_material_id(ShaderVariants.PLAIN_ID))
	assert_null(mmi.material_override, "plain → override 없음")
	assert_false(_view.set_material_id("zzz"), "없는 시안 거부")
	assert_push_error("시안 'zzz' 없음", "push_error 1건")
	assert_eq(_view.get_material_id(), ShaderVariants.PLAIN_ID, "거부 뒤 그대로")


func test_spike_builder_delegates_to_shared_module() -> void:
	var s: SpikeConfigSet = load(SPIKE_SETTINGS_PATH) as SpikeConfigSet
	var a: ArrayMesh = SpikeCrowd.build_proxy_mesh(s)
	var b: ArrayMesh = CrowdProxyMesh.build(s.body_radius_m, s.body_height_m, s.body_radial_segments, s.body_rings, s.head_size_m, s.arm_size_m)
	assert_eq(a.get_faces(), b.get_faces(), "SpikeCrowd.build_proxy_mesh == CrowdProxyMesh.build")
	var mat: StandardMaterial3D = a.surface_get_material(0) as StandardMaterial3D
	assert_not_null(mat)
	assert_true(mat.vertex_color_use_as_albedo, "정점 색 albedo(plain 룩)")


# --- AC5 --------------------------------------------------------------------

func test_session_loaded_then_one_tick_restores_with_snap() -> void:
	var n: int = 30
	_bus.publish("audience.agent_moved", _tick(1, n, 0, 0, "moving"))
	_bus.publish("audience.agent_moved", _tick(2, n, 1, 0, "moving"))
	_view._process(_tick_len * 0.5)
	_bus.publish("session.loaded", {"day": 3})
	assert_eq(_view.get_visible_instance_count(), 0, "session.loaded → 비움")
	assert_eq(_view.get_slot(1), -1)
	# 같은 id 가 먼 곳에서 온다: 보간 없이 그 자리에 스냅.
	var c: Dictionary = _tick(500, n, 5, 6, "moving")
	_bus.publish("audience.agent_moved", c)
	assert_eq(_view.get_visible_instance_count(), n, "다음 agent_moved 1틱으로 전체 복구")
	for frac: float in [0.0, 0.5]:
		if frac > 0.0:
			_view._process(_tick_len * frac)
		var worst: float = 0.0
		for i: int in range(n):
			var e: Array = (c["agents"] as Array)[i]
			worst = maxf(worst, _origin(_view.get_slot(i + 1)).distance_to(_world(e[1], e[2])))
		assert_lt(worst, POS_EPS, "로드 뒤 첫 틱은 스냅 (t=%.1f, 최대 오차 %f)" % [frac, worst])
	# 색도 복구(유형이 원소에 있다).
	var types: Array = _aud["types"]
	var got: Color = _view.get_slot_color(_view.get_slot(1))
	assert_true(Color(got.r, got.g, got.b).is_equal_approx(Color.html(str((types[0] as Dictionary)["color"]))), "유형 색 복구")


func test_new_id_snaps_while_existing_interpolates() -> void:
	var types: Array[String] = _type_ids()
	var a: Vector2i = _c(2, 2)
	var b: Vector2i = _c(4, 2)
	_bus.publish("audience.agent_moved", {"tick": 1, "agents": [[1, a.x, a.y, "moving", types[0]]]})
	_bus.publish("audience.agent_moved", {"tick": 2, "agents": [[1, b.x, b.y, "moving", types[0]], [2, b.x, b.y, "entering", types[1]]]})
	_view._process(_tick_len * 0.5)
	assert_true(_origin(_view.get_slot(1)).distance_to(_world(a.x, a.y).lerp(_world(b.x, b.y), 0.5)) < POS_EPS, "기존 id 보간")
	assert_true(_origin(_view.get_slot(2)).distance_to(_world(b.x, b.y)) < POS_EPS, "새 id 는 첫 틱에 보간 없이")


# --- 방향 -------------------------------------------------------------------

func test_watching_faces_stage_focus_or_plus_z() -> void:
	var types: Array[String] = _type_ids()
	var at: Vector2i = Vector2i(5, 10)
	var c: Vector2i = _c(at.x, at.y)
	_bus.publish("audience.agent_moved", {"tick": 1, "agents": [[1, c.x, c.y, "watching", types[0]]]})
	assert_true(_facing(0).distance_to(Vector3.BACK) < DIR_EPS, "무대 모름 → +z")
	assert_false(_view.has_stage())
	# 기준 배치 무대(stage_small [10,20] 회전 0): 초점 g = 정면 가장자리 [10..13, 20] 의 E[⌊4/2⌋] = [12, 20].
	var stage: Dictionary = BuildTestUtil.placed("f1", "stage_small", Vector2i(10, 20), 0)
	_bus.publish("build.placed", stage)
	assert_true(_view.has_stage())
	var fp: Array = BuildTestUtil.row("stage_small")["footprint"]
	var g: Vector2i = Vector2i(10 + int(fp[0]) / 2, 20)
	assert_true((_view.get_focus_world() as Vector3).is_equal_approx(Vector3((g.x + 0.5) * _t, 0.0, (g.y + 0.5) * _t)), "초점 = g 셀 중앙")
	_bus.publish("audience.agent_moved", {"tick": 2, "agents": [[1, c.x, c.y, "watching", types[0]]]})
	_view._process(_tick_len)
	var want: Vector3 = (Vector3((g.x + 0.5) * _t, 0.0, (g.y + 0.5) * _t) - _world(c.x, c.y)).normalized()
	assert_true(_facing(0).distance_to(want) < DIR_EPS, "watching → 무대 초점 %s (got %s)" % [want, _facing(0)])
	# 다른 가구 철거는 무관, 무대 철거 → +z.
	_bus.publish("build.demolished", BuildTestUtil.demolished("f9", "bench", Vector2i(1, 1), 0))
	assert_true(_view.has_stage(), "다른 entity 철거는 무관")
	_bus.publish("build.demolished", BuildTestUtil.demolished("f1", "stage_small", Vector2i(10, 20), 0))
	_bus.publish("audience.agent_moved", {"tick": 3, "agents": [[1, c.x, c.y, "watching", types[0]]]})
	_view._process(_tick_len)
	assert_true(_facing(0).distance_to(Vector3.BACK) < DIR_EPS, "무대 철거 → +z")


func test_moving_faces_motion_and_at_bar_keeps_heading() -> void:
	var types: Array[String] = _type_ids()
	var a: Vector2i = _c(3, 3)
	var b: Vector2i = _c(4, 3)
	_bus.publish("audience.agent_moved", {"tick": 1, "agents": [[1, a.x, a.y, "moving", types[0]]]})
	_bus.publish("audience.agent_moved", {"tick": 2, "agents": [[1, b.x, b.y, "moving", types[0]]]})
	_view._process(_tick_len)
	assert_true(_facing(0).distance_to(Vector3.RIGHT) < DIR_EPS, "+x 로 이동 → +x 를 본다")
	_bus.publish("audience.agent_moved", {"tick": 3, "agents": [[1, b.x, b.y, "at_bar", types[0]]]})
	_view._process(_tick_len)
	assert_true(_facing(0).distance_to(Vector3.RIGHT) < DIR_EPS, "at_bar 정지 → 방향 유지")
	assert_true(_origin(0).distance_to(_world(b.x, b.y)) < POS_EPS, "at_bar 정지 위치")
	# 수직 축만 회전(바닥에 선다).
	var xf: Transform3D = _view.get_slot_transform(0)
	assert_true(xf.basis.y.is_equal_approx(Vector3.UP), "y 축 회전만")
	assert_eq(xf.origin.y, 0.0, "발 = 바닥")


# --- 그 밖 ------------------------------------------------------------------

func test_admissions_and_overflow_and_no_commands() -> void:
	_bus.publish("audience.admissions_decided", {"day": 1, "admissions": 83, "expected": 83, "noise_bp": 0, "capacity": 122,
		"capped_by": "none", "has_lineup": true, "by_type": {}})
	assert_eq(_view.get_admissions(), 83, "오늘 입장 수 보관(HUD 용)")
	var cap: int = int(_aud["max_agents"])
	_view.on_agent_moved(_tick(1, cap + 5, 0, 0, "moving"))
	assert_eq(_view.get_visible_instance_count(), cap, "max_agents 초과분은 그리지 않는다")
	assert_eq(_bus.get_pending_commands().size(), 0, "명령 발행 0")
	_bus.publish("session.loaded", {"day": 2})
	assert_eq(_view.get_admissions(), -1, "로드 뒤 초기화")


func test_crowd_data_rejects_bad_tables() -> void:
	var bad_sim: Dictionary = _sim.duplicate(true)
	bad_sim["ticks_per_second"] = 0
	assert_null(CrowdData.from_dicts(_aud, bad_sim), "ticks_per_second 0 거부")
	var bad_aud: Dictionary = _aud.duplicate(true)
	(bad_aud["types"] as Array)[0]["color"] = "pal_red"
	assert_null(CrowdData.from_dicts(bad_aud, _sim), "hex 아닌 색 거부")
	assert_push_error_count(2, "거부마다 push_error")
	var d: CrowdData = CrowdData.from_dicts(_aud, _sim)
	assert_eq(d.type_ids.size(), (_aud["types"] as Array).size())
	assert_eq(d.tile_center_pos(Vector2i(3, 4)), _c(3, 4), "c(t) = t × P + P/2")


# --- 샌드박스 --se-crowd-preset ----------------------------------------------

func _sandbox() -> GridSandbox:
	var s: GridSandbox = (load(SANDBOX_SCENE) as PackedScene).instantiate() as GridSandbox
	add_child_autofree(s)
	return s


func test_sandbox_crowd_preset_builds_crowd_and_spots() -> void:
	var s: GridSandbox = _sandbox()
	assert_null(s.get_crowd_view(), "인자 없으면 군중 없음(기준 캡처 불변)")
	var cap: int = int(_aud["max_agents"])
	assert_true(s.setup_crowd(str(cap)))
	var cv: CrowdView = s.get_crowd_view()
	assert_not_null(cv)
	assert_eq(cv.get_visible_instance_count(), cap, "관객 %d" % cap)
	assert_true(cv.has_stage(), "기준 배치 무대를 안다")
	assert_eq(s.get_build_preset(), BuildPreset.BASELINE, "배치 프리셋이 없으면 baseline")
	assert_eq(s.get_coverage_overlay().get_mode(), CoverageOverlay.MODE_OFF, "오버레이 끔")
	var sl: StageLights = s.get_stage_lights()
	assert_eq(sl.get_mode(), StageLights.MODE_SHOW, "공연 중")
	assert_eq(sl.get_active_spot_count(), sl.params.max_spots, "스포트 max_spots 개(조명 가구 Σ light_grade ≥ max)")
	assert_eq(sl.get_active_spot_count(), mini(sl.params.max_spots, sl.get_light_grade_sum()))
	# 전원 watching, 관람 타일 위, 무대 초점을 본다.
	for slot: int in range(cap):
		var f: Vector3 = -cv.get_slot_transform(slot).basis.z
		var to_focus: Vector3 = (cv.get_focus_world() as Vector3) - cv.get_slot_transform(slot).origin
		assert_gt(f.dot(to_focus.normalized()), 0.99, "슬롯 %d 가 무대를 본다" % slot)
	assert_false(s.setup_crowd(str(cap)), "두 번은 안 붙는다")
	# 시안 전환이 군중에도 간다.
	assert_true(s.apply_material(ShaderVariants.PLAIN_ID))
	assert_eq(cv.get_material_id(), ShaderVariants.PLAIN_ID)


func test_sandbox_crowd_preset_rejects_bad_values() -> void:
	var cap: int = int(_aud["max_agents"])
	for raw: String in ["0", str(cap + 1), "abc", "-3"]:
		var s: GridSandbox = _sandbox()
		assert_false(s.setup_crowd(raw), "'%s' 거부" % raw)
		assert_null(s.get_crowd_view())
	assert_push_error_count(4, "값마다 push_error")
	assert_eq(CrowdPreset.resolve(PackedStringArray(["--se-crowd-preset=150"])), "150")
	assert_eq(CrowdPreset.resolve(PackedStringArray(["--x"])), CrowdPreset.NONE)
