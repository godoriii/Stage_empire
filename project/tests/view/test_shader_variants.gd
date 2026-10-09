extends GutTest
## SE-004 AC4(시안 id 해석·검증·로드), AC5(apply: material_override + next_pass, 노드 추가 없음, 순환 후 같은 상태).
## SE-018 AC1(기본 = b, 예전 룩 = plain, "default" 무효), AC2(로드 실패 push_error, apply -1·변경 없음).

const TOON_TRES_PATTERN: String = "res://view/shaders/params/toon_%s.tres"
const OUTLINE_TRES_PATTERN: String = "res://view/shaders/params/outline_%s.tres"


# --- AC4 ------------------------------------------------------------------

func test_resolve_and_validate_ids() -> void:
	var none: PackedStringArray = PackedStringArray()
	assert_eq(ShaderVariants.resolve_material_id("", none, "x"), "x", "인자 없으면 기본값")
	assert_eq(ShaderVariants.resolve_material_id("", PackedStringArray(["--config=E", "--material=B"]), "x"), "b", "명령줄, 소문자화")
	assert_eq(ShaderVariants.resolve_material_id("C", PackedStringArray(["--material=a"]), "x"), "c", "@export 우선, 소문자화")
	assert_eq(ShaderVariants.resolve_material_id("", PackedStringArray(["--material=zzz"]), "x"), "zzz", "유효성은 검사하지 않는다")
	assert_eq(ShaderVariants.resolve_material_id("", none, ""), "", "기본값이 빈 문자열이면 빈 문자열")
	for id: String in ["plain", "a", "b", "c"]:
		assert_true(ShaderVariants.is_valid_id(id), "%s 유효" % id)
	for id: String in ["", "d", "unlit", "A", "default"]:
		assert_false(ShaderVariants.is_valid_id(id), "'%s' 무효" % id)
	for id: String in ["a", "b", "c"]:
		var mat: ShaderMaterial = ShaderVariants.load_material(id)
		assert_not_null(mat, "load_material(%s)" % id)
		assert_eq(mat, load(TOON_TRES_PATTERN % id), "load_material(%s) == toon_%s.tres (같은 리소스)" % [id, id])
	assert_null(ShaderVariants.load_material("plain"), "plain → null")
	assert_null(ShaderVariants.load_material("default"), "default(SE-018 부터 없는 id) → null")
	assert_null(ShaderVariants.load_material("zzz"), "없는 id → null")
	assert_eq(get_errors().size(), 0, "plain·없는 id 의 load_material 은 push_error 하지 않는다")


# --- SE-018 AC1 -------------------------------------------------------------

func test_default_is_b_and_plain_is_legacy() -> void:
	assert_eq(ShaderVariants.DEFAULT_ID, "b", "기본 시안 = b(SE-018)")
	assert_eq(ShaderVariants.IDS, PackedStringArray(["plain", "a", "b", "c", "ss"]), "시안 id 목록(SE-021 ss 추가)")
	assert_eq(ShaderVariants.SELECTABLE_IDS, PackedStringArray(["a", "b", "c"]), "런타임 전환 시안 불변")
	assert_false(ShaderVariants.is_valid_id("default"), "\"default\" 는 더 이상 유효 id 가 아니다")
	assert_true(ShaderVariants.is_valid_id("plain"), "plain 유효")
	assert_eq(ShaderVariants.resolve_material_id("", PackedStringArray(), ShaderVariants.DEFAULT_ID), "b", "인자 없으면 b")
	assert_eq(ShaderVariants.resolve_material_id("", PackedStringArray(["--material=PLAIN"]), ShaderVariants.DEFAULT_ID), "plain",
		"--material=PLAIN → plain")
	var b: ShaderMaterial = ShaderVariants.load_material("b")
	assert_not_null(b, "load_material(b)")
	if b != null:
		assert_eq(b.resource_path, "res://view/shaders/params/toon_b.tres", "기본 시안 리소스 경로")
	assert_null(ShaderVariants.load_material("plain"), "plain → null(의도된 값)")
	assert_eq(get_errors().size(), 0, "plain 로드는 push_error 0")


# --- SE-018 AC2 -------------------------------------------------------------

func test_load_failure_pushes_error_and_apply_changes_nothing() -> void:
	var bad_pattern: String = "res://view/shaders/params/nope_%s.tres"
	var bad_path: String = bad_pattern % "b"
	assert_null(ShaderVariants.load_material("b", bad_pattern), "로드 실패 → null")
	var errs: Array = _push_errors()
	assert_eq(errs.size(), 1, "로드 실패 push_error 정확히 1건")
	if errs.size() == 1:
		assert_true(errs[0].contains_text("'b'"), "메시지에 id: %s" % errs[0].code)
		assert_true(errs[0].contains_text(bad_path), "메시지에 경로: %s" % errs[0].code)
	assert_push_error_count(1, "로드 실패 push_error 1건")

	var t: Dictionary = _make_tree()
	var root: Node3D = t["root"]
	ShaderVariants.apply(root, "c", [])
	var all: Array[GeometryInstance3D] = []
	for n: Node in root.find_children("*", "GeometryInstance3D", true, false):
		all.append(n as GeometryInstance3D)
	all.append_array(t["targets"])
	var snap: Dictionary = {}
	for g: GeometryInstance3D in all:
		snap[g] = g.material_override
	var before_nodes: int = _descendant_count(root)
	assert_eq(ShaderVariants.apply(root, "b", [], bad_pattern), -1, "로드 실패 시 apply → -1")
	assert_push_error_count(2, "apply 로드 실패 push_error 누적 2건")
	for g: GeometryInstance3D in snap.keys():
		assert_eq(g.material_override, snap[g], "%s: 로드 실패 apply 는 아무것도 바꾸지 않는다" % g.name)
	assert_eq(_descendant_count(root), before_nodes, "노드 수 그대로")

	# 기본 패턴은 기존대로 적용 수를 돌려준다.
	var targets: Array[GeometryInstance3D] = t["targets"]
	assert_eq(ShaderVariants.apply(root, "b"), targets.size() + (t["excluded_meshes"] as Array).size(), "기본 패턴 apply(b) = 전체 메시 수")
	var exclude: Array[Node] = [t["excluded"]]
	assert_eq(ShaderVariants.apply(root, "b", exclude), targets.size(), "exclude 있으면 대상 수")
	for g: GeometryInstance3D in targets:
		assert_eq(g.material_override, load(TOON_TRES_PATTERN % "b"), "%s: toon_b.tres" % g.name)


