extends GutTest
## SE-001 AC2~AC7, AC10 — TickLoop. docs/gdd/tick.md#세션-구간, #배속, #명령-큐와-틱-순서, #스냅샷, #수용-기준.

var _cfg: SimConfig
var _loop: TickLoop
var _log: Array = []
var _bad: Array = []


func before_all() -> void:
	_cfg = SimConfig.load()


func before_each() -> void:
	_log = []
	_bad = []
	_loop = null


func _new_loop(seed_value: int = 42) -> TickLoop:
	return TickLoop.new(_cfg, seed_value)


func _hash(loop: TickLoop) -> String:
	return JSON.stringify(loop.snapshot(), "", true)


func _req_speed(loop: TickLoop, s: Variant) -> bool:
	return loop.bus.publish("time.speed_requested", {"speed": s})


func _next_day(loop: TickLoop) -> void:
	loop.bus.publish("time.next_day_requested", {})


## 경계 상태 불변식 I1~I4. 어긋나면 설명 문자열, 아니면 "".
func _invariants(loop: TickLoop) -> String:
	var d: int = _cfg.day_ticks
	if loop.tick != (loop.day - 1) * d + loop.tick_in_day:
		return "I1 tick %d" % loop.tick
	if loop.tick_in_day != _cfg.phase_start(loop.phase) + loop.tick_in_phase:
		return "I2 tick %d" % loop.tick
	var len_p: int = _cfg.phase_ticks(loop.phase)
	if len_p > 0 and not (loop.tick_in_phase >= 0 and loop.tick_in_phase < len_p):
		return "I3 tick %d" % loop.tick
	if len_p == 0 and loop.tick_in_phase != 0:
		return "I3 tick %d" % loop.tick
	if not _cfg.is_speed_allowed(loop.phase, loop.speed):
		return "I4 tick %d speed %d" % [loop.tick, loop.speed]
	return ""


## 루프를 해당 구간 시작 경계까지 진행(1일차).
func _loop_at(phase_id: String) -> TickLoop:
	var loop: TickLoop = _new_loop()
	loop.advance(_cfg.phase_start(phase_id))
	assert_eq(loop.phase, phase_id, "준비: %s 진입" % phase_id)
	return loop


# --- AC2 ---------------------------------------------------------------------

func test_advance_increments_tick() -> void:
	assert_gte(_cfg.phases[0]["default_speed"], 1, "전제: day default_speed ≥ 1")
	var loop: TickLoop = _new_loop()
	assert_eq(loop.tick, 0)
	assert_eq(loop.advance(1), 1, "반환 1")
	assert_eq(loop.tick, 1)
	assert_eq(loop.tick_in_phase, 1)
	assert_eq(loop.advance(-5), 0, "음수 n 은 0")
	assert_eq(loop.tick, 1)


func _check_tick(payload: Dictionary) -> void:
	_log.append(payload)
	var bad: String = _invariants(_loop)
	if bad != "":
		_bad.append(bad)


func test_tick_advanced_published_once_per_tick() -> void:
	_loop = _new_loop()
	_loop.bus.subscribe("tick.advanced", _check_tick)
	assert_eq(_loop.advance(3300), 3300, "반환 3,300")
	assert_eq(_log.size(), 3300, "tick.advanced 3,300회")
	var mono: bool = true
	for i: int in _log.size():
		if _log[i]["tick"] != i + 1:
			mono = false
	assert_true(mono, "tick 1..3300 단조 증가")
	assert_eq(_log[_log.size() - 1], {"tick": 3300, "phase": "close"}, "마지막 페이로드")
	assert_eq(_bad, [], "매 틱 후 I1~I4")
	assert_eq(_invariants(_loop), "")


# --- AC3 ---------------------------------------------------------------------

