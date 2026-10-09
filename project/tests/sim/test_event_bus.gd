extends GutTest
## SE-001 AC8 — EventBus. docs/gdd/tick.md#이벤트-순서 E1~E5, #명령-큐와-틱-순서.

var _log: Array = []
var _depth: int = 0
var _max_depth: int = 0
var _bus: EventBus


func before_each() -> void:
	_log = []
	_depth = 0
	_max_depth = 0
	_bus = EventBus.new()


func _h(payload: Dictionary, tag: String) -> void:
	_depth += 1
	_max_depth = maxi(_max_depth, _depth)
	_log.append(tag)
	_depth -= 1


func test_delivery_in_subscription_order() -> void:
	var a: Callable = _h.bind("a")
	var b: Callable = _h.bind("b")
	var c: Callable = _h.bind("c")
	_bus.subscribe("test.e", b)
	_bus.subscribe("test.e", a)
	_bus.subscribe("test.e", c)
	_bus.subscribe("test.e", a)   # 중복 무시
	assert_true(_bus.publish("test.e", {"x": 1}))
	assert_eq(_log, ["b", "a", "c"], "구독 순서대로, 중복 구독 무시")


func _publisher(payload: Dictionary) -> void:
	_depth += 1
	_max_depth = maxi(_max_depth, _depth)
	_log.append("a1")
	_bus.publish("test.b", {})
	_bus.publish("test.c", {})
	_log.append("a1-end")
	_depth -= 1


func test_nested_publish_is_queued_fifo() -> void:
	_bus.subscribe("test.a", _publisher)
	_bus.subscribe("test.a", _h.bind("a2"))
	_bus.subscribe("test.b", _h.bind("b"))
	_bus.subscribe("test.c", _h.bind("c"))
	assert_false(_bus.is_dispatching())
	_bus.publish("test.a", {})
	assert_eq(_log, ["a1", "a1-end", "a2", "b", "c"], "현재 이벤트의 남은 구독자 → b → c (E2)")
	assert_eq(_max_depth, 1, "핸들러 실행이 겹치지 않는다(재진입 없음)")
	assert_false(_bus.is_dispatching(), "최외곽 publish 는 연쇄를 다 전달한 뒤 반환(E3)")


func test_unsubscribe_stops_delivery() -> void:
	var a: Callable = _h.bind("a")
	_bus.subscribe("test.e", a)
	_bus.unsubscribe("test.e", a)
	_bus.publish("test.e", {})
	assert_eq(_log, [], "해지 후 호출 0회")

	# 디스패치 중 해지는 다음 이벤트부터(E1).
	var b: Callable = _h.bind("b")
	var remover: Callable = func(_p: Dictionary) -> void:
		_log.append("r")
		_bus.unsubscribe("test.f", b)
	_bus.subscribe("test.f", remover)
	_bus.subscribe("test.f", b)
	_bus.publish("test.f", {})
	assert_eq(_log, ["r", "b"], "진행 중인 이벤트는 시작 시점 목록대로")
	_bus.publish("test.f", {})
	assert_eq(_log, ["r", "b", "r"], "다음 이벤트부터 해지 반영")


func test_rejects_object_payload() -> void:
	_bus.subscribe("test.e", _h.bind("e"))
	assert_false(_bus.publish("test.e", {"o": RefCounted.new()}), "Object")
	assert_false(_bus.publish("test.e", {"v": Vector2()}), "Vector2")
	assert_false(_bus.publish("test.e", {"c": Callable(self, "_h")}), "Callable")
	assert_false(_bus.publish("test.e", {"n": [1, [RefCounted.new()]]}), "중첩 배열 안 Object")
	assert_false(_bus.publish("test.e", {"p": PackedInt32Array([1])}), "Packed*Array")
	assert_push_error_count(5, "위반마다 push_error")
	assert_eq(_log, [], "구독자 호출 0회")
	# 허용 값은 통과하고, 같은 사본이 전달된다.
	assert_true(_bus.publish("test.e", {"a": [1, 2.5, "s", null, true], "d": {"k": &"sn"}}))
	assert_eq(_log, ["e"])


var _cmd_count: int = 0


func _cmd_handler(payload: Dictionary) -> void:
	_cmd_count += 1
	if payload.get("again", false):
		_bus.publish("test.x_requested", {"again": false})


func test_commands_deferred_until_dispatch() -> void:
	_cmd_count = 0
	_bus.subscribe("test.x_requested", _cmd_handler)
	assert_true(_bus.publish("test.x_requested", {"again": true}))
	assert_eq(_cmd_count, 0, "명령은 즉시 전달되지 않는다")
	assert_eq(_bus.get_pending_commands().size(), 1)
	assert_eq(_bus.dispatch_commands(), 1, "전달한 명령 수")
	assert_eq(_cmd_count, 1, "dispatch_commands 에서 1회")
	assert_eq(_bus.get_pending_commands(), [{"name": "test.x_requested", "payload": {"again": false}}], "전달 중 발행한 명령은 다음 호출로")
	assert_eq(_bus.dispatch_commands(), 1)
	assert_eq(_cmd_count, 2, "다음 호출에 전달")
	assert_eq(_bus.dispatch_commands(), 0, "큐가 비면 0")
	# 구독자 없는 명령은 버리고 warning.
	_bus.publish("test.nobody_requested", {})
	assert_eq(_bus.dispatch_commands(), 0, "구독자 없는 명령은 전달 수에 들지 않는다")
	assert_push_warning_count(1)
	assert_eq(_bus.get_pending_commands().size(), 0, "버려진다")


## SE-006 리뷰 발견 1 (a): v0 명령 페이로드의 숫자는 int 만(E4 보강). 상태 이벤트는 float 허용.
func test_command_payload_numbers_int_only() -> void:
	_bus.subscribe("test.y_requested", _h.bind("y"))
	assert_false(_bus.publish("test.y_requested", {"v": 1.5}), "명령 float 거부")
	assert_false(_bus.publish("test.y_requested", {"cell": [1.0, 2]}), "명령 정수값 float 도 거부")
	assert_push_error_count(2)
	assert_eq(_bus.get_pending_commands().size(), 0, "큐잉 안 함")
	assert_true(_bus.publish("test.y_requested", {"cell": [1, 2], "n": null, "s": "a"}), "int·기본형은 허용")
	assert_true(_bus.publish("test.e", {"v": 1.5}), "상태 이벤트는 float 허용")
	# JSON 왕복 정규화: 정수값 float → int, 정수 아닌 float → null.
	var rt: Variant = JSON.parse_string(JSON.stringify(_bus.get_pending_commands()))
	var norm: Variant = EventBus.normalize_commands(rt)
	assert_eq(JSON.stringify(norm, "", true), JSON.stringify(_bus.get_pending_commands(), "", true), "왕복 후 정규화 = 원본")
	assert_typeof(norm[0]["payload"]["cell"][0], TYPE_INT)
	assert_null(EventBus.normalize_commands([{"name": "test.y_requested", "payload": {"v": 1.5}}]), "정수 아닌 float → null")
	assert_null(EventBus.normalize_commands([{"name": "test.state", "payload": {}}]), "명령 이름 아님 → null")
