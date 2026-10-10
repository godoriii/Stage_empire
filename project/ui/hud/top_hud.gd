class_name TopHud
extends UiPanel
## SE-039 AC1·AC3: 상단 HUD(PRD "UI 구성" 상단: 자금·명성·날짜·속도) + 티켓 가격 스피너.
## 구독: economy.cash_changed(현금), reputation.changed(명성 total), time.phase_changed(구간·날짜·배속 버튼 활성),
##   time.day_started(날짜), time.speed_changed(현재 배속), economy.ticket_price_changed/rejected(스피너),
##   session.loaded {day, phase, speed, show_active}(전체 복구 + 명성 초기값 = ReputationSystem.total 읽기, SE-030 인계).
## 발행: time.speed_requested {speed: int}(버튼), economy.ticket_price_requested {price: int}(스피너).
## 배속 버튼 = sim.json 모든 구간 speeds 의 합집합, 현재 구간 speeds 에 없는 값은 비활성(tick.md #배속).
## 스피너 범위 = economy.json 현재 티어 행 ticket_price_min..max, 낮 구간만 편집(economy.md 티켓 가격).
## 현금 초기값 = economy.json starting_cash(새 게임). 불러오기·새 게임 뒤 현금·가격은 apply_session_state(SE-040 AC-39a —
##   메인 씬이 session.loaded 뒤 GameSession.hud_state() 사전을 넘긴다. economy 는 재발행되지 않는다).

signal artist_panel_requested
signal menu_requested

## economy.md: 가격 요청은 낮 구간에서만 유효(구간 id 는 events.md 의 프로토콜 값).
const PRICE_PHASE: String = "day"
const SPEED_NAME_PATTERN: String = "Speed_%d"
## tick.md #배속: 0 = 일시정지(프로토콜 값). 이 버튼만 ui.hud.pause 키로 표시한다.
const PAUSE_SPEED: int = 0
const META_SPEED: StringName = &"speed"
const CASH_PATH: NodePath = ^"Top/VBox/Row1/Cash"
const REP_PATH: NodePath = ^"Top/VBox/Row1/Reputation"
const DAY_PATH: NodePath = ^"Top/VBox/Row1/Day"
const PHASE_PATH: NodePath = ^"Top/VBox/Row1/Phase"
const SPEEDS_PATH: NodePath = ^"Top/VBox/Row1/Speeds"
const PRICE_LABEL_PATH: NodePath = ^"Top/VBox/Row2/PriceLabel"
const PRICE_PATH: NodePath = ^"Top/VBox/Row2/Price"
const ARTISTS_PATH: NodePath = ^"Top/VBox/Row2/Artists"
const MENU_PATH: NodePath = ^"Top/VBox/Row2/Menu"

var _reputation_reader: Object
var _cash: int = 0
var _reputation: int = 0
var _day: int = 0
var _phase: String = ""
var _speed: int = 0
var _price: int = 0


func _event_handlers() -> Dictionary:
	return {
		"economy.cash_changed": on_cash_changed,
		"reputation.changed": on_reputation_changed,
		"time.phase_changed": on_phase_changed,
		"time.day_started": on_day_started,
		"time.speed_changed": on_speed_changed,
		"economy.ticket_price_changed": on_price_changed,
		"economy.ticket_price_rejected": on_price_rejected,
		"session.loaded": on_session_loaded,
	}


## 명성 초기값을 읽을 객체(ReputationSystem — 읽는 멤버는 total 하나). null 이면 0 에서 시작.
func set_reputation_reader(reader: Object) -> void:
	_reputation_reader = reader
	_reputation = read_reputation_total(reader, _reputation)
	_refresh_labels()


## ReputationSystem.total 읽기(프로퍼티 또는 같은 이름 메서드). 없으면 fallback.
static func read_reputation_total(reader: Object, fallback: int) -> int:
	if reader == null:
		return fallback
	if reader.has_method("total"):
		return int(reader.call("total"))
	var v: Variant = reader.get("total")
	return int(v) if v != null else fallback


func _on_setup() -> void:
	_cash = _data.starting_cash
	_price = _data.ticket_price_default
	var spin: SpinBox = get_price_spin()
	spin.min_value = _data.ticket_price_min
	spin.max_value = _data.ticket_price_max
	spin.step = 1
	spin.rounded = true
	spin.set_value_no_signal(_price)
	if not spin.value_changed.is_connected(_on_price_spin_changed):
		spin.value_changed.connect(_on_price_spin_changed)
	var art: Button = get_node(ARTISTS_PATH) as Button
	art.text = t("ui.hud.artists")
	if not art.pressed.is_connected(_emit_artist_panel):
		art.pressed.connect(_emit_artist_panel)
	var menu: Button = get_node(MENU_PATH) as Button
	menu.text = t("ui.hud.menu")
	if not menu.pressed.is_connected(_emit_menu):
		menu.pressed.connect(_emit_menu)
	(get_node(PRICE_LABEL_PATH) as Label).text = t("ui.hud.ticket_price")
	_build_speed_buttons()
	_refresh_labels()


# --- 조회 -------------------------------------------------------------------

func get_cash() -> int:
	return _cash


