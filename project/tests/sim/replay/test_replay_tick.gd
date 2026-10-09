extends GutTest
## SE-001 AC11 — 시드 고정 리플레이. docs/gdd/tick.md#수용-기준 "리플레이 스크립트 (AC11)".
## 실행 A(advance 를 목표까지 한 번에)와 B(advance(37) 반복)의 최종 상태 해시·이벤트 열·뽑은 난수 열이 같아야 한다.

const CHUNK_B: int = 37

var _cfg: SimConfig
var _loop: TickLoop
var _draws: Array = []


func before_all() -> void:
	_cfg = SimConfig.load()


## 상태에 RNG 를 섞기 위한 의도적 소비: tick.advanced 마다 events 스트림 1회.
func _draw(_payload: Dictionary) -> void:
	_draws.append(_loop.rng.stream("events").randi())


func _run_to(target: int, chunk: int) -> void:
	while _loop.tick < target:
		var n: int = target - _loop.tick
		if chunk > 0:
			n = mini(chunk, n)
		if _loop.advance(n) == 0:
			break


func _speed(s: int) -> void:
	_loop.bus.publish("time.speed_requested", {"speed": s})


func _next_day() -> void:
	_loop.bus.publish("time.next_day_requested", {})


func _run(seed_value: int, chunk: int) -> Dictionary:
	_draws = []
	_loop = TickLoop.new(_cfg, seed_value)
	var rec: EventRecorder = EventRecorder.new(_loop.bus)
	_loop.bus.subscribe("tick.advanced", _draw)
	var tag: String = "seed %d chunk %d" % [seed_value, chunk]

	_speed(3)                                     # 1
	_run_to(1000, chunk)                          # 2
	assert_eq(_loop.speed, 3, tag + " #1 1→3")
	_speed(2)
	_run_to(1800, chunk)                          # 3
	assert_eq([_loop.phase, _loop.speed], ["evening", 1], tag + " #3 evening 진입 2→1")
	_speed(2)
	_run_to(2000, chunk)                          # 4
	_speed(0)
	assert_eq(_loop.advance(100), 0, tag + " #4 반환 0")
	assert_eq([_loop.tick, _loop.speed], [2000, 0], tag + " #4 tick 2000, 1→0")
	_speed(1)                                     # 5
	_run_to(2500, chunk)                          # 6
	assert_eq(_loop.phase, "show", tag + " #6")
	_speed(0)
	_run_to(3300, chunk)                          # 7
	assert_eq([_loop.phase, _loop.speed], ["close", 0], tag + " #7 close 1→0")
	_next_day()
	_run_to(3400, chunk)                          # 8
	assert_eq([_loop.day, _loop.tick, _loop.speed], [2, 3400, 1], tag + " #8 day 2")
	_speed(3)
	_run_to(6600, chunk)                          # 9
	assert_eq([_loop.phase, _loop.speed, _loop.tick], ["close", 0, 6600], tag + " #9")
	_next_day()
	_run_to(7100, chunk)                          # 10
	_loop.advance(0)

	var snap: Dictionary = _loop.snapshot()
	return {
		"snap": snap,
		"hash": JSON.stringify(snap, "", true),
		"events": rec.to_json(),
		"time_events": JSON.stringify(rec.without_ticks(), "", true),
		"draws": JSON.stringify(_draws),
		"counts": {
			"tick.advanced": rec.count("tick.advanced"),
			"time.phase_changed": rec.count("time.phase_changed"),
			"time.day_started": rec.count("time.day_started"),
			"time.speed_changed": rec.count("time.speed_changed"),
			"time.speed_rejected": rec.count("time.speed_rejected"),
		},
		"rejected": rec.of("time.speed_rejected"),
	}


func test_two_runs_identical() -> void:
	var a: Dictionary = _run(42, 0)
	var b: Dictionary = _run(42, CHUNK_B)
	assert_eq(a["hash"], b["hash"], "최종 상태 해시 동일")
	assert_eq(a["events"], b["events"], "이벤트 열(이름+페이로드) 동일")
	assert_eq(a["draws"], b["draws"], "뽑은 난수 열 동일")

	var s: Dictionary = a["snap"]
	assert_eq([s["tick"], s["day"], s["phase"], s["tick_in_phase"], s["speed"], s["pending_commands"]],
		[7100, 3, "day", 500, 1, []], "기대 최종 상태")
	assert_eq(a["counts"], {
		"tick.advanced": 7100,
		"time.phase_changed": 8,
		"time.day_started": 2,
		"time.speed_changed": 11,
		"time.speed_rejected": 2,
	}, "기대 이벤트 개수")
	assert_eq(a["rejected"], [
		{"speed": 2, "reason": "not_allowed", "phase": "evening"},
		{"speed": 0, "reason": "not_allowed", "phase": "show"},
	])

	# 시드 43: rng 는 다르고, 시간 이벤트 열은 같다.
	var c: Dictionary = _run(43, 0)
	assert_ne(JSON.stringify(c["snap"]["rng"]), JSON.stringify(s["rng"]), "시드 43 → rng 다름")
	assert_ne(c["draws"], a["draws"], "시드 43 → 난수 열 다름")
	assert_eq(c["events"], a["events"], "시드 43 → 시간 이벤트 열 동일")