func test_phase_boundaries_from_config() -> void:
	var total: int = 0
	for ph: Dictionary in _cfg.phases:
		total += ph["ticks"]
	assert_eq(total, 3300, "Σ ticks = 3,300")
	assert_eq(_cfg.day_ticks, total)
	var loop: TickLoop = _new_loop()
	loop.advance(_cfg.phase_start("evening") - 1)
	assert_eq([loop.phase, loop.tick_in_day, loop.tick_in_phase], ["day", 1799, 1799], "1,799틱 후 day")
	loop.advance(1)
	assert_eq([loop.phase, loop.tick_in_day, loop.tick_in_phase], ["evening", 1800, 0], "1,800 은 evening 의 0")
	loop.advance(_cfg.phase_start("show") - loop.tick)
	assert_eq([loop.phase, loop.tick_in_day, loop.tick_in_phase], ["show", 2400, 0])
	loop.advance(_cfg.phase_start("close") - loop.tick)
	assert_eq([loop.phase, loop.tick_in_day, loop.tick_in_phase, loop.tick], ["close", 3300, 0, 3300])
	assert_eq(_invariants(loop), "")


func test_phase_changed_events_in_order() -> void:
	var loop: TickLoop = _new_loop()
	var rec: EventRecorder = EventRecorder.new(loop.bus)
	loop.advance(3300)
	var pcs: Array = rec.of("time.phase_changed")
	assert_eq(pcs, [
		{"from": "day", "to": "evening", "day": 1, "tick": 1800},
		{"from": "evening", "to": "show", "day": 1, "tick": 2400},
		{"from": "show", "to": "close", "day": 1, "tick": 3300},
	], "phase_changed 정확히 3회, 순서대로")
	for pc: Dictionary in pcs:
		var i_pc: int = -1
		var i_tick: int = -1
		for i: int in rec.events.size():
			var e: Array = rec.events[i]
			if e[0] == "time.phase_changed" and e[1] == pc:
				i_pc = i
			if e[0] == "tick.advanced" and e[1]["tick"] == pc["tick"]:
				i_tick = i
		assert_true(i_pc >= 0 and i_pc < i_tick, "tick %d: phase_changed 가 같은 틱의 tick.advanced 보다 먼저" % pc["tick"])
		assert_eq(rec.events[i_tick][1]["phase"], pc["to"], "tick.advanced.phase 는 갱신 후 구간")


# --- AC4 ---------------------------------------------------------------------

func test_close_holds_until_next_day_requested() -> void:
	var loop: TickLoop = _new_loop()
	loop.advance(3300)
	assert_eq(loop.phase, "close")
	var rec: EventRecorder = EventRecorder.new(loop.bus)
	assert_eq(loop.advance(10), 0, "close 에서 advance 반환 0")
	assert_eq(loop.step(1.0), 0, "close 에서 step 반환 0")
	assert_eq(loop.tick, 3300, "tick 불변")
	assert_eq(rec.events, [], "이벤트 없음")
	_next_day(loop)
	assert_eq(loop.day, 1, "명령은 경계 처리 전까지 적용되지 않는다")
	assert_eq(loop.advance(0), 0)
	assert_eq([loop.day, loop.phase, loop.tick_in_day, loop.tick, loop.speed], [2, "day", 0, 3300, 1])
	assert_eq(rec.events, [
		["time.day_started", {"day": 2}],
		["time.phase_changed", {"from": "close", "to": "day", "day": 2, "tick": 3300}],
		["time.speed_changed", {"speed": 1, "from": 0, "cause": "phase_enter"}],
	], "day_started → phase_changed → speed_changed (E8)")
	assert_eq(_invariants(loop), "")
	assert_eq(loop.advance(1), 1)
	assert_eq(loop.tick, 3301)
	assert_eq(rec.events[rec.events.size() - 1], ["tick.advanced", {"tick": 3301, "phase": "day"}])


func test_next_day_ignored_outside_close() -> void:
	for phase_id: String in ["day", "evening", "show"]:
		var loop: TickLoop = _loop_at(phase_id)
		loop.advance(3)
		var before: String = _hash(loop)
		var rec: EventRecorder = EventRecorder.new(loop.bus)
		_next_day(loop)
		loop.advance(0)
		assert_eq(_hash(loop), before, "%s: 상태 불변" % phase_id)
		assert_eq(rec.events, [], "%s: 시간 이벤트 0개" % phase_id)


