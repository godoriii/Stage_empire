class_name SpikeCrowd
extends Node3D
## 성능 스파이크 씬(SE-003, SE-013): MultiMesh 캐릭터 프록시 N개 + 동적 라이트 M개(Omni/Spot 혼합) +
## 무대 프록시 박스(셰도우 캐스터)를 SE-002 의 IsoCamera(최대 줌아웃)·GridView 위에 전부 화면 안에 띄우고 매 프레임 움직인다.
## 표시 전용. sim/core 와 연결하지 않고 이벤트 버스를 쓰지 않는다. 툰 룩은 범위 밖(SE-004).
##
## 수치는 전부 spike_configs.tres(SpikeConfigSet)에 있다. 구성은 config_id(@export) 또는 명령줄로 고른다.
## 군중 그림자는 구성의 crowd_shadows 를 따른다(구성 E = off, style-guide 2026-10-09 결정).
##
## 실행(구경):  godot --path project res://view/perf/spike_crowd.tscn -- --config=E
## 측정은 이 씬이 아니라 tests 쪽 진입점(tests/view/perf/measure_spike.tscn)이 이 씬을 인스턴스화해서 한다.
##   view/ 는 tests/ 를 참조하지 않는다(test_view_boundary.gd). 측정기가 measure_mode 를 켜고
##   set_process(false) 로 이 노드의 자체 진행을 멈춘 뒤 advance()·update_label() 을 직접 호출한다.
##
## 군중 갱신 경로(실제 게임과 같은 비용 구조):
##   interpolation_tick_hz 마다 "시뮬레이션이 내준 다음 위치"를 전 인스턴스에 대해 계산하고(_sim_tick),
##   매 프레임 이전/다음 위치를 alpha 로 보간해 CPU 에서 전 인스턴스 트랜스폼을 MultiMesh 버퍼에 다시 쓴다.

const DEFAULT_SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"
const ARG_CONFIG: String = "--config="

## MultiMesh 버퍼 레이아웃(TRANSFORM_3D + use_colors): 행 우선 3×4 트랜스폼 12개 + 색 4개.
const FLOATS_PER_TRANSFORM: int = 12
const FLOATS_PER_COLOR: int = 4
const FLOATS_PER_INSTANCE: int = FLOATS_PER_TRANSFORM + FLOATS_PER_COLOR

@export var settings: SpikeConfigSet
## 비워 두면 명령줄 --config=<id>, 그것도 없으면 settings.default_config_id.
@export var config_id: String = ""

@onready var iso_camera: IsoCamera = $IsoCamera
@onready var grid: GridView = $GridView
@onready var crowd: MultiMeshInstance3D = $Crowd
@onready var lights_root: Node3D = $Lights
@onready var stage_props_root: Node3D = $StageProps
@onready var info_label: Label = $Overlay/InfoLabel

var config: SpikeConfig
## 측정기가 켠다(입력 무시, 라벨 표시). 이 씬은 명령줄로 측정 모드를 켜지 않는다.
var measure_mode: bool = false

var _time: float = 0.0
var _crowd_center: Vector3 = Vector3.ZERO
var _crowd_side_m: float = 0.0
var _layout_yaw: Basis = Basis.IDENTITY

# 인스턴스별 데이터(인덱스 = 인스턴스 번호).
var _anchor: PackedVector3Array = PackedVector3Array()
var _phase: PackedFloat32Array = PackedFloat32Array()
var _speed: PackedFloat32Array = PackedFloat32Array()
var _prev_pos: PackedVector3Array = PackedVector3Array()
var _next_pos: PackedVector3Array = PackedVector3Array()
var _prev_yaw: PackedFloat32Array = PackedFloat32Array()
var _next_yaw: PackedFloat32Array = PackedFloat32Array()
var _buffer: PackedFloat32Array = PackedFloat32Array()
var _tick_dt: float = 0.0
var _tick_accum: float = 0.0
## _prev_* 가 나타내는 시뮬레이션 시각(초).
var _sim_time: float = 0.0

# 라이트별 데이터.
var _lights: Array[Light3D] = []
var _light_anchor: PackedVector3Array = PackedVector3Array()
var _light_phase: PackedFloat32Array = PackedFloat32Array()
var _last_fps_shown: int = -1


