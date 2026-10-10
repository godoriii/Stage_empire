extends GutTest
## SE-040 메인 씬 통합(헤드리스). 티켓의 project/tests/e2e/test_main_scene.gd 대신 여기(producer 결정 — render 쓰기 범위).
## AC2(1일 진행 → HUD·가구·군중·리포트 = sim), AC3·AC-38b·AC-39a(저장 → 새 인스턴스 --se-load → 뷰 동일, 공연 중 스포트),
## AC4(필수 조작 6회로 1일), AC-38a(배속 보간 균일), AC-38c(실제 show.ended 끝 색), AC-38f(150명 상한 경고 0),
## AC-39b(Esc: 고스트 취소 우선), AC-39c(시드·파산 → 새 게임 → 첫 마감 "다음 날" 활성), AC-39d(슬롯 출처), AC-37a(check_place 주입).
## 테스트는 sim 을 직접 읽는다(대조 기준). 진행은 session.advance(헤드리스 구동기) — SimDriver 의 실시간 _process 는 끈다.

const MAIN_SCENE: String = "res://view/scenes/main.tscn"
const SAVES: String = "user://test_se040_main"
const SEED: int = 0
const SLOT: String = "1"
const CAP_WARNING: String = "max_agents"

var _cfg: SimConfig


func before_all() -> void:
	_cfg = SimConfig.load()


func after_each() -> void:
	_rm_dir(SAVES)


# --- 도우미 ----------------------------------------------------------------------

func _main(args: Array = ["--se-seed=%d" % SEED]) -> MainScene:
	var m: MainScene = (load(MAIN_SCENE) as PackedScene).instantiate() as MainScene
	m.use_cmdline_args = false
	m.boot_args = PackedStringArray(args)
	m.drive_realtime = false
	m.saves_dir = SAVES
	add_child_autofree(m)
	return m


## 시작 메뉴의 "새 게임"(AC4 조작 1) → 경계 처리.
func _menu_new_game(m: MainScene) -> void:
	m.get_ui_root().menu.get_new_game_button().pressed.emit()
	m.session.advance(0)


func _phase(m: MainScene) -> String:
	return str(m.session.hud_state()["phase"])


## 구간 phase 진입 뒤 offset 틱까지 advance(1) 로 진행.
func _advance_into(m: MainScene, phase: String, offset: int) -> void:
	var guard: int = _cfg.day_ticks + 1
	while _phase(m) != phase and guard > 0:
		m.session.advance(1)
		guard -= 1
	m.session.advance(offset)


func _active_agents(m: MainScene) -> int:
	var n: int = 0
	for a: Dictionary in m.session.audience.agents():
		if str(a["state"]) != "gone":
			n += 1
	return n


func _place_via_ghost(m: MainScene, furniture_id: String, cell: Vector2i, rotation: int = 0) -> bool:
	var g: PlacementGhost = m.get_placement_ghost()
	g.select(furniture_id)
	while g.get_rotation_deg() != rotation:
		g.rotate_selection()
	g.hover(cell)
	var ok: bool = g.click()
	g.cancel()
	return ok


func _baseline() -> Array:
	return (BuildCatalog.load_default().reference_layout(MainScene.AUTOPLAY_LAYOUT_ID)["placements"] as Array)


func _warnings_containing(text: String) -> int:
	var n: int = 0
	for e: Variant in get_errors():
		if e.is_push_warning() and e.contains_text(text):
			n += 1
	return n


func _push_error_count() -> int:
	var n: int = 0
	for e: Variant in get_errors():
		if e.is_push_error():
			n += 1
	return n


func _esc_key() -> InputEventKey:
	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	return ev


func _rm_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


# --- 조립·경계 ----------------------------------------------------------------------

