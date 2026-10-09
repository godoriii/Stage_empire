class_name IsoCamera
extends Node3D
## 직교 아이소메트릭 카메라. 이 노드는 지면(y=0) 위의 피벗이고, 자식 Camera3D 가 피벗을 바라본다.
## 피치·요는 고정(iso_camera_params.tres), 회전은 90° 단위 4방향만, 줌은 4단계만 허용한다(PRD).
## 게임 상태를 읽거나 바꾸지 않는다. 표시 전용.

## 카메라 시점(요·줌·피벗)이 바뀌면 발행. HUD 표시용 Godot 시그널이며 이벤트 버스 이벤트가 아니다.
signal view_changed

## PRD 고정: 회전 단위와 방향 수. 자유 회전은 비목표(PRD)이므로 튜닝 대상이 아니다.
const ROTATION_STEP_DEG: float = 90.0
const ROTATION_STEPS: int = 4
const DEFAULT_PARAMS_PATH: String = "res://view/camera/iso_camera_params.tres"

@export var params: IsoCameraParams

var _camera: Camera3D
var _yaw_step: int = 0
var _zoom_index: int = 0
var _bounds_size_m: Vector2 = Vector2.ZERO
var _has_bounds: bool = false


func _ready() -> void:
	apply_params()


## params 를 다시 읽어 카메라를 초기 상태(요 45°, 기본 줌)로 맞춘다.
func apply_params() -> void:
	if params == null:
		params = load(DEFAULT_PARAMS_PATH) as IsoCameraParams
	params.validate()
	_camera = get_node_or_null(^"Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.position = Vector3(0.0, 0.0, params.camera_distance_m)
	_camera.rotation = Vector3.ZERO
	_camera.near = params.near_m
	_camera.far = params.far_m
	_yaw_step = 0
	_zoom_index = clampi(params.default_zoom_index, 0, maxi(params.zoom_sizes.size() - 1, 0))
	_apply_rotation()
	_apply_zoom()


func get_camera() -> Camera3D:
	return _camera


# --- 회전 -----------------------------------------------------------------

## 요 +90°.
func rotate_cw() -> void:
	_yaw_step = posmod(_yaw_step + 1, ROTATION_STEPS)
	_apply_rotation()


## 요 −90°.
func rotate_ccw() -> void:
	_yaw_step = posmod(_yaw_step - 1, ROTATION_STEPS)
	_apply_rotation()


## 현재 요(도), [0, 360) 로 정규화. 기본 파라미터에서는 {45, 135, 225, 315} 중 하나.
func get_yaw_deg() -> float:
	return fposmod(params.base_yaw_deg + ROTATION_STEP_DEG * float(_yaw_step), 360.0)


func get_pitch_deg() -> float:
	return params.pitch_deg


## 0..3. 0 = 초기 방향.
func get_yaw_step() -> int:
	return _yaw_step


# --- 줌 -------------------------------------------------------------------

## 더 가깝게(size 감소). 최소 단계에서는 변화 없음.
func zoom_in() -> void:
	set_zoom_index(_zoom_index - 1)


## 더 멀리(size 증가). 최대 단계에서는 변화 없음.
func zoom_out() -> void:
	set_zoom_index(_zoom_index + 1)


func set_zoom_index(index: int) -> void:
	var clamped: int = clampi(index, 0, get_zoom_level_count() - 1)
	if clamped == _zoom_index:
		return
	_zoom_index = clamped
	_apply_zoom()


func get_zoom_index() -> int:
	return _zoom_index


func get_zoom_level_count() -> int:
	return params.zoom_sizes.size()


func get_zoom_size() -> float:
	return params.zoom_sizes[_zoom_index]


# --- 팬 -------------------------------------------------------------------

## 피벗 이동 허용 영역을 그리드 크기(m)로 설정한다. 피벗은 [−margin, size + margin] 으로 클램프된다.
func set_bounds(size_m: Vector2) -> void:
	_bounds_size_m = size_m
	_has_bounds = true
	_set_pivot(position)


## 피벗을 지면 위 한 점으로 옮긴다(y 는 0 으로 고정).
func focus_on(world_point: Vector3) -> void:
	_set_pivot(world_point)


## 화면 축 기준 지면 이동(m). x = 화면 오른쪽, y = 화면 아래쪽(카메라 쪽).
## 피벗은 XZ 평면에서만 움직이고 y 는 바뀌지 않는다.
func pan(screen_delta_m: Vector2) -> void:
	var yaw_basis: Basis = Basis(Vector3.UP, deg_to_rad(get_yaw_deg()))
	var right: Vector3 = yaw_basis * Vector3.RIGHT
	var back: Vector3 = yaw_basis * Vector3.BACK
	pan_world(right * screen_delta_m.x + back * screen_delta_m.y)


## 월드 좌표계 기준 지면 이동. y 성분은 무시한다.
func pan_world(world_delta: Vector3) -> void:
	_set_pivot(position + Vector3(world_delta.x, 0.0, world_delta.z))


## 피벗 이동 허용 범위의 최솟값/최댓값(m). bounds 가 없으면 무한.
func get_pan_min() -> Vector2:
	if not _has_bounds:
		return Vector2(-INF, -INF)
	return Vector2(-params.pan_margin_m, -params.pan_margin_m)


func get_pan_max() -> Vector2:
	if not _has_bounds:
		return Vector2(INF, INF)
	return _bounds_size_m + Vector2(params.pan_margin_m, params.pan_margin_m)


# --- 내부 -----------------------------------------------------------------

func _set_pivot(world_point: Vector3) -> void:
	var lo: Vector2 = get_pan_min()
	var hi: Vector2 = get_pan_max()
	var p: Vector3 = Vector3(
		clampf(world_point.x, lo.x, hi.x),
		position.y,
		clampf(world_point.z, lo.y, hi.y))
	if p.is_equal_approx(position):
		return
	position = p
	view_changed.emit()


func _apply_rotation() -> void:
	rotation = Vector3(deg_to_rad(params.pitch_deg), deg_to_rad(get_yaw_deg()), 0.0)
	view_changed.emit()


func _apply_zoom() -> void:
	if params.zoom_sizes.is_empty():
		return
	_camera.size = params.zoom_sizes[_zoom_index]
	view_changed.emit()
