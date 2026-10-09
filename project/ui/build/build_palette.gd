class_name BuildPalette
extends CanvasLayer
## SE-037: 하단 건설 팔레트(PRD "UI 구성": 하단 건설 팔레트) + 상태 문구 + 거절 토스트.
## - 카테고리 탭 = furniture.json 의 카테고리(테이블 순서), 가구 버튼 = 테이블 행 하나당 1개(수는 데이터에서).
##   버튼 글자: 이름, build_cost, upkeep_per_day(테이블 값). 누르면 PlacementGhost.select(id).
## - 철거 버튼 → PlacementGhost.set_demolish_mode(true).
## - 상태 문구(우측 상단): 고스트 모드·선택·회전·추정 사유, 오버레이 HUD 문구(CoverageOverlay.get_hud_text), 조작 키.
## - build.rejected {reason} → 토스트 Label 을 ToastTimer.wait_time(씬, 3초) 동안 표시.
## 이벤트는 build.rejected 구독만 한다. 발행하지 않는다(명령 발행은 PlacementGhost).

const EV_REJECTED: String = "build.rejected"
const TABS_PATH: NodePath = ^"Bottom/VBox/Tabs"
const ITEMS_PATH: NodePath = ^"Bottom/VBox/Row/Items"
const DEMOLISH_PATH: NodePath = ^"Bottom/VBox/Row/Demolish"
const STATUS_PATH: NodePath = ^"Status/Label"
const TOAST_PATH: NodePath = ^"Toast"
const TOAST_TIMER_PATH: NodePath = ^"ToastTimer"
const TAB_NAME_PATTERN: String = "Tab_%s"
const CATEGORY_BOX_PATTERN: String = "Cat_%s"
const ITEM_NAME_PATTERN: String = "Item_%s"
const ITEM_TEXT_PATTERN: String = "%s\n건설 %d · 유지 %d/일"
const META_FURNITURE_ID: StringName = &"furniture_id"
const META_CATEGORY: StringName = &"category"
## 카테고리 탭 표시 이름(build.md "가구 카테고리" 표). 없는 id 는 id 그대로. 로컬라이즈 키 분리는 후속 content 티켓.
const CATEGORY_LABELS: Dictionary = {
	"stage": "무대", "sound": "음향", "light": "조명", "bar": "바",
	"amenity": "편의", "safety": "안전", "decor": "장식",
}
## build.rejected reason 표시 이름(build.md B·D·H 표 15종). 없는 id 는 id 그대로.
const REASON_LABELS: Dictionary = {
	"invalid": "잘못된 요청", "not_allowed": "지금은 건설할 수 없다", "unknown_furniture": "없는 가구",
	"bad_rotation": "회전 불가", "out_of_bounds": "맵 밖", "blocked_tile": "배치 불가 타일", "overlap": "다른 가구와 겹침",
	"wall_required": "벽에 붙여야 함", "limit_reached": "설치 한도", "path_blocked": "통로가 막힘",
	"insufficient_cash": "자금 부족", "bankrupt": "파산", "charge_invalid": "결제 오류",
	"charge_unresolved": "결제 응답 없음", "not_found": "철거할 가구 없음",
}

var _bus: EventBus
var _catalog: BuildCatalog
var _ghost: PlacementGhost
var _overlay: CoverageOverlay
var _tabs: HBoxContainer
var _items: HBoxContainer
var _demolish: Button
var _status: Label
var _toast: Label
var _toast_timer: Timer
var _tab_group: ButtonGroup
var _current_category: String = ""


func _ready() -> void:
	_tabs = get_node(TABS_PATH) as HBoxContainer
	_items = get_node(ITEMS_PATH) as HBoxContainer
	_demolish = get_node(DEMOLISH_PATH) as Button
	_status = get_node(STATUS_PATH) as Label
	_toast = get_node(TOAST_PATH) as Label
	_toast_timer = get_node(TOAST_TIMER_PATH) as Timer
	_toast.visible = false
	if not _toast_timer.timeout.is_connected(hide_toast):
		_toast_timer.timeout.connect(hide_toast)
	if not _demolish.pressed.is_connected(_on_demolish_pressed):
		_demolish.pressed.connect(_on_demolish_pressed)


## 팔레트를 만든다. ghost·overlay 는 null 이어도 된다(버튼·토스트만 동작).
func bind(bus: EventBus, catalog: BuildCatalog, ghost: PlacementGhost, overlay: CoverageOverlay) -> void:
	_unsubscribe()
	_bus = bus
	_catalog = catalog
	_ghost = ghost
	_overlay = overlay
	if _bus != null:
		_bus.subscribe(EV_REJECTED, on_rejected)
	if _ghost != null and not _ghost.state_changed.is_connected(refresh_status):
		_ghost.state_changed.connect(refresh_status)
	if _overlay != null and not _overlay.refreshed.is_connected(refresh_status):
		_overlay.refreshed.connect(refresh_status)
	_build_buttons()
	refresh_status()


func _exit_tree() -> void:
	_unsubscribe()


func _unsubscribe() -> void:
	if _bus != null:
		_bus.unsubscribe(EV_REJECTED, on_rejected)
	_bus = null


# --- 조회 -------------------------------------------------------------------

