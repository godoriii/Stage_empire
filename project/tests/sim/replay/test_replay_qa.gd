extends GutTest
## SE-001 QA 추가 (qa, 2026-10-09). test_replay_tick.gd 가 덮지 않는 결정성 항목.
##  1. step() 구동기 + 봇식 무작위 명령(별도 마스터 시드의 하네스 RNG) 으로 시드 42 를 독립 2회 실행 → 체크포인트별
##     스냅샷 JSON·이벤트 열·난수 열 동일. 시드 43 은 seed/rng 외 전부 동일, 전체 JSON 은 다름.
##  2. 1일차 마감 경계(대기 명령 포함)에서 JSON 왕복 스냅샷 → 다른 시드의 새 TickLoop 에 restore → 나머지 실행이
##     연속 실행과 같음(상태·이벤트·난수).
##  3. 마스터 시드 범위 밖 처리(tick.md#결정성과-rng), step() 극단 입력.
## 근거: docs/gdd/tick.md#결정성과-rng, #스냅샷, #배속 S4~S5.

const MAX_ITERS: int = 30000
const CHECKPOINT_EVERY: int = 250
const BOT_EVERY: int = 40
const BOT_SEED: int = 1234
const LAST_DAY: int = 3

var _cfg: SimConfig
var _loop: TickLoop
var _draws: Array = []


func before_all() -> void:
	_cfg = SimConfig.load()


## 게임 스트림 2개를 틱마다 소비해 상태에 RNG 를 섞는다.
func _draw(_payload: Dictionary) -> void:
	_draws.append(_loop.rng.stream("audience").randi())
	_draws.append(_loop.rng.stream("events").randi())


## 한 판: step(0.1) 구동. BOT_EVERY 반복마다 하네스 RNG 로 고른 배속 요청, close 에서는 다음 날 요청.
## split == true 면 1일차 close 에서 스냅샷(JSON 왕복) 후 다른 시드의 새 루프에 restore 하고 이어간다.
func _drive(seed_value: int, split: bool) -> Dictionary:
	_draws = []
	_loop = TickLoop.new(_cfg, seed_value)
	var recs: Array = [EventRecorder.new(_loop.bus)]
	_loop.bus.subscribe("tick.advanced", _draw)
	var bot_names: Array[String] = ["bot"]
	var bot: SeededRng = SeededRng.new(BOT_SEED, bot_names)
	var checkpoints: Array = []
	var did_split: bool = false
	var pending_at_split: int = -1
	var i: int = 0
	while i < MAX_ITERS:
		if i % BOT_EVERY == 0:
			_loop.bus.publish("time.speed_requested", {"speed": bot.stream("bot").randi() % 4})
		if _loop.phase == "close":
			if _loop.day >= LAST_DAY:
				break
			_loop.bus.publish("time.next_day_requested", {})
		if split and not did_split and _loop.phase == "close":
			did_split = true
			var parsed: Variant = JSON.parse_string(JSON.stringify(_loop.snapshot()))
			var next_loop: TickLoop = TickLoop.new(_cfg, 7)
			assert_true(next_loop.restore(parsed), "JSON 왕복 스냅샷 복원")
			pending_at_split = next_loop.bus.get_pending_commands().size()
			_loop = next_loop
			recs.append(EventRecorder.new(_loop.bus))
			_loop.bus.subscribe("tick.advanced", _draw)
		_loop.step(0.1)
		if i % CHECKPOINT_EVERY == 0:
			checkpoints.append(JSON.stringify(_loop.snapshot(), "", true))
		i += 1
	var events: Array = []
	for r: EventRecorder in recs:
		events.append_array(r.events)
	var snap: Dictionary = _loop.snapshot()
	return {
		"iters": i,
		"snap": snap,
		"final": JSON.stringify(snap, "", true),
		"checkpoints": checkpoints,
		"events": JSON.stringify(events, "", true),
		"event_count": events.size(),
		"draws": JSON.stringify(_draws),
		"draw_count": _draws.size(),
		"pending_at_split": pending_at_split,
	}


func _strip_seed_rng(snap: Dictionary) -> String:
	var d: Dictionary = snap.duplicate(true)
	d.erase("seed")
	d.erase("rng")
	return JSON.stringify(d, "", true)