func _ready() -> void:
	InputActions.register()
	if settings == null:
		settings = load(DEFAULT_SETTINGS_PATH) as SpikeConfigSet
	for err: String in settings.get_errors():
		push_error("SpikeCrowd: 설정 오류: %s" % err)
	var wanted: String = resolve_config_id(config_id, OS.get_cmdline_user_args(), settings.default_config_id)
	config = settings.get_config(wanted)
	if config == null:
		push_error("SpikeCrowd: 구성 '%s' 없음 (가능: %s)" % [wanted, ", ".join(settings.get_config_ids())])
		config = settings.get_config(settings.default_config_id)
	config_id = config.id
	_build()


## 구성 id 결정: @export 값 > 명령줄 --config= > 기본값.
static func resolve_config_id(exported_id: String, user_args: PackedStringArray, default_id: String) -> String:
	if not exported_id.is_empty():
		return exported_id
	for a: String in user_args:
		if a.begins_with(ARG_CONFIG):
			return a.trim_prefix(ARG_CONFIG).strip_edges().to_upper()
	return default_id


func _unhandled_input(event: InputEvent) -> void:
	if measure_mode:
		return
	if event.is_action_pressed(InputActions.CAMERA_ROTATE_CW):
		iso_camera.rotate_cw()
	elif event.is_action_pressed(InputActions.CAMERA_ROTATE_CCW):
		iso_camera.rotate_ccw()
	elif event.is_action_pressed(InputActions.CAMERA_ZOOM_IN):
		iso_camera.zoom_in()
	elif event.is_action_pressed(InputActions.CAMERA_ZOOM_OUT):
		iso_camera.zoom_out()


func _process(delta: float) -> void:
	if config == null:
		return
	if not measure_mode:
		var dir: Vector2 = Input.get_vector(
			InputActions.CAMERA_PAN_LEFT, InputActions.CAMERA_PAN_RIGHT,
			InputActions.CAMERA_PAN_UP, InputActions.CAMERA_PAN_DOWN)
		if dir != Vector2.ZERO:
			iso_camera.pan(dir * iso_camera.get_zoom_size() * iso_camera.params.pan_speed_screens_per_sec * delta)
	advance(delta)
	update_label()


## 연출을 delta 초 진행한다: 군중 보간 + 버퍼 업로드, 라이트 위치·방향·색.
## 측정기는 이 호출을 감싸 CPU 시간(군중 갱신 + 라이트 갱신)을 잰다.
func advance(delta: float) -> void:
	_time += delta
	_advance_crowd(delta)
	_update_lights()


# --- 조회(테스트·측정기용) -------------------------------------------------

func get_instance_count() -> int:
	return crowd.multimesh.instance_count


func get_light_nodes() -> Array[Light3D]:
	return _lights


func get_shadow_light_count() -> int:
	var n: int = 0
	for l: Light3D in _lights:
		if l.shadow_enabled:
			n += 1
	return n


func get_instance_mesh_triangle_count() -> int:
	return crowd.multimesh.mesh.get_faces().size() / 3


## 군중이 실제로 그림자를 드리우는지(cast_shadow != OFF).
func is_crowd_casting_shadows() -> bool:
	return crowd.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func get_stage_prop_nodes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child: Node in stage_props_root.get_children():
		var mi: MeshInstance3D = child as MeshInstance3D
		if mi != null and not mi.is_queued_for_deletion():
			out.append(mi)
	return out


## 무대 프록시 전체 삼각형 수(메인 패스 1회 기준).
func get_stage_prop_triangle_count() -> int:
	var n: int = 0
	for mi: MeshInstance3D in get_stage_prop_nodes():
		n += mi.mesh.get_faces().size() / 3
	return n


func get_crowd_center() -> Vector3:
	return _crowd_center


func get_crowd_side_m() -> float:
	return _crowd_side_m


func get_elapsed_sec() -> float:
	return _time


## 화면에 보이는 최대 군중 정사각 한 변(m): 최대 줌아웃 직교 화면(세로 size, 가로 size × 화면비)에
## 카메라 요에 맞춘 정사각형을 넣는다. 지면 깊이는 sin(피치)로 줄고 캐릭터 높이는 cos(피치)만큼 화면을 먹는다.
static func fit_crowd_side_m(cam_params: IsoCameraParams, aspect: float, char_height_m: float) -> float:
	var size_v: float = cam_params.zoom_sizes[cam_params.zoom_sizes.size() - 1]
	var pitch: float = absf(deg_to_rad(cam_params.pitch_deg))
	var width_m: float = size_v * aspect
	var depth_m: float = (size_v - char_height_m * cos(pitch)) / sin(pitch)
	return minf(width_m, depth_m)


