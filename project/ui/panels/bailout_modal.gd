class_name BailoutModal
extends UiPanel
## SE-039 AC5: 구제 제안 모달(economy.md #파산과-구제). economy.bailout_offered → 보임(금액·이자·상환일 표시).
## "수락" → economy.bailout_accept_requested {} 1건 후 닫힘. "닫기" → 닫힘(수락 없이 다음 날로 가면 sim 이 자동 수락).
## economy.bailout_taken·time.day_started·session.loaded → 닫힘.

const BODY_PATH: NodePath = ^"Center/Panel/VBox/Body"
const TITLE_PATH: NodePath = ^"Center/Panel/VBox/Title"
const ACCEPT_PATH: NodePath = ^"Center/Panel/VBox/Buttons/Accept"
const CLOSE_PATH: NodePath = ^"Center/Panel/VBox/Buttons/Close"

var _offer: Dictionary = {}


func _event_handlers() -> Dictionary:
	return {
		"economy.bailout_offered": on_offered,
		"economy.bailout_taken": func(_p: Dictionary) -> void: close(),
		"time.day_started": func(_p: Dictionary) -> void: close(),
		"session.loaded": func(_p: Dictionary) -> void: close(),
	}


func _on_setup() -> void:
	visible = false
	(get_node(TITLE_PATH) as Label).text = t("ui.bailout.title")
	var accept: Button = get_accept_button()
	accept.text = t("ui.bailout.accept")
	if not accept.pressed.is_connected(_on_accept):
		accept.pressed.connect(_on_accept)
	var c: Button = get_node(CLOSE_PATH) as Button
	c.text = t("ui.common.close")
	if not c.pressed.is_connected(close):
		c.pressed.connect(close)


func get_accept_button() -> Button:
	return get_node(ACCEPT_PATH) as Button


func get_body_text() -> String:
	return (get_node(BODY_PATH) as Label).text


func on_offered(p: Dictionary) -> void:
	_offer = p.duplicate(true)
	(get_node(BODY_PATH) as Label).text = t("ui.bailout.body", {
		"deficit": int(p.get("deficit", 0)), "amount": int(p.get("amount", 0)), "interest": int(p.get("interest", 0)),
		"total_due": int(p.get("total_due", 0)), "repay_days": int(p.get("repay_days", 0)),
		"first_installment": int(p.get("first_installment", 0)), "bailouts_left_after": int(p.get("bailouts_left_after", 0)),
	})
	visible = true


func close() -> void:
	_offer.clear()
	visible = false


func _on_accept() -> void:
	if _offer.is_empty():
		return
	if _bus != null:
		_bus.publish("economy.bailout_accept_requested", {})
	close()
