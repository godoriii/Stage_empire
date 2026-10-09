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
	_reentry_on = false
	_reentry_snap_done = false
	_reentry_restore_done = false
	_reentry_log = []
	_reentry_state = {"n": 0}


func _new_loop(seed_value: int = 42) -> TickLoop:
	return TickLoop.new(_cfg, seed_value)


func _hash(loop: TickLoop) -> String:
	return JSON.stringify(loop.snapshot(), "", true)


func _req_speed(loop: TickLoop, s: Variant) -> bool:
	return loop.bus.publish("time.speed_requested", {"speed": s})


func _next_day(loop: TickLoop) -> void:
	loop.bus.publish("time.next_day_requested", {})


## I2 기대값을 getter(phase_start 사용)와 독립으로 계산한다: phases 배열을 앞에서부터 돌며 현재 구간 앞의
## 구간 길이(ticks)를 누적하고 tick_in_phase 를 더한다(docs/reviews/SE-001.md 발견 4-i).
func _tick_in_day_independent(loop: TickLoop) -> int:
	var before: int = 0
	for p: Dictionary in _cfg.phases:
		if p["id"] == loop.phase:
			return before + loop.tick_in_phase
		before += int(p["ticks"])
	return -1


## 경계 상태 불변식 I1~I4. 어긋나면 설명 문자열, 아니면 "".
func _invariants(loop: TickLoop) -> String:
	var d: int = _cfg.day_ticks
	if loop.tick != (loop.day - 1) * d + loop.tick_in_day:
		return "I1 tick %d" % loop.tick
	if loop.tick_in_day != _tick_in_day_independent(loop):
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


