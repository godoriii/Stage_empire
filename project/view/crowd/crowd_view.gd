class_name CrowdView
extends Node3D
## SE-038: 관객 군중 표시(티어 1~3 개별 에이전트, GPU 인스턴싱). audience.md "view 계약" 그대로.
## 구독만 한다. 이벤트를 발행하지 않고 게임 상태를 바꾸지 않는다(CLAUDE.md 원칙 1). audience 상태를 읽지 않는다.
##
## 구독:
##   audience.agent_moved {tick, agents: [[id, px, pz, state, type], …]} — 틱마다. 원소 하나 = 인스턴스 하나.
##     gone 은 숨긴다(그 틱 이후 원소가 오지 않는다). 그 밖의 상태는 전부 보이고 색은 유형 색뿐(반투명 금지).
##   audience.admissions_decided — "오늘 N 명" 값만 보관(HUD SE-039 가 읽는다). 표시에는 쓰지 않는다.
##   build.placed / build.demolished — 무대(category stage)의 초점 셀 g 만 추적(watching 방향).
##   session.loaded — 전부 비운다. 다음 agent_moved 1틱으로 전체를 다시 만든다(모두 새 id 라 보간 없이 스냅, AC5).
##
## 표시:
##   MultiMesh instance_count = audience.json max_agents(고정), visible_instance_count = 이번 틱 활성(≠ gone) 수.
##   슬롯 = 이번 틱 payload 순서(id 오름차순)에서 gone 을 뺀 순번 — 앞 N 칸만 그려지므로 매 틱 다시 채운다(id → 슬롯).
##   위치 = 직전 틱 → 이번 틱 선형 보간, t = acc ÷ tick_len(tick_len = 1 ÷ sim.json ticks_per_second).
##   새 id(직전 틱에 없던 것)는 보간 없이 놓는다. _process 는 표시 버퍼만 다시 쓴다(게임 상태 변경 없음).
##   방향(모델 정면 −z): watching = 에이전트 → 무대 초점 셀(모르면 +z), 움직였으면 진행 방향, 아니면 직전 방향 유지.
##   색 = audience.json types[].color, 알파 1.0(materials.md M3). 군중 cast_shadow = OFF(style-guide 2026-10-09).
##   메시 = CrowdProxyMesh(SpikeCrowd 와 같은 빌더), 머티리얼 = ShaderVariants 시안(기본 DEFAULT_ID).

const EV_AGENT_MOVED: String = "audience.agent_moved"
const EV_ADMISSIONS: String = "audience.admissions_decided"
const EV_PLACED: String = "build.placed"
const EV_DEMOLISHED: String = "build.demolished"
const EV_SESSION_LOADED: String = "session.loaded"
const DEFAULT_PARAMS_PATH: String = "res://view/crowd/crowd_view_params.tres"
const MULTIMESH_NAME: StringName = &"Crowd"

## agent_moved 원소 칸(events.md: [id, px, pz, state, type]).
const IDX_ID: int = 0
const IDX_PX: int = 1
const IDX_PZ: int = 2
const IDX_STATE: int = 3
const IDX_TYPE: int = 4
const ELEMENT_SIZE: int = 5
const STATE_GONE: String = "gone"
const STATE_WATCHING: String = "watching"
## 무대를 모를 때 watching 이 보는 방향(audience.md view 계약: 기준 배치 무대는 남쪽 → +z).
const DEFAULT_FACING: Vector3 = Vector3.BACK

## MultiMesh 버퍼 레이아웃(TRANSFORM_3D + use_colors) — SpikeCrowd 와 같다.
const FLOATS_PER_TRANSFORM: int = 12
const FLOATS_PER_COLOR: int = 4
const FLOATS_PER_INSTANCE: int = FLOATS_PER_TRANSFORM + FLOATS_PER_COLOR

@export var params: CrowdViewParams

var _bus: EventBus
var _catalog: BuildCatalog
var _data: CrowdData
var _mmi: MultiMeshInstance3D
var _material_id: String = ShaderVariants.DEFAULT_ID
var _buffer: PackedFloat32Array = PackedFloat32Array()

