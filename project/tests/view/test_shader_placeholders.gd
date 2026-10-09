extends GutTest
## SE-004 AC8: 샌드박스 --material= 상당(GridSandbox.apply_material)으로 플레이스홀더 세트 생성·시안 적용,
## shader_variant_* 액션으로 런타임 전환, 없는 id 거부. 인자 없이 열면 플레이스홀더가 없다(SE-002 그대로).

const SANDBOX_SCENE: String = "res://view/scenes/grid_sandbox.tscn"
const SET_PATH: String = "res://view/scenes/shader_placeholders.tres"
const TOON_TRES_PATTERN: String = "res://view/shaders/params/toon_%s.tres"
const EPS: float = 0.0001

var _sandbox: GridSandbox
var _set: ShaderPlaceholderSet


func before_each() -> void:
	_set = load(SET_PATH) as ShaderPlaceholderSet
	_sandbox = (load(SANDBOX_SCENE) as PackedScene).instantiate() as GridSandbox
	add_child_autofree(_sandbox)


func _press(action: StringName) -> void:
	var ev: InputEventAction = InputEventAction.new()
	ev.action = action
	ev.pressed = true
	_sandbox._unhandled_input(ev)


## 샌드박스의 직계 자식 중 ShaderPlaceholders(스크립트 클래스라 find_children 의 타입 필터 대신 is 로 검사).
func _placeholder_nodes() -> Array[Node]:
	var out: Array[Node] = []
	for c: Node in _sandbox.get_children():
		if c is ShaderPlaceholders and not c.is_queued_for_deletion():
			out.append(c)
	return out