func test_seed42_independent_runs_identical_and_seed43_differs() -> void:
	var a: Dictionary = _drive(42, false)
	var b: Dictionary = _drive(42, false)
	assert_lt(a["iters"], MAX_ITERS, "스크립트가 반복 상한 전에 끝난다")
	assert_eq([a["snap"]["day"], a["snap"]["phase"]], [LAST_DAY, "close"], "3일차 마감까지 진행")
	assert_gt(a["checkpoints"].size(), 10, "체크포인트 충분")
	assert_gt(a["draw_count"], 0, "난수를 실제로 소비했다")
	assert_gt(a["event_count"], 0)
	assert_eq(a["final"], b["final"], "시드 42 독립 2회: 최종 스냅샷 JSON 동일")
	assert_eq(a["checkpoints"], b["checkpoints"], "체크포인트별 스냅샷 JSON 동일")
	assert_eq(a["events"], b["events"], "이벤트 열(이름+페이로드) 동일")
	assert_eq(a["draws"], b["draws"], "난수 열 동일")

	var c: Dictionary = _drive(43, false)
	assert_ne(c["final"], a["final"], "시드 43: 최종 스냅샷 JSON 다름")
	assert_ne(c["draws"], a["draws"], "시드 43: 난수 열 다름")
	assert_ne(c["snap"]["rng"], a["snap"]["rng"], "시드 43: rng 상태 다름")
	assert_eq(_strip_seed_rng(c["snap"]), _strip_seed_rng(a["snap"]), "시드 43: seed·rng 를 뺀 시간 상태는 동일")
	assert_eq(c["events"], a["events"], "시드 43: 시간 이벤트 열은 동일(난수가 시간 규칙에 새지 않는다)")
	var diff_cp: int = 0
	for k: int in a["checkpoints"].size():
		if a["checkpoints"][k] != c["checkpoints"][k]:
			diff_cp += 1
	assert_eq(diff_cp, a["checkpoints"].size(), "시드 43: 모든 체크포인트 JSON 이 다름")


func test_json_roundtrip_restore_at_day_boundary_equals_continuous_run() -> void:
	var a: Dictionary = _drive(42, false)
	var d: Dictionary = _drive(42, true)
	assert_gt(d["pending_at_split"], 0, "분할 경계에 대기 명령이 남아 있다(pending_commands 왕복 검증)")
	assert_eq(d["final"], a["final"], "분할 실행 == 연속 실행: 최종 스냅샷 JSON")
	assert_eq(d["checkpoints"], a["checkpoints"], "체크포인트 전부 동일")
	assert_eq(d["events"], a["events"], "이벤트 열 동일(restore 는 이벤트를 내지 않는다)")
	assert_eq(d["draws"], a["draws"], "난수 열 동일")


## test_tick.gd 는 키 집합을 구현 상수(TickLoop.SNAPSHOT_KEYS)와 비교한다. 여기서는 tick.md#스냅샷 표의 이름을 리터럴로 고정한다.
func test_snapshot_keys_and_values_pinned_to_spec() -> void:
	var loop: TickLoop = TickLoop.new(_cfg, 42)
	loop.advance(1801)   # evening 안
	var snap: Dictionary = loop.snapshot()
	var keys: Array = snap.keys()
	keys.sort()
	assert_eq(keys, ["day", "pending_commands", "phase", "rng", "schema_version", "seed", "speed", "systems", "tick", "tick_in_phase"], "스펙 표의 10개 키(SE-011)")
	# schema_version 2 는 SE-012 에서 적용됨(tick.md 스냅샷 표)
	assert_eq([snap["schema_version"], snap["seed"], snap["tick"], snap["day"], snap["phase"], snap["tick_in_phase"], snap["speed"], snap["pending_commands"], snap["systems"]],
		[2, 42, 1801, 1, "evening", 1, 1, [], {}], "값")
	var stream_keys: Array = snap["rng"].keys()
	stream_keys.sort()
	assert_eq(stream_keys, ["artist", "audience", "economy", "events", "world"], "rng 스트림 5개(v0)")
	assert_false(snap.has("tick_in_day"), "tick_in_day 는 파생이라 저장하지 않는다")


