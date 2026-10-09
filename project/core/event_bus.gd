class_name EventBus
extends RefCounted
## 이벤트 버스 (SE-001). 규칙: docs/gdd/tick.md#이벤트-순서 E1~E9, #명령-큐와-틱-순서, docs/gdd/events.md.
##
## - 상태 이벤트: 버스가 쉬고 있으면 즉시 전달하고 연쇄 이벤트까지 다 전달한 뒤 반환(E3).
##   디스패치 중(핸들러 안)에 발행하면 이벤트 큐 끝에 넣고 현재 이벤트가 끝난 뒤 FIFO 로 전달(E2).
## - 명령 이벤트(이름이 COMMAND_SUFFIX 로 끝남): 명령 큐에 넣고 dispatch_commands() 때만 전달(E5).
## - 페이로드는 기본형·Array·Dictionary 만(E4). 명령 페이로드의 숫자는 int 만 허용한다(v0, SE-006 리뷰
##   발견 1 의 (a) 안): 스냅샷 JSON 왕복 후 정수값 float 를 int 로 되돌리는 정규화가 손실 없이 정의된다.

const COMMAND_SUFFIX: String = "_requested"

var _subs: Dictionary = {}                 # name -> Array[Callable]
var _event_queue: Array[Dictionary] = []   # [{name, payload}] 디스패치 중 발행된 상태 이벤트
var _command_queue: Array[Dictionary] = [] # [{name, payload}] 명령 큐
var _dispatching: bool = false


static func is_command(event_name: String) -> bool:
	return event_name.ends_with(COMMAND_SUFFIX)


## 같은 (이름, 핸들러) 중복 구독은 무시한다. 디스패치 중 구독은 다음 이벤트부터 반영(E1).
func subscribe(event_name: String, handler: Callable) -> void:
	if event_name.is_empty() or not handler.is_valid():
		push_error("[EventBus] subscribe: 이름이 비었거나 핸들러가 유효하지 않다 (%s)" % event_name)
		return
	var list: Array = _subs.get(event_name, [])
	if _find_handler(list, handler) >= 0:
		return
	list.append(handler)
	_subs[event_name] = list


func unsubscribe(event_name: String, handler: Callable) -> void:
	if not _subs.has(event_name):
		return
	var list: Array = _subs[event_name]
	var i: int = _find_handler(list, handler)
	if i >= 0:
		list.remove_at(i)
	if list.is_empty():
		_subs.erase(event_name)


## 상태 이벤트는 즉시(디스패치 중이면 FIFO 큐), 명령은 명령 큐. 페이로드가 E4 위반이면 push_error, false.
func publish(event_name: String, payload: Dictionary = {}) -> bool:
	if event_name.is_empty():
		push_error("[EventBus] publish: 이벤트 이름이 비었다")
		return false
	var cmd: bool = is_command(event_name)
	if not _is_valid_value(payload, not cmd):
		if cmd:
			push_error("[EventBus] publish '%s': 명령 페이로드는 null/bool/int/String/Array/Dictionary 만 허용(float 금지, E4 v0)" % event_name)
		else:
			push_error("[EventBus] publish '%s': 페이로드에 허용되지 않은 값(Object 등)이 있다 (E4)" % event_name)
		return false
	var copy: Dictionary = payload.duplicate(true)
	if cmd:
		_command_queue.append({"name": event_name, "payload": copy})
		return true
	if _dispatching:
		_event_queue.append({"name": event_name, "payload": copy})
		return true
	_dispatch_outermost(event_name, copy)
	return true


## 경계 처리. 호출 시점 명령 k 개만 FIFO 로 전달한다. 전달 중 들어온 명령은 다음 호출로 간다.
## 구독자 없는 명령은 버리고 push_warning. 반환값 = 전달한 명령 수.
func dispatch_commands() -> int:
	if _dispatching:
		push_error("[EventBus] dispatch_commands: 디스패치 중에는 호출할 수 없다")
		return 0
	var k: int = _command_queue.size()
	var delivered: int = 0
	for i: int in k:
		var cmd: Dictionary = _command_queue.pop_front()
		var event_name: String = cmd["name"]
		if not _subs.has(event_name):
			push_warning("[EventBus] 구독자 없는 명령을 버린다: %s" % event_name)
			continue
		_dispatch_outermost(event_name, cmd["payload"])
		delivered += 1
	return delivered


func is_dispatching() -> bool:
	return _dispatching


## 명령 큐의 깊은 복사본 [{name: String, payload: Dictionary}, …] (큐 순서).
func get_pending_commands() -> Array:
	var out: Array = []
	for cmd: Dictionary in _command_queue:
		out.append({"name": cmd["name"], "payload": (cmd["payload"] as Dictionary).duplicate(true)})
	return out


