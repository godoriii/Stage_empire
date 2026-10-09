class_name EventRecorder
extends RefCounted
## 테스트 전용: 버스의 이벤트를 [이름, 페이로드] 로 기록한다(SE-001). 기록기는 상태 이벤트를 발행하지 않는다(E7).

const TIME_EVENTS: Array[String] = [
	"tick.advanced", "time.phase_changed", "time.day_started", "time.speed_changed", "time.speed_rejected",
]

var events: Array = []   # [[name, payload], …]


func _init(bus: EventBus, names: Array[String] = TIME_EVENTS) -> void:
	for n: String in names:
		bus.subscribe(n, _on_event.bind(n))


func _on_event(payload: Dictionary, event_name: String) -> void:
	events.append([event_name, payload.duplicate(true)])


func clear() -> void:
	events.clear()


func names() -> Array[String]:
	var out: Array[String] = []
	for e: Array in events:
		out.append(e[0])
	return out


func of(event_name: String) -> Array:
	var out: Array = []
	for e: Array in events:
		if e[0] == event_name:
			out.append(e[1])
	return out


func count(event_name: String) -> int:
	return of(event_name).size()


## 시간 이벤트 중 tick.advanced 를 뺀 것(구간·배속·날짜 이벤트만).
func without_ticks() -> Array:
	var out: Array = []
	for e: Array in events:
		if e[0] != "tick.advanced":
			out.append(e)
	return out


func to_json() -> String:
	return JSON.stringify(events, "", true)