func test_master_seed_out_of_range_is_folded() -> void:
	var names: Array[String] = _cfg.rng_streams
	var low: SeededRng = SeededRng.new(-1, names)
	assert_eq(low.master_seed, SeededRng.MASTER_SEED_MAX, "-1 → posmod(2^31)")
	var high: SeededRng = SeededRng.new(SeededRng.MASTER_SEED_MAX + 1, names)
	assert_eq(high.master_seed, 0, "2^31 → 0")
	assert_push_error_count(2, "범위 밖이면 push_error")
	var loop: TickLoop = TickLoop.new(_cfg, SeededRng.MASTER_SEED_MAX + 1)
	assert_push_error_count(3)
	assert_eq(loop.snapshot()["seed"], 0, "스냅샷 seed 는 접힌 값")
	assert_eq(JSON.stringify(high.get_state()), JSON.stringify(SeededRng.new(0, names).get_state()), "접힌 시드 = 시드 0 과 같은 열")


func test_step_extreme_delta() -> void:
	# 큰 delta(1e9 초 ≈ 31년, 어떤 프레임 정지보다 크다): 상한(max_ticks_per_step)으로 잘리고 누적기는 잔여를 남기지 않는다.
	for s: int in [1, 3]:
		var loop: TickLoop = TickLoop.new(_cfg, 42)
		loop.bus.publish("time.speed_requested", {"speed": s})
		assert_eq(loop.step(1.0e9), _cfg.max_ticks_per_step, "배속 %d: step(1e9) → 상한" % s)
		assert_eq(loop.step(0.0), 0, "배속 %d: 이어진 step(0) 은 0틱(누적기 잔여 없음)" % s)
		assert_eq(loop.step(0.1), s, "배속 %d: 다음 step(0.1) 은 정상 %d틱" % [s, s])
	# 음수·NaN·INF 는 0 으로 취급(틱이 늘지도 줄지도 않는다).
	var l2: TickLoop = TickLoop.new(_cfg, 42)
	assert_eq(l2.step(-1.0), 0, "음수 delta")
	assert_eq(l2.step(NAN), 0, "NaN delta")
	assert_eq(l2.step(INF), 0, "INF delta")
	assert_eq(l2.tick, 0)
	# 잔여 누적: 0.04 × 3 = 0.12초 → 1배속에서 1틱, 잔여 0.02초가 다음 step 에 이어진다.
	var l3: TickLoop = TickLoop.new(_cfg, 42)
	var total: int = 0
	for k: int in 3:
		total += l3.step(0.04)
	assert_eq(total, 1, "0.04×3 → 1틱")
	assert_eq(l3.step(0.08), 1, "잔여 0.02 + 0.08 = 0.1초 → 1틱")


## SE-007-bug 회귀(docs/tickets/SE-007-bug.md 재현 표 + AC1): 수정 전에는 배속 3 에서 delta ≥ ~3.1e11 초,
## 배속 1 에서 ≥ ~9.2e11 초면 `us * s0 * ticks_per_second` 가 int64 를 넘쳐 step() 이 0틱을 돌려주고 누적기가 깨졌다.
## 수정 후: 어떤 큰 delta 에서도 step(d) == max_ticks_per_step, 이어진 step(0.0) == 0(잔여 정상 범위),
## 이어진 step(0.1) == 배속 틱 수. 표의 모든 값 + 그보다 큰 1e300 을 배속 1·2·3 에서 확인한다.
func test_step_int64_overflow_known_bug() -> void:
	var deltas: Array[float] = [3.0e11, 4.0e11, 9.0e11, 1.0e12, 1.0e13, 1.0e300]
	for s: int in [1, 2, 3]:
		for d: float in deltas:
			var loop: TickLoop = TickLoop.new(_cfg, 42)
			loop.bus.publish("time.speed_requested", {"speed": s})
			assert_eq(loop.step(d), _cfg.max_ticks_per_step, "배속 %d: step(%s) → 상한" % [s, d])
			assert_eq(loop.step(0.0), 0, "배속 %d, %s 뒤: step(0) 은 0틱(누적기 잔여 정상)" % [s, d])
			assert_eq(loop.step(0.1), s, "배속 %d, %s 뒤: step(0.1) 은 %d틱" % [s, d, s])
			assert_eq(loop.tick, _cfg.max_ticks_per_step + s, "배속 %d, %s: tick 합계" % [s, d])
	# 재현 절차 그대로(시드 42, 배속 3, step(4e11) → step(0.1)).
	var r: TickLoop = TickLoop.new(_cfg, 42)
	r.bus.publish("time.speed_requested", {"speed": 3})
	assert_eq([r.step(4.0e11), r.step(0.1)], [30, 3], "재현 절차: 30 / 3")