# --- AC5 ---------------------------------------------------------------------

func test_speed_allowed_per_phase() -> void:
	for ph: Dictionary in _cfg.phases:
		var phase_id: String = ph["id"]
		for s: int in [0, 1, 2, 3]:
			var loop: TickLoop = _loop_at(phase_id)
			var cur: int = loop.speed
			var rec: EventRecorder = EventRecorder.new(loop.bus)
			_req_speed(loop, s)
			loop.advance(0)
			var label: String = "%s 요청 %d (현재 %d)" % [phase_id, s, cur]
			if not (ph["speeds"] as Array).has(s):
				assert_eq(loop.speed, cur, label + ": 거부, 불변")
				assert_eq(rec.events, [["time.speed_rejected", {"speed": s, "reason": "not_allowed", "phase": phase_id}]], label)
			elif s == cur:
				assert_eq(loop.speed, cur, label)
				assert_eq(rec.events, [], label + ": 같은 값은 이벤트 없음")
			else:
				assert_eq(loop.speed, s, label + ": 적용")
				assert_eq(rec.events, [["time.speed_changed", {"speed": s, "from": cur, "cause": "requested"}]], label)


func test_speed_rejected_keeps_state() -> void:
	var loop: TickLoop = _loop_at("show")
	loop.advance(5)
	var rec: EventRecorder = EventRecorder.new(loop.bus)
	var before: String = _hash(loop)
	for s: int in [0, 2, 3]:
		_req_speed(loop, s)
	loop.bus.publish("time.speed_requested", {"speed": "fast"})
	loop.bus.publish("time.speed_requested", {})
	loop.advance(0)
	assert_eq(_hash(loop), before, "요청 전후 상태 해시 동일")
	assert_eq(rec.events, [
		["time.speed_rejected", {"speed": 0, "reason": "not_allowed", "phase": "show"}],
		["time.speed_rejected", {"speed": 2, "reason": "not_allowed", "phase": "show"}],
		["time.speed_rejected", {"speed": 3, "reason": "not_allowed", "phase": "show"}],
		["time.speed_rejected", {"speed": "fast", "reason": "invalid", "phase": "show"}],
		["time.speed_rejected", {"speed": null, "reason": "invalid", "phase": "show"}],
	])
	# 1.5: v0 에서는 명령 페이로드 숫자가 int 만 허용(E4 보강, SE-006 리뷰 발견 1 (a))이라
	# 버스가 publish 단계에서 거부한다(false + push_error). TickLoop 까지 가지 않으므로 speed_rejected 도 없다.
	rec.clear()
	assert_false(_req_speed(loop, 1.5), "1.5 는 버스가 거부")
	assert_push_error_count(1)
	loop.advance(0)
	assert_eq(_hash(loop), before, "1.5 요청 후에도 상태 불변")
	assert_eq(rec.events, [], "이벤트 없음")


func test_speed_clamped_on_phase_enter() -> void:
	for s: int in [3, 2]:
		var loop: TickLoop = _new_loop()
		var rec: EventRecorder = EventRecorder.new(loop.bus)
		_req_speed(loop, s)
		loop.advance(_cfg.phase_start("evening"))
		assert_eq([loop.phase, loop.speed], ["evening", 1], "day %d → evening 진입 1" % s)
		assert_eq(rec.without_ticks(), [
			["time.speed_changed", {"speed": s, "from": 1, "cause": "requested"}],
			["time.phase_changed", {"from": "day", "to": "evening", "day": 1, "tick": 1800}],
			["time.speed_changed", {"speed": 1, "from": s, "cause": "phase_enter"}],
		])
		rec.clear()
		loop.advance(_cfg.phase_start("show") - loop.tick)
		assert_eq([loop.phase, loop.speed], ["show", 1], "show 진입 1 유지")
		assert_eq(rec.without_ticks(), [["time.phase_changed", {"from": "evening", "to": "show", "day": 1, "tick": 2400}]], "show 진입: 배속 이벤트 없음")
		rec.clear()
		loop.advance(_cfg.day_ticks)
		assert_eq([loop.phase, loop.speed], ["close", 0], "close 진입 0")
		assert_eq(rec.without_ticks(), [
			["time.phase_changed", {"from": "show", "to": "close", "day": 1, "tick": 3300}],
			["time.speed_changed", {"speed": 0, "from": 1, "cause": "phase_enter"}],
		])
		rec.clear()
		_next_day(loop)
		loop.advance(0)
		assert_eq([loop.phase, loop.speed, loop.day], ["day", 1, 2], "다음 날 1")
		assert_eq(rec.of("time.speed_changed"), [{"speed": 1, "from": 0, "cause": "phase_enter"}])


