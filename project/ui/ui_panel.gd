class_name UiPanel
extends CanvasLayer
## SE-039: HUD·패널 공용 바탕. 이벤트 구독 표(_event_handlers)를 버스에 붙이고 떼는 일만 한다.
## 원칙 1: 구독 + *_requested 발행만. 발행은 하위 클래스가 `_bus.publish("<도메인>.<이름>_requested", …)` 리터럴로 한다
## (test_view_boundary 가 문자열 리터럴로 검사). sim 상태를 바꾸지 않는다. _process 를 쓰지 않는다(원칙 2).
## handle(name, payload) 는 샌드박스 프리셋(버스 발행 없이 가짜 sim 출력 주입)과 UiRoot.inject 가 쓴다.

var _bus: EventBus
var _data: UiData
var _text: UiText
var _params: UiParams
var _handlers: Dictionary = {}


## 버스·데이터·문자열·표시 상수를 받는다. text/params 가 null 이면 폴백 문자열·기본 .tres.
func setup(bus: EventBus, data: UiData, text: UiText, params: UiParams = null) -> void:
	unbind()
	_bus = bus
	_data = data
	_text = text if text != null else UiText.from_strings({})
	_params = params if params != null else UiParams.load_default()
	_handlers = _event_handlers()
	if _bus != null:
		for ev: String in _handlers:
			_bus.subscribe(ev, _handlers[ev])
	_on_setup()


## 하위 클래스: {이벤트 이름: Callable(payload: Dictionary)}.
func _event_handlers() -> Dictionary:
	return {}


## 하위 클래스: setup 끝에 한 번(행 만들기 등).
func _on_setup() -> void:
	pass


func subscribed_events() -> PackedStringArray:
	return PackedStringArray(_handlers.keys())


## 버스 없이 이벤트 하나를 직접 넣는다(프리셋·UiRoot.inject). 구독하지 않는 이벤트면 false.
func handle(event_name: String, payload: Dictionary) -> bool:
	if not _handlers.has(event_name):
		return false
	(_handlers[event_name] as Callable).call(payload)
	return true


func unbind() -> void:
	if _bus != null:
		for ev: String in _handlers:
			_bus.unsubscribe(ev, _handlers[ev])
	_bus = null


func _exit_tree() -> void:
	unbind()


func t(key: String, params: Dictionary = {}) -> String:
	return _text.t(key, params) if _text != null else key