## SE-007-bug: S4 포화는 정수 초만 자르고 소수부는 남긴다. S5 의 잔여 acc 는 포화 전 계산과 같아야 한다.
## 배속 1, step(10.05): acc = 100.5틱분 → 30틱 처리, 잔여 0.5틱분. 이어서 0.04초(0.4틱분) → 0틱, 0.01초 → 1틱.
## 1e13 + 0.25초(부동소수 정확값)도 같은 규칙: 잔여 0.5틱분.
func test_step_saturation_keeps_fraction() -> void:
	for d: float in [10.05, 1.0e13 + 0.25]:
		var loop: TickLoop = _new_loop()
		assert_eq(loop.step(d), _cfg.max_ticks_per_step, "step(%s) → 상한" % d)
		assert_eq(loop.step(0.04), 0, "%s 뒤: 잔여 0.5 + 0.4틱분 → 0틱" % d)
		assert_eq(loop.step(0.01), 1, "%s 뒤: 잔여 0.9 + 0.1틱분 → 1틱" % d)
		assert_eq(loop.step(0.0), 0, "%s 뒤: 잔여 0" % d)


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
	assert_eq(keys, want, "#스냅샷 표의 10개 키만")
	assert_eq(keys.size(), 10)
	assert_eq(keys, ["day", "pending_commands", "phase", "rng", "schema_version", "seed", "speed", "systems", "tick", "tick_in_phase"], "tick.md 표 리터럴(SE-011)")
	assert_eq(snap["systems"], {}, "훅 시스템 없음 → systems == {}")
	# SE-012 2차(sim.json v3) 뒤 리터럴 2 로 교체: assert_eq(snap["schema_version"], 2)
	assert_eq(snap["schema_version"], _cfg.snapshot_schema_version, "schema_version == sim.json snapshot_schema_version")
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
	# SE-009: restore 3단계의 I4·seed 범위 검사(tick.md#스냅샷). 기대값은 tick.md 의 리터럴.
	assert_eq(good["phase"], "show", "전제: good 은 show 구간")
	assert_eq(good["speed"], 1, "전제: good 의 speed 는 1")
	var errs: int = bads.size()
	var more: Dictionary = {}
	s = good.duplicate(true)
	s["speed"] = 2
	more["I4 speed 2 in show"] = s
	s = good.duplicate(true)
	s["seed"] = -1
	more["seed -1"] = s
	s = good.duplicate(true)
	s["seed"] = 2147483648
	more["seed 2^31"] = s
	for label: String in more:
		assert_false(target.restore(more[label]), label + " → false")
		errs += 1
		assert_push_error_count(errs, label + ": push_error 1회")
		assert_eq(_hash(target), before, label + ": 상태 불변")
	s = good.duplicate(true)
	s["seed"] = 2147483647
	assert_true(target.restore(s), "seed max passes → true")
	assert_push_error_count(errs, "seed max passes: push_error 추가 0회")
	assert_eq(target.master_seed, 2147483647, "seed max passes: master_seed")
	assert_eq(target.snapshot()["seed"], 2147483647, "seed max passes: snapshot seed")
	# SE-011: restore 5단계 systems 불일치(D5). 훅 없는 target.
	var before_sys: String = _hash(target)
	var sys_bads: Dictionary = {}
	s = good.duplicate(true)
	s.erase("systems")
	sys_bads["systems 키 없음"] = s
	s = good.duplicate(true)
	s["systems"] = []
	sys_bads["systems 배열"] = s
	s = good.duplicate(true)
	s["systems"] = {"build": 5}
	sys_bads["systems.build 값이 객체 아님"] = s
	for label: String in sys_bads:
		assert_false(target.restore(sys_bads[label]), label + " → false")
		errs += 1
		assert_push_error_count(errs, label + ": push_error 1회")
		assert_eq(_hash(target), before_sys, label + ": 상태 불변")
	# 훅 시스템(build)이 등록된 target2 에 systems == {} → 항목 없음(③) 실패, restore_hook 호출 0회.
	var journal: Array = []
	var fake: FakeSys = FakeSys.new("build", journal)
	var target2: TickLoop = _new_loop(11)
	assert_true(target2.register_system("build", fake.update, fake.snapshot_hook, fake.restore_hook))
	var before2: String = _hash(target2)
	assert_false(target2.restore(good), "훅 시스템 항목 없음 → false")
	errs += 1
	assert_push_error_count(errs, "③: push_error 1회")
	assert_eq(_hash(target2), before2, "③: target2 상태 불변")
	assert_eq(fake.restore_calls, 0, "③: restore_hook 호출 0회")
	# 훅 시스템이 아닌 id(system_order 밖 weather, 미등록 staff) → 경고 후 무시, true.
	s = good.duplicate(true)
	s["systems"] = {"weather": {}, "staff": {}}
	assert_true(target.restore(s), "모르는 id 항목은 경고 후 무시")
	assert_push_warning_count(2, "id 마다 push_warning 1회")
	assert_push_error_count(errs, "push_error 추가 0")
	assert_eq(_hash(target), _hash(loop), "경고 항목은 버려져 systems == {}")
	assert_true(target.restore(good), "정상 스냅샷은 통과")
	assert_eq(_hash(target), _hash(loop))


# --- AC10 SE-011: 시스템 스냅샷 훅 (tick.md#명령-큐와-틱-순서 "시스템 등록", #스냅샷) -----------------

## 테스트용 가짜 시스템(tick.md#테스트-방법). 상태 {n}, update 가 n += 1, 훅은 깊은 복사·검사 후 교체(SH3).
## 공유 journal 에 restore_hook 호출을 [id, d.n] 으로 남긴다.
class FakeSys:
	extends RefCounted
	var id: String = ""
	var journal: Array = []
	var state: Dictionary = {"n": 0}
	var restore_calls: int = 0
	var fail_restore: bool = false
	## 0 보다 크면 restore_calls 가 이 값 이상인 호출부터 false.
	var fail_from_call: int = 0
	var override_on: bool = false
	var override_value: Variant = null

	func _init(p_id: String, p_journal: Array) -> void:
		id = p_id
		journal = p_journal

	func update(_ctx: Dictionary) -> void:
		state["n"] = int(state["n"]) + 1

	func snapshot_hook() -> Variant:
		if override_on:
			return override_value
		return state.duplicate(true)

	func restore_hook(d: Dictionary) -> bool:
		restore_calls += 1
		journal.append([id, d.get("n")])
		if fail_restore or (fail_from_call > 0 and restore_calls >= fail_from_call):
			return false
		var n: Variant = d.get("n")
		if n is float and is_finite(n) and n == floorf(n):
			n = int(n)
		if not (n is int):
			return false
		state = {"n": n}
		return true


