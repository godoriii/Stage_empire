class_name MainMenu
extends UiPanel
## SE-039 AC6: 메뉴(Esc — UiRoot 가 ui_cancel 액션으로 연다). 저장/불러오기 슬롯(UiParams.save_slots) + 새 게임 + 계속.
## 발행: session.save_requested {slot: String}, session.load_requested {slot: String},
##   session.new_game_requested {seed: int}(SE-036 결과 절 이름 그대로, events.md 등록은 SE-039 2차).
## 구독: session.loaded → 닫힘. session.saved·session.load_failed 의 알림은 Notifications 몫.

signal resume_requested

const TITLE_PATH: NodePath = ^"Center/Panel/VBox/Title"
const SLOTS_PATH: NodePath = ^"Center/Panel/VBox/Slots"
const NEW_GAME_PATH: NodePath = ^"Center/Panel/VBox/NewGame"
const RESUME_PATH: NodePath = ^"Center/Panel/VBox/Resume"
const SAVE_NAME_PATTERN: String = "Save_%s"
const LOAD_NAME_PATTERN: String = "Load_%s"


func _event_handlers() -> Dictionary:
	return {
		"session.loaded": func(_p: Dictionary) -> void: close(),
	}


func _on_setup() -> void:
	visible = false
	(get_node(TITLE_PATH) as Label).text = t("ui.menu.title")
	var grid: GridContainer = get_node(SLOTS_PATH) as GridContainer
	for c: Node in grid.get_children():
		grid.remove_child(c)
		c.free()
	for slot: String in _params.save_slots:
		var s: Button = Button.new()
		s.name = SAVE_NAME_PATTERN % slot
		s.text = t("ui.menu.save_slot", {"slot": slot})
		s.pressed.connect(request_save.bind(slot))
		grid.add_child(s)
		var l: Button = Button.new()
		l.name = LOAD_NAME_PATTERN % slot
		l.text = t("ui.menu.load_slot", {"slot": slot})
		l.pressed.connect(request_load.bind(slot))
		grid.add_child(l)
	var ng: Button = get_node(NEW_GAME_PATH) as Button
	ng.text = t("ui.menu.new_game")
	if not ng.pressed.is_connected(request_new_game):
		ng.pressed.connect(request_new_game)
	var r: Button = get_node(RESUME_PATH) as Button
	r.text = t("ui.menu.resume")
	if not r.pressed.is_connected(_on_resume):
		r.pressed.connect(_on_resume)


func get_save_button(slot: String) -> Button:
	return get_node(SLOTS_PATH).get_node_or_null(SAVE_NAME_PATTERN % slot) as Button


func get_load_button(slot: String) -> Button:
	return get_node(SLOTS_PATH).get_node_or_null(LOAD_NAME_PATTERN % slot) as Button


func get_new_game_button() -> Button:
	return get_node(NEW_GAME_PATH) as Button


func open() -> void:
	visible = true


func close() -> void:
	visible = false


func toggle() -> void:
	visible = not visible


func request_save(slot: String) -> void:
	if _bus != null:
		_bus.publish("session.save_requested", {"slot": slot})


func request_load(slot: String) -> void:
	if _bus != null:
		_bus.publish("session.load_requested", {"slot": slot})


func request_new_game() -> void:
	if _bus != null:
		_bus.publish("session.new_game_requested", {"seed": _params.new_game_seed})


func _on_resume() -> void:
	close()
	resume_requested.emit()
