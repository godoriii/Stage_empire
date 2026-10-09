class_name TileCursor
extends Node3D
## 타일 호버 커서. 화면 좌표 → 카메라 레이 → 지면(y=0) 교점 → 타일 판정(레이캐스트, PRD 배치 규칙).
## 그리드 안이면 강조 메시와 좌표 라벨을 타일 중심에 띄우고, 밖이면 숨긴다.
## 표시 전용: 게임 상태를 바꾸지 않고 이벤트 버스에 아무것도 발행하지 않는다.
## 배치 요청(build.place_requested)은 후속 티켓에서 이 노드의 hovered 타일을 써서 발행한다.

## 호버 타일이 바뀔 때(그리드 밖으로 나가는 것 포함). HUD 표시용 Godot 시그널.
signal hovered_tile_changed(tile: Vector2i, inside: bool)

const DEFAULT_PARAMS_PATH: String = "res://view/grid/grid_view_params.tres"

@export var params: GridViewParams
## true 면 매 프레임 마우스 위치로 호버를 갱신한다(카메라가 움직여도 커서가 맞도록).
@export var track_mouse: bool = true

var _camera: Camera3D
var _grid: GridView
var _mesh: MeshInstance3D
var _label: Label3D
var _hovered: Vector2i = IsoGridMath.INVALID_TILE
var _inside: bool = false


func _ready() -> void:
	_build_visuals()
	visible = false


func setup(camera: Camera3D, grid: GridView) -> void:
	_camera = camera
	_grid = grid
	_build_visuals()


func _process(_delta: float) -> void:
	if track_mouse and _camera != null and _grid != null:
		update_hover(get_viewport().get_mouse_position())


## 화면 좌표(뷰포트 픽셀) → 타일 좌표. 그리드 밖일 수 있다(is_inside 로 확인).
## 레이가 지면과 만나지 않으면 IsoGridMath.INVALID_TILE.
func screen_to_tile(screen_pos: Vector2) -> Vector2i:
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var direction: Vector3 = _camera.project_ray_normal(screen_pos)
	return _grid.get_math().ray_to_tile(origin, direction)


## 화면 좌표로 호버 상태와 커서 표시를 갱신한다.
func update_hover(screen_pos: Vector2) -> void:
	var tile: Vector2i = screen_to_tile(screen_pos)
	var inside: bool = tile != IsoGridMath.INVALID_TILE and _grid.is_inside(tile)
	if inside:
		position = _grid.tile_to_world(tile) + Vector3(0.0, params.cursor_y_offset_m, 0.0)
		_label.text = "%d, %d" % [tile.x, tile.y]
	visible = inside
	if tile != _hovered or inside != _inside:
		_hovered = tile
		_inside = inside
		hovered_tile_changed.emit(tile, inside)


func get_hovered_tile() -> Vector2i:
	return _hovered


func is_hovering() -> bool:
	return _inside


func _build_visuals() -> void:
	if params == null:
		params = load(DEFAULT_PARAMS_PATH) as GridViewParams
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mesh.name = "Highlight"
		_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = params.cursor_color
		_mesh.material_override = mat
		add_child(_mesh)
	if _grid != null:
		var plane: PlaneMesh = PlaneMesh.new()
		plane.size = Vector2.ONE * _grid.get_tile_size_m() * params.cursor_fill_ratio
		_mesh.mesh = plane
	if _label == null:
		_label = Label3D.new()
		_label.name = "CoordLabel"
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.modulate = params.cursor_color
		add_child(_label)
	_label.position = Vector3(0.0, params.cursor_label_height_m, 0.0)
	_label.pixel_size = params.cursor_label_pixel_size
	_label.font_size = params.cursor_label_font_size