# --- AC6 ---------------------------------------------------------------------

func test_step_accumulator_by_speed() -> void:
	var expect: Dictionary = {1: 100, 3: 300, 0: 0}
	for s: int in expect:
		var loop: TickLoop = _new_loop()
		if s != loop.speed:
			_req_speed(loop, s)
		var total: int = 0
		for i: int in 100:
			total += loop.step(0.1)
		assert_eq(loop.speed, s)
		assert_eq(total, expect[s], "배속 %d: step(0.1)×100 → %d틱" % [s, expect[s]])
		assert_eq(loop.tick, expect[s])
	var a: TickLoop = _new_loop()
	var b: TickLoop = _new_loop()
	a.step(0.05)
	a.step(0.05)
	b.step(0.1)
	assert_eq(a.tick, 1)
	assert_eq(_hash(a), _hash(b), "step(0.05)×2 == step(0.1)×1")


func test_step_caps_and_discards() -> void:
	var loop: TickLoop = _new_loop()
	assert_eq(loop.step(10.0), _cfg.max_ticks_per_step, "step(10.0) → max_ticks_per_step 틱")
	assert_eq(loop.step(0.0), 0, "상한 초과분은 버린다")
	assert_eq(loop.tick, 30)

	# day 끝 3배속: evening 진입(3→1)에서 멈추고 남은 몫을 버린다.
	loop = _new_loop()
	loop.advance(_cfg.phase_start("evening") - 10)
	_req_speed(loop, 3)
	assert_eq(loop.step(1.0), 10, "evening 진입 틱까지만")
	assert_eq([loop.phase, loop.speed, loop.tick], ["evening", 1, 1800])
	assert_eq(loop.step(0.0), 0, "남은 몫 버림")
	assert_eq(loop.step(0.1), 1, "이후 1배속")

	# close 진입 시 멈춤.
	loop = _new_loop()
	loop.advance(_cfg.day_ticks - 10)
	assert_eq(loop.step(10.0), 10, "close 진입에서 멈춤")
	assert_eq([loop.phase, loop.tick], ["close", 3300])
	assert_eq(loop.step(1.0), 0)


# --- AC7 ---------------------------------------------------------------------

func _speed_at_tick5(payload: Dictionary) -> void:
	if payload["tick"] == 5:
		_log.append(_loop.speed)
		_req_speed(_loop, 2)


func test_commands_applied_at_tick_boundary() -> void:
	# (a) advance(10)
	_loop = _new_loop()
	_loop.bus.subscribe("tick.advanced", _speed_at_tick5)
	var rec: EventRecorder = EventRecorder.new(_loop.bus)
	_loop.advance(10)
	assert_eq(_log, [1], "핸들러 안에서 speed 는 아직 1")
	var i_sc: int = rec.events.find(["time.speed_changed", {"speed": 2, "from": 1, "cause": "requested"}])
	var i_t5: int = rec.events.find(["tick.advanced", {"tick": 5, "phase": "day"}])
	var i_t6: int = rec.events.find(["tick.advanced", {"tick": 6, "phase": "day"}])
	assert_true(i_t5 >= 0 and i_t5 < i_sc and i_sc < i_t6, "speed_changed 는 tick 5 뒤·tick 6 앞 (%d,%d,%d)" % [i_t5, i_sc, i_t6])
	assert_eq(_loop.speed, 2)
	# (b) advance(5): 마지막 틱 뒤에는 경계 처리가 없다.
	_log = []
	_loop = _new_loop()
	_loop.bus.subscribe("tick.advanced", _speed_at_tick5)
	assert_eq(_loop.advance(5), 5)
	assert_eq(_loop.speed, 1, "반환 뒤 speed 1")
	assert_eq(_loop.bus.get_pending_commands().size(), 1, "명령 1개 대기")
	_loop.advance(0)
	assert_eq(_loop.speed, 2, "advance(0) 경계에서 적용")
	assert_eq(_loop.bus.get_pending_commands().size(), 0)