func _journal_ids(journal: Array) -> Array:
	var out: Array = []
	for e: Array in journal:
		out.append(e[0])
	return out


func _register_fakes(loop: TickLoop, journal: Array) -> Dictionary:
	var f: Dictionary = {
		"reputation": FakeSys.new("reputation", journal),
		"build": FakeSys.new("build", journal),
		"audience": FakeSys.new("audience", journal),
	}
	assert_true(loop.register_system("reputation", f["reputation"].update, f["reputation"].snapshot_hook, f["reputation"].restore_hook))
	assert_true(loop.register_system("build", f["build"].update, f["build"].snapshot_hook, f["build"].restore_hook))
	assert_true(loop.register_system("audience", f["audience"].update), "2인자(훅 없음)")
	return f


func test_register_system_rejects_half_hooks() -> void:
	var journal: Array = []
	var fake: FakeSys = FakeSys.new("build", journal)
	var loop: TickLoop = _new_loop()
	var upd: Callable = fake.update
	var snap: Callable = fake.snapshot_hook
	var rest: Callable = fake.restore_hook
	var bad: Callable = Callable(fake, "no_such_method")
	assert_false(loop.register_system("build", upd, snap), "(1) restore 비움 → G5")
	assert_false(loop.register_system("build", upd, Callable(), rest), "(2) snapshot 비움 → G5")
	assert_false(loop.register_system("build", upd, bad, rest), "(3) snapshot 무효 → G6")
	assert_false(loop.register_system("build", upd, snap, bad), "(4) restore 무효 → G6")
	assert_false(loop.register_system("build", bad, snap, rest), "(5) update 무효 → G4")
	assert_push_error_count(5, "실패마다 push_error 1회")
	assert_eq(loop.snapshot()["systems"], {}, "등록 안 됨: systems == {}")
	loop.advance(1)
	assert_eq(fake.state["n"], 0, "등록 안 됨: update 호출 0회")
	assert_true(loop.register_system("build", upd, snap, rest), "(6) 앞 실패가 등록을 남기지 않아 G3 에 안 걸림")
	assert_false(loop.register_system("build", upd, snap, rest), "(7) 같은 id 재등록 → G3")
	assert_true(loop.register_system("staff", _fake_system.bind("staff")), "(8) 2인자 하위 호환")
	assert_eq(loop.snapshot()["systems"].keys(), ["build"])
	assert_push_error_count(6)