func get_cash_text() -> String:
	return (get_node(CASH_PATH) as Label).text


func get_reputation_text() -> String:
	return (get_node(REP_PATH) as Label).text


func get_day_text() -> String:
	return (get_node(DAY_PATH) as Label).text


func get_phase_text() -> String:
	return (get_node(PHASE_PATH) as Label).text


func get_speed_buttons() -> Array[Button]:
	var out: Array[Button] = []
	for c: Node in get_node(SPEEDS_PATH).get_children():
		if c is Button and not c.is_queued_for_deletion():
			out.append(c as Button)
	return out


func get_speed_button(speed: int) -> Button:
	return get_node(SPEEDS_PATH).get_node_or_null(SPEED_NAME_PATTERN % speed) as Button


func get_price_spin() -> SpinBox:
	return get_node(PRICE_PATH) as SpinBox


func get_phase() -> String:
	return _phase


func get_speed() -> int:
	return _speed


# --- 이벤트 -----------------------------------------------------------------

func on_cash_changed(p: Dictionary) -> void:
	_cash = int(p.get("cash", _cash))
	_refresh_labels()


func on_reputation_changed(p: Dictionary) -> void:
	_reputation = int(p.get("total", _reputation))
	_refresh_labels()


func on_phase_changed(p: Dictionary) -> void:
	_phase = str(p.get("to", _phase))
	_day = int(p.get("day", _day))
	_refresh_labels()


func on_day_started(p: Dictionary) -> void:
	_day = int(p.get("day", _day))
	_refresh_labels()


func on_speed_changed(p: Dictionary) -> void:
	_speed = int(p.get("speed", _speed))
	_refresh_labels()


func on_price_changed(p: Dictionary) -> void:
	_price = int(p.get("price", _price))
	get_price_spin().set_value_no_signal(_price)


## 거절 → 마지막으로 받아들여진 값으로 되돌린다(알림은 Notifications 가 같은 이벤트로).
func on_price_rejected(_p: Dictionary) -> void:
	get_price_spin().set_value_no_signal(_price)


func on_session_loaded(p: Dictionary) -> void:
	_day = int(p.get("day", _day))
	_phase = str(p.get("phase", _phase))
	_speed = int(p.get("speed", _speed))
	_reputation = read_reputation_total(_reputation_reader, _reputation)
	_refresh_labels()


## SE-040 AC-39a: sim 읽기 전용 상태 사전(GameSession.hud_state 키: day·phase·speed·cash·ticket_price·reputation_total)으로
## 전체를 다시 채운다. 없는 키는 그대로 둔다. 발행 없음.
func apply_session_state(state: Dictionary) -> void:
	_day = int(state.get("day", _day))
	_phase = str(state.get("phase", _phase))
	_speed = int(state.get("speed", _speed))
	_cash = int(state.get("cash", _cash))
	_reputation = int(state.get("reputation_total", _reputation))
	if state.has("ticket_price"):
		_price = int(state["ticket_price"])
		get_price_spin().set_value_no_signal(_price)
	_refresh_labels()


# --- 내부 -------------------------------------------------------------------

func _build_speed_buttons() -> void:
	var box: Node = get_node(SPEEDS_PATH)
	for c: Node in box.get_children():
		box.remove_child(c)
		c.free()
	for s: int in _data.all_speeds:
		var b: Button = Button.new()
		b.name = SPEED_NAME_PATTERN % s
		b.text = t("ui.hud.pause") if s == PAUSE_SPEED else t("ui.hud.speed", {"speed": s})
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.set_meta(META_SPEED, s)
		b.pressed.connect(_on_speed_pressed.bind(s))
		box.add_child(b)


func _refresh_labels() -> void:
	if not is_inside_tree() or _data == null:
		return
	(get_node(CASH_PATH) as Label).text = t("ui.hud.cash", {"cash": _cash})
	(get_node(REP_PATH) as Label).text = t("ui.hud.reputation", {"reputation": _reputation})
	(get_node(DAY_PATH) as Label).text = t("ui.hud.day", {"day": _day})
	(get_node(PHASE_PATH) as Label).text = t("ui.phase.%s" % _phase) if not _phase.is_empty() else ""
	for b: Button in get_speed_buttons():
		var s: int = int(b.get_meta(META_SPEED))
		b.disabled = not _data.speed_allowed(_phase, s)
		b.set_pressed_no_signal(s == _speed)
	get_price_spin().editable = _phase == PRICE_PHASE


func _on_speed_pressed(speed: int) -> void:
	# 눌림 표시는 time.speed_changed 가 올 때만 바꾼다(요청 ≠ 확정).
	var b: Button = get_speed_button(speed)
	if b != null:
		b.set_pressed_no_signal(speed == _speed)
	if _bus != null and _data.speed_allowed(_phase, speed):
		_bus.publish("time.speed_requested", {"speed": speed})


func _on_price_spin_changed(value: float) -> void:
	var price: int = int(round(value))
	if _bus != null and _phase == PRICE_PHASE and price != _price:
		_bus.publish("economy.ticket_price_requested", {"price": price})


func _emit_artist_panel() -> void:
	artist_panel_requested.emit()


func _emit_menu() -> void:
	menu_requested.emit()