## 명령 큐를 교체한다(스냅샷 복원용). 원소 형식이 틀리면 push_error, false, 큐 불변.
func set_pending_commands(a: Array) -> bool:
	if _dispatching:
		push_error("[EventBus] set_pending_commands: 디스패치 중에는 호출할 수 없다")
		return false
	var next: Array[Dictionary] = []
	for e: Variant in a:
		if not (e is Dictionary):
			push_error("[EventBus] set_pending_commands: 원소는 {name, payload} 객체여야 한다")
			return false
		var n: Variant = e.get("name")
		var p: Variant = e.get("payload")
		if not (n is String or n is StringName) or not is_command(String(n)):
			push_error("[EventBus] set_pending_commands: 명령 이름이 아니다: %s" % [n])
			return false
		if not (p is Dictionary) or not _is_valid_value(p, false):
			push_error("[EventBus] set_pending_commands: '%s' 페이로드가 명령 규칙(E4 v0)을 어긴다" % n)
			return false
		next.append({"name": String(n), "payload": (p as Dictionary).duplicate(true)})
	_command_queue = next
	return true


## JSON 왕복으로 온 명령 목록을 정규화한다: 정수값 float → int (재귀). 명령 페이로드는 원래 int 만
## 가지므로 손실 없는 역변환이다. 정수값이 아닌 float·형식 오류가 있으면 null.
static func normalize_commands(a: Variant) -> Variant:
	if not (a is Array):
		return null
	var out: Array = []
	for e: Variant in a:
		if not (e is Dictionary):
			return null
		var n: Variant = e.get("name")
		if not (n is String or n is StringName) or not is_command(String(n)):
			return null
		var ok: Array = [true]
		var p: Variant = _int_normalized(e.get("payload"), ok)
		if not ok[0] or not (p is Dictionary):
			return null
		out.append({"name": String(n), "payload": p})
	return out


## E4 기본형 검사(재귀). 키는 String/StringName, 값은 null/bool/int/(float)/String/StringName/Array/Dictionary.
## TickLoop 이 시스템 snapshot_hook 반환값 검사(SH2)에 쓴다(allow_float = true).
static func is_valid_value(v: Variant, allow_float: bool) -> bool:
	return _is_valid_value(v, allow_float)


## Callable 의 == 는 bind() 인자를 구별하지 않으므로 바인드 인자까지 같아야 같은 핸들러로 본다.
static func _find_handler(list: Array, handler: Callable) -> int:
	var args: Array = handler.get_bound_arguments()
	for i: int in list.size():
		var h: Callable = list[i]
		if h == handler and h.get_bound_arguments() == args:
			return i
	return -1


func _dispatch_outermost(event_name: String, payload: Dictionary) -> void:
	_dispatching = true
	_deliver(event_name, payload)
	while not _event_queue.is_empty():
		var ev: Dictionary = _event_queue.pop_front()
		_deliver(ev["name"], ev["payload"])
	_dispatching = false


## 호출 목록은 시작 시점 사본(E1). 모든 구독자가 같은 페이로드 사본을 받는다(E4).
func _deliver(event_name: String, payload: Dictionary) -> void:
	var handlers: Array = (_subs.get(event_name, []) as Array).duplicate()
	for h: Callable in handlers:
		if h.is_valid():
			h.call(payload)
		else:
			push_warning("[EventBus] 무효 핸들러 건너뜀: %s" % event_name)


static func _is_valid_value(v: Variant, allow_float: bool) -> bool:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME:
			return true
		TYPE_FLOAT:
			return allow_float
		TYPE_ARRAY:
			for e: Variant in v:
				if not _is_valid_value(e, allow_float):
					return false
			return true
		TYPE_DICTIONARY:
			for k: Variant in v:
				if typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME:
					return false
				if not _is_valid_value(v[k], allow_float):
					return false
			return true
	return false


static func _int_normalized(v: Variant, ok: Array) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME:
			return v
		TYPE_FLOAT:
			var f: float = v
			if is_finite(f) and f == floorf(f):
				return int(f)
			ok[0] = false
			return null
		TYPE_ARRAY:
			var arr: Array = []
			for e: Variant in v:
				arr.append(_int_normalized(e, ok))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k: Variant in v:
				if typeof(k) != TYPE_STRING and typeof(k) != TYPE_STRING_NAME:
					ok[0] = false
					return null
				d[k] = _int_normalized(v[k], ok)
			return d
	ok[0] = false
	return null
