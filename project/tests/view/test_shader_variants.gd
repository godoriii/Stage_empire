extends GutTest
## SE-004 AC4(시안 id 해석·검증·로드), AC5(apply: material_override + next_pass, 노드 추가 없음, 순환 후 같은 상태).

const TOON_TRES_PATTERN: String = "res://view/shaders/params/toon_%s.tres"
const OUTLINE_TRES_PATTERN: String = "res://view/shaders/params/outline_%s.tres"


# --- AC4 ------------------------------------------------------------------

func test_resolve_and_validate_ids() -> void:
	var none: PackedStringArray = PackedStringArray()
	assert_eq(ShaderVariants.resolve_material_id("", none, "default"), "default", "인자 없으면 기본값")
	assert_eq(ShaderVariants.resolve_material_id("", PackedStringArray(["--config=E", "--material=B"]), "default"), "b", "명령줄, 소문자화")
	assert_eq(ShaderVariants.resolve_material_id("C", PackedStringArray(["--material=a"]), "default"), "c", "@export 우선, 소문자화")
	assert_eq(ShaderVariants.resolve_material_id("", PackedStringArray(["--material=zzz"]), "default"), "zzz", "유효성은 검사하지 않는다")
	assert_eq(ShaderVariants.resolve_material_id("", none, ""), "", "기본값이 빈 문자열이면 빈 문자열(샌드박스: 시안 없음)")
	assert_eq(ShaderVariants.IDS, PackedStringArray(["default", "a", "b", "c"]), "시안 id 목록")
	for id: String in ["default", "a", "b", "c"]:
		assert_true(ShaderVariants.is_valid_id(id), "%s 유효" % id)
	for id: String in ["", "d", "unlit", "A"]:
		assert_false(ShaderVariants.is_valid_id(id), "'%s' 무효" % id)
	for id: String in ["a", "b", "c"]:
		var mat: ShaderMaterial = ShaderVariants.load_material(id)
		assert_not_null(mat, "load_material(%s)" % id)
		assert_eq(mat, load(TOON_TRES_PATTERN % id), "load_material(%s) == toon_%s.tres (같은 리소스)" % [id, id])
	assert_null(ShaderVariants.load_material("default"), "default → null")
	assert_null(ShaderVariants.load_material("zzz"), "없는 id → null")


# --- AC5 ------------------------------------------------------------------

## 검사용 트리: 루트 아래 MeshInstance3D 2(하나는 중첩), MultiMeshInstance3D 1, 제외 서브트리(MeshInstance3D 2), Label3D 1.
func _make_tree() -> Dictionary:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var a: MeshInstance3D = MeshInstance3D.new()
	a.mesh = BoxMesh.new()
	root.add_child(a)
	var group: Node3D = Node3D.new()
	root.add_child(group)
	var b: MeshInstance3D = MeshInstance3D.new()
	b.mesh = CapsuleMesh.new()
	group.add_child(b)
	var mm: MultiMeshInstance3D = MultiMeshInstance3D.new()
	mm.multimesh = MultiMesh.new()
	mm.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mm.multimesh.mesh = BoxMesh.new()
	mm.multimesh.instance_count = 4
	root.add_child(mm)
	var excluded: Node3D = Node3D.new()
	root.add_child(excluded)
	var ex1: MeshInstance3D = MeshInstance3D.new()
	excluded.add_child(ex1)
	var ex2: MeshInstance3D = MeshInstance3D.new()
	ex1.add_child(ex2)
	var label: Label3D = Label3D.new()
	root.add_child(label)
	var targets: Array[GeometryInstance3D] = [a, b, mm]
	return {"root": root, "targets": targets, "excluded": excluded, "excluded_meshes": [ex1, ex2], "label": label}


func _descendant_count(n: Node) -> int:
	var c: int = 0
	for child: Node in n.get_children():
		c += 1 + _descendant_count(child)
	return c


func test_apply_sets_override_and_next_pass_without_new_nodes() -> void:
	var t: Dictionary = _make_tree()
	var root: Node3D = t["root"]
	var targets: Array[GeometryInstance3D] = t["targets"]
	var exclude: Array[Node] = [t["excluded"]]
	var before: int = _descendant_count(root)
	var n: int = ShaderVariants.apply(root, "b", exclude)
	assert_eq(n, targets.size(), "적용 수 = 대상 MeshInstance3D·MultiMeshInstance3D 수")
	assert_eq(_descendant_count(root), before, "외곽선은 next_pass 라 노드가 늘지 않는다")
	var toon_b: ShaderMaterial = load(TOON_TRES_PATTERN % "b") as ShaderMaterial
	var outline_b: ShaderMaterial = load(OUTLINE_TRES_PATTERN % "b") as ShaderMaterial
	for g: GeometryInstance3D in targets:
		assert_eq(g.material_override, toon_b, "%s: material_override == toon_b.tres" % g.get_class())
		assert_eq(g.material_override.next_pass, outline_b, "%s: next_pass == outline_b.tres" % g.get_class())
	for ex: MeshInstance3D in t["excluded_meshes"]:
		assert_null(ex.material_override, "exclude 서브트리는 그대로")
	assert_null((t["label"] as Label3D).material_override, "Label3D(글자)는 대상 아님")

	assert_eq(ShaderVariants.apply(root, "default", exclude), targets.size(), "default 도 같은 수")
	for g: GeometryInstance3D in targets:
		assert_null(g.material_override, "default → material_override == null")

	# a → b → c → default → a 를 돌려도 마지막 상태가 첫 apply("a") 와 같다.
	ShaderVariants.apply(root, "a", exclude)
	var first: Array[Material] = []
	for g: GeometryInstance3D in targets:
		first.append(g.material_override)
	for id: String in ["b", "c", "default", "a"]:
		ShaderVariants.apply(root, id, exclude)
	for i: int in targets.size():
		assert_eq(targets[i].material_override, first[i], "순환 후 같은 머티리얼")
		assert_eq(targets[i].material_override, load(TOON_TRES_PATTERN % "a"), "toon_a.tres")
	assert_eq(_descendant_count(root), before, "순환 후에도 노드 수 그대로")


func test_apply_rejects_unknown_id_without_changes() -> void:
	var t: Dictionary = _make_tree()
	var root: Node3D = t["root"]
	ShaderVariants.apply(root, "c", [])
	assert_eq(ShaderVariants.apply(root, "zzz", []), -1, "없는 id → -1")
	assert_push_error("zzz")
	for g: GeometryInstance3D in t["targets"]:
		assert_eq(g.material_override, load(TOON_TRES_PATTERN % "c"), "없는 id 는 아무것도 바꾸지 않는다")