func _meshes_under(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for m: Node in n.find_children("*", "MeshInstance3D", true, false):
		out.append(m as MeshInstance3D)
	return out


func _excluded_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = _meshes_under(_sandbox.grid)
	out.append_array(_meshes_under(_sandbox.cursor))
	return out


## 제외 대상(바닥·커서) 메시의 현재 material_override. GridView 메시는 null, TileCursor 강조 메시는 SE-002 의 자체 override.
func _excluded_snapshot() -> Dictionary:
	var snap: Dictionary = {}
	for mi: MeshInstance3D in _excluded_meshes():
		snap[mi] = mi.material_override
	return snap


## 바닥·커서 메시가 스냅숏 그대로이고 시안 머티리얼이 아니다. GridView 메시는 null.
func _assert_excluded_untouched(snap: Dictionary, what: String) -> void:
	assert_gt(snap.size(), 0, "제외 대상 메시가 있다")
	for mi: MeshInstance3D in snap.keys():
		assert_eq(mi.material_override, snap[mi], "%s: %s 머티리얼 그대로" % [mi.name, what])
		assert_false(mi.material_override is ShaderMaterial, "%s: %s 시안 머티리얼 아님" % [mi.name, what])
	for mi: MeshInstance3D in _meshes_under(_sandbox.grid):
		assert_null(mi.material_override, "%s: GridView 메시 material_override == null (%s)" % [mi.name, what])


func test_set_resource_is_valid() -> void:
	assert_not_null(_set, "shader_placeholders.tres 는 ShaderPlaceholderSet")
	assert_eq(_set.get_errors().size(), 0, "설정 오류 없음: %s" % ", ".join(_set.get_errors()))
	# 티켓 치수(style-guide 표기 w×d, 높이).
	assert_eq(_set.bar_size_m, Vector3(3.0, 1.1, 1.0), "바 카운터 3×1, 높이 1.1")
	assert_eq(_set.stage_size_m, Vector3(4.0, 0.6, 3.0), "무대 4×3, 높이 0.6")
	assert_almost_eq(_set.character_radius_m * 2.0, 0.5, EPS, "캡슐 지름 0.5")
	assert_almost_eq(_set.character_height_m, 1.7, EPS, "캡슐 높이 1.7")
	assert_eq(_set.character_offsets_m.size(), 5, "캡슐 5개")
	assert_eq(_set.spot_offsets_m.size(), 3, "컬러 스포트 3개")
	assert_eq(_set.get_mesh_count(), 8, "메시 = 바 1 + 무대 1 + 캡슐 5 + 벽 1")


func test_sandbox_without_material_has_no_placeholders() -> void:
	assert_eq(_placeholder_nodes().size(), 0, "인자 없이 열면 ShaderPlaceholders 없음")
	assert_null(_sandbox.get_placeholders())
	assert_eq(_sandbox.get_material_id(), "", "시안 없음")
	assert_false(_sandbox.hud.get_text().contains("시안"), "HUD 에 시안 줄 없음(SE-002 화면)")
	# 시안 키를 눌러도 플레이스홀더를 만들지 않는다(SE-002 동작 그대로).
	var snap: Dictionary = _excluded_snapshot()
	_press(InputActions.SHADER_VARIANT_1)
	assert_eq(_placeholder_nodes().size(), 0, "--material= 없이는 시안 키 무시")
	_assert_excluded_untouched(snap, "시안 키 후")


func test_sandbox_material_arg_spawns_and_applies() -> void:
	var snap: Dictionary = _excluded_snapshot()
	assert_true(_sandbox.apply_material("a"), "apply_material(a)")
	var nodes: Array[Node] = _placeholder_nodes()
	assert_eq(nodes.size(), 1, "ShaderPlaceholders 1개")
	if nodes.size() != 1:
		return
	var ph: ShaderPlaceholders = nodes[0] as ShaderPlaceholders
	assert_eq(ph, _sandbox.get_placeholders())
	assert_true(ph.position.is_equal_approx(_sandbox.grid.get_center_world()), "세트 기준점 = 그리드 중심")
	var meshes: Array[MeshInstance3D] = _meshes_under(ph)
	assert_eq(meshes.size(), _set.get_mesh_count(), "MeshInstance3D 수 = 치수 리소스 개수")
	assert_eq(meshes.size(), 8, "바 1 + 무대 1 + 캡슐 5 + 벽 1 = 8")
	var toon_a: Material = load(TOON_TRES_PATTERN % "a")
	for mi: MeshInstance3D in meshes:
		assert_eq(mi.material_override, toon_a, "%s: toon_a.tres" % mi.name)
	_assert_excluded_untouched(snap, "a 적용 후")
	assert_eq(ph.get_spot_lights().size(), _set.spot_offsets_m.size(), "컬러 스포트 수")
	assert_string_contains(_sandbox.hud.get_text(), "시안: a")
	assert_eq(_sandbox.get_material_id(), "a")

	# 치수: 박스는 리소스 크기 그대로, 바닥 위(피벗 = 바닥 중심).
	var by_name: Dictionary = {}
	for mi: MeshInstance3D in meshes:
		by_name[String(mi.name)] = mi
	var sizes: Dictionary = {"Bar": _set.bar_size_m, "Stage": _set.stage_size_m, "Wall": _set.wall_size_m}
	for n: String in sizes.keys():
		var mi: MeshInstance3D = by_name.get(n)
		assert_not_null(mi, "%s 메시" % n)
		if mi == null:
			continue
		assert_true(mi.mesh.get_aabb().size.is_equal_approx(sizes[n]), "%s 크기 = 리소스 값" % n)
		var bottom: float = (mi.global_transform * mi.mesh.get_aabb().position).y
		assert_almost_eq(bottom, 0.0, EPS, "%s 바닥 y = 0" % n)
	var cap: MeshInstance3D = by_name.get(ShaderPlaceholders.CHARACTER_NAME_PATTERN % 0)
	assert_not_null(cap, "캐릭터 캡슐")
	if cap != null:
		assert_almost_eq(cap.mesh.get_aabb().size.y, _set.character_height_m, EPS, "캡슐 높이")
		assert_almost_eq(cap.mesh.get_aabb().size.x, _set.character_radius_m * 2.0, EPS, "캡슐 지름")

	# 런타임 전환: shader_variant_2 → b. 노드는 늘지 않는다.
	var count_before: int = _sandbox.find_children("*", "", true, false).size()
	_press(InputActions.SHADER_VARIANT_2)
	var toon_b: Material = load(TOON_TRES_PATTERN % "b")
	for mi: MeshInstance3D in _meshes_under(ph):
		assert_eq(mi.material_override, toon_b, "%s: shader_variant_2 → toon_b.tres" % mi.name)
	_assert_excluded_untouched(snap, "b 전환 후")
	assert_eq(_placeholder_nodes().size(), 1, "전환해도 플레이스홀더는 1개")
	assert_eq(_sandbox.find_children("*", "", true, false).size(), count_before, "전환은 노드를 추가하지 않는다")
	assert_string_contains(_sandbox.hud.get_text(), "시안: b")
	_press(InputActions.SHADER_VARIANT_3)
	assert_eq(meshes[0].material_override, load(TOON_TRES_PATTERN % "c"), "shader_variant_3 → c")
	_press(InputActions.SHADER_VARIANT_1)
	assert_eq(meshes[0].material_override, toon_a, "shader_variant_1 → a")
	# default 로 되돌리면 원래(정점색 StandardMaterial3D).
	assert_true(_sandbox.apply_material("default"))
	for mi: MeshInstance3D in _meshes_under(ph):
		assert_null(mi.material_override, "%s: default → null" % mi.name)
		assert_true(mi.mesh.surface_get_material(0) is StandardMaterial3D, "%s: 기본 머티리얼" % mi.name)
		assert_true((mi.mesh.surface_get_material(0) as StandardMaterial3D).vertex_color_use_as_albedo, "정점색 albedo")


func test_bad_material_id_rejected() -> void:
	assert_false(_sandbox.apply_material("zzz"), "없는 id → false")
	assert_push_error("zzz")
	assert_eq(_placeholder_nodes().size(), 0, "플레이스홀더를 만들지 않는다")
	assert_eq(_sandbox.get_material_id(), "", "시안 그대로(없음)")
	assert_false(_sandbox.hud.get_text().contains("시안"), "HUD 그대로")
