extends GutTest
## SE-037 qa 추가 테스트(render-engineer 테스트가 덮지 않는 틈, 변이 테스트에서 확인).
##  - AC5 동적 확인: 팔레트 버튼·탭이 *주입한 카탈로그* 를 따라간다(행 수 리터럴 하드코딩 변이는 20행 데이터로는 안 잡힌다).
##  - G4: rotation_degrees.y 가 방향표의 정면 방향(−z 기준)과 일치한다(90 → −x, 180 → +z, 270 → +x).
##  - 고스트 상자가 회전·점유 사각형(G3·G5)을 따라간다. 회전한 점유 셀로 겹침을 판정한다.

const PALETTE_SCENE: String = "res://ui/build/build_palette.tscn"
const EPS: float = 0.0001

var _t: float


func before_all() -> void:
	InputActions.register_build()


func before_each() -> void:
	_t = ViewTestUtil.expected_tile_size_m()


func _palette_for(furniture: Dictionary) -> BuildPalette:
	var catalog: BuildCatalog = BuildCatalog.from_dicts(furniture, BuildTestUtil.map_json())
	assert_not_null(catalog, "수정한 사본으로 카탈로그 생성")
	var palette: BuildPalette = (load(PALETTE_SCENE) as PackedScene).instantiate() as BuildPalette
	add_child_autofree(palette)
	palette.bind(EventBus.new(), catalog, null, null)
	return palette


func test_palette_follows_injected_row_count() -> void:
	var f: Dictionary = BuildTestUtil.furniture_json()
	var rows: Array = f["rows"]
	var base: int = rows.size()
	# 행 3개 제거 → 버튼 수가 따라 줄어든다.
	var fewer: Dictionary = f.duplicate(true)
	for i: int in 3:
		(fewer["rows"] as Array).pop_back()
	assert_eq(_palette_for(fewer).get_item_buttons().size(), base - 3, "행 %d개 → 버튼 %d개" % [base - 3, base - 3])
	# 행 2개 추가(새 id) → 늘어난다.
	var more: Dictionary = f.duplicate(true)
	for k: int in 2:
		var extra: Dictionary = (rows[0] as Dictionary).duplicate(true)
		extra["id"] = "qa_extra_%d" % k
		extra["name"] = "QA 가구 %d" % k
		(more["rows"] as Array).append(extra)
	var p: BuildPalette = _palette_for(more)
	assert_eq(p.get_item_buttons().size(), base + 2, "행 %d개 → 버튼 %d개" % [base + 2, base + 2])
	assert_not_null(p.get_item_button("qa_extra_1"), "새 행 버튼")


func test_palette_tabs_follow_injected_categories() -> void:
	var f: Dictionary = BuildTestUtil.furniture_json().duplicate(true)
	var drop: String = str((f["rows"] as Array)[-1]["category"])
	var kept: Array = []
	for r: Dictionary in f["rows"]:
		if r["category"] != drop:
			kept.append(r)
	f["rows"] = kept
	var cats: Array[String] = []
	for r: Dictionary in kept:
		if not cats.has(r["category"]):
			cats.append(r["category"])
	var tabs: Array[Button] = _palette_for(f).get_tab_buttons()
	assert_eq(tabs.size(), cats.size(), "카테고리 하나를 빼면 탭도 하나 준다 (%s)" % drop)
	for t: Button in tabs:
		assert_ne(str(t.get_meta(BuildPalette.META_CATEGORY)), drop, "빠진 카테고리 탭 없음")


func test_furniture_front_matches_rotation_table() -> void:
	# build.md G4·방향표: 모델 정면은 회전 0 에서 −z, 90 → −x, 180 → +z, 270 → +x.
	var bus: EventBus = EventBus.new()
	var view: FurnitureView = FurnitureView.new()
	add_child_autofree(view)
	view.bind(bus, BuildTestUtil.catalog(), _t)
	var fronts: Dictionary = {0: Vector3(0, 0, -1), 90: Vector3(-1, 0, 0), 180: Vector3(0, 0, 1), 270: Vector3(1, 0, 0)}
	var n: int = 1
	for rot: int in fronts.keys():
		bus.publish("build.placed", BuildTestUtil.placed("f%d" % n, "speaker_floor", Vector2i(n * 2, 3), rot))
		var node: Node3D = view.get_instance_node("f%d" % n)
		var front: Vector3 = node.basis * Vector3(0, 0, -1)
		assert_true(front.is_equal_approx(fronts[rot]), "rotation %d 정면 %s == %s" % [rot, front, fronts[rot]])
		n += 1