func test_boot_wires_views_to_session_bus() -> void:
	var m: MainScene = _main()
	assert_not_null(m.session, "GameSession 생성")
	assert_eq(m.seed_value, SEED, "--se-seed")
	assert_true(m.is_start_menu_open(), "인자(로드·캡처·자동 플레이) 없으면 시작 메뉴")
	assert_true(m.get_ui_root().menu.visible, "메뉴 보임")
	assert_true(m.driver.hold, "시작 메뉴 동안 시간 정지(hold)")
	assert_true(m.get_placement_ghost().has_validator(), "AC-37a: 고스트 validator 주입")
	assert_lt(m.driver.process_priority, m.get_crowd_view().process_priority, "SimDriver 가 표시 보간보다 먼저 돈다")
	assert_false(m.driver.is_processing(), "테스트는 실시간 구동 끔")
	assert_eq(m.get_ui_root().menu.get_new_game_button() != null, true)
	assert_eq(_push_error_count(), 0, "부팅 push_error 0")


func test_seed_resolution_ac39c() -> void:
	assert_eq(MainScene.resolve_seed(PackedStringArray(["--se-seed=42"])), 42)
	assert_eq(MainScene.resolve_seed(PackedStringArray(["--se-seed=-7"])), -7, "명시 시드는 int 그대로(SN: 음수 허용)")
	var t: int = MainScene.resolve_seed(PackedStringArray())
	assert_gte(t, 0, "시작 시각 시드는 0 이상")
	assert_lte(t, MainScene.SEED_MASK)


func test_ghost_validator_is_session_check_place_ac37a() -> void:
	var m: MainScene = _main()
	var g: PlacementGhost = m.get_placement_ghost()
	var p0: Dictionary = _baseline()[0]
	var cell: Vector2i = BuildCatalog.to_cell(p0["cell"])
	g.select(str(p0["furniture_id"]))
	g.hover(cell)
	assert_eq(g.get_reason(), m.session.check_place(str(p0["furniture_id"]), cell, 0), "고스트 사유 = check_place")
	g.hover(Vector2i(-5, -5))
	assert_eq(g.get_reason(), m.session.check_place(str(p0["furniture_id"]), Vector2i(-5, -5), 0))
	assert_ne(g.get_reason(), "", "맵 밖은 무효")


# --- AC2 · AC4 · AC-38c · AC-38f --------------------------------------------------------