## 캐릭터 프록시 메시: 캡슐 몸통 + 박스 머리 + 박스 팔 2개를 한 서피스로 합친다(MultiMesh 드로우 1회).
## 피벗은 발 중심(y = 0, style-guide). 인스턴스 색은 정점 색으로 albedo 에 곱해진다.
static func build_proxy_mesh(s: SpikeConfigSet) -> ArrayMesh:
	var body: CapsuleMesh = CapsuleMesh.new()
	body.radius = s.body_radius_m
	body.height = s.body_height_m
	body.radial_segments = s.body_radial_segments
	body.rings = s.body_rings
	var head: BoxMesh = BoxMesh.new()
	head.size = Vector3.ONE * s.head_size_m
	var arm: BoxMesh = BoxMesh.new()
	arm.size = s.arm_size_m
	var st: SurfaceTool = SurfaceTool.new()
	st.append_from(body, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, s.body_height_m * 0.5, 0.0)))
	st.append_from(head, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, s.body_height_m + s.head_size_m * 0.5, 0.0)))
	var arm_x: float = s.body_radius_m + s.arm_size_m.x * 0.5
	var arm_y: float = s.body_height_m - s.body_radius_m - s.arm_size_m.y * 0.5
	st.append_from(arm, 0, Transform3D(Basis.IDENTITY, Vector3(-arm_x, arm_y, 0.0)))
	st.append_from(arm, 0, Transform3D(Basis.IDENTITY, Vector3(arm_x, arm_y, 0.0)))
	var mesh: ArrayMesh = st.commit()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


# --- 구성 -----------------------------------------------------------------

func _build() -> void:
	var s: SpikeConfigSet = settings
	iso_camera.set_zoom_index(iso_camera.get_zoom_level_count() - 1)
	var aspect: float = float(s.resolution.x) / float(s.resolution.y)
	var char_h: float = s.body_height_m + s.head_size_m + s.bob_height_m
	var fit: float = fit_crowd_side_m(iso_camera.params, aspect, char_h)
	_crowd_side_m = fit * s.crowd_fill_ratio - 2.0 * s.wander_radius_m
	_layout_yaw = Basis(Vector3.UP, deg_to_rad(iso_camera.params.base_yaw_deg))

	# 바닥: SE-002 GridView 를 군중 영역(요 회전 정사각형의 AABB)을 덮는 크기로 다시 만든다.
	var tile_m: float = GridDataLoader.load_tile_size_m()
	var yaw_rad: float = deg_to_rad(iso_camera.params.base_yaw_deg)
	var aabb_side: float = _crowd_side_m * (absf(cos(yaw_rad)) + absf(sin(yaw_rad))) + 2.0 * s.wander_radius_m
	var tiles: int = ceili(aabb_side / tile_m)
	grid.setup(IsoGridMath.new(Vector2i(tiles, tiles), tile_m))
	_crowd_center = grid.get_center_world()
	iso_camera.set_bounds(grid.get_extent_m())
	iso_camera.focus_on(_crowd_center)

	get_viewport().positional_shadow_atlas_size = config.shadow_atlas_size
	_build_crowd()
	_build_stage_props()
	_build_lights()
	update_label()