func test_ghost_box_follows_rotation_and_footprint() -> void:
	var bus: EventBus = EventBus.new()
	var catalog: BuildCatalog = BuildTestUtil.catalog()
	var view: FurnitureView = FurnitureView.new()
	add_child_autofree(view)
	view.bind(bus, catalog, _t)
	var ghost: PlacementGhost = PlacementGhost.new()
	add_child_autofree(ghost)
	ghost.bind(bus, catalog, view, _t)
	var row: Dictionary = BuildTestUtil.row("bar_counter")
	var fp: Array = row["footprint"]
	var h: float = float(row["height_m"])
	ghost.select("bar_counter")
	ghost.rotate_selection()   # 90
	ghost.hover(Vector2i(20, 4))
	var box: MeshInstance3D = ghost.get_node(^"GhostBox") as MeshInstance3D
	# 회전 90: [W', D'] = [d, w] = [1, 3] → 중심 = ((20 + 0.5) t, h/2, (4 + 1.5) t), 상자 노드 y 회전 90.
	assert_true(box.position.is_equal_approx(Vector3(20.5 * _t, h * 0.5, 5.5 * _t)), "고스트 위치 G5 (회전 90): %s" % box.position)
	assert_almost_eq(box.rotation_degrees.y, 90.0, EPS, "고스트 회전")
	var size: Vector3 = (box.mesh as BoxMesh).size
	var pad: float = ghost.params.ghost_padding_m
	assert_almost_eq(size.x, float(fp[0]) * _t + pad, EPS, "상자 x = footprint.w (회전 전 기준)")
	assert_almost_eq(size.z, float(fp[1]) * _t + pad, EPS, "상자 z = footprint.d")
	assert_almost_eq(size.y, h + pad, EPS, "상자 높이 = height_m")
	var world: AABB = box.transform * (box.mesh as BoxMesh).get_aabb()
	assert_almost_eq(world.size.x, 1.0 * _t + pad, 0.001, "월드 폭 x = W'")
	assert_almost_eq(world.size.z, 3.0 * _t + pad, 0.001, "월드 폭 z = D'")


func test_overlap_uses_rotated_cells() -> void:
	var bus: EventBus = EventBus.new()
	var catalog: BuildCatalog = BuildTestUtil.catalog()
	var view: FurnitureView = FurnitureView.new()
	add_child_autofree(view)
	view.bind(bus, catalog, _t)
	var ghost: PlacementGhost = PlacementGhost.new()
	add_child_autofree(ghost)
	ghost.bind(bus, catalog, view, _t)
	bus.publish("build.placed", BuildTestUtil.placed("f1", "stage_small", Vector2i(10, 20), 0))   # x10..13, z20..22
	# bar_counter [3,1] 를 [13,19] 에: 회전 0 → x13..15, z19 (겹침 없음), 회전 90 → x13, z19..21 ([13,20] 겹침).
	assert_eq(ghost.estimate_reason("bar_counter", Vector2i(13, 19), 0), "", "회전 0: 겹침 없음")
	assert_eq(ghost.estimate_reason("bar_counter", Vector2i(13, 19), 90), "overlap", "회전 90: 회전한 셀로 겹침")
	assert_eq(ghost.estimate_reason("bar_counter", Vector2i(13, 19), 270), "overlap", "회전 270 도 같은 점유")
	# 맵 안/밖·벽 판정도 회전한 사각형 기준(맵 24×24, 바깥 둘레는 벽).
	assert_eq(ghost.estimate_reason("bar_counter", Vector2i(22, 5), 0), "out_of_bounds", "r0 x22..24 → x24 맵 밖")
	assert_eq(ghost.estimate_reason("bar_counter", Vector2i(22, 5), 90), "", "r90 x22, z5..7 → 바닥(같은 셀이 r0 이면 밖이다)")
	assert_eq(ghost.estimate_reason("bar_counter", Vector2i(22, 22), 90), "out_of_bounds", "r90 x22, z22..24 → z24 맵 밖")
	assert_eq(ghost.estimate_reason("bar_counter", Vector2i(22, 21), 90), "blocked_tile", "r90 x22, z21..23 → z23 벽")


func test_confirm_without_selection_or_hover_sends_nothing() -> void:
	var bus: EventBus = EventBus.new()
	var catalog: BuildCatalog = BuildTestUtil.catalog()
	var ghost: PlacementGhost = PlacementGhost.new()
	add_child_autofree(ghost)
	ghost.bind(bus, catalog, null, _t)
	BuildTestUtil.press(ghost, InputActions.BUILD_CONFIRM)
	assert_eq(bus.get_pending_commands().size(), 0, "선택·호버 없이 클릭 → 0건")
	ghost.select("speaker_floor")
	BuildTestUtil.press(ghost, InputActions.BUILD_CONFIRM)
	assert_eq(bus.get_pending_commands().size(), 0, "호버 없이 클릭 → 0건")
