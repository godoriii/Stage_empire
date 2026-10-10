class_name Notifications
extends UiPanel
## SE-039: 우측 알림 피드(PRD "UI 구성" 우측) + 티어 해금 토스트(R12, "계속 플레이").
## 구독(거절·실패 → 피드 1줄, 문구 = ui.notify.<출처> + ui.reason.<출처>.<reason>):
##   build.rejected, artist.booking_rejected, economy.ticket_price_rejected, time.speed_rejected, session.load_failed,
##   session.saved(확인 1줄), reputation.tier_unlocked(토스트 1건), session.loaded(토스트 닫힘 — 다른 세계).
## 최대 줄 수·표시 시간은 UiParams. 발행 없음.

const FEED_PATH: NodePath = ^"Feed"
const TOAST_PATH: NodePath = ^"Toast"
const TOAST_LABEL_PATH: NodePath = ^"Toast/VBox/Label"
const TOAST_CONTINUE_PATH: NodePath = ^"Toast/VBox/Continue"
const ENTRY_NAME_PATTERN: String = "Entry_%d"
## 이벤트 → 알림 출처 id(ui.notify.<id>, ui.reason.<id>.<reason>).
const SOURCES: Dictionary = {
	"build.rejected": "build",
	"artist.booking_rejected": "artist",
	"economy.ticket_price_rejected": "ticket_price",
	"time.speed_rejected": "speed",
	"session.load_failed": "load",
}

var _seq: int = 0


func _event_handlers() -> Dictionary:
	var h: Dictionary = {}
	for ev: String in SOURCES:
		h[ev] = _on_rejected.bind(str(SOURCES[ev]))
	h["session.saved"] = on_saved
	h["reputation.tier_unlocked"] = on_tier_unlocked
	h["session.loaded"] = func(_p: Dictionary) -> void: hide_toast()
	return h


func _on_setup() -> void:
	(get_node(TOAST_PATH) as Control).visible = false
	var c: Button = get_node(TOAST_CONTINUE_PATH) as Button
	c.text = t("ui.unlock.continue")
	if not c.pressed.is_connected(hide_toast):
		c.pressed.connect(hide_toast)
	clear()


func get_entries() -> Array[Label]:
	var out: Array[Label] = []
	for c: Node in get_node(FEED_PATH).get_children():
		if c is Label and not c.is_queued_for_deletion():
			out.append(c as Label)
	return out


func get_entry_texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for l: Label in get_entries():
		out.append(l.text)
	return out


func is_toast_visible() -> bool:
	return (get_node(TOAST_PATH) as Control).visible


func get_toast_text() -> String:
	return (get_node(TOAST_LABEL_PATH) as Label).text


func get_continue_button() -> Button:
	return get_node(TOAST_CONTINUE_PATH) as Button


## 피드에 한 줄. 최대 줄 수를 넘으면 가장 오래된 줄부터 지운다.
func push(text: String) -> void:
	var feed: Node = get_node(FEED_PATH)
	var l: Label = Label.new()
	_seq += 1
	l.name = ENTRY_NAME_PATTERN % _seq
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	feed.add_child(l)
	var entries: Array[Label] = get_entries()
	var over: int = entries.size() - maxi(_params.notification_max, 1)
	for i: int in range(over):
		feed.remove_child(entries[i])
		entries[i].free()
	if _params.notification_seconds > 0.0 and is_inside_tree():
		get_tree().create_timer(_params.notification_seconds).timeout.connect(_expire.bind(l))


func clear() -> void:
	var feed: Node = get_node(FEED_PATH)
	for c: Node in feed.get_children():
		feed.remove_child(c)
		c.free()


func hide_toast() -> void:
	(get_node(TOAST_PATH) as Control).visible = false


func on_saved(p: Dictionary) -> void:
	push(t("ui.notify.saved", {"slot": str(p.get("slot", "")), "day": int(p.get("day", 0))}))


func on_tier_unlocked(p: Dictionary) -> void:
	(get_node(TOAST_LABEL_PATH) as Label).text = t("ui.unlock.toast", {"tier": int(p.get("tier", 0))})
	(get_node(TOAST_PATH) as Control).visible = true


func _on_rejected(p: Dictionary, source: String) -> void:
	var reason: String = str(p.get("reason", ""))
	push(t("ui.notify.%s" % source, {"reason": t("ui.reason.%s.%s" % [source, reason])}))


func _expire(l: Label) -> void:
	if is_instance_valid(l) and l.get_parent() != null:
		l.get_parent().remove_child(l)
		l.free()