# --- AC5 ------------------------------------------------------------------

## 이 테스트에서 지금까지 난 push_error(GutTrackedError).
func _push_errors() -> Array:
	var out: Array = []
	for e: Variant in get_errors():
		if e.is_push_error():
			out.append(e)
	return out

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

	assert_eq(ShaderVariants.apply(root, "plain", exclude), targets.size(), "plain 도 같은 수")
	for g: GeometryInstance3D in targets:
		assert_null(g.material_override, "plain → material_override == null")

	# a → b → c → plain → a 를 돌려도 마지막 상태가 첫 apply("a") 와 같다.
	ShaderVariants.apply(root, "a", exclude)
	var first: Array[Material] = []
	for g: GeometryInstance3D in targets:
		first.append(g.material_override)
	for id: String in ["b", "c", "plain", "a"]:
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
	assert_eq(ShaderVariants.apply(root, "default", []), -1, "예전 default → -1(없는 id 와 같은 처리)")
	assert_push_error("'default' 없음")
	for g: GeometryInstance3D in t["targets"]:
		assert_eq(g.material_override, load(TOON_TRES_PATTERN % "c"), "없는 id 는 아무것도 바꾸지 않는다")


# --- SE-021 AC4 -------------------------------------------------------------

func test_ss_adds_exactly_one_post_pass_node() -> void:
	var t: Dictionary = _make_tree()
	var root: Node3D = t["root"]
	var targets: Array[GeometryInstance3D] = t["targets"]
	var exclude: Array[Node] = [t["excluded"]]
	var before: int = _descendant_count(root)
	var toon_ss: ShaderMaterial = load(TOON_TRES_PATTERN % "ss") as ShaderMaterial
	assert_not_null(toon_ss, "toon_ss.tres 로드")
	assert_true(ShaderVariants.is_valid_id("ss"), "ss 유효")
	assert_false(ShaderVariants.SELECTABLE_IDS.has("ss"), "ss 는 런타임 전환 키 없음")
	assert_ne(ShaderVariants.DEFAULT_ID, "ss", "기본값은 그대로(사람 Q2)")
	assert_eq(ShaderVariants.apply(root, "ss", exclude), targets.size(), "적용 수 = 대상 수(포스트 패스 노드는 세지 않음)")
	assert_eq(_descendant_count(root), before + 1, "ss: 포스트 패스 노드 정확히 1개 추가")
	var pass_node: Node = ShaderVariants.get_post_pass(root)
	assert_not_null(pass_node, "포스트 패스 노드")
	if pass_node != null:
		assert_eq(pass_node.get_parent(), root, "root 직속")
		assert_true(pass_node is MeshInstance3D, "전체 화면 쿼드 MeshInstance3D")
		assert_eq((pass_node as MeshInstance3D).material_override, load(OUTLINE_TRES_PATTERN % "ss"), "쿼드 머티리얼 == outline_ss.tres")
		assert_true(pass_node.is_in_group(ShaderVariants.POST_PASS_GROUP), "포스트 패스 그룹")
	for g: GeometryInstance3D in targets:
		assert_eq(g.material_override, toon_ss, "%s: toon_ss.tres" % g.get_class())
		assert_null(g.material_override.next_pass, "%s: ss 는 next_pass 없음" % g.get_class())
	# 2회 연속 호출해도 +1 유지.
	ShaderVariants.apply(root, "ss", exclude)
	assert_eq(_descendant_count(root), before + 1, "ss 2회: 중복 추가 없음")
	assert_eq(ShaderVariants.get_post_pass(root), pass_node, "같은 노드 유지")
	# b 로 되돌리면 노드 수 복원, next_pass 복원.
	ShaderVariants.apply(root, "b", exclude)
	assert_eq(_descendant_count(root), before, "b: 노드 수 복원")
	assert_null(ShaderVariants.get_post_pass(root), "b: 포스트 패스 없음")
	for g: GeometryInstance3D in targets:
		assert_eq(g.material_override.next_pass, load(OUTLINE_TRES_PATTERN % "b"), "%s: next_pass == outline_b.tres" % g.get_class())
	# apply_materials 는 포스트 패스를 건드리지 않는다(스파이크용).
	ShaderVariants.apply_materials(root, "ss", exclude)
	assert_eq(_descendant_count(root), before, "apply_materials: 노드 추가 없음")
	assert_eq(get_errors().size(), 0, "오류 없음")
