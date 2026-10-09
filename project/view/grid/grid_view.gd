class_name GridView
extends Node3D
## 티어 부지 그리드 표시: 바닥 판 + 타일 선. 좌표 변환은 IsoGridMath 에 위임한다.
## 그리드 크기는 data/tiers/tiers.json, 타일 크기는 data/sim/sim.json 에서 읽는다(GridDataLoader).
## 게임 상태를 바꾸지 않는다. 표시 전용.

const DEFAULT_PARAMS_PATH: String = "res://view/grid/grid_view_params.tres"

@export var params: GridViewParams
## 표시할 티어 행 id (tiers.json rows[].id).
@export var tier_id: String = "tier_1"

var _math: IsoGridMath
var _floor: MeshInstance3D
var _lines: MeshInstance3D


func _ready() -> void:
	if _math == null:
		load_from_data()


## 데이터 테이블에서 그리드를 읽어 메시를 다시 만든다.
func load_from_data() -> void:
	setup(GridDataLoader.load_grid_math(tier_id))


## 주어진 그리드 수학으로 메시를 다시 만든다.
func setup(math: IsoGridMath) -> void:
	if params == null:
		params = load(DEFAULT_PARAMS_PATH) as GridViewParams
	_math = math
	_rebuild()


func get_math() -> IsoGridMath:
	return _math


func get_grid_size() -> Vector2i:
	return _math.grid_size


func get_tile_size_m() -> float:
	return _math.tile_size_m


func get_extent_m() -> Vector2:
	return _math.get_extent_m()


func get_center_world() -> Vector3:
	var e: Vector2 = get_extent_m()
	return Vector3(e.x * 0.5, 0.0, e.y * 0.5)


func world_to_tile(world: Vector3) -> Vector2i:
	return _math.world_to_tile(world)


func tile_to_world(tile: Vector2i) -> Vector3:
	return _math.tile_to_world(tile)


func is_inside(tile: Vector2i) -> bool:
	return _math.is_inside(tile)


func _rebuild() -> void:
	if _floor != null:
		_floor.queue_free()
	if _lines != null:
		_lines.queue_free()
	var extent: Vector2 = _math.get_extent_m()

	_floor = MeshInstance3D.new()
	_floor.name = "Floor"
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(extent.x, params.floor_thickness_m, extent.y)
	var floor_mat: StandardMaterial3D = StandardMaterial3D.new()
	floor_mat.albedo_color = params.floor_color
	box.material = floor_mat
	_floor.mesh = box
	_floor.position = Vector3(extent.x * 0.5, -params.floor_thickness_m * 0.5, extent.y * 0.5)
	add_child(_floor)

	_lines = MeshInstance3D.new()
	_lines.name = "TileLines"
	_lines.mesh = _build_line_mesh(extent)
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lines)


func _build_line_mesh(extent: Vector2) -> ArrayMesh:
	var y: float = params.line_y_offset_m
	var t: float = _math.tile_size_m
	var verts: PackedVector3Array = PackedVector3Array()
	for x: int in range(_math.grid_size.x + 1):
		verts.append(Vector3(x * t, y, 0.0))
		verts.append(Vector3(x * t, y, extent.y))
	for z: int in range(_math.grid_size.y + 1):
		verts.append(Vector3(0.0, y, z * t))
		verts.append(Vector3(extent.x, y, z * t))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = params.line_color
	mesh.surface_set_material(0, mat)
	return mesh