## 직전에 받은 틱의 에이전트 표시 상태: id → {pos: Vector3, yaw: float}.
var _last: Dictionary = {}
## 슬롯별(앞 _active 칸만 의미 있음).
var _slot_ids: PackedInt64Array = PackedInt64Array()
var _from_pos: PackedVector3Array = PackedVector3Array()
var _to_pos: PackedVector3Array = PackedVector3Array()
var _from_yaw: PackedFloat32Array = PackedFloat32Array()
var _to_yaw: PackedFloat32Array = PackedFloat32Array()
var _slot_of: Dictionary = {}
var _active: int = 0
var _acc: float = 0.0
var _alpha: float = 1.0
var _last_tick: int = -1
var _admissions: int = -1
## 무대 위치(StageGeometry.from_placed). 비어 있으면 무대 모름.
var _stage: Dictionary = {}
var _focus_world: Vector3 = Vector3.ZERO
var _warned_types: Dictionary = {}


## 버스 구독을 시작하고 MultiMesh 를 만든다. data 가 null 이면 CrowdData.load_default().
## catalog 가 null 이면 무대를 알 수 없다(watching 은 +z).
func bind(bus: EventBus, catalog: BuildCatalog, data: CrowdData = null) -> bool:
	if params == null:
		params = load(DEFAULT_PARAMS_PATH) as CrowdViewParams
	_unsubscribe()
	_catalog = catalog
	_data = data if data != null else CrowdData.load_default()
	if _data == null:
		push_error("CrowdView: 데이터(audience.json·sim.json)를 읽지 못해 군중을 그리지 않는다")
		return false
	_build_multimesh()
	_bus = bus
	if _bus != null:
		_bus.subscribe(EV_AGENT_MOVED, on_agent_moved)
		_bus.subscribe(EV_ADMISSIONS, on_admissions_decided)
		_bus.subscribe(EV_PLACED, on_placed)
		_bus.subscribe(EV_DEMOLISHED, on_demolished)
		_bus.subscribe(EV_SESSION_LOADED, on_session_loaded)
	return true


func _exit_tree() -> void:
	_unsubscribe()


func _unsubscribe() -> void:
	if _bus == null:
		return
	_bus.unsubscribe(EV_AGENT_MOVED, on_agent_moved)
	_bus.unsubscribe(EV_ADMISSIONS, on_admissions_decided)
	_bus.unsubscribe(EV_PLACED, on_placed)
	_bus.unsubscribe(EV_DEMOLISHED, on_demolished)
	_bus.unsubscribe(EV_SESSION_LOADED, on_session_loaded)
	_bus = null


## 시안을 바꾼다(샌드박스 키 1/2/3). 없는 id 면 false(아무것도 안 바꿈).
func set_material_id(id: String) -> bool:
	if not ShaderVariants.is_valid_id(id):
		push_error("CrowdView: 시안 '%s' 없음" % id)
		return false
	_material_id = id
	if _mmi != null:
		ShaderVariants.apply_materials(_mmi, _material_id)
	return true


func get_material_id() -> String:
	return _material_id


## 표시 보간만 진행한다(게임 상태 변경 없음).
func _process(delta: float) -> void:
	advance_display(delta)


## 보간 진행: acc += delta, t = clamp(acc ÷ tick_len, 0, 1) 로 버퍼를 다시 쓴다. 이미 t = 1 이면 아무것도 안 한다.
func advance_display(delta: float) -> void:
	if _data == null or _active == 0 or _alpha >= 1.0:
		return
	_acc += delta
	_write(clampf(_acc / _data.tick_len_sec, 0.0, 1.0))


# --- 구독 핸들러 --------------------------------------------------------------