func _build_crowd() -> void:
	var s: SpikeConfigSet = settings
	var n: int = config.instances
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = s.crowd_seed
	var cols: int = ceili(sqrt(float(n)))
	var spacing: float = _crowd_side_m / float(cols)
	var half: float = _crowd_side_m * 0.5
	var jitter: float = spacing * s.crowd_jitter_ratio

	_anchor.resize(n)
	_phase.resize(n)
	_speed.resize(n)
	_prev_pos.resize(n)
	_next_pos.resize(n)
	_prev_yaw.resize(n)
	_next_yaw.resize(n)
	_buffer.resize(n * FLOATS_PER_INSTANCE)
	_buffer.fill(0.0)
	for i: int in range(n):
		var u: float = (float(i % cols) + 0.5) * spacing - half + rng.randf_range(-jitter, jitter)
		var v: float = (float(i / cols) + 0.5) * spacing - half + rng.randf_range(-jitter, jitter)
		_anchor[i] = _crowd_center + _layout_yaw * Vector3(u, 0.0, v)
		_phase[i] = rng.randf() * TAU
		_speed[i] = rng.randf_range(s.wander_speed_min, s.wander_speed_max)
		var o: int = i * FLOATS_PER_INSTANCE
		# 회전은 Y 축뿐이라 기저의 상수 칸(행 1 = (0, 1, 0), [0][1], [2][1])은 여기서 한 번만 쓴다.
		_buffer[o + 5] = 1.0
		var c: Color = s.crowd_palette[rng.randi_range(0, s.crowd_palette.size() - 1)]
		_buffer[o + 12] = c.r
		_buffer[o + 13] = c.g
		_buffer[o + 14] = c.b
		_buffer[o + 15] = c.a

	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = build_proxy_mesh(s)
	mm.instance_count = n
	# 컬링으로 숫자를 깎지 않도록 군중 전체를 덮는 고정 AABB(매 프레임 AABB 재계산 비용도 없앤다).
	var reach: float = _crowd_side_m + 2.0 * s.wander_radius_m
	var top: float = s.body_height_m + s.head_size_m + s.bob_height_m
	mm.custom_aabb = AABB(_crowd_center - Vector3(reach, 0.0, reach), Vector3(reach * 2.0, top, reach * 2.0))
	crowd.multimesh = mm
	crowd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if config.crowd_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_tick_dt = 1.0 / s.interpolation_tick_hz
	_tick_accum = 0.0
	_sim_time = 0.0
	_sim_targets(_sim_time, _prev_pos, _prev_yaw)
	_sim_targets(_sim_time + _tick_dt, _next_pos, _next_yaw)
	_write_instances(0.0)


## 무대 프록시 박스(셰도우 캐스터)를 군중 영역 안에 한 줄로 놓는다. 모든 구성에서 같다(구성 간 비교 가능성).
## 배치는 군중과 같은 레이아웃 좌표(카메라 기준 요로 돌린 정사각형)를 쓴다.
func _build_stage_props() -> void:
	var s: SpikeConfigSet = settings
	for child: Node in stage_props_root.get_children():
		child.queue_free()
	var n: int = s.stage_prop_count
	var span: float = _crowd_side_m * s.stage_prop_span_ratio
	var spacing: float = span / float(n)
	var v: float = _crowd_side_m * 0.5 * s.stage_prop_offset_ratio
	var box: BoxMesh = BoxMesh.new()
	box.size = s.stage_prop_size_m
	for i: int in range(n):
		var u: float = (float(i) + 0.5) * spacing - span * 0.5
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "Prop_%02d" % i
		mi.mesh = box
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.transform = Transform3D(_layout_yaw, _crowd_center + _layout_yaw * Vector3(u, s.stage_prop_size_m.y * 0.5, v))
		stage_props_root.add_child(mi)


func _build_lights() -> void:
	var s: SpikeConfigSet = settings
	var m: int = config.lights
	for child: Node in lights_root.get_children():
		child.queue_free()
	_lights.clear()
	_light_anchor.resize(m)
	_light_phase.resize(m)
	var cols: int = maxi(1, ceili(sqrt(float(m))))
	var area: float = _crowd_side_m * s.light_area_ratio
	var spacing: float = area / float(cols)
	for i: int in range(m):
		var u: float = (float(i % cols) + 0.5) * spacing - area * 0.5
		var v: float = (float(i / cols) + 0.5) * spacing - area * 0.5
		_light_anchor[i] = _crowd_center + _layout_yaw * Vector3(u, 0.0, v)
		_light_phase[i] = TAU * float(i) / float(m)
		var light: Light3D
		# 홀수 = 무빙 헤드(SpotLight3D), 짝수 = OmniLight3D. 셰도우는 앞쪽 shadow_lights 개 → 두 종류에 고르게.
		if i % 2 == 1:
			var spot: SpotLight3D = SpotLight3D.new()
			spot.spot_range = s.spot_range_m
			spot.spot_angle = s.spot_angle_deg
			spot.light_energy = s.spot_energy
			light = spot
		else:
			var omni: OmniLight3D = OmniLight3D.new()
			omni.omni_range = s.omni_range_m
			omni.light_energy = s.omni_energy
			light = omni
		light.name = "Light_%02d" % i
		light.shadow_enabled = i < config.shadow_lights
		lights_root.add_child(light)
		_lights.append(light)
	_update_lights()


# --- 매 프레임 ------------------------------------------------------------

