class_name StageLights
extends Node3D
## SE-038: 무대 연출 v0 — 공연 구간(show.started ~ show.ended)에 무대 스포트를 켠다.
## 구독만 한다. 이벤트를 발행하지 않고 게임 상태를 바꾸지 않는다(CLAUDE.md 원칙 1).
##
## 구독:
##   build.placed / build.demolished — 설치 가구의 effects.light_grade(furniture.json, build.md C6) 를 entity 별로 누적,
##     무대(category stage) 위치 추적. session.loaded — 전부 비우고 끈다(로드 뒤 build.placed 재발행으로 복구, SE-036).
##     session.loaded.show_active 가 true 면(공연 중 저장을 불러옴, SE-049 — show.started 는 재발행되지 않는다) 재발행 끝 표시인
##     build.coverage_changed {cause:"sync"}(GameSession 재발행 순서 loaded → placed… → coverage_changed) 에서 show.started 와
##     같이 켠다(SE-040 AC-38b).
##   show.started — 스포트 N = min(max_spots, Σ light_grade) 개를 켠다(색 = show_colors). 무대를 모르면 켜지 않는다.
##   show.ended {grade} — 끝 연출: 켜진 스포트를 grade 색(stage_light_params.tres grade_colors)으로 바꾸고
##     finale_sec 뒤 끈다(0 이면 즉시). show.skipped — 변화 없음.
## 스포트 위치: 무대 정면 가장자리에서 관객 쪽 spot_forward_m, 높이 spot_height_m, 정면 폭에 고르게. 무대 중심을 겨눈다.
## 정적(움직이지 않음) — 캡처 재현성. 무빙 헤드·파티클·안개는 VS.
## 끝 연출 타이머는 _process 에서 표시 상태만 바꾼다(게임 상태 아님).

const EV_PLACED: String = "build.placed"
const EV_DEMOLISHED: String = "build.demolished"
const EV_SESSION_LOADED: String = "session.loaded"
const EV_SHOW_STARTED: String = "show.started"
const EV_SHOW_ENDED: String = "show.ended"
const EV_SHOW_SKIPPED: String = "show.skipped"
const EV_COVERAGE_CHANGED: String = "build.coverage_changed"
const DEFAULT_PARAMS_PATH: String = "res://view/stage/stage_light_params.tres"
## furniture.json effects 의 연출 등급 필드(build.md C6).
const LIGHT_GRADE_FIELD: String = "light_grade"
const SPOT_NAME_PATTERN: String = "Spot_%d"

const MODE_OFF: String = "off"
const MODE_SHOW: String = "show"
const MODE_FINALE: String = "finale"

@export var params: StageLightParams

var _bus: EventBus
var _catalog: BuildCatalog
var _tile_m: float = 0.0
var _spots: Array[SpotLight3D] = []
## entity_id → light_grade.
var _grade_by_entity: Dictionary = {}
var _stage: Dictionary = {}
var _mode: String = MODE_OFF
var _on_count: int = 0
var _finale_left: float = 0.0
var _finale_color: Color = Color.WHITE
## session.loaded.show_active — 재발행이 끝나면(coverage_changed) 공연 스포트를 다시 켠다.
var _resume_show: bool = false


## 버스 구독을 시작하고 스포트 노드 max_spots 개(꺼짐)를 만든다. tile_m = sim.json tile_size_m.
## .tres 설정 오류(StageLightParams.get_errors)가 있으면 push_error 후 false — 구독은 그대로 하고, show_colors 가 비면
## grade_fallback_color 로 켠다(0 나눗셈 방지, SE-040 AC-38e). 오류가 없으면 true.
func bind(bus: EventBus, catalog: BuildCatalog, tile_m: float) -> bool:
	if params == null:
		params = load(DEFAULT_PARAMS_PATH) as StageLightParams
	var errs: PackedStringArray = params.get_errors()
	for err: String in errs:
		push_error("StageLights: 설정 오류: %s" % err)
	_unsubscribe()
	_catalog = catalog
	_tile_m = tile_m
	_build_spots()
	_bus = bus
	if _bus != null:
		_bus.subscribe(EV_PLACED, on_placed)
		_bus.subscribe(EV_DEMOLISHED, on_demolished)
		_bus.subscribe(EV_SESSION_LOADED, on_session_loaded)
		_bus.subscribe(EV_SHOW_STARTED, on_show_started)
		_bus.subscribe(EV_SHOW_ENDED, on_show_ended)
		_bus.subscribe(EV_SHOW_SKIPPED, on_show_skipped)
		_bus.subscribe(EV_COVERAGE_CHANGED, on_coverage_changed)
	return errs.is_empty()