func test_system_snapshot_hooks_included_in_order() -> void:
	# (a) 훅 시스템 없는 루프
	var plain: TickLoop = _new_loop()
	var ks: Array = plain.snapshot().keys()
	ks.sort()
	assert_eq(ks, ["day", "pending_commands", "phase", "rng", "schema_version", "seed", "speed", "systems", "tick", "tick_in_phase"], "10개 키 리터럴")
	assert_eq(plain.snapshot()["systems"], {})
	# (b) reputation(훅), build(훅), audience(훅 없음) 순서로 등록
	var journal: Array = []
	var a: TickLoop = _new_loop(42)
	var fa: Dictionary = _register_fakes(a, journal)
	a.advance(5)
	var rec_a: EventRecorder = EventRecorder.new(a.bus)
	var snap: Dictionary = a.snapshot()
	assert_eq(snap.size(), 10, "최상위 키 10개(SNAPSHOT_KEYS)")
	assert_eq(snap.size(), TickLoop.SNAPSHOT_KEYS.size())
	# SE-012 2차(sim.json v3) 뒤 리터럴 2 로 교체: assert_eq(snap["schema_version"], 2)
	assert_eq(snap["schema_version"], _cfg.snapshot_schema_version)
	assert_eq(snap["systems"].keys(), ["build", "reputation"], "system_order 순 삽입(등록 순서 무관)")
	assert_false(snap["systems"].has("audience"), "훅 없는 시스템은 항목 없음")
	assert_eq(snap["systems"]["build"]["n"], 5)
	assert_eq(_hash(a), JSON.stringify(snap, "", true), "두 번 호출해도 같은 해시(SH1)")
	assert_eq([fa["build"].state, fa["reputation"].state, fa["audience"].state], [{"n": 5}, {"n": 5}, {"n": 5}], "가짜 상태 불변")
	snap["systems"]["build"]["n"] = 999
	assert_eq(fa["build"].state["n"], 5, "스냅샷을 고쳐도 시스템 불변(SH7 깊은 복사)")
	# (c) JSON 왕복 → 새 루프 + 새 가짜에 복원
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(a.snapshot()))
	var b: TickLoop = _new_loop(7)
	var fb: Dictionary = _register_fakes(b, journal)
	var rec_b: EventRecorder = EventRecorder.new(b.bus)
	journal.clear()
	assert_true(b.restore(parsed), "restore true")
	assert_eq(_journal_ids(journal), ["build", "reputation"], "restore_hook 각 1회, system_order 순")
	assert_eq(_hash(b), _hash(a), "복원 직후 해시 동일")
	# (d) snapshot()/restore() 동안 이벤트 0개
	assert_eq(rec_a.events, [], "snapshot 중 이벤트 0개")
	assert_eq(rec_b.events, [], "restore 중 이벤트 0개")
	a.advance(100)
	b.advance(100)
	assert_eq(_hash(b), _hash(a), "양쪽 advance(100) 후 해시 동일")
	assert_eq([fb["build"].state["n"], fb["reputation"].state["n"]], [105, 105], "훅 가짜 n == 105")


func test_system_restore_rolls_back_on_failure() -> void:
	var journal: Array = []
	var loop: TickLoop = _new_loop(42)
	var f: Dictionary = {}
	for id: String in ["build", "audience", "economy"]:
		f[id] = FakeSys.new(id, journal)
		assert_true(loop.register_system(id, f[id].update, f[id].snapshot_hook, f[id].restore_hook))
	loop.advance(10)
	var s: Dictionary = JSON.parse_string(JSON.stringify(loop.snapshot()))
	assert_eq(s["systems"]["build"]["n"], 10.0, "전제: 스냅샷 n == 10")
	loop.advance(20)
	_req_speed(loop, 2)
	var before_snap: Dictionary = loop.snapshot()
	var before: String = JSON.stringify(before_snap, "", true)
	# (a) economy 의 restore_hook 이 false → 역순 롤백
	f["economy"].fail_restore = true
	journal.clear()
	assert_false(loop.restore(s), "restore false")
	assert_eq(_journal_ids(journal), ["build", "audience", "economy", "audience", "build"], "적용 2 → 실패 1 → 역순 롤백 2")
	assert_eq([journal[3][1], journal[4][1]], [30, 30], "롤백은 사전 스냅샷(n == 30)")
	for id: String in f:
		assert_eq(f[id].state["n"], 30, "%s n == 30" % id)
	assert_eq(_hash(loop), before, "TickLoop 카운터·rng·명령 큐(1개)·시스템 상태 불변")
	assert_eq([loop.tick, loop.bus.get_pending_commands().size()], [30, 1])
	assert_push_error_count(1, "시스템 실패 1")
	# (b) build 롤백도 실패(적용은 성공) → 복구 불능, push_error 누적 3
	f["build"].fail_from_call = f["build"].restore_calls + 2
	assert_false(loop.restore(s))
	assert_push_error_count(3, "시스템 실패 1 + 롤백 실패 1")
	var now: Dictionary = loop.snapshot()
	var was: Dictionary = before_snap.duplicate(true)
	now.erase("systems")
	was.erase("systems")
	assert_eq(JSON.stringify(now, "", true), JSON.stringify(was, "", true), "systems 를 뺀 TickLoop 상태 불변")
	# (c) 실패 설정을 끄면 성공
	f["economy"].fail_restore = false
	f["build"].fail_from_call = 0
	assert_true(loop.restore(s))
	for id: String in f:
		assert_eq(f[id].state["n"], 10, "%s n == 10" % id)
	assert_eq(loop.tick, 10)


