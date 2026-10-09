class_name CoverageOverlay
extends Node3D
## SE-037: 커버리지 오버레이(PRD "오버레이 모드": 지형 데칼, 키 하나로 전환).
## build.coverage_changed 의 관람 타일(viewing_tiles)마다 바닥 위 반투명 타일 하나(MultiMesh 1개 = 드로우콜 1):
##   현재 모드의 덮인 타일(sound_tiles / sight_tiles / bar_tiles)이면 params.overlay_covered_colors[모드], 아니면
##   params.overlay_uncovered_color. 관람 타일이 아닌 곳은 데칼 없음.
## 모드 순환(overlay_cycle): off → sound → sight → bar → off. off 면 숨김.
## 숫자는 sim 이 발행한 페이로드의 타일 배열 크기만 보여 준다(HUD 문구). session.loaded 면 지운다(다음 coverage_changed 까지).
## 구독만 한다. 이벤트를 발행하지 않는다.

signal mode_changed(mode: String)
## 데칼을 다시 그린 뒤(모드 변경·coverage_changed·session.loaded). HUD 문구 갱신용.
signal refreshed

const EV_COVERAGE_CHANGED: String = "build.coverage_changed"
const EV_SESSION_LOADED: String = "session.loaded"
const DEFAULT_PARAMS_PATH: String = "res://view/build/build_view_params.tres"
const DECALS_NAME: StringName = &"Decals"
const MODE_OFF: String = "off"
## 순환 순서. 0 = off.
const MODES: PackedStringArray = ["off", "sound", "sight", "bar"]
## 모드 → 페이로드의 덮인 타일 키.
const MODE_TILE_KEYS: Dictionary = {"sound": "sound_tiles", "sight": "sight_tiles", "bar": "bar_tiles"}
## HUD 표시 이름(로컬라이즈 키 분리는 후속 content 티켓).
const MODE_LABELS: Dictionary = {"off": "끔", "sound": "음향", "sight": "시야", "bar": "바 서비스"}
const VIEWING_KEY: String = "viewing_tiles"

@export var params: BuildViewParams

var _bus: EventBus
var _tile_m: float = 1.0
var _mode: String = MODE_OFF
var _coverage: Dictionary = {}
## Vector2i -> Color (현재 모드에서 그린 데칼 색). get_tile_color 조회용.
var _colors: Dictionary = {}
## MultiMesh 인스턴스 순서의 셀(인스턴스 i = _cells[i]). 헤드리스 더미 렌더러는 인스턴스 버퍼를 돌려주지 않아 따로 둔다.
var _cells: Array[Vector2i] = []
var _decals: MultiMeshInstance3D


func bind(bus: EventBus, tile_m: float) -> void:
	if params == null:
		params = load(DEFAULT_PARAMS_PATH) as BuildViewParams
	_unsubscribe()
	_bus = bus
	_tile_m = tile_m
	_build_visuals()
	if _bus != null:
		_bus.subscribe(EV_COVERAGE_CHANGED, on_coverage_changed)
		_bus.subscribe(EV_SESSION_LOADED, on_session_loaded)
	_rebuild()


func _exit_tree() -> void:
	_unsubscribe()


func _unsubscribe() -> void:
	if _bus == null:
		return
	_bus.unsubscribe(EV_COVERAGE_CHANGED, on_coverage_changed)
	_bus.unsubscribe(EV_SESSION_LOADED, on_session_loaded)
	_bus = null


func on_coverage_changed(payload: Dictionary) -> void:
	_coverage = payload.duplicate(true)
	_rebuild()


func on_session_loaded(_payload: Dictionary) -> void:
	_coverage = {}
	_rebuild()


## 다음 모드로(off → sound → sight → bar → off). 새 모드 id.
func cycle_mode() -> String:
	var i: int = MODES.find(_mode)
	set_mode(MODES[(i + 1) % MODES.size()])
	return _mode


## 모드 지정. 없는 id 면 false.
func set_mode(mode: String) -> bool:
	if not MODES.has(mode):
		push_warning("CoverageOverlay: 모드 '%s' 없음" % mode)
		return false
	if mode != _mode:
		_mode = mode
		_rebuild()
		mode_changed.emit(_mode)
	return true


func get_mode() -> String:
	return _mode


func has_coverage() -> bool:
	return not _coverage.is_empty()