func _exit_tree() -> void:
	_unsubscribe()


func _unsubscribe() -> void:
	if _bus == null:
		return
	_bus.unsubscribe(EV_PLACED, on_placed)
	_bus.unsubscribe(EV_DEMOLISHED, on_demolished)
	_bus.unsubscribe(EV_SESSION_LOADED, on_session_loaded)
	_bus.unsubscribe(EV_SHOW_STARTED, on_show_started)
	_bus.unsubscribe(EV_SHOW_ENDED, on_show_ended)
	_bus.unsubscribe(EV_SHOW_SKIPPED, on_show_skipped)
	_bus.unsubscribe(EV_COVERAGE_CHANGED, on_coverage_changed)
	_bus = null


func _process(delta: float) -> void:
	advance_display(delta)


## 끝 연출 타이머만 진행한다(표시 전용).
func advance_display(delta: float) -> void:
	if _mode != MODE_FINALE:
		return
	_finale_left -= delta
	if _finale_left <= 0.0:
		_turn_off()


# --- 구독 핸들러 --------------------------------------------------------------

## build.placed: light_grade 누적(같은 entity 면 교체), 무대면 위치 갱신.
func on_placed(payload: Dictionary) -> void:
	var entity_id: String = str(payload.get("entity_id", ""))
	if _catalog == null or entity_id.is_empty():
		return
	var row: Dictionary = _catalog.furniture(str(payload.get("furniture_id", "")))
	if row.is_empty():
		return
	var effects: Dictionary = row.get("effects", {}) as Dictionary
	_grade_by_entity[entity_id] = maxi(0, int(effects.get(LIGHT_GRADE_FIELD, 0)))
	var st: Dictionary = StageGeometry.from_placed(_catalog, payload)
	if not st.is_empty():
		_stage = st
	elif str(_stage.get("entity_id", "")) == entity_id:
		_stage = {}


## build.demolished: 그 entity 의 light_grade 를 빼고, 무대면 무대 모름.
func on_demolished(payload: Dictionary) -> void:
	var entity_id: String = str(payload.get("entity_id", ""))
	_grade_by_entity.erase(entity_id)
	if str(_stage.get("entity_id", "")) == entity_id:
		_stage = {}


func on_session_loaded(payload: Dictionary) -> void:
	_grade_by_entity.clear()
	_stage = {}
	_turn_off()
	_resume_show = bool(payload.get("show_active", false))


## build.coverage_changed: 로드 재발행 끝(공연 중 로드면 스포트 복구). 그 밖에는 무시.
func on_coverage_changed(_payload: Dictionary) -> void:
	if not _resume_show:
		return
	_resume_show = false
	on_show_started({})


## show.started: N = min(max_spots, Σ light_grade) 개를 공연 색으로 켠다.
func on_show_started(_payload: Dictionary) -> void:
	_turn_off()
	var n: int = mini(params.max_spots, get_light_grade_sum())
	if n <= 0:
		_mode = MODE_SHOW
		return
	if _stage.is_empty():
		push_warning("StageLights: show.started 인데 무대 위치를 모른다 — 스포트를 켜지 않는다")
		_mode = MODE_SHOW
		return
	_place_spots(n)
	for i: int in range(n):
		var spot: SpotLight3D = _spots[i]
		spot.light_color = show_color(i)
		spot.visible = true
	_on_count = n
	_mode = MODE_SHOW


