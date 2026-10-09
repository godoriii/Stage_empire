class_name ShaderPlaceholders
extends Node3D
## SE-004 셰이더 시안 비교용 플레이스홀더 세트: 바 카운터, 무대, 캐릭터 캡슐 N개, 벽 세그먼트, 컬러 스포트.
## 메시는 코드로 만든 프리미티브뿐이다(assets/ 참조 없음). 치수·색·라이트는 placeholder_set(.tres)에서 읽는다.
## 이 노드의 위치 = 세트의 기준점(샌드박스에서는 그리드 중심). 자식 오프셋은 그 기준 m.
##
## 색은 정점색(COLOR)으로 넣는다: 기본 머티리얼은 StandardMaterial3D(vertex_color_use_as_albedo)라 plain 시안에서도
## 같은 색으로 보이고, 툰 시안은 정점색 × base_color 라 시안 간 비교에서 색이 같다(스파이크 군중과 같은 방식).
## accent 영역(accent_top 인 박스의 윗면)은 정점 알파 0 으로 표시한다. SE-024 부터 toon.gdshader 는 정점 알파를 읽지 않으므로
## (슬롯 = 서피스, docs/gdd/materials.md) 이 알파는 화면에 영향이 없고 accent 색은 정점색 rgb 로만 보인다.
## 표시 전용. 게임 상태를 바꾸지 않는다.

const DEFAULT_SET_PATH: String = "res://view/scenes/shader_placeholders.tres"
## 박스 플레이스홀더 노드 이름(생성 순서).
const BOX_NAMES: PackedStringArray = ["Bar", "Stage", "Wall"]
const CHARACTER_NAME_PATTERN: String = "Character_%d"
const SPOT_NAME_PATTERN: String = "Spot_%d"

@export var placeholder_set: ShaderPlaceholderSet

var _meshes: Array[MeshInstance3D] = []
var _spots: Array[SpotLight3D] = []


func _ready() -> void:
	build()


## 세트를 (다시) 만든다. 기존 자식은 즉시 지운다.
func build() -> void:
	if placeholder_set == null:
		placeholder_set = load(DEFAULT_SET_PATH) as ShaderPlaceholderSet
	for err: String in placeholder_set.get_errors():
		push_error("ShaderPlaceholders: 설정 오류: %s" % err)
	for child: Node in get_children():
		remove_child(child)
		child.free()
	_meshes.clear()
	_spots.clear()
	var s: ShaderPlaceholderSet = placeholder_set
	_add_box(BOX_NAMES[0], s.bar_size_m, s.bar_offset_m, s.bar_color, s.bar_accent_top)
	_add_box(BOX_NAMES[1], s.stage_size_m, s.stage_offset_m, s.stage_color, s.stage_accent_top)
	_add_box(BOX_NAMES[2], s.wall_size_m, s.wall_offset_m, s.wall_color, false)
	var capsule: CapsuleMesh = CapsuleMesh.new()
	capsule.radius = s.character_radius_m
	capsule.height = s.character_height_m
	for i: int in range(s.character_offsets_m.size()):
		var c: Color = s.character_colors[i % s.character_colors.size()] if not s.character_colors.is_empty() else Color.WHITE
		var off: Vector2 = s.character_offsets_m[i]
		_add_mesh(CHARACTER_NAME_PATTERN % i, colorize(capsule, c, s.accent_color, false),
			Vector3(off.x, s.character_height_m * 0.5, off.y))
	for i: int in range(s.spot_offsets_m.size()):
		var spot: SpotLight3D = SpotLight3D.new()
		spot.name = SPOT_NAME_PATTERN % i
		spot.light_color = s.spot_colors[i]
		spot.light_energy = s.spot_energy
		spot.spot_range = s.spot_range_m
		spot.spot_angle = s.spot_angle_deg
		spot.transform = Transform3D(Basis.IDENTITY, s.spot_offsets_m[i]).looking_at(s.spot_targets_m[i], Vector3.UP)
		add_child(spot)
		_spots.append(spot)


func get_mesh_instances() -> Array[MeshInstance3D]:
	return _meshes


func get_spot_lights() -> Array[SpotLight3D]:
	return _spots


## 프리미티브 메시를 정점색이 들어간 ArrayMesh 로 바꾼다. accent_top 이면 윗면(법선 y > 0.5) 정점은 accent 색 + 알파 0.
## 기본 머티리얼은 정점색을 albedo 로 쓰는 StandardMaterial3D(plain 시안).
static func colorize(mesh: PrimitiveMesh, color: Color, accent: Color, accent_top: bool) -> ArrayMesh:
	var arrays: Array = mesh.get_mesh_arrays()
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = PackedColorArray()
	colors.resize(normals.size())
	for i: int in range(normals.size()):
		if accent_top and normals[i].y > 0.5:
			colors[i] = Color(accent.r, accent.g, accent.b, 0.0)
		else:
			colors[i] = Color(color.r, color.g, color.b, 1.0)
	arrays[Mesh.ARRAY_COLOR] = colors
	var out: ArrayMesh = ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	out.surface_set_material(0, mat)
	return out


func _add_box(node_name: String, size_m: Vector3, offset_m: Vector2, color: Color, accent_top: bool) -> void:
	var box: BoxMesh = BoxMesh.new()
	box.size = size_m
	_add_mesh(node_name, colorize(box, color, placeholder_set.accent_color, accent_top),
		Vector3(offset_m.x, size_m.y * 0.5, offset_m.y))


func _add_mesh(node_name: String, mesh: Mesh, pos: Vector3) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)
	_meshes.append(mi)