## audience.agent_moved. 원소 형식이 틀리면 그 원소만 건너뛴다(push_warning).
func on_agent_moved(payload: Dictionary) -> void:
	if _data == null:
		return
	var agents_v: Variant = payload.get("agents", [])
	if not (agents_v is Array):
		push_warning("CrowdView: agent_moved.agents 가 배열이 아니다")
		return
	var cap: int = _data.max_agents
	var next: Dictionary = {}
	_slot_of.clear()
	var n: int = 0
	var dropped: int = 0
	for e: Variant in agents_v as Array:
		if not (e is Array) or (e as Array).size() < ELEMENT_SIZE:
			push_warning("CrowdView: agent_moved 원소 형식 오류 %s" % str(e))
			continue
		var el: Array = e as Array
		var state: String = str(el[IDX_STATE])
		if state == STATE_GONE:
			continue
		if n >= cap:
			dropped += 1
			continue
		var id: int = int(el[IDX_ID])
		var to: Vector3 = _data.to_world(int(el[IDX_PX]), int(el[IDX_PZ]))
		var prev: Dictionary = _last.get(id, {}) as Dictionary
		var from: Vector3 = prev.get("pos", to) as Vector3
		var yaw: float = _yaw_for(state, from, to, prev)
		_slot_ids[n] = id
		_from_pos[n] = from
		_to_pos[n] = to
		_from_yaw[n] = float(prev.get("yaw", yaw))
		_to_yaw[n] = yaw
		_write_color(n, _type_color(str(el[IDX_TYPE])))
		_slot_of[id] = n
		next[id] = {"pos": to, "yaw": yaw}
		n += 1
	if dropped > 0:
		push_warning("CrowdView: 활성 에이전트가 max_agents(%d)를 넘어 %d 명을 그리지 않는다" % [cap, dropped])
	_last = next
	_active = n
	_last_tick = int(payload.get("tick", -1))
	_acc = 0.0
	_mmi.multimesh.visible_instance_count = n
	_write(0.0)


## audience.admissions_decided: admissions 만 보관.
func on_admissions_decided(payload: Dictionary) -> void:
	_admissions = int(payload.get("admissions", -1))


## build.placed: 무대면 초점을 갱신한다. 다른 가구는 무시.
func on_placed(payload: Dictionary) -> void:
	if _data == null:
		return
	var st: Dictionary = StageGeometry.from_placed(_catalog, payload)
	if st.is_empty():
		return
	_stage = st
	var g: Vector2i = StageGeometry.focus_cell(st["footprint"], st["cell"], st["rotation"])
	_focus_world = StageGeometry.cell_center_world(g, _data.tile_m)


## build.demolished: 추적 중인 무대면 무대 모름(+z)으로.
func on_demolished(payload: Dictionary) -> void:
	if not _stage.is_empty() and str(payload.get("entity_id", "")) == str(_stage["entity_id"]):
		_stage = {}


## session.loaded: 군중·무대·보간 기준을 전부 비운다(다음 agent_moved 가 전원을 스냅으로 다시 놓는다).
func on_session_loaded(_payload: Dictionary) -> void:
	_last.clear()
	_slot_of.clear()
	_stage = {}
	_active = 0
	_alpha = 1.0
	_acc = 0.0
	_last_tick = -1
	_admissions = -1
	if _mmi != null:
		_mmi.multimesh.visible_instance_count = 0


# --- 조회 (읽기 전용) ---------------------------------------------------------

func get_multimesh_instance() -> MultiMeshInstance3D:
	return _mmi


func get_instance_count() -> int:
	return _mmi.multimesh.instance_count if _mmi != null else 0


func get_visible_instance_count() -> int:
	return _mmi.multimesh.visible_instance_count if _mmi != null else 0


## id 의 현재 슬롯(없거나 gone 이면 -1).
func get_slot(id: int) -> int:
	return int(_slot_of.get(id, -1))


## 슬롯의 표시 트랜스폼(버퍼에서 읽는다 = MultiMesh 에 올린 값).
func get_slot_transform(slot: int) -> Transform3D:
	var o: int = slot * FLOATS_PER_INSTANCE
	var b: PackedFloat32Array = _buffer
	var basis: Basis = Basis(Vector3(b[o], b[o + 4], b[o + 8]), Vector3(b[o + 1], b[o + 5], b[o + 9]), Vector3(b[o + 2], b[o + 6], b[o + 10]))
	return Transform3D(basis, Vector3(b[o + 3], b[o + 7], b[o + 11]))


