class_name GameOver
extends UiPanel
## SE-039 AC5: 파산 화면(economy.bankrupt — economy.md "게임 오버"). 전체 화면을 덮어 입력을 막는다
## (Block 이 마우스를 멈추고, 보이는 동안 _unhandled_input 을 소비). "새 게임" → session.new_game_requested {seed}
## (seed = UiParams.new_game_seed, SE-039 2차가 events.md 에 등록). session.loaded 면 닫힌다(새 게임·불러오기 성공).

const TITLE_PATH: NodePath = ^"Block/Center/Panel/VBox/Title"
const BODY_PATH: NodePath = ^"Block/Center/Panel/VBox/Body"
const NEW_GAME_PATH: NodePath = ^"Block/Center/Panel/VBox/NewGame"


func _event_handlers() -> Dictionary:
	return {
		"economy.bankrupt": on_bankrupt,
		"session.loaded": func(_p: Dictionary) -> void: visible = false,
	}


func _on_setup() -> void:
	visible = false
	(get_node(TITLE_PATH) as Label).text = t("ui.game_over.title")
	var b: Button = get_new_game_button()
	b.text = t("ui.game_over.new_game")
	if not b.pressed.is_connected(_on_new_game):
		b.pressed.connect(_on_new_game)


func get_new_game_button() -> Button:
	return get_node(NEW_GAME_PATH) as Button


func get_body_text() -> String:
	return (get_node(BODY_PATH) as Label).text


func get_block() -> Control:
	return get_node(^"Block") as Control


func is_blocking() -> bool:
	return visible


func on_bankrupt(p: Dictionary) -> void:
	(get_node(BODY_PATH) as Label).text = t("ui.game_over.body", {
		"day": int(p.get("day", 0)), "cash": int(p.get("cash", 0)), "bailouts_used": int(p.get("bailouts_used", 0)),
	})
	visible = true


## 보이는 동안 남은 입력(카메라·건설 단축키)을 소비한다. 버튼 클릭은 GUI 단계에서 먼저 처리된다.
func _unhandled_input(_event: InputEvent) -> void:
	if visible:
		get_viewport().set_input_as_handled()


func _on_new_game() -> void:
	if _bus != null:
		_bus.publish("session.new_game_requested", {"seed": _params.new_game_seed})
