extends GutTest
## SE-039 AC5: 구제 모달·파산 화면·티어 해금 토스트.

var bus: EventBus
var root: UiRoot


func before_each() -> void:
	bus = EventBus.new()
	root = UiTestUtil.make_root(self, bus)


func _offer() -> Dictionary:
	return {"day": 8, "kind": "loan", "deficit": 742, "amount": 3742, "interest": 374, "total_due": 4116, "repay_days": 10,
		"first_installment": 411, "bailouts_left_after": 1}


func test_bailout_offer_shows_modal_and_accept_publishes() -> void:
	assert_false(root.bailout.visible)
	bus.publish("economy.bailout_offered", _offer())
	assert_true(root.bailout.visible, "제안 → 모달")
	assert_true(root.bailout.get_body_text().contains("3742"), "금액 표시")
	root.bailout.get_accept_button().pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "economy.bailout_accept_requested"), [{}], "수락 1건")
	assert_false(root.bailout.visible, "수락 뒤 닫힘")
	root.bailout.get_accept_button().pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "economy.bailout_accept_requested").size(), 1, "닫힌 뒤 재발행 없음")


func test_bailout_taken_or_new_day_closes_modal() -> void:
	bus.publish("economy.bailout_offered", _offer())
	bus.publish("economy.bailout_taken", {"day": 8, "kind": "loan", "amount": 3742, "total_due": 4116, "repay_days": 10,
		"bailouts_left": 1, "cash": 3000, "auto": true})
	assert_false(root.bailout.visible, "taken → 닫힘")
	bus.publish("economy.bailout_offered", _offer())
	bus.publish("time.day_started", {"day": 9})
	assert_false(root.bailout.visible, "day_started → 닫힘")


func test_bankrupt_shows_blocking_game_over() -> void:
	bus.publish("economy.bankrupt", {"day": 14, "cash": -1555, "bailouts_used": 2})
	assert_true(root.game_over.visible, "파산 → 게임 오버")
	assert_true(root.game_over.is_blocking())
	assert_eq(root.game_over.get_block().mouse_filter, Control.MOUSE_FILTER_STOP, "전체 화면이 마우스를 막는다")
	assert_true(root.game_over.get_body_text().contains("14"))
	root.game_over.get_new_game_button().pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "session.new_game_requested"), [{"seed": UiParams.load_default().new_game_seed}])


func test_game_over_blocks_menu_and_panels() -> void:
	bus.publish("economy.bankrupt", {"day": 14, "cash": -1555, "bailouts_used": 2})
	var ev: InputEventAction = InputEventAction.new()
	ev.action = UiRoot.MENU_ACTION
	ev.pressed = true
	root._unhandled_input(ev)
	assert_false(root.menu.visible, "파산 중 Esc 무시")
	root.toggle_artist_panel()
	assert_false(root.artist_panel.visible, "파산 중 섭외 패널 열리지 않음")
	bus.publish("session.loaded", {"day": 1, "phase": UiTestUtil.phase_ids()[0], "speed": 1, "show_active": false})
	assert_false(root.game_over.visible, "새 게임·불러오기 → 닫힘")


func test_tier_unlocked_shows_one_toast_with_continue() -> void:
	bus.publish("reputation.tier_unlocked", {"tier": 2, "day": 25})
	assert_true(root.notifications.is_toast_visible(), "토스트 1건")
	assert_true(root.notifications.get_toast_text().contains("2"))
	assert_eq(root.notifications.get_entries().size(), 0, "피드에는 넣지 않는다(토스트 1건만)")
	root.notifications.get_continue_button().pressed.emit()
	assert_false(root.notifications.is_toast_visible(), "계속 플레이 → 닫힘")


## SE-053 AC4: 파산 → 새 게임(session.loaded) 뒤 리포트에 파산 기록 0, 첫 마감 "다음 날" 활성. 해금 토스트도 닫힘.
func test_se053_ac4_new_game_clears_bankrupt_in_report() -> void:
	bus.publish("reputation.tier_unlocked", {"tier": 2, "day": 13})
	bus.publish("economy.bankrupt", {"day": 14, "cash": -1555, "bailouts_used": 2})
	root.game_over.get_new_game_button().pressed.emit()
	bus.publish("session.loaded", {"day": 1, "phase": UiTestUtil.phase_ids()[0], "speed": 1, "show_active": false})
	assert_false(root.notifications.is_toast_visible(), "새 게임 → 해금 토스트 닫힘")
	UiTestUtil.enter_phase(bus, UiTestUtil.close_phase(), 1)
	assert_true(root.day_report.visible)
	assert_false(root.day_report.get_next_button().disabled, "다음 날 활성")
	assert_false(root.day_report.get_row_text("R13").begins_with("ui.report.r13_bankrupt"), "파산 기록 0")
	assert_false(root.game_over.visible)