## 셀의 데칼 색. 데칼이 없으면(off, 관람 타일 아님, 데이터 없음) 투명(알파 0).
func get_tile_color(cell: Vector2i) -> Color:
	return _colors.get(cell, Color(0, 0, 0, 0))


## 그린 데칼 수(= off 가 아니면 viewing_tiles 수).
func get_decal_count() -> int:
	if _decals == null or not _decals.visible:
		return 0
	return _decals.multimesh.instance_count


## 그린 데칼의 셀(MultiMesh 인스턴스 순서 = viewing_tiles 순서).
func get_decal_cells() -> Array[Vector2i]:
	return _cells.duplicate()


## HUD 문구: "오버레이(O): 음향 — 덮임 96 / 관람 405". 키 이름은 InputMap 에서.
func get_hud_text() -> String:
	var head: String = "오버레이(%s): %s" % [key_name(InputActions.OVERLAY_CYCLE), MODE_LABELS.get(_mode, _mode)]
	if _mode == MODE_OFF:
		return head
	if _coverage.is_empty():
		return "%s — 데이터 없음" % head
	var covered: int = (_coverage.get(MODE_TILE_KEYS[_mode], []) as Array).size()
	var viewing: int = (_coverage.get(VIEWING_KEY, []) as Array).size()
	return "%s — 덮임 %d / 관람 %d" % [head, covered, viewing]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(InputActions.OVERLAY_CYCLE):
		cycle_mode()
		if is_inside_tree():
			get_viewport().set_input_as_handled()


# --- 공용 메시 헬퍼 (PlacementGhost 반경 미리보기도 쓴다) ---------------------

## 바닥에 눕힌 한 변 size_m 정사각 평면 MultiMesh(인스턴스 색 사용, 인스턴스 0).
static func make_tile_multimesh(size_m: float) -> MultiMesh:
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(size_m, size_m)
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = plane
	mm.instance_count = 0
	return mm


## 데칼 머티리얼: 무광(unshaded)·알파 투명·인스턴스 색 = albedo. 툰 시안 적용 대상에서 빼야 한다(샌드박스 exclude).
static func make_decal_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	return mat


# --- 내부 -------------------------------------------------------------------

func _rebuild() -> void:
	_colors.clear()
	_cells.clear()
	if _decals == null:
		return
	var mm: MultiMesh = _decals.multimesh
	mm.instance_count = 0
	if _mode == MODE_OFF or _coverage.is_empty():
		_decals.visible = false
		refreshed.emit()
		return
	var covered: Dictionary = {}
	for pair: Variant in _coverage.get(MODE_TILE_KEYS[_mode], []):
		covered[BuildCatalog.to_cell(pair)] = true
	var covered_color: Color = params.overlay_covered_colors.get(_mode, params.overlay_uncovered_color)
	var cells: Array[Vector2i] = _cells
	for pair: Variant in _coverage.get(VIEWING_KEY, []):
		var c: Vector2i = BuildCatalog.to_cell(pair)
		if c == IsoGridMath.INVALID_TILE or _colors.has(c):
			continue
		cells.append(c)
		_colors[c] = covered_color if covered.has(c) else params.overlay_uncovered_color
	mm.instance_count = cells.size()
	for i: int in cells.size():
		var p: Vector3 = Vector3((float(cells[i].x) + 0.5) * _tile_m, params.decal_y_offset_m, (float(cells[i].y) + 0.5) * _tile_m)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))
		mm.set_instance_color(i, _colors[cells[i]])
	_decals.visible = not cells.is_empty()
	refreshed.emit()


func _build_visuals() -> void:
	if _decals != null:
		return
	_decals = MultiMeshInstance3D.new()
	_decals.name = DECALS_NAME
	_decals.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_decals.multimesh = make_tile_multimesh(_tile_m * params.decal_fill_ratio)
	_decals.material_override = make_decal_material()
	_decals.visible = false
	add_child(_decals)


## 액션의 첫 바인딩 이름(DebugHud 와 같은 규칙: 키보드는 물리 키 글자).
static func key_name(action: StringName) -> String:
	if not InputMap.has_action(action):
		return "?"
	var events: Array[InputEvent] = InputMap.action_get_events(action)
	if events.is_empty():
		return "?"
	var ev: InputEvent = events[0]
	if ev is InputEventKey:
		var k: InputEventKey = ev as InputEventKey
		return OS.get_keycode_string(k.physical_keycode if k.physical_keycode != 0 else k.keycode)
	return ev.as_text()