func get_tab_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for c: Node in _tabs.get_children():
		if c is Button and not c.is_queued_for_deletion():
			out.append(c as Button)
	return out


## 가구 버튼 전부(모든 카테고리, 테이블 순서).
func get_item_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for box: Node in _items.get_children():
		if box.is_queued_for_deletion():
			continue
		for c: Node in box.get_children():
			if c is Button:
				out.append(c as Button)
	return out


func get_item_button(furniture_id: String) -> Button:
	for b: Button in get_item_buttons():
		if str(b.get_meta(META_FURNITURE_ID, "")) == furniture_id:
			return b
	return null


func get_demolish_button() -> Button:
	return _demolish


func get_current_category() -> String:
	return _current_category


func get_status_text() -> String:
	return _status.text


func get_toast_text() -> String:
	return _toast.text


func is_toast_visible() -> bool:
	return _toast.visible


func get_toast_timer() -> Timer:
	return _toast_timer


# --- 동작 -------------------------------------------------------------------

## 탭 전환: 그 카테고리의 버튼 줄만 보인다. 없는 카테고리면 false.
func select_category(category: String) -> bool:
	var found: bool = false
	for box: Node in _items.get_children():
		var on: bool = str(box.get_meta(META_CATEGORY, "")) == category
		(box as Control).visible = on
		found = found or on
	if not found:
		return false
	_current_category = category
	for t: Button in get_tab_buttons():
		t.set_pressed_no_signal(str(t.get_meta(META_CATEGORY, "")) == category)
	return true


## build.rejected → 토스트. 문구 = "거절: <표시 이름> (<reason>)".
func on_rejected(payload: Dictionary) -> void:
	var reason: String = str(payload.get("reason", ""))
	show_toast("거절: %s (%s)" % [REASON_LABELS.get(reason, reason), reason])


func show_toast(text: String) -> void:
	_toast.text = text
	_toast.visible = true
	_toast_timer.start()


func hide_toast() -> void:
	_toast.visible = false


## 상태 문구 갱신(고스트·오버레이 변화 때 자동).
func refresh_status() -> void:
	if _status == null:
		return
	var lines: PackedStringArray = PackedStringArray()
	lines.append(_ghost_line())
	if _overlay != null:
		lines.append(_overlay.get_hud_text())
	lines.append("회전 %s · 취소 %s · 철거 %s" % [
		CoverageOverlay.key_name(InputActions.BUILD_ROTATE), CoverageOverlay.key_name(InputActions.BUILD_CANCEL),
		CoverageOverlay.key_name(InputActions.BUILD_DEMOLISH)])
	_status.text = "\n".join(lines)


# --- 내부 -------------------------------------------------------------------

func _ghost_line() -> String:
	if _ghost == null:
		return "배치: -"
	match _ghost.get_mode():
		PlacementGhost.Mode.PLACE:
			var row: Dictionary = _catalog.furniture(_ghost.get_selected_id())
			var line: String = "배치: %s · %d°" % [row.get("name", _ghost.get_selected_id()), _ghost.get_rotation_deg()]
			if not _ghost.get_reason().is_empty():
				line += " — %s" % REASON_LABELS.get(_ghost.get_reason(), _ghost.get_reason())
			return line
		PlacementGhost.Mode.DEMOLISH:
			return "철거: 가구를 클릭"
	return "배치: 팔레트에서 가구 선택"


func _build_buttons() -> void:
	for c: Node in _tabs.get_children():
		_tabs.remove_child(c)
		c.queue_free()
	for c: Node in _items.get_children():
		_items.remove_child(c)
		c.queue_free()
	if _catalog == null:
		return
	_tab_group = ButtonGroup.new()
	for cat: String in _catalog.categories():
		var tab: Button = Button.new()
		tab.name = TAB_NAME_PATTERN % cat
		tab.text = CATEGORY_LABELS.get(cat, cat)
		tab.toggle_mode = true
		tab.button_group = _tab_group
		tab.focus_mode = Control.FOCUS_NONE
		tab.set_meta(META_CATEGORY, cat)
		tab.pressed.connect(select_category.bind(cat))
		_tabs.add_child(tab)
		var box: HBoxContainer = HBoxContainer.new()
		box.name = CATEGORY_BOX_PATTERN % cat
		box.set_meta(META_CATEGORY, cat)
		_items.add_child(box)
		for row: Dictionary in _catalog.rows_in_category(cat):
			var id: String = str(row["id"])
			var b: Button = Button.new()
			b.name = ITEM_NAME_PATTERN % id
			b.text = ITEM_TEXT_PATTERN % [row.get("name", id), int(row.get("build_cost", 0)), int(row.get("upkeep_per_day", 0))]
			b.focus_mode = Control.FOCUS_NONE
			b.set_meta(META_FURNITURE_ID, id)
			b.pressed.connect(_on_item_pressed.bind(id))
			box.add_child(b)
	var cats: PackedStringArray = _catalog.categories()
	if not cats.is_empty():
		select_category(cats[0])


func _on_item_pressed(furniture_id: String) -> void:
	if _ghost != null:
		_ghost.select(furniture_id)


func _on_demolish_pressed() -> void:
	if _ghost != null:
		_ghost.set_demolish_mode(true)

