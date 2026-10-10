extends GutTest
## SE-040 qa: AC-37f 정식 통합 확인. 실제 GameSession(Economy+BuildSystem+TickLoop 버스) 위에서 main.tscn 을 돌려
## 배치 → build.placed → 가구 노드 → build.coverage_changed → 오버레이 갱신 → 자금 부족 build.rejected → 알림(토스트 피드).
## test_main_scene.gd(render)는 노드 수까지만 보고, 이 파일이 오버레이 내용과 거절 알림을 덮는다.
## 진행은 session.advance(0)(경계 처리). 기대값은 sim 이벤트 페이로드·ui_ko.json 에서 읽는다(리터럴 문구 없음).

const MAIN_SCENE: String = "res://view/scenes/main.tscn"
const SAVES: String = "user://test_se040_qa"
const REASON_FUNDS: String = "insufficient_cash"
const MODE_SOUND: String = "sound"


func after_each() -> void:
	var d: DirAccess = DirAccess.open(SAVES)
	if d != null:
		for f: String in d.get_files():
			d.remove(f)
		DirAccess.remove_absolute(SAVES)


func _main() -> MainScene:
	var m: MainScene = (load(MAIN_SCENE) as PackedScene).instantiate() as MainScene
	m.use_cmdline_args = false
	m.boot_args = PackedStringArray(["--se-seed=0"])
	m.drive_realtime = false
	m.saves_dir = SAVES
	add_child_autofree(m)
	m.get_ui_root().menu.get_new_game_button().pressed.emit()
	m.session.advance(0)
	return m


func _place_via_ghost(m: MainScene, p: Dictionary) -> bool:
	var g: PlacementGhost = m.get_placement_ghost()
	g.select(str(p["furniture_id"]))
	while g.get_rotation_deg() != int(p["rotation"]):
		g.rotate_selection()
	g.hover(BuildCatalog.to_cell(p["cell"]))
	var ok: bool = g.click()
	g.cancel()
	m.session.advance(0)
	return ok


func _unique_cells(pairs: Array) -> Dictionary:
	var out: Dictionary = {}
	for pair: Variant in pairs:
		out[BuildCatalog.to_cell(pair)] = true
	return out