func test_one_day_six_operations_matches_sim_ac2_ac4() -> void:
	var m: MainScene = _main()
	var ui: UiRoot = m.get_ui_root()
	var bus: EventBus = m.session.bus
	var ended: Array = []
	bus.subscribe("show.ended", func(p: Dictionary) -> void: ended.append(p))
	# 조작 1: 새 게임(메뉴). SN5 — 뷰 노드는 그대로(다시 bind 하지 않는다).
	var fv_before: FurnitureView = m.get_furniture_view()
	_menu_new_game(m)
	assert_false(ui.menu.visible, "새 게임 → 메뉴 닫힘")
	assert_false(m.driver.hold, "메뉴가 닫히면 시간이 흐른다")
	assert_eq(m.get_furniture_view(), fv_before, "SN5: 같은 뷰")
	# 조작 2·3: 무대·스피커(고스트 클릭 = build.place_requested).
	var stage: Dictionary = _baseline()[0]
	var speaker: Dictionary = _baseline()[1]
	assert_true(_place_via_ghost(m, str(stage["furniture_id"]), BuildCatalog.to_cell(stage["cell"]), int(stage["rotation"])), "무대 클릭")
	assert_true(_place_via_ghost(m, str(speaker["furniture_id"]), BuildCatalog.to_cell(speaker["cell"]), int(speaker["rotation"])), "스피커 클릭")
	m.session.advance(0)
	assert_eq(m.get_furniture_view().get_instance_count(), m.session.build.instances.size(), "가구 노드 수 = build 인스턴스")
	assert_eq(m.session.build.instances.size(), 2)
	# 조작 4: 섭외(패널 버튼).
	var artist_id: String = m.first_bookable_artist()
	assert_ne(artist_id, "", "섭외 가능한 아티스트 있음")
	ui.artist_panel.get_book_button(artist_id).pressed.emit()
	# 조작 5: 배속 3(HUD 버튼).
	ui.hud.get_speed_button(MainScene.AUTOPLAY_SPEED).pressed.emit()
	m.session.advance(0)
	assert_eq(int(m.session.hud_state()["speed"]), MainScene.AUTOPLAY_SPEED, "배속 3 적용")
	assert_eq(ui.hud.get_speed(), MainScene.AUTOPLAY_SPEED, "HUD 배속 = sim")
	assert_eq(m.get_crowd_view().get_speed(), MainScene.AUTOPLAY_SPEED, "CrowdView 보간 배속 = time.speed_changed")
	# 공연 중 틱: 군중 = 활성 에이전트.
	_advance_into(m, "show", _cfg.phase_ticks("show") / 2)
	assert_eq(_phase(m), "show")
	assert_gt(_active_agents(m), 0, "공연 중 관객 있음")
	assert_eq(m.get_crowd_view().get_visible_instance_count(), _active_agents(m), "군중 visible_instance_count = 활성 에이전트")
	assert_eq(m.get_crowd_view().get_last_tick(), m.session.loop.tick, "마지막 agent_moved 틱 = 현재 틱")
	assert_eq(m.get_crowd_view().get_speed(), 1, "공연 구간 배속 1(time.speed_changed)")
	# 마감까지.
	m.session.advance(_cfg.day_ticks)
	assert_eq(_phase(m), "close", "1일 = 마감")
	assert_eq(ui.hud.get_cash(), m.session.economy.cash, "HUD 현금 = economy.cash")
	assert_eq(m.get_furniture_view().get_instance_count(), m.session.build.instances.size())
	assert_true(ui.day_report.visible, "마감 리포트 표시")
	assert_true(ui.day_report.get_row_text("R8").contains(str(m.session.economy.cash)), "R8 현금 = sim")
	assert_eq(ended.size(), 1, "show.ended 1회")
	if ended.size() == 1:
		var grade: String = str(ended[0]["grade"])
		var sl: StageLights = m.get_stage_lights()
		assert_eq(sl.get_finale_color(), sl.params.grade_colors.get(grade, sl.params.grade_fallback_color),
			"AC-38c: 끝 색 = grade_colors[payload.grade] (%s)" % grade)
		assert_true(sl.params.grade_colors.has(grade), "실제 grade 키가 params 에 있다(%s)" % grade)
	# 조작 6: 마감 "다음 날".
	assert_false(ui.day_report.get_next_button().disabled, "다음 날 활성")
	ui.day_report.get_next_button().pressed.emit()
	m.session.advance(0)
	assert_eq(int(m.session.hud_state()["day"]), 2, "2일차")
	assert_eq(_phase(m), "day")
	assert_eq(_warnings_containing(CAP_WARNING), 0, "AC-38f: 상한 경고 0")
	assert_eq(_push_error_count(), 0, "push_error 0")


# --- AC3 · AC-38b · AC-39a ----------------------------------------------------------------

