extends GutTest
## SE-039 AC6: Esc → 메뉴, 저장/불러오기 슬롯 → session.* 명령, load_failed → 알림.

var bus: EventBus
var root: UiRoot


func before_each() -> void:
	bus = EventBus.new()
	root = UiTestUtil.make_root(self, bus)


func _esc() -> void:
	var ev: InputEventAction = InputEventAction.new()
	ev.action = UiRoot.MENU_ACTION
	ev.pressed = true
	root._unhandled_input(ev)


func test_esc_toggles_menu() -> void:
	assert_false(root.menu.visible)
	_esc()
	assert_true(root.menu.visible, "Esc → 메뉴")
	_esc()
	assert_false(root.menu.visible, "Esc 다시 → 닫힘")


func test_esc_closes_artist_panel_first() -> void:
	root.toggle_artist_panel()
	assert_true(root.artist_panel.visible)
	_esc()
	assert_false(root.artist_panel.visible, "섭외 패널 먼저 닫힘")
	assert_false(root.menu.visible)


func test_slots_from_params() -> void:
	var slots: PackedStringArray = UiParams.load_default().save_slots
	assert_gt(slots.size(), 0)
	for s: String in slots:
		assert_not_null(root.menu.get_save_button(s), "저장 %s" % s)
		assert_not_null(root.menu.get_load_button(s), "불러오기 %s" % s)


func test_save_and_load_publish_slot() -> void:
	var slots: PackedStringArray = UiParams.load_default().save_slots
	var s: String = slots[slots.size() - 1]
	root.menu.get_save_button(s).pressed.emit()
	root.menu.get_load_button(s).pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "session.save_requested"), [{"slot": s}])
	assert_eq(UiTestUtil.commands(bus, "session.load_requested"), [{"slot": s}])
	assert_eq(typeof(UiTestUtil.commands(bus, "session.save_requested")[0]["slot"]), TYPE_STRING, "slot 은 String(SE-036)")


func test_new_game_publishes_seed() -> void:
	root.menu.get_new_game_button().pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "session.new_game_requested"), [{"seed": UiParams.load_default().new_game_seed}])


func test_load_failed_notifies_and_loaded_closes_menu() -> void:
	_esc()
	bus.publish("session.load_failed", {"slot": "1", "reason": "missing"})
	assert_eq(root.notifications.get_entries().size(), 1, "load_failed → 알림 1건")
	assert_true(root.menu.visible, "실패면 메뉴 유지")
	bus.publish("session.loaded", {"day": 15, "phase": UiTestUtil.phase_ids()[0], "speed": 1, "show_active": false})
	assert_false(root.menu.visible, "loaded → 닫힘")
	assert_true(root.hud.get_day_text().contains("15"), "HUD 복구")


func test_hud_buttons_open_panels() -> void:
	root.hud.artist_panel_requested.emit()
	assert_true(root.artist_panel.visible)
	UiTestUtil.enter_phase(bus, UiTestUtil.close_phase())
	assert_false(root.artist_panel.visible, "마감 진입 → 섭외 패널 닫힘(리포트 우선)")
	root.hud.menu_requested.emit()
	assert_true(root.menu.visible)
