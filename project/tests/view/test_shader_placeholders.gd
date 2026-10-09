extends GutTest
## SE-004 AC8: 샌드박스 --material= 상당(GridSandbox.apply_material)으로 플레이스홀더 세트 생성·시안 적용,
## shader_variant_* 액션으로 런타임 전환, 없는 id 거부.
## SE-018 AC4: 인자 없이 열면 플레이스홀더 + 시안 B(ShaderVariants.DEFAULT_ID), plain = 예전 룩, "default" 는 없는 id.

const SANDBOX_SCENE: String = "res://view/scenes/grid_sandbox.tscn"
const SET_PATH: String = "res://view/scenes/shader_placeholders.tres"
const TOON_TRES_PATTERN: String = "res://view/shaders/params/toon_%s.tres"
const OUTLINE_TRES_PATTERN: String = "res://view/shaders/params/outline_%s.tres"
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


## SE-018 AC4: 인자 없이 열면 플레이스홀더 세트 + 시안 B(기본값 ShaderVariants.DEFAULT_ID).
func test_sandbox_defaults_to_b() -> void:
	var nodes: Array[Node] = _placeholder_nodes()
	assert_eq(nodes.size(), 1, "인자 없이 열어도 ShaderPlaceholders 1개")
	if nodes.size() != 1:
		return
	var ph: ShaderPlaceholders = nodes[0] as ShaderPlaceholders
	assert_eq(ph, _sandbox.get_placeholders())
	assert_true(ph.position.is_equal_approx(_sandbox.grid.get_center_world()), "세트 기준점 = 그리드 중심")
	var meshes: Array[MeshInstance3D] = _meshes_under(ph)
	assert_eq(meshes.size(), 8, "SE-004 AC8 과 같은 세트: 바 1 + 무대 1 + 캡슐 5 + 벽 1")
	var toon_b: Material = load(TOON_TRES_PATTERN % "b")
	var outline_b: Material = load(OUTLINE_TRES_PATTERN % "b")
	for mi: MeshInstance3D in meshes:
		assert_eq(mi.material_override, toon_b, "%s: material_override == toon_b.tres" % mi.name)
		if mi.material_override != null:
			assert_eq(mi.material_override.next_pass, outline_b, "%s: next_pass == outline_b.tres" % mi.name)
	assert_eq(_sandbox.get_material_id(), "b", "기본 시안 b")
	assert_eq(_sandbox.get_material_id(), ShaderVariants.DEFAULT_ID, "기본값 출처 = ShaderVariants.DEFAULT_ID")
	assert_string_contains(_sandbox.hud.get_text(), "시안: b")
	# 바닥·커서는 시안 제외: GridView 메시 null, TileCursor 강조 메시는 자체 StandardMaterial3D(적용 전 값) 그대로.
	var snap: Dictionary = _excluded_snapshot()
	_assert_excluded_untouched(snap, "기본 적용 후")
	var cursor_meshes: Array[MeshInstance3D] = _meshes_under(_sandbox.cursor)
	assert_gt(cursor_meshes.size(), 0, "TileCursor 메시가 있다")
	for mi: MeshInstance3D in cursor_meshes:
		var cm: StandardMaterial3D = mi.material_override as StandardMaterial3D
		assert_not_null(cm, "%s: TileCursor 자체 StandardMaterial3D" % mi.name)
		if cm != null:
			assert_eq(cm.albedo_color, _sandbox.cursor.params.cursor_color, "%s: 커서 색 그대로" % mi.name)
			assert_eq(cm.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED, "%s: unshaded 그대로" % mi.name)
	# 키 1/2/3 으로 a → b → c 전환, 노드 수 불변.
	var count_before: int = _sandbox.find_children("*", "", true, false).size()
	var expected: Array[String] = ["a", "b", "c"]
	var actions: Array[StringName] = [InputActions.SHADER_VARIANT_1, InputActions.SHADER_VARIANT_2, InputActions.SHADER_VARIANT_3]
	for i: int in actions.size():
		_press(actions[i])
		assert_eq(_sandbox.get_material_id(), expected[i], "키 %d → %s" % [i + 1, expected[i]])
		assert_eq(meshes[0].material_override, load(TOON_TRES_PATTERN % expected[i]), "키 %d → toon_%s.tres" % [i + 1, expected[i]])
		assert_string_contains(_sandbox.hud.get_text(), "시안: %s" % expected[i])
	assert_eq(_placeholder_nodes().size(), 1, "전환해도 플레이스홀더는 1개")
	assert_eq(_sandbox.find_children("*", "", true, false).size(), count_before, "전환은 노드를 추가하지 않는다")
	_assert_excluded_untouched(snap, "a/b/c 전환 후")