func test_save_in_show_then_load_in_new_instance_ac3_ac38b() -> void:
	var a: MainScene = _main()
	_menu_new_game(a)
	assert_gt(a.publish_autoplay_setup(true), 0)
	a.session.advance(0)
	_advance_into(a, "show", _cfg.phase_ticks("show") / 2)
	var spots: int = a.get_stage_lights().get_active_spot_count()
	assert_gt(spots, 0, "공연 중 스포트 켜짐(조명 가구)")
	a.session.bus.publish("session.save_requested", {"slot": SLOT})
	a.session.advance(0)
	assert_true(FileAccess.file_exists(a.session.slot_path(SLOT)), "슬롯 파일")
	var want: Dictionary = {
		"furniture": a.get_furniture_view().get_instance_count(), "cash_text": a.get_ui_root().hud.get_cash_text(),
		"cash": a.session.economy.cash, "day": a.get_ui_root().hud.get_day_text(), "phase": a.get_ui_root().hud.get_phase(),
		"spots": spots, "overlay": a.get_coverage_overlay().has_coverage(),
	}
	a.session.advance(1)
	var crowd_next: int = a.get_crowd_view().get_visible_instance_count()
	a.queue_free()
	await get_tree().process_frame
	# 새 씬 인스턴스: --se-load=1.
	var b: MainScene = _main(["--se-load=%s" % SLOT])
	assert_false(b.is_start_menu_open(), "--se-load 면 시작 메뉴 없음")
	assert_ne(b.get_ui_root().hud.get_cash(), want["cash"], "로드 전에는 새 게임 현금(대조)")
	b.session.advance(0)
	assert_eq(b.get_furniture_view().get_instance_count(), want["furniture"], "가구 노드 수 동일")
	assert_eq(b.get_ui_root().hud.get_cash(), want["cash"], "AC-39a: HUD 현금 = 저장 시점(hud_state)")
	assert_eq(b.get_ui_root().hud.get_cash_text(), want["cash_text"])
	assert_eq(b.get_ui_root().hud.get_day_text(), want["day"])
	assert_eq(b.get_ui_root().hud.get_phase(), want["phase"])
	assert_eq(b.get_stage_lights().get_active_spot_count(), want["spots"], "AC-38b: 로드 직후 스포트 수 = 저장 시점")
	assert_eq(b.get_coverage_overlay().has_coverage(), want["overlay"], "커버리지 재발행(sync)")
	assert_eq(b.get_crowd_view().get_visible_instance_count(), 0, "로드 직후 군중 비움(다음 agent_moved 까지)")
	b.session.advance(1)
	assert_eq(b.get_crowd_view().get_visible_instance_count(), crowd_next, "다음 틱 군중 = 연속 진행과 같다")
	assert_eq(_push_error_count(), 0, "push_error 0")


func test_load_close_autosave_fills_report_cash_ac39a() -> void:
	var a: MainScene = _main()
	_menu_new_game(a)
	a.publish_autoplay_setup(false)
	a.session.advance(0)
	a.session.advance(_cfg.day_ticks)
	assert_eq(_phase(a), "close")
	var cash: int = a.session.economy.cash
	var slot: String = GameSession.autosave_slot(1)
	assert_true(FileAccess.file_exists(a.session.slot_path(slot)), "마감 오토세이브")
	a.queue_free()
	await get_tree().process_frame
	var b: MainScene = _main(["--se-load=%s" % slot])
	b.session.advance(0)
	var ui: UiRoot = b.get_ui_root()
	assert_eq(_phase(b), "close")
	assert_ne(cash, 0)
	assert_eq(ui.hud.get_cash(), cash, "HUD 현금 = sim(0 아님)")
	assert_true(ui.day_report.visible, "close 로드 → 리포트")
	assert_true(ui.day_report.get_row_text("R8").contains(str(cash)), "R8 현금 = sim: %s" % ui.day_report.get_row_text("R8"))
	assert_true(ui.day_report.get_row_text("R12").contains(str(cash)), "R12 현금 = sim: %s" % ui.day_report.get_row_text("R12"))


# --- AC-38a ---------------------------------------------------------------------------

