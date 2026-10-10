extends GutTest
## SE-039 AC1(HUD 라벨·배속 버튼), AC3(티켓 가격 스피너). 가짜 버스에 상태 이벤트를 넣고 라벨·버튼·명령 큐를 단언.

const SCENE: String = "res://ui/hud/top_hud.tscn"

var bus: EventBus
var hud: TopHud


func before_each() -> void:
	bus = EventBus.new()
	hud = UiTestUtil.make_panel(self, SCENE, bus, UiTestUtil.fixture_text()) as TopHud


func test_labels_follow_events() -> void:
	bus.publish("economy.cash_changed", {"cash": 4321, "delta": -679, "reason": "build"})
	bus.publish("reputation.changed", {"day": 2, "delta": 18, "total": 77, "by_genre": {}})
	UiTestUtil.enter_phase(bus, UiTestUtil.phase_ids()[0], 5)
	assert_eq(hud.get_cash_text(), "C4321")
	assert_eq(hud.get_reputation_text(), "R77")
	assert_eq(hud.get_day_text(), "D5")
	assert_eq(hud.get_phase_text(), "PH_day")
	bus.publish("time.day_started", {"day": 6})
	assert_eq(hud.get_day_text(), "D6")
	UiTestUtil.enter_phase(bus, UiTestUtil.close_phase(), 6)
	assert_eq(hud.get_phase_text(), "PH_close")


func test_initial_cash_is_starting_cash() -> void:
	assert_eq(hud.get_cash_text(), "C%d" % int(UiTestUtil.json(UiTestUtil.ECONOMY_PATH)["starting_cash"]))


func test_speed_buttons_are_union_of_phase_speeds() -> void:
	var union: Dictionary = {}
	for ph: String in UiTestUtil.phase_ids():
		for s: int in UiTestUtil.phase_speeds(ph):
			union[s] = true
	assert_eq(hud.get_speed_buttons().size(), union.size(), "버튼 수 = sim.json speeds 합집합")
	for s: Variant in union:
		assert_not_null(hud.get_speed_button(int(s)), "배속 %d 버튼" % int(s))


func test_speed_buttons_disabled_outside_phase_speeds() -> void:
	for ph: String in UiTestUtil.phase_ids():
		UiTestUtil.enter_phase(bus, ph)
		var allowed: Array[int] = UiTestUtil.phase_speeds(ph)
		for b: Button in hud.get_speed_buttons():
			var s: int = int(b.get_meta(TopHud.META_SPEED))
			assert_eq(b.disabled, not allowed.has(s), "%s 구간 배속 %d 비활성 = %s" % [ph, s, str(not allowed.has(s))])


func test_speed_click_publishes_int_request() -> void:
	var ph: String = UiTestUtil.phase_ids()[0]
	UiTestUtil.enter_phase(bus, ph)
	var allowed: Array[int] = UiTestUtil.phase_speeds(ph)
	var target: int = allowed[allowed.size() - 1]
	hud.get_speed_button(target).pressed.emit()
	var cmds: Array = UiTestUtil.commands(bus, "time.speed_requested")
	assert_eq(cmds.size(), 1, "명령 1건")
	assert_eq(cmds[0], {"speed": target})
	assert_eq(typeof(cmds[0]["speed"]), TYPE_INT, "speed 는 int")
	assert_false(hud.get_speed_button(target).button_pressed, "speed_changed 전에는 눌림 표시 안 바뀜")
	bus.publish("time.speed_changed", {"speed": target, "from": 1, "cause": "requested"})
	assert_true(hud.get_speed_button(target).button_pressed, "speed_changed 뒤 눌림")


func test_disallowed_speed_does_not_publish() -> void:
	var close: String = UiTestUtil.close_phase()
	UiTestUtil.enter_phase(bus, close)
	var allowed: Array[int] = UiTestUtil.phase_speeds(close)
	for b: Button in hud.get_speed_buttons():
		if not allowed.has(int(b.get_meta(TopHud.META_SPEED))):
			b.pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "time.speed_requested").size(), 0, "허용 밖 배속은 발행 안 함")


func test_price_spinner_range_from_economy_row() -> void:
	var row: Dictionary = UiTestUtil.economy_row()
	var spin: SpinBox = hud.get_price_spin()
	assert_eq(int(spin.min_value), int(row["ticket_price_min"]))
	assert_eq(int(spin.max_value), int(row["ticket_price_max"]))
	assert_eq(int(spin.value), int(row["ticket_price_default"]))


func test_price_change_publishes_and_rejected_reverts() -> void:
	var row: Dictionary = UiTestUtil.economy_row()
	UiTestUtil.enter_phase(bus, UiTestUtil.phase_ids()[0])
	var spin: SpinBox = hud.get_price_spin()
	assert_true(spin.editable, "낮 구간 편집 가능")
	var want: int = int(row["ticket_price_default"]) + 1
	spin.value = want
	assert_eq(UiTestUtil.commands(bus, "economy.ticket_price_requested"), [{"price": want}])
	bus.publish("economy.ticket_price_rejected", {"price": want, "reason": "not_allowed", "phase": "day"})
	assert_eq(int(spin.value), int(row["ticket_price_default"]), "거절 → 이전 값")
	bus.publish("economy.ticket_price_changed", {"price": want, "from": int(row["ticket_price_default"])})
	assert_eq(int(spin.value), want, "변경 반영")
	assert_eq(UiTestUtil.commands(bus, "economy.ticket_price_requested").size(), 1, "이벤트 반영은 재발행하지 않는다")


func test_price_spinner_locked_outside_day() -> void:
	UiTestUtil.enter_phase(bus, UiTestUtil.close_phase())
	assert_false(hud.get_price_spin().editable, "낮 외 구간 잠김")
	hud._on_price_spin_changed(hud.get_price_spin().value + 1)
	assert_eq(UiTestUtil.commands(bus, "economy.ticket_price_requested").size(), 0)


func test_session_loaded_reads_reputation_total() -> void:
	var reader: RefCounted = _reader(150)
	hud.set_reputation_reader(reader)
	assert_eq(hud.get_reputation_text(), "R150", "초기값 = ReputationSystem.total")
	reader.set("total", 222)
	bus.publish("session.loaded", {"day": 9, "phase": UiTestUtil.phase_ids()[0], "speed": 1, "show_active": false})
	assert_eq(hud.get_reputation_text(), "R222", "불러오기 뒤 다시 읽기")
	assert_eq(hud.get_day_text(), "D9")
	assert_true(hud.get_speed_button(1).button_pressed)


func test_fallback_text_shows_key_and_values() -> void:
	var t: UiText = UiText.from_strings({})
	assert_eq(t.t("ui.hud.cash", {"cash": 10}), "ui.hud.cash 10")
	assert_eq(t.t("ui.hud.menu"), "ui.hud.menu")
	assert_eq(UiTestUtil.fixture_text().t("ui.hud.cash", {"cash": 10}), "C10")


func _reader(total: int) -> RefCounted:
	var o: RefCounted = load("res://tests/view/fake_reputation.gd").new()
	o.set("total", total)
	return o