## show.ended {grade}: 끝 연출(grade 색) 뒤 끈다.
func on_show_ended(payload: Dictionary) -> void:
	var grade: String = str(payload.get("grade", ""))
	_finale_color = params.grade_colors.get(grade, params.grade_fallback_color) as Color
	if _on_count <= 0 or params.finale_sec <= 0.0:
		_turn_off()
		return
	for i: int in range(_on_count):
		_spots[i].light_color = _finale_color
	_finale_left = params.finale_sec
	_mode = MODE_FINALE


## show.skipped: 변화 없음(구독은 계약 문서화용 — 공연 없는 날 스포트를 켜지 않는다).
func on_show_skipped(_payload: Dictionary) -> void:
	pass


# --- 조회 (읽기 전용) ---------------------------------------------------------

## 공연 중 스포트 i 의 색(show_colors[i % 크기]). show_colors 가 비어 있으면 grade_fallback_color.
func show_color(i: int) -> Color:
	if params.show_colors.is_empty():
		return params.grade_fallback_color
	return params.show_colors[i % params.show_colors.size()]


func get_spot_nodes() -> Array[SpotLight3D]:
	return _spots.duplicate()


## 보이는(켜진) 스포트 수.
func get_active_spot_count() -> int:
	var n: int = 0
	for s: SpotLight3D in _spots:
		if s.visible:
			n += 1
	return n


func get_light_grade_sum() -> int:
	var total: int = 0
	for g: Variant in _grade_by_entity.values():
		total += int(g)
	return total


## "off" / "show" / "finale".
func get_mode() -> String:
	return _mode


## 마지막 show.ended 의 끝 연출 색.
func get_finale_color() -> Color:
	return _finale_color


func has_stage() -> bool:
	return not _stage.is_empty()


# --- 내부 -------------------------------------------------------------------

func _build_spots() -> void:
	for s: SpotLight3D in _spots:
		remove_child(s)
		s.queue_free()
	_spots.clear()
	for i: int in range(params.max_spots):
		var spot: SpotLight3D = SpotLight3D.new()
		spot.name = SPOT_NAME_PATTERN % i
		spot.spot_range = params.spot_range_m
		spot.spot_angle = params.spot_angle_deg
		spot.light_energy = params.spot_energy
		spot.spot_attenuation = params.spot_attenuation
		spot.shadow_enabled = params.spot_shadows
		spot.visible = false
		add_child(spot)
		_spots.append(spot)
	_on_count = 0
	_mode = MODE_OFF


## 켜질 n 개를 무대 정면 앞 공중에 고르게 놓고 무대 중심을 겨눈다.
func _place_spots(n: int) -> void:
	var fp: Vector2i = _stage["footprint"]
	var cell: Vector2i = _stage["cell"]
	var rot: int = _stage["rotation"]
	var size: Vector2i = BuildCatalog.rotated_size(fp, rot)
	var center: Vector3 = BuildCatalog.center_world(fp, cell, rot, _tile_m)
	var front: Vector3 = StageGeometry.front_dir(rot)
	var right: Vector3 = Vector3.UP.cross(front).normalized()
	# 정면 폭(m)과 중심 → 정면 가장자리까지 거리(m).
	var width_m: float = float(size.x if absf(front.z) > 0.5 else size.y) * _tile_m
	var half_depth_m: float = float(size.y if absf(front.z) > 0.5 else size.x) * _tile_m * 0.5
	var span: float = width_m * params.spot_spread_ratio
	var base: Vector3 = center + front * (half_depth_m + params.spot_forward_m) + Vector3.UP * params.spot_height_m
	var aim: Vector3 = center + Vector3.UP * params.aim_height_m
	for i: int in range(n):
		var u: float = (float(i) + 0.5) / float(n) * span - span * 0.5
		var pos: Vector3 = base + right * u
		# StageLights 는 월드 원점(그리드 원점)에 놓인다고 보고 로컬 트랜스폼으로 쓴다(트리 밖에서도 동작).
		_spots[i].transform = Transform3D(Basis.looking_at(aim - pos, Vector3.UP), pos)


func _turn_off() -> void:
	for s: SpotLight3D in _spots:
		s.visible = false
	_on_count = 0
	_finale_left = 0.0
	_mode = MODE_OFF