## 배속 3, 60fps: 틱이 2프레임마다 오고(SimDriver 가 먼저), 표시 위치가 프레임마다 같은 거리만큼 움직인다.
func test_speed3_interpolation_uniform_per_frame_ac38a() -> void:
	var bus: EventBus = EventBus.new()
	var cv: CrowdView = CrowdView.new()
	add_child_autofree(cv)
	var data: CrowdData = CrowdData.load_default()
	assert_true(cv.bind(bus, null, data))
	assert_eq(cv.get_speed(), data.default_speed, "초기 배속 = sim.json phases[0].default_speed")
	bus.publish("time.speed_changed", {"speed": 3, "from": 1, "cause": "request"})
	assert_eq(cv.get_speed(), 3)
	var frame: float = 1.0 / 60.0
	var tick_s: float = data.tick_len_sec
	var ticks_per_frame: float = frame * 3.0 / tick_s        # 0.5
	var acc: float = 0.0
	var tick: int = 0
	var xs: Array[float] = []
	bus.publish("audience.agent_moved", {"tick": 0, "agents": [[1, 0, 0, "moving", data.type_ids[0]]]})   # 첫 틱(스냅)
	for f: int in range(12):
		acc += ticks_per_frame
		while acc >= 1.0 - 1e-6:                             # SimDriver(먼저): 이번 프레임에 처리된 틱
			acc -= 1.0
			tick += 1
			bus.publish("audience.agent_moved", {"tick": tick, "agents": [[1, tick * data.pos_scale, 0, "moving", data.type_ids[0]]]})
		cv.advance_display(frame)                            # CrowdView(뒤)
		xs.append(cv.get_slot_transform(0).origin.x)
	var step: float = data.tile_m * ticks_per_frame
	for i: int in range(1, xs.size()):
		assert_almost_eq(xs[i] - xs[i - 1], step, 1e-4, "프레임 %d 이동량 균일" % i)
	# speed 0: 진행 정지.
	bus.publish("audience.agent_moved", {"tick": tick + 1, "agents": [[1, (tick + 1) * data.pos_scale, 0, "moving", data.type_ids[0]]]})
	bus.publish("time.speed_changed", {"speed": 0, "from": 3, "cause": "request"})
	var x0: float = cv.get_slot_transform(0).origin.x
	cv.advance_display(frame)
	assert_eq(cv.get_slot_transform(0).origin.x, x0, "speed 0 이면 보간 정지")
	# session.loaded.speed 가 초기값.
	bus.publish("session.loaded", {"day": 1, "phase": "evening", "speed": 1, "show_active": false})
	assert_eq(cv.get_speed(), 1, "로드 = session.loaded.speed")


# --- AC-39b ---------------------------------------------------------------------------

func test_esc_cancels_ghost_before_menu_ac39b() -> void:
	var m: MainScene = _main()
	_menu_new_game(m)
	var ui: UiRoot = m.get_ui_root()
	var g: PlacementGhost = m.get_placement_ghost()
	assert_false(ui.menu.visible)
	g.select(str(_baseline()[0]["furniture_id"]))
	assert_true(m.is_ghost_active())
	get_viewport().push_input(_esc_key())
	assert_eq(g.get_mode(), PlacementGhost.Mode.NONE, "Esc 1: 고스트 취소")
	assert_false(ui.menu.visible, "Esc 1: 메뉴는 열리지 않는다")
	get_viewport().push_input(_esc_key())
	assert_true(ui.menu.visible, "Esc 2: 고스트가 없으면 메뉴")


# --- AC-39c ---------------------------------------------------------------------------

## 파산 → 파산 화면 "새 게임"(seed = 실행 시드) → 첫 마감 "다음 날" 활성.
func test_bankrupt_then_new_game_next_day_enabled_ac39c() -> void:
	var m: MainScene = _main()
	_menu_new_game(m)
	var ui: UiRoot = m.get_ui_root()
	var new_games: Array = []
	m.session.bus.subscribe("session.loaded", func(p: Dictionary) -> void: new_games.append(p))
	# 무대 없이 매일 현금을 가구로 써서 정산 적자 → 구제 → … → 파산.
	var catalog: BuildCatalog = BuildCatalog.load_default()
	var days: int = 0
	while not bool(m.session.hud_state()["bankrupt"]) and days < 30:
		_spend_cash(m, catalog)
		m.session.advance(_cfg.day_ticks)
		if not bool(m.session.hud_state()["bankrupt"]):
			m.session.bus.publish("time.next_day_requested", {})
			m.session.advance(0)
		days += 1
	assert_true(bool(m.session.hud_state()["bankrupt"]), "파산 도달(%d일)" % days)
	assert_true(ui.game_over.is_blocking(), "파산 화면")
	assert_true(ui.day_report.get_next_button().disabled, "파산 뒤 다음 날 비활성(대조)")
	ui.game_over.get_new_game_button().pressed.emit()
	assert_eq(UiTestUtil.commands(m.session.bus, "session.new_game_requested"), [{"seed": m.seed_value}], "seed = 실행 시드")
	m.session.advance(0)
	assert_eq(new_games.size(), 1, "session.loaded 1회")
	assert_false(ui.game_over.is_blocking(), "파산 화면 닫힘")
	assert_eq(ui.hud.get_cash(), m.session.economy.cash, "새 게임 현금 = sim")
	assert_eq(m.get_furniture_view().get_instance_count(), 0, "가구 비움")
	m.session.advance(_cfg.day_ticks)
	assert_eq(_phase(m), "close")
	assert_false(ui.day_report.get_next_button().disabled, "첫 마감 다음 날 활성")