## 시뮬레이션 쪽 "틱 시각 t 의 위치"를 흉내 낸다: 기준점 주위 원운동, 진행 방향을 바라봄.
func _sim_targets(t: float, out_pos: PackedVector3Array, out_yaw: PackedFloat32Array) -> void:
	var r: float = settings.wander_radius_m
	var anchor: PackedVector3Array = _anchor
	var speed: PackedFloat32Array = _speed
	var phase: PackedFloat32Array = _phase
	for i: int in range(anchor.size()):
		var a: float = t * speed[i] + phase[i]
		out_pos[i] = anchor[i] + Vector3(sin(a) * r, 0.0, cos(a) * r)
		out_yaw[i] = a + PI * 0.5


func _advance_crowd(delta: float) -> void:
	_tick_accum += delta
	var ticks: int = floori(_tick_accum / _tick_dt)
	if ticks > 0:
		_tick_accum -= float(ticks) * _tick_dt
		_sim_time += float(ticks) * _tick_dt
		if ticks == 1:
			var tp: PackedVector3Array = _prev_pos
			_prev_pos = _next_pos
			_next_pos = tp
			var ty: PackedFloat32Array = _prev_yaw
			_prev_yaw = _next_yaw
			_next_yaw = ty
		else:
			_sim_targets(_sim_time, _prev_pos, _prev_yaw)
		_sim_targets(_sim_time + _tick_dt, _next_pos, _next_yaw)
	_write_instances(_tick_accum / _tick_dt)


## 보간한 트랜스폼을 버퍼에 쓰고 MultiMesh 에 통째로 올린다(RenderingServer.multimesh_set_buffer).
func _write_instances(alpha: float) -> void:
	var bob_h: float = settings.bob_height_m
	var bob_w: float = TAU * settings.bob_freq_hz
	var bob_t: float = _time * bob_w
	# 패킹 배열은 참조 공유라 로컬 별칭으로 써도 복사가 없다. 멤버 조회를 루프 밖으로 빼는 GDScript 최적화.
	var b: PackedFloat32Array = _buffer
	var pp: PackedVector3Array = _prev_pos
	var np: PackedVector3Array = _next_pos
	var py: PackedFloat32Array = _prev_yaw
	var ny: PackedFloat32Array = _next_yaw
	var ph: PackedFloat32Array = _phase
	var o: int = 0
	for i: int in range(pp.size()):
		var p: Vector3 = pp[i].lerp(np[i], alpha)
		var yaw: float = lerpf(py[i], ny[i], alpha)
		var c: float = cos(yaw)
		var s: float = sin(yaw)
		b[o] = c
		b[o + 2] = s
		b[o + 3] = p.x
		b[o + 7] = p.y + bob_h * absf(sin(bob_t + ph[i]))
		b[o + 8] = -s
		b[o + 10] = c
		b[o + 11] = p.z
		o += FLOATS_PER_INSTANCE
	crowd.multimesh.buffer = b


func _update_lights() -> void:
	var s: SpikeConfigSet = settings
	for i: int in range(_lights.size()):
		var a: float = _time * s.light_orbit_speed + _light_phase[i]
		var anchor: Vector3 = _light_anchor[i]
		var pos: Vector3 = anchor + Vector3(cos(a) * s.light_orbit_radius_m, s.light_height_m, sin(a) * s.light_orbit_radius_m)
		var light: Light3D = _lights[i]
		if light is SpotLight3D:
			var b: float = _time * s.spot_sweep_speed + _light_phase[i]
			var target: Vector3 = anchor + Vector3(cos(b) * s.spot_sweep_radius_m, 0.0, sin(b) * s.spot_sweep_radius_m)
			# 아래를 겨누므로 방향은 FORWARD 와 평행해질 수 없다(라이트가 캐릭터보다 높다).
			light.look_at_from_position(pos, target, Vector3.FORWARD)
		else:
			light.position = pos
		light.light_color = Color.from_hsv(fposmod(_time * s.light_hue_speed + _light_phase[i] / TAU, 1.0), s.light_saturation, 1.0)


## 오버레이 라벨(구성·수·fps). fps 가 바뀔 때만 다시 쓴다. 측정기도 프레임마다 호출한다.
func update_label() -> void:
	if info_label == null or config == null:
		return
	var fps: int = int(Engine.get_frames_per_second())
	if fps == _last_fps_shown and not info_label.text.is_empty():
		return
	_last_fps_shown = fps
	info_label.text = "스파이크 구성 %s%s\n인스턴스 %d · 라이트 %d (셰도우 %d) · 군중 그림자 %s\n%d fps" % [
		config.id, " [측정 중]" if measure_mode else "",
		config.instances, config.lights, config.shadow_lights, "on" if config.crowd_shadows else "off", fps]