func _fake_system(ctx: Dictionary, id: String) -> void:
	_log.append([id, ctx])


func _log_tick(payload: Dictionary) -> void:
	_log.append(["tick.advanced", payload["tick"]])


func test_systems_updated_in_config_order() -> void:
	_loop = _new_loop()
	for id: String in ["reputation", "build", "audience"]:
		assert_true(_loop.register_system(id, _fake_system.bind(id)), "등록 %s" % id)
	assert_false(_loop.register_system("weather", _fake_system.bind("weather")), "system_order 에 없는 id")
	assert_false(_loop.register_system("build", _fake_system.bind("build")), "중복 등록")
	assert_push_error_count(2)
	_loop.bus.subscribe("tick.advanced", _log_tick)
	_loop.advance(2)
	assert_eq(_log, [
		["build", {"tick": 1, "day": 1, "phase": "day", "tick_in_day": 0, "tick_in_phase": 0}],
		["audience", {"tick": 1, "day": 1, "phase": "day", "tick_in_day": 0, "tick_in_phase": 0}],
		["reputation", {"tick": 1, "day": 1, "phase": "day", "tick_in_day": 0, "tick_in_phase": 0}],
		["tick.advanced", 1],
		["build", {"tick": 2, "day": 1, "phase": "day", "tick_in_day": 1, "tick_in_phase": 1}],
		["audience", {"tick": 2, "day": 1, "phase": "day", "tick_in_day": 1, "tick_in_phase": 1}],
		["reputation", {"tick": 2, "day": 1, "phase": "day", "tick_in_day": 1, "tick_in_phase": 1}],
		["tick.advanced", 2],
	], "system_order 순서, tick.advanced 이전, ctx 는 틱 시작 시점")
	# 공연 마지막 틱의 ctx (tick.md 예).
	_loop.advance(_cfg.day_ticks - 1 - _loop.tick)
	_log = []
	_loop.advance(1)
	assert_eq(_log[0], ["build", {"tick": 3300, "day": 1, "phase": "show", "tick_in_day": 3299, "tick_in_phase": 899}])


func _ping(_payload: Dictionary) -> void:
	_log.append("ping")


func test_commands_applied_while_paused() -> void:
	for use_step: bool in [false, true]:
		_log = []
		var loop: TickLoop = _new_loop()
		loop.bus.subscribe("test.ping_requested", _ping)
		_req_speed(loop, 0)
		loop.advance(0)
		assert_eq(loop.speed, 0, "일시정지")
		loop.bus.publish("test.ping_requested", {})
		assert_eq(loop.advance(5), 0, "일시정지 중 틱 0")
		assert_eq(_log, ["ping"], "일시정지 중에도 명령 적용")
		loop.bus.publish("test.ping_requested", {})
		_req_speed(loop, 1)
		var n: int = loop.step(0.016) if use_step else loop.advance(0)
		assert_eq(n, 0, "이번 호출은 틱 0")
		assert_eq(loop.tick, 0, "tick 불변")
		assert_eq(loop.speed, 1, "배속 명령 적용")
		assert_eq(_log, ["ping", "ping"])
		var m: int = loop.step(0.1) if use_step else loop.advance(1)
		assert_eq(m, 1, "이어진 호출부터 틱 진행 (step=%s)" % use_step)