## 낮 구간에서 살 수 있는 가장 비싼 가구를 빈 칸에 계속 놓는다(check_place 통과 칸만).
func _spend_cash(m: MainScene, catalog: BuildCatalog) -> void:
	var ids: Array = []
	for c: String in catalog.categories():
		for r: Dictionary in catalog.rows_in_category(c):
			if str(r["category"]) != "stage":
				ids.append([int(r["build_cost"]), str(r["id"])])
	ids.sort()
	ids.reverse()
	var size: Vector2i = catalog.get_map_size()
	for e: Array in ids:
		for z: int in range(size.y):
			for x: int in range(size.x):
				if m.session.economy.cash < int(e[0]):
					break
				if m.session.check_place(str(e[1]), Vector2i(x, z), 0) == "":
					m.session.bus.publish("build.place_requested", {"furniture_id": e[1], "cell": [x, z], "rotation": 0})
					m.session.advance(0)


# --- AC-39d ---------------------------------------------------------------------------

func test_save_slots_source_ac39d() -> void:
	var dir: String = SAVES
	DirAccess.make_dir_recursive_absolute(dir)
	var p_int: String = dir.path_join("save_int.json")
	var p_arr: String = dir.path_join("save_arr.json")
	var f: FileAccess = FileAccess.open(p_int, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "manual_slots": 2, "autosave_keep": 3}))
	f.close()
	f = FileAccess.open(p_arr, FileAccess.WRITE)
	f.store_string(JSON.stringify({"manual_slots": ["a", "b", "c", "d"]}))
	f.close()
	assert_eq(UiParams.read_manual_slots(p_int), PackedStringArray(["1", "2"]), "정수 n → 1..n")
	assert_eq(UiParams.read_manual_slots(p_arr), PackedStringArray(["a", "b", "c", "d"]), "배열 그대로")
	assert_eq(UiParams.read_manual_slots(dir.path_join("none.json")).size(), 0, "없으면 빈 배열")
	var base: UiParams = UiParams.load_default()
	var p: UiParams = base.for_session(77, p_int)
	assert_eq(p.save_slots, PackedStringArray(["1", "2"]))
	assert_eq(p.new_game_seed, 77)
	assert_ne(base.new_game_seed, 77, "원본 .tres 불변")
	# 메인 씬: save.json 이 없으면 ui_params.tres 기본.
	var m: MainScene = _main()
	var want: PackedStringArray = UiParams.read_manual_slots()
	if want.is_empty():
		want = base.save_slots
	for s: String in want:
		assert_not_null(m.get_ui_root().menu.get_save_button(s), "메뉴 슬롯 %s" % s)
	DirAccess.remove_absolute(p_int)
	DirAccess.remove_absolute(p_arr)


# --- AC-38e ---------------------------------------------------------------------------

func test_stage_lights_empty_show_colors_fallback_ac38e() -> void:
	var sl: StageLights = StageLights.new()
	sl.params = (load(StageLights.DEFAULT_PARAMS_PATH) as StageLightParams).duplicate() as StageLightParams
	sl.params.show_colors = PackedColorArray()
	add_child_autofree(sl)
	assert_false(sl.bind(null, BuildCatalog.load_default(), 1.0), "설정 오류 → false")
	assert_push_error("show_colors", "설정 오류 push_error")
	assert_eq(sl.show_color(3), sl.params.grade_fallback_color, "show_colors 비면 폴백 색(0 나눗셈 없음)")
	var ok: StageLights = StageLights.new()
	add_child_autofree(ok)
	assert_true(ok.bind(null, BuildCatalog.load_default(), 1.0), "기본 .tres 는 true")