func test_system_snapshot_rejects_invalid_hook_return() -> void:
	var journal: Array = []
	var fake: FakeSys = FakeSys.new("build", journal)
	var loop: TickLoop = _new_loop()
	assert_true(loop.register_system("build", fake.update, fake.snapshot_hook, fake.restore_hook))
	loop.advance(3)
	var good: Dictionary = loop.snapshot()
	var bad_values: Array = [[], "x", {"v": Vector2(1, 2)}, {"o": RefCounted.new()}, {"a": [Callable()]}, {1: 2}]
	fake.override_on = true
	var n: int = 0
	for v: Variant in bad_values:
		fake.override_value = v
		assert_eq(loop.snapshot(), {}, "반환값 %s → {}" % [v])
		n += 1
		assert_push_error_count(n, "push_error 1회")
	var tick0: int = loop.tick
	var rng0: Dictionary = loop.rng.get_state()
	var cmds0: Array = loop.bus.get_pending_commands()
	assert_false(loop.restore(good), "6단계 사전 스냅샷 실패 → false")
	assert_eq(fake.restore_calls, 0, "restore_hook 호출 0회")
	assert_eq([loop.tick, loop.rng.get_state(), loop.bus.get_pending_commands()], [tick0, rng0, cmds0], "TickLoop 필드 불변")
	assert_push_error_count(7)
	fake.override_on = false
	assert_eq(loop.snapshot().size(), 10, "정상 반환이면 키 10개")
	assert_true(loop.restore(good))
	# 호출 시점에 훅이 무효(객체 해제)이면 snapshot() 은 {} + push_error.
	var loop2: TickLoop = _new_loop()
	var gone: FakeSys = FakeSys.new("build", journal)
	assert_true(loop2.register_system("build", gone.update, gone.snapshot_hook, gone.restore_hook))
	gone = null
	assert_eq(loop2.snapshot(), {}, "해제된 객체의 훅 → {}")
	assert_push_error_count(8)


var _reentry_on: bool = false
var _reentry_snap_done: bool = false
var _reentry_restore_done: bool = false
var _reentry_log: Array = []
var _reentry_state: Dictionary = {"n": 0}


func _re_update(_ctx: Dictionary) -> void:
	_reentry_state["n"] = int(_reentry_state["n"]) + 1


func _re_snapshot() -> Dictionary:
	if _reentry_on and not _reentry_snap_done:
		_reentry_snap_done = true
		_reentry_log.append(_loop.snapshot())
		_reentry_log.append(_loop.advance(1))
		_reentry_log.append(_loop.register_system("staff", _fake_system.bind("staff")))
	return _reentry_state.duplicate(true)


func _re_restore(d: Dictionary) -> bool:
	if _reentry_on and not _reentry_restore_done:
		_reentry_restore_done = true
		_reentry_log.append(_loop.restore(_loop_snap))
	_reentry_state = {"n": int(d["n"])}
	return true


func test_system_hooks_reject_reentry() -> void:
	_loop = _new_loop()
	assert_true(_loop.register_system("build", _re_update, _re_snapshot, _re_restore))
	_loop.advance(2)
	_loop_snap = _loop.snapshot()
	var tick0: int = _loop.tick
	_reentry_on = true
	var snap: Dictionary = _loop.snapshot()
	assert_eq(snap.size(), 10, "바깥 snapshot 은 정상")
	assert_eq(_reentry_log, [{}, 0, false], "snapshot_hook 안: snapshot {} · advance 0 · register_system false")
	assert_true(_loop.restore(snap), "바깥 restore 는 true")
	assert_eq(_reentry_log.slice(3), [false], "restore_hook 안: restore false")
	assert_push_error_count(4)
	assert_eq(_loop.tick, tick0, "tick 불변")
	_reentry_on = false
	assert_true(_loop.register_system("staff", _fake_system.bind("staff")), "훅 안 시도가 등록을 남기지 않음")