## SE-018 AC4: --material=plain(@export 상당)이면 플레이스홀더가 SE-004 이전 룩(정점색 StandardMaterial3D).
func test_plain_restores_legacy_look() -> void:
	var plain: GridSandbox = (load(SANDBOX_SCENE) as PackedScene).instantiate() as GridSandbox
	plain.material_id = "plain"
	add_child_autofree(plain)
	assert_eq(plain.get_material_id(), "plain")
	assert_string_contains(plain.hud.get_text(), "시안: plain")
	var ph: ShaderPlaceholders = plain.get_placeholders()
	assert_not_null(ph, "plain 도 플레이스홀더 세트를 만든다")
	if ph == null:
		return
	var meshes: Array[MeshInstance3D] = _meshes_under(ph)
	assert_eq(meshes.size(), 8, "플레이스홀더 8개")
	for mi: MeshInstance3D in meshes:
		assert_null(mi.material_override, "%s: plain → material_override == null" % mi.name)
		assert_true(mi.mesh.surface_get_material(0) is StandardMaterial3D, "%s: 기본 머티리얼" % mi.name)
		assert_true((mi.mesh.surface_get_material(0) as StandardMaterial3D).vertex_color_use_as_albedo, "%s: 정점색 albedo" % mi.name)
	for mi: MeshInstance3D in _meshes_under(plain.grid):
		assert_null(mi.material_override, "%s: GridView 메시 null" % mi.name)
	assert_eq(get_errors().size(), 0, "plain 은 오류 없음")


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
	# plain 으로 되돌리면 원래(정점색 StandardMaterial3D).
	assert_true(_sandbox.apply_material("plain"))
	for mi: MeshInstance3D in _meshes_under(ph):
		assert_null(mi.material_override, "%s: plain → null" % mi.name)
		assert_true(mi.mesh.surface_get_material(0) is StandardMaterial3D, "%s: 기본 머티리얼" % mi.name)
		assert_true((mi.mesh.surface_get_material(0) as StandardMaterial3D).vertex_color_use_as_albedo, "정점색 albedo")


## SE-004 AC8 + SE-018 AC4: 없는 id(예전 "default" 포함)는 push_error + false, 상태 그대로.
## (_ready 에서 같은 거부가 나면 종료 코드 2 — 그 분기는 apply_material 의 false 를 그대로 쓴다.)
func test_bad_material_id_rejected() -> void:
	var meshes_before: Array[MeshInstance3D] = _meshes_under(_sandbox.get_placeholders())
	var toon_b: Material = load(TOON_TRES_PATTERN % "b")
	for bad: String in ["zzz", "default"]:
		assert_false(_sandbox.apply_material(bad), "없는 id '%s' → false" % bad)
		assert_push_error("'%s' 없음" % bad)
		assert_eq(_placeholder_nodes().size(), 1, "%s: 플레이스홀더를 더 만들지 않는다" % bad)
		assert_eq(_sandbox.get_material_id(), "b", "%s: 시안 그대로(b)" % bad)
		assert_string_contains(_sandbox.hud.get_text(), "시안: b")
		for mi: MeshInstance3D in meshes_before:
			assert_eq(mi.material_override, toon_b, "%s: %s 머티리얼 그대로" % [bad, mi.name])
	assert_eq(GridSandbox.EXIT_BAD_MATERIAL, 2, "없는 시안 종료 코드 2")