func get_slot_color(slot: int) -> Color:
	var o: int = slot * FLOATS_PER_INSTANCE + FLOATS_PER_TRANSFORM
	return Color(_buffer[o], _buffer[o + 1], _buffer[o + 2], _buffer[o + 3])


## 현재 보간 계수(0 = 직전 틱 위치, 1 = 이번 틱 위치).
func get_alpha() -> float:
	return _alpha


func get_tick_len_sec() -> float:
	return _data.tick_len_sec if _data != null else 0.0


func get_last_tick() -> int:
	return _last_tick


## 오늘 입장 수(admissions_decided 를 못 받았으면 -1).
func get_admissions() -> int:
	return _admissions


func has_stage() -> bool:
	return not _stage.is_empty()


## watching 이 바라보는 점(무대를 모르면 null).
func get_focus_world() -> Variant:
	return _focus_world if has_stage() else null


func get_data() -> CrowdData:
	return _data


# --- 내부 -------------------------------------------------------------------

func _build_multimesh() -> void:
	var cap: int = _data.max_agents
	if _mmi == null:
		_mmi = MultiMeshInstance3D.new()
		_mmi.name = MULTIMESH_NAME
		add_child(_mmi)
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = params.build_proxy_mesh()
	mm.instance_count = cap
	mm.visible_instance_count = 0
	_mmi.multimesh = mm
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_buffer.resize(cap * FLOATS_PER_INSTANCE)
	_buffer.fill(0.0)
	_slot_ids.resize(cap)
	_from_pos.resize(cap)
	_to_pos.resize(cap)
	_from_yaw.resize(cap)
	_to_yaw.resize(cap)
	_active = 0
	_alpha = 1.0
	mm.buffer = _buffer
	ShaderVariants.apply_materials(_mmi, _material_id)


func _yaw_for(state: String, from: Vector3, to: Vector3, prev: Dictionary) -> float:
	if state == STATE_WATCHING:
		var target_dir: Vector3 = (_focus_world - to) if has_stage() else DEFAULT_FACING
		if is_zero_approx(target_dir.x) and is_zero_approx(target_dir.z):
			target_dir = DEFAULT_FACING
		return StageGeometry.yaw_facing(target_dir)
	var step: Vector3 = to - from
	if not (is_zero_approx(step.x) and is_zero_approx(step.z)):
		return StageGeometry.yaw_facing(step)
	if prev.has("yaw"):
		return float(prev["yaw"])
	return StageGeometry.yaw_facing(DEFAULT_FACING)


func _type_color(type_id: String) -> Color:
	if _data.type_colors.has(type_id):
		return _data.type_colors[type_id] as Color
	if not _warned_types.has(type_id):
		_warned_types[type_id] = true
		push_warning("CrowdView: 모르는 관객 유형 '%s' — unknown_type_color 로 그린다" % type_id)
	var c: Color = params.unknown_type_color
	c.a = 1.0
	return c


func _write_color(slot: int, c: Color) -> void:
	var o: int = slot * FLOATS_PER_INSTANCE + FLOATS_PER_TRANSFORM
	_buffer[o] = c.r
	_buffer[o + 1] = c.g
	_buffer[o + 2] = c.b
	_buffer[o + 3] = 1.0


## 앞 _active 슬롯의 보간 트랜스폼을 버퍼에 쓰고 MultiMesh 에 올린다(y 축 회전만).
func _write(alpha: float) -> void:
	_alpha = alpha
	var b: PackedFloat32Array = _buffer
	for i: int in range(_active):
		var p: Vector3 = _from_pos[i].lerp(_to_pos[i], alpha)
		var yaw: float = lerp_angle(_from_yaw[i], _to_yaw[i], alpha)
		var c: float = cos(yaw)
		var s: float = sin(yaw)
		var o: int = i * FLOATS_PER_INSTANCE
		b[o] = c
		b[o + 1] = 0.0
		b[o + 2] = s
		b[o + 3] = p.x
		b[o + 4] = 0.0
		b[o + 5] = 1.0
		b[o + 6] = 0.0
		b[o + 7] = p.y
		b[o + 8] = -s
		b[o + 9] = 0.0
		b[o + 10] = c
		b[o + 11] = p.z
	_mmi.multimesh.buffer = b