# --- AC10 --------------------------------------------------------------------

func _all_primitive(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_ARRAY:
			for e: Variant in v:
				if not _all_primitive(e):
					return false
			return true
		TYPE_DICTIONARY:
			for k: Variant in v:
				if typeof(k) != TYPE_STRING or not _all_primitive(v[k]):
					return false
			return true
	return false


func test_snapshot_restore_equivalence() -> void:
	var a: TickLoop = _new_loop(42)
	a.advance(1000)
	for i: int in 10:
		a.rng.stream("audience").randi()
	_req_speed(a, 3)
	var snap: Dictionary = a.snapshot()
	var keys: Array = snap.keys()
	keys.sort()
	var want: Array = []
	want.append_array(TickLoop.SNAPSHOT_KEYS)
	want.sort()
	assert_eq(keys, want, "#스냅샷 표의 9개 키만")
	assert_eq(keys.size(), 9)
	assert_true(_all_primitive(snap), "기본형만")
	assert_typeof(snap["rng"]["audience"], TYPE_STRING)
	assert_eq(snap["pending_commands"], [{"name": "time.speed_requested", "payload": {"speed": 3}}], "미적용 명령 포함")
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(snap))
	var b: TickLoop = _new_loop(7)
	assert_true(b.restore(parsed), "JSON 왕복 스냅샷 복원")
	assert_eq(_hash(b), _hash(a), "복원 직후 상태 해시 동일(대기 명령 남은 상태, 리뷰 SE-006 발견 1)")
	assert_eq(a.advance(1500), b.advance(1500))
	assert_eq(_hash(b), _hash(a), "복원 후 advance(1500) == 연속 advance(1500)")
	assert_eq(a.speed, b.speed)


func _snap_in_handler(_payload: Dictionary) -> void:
	if _log.is_empty():
		_log.append(_loop.snapshot())
		_log.append(_loop.restore(_loop_snap))
		_log.append(_loop.advance(1))


func _snap_in_system(_ctx: Dictionary) -> void:
	if _bad.is_empty():
		_bad.append(_loop.snapshot())


var _loop_snap: Dictionary = {}


func test_snapshot_rejected_mid_tick() -> void:
	_loop = _new_loop()
	_loop_snap = _loop.snapshot()
	_loop.bus.subscribe("tick.advanced", _snap_in_handler)
	assert_true(_loop.register_system("economy", _snap_in_system))
	_loop.advance(3)
	assert_eq(_log, [{}, false, 0], "핸들러 안: snapshot {} · restore false · advance 0")
	assert_eq(_bad, [{}], "시스템 update 안: snapshot {}")
	assert_push_error_count(4, "각각 push_error")
	assert_eq(_loop.tick, 3, "핸들러 안 advance 는 진행시키지 않음")


func test_restore_rejects_bad_snapshot() -> void:
	var loop: TickLoop = _new_loop()
	loop.advance(2500)
	var good: Dictionary = loop.snapshot()
	var target: TickLoop = _new_loop(9)
	target.advance(10)
	var before: String = _hash(target)
	var bads: Dictionary = {}
	var s: Dictionary = good.duplicate(true)
	s["schema_version"] = _cfg.snapshot_schema_version + 1
	bads["schema_version"] = s
	s = good.duplicate(true)
	s["tick"] = good["tick"] + 1
	bads["I1 tick 조작"] = s
	s = good.duplicate(true)
	s["phase"] = "night"
	bads["모르는 phase"] = s
	s = good.duplicate(true)
	s["pending_commands"] = [{"name": "time.speed_requested", "payload": {"speed": 1.5}}]
	bads["명령 float"] = s
	for label: String in bads:
		assert_false(target.restore(bads[label]), label + " → false")
		assert_eq(_hash(target), before, label + ": 상태 불변")
	assert_push_error_count(bads.size())
	assert_true(target.restore(good), "정상 스냅샷은 통과")
	assert_eq(_hash(target), _hash(loop))