func test_place_node_overlay_then_insufficient_cash_toast_ac37f() -> void:
	var m: MainScene = _main()
	var bus: EventBus = m.session.bus
	var placed: Array = []
	var coverage: Array = []
	var rejected: Array = []
	bus.subscribe("build.placed", func(p: Dictionary) -> void: placed.append(p))
	bus.subscribe("build.coverage_changed", func(p: Dictionary) -> void: coverage.append(p))
	bus.subscribe("build.rejected", func(p: Dictionary) -> void: rejected.append(p))
	var ov: CoverageOverlay = m.get_coverage_overlay()
	assert_true(ov.set_mode(MODE_SOUND), "오버레이 음향 모드")
	assert_eq(ov.get_decal_count(), 0, "배치 전 오버레이 비어 있음")
	var layout: Array = BuildCatalog.load_default().reference_layout(MainScene.AUTOPLAY_LAYOUT_ID)["placements"]
	var cash0: int = m.session.economy.cash
	# 1) 무대 배치 → build.placed → 가구 노드 + 자금 차감.
	assert_true(_place_via_ghost(m, layout[0]), "무대 클릭")
	assert_eq(placed.size(), 1, "build.placed 1건")
	assert_eq(m.get_furniture_view().get_instance_count(), m.session.build.instances.size(), "가구 노드 = build 인스턴스")
	assert_eq(m.get_furniture_view().get_instance_count(), 1)
	assert_eq(m.session.economy.cash, cash0 - int(placed[0]["cost"]), "자금 = 시작 − 건설비(build.placed.cost)")
	assert_eq(m.get_ui_root().hud.get_cash(), m.session.economy.cash, "HUD 현금 = economy.cash")
	# 2) 스피커 배치 → coverage_changed → 오버레이 갱신(데칼 수·색이 페이로드와 일치).
	var n_cov: int = coverage.size()
	var sound_before: int = 0
	if n_cov > 0:
		sound_before = (coverage[n_cov - 1].get(CoverageOverlay.MODE_TILE_KEYS[MODE_SOUND], []) as Array).size()
	assert_true(_place_via_ghost(m, layout[1]), "스피커 클릭")
	assert_gt(coverage.size(), n_cov, "스피커 배치 → build.coverage_changed 발행")
	var last: Dictionary = coverage[coverage.size() - 1]
	var sound_after: Array = last.get(CoverageOverlay.MODE_TILE_KEYS[MODE_SOUND], [])
	var viewing: Dictionary = _unique_cells(last.get(CoverageOverlay.VIEWING_KEY, []))
	var covered: Dictionary = _unique_cells(sound_after)
	assert_true(ov.has_coverage(), "오버레이가 커버리지를 받음")
	assert_gt(sound_after.size(), sound_before, "스피커가 음향 덮임 타일을 늘린다")
	assert_gt(viewing.size(), 0, "관람 타일 있음")
	assert_eq(ov.get_decal_count(), viewing.size(), "데칼 수 = 페이로드 관람 타일 수(중복 제외)")
	var covered_color: Color = ov.params.overlay_covered_colors[MODE_SOUND]
	var checked: int = 0
	for c: Vector2i in ov.get_decal_cells():
		var want: Color = covered_color if covered.has(c) else ov.params.overlay_uncovered_color
		assert_eq(ov.get_tile_color(c), want, "타일 %s 색 = 덮임 여부" % c)
		checked += 1
	assert_eq(checked, viewing.size())
	assert_eq(m.get_furniture_view().get_instance_count(), 2, "가구 노드 2")
	# 3) 자금 부족: 가장 비싼 가구를 놓을 수 없을 때까지 돈을 쓰고, 남은 돈보다 비싼 가구를 한 번 더 요청한다.
	var catalog: BuildCatalog = BuildCatalog.load_default()
	var rows: Array = []
	for cat: String in catalog.categories():
		for r: Dictionary in catalog.rows_in_category(cat):
			if str(r["category"]) != "stage":
				rows.append([int(r["build_cost"]), str(r["id"])])
	rows.sort()
	rows.reverse()
	var size: Vector2i = catalog.get_map_size()
	for e: Array in rows:
		for z: int in range(size.y):
			for x: int in range(size.x):
				if m.session.economy.cash >= int(e[0]) and m.session.check_place(str(e[1]), Vector2i(x, z), 0) == "":
					bus.publish("build.place_requested", {"furniture_id": e[1], "cell": [x, z], "rotation": 0})
					m.session.advance(0)
	assert_eq(rejected.size(), 0, "소비 단계에서는 거절 0(자금 확인 후 요청)")
	var target: Array = []
	var cell: Vector2i = Vector2i(-1, -1)
	for e: Array in rows:
		if int(e[0]) <= m.session.economy.cash:
			continue
		for z: int in range(size.y):
			for x: int in range(size.x):
				if cell.x < 0 and m.session.check_place(str(e[1]), Vector2i(x, z), 0) == "":
					cell = Vector2i(x, z)
					target = e
	assert_false(target.is_empty(), "남은 돈보다 비싸고 놓을 칸이 있는 가구가 있다")
	var cash_before: int = m.session.economy.cash
	var nodes_before: int = m.get_furniture_view().get_instance_count()
	var inst_before: int = m.session.build.instances.size()
	var feed_before: int = m.get_ui_root().notifications.get_entries().size()
	bus.publish("build.place_requested", {"furniture_id": target[1], "cell": [cell.x, cell.y], "rotation": 0})
	m.session.advance(0)
	assert_eq(rejected.size(), 1, "build.rejected 1건")
	assert_eq(str(rejected[0]["reason"]), REASON_FUNDS, "사유 = 자금 부족")
	assert_eq(str(rejected[0]["furniture_id"]), str(target[1]), "거절 페이로드 furniture_id")
	assert_eq(m.session.economy.cash, cash_before, "거절 뒤 자금 불변")
	assert_eq(m.session.build.instances.size(), inst_before, "거절 뒤 인스턴스 불변")
	assert_eq(m.get_furniture_view().get_instance_count(), nodes_before, "거절 뒤 가구 노드 불변")
	assert_eq(m.get_ui_root().hud.get_cash(), cash_before, "HUD 현금 불변")
	var feed: PackedStringArray = m.get_ui_root().notifications.get_entry_texts()
	assert_eq(feed.size(), feed_before + 1, "알림 1줄 추가")
	var text: UiText = UiText.load_default()
	var want_text: String = text.t("ui.notify.build", {"reason": text.t("ui.reason.build.%s" % REASON_FUNDS)})
	assert_eq(feed[feed.size() - 1], want_text, "알림 문구 = ui_ko.json(자금 부족)")
	assert_false(want_text.contains("ui."), "키 문자열이 새지 않는다")
	assert_ne(want_text, "", "문구 비어 있지 않음")
	# 4) 거절은 커버리지를 바꾸지 않는다.
	var cov_n: int = coverage.size()
	bus.publish("build.place_requested", {"furniture_id": target[1], "cell": [cell.x, cell.y], "rotation": 0})
	m.session.advance(0)
	assert_eq(coverage.size(), cov_n, "거절은 build.coverage_changed 를 내지 않는다")
	var errs: int = 0
	for e: Variant in get_errors():
		if e.is_push_error():
			errs += 1
	assert_eq(errs, 0, "push_error 0")
