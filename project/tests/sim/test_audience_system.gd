extends GutTest
## SE-034 — AudienceSystem. docs/gdd/audience.md #수용-기준 AU1~AU10(AU0 은 test_audience_config.gd, AU11 은
## test_audience_perf.gd)과 티켓 AC1~AC6, "SE-034 인계 확정" 리뷰 grep 기준을 옮겼다.
## 기대 수치는 audience.json reference_scenarios[].expected·흐름 값·sim.json 구간 틱에서 읽는다. 이벤트 이름·상태 문자열·reason 은
## 리터럴로 단언한다. 인계값(시드 0 첫 audience 뽑기 3,230,427,448)은 리터럴로 한 번 단언한다.
## 공통 전제: 단위 케이스는 AudienceSystem 하나를 버스에 두고 입력 이벤트를 테스트가 직접 발행하고 update(ctx) 를 부른다
## (직접 발행하는 커버리지에도 blocked_cells 를 넣는다). 하루 단위 케이스는 TickLoop 에 build·economy·audience(+artist)를 훅과
## 함께 등록하고 기준 배치를 실제 build 명령으로 놓는다(AudienceHarness).

## 인계(docs/reviews/SE-029.md "SE-034 인계" 3): 시드 0 의 audience 스트림 첫 randi() 와 파생 시드(tick.md 검증 벡터).
const FIRST_DRAW_SEED0: int = 3230427448
const DERIVED_SEED0_AUDIENCE: int = 1688486501

var _h: AudienceHarness
var _cfg: AudienceConfig
var _base: Dictionary
var _e0: Array
var _e1: Array


func before_all() -> void:
	_h = AudienceHarness.new()
	_cfg = _h.acfg
	_base = _h.coverage_payload("baseline_show")
	_e0 = _cfg.entrances()[0]
	_e1 = _cfg.entrances()[1]


# --- 도우미 -------------------------------------------------------------------

func _sc(id: String) -> Dictionary:
	return _cfg.scenario(id)


func _cov_with(over: Dictionary) -> Dictionary:
	var c: Dictionary = _base.duplicate(true)
	for k: Variant in over:
		c[k] = over[k]
	return c


## 손으로 만든 작은 커버리지(관람 = 음향 = 시야)로 저녁 구간의 단위 시스템.
func _hand(viewing: Array, bar: Array = [], blocked: Array = [], capacity: int = 10) -> Dictionary:
	var u: Dictionary = _h.unit(0)
	(u["bus"] as EventBus).publish("build.coverage_changed", AudienceHarness.small_coverage(viewing, viewing, viewing, bar, blocked, capacity))
	AudienceHarness.phase(u["bus"], "day", "evening")
	return u


func _tick(u: Dictionary, ph: String = "evening", tip: int = 0) -> void:
	(u["aud"] as AudienceSystem).update(_h.ctx(1, ph, tip))


func _agent(u: Dictionary, id: int) -> Dictionary:
	return AudienceHarness.by_id((u["aud"] as AudienceSystem).agents()).get(id, {})


## 마지막 agent_moved 에서 id 의 원소. 없으면 [].
func _moved(u: Dictionary, id: int) -> Array:
	var rec: EventRecorder = u["rec"]
	var all: Array = rec.of("audience.agent_moved")
	if all.is_empty():
		return []
	for e: Array in all.back()["agents"]:
		if int(e[0]) == id:
			return e
	return []


## occ(t): 점유 상태이고 (next ?? tile) == t 인 에이전트 수(MV1).
func _occ(u: Dictionary, t: Array) -> int:
	var n: int = 0
	for a: Dictionary in (u["aud"] as AudienceSystem).agents():
		if AudienceSystem.OCCUPYING.has(a["state"]):
			var o: Variant = a["next"] if a["next"] != null else a["tile"]
			if o == t:
				n += 1
	return n


func _stream_state(rng: SeededRng, name: String) -> String:
	return rng.get_state()[name]


## 시드 seed 의 name 스트림을 k 번 뽑은 뒤 상태.
func _state_after(seed_value: int, name: String, k: int) -> String:
	var r: SeededRng = SeededRng.new(seed_value, _h.scfg.rng_streams)
	for i: int in k:
		r.stream(name).randi()
	return r.get_state()[name]


func _blocked_set(cov: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for c: Array in cov["blocked_cells"]:
		out[Vector2i(c[0], c[1])] = true
	return out


## path 가 from 에서 4방향 한 칸씩 이어지고 blocked 를 지나지 않으며 걸을 수 있는 타일인가.
func _path_ok(from: Array, path: Array, blocked: Dictionary) -> bool:
	var prev: Array = from
	for t: Array in path:
		if absi(int(t[0]) - int(prev[0])) + absi(int(t[1]) - int(prev[1])) != 1:
			return false
		if blocked.has(Vector2i(t[0], t[1])) or not _h.map.is_walkable(t[0], t[1]):
			return false
		prev = t
	return true


# --- 인계·AU1·AU2 입장 수 ---------------------------------------------------------------

func test_first_draw_seed0() -> void:
	assert_eq(SeededRng.derive_seed(0, "audience"), DERIVED_SEED0_AUDIENCE, "0:audience 파생 시드")
	var r: SeededRng = SeededRng.new(0, _h.scfg.rng_streams)
	assert_eq(r.stream("audience").randi(), FIRST_DRAW_SEED0, "시드 0 첫 audience 뽑기")
	for sid: String in _cfg.scenario_ids():
		assert_eq(_sc(sid)["expected"]["first_draw"], FIRST_DRAW_SEED0, "%s first_draw" % sid)


func test_au1_reference_admissions_seed0() -> void:
	for sid: String in _cfg.scenario_ids():
		var sc: Dictionary = _sc(sid)
		var x: Dictionary = sc["expected"]
		var u: Dictionary = _h.unit(sc["seed"])
		var aud: AudienceSystem = u["aud"]
		var rec: EventRecorder = u["rec"]
		_h.decide(u, sc, _base, sc["day"])
		assert_eq(rec.count("audience.admissions_decided"), 1, "%s: admissions_decided 1회" % sid)
		var p: Dictionary = rec.of("audience.admissions_decided")[0]
		assert_eq(p.keys(), ["day", "admissions", "expected", "noise_bp", "capacity", "capped_by", "has_lineup", "by_type"], "%s: 페이로드 키" % sid)
		assert_eq(p["day"], sc["day"])
		for k: String in ["admissions", "noise_bp", "capped_by", "by_type"]:
			assert_eq(p[k], x[k], "%s: %s" % [sid, k])
		assert_eq(p["expected"], int(x["expected_centi"]) / AudienceConfig.CENTI_PER_PERSON, "%s: expected" % sid)
		assert_eq(p["capacity"], _base["capacity"], "%s: capacity" % sid)
		assert_eq(p["has_lineup"], sc["lineup"] != null, "%s: has_lineup" % sid)
		assert_eq(AudienceConfig.expected_by_type(_cfg, sc["lineup"], sc["reputation_total"], sc["ticket_price"]), x["e_centi"], "%s: e_centi" % sid)
		if sc["lineup"] == null:
			assert_eq([p["by_type"]["genre_fan"], p["by_type"]["walk_in"]], [0, 0], "no_lineup: 팬·뜨내기 0")
		# AD11·AD12: 도착 순서 = 유형 순서 배열을 같은 스트림(첫 뽑기 다음)으로 Fisher–Yates
		var n: int = x["admissions"]
		var order: Array = []
		for t: String in _cfg.type_ids():
			for i: int in int(x["by_type"][t]):
				order.append(t)
		var r: SeededRng = SeededRng.new(sc["seed"], _h.scfg.rng_streams)
		r.stream("audience").randi()
		for i: int in range(n - 1, 0, -1):
			var j: int = r.stream("audience").randi() % (i + 1)
			var tmp: Variant = order[i]
			order[i] = order[j]
			order[j] = tmp
		var arr: Array = aud.arrivals()
		assert_eq(arr.size(), n, "%s: arrivals 수" % sid)
		var seen: Dictionary = {}
		for k: int in n:
			var e: Array = arr[k]
			assert_eq([e[0], e[1], e[2]], [k + 1, order[k], k * _cfg.arrival_window_ticks / n], "%s: arrivals[%d]" % [sid, k])
			var t: String = e[1]
			var quota: int = int(x["by_type"][t]) * int(_cfg.type_rule(t)["bar_visit_bp"]) / _cfg.rate_scale
			assert_eq(e[3], int(seen.get(t, 0)) < quota, "%s: arrivals[%d] bar_planned" % [sid, k])
			seen[t] = int(seen.get(t, 0)) + 1
		assert_eq(aud.next_id, n + 1, "%s: next_id" % sid)
		assert_eq(aud.today["admissions"], n)
		assert_eq(_stream_state(u["rng"], "audience"), _state_after(sc["seed"], "audience", maxi(1, n)), "%s: 뽑기 max(1, N)" % sid)


## 시스템 수준 시드 표본: 1, 6, 11, … 96 (20개). 시드 0~100 전체 범위 검사는 AudienceConfig 오라클 쪽
## (`test_audience_data.gd::test_other_seeds_fall_in_declared_ranges`, 101개)이 맡는다. SE-052 C 가 100 → 20 으로 줄였다.
const AU2_SEED_STEP: int = 5


func test_au2_other_seeds_in_range() -> void:
	for sid: String in _cfg.scenario_ids():
		var sc: Dictionary = _sc(sid)
		var rg: Array = sc["expected"]["admissions_range_other_seeds"]
		var lo: int = 1 << 30
		var hi: int = -1
		for seed_value: int in range(1, 101, AU2_SEED_STEP):
			var u: Dictionary = _h.unit(seed_value)
			_h.decide(u, sc, _base)
			var p: Dictionary = (u["rec"] as EventRecorder).of("audience.admissions_decided")[0]
			var adm: int = p["admissions"]
			lo = mini(lo, adm)
			hi = maxi(hi, adm)
			var s: int = 0
			for t: String in _cfg.type_ids():
				s += int(p["by_type"][t])
			assert_eq(s, adm, "%s 시드 %d: by_type 합" % [sid, seed_value])
			assert_eq((u["aud"] as AudienceSystem).arrivals().size(), adm)
		assert_between(lo, int(rg[0]), int(rg[1]), "%s: 최소 입장 %d 가 범위 %s 안" % [sid, lo, rg])
		assert_between(hi, int(rg[0]), int(rg[1]), "%s: 최대 입장 %d 가 범위 %s 안" % [sid, hi, rg])
		assert_lte(hi, _cfg.max_agents, "%s: 150 상한" % sid)


# --- AU3 상한 ------------------------------------------------------------------------

func test_au3_capacity_40() -> void:
	var u: Dictionary = _h.unit(0)
	_h.decide(u, _sc("local_top_baseline"), _cov_with({"capacity": 40}))
	var p: Dictionary = (u["rec"] as EventRecorder).of("audience.admissions_decided")[0]
	assert_eq([p["admissions"], p["capped_by"], p["capacity"]], [40, "capacity", 40])


## AU15 (SE-052, SF5 관객 0): capacity 0·무대 있음·라인업 있음으로 하루 → AD9 admissions 0·capped_by "capacity",
## 마감 요약 crowd_bp 0(옛 규칙은 capacity 0 이면 10,000)·audience 0·avg_satisfaction_bp 0.
func test_au15_capacity_zero_crowd_zero() -> void:
	var u: Dictionary = _h.unit(0)
	var rec: EventRecorder = u["rec"]
	var cov: Dictionary = _cov_with({"capacity": 0})
	assert_true(cov["has_stage"], "전제: 무대 있음")
	_h.decide(u, _sc("rookie_baseline"), cov)
	var p: Dictionary = rec.of("audience.admissions_decided")[0]
	assert_eq([p["admissions"], p["capped_by"], p["capacity"], p["has_lineup"]], [0, "capacity", 0, true], "AD9 capacity 0")
	_h.run_day(u)
	assert_eq(rec.count("audience.day_summary"), 1, "요약 1회")
	var sm: Dictionary = rec.of("audience.day_summary")[0]
	assert_eq([sm["admissions"], sm["audience"], sm["avg_satisfaction_bp"], sm["crowd_bp"]], [0, 0, 0, 0], "SF5 관객 0 → crowd_bp 0")


## 수용 150·인기 100·명성 2,000 → 150 명, 동시 에이전트 최대 150.
func test_au3_stress_150_agents() -> void:
	var lu: Dictionary = _sc("rookie_baseline")["lineup"].duplicate()
	lu["popularity"] = _cfg.stat_max
	var sc: Dictionary = {"reputation_total": _cfg.reputation_cap, "ticket_price": _cfg.price_ref, "lineup": lu}
	var u: Dictionary = _h.unit(0)
	_h.decide(u, sc, _cov_with({"capacity": _cfg.max_agents}))
	var rec: EventRecorder = u["rec"]
	var p: Dictionary = rec.of("audience.admissions_decided")[0]
	assert_eq([p["admissions"], p["capped_by"]], [_cfg.max_agents, "capacity"], "capacity 150 == max_agents → capacity")
	_h.run_day(u)
	var peak: int = 0
	for m: Dictionary in rec.of("audience.agent_moved"):
		peak = maxi(peak, (m["agents"] as Array).size())
	assert_eq(peak, _cfg.max_agents, "동시 에이전트 최대 150")
	var sm: Dictionary = rec.of("audience.day_summary")[0]
	assert_eq(sm["admissions"], _cfg.max_agents)
	assert_eq(int(sm["audience"]) + int(sm["left_early"]), _cfg.max_agents)
	gut.p("스트레스 150: 조기 퇴장 %d, 평균 만족 %d, 바 방문 %d" % [sm["left_early"], sm["avg_satisfaction_bp"], sm["bar_buyers"]])


func test_au3_max_agents_capacity_200() -> void:
	var lu: Dictionary = _sc("rookie_baseline")["lineup"].duplicate()
	lu["popularity"] = _cfg.stat_max
	var sc: Dictionary = {"reputation_total": _cfg.reputation_cap, "ticket_price": _cfg.price_ref, "lineup": lu}
	var u: Dictionary = _h.unit(0)
	_h.decide(u, sc, _cov_with({"capacity": _cfg.max_agents + 50}))
	var p: Dictionary = (u["rec"] as EventRecorder).of("audience.admissions_decided")[0]
	assert_eq([p["admissions"], p["capped_by"]], [_cfg.max_agents, "max_agents"], "capacity 200 → max_agents 로 잘림")


func test_au3_no_stage_draws_once() -> void:
	var u: Dictionary = _h.unit(0)
	var before: Dictionary = (u["rng"] as SeededRng).get_state()
	_h.decide(u, _sc("local_top_baseline"), _h.coverage_payload("empty_room"))
	var p: Dictionary = (u["rec"] as EventRecorder).of("audience.admissions_decided")[0]
	assert_eq([p["admissions"], p["capped_by"], p["capacity"]], [0, "no_stage", _h.coverage_payload("empty_room")["capacity"]])
	assert_eq((u["aud"] as AudienceSystem).arrivals(), [], "도착 없음")
	assert_eq(_stream_state(u["rng"], "audience"), _state_after(0, "audience", 1), "무대가 없어도 정확히 1 뽑기")
	for s: String in _h.scfg.rng_streams:
		if s != "audience":
			assert_eq(_stream_state(u["rng"], s), before[s], "%s 스트림 불변" % s)


# --- 입력 계약 LS1~LS4 ---------------------------------------------------------------

func test_lineup_rules_ls1_to_ls4() -> void:
	var u: Dictionary = _h.unit(0)
	var bus: EventBus = u["bus"]
	var aud: AudienceSystem = u["aud"]
	var rec: EventRecorder = u["rec"]
	var lu: Dictionary = AudienceHarness.lineup_payload(1, _sc("local_top_baseline")["lineup"])
	var s0: String = _stream_state(u["rng"], "audience")
	bus.publish("build.coverage_changed", _base)
	bus.publish("artist.lineup_set", lu)                                                          # LS1 낮
	assert_eq([aud.today, rec.count("audience.admissions_decided")], [null, 0], "LS1 낮 구간 무시")
	AudienceHarness.phase(bus, "day", "evening", 1)
	var wrong_day: Dictionary = lu.duplicate()
	wrong_day["day"] = 2
	bus.publish("artist.lineup_set", wrong_day)                                                   # LS1 날짜
	assert_eq(aud.today, null, "LS1 다른 날 무시")
	var bads: Array = []
	var b: Dictionary
	b = lu.duplicate(); b["artist_id"] = 5; bads.append(["artist_id 정수", b])
	b = lu.duplicate(); b["genre"] = "jazz"; bads.append(["genre jazz", b])
	b = lu.duplicate(); b["popularity"] = _cfg.stat_max + 1; bads.append(["인기 101", b])
	b = lu.duplicate(); b["skill"] = "x"; bads.append(["실력 문자열", b])
	var errs: int = 0
	for c: Array in bads:                                                                         # LS3
		bus.publish("artist.lineup_set", c[1])
		errs += 1
		assert_push_error("LS3", "%s: LS3" % c[0])
		assert_push_error_count(errs, "%s: push_error 1회" % c[0])
		assert_eq(aud.today, null, "%s: 결정 없음" % c[0])
	assert_eq(_stream_state(u["rng"], "audience"), s0, "LS1·LS3 는 뽑지 않는다")
	bus.publish("artist.lineup_set", AudienceHarness.lineup_payload(1, null))                    # LS4 라인업 없음
	assert_eq(rec.count("audience.admissions_decided"), 1, "LS4 라인업 없음도 결정이 있다")
	assert_eq(aud.lineup, null)
	assert_false(aud.today["has_lineup"])
	var adm: int = aud.today["admissions"]
	bus.publish("artist.lineup_set", lu)                                                          # LS2
	assert_eq(rec.count("audience.admissions_decided"), 1, "LS2 하루 1회")
	assert_eq(aud.today["admissions"], adm)
	# day_started 는 lineup·today·도착을 비운다
	bus.publish("artist.lineup_set", lu)
	AudienceHarness.phase(bus, "evening", "show", 1)
	AudienceHarness.phase(bus, "show", "close", 1)
	bus.publish("time.day_started", {"day": 2})
	AudienceHarness.phase(bus, "close", "day", 2)
	assert_eq([aud.day, aud.lineup, aud.today, aud.arrivals(), aud.agents()], [2, null, null, [], []], "day_started 초기화")
	AudienceHarness.phase(bus, "day", "evening", 2)
	bus.publish("artist.lineup_set", AudienceHarness.lineup_payload(2, _sc("local_top_baseline")["lineup"]))
	assert_eq(aud.lineup["genre"], _sc("local_top_baseline")["lineup"]["genre"], "다음 날 다시 결정")
	assert_eq(aud.today["day"], 2)
	assert_eq(aud.arrivals()[0][0], adm + 1, "next_id 는 증가만 한다(재사용 없음)")


func test_input_events_validation() -> void:
	var u: Dictionary = _h.unit(0)
	var bus: EventBus = u["bus"]
	var aud: AudienceSystem = u["aud"]
	bus.publish("build.coverage_changed", _base)
	var cov: Dictionary = aud.coverage.duplicate(true)
	var fields: Array = []
	fields.append_array(AudienceSystem.COVERAGE_FIELDS)
	assert_eq(cov.keys(), fields, "coverage 8필드")
	assert_eq(cov["blocked_cells"], _base["blocked_cells"], "blocked_cells 저장")
	var no_blocked: Dictionary = _base.duplicate(true)
	no_blocked.erase("blocked_cells")
	bus.publish("build.coverage_changed", no_blocked)
	bus.publish("build.coverage_changed", _cov_with({"viewing_tiles": [[99, 0]]}))
	bus.publish("build.coverage_changed", _cov_with({"sound_tiles": [[1, 2, 3]]}))
	bus.publish("build.coverage_changed", _cov_with({"has_stage": 1}))
	assert_eq(aud.coverage, cov, "형식 오류 커버리지는 무시")
	var floats: Dictionary = AudienceHarness.rt(_base)
	bus.publish("build.coverage_changed", floats)
	assert_eq(aud.coverage, cov, "정수값 float 좌표는 int 로 정규화")
	bus.publish("reputation.changed", {"total": -1})
	bus.publish("reputation.changed", {"total": "x"})
	assert_eq(aud.reputation_total, 0)
	bus.publish("reputation.changed", {"total": 150})
	assert_eq(aud.reputation_total, 150)
	bus.publish("economy.ticket_price_changed", {"price": 0, "from": 20})
	assert_eq(aud.ticket_price, _cfg.ticket_price_default, "새 게임 가격 = ticket_price_default")
	bus.publish("economy.ticket_price_changed", {"price": 30, "from": 20})
	assert_eq(aud.ticket_price, 30)
	AudienceHarness.phase(bus, "day", "noon", 1)
	assert_eq(aud.phase, "day", "모르는 구간 무시")
	# update 는 day·close 에서 아무것도 하지 않는다(이벤트 0)
	var rec: EventRecorder = u["rec"]
	aud.update(_h.ctx(1, "day", 5))
	assert_eq(rec.events.size(), 0, "낮 update 이벤트 0")


func test_no_decision_day_reports_zero() -> void:
	var u: Dictionary = _h.unit(0)
	var rec: EventRecorder = u["rec"]
	(u["bus"] as EventBus).publish("build.coverage_changed", _base)
	AudienceHarness.phase(u["bus"], "day", "evening")
	_h.run_day(u)
	assert_eq(rec.count("audience.admissions_decided"), 0, "artist 미등록 → 결정 없음")
	assert_eq(rec.count("audience.agent_moved"), _h.scfg.phase_ticks("evening") + _h.scfg.phase_ticks("show"))
	for m: Dictionary in rec.of("audience.agent_moved"):
		assert_eq(m["agents"], [], "에이전트 0 이어도 agents: []")
	assert_eq(rec.of("economy.sales_reported"), [{"admissions": 0, "audience": 0}], "{0, 0} 보고 1회")
	var sm: Dictionary = rec.of("audience.day_summary")[0]
	assert_eq([sm["admissions"], sm["audience"], sm["avg_satisfaction_bp"], sm["has_lineup"]], [0, 0, 0, false])


# --- AU4 상태 전이표 -------------------------------------------------------------------

## T1(도착)·T2(빈 입구로 입장, 입구 순서).
func test_t1_t2_arrival_and_entry() -> void:
	var u: Dictionary = _hand([[11, 10], [12, 10]])
	assert_true(_h.inject(u["aud"], [], "evening", [[1, "regular", 3, false], [2, "walk_in", 4, false]]))
	for tip: int in 3:
		_tick(u, "evening", tip)
		assert_eq((u["aud"] as AudienceSystem).agents(), [], "spawn_tick 전에는 없다(tip %d)" % tip)
	_tick(u, "evening", 3)
	var a: Dictionary = _agent(u, 1)
	assert_eq([a["state"], a["tile"], a["enter_left"]], ["entering", _e0, _cfg.entry_ticks], "T1 → T2 같은 틱, 첫 입구")
	assert_eq(_moved(u, 1), [1, _h.center(_e0)[0], _h.center(_e0)[1], "entering", "regular"])
	assert_eq((u["aud"] as AudienceSystem).arrivals().size(), 1)
	_tick(u, "evening", 4)
	assert_eq([_agent(u, 2)["state"], _agent(u, 2)["tile"]], ["entering", _e1], "첫 입구가 차 있으면 다음 입구")


## T3: 빈 입구 없음 → queued 대기 +1, 표시 좌표 c(entrances[0]).
func test_t3_queued_waits() -> void:
	var u: Dictionary = _hand([[11, 10]])
	var agents: Array = [
		AudienceHarness.agent(1, "regular", "entering", _e0, {"enter_left": 100}),
		AudienceHarness.agent(2, "regular", "entering", _e1, {"enter_left": 100}),
		AudienceHarness.agent(3, "regular", "queued", null),
	]
	assert_true(_h.inject(u["aud"], agents, "evening"))
	for i: int in range(1, 4):
		_tick(u, "evening", i)
		var a: Dictionary = _agent(u, 3)
		assert_eq([a["state"], a["wait"], a["tile"]], ["queued", i, null], "T3 대기 %d" % i)
	assert_eq(_moved(u, 3), [3, _h.center(_e0)[0], _h.center(_e0)[1], "queued", "regular"], "queued 표시 = c(entrances[0])")


## T4·T5: entering entry_ticks 틱 → moving, 관람 자리 경로.
func test_t4_t5_entering_then_spot() -> void:
	var u: Dictionary = _hand([[11, 10]])
	assert_true(_h.inject(u["aud"], [AudienceHarness.agent(1, "genre_fan", "entering", _e0, {"enter_left": _cfg.entry_ticks})], "evening"))
	for i: int in range(1, _cfg.entry_ticks):
		_tick(u)
		assert_eq([_agent(u, 1)["state"], _agent(u, 1)["enter_left"]], ["entering", _cfg.entry_ticks - i], "T4 %d" % i)
	_tick(u)
	var a: Dictionary = _agent(u, 1)
	assert_eq([a["state"], a["enter_left"], a["target"], a["target_kind"]], ["moving", 0, [11, 10], "spot"], "T5 → moving + 자리")
	var want: Array = []
	for z: int in range(1, 11):
		want.append([11, z])
	assert_eq(a["path"], want, "경로 = 출발 제외 목표 포함")


## T5 바 → T9 at_bar → T10 bar_ticks → T11 구매·관람 자리. 바 자리 없음 → bar_fail_wait_ticks.
func test_t5_t9_t10_t11_bar_visit() -> void:
	var u: Dictionary = _hand([[11, 10]], [[11, 5]])
	var aud: AudienceSystem = u["aud"]
	assert_true(_h.inject(aud, [AudienceHarness.agent(1, "regular", "entering", _e0, {"enter_left": 1, "bar_planned": true})], "evening"))
	_tick(u)
	var a: Dictionary = _agent(u, 1)
	assert_eq([a["state"], a["target"], a["target_kind"], (a["path"] as Array).size()], ["moving", [11, 5], "bar", 5], "T5 바 자리")
	var at_bar: int = 0
	var guard: int = 0
	while _agent(u, 1)["state"] != "watching" and guard < 500:
		_tick(u)
		guard += 1
		var b: Dictionary = _agent(u, 1)
		if b["state"] == "at_bar":
			at_bar += 1
			assert_eq(b["tile"], [11, 5])
		elif at_bar > 0 and b["state"] == "moving" and b["target_kind"] == "spot" and (b["path"] as Array).size() == 5:
			assert_eq([b["target"], b["bar_planned"]], [[11, 10], false], "T11 → 관람 자리")
			assert_eq(aud.today["bar_buyers"], 1, "T11 bar_buyers +1")
	assert_eq(at_bar, _cfg.bar_ticks, "at_bar 는 bar_ticks 틱")
	assert_eq([_agent(u, 1)["state"], _agent(u, 1)["tile"]], ["watching", [11, 10]], "T9 → watching")
	# 바 자리 없음(bar_tiles 빈 커버리지): bar_planned 해제 + 대기 +bar_fail_wait_ticks, 관람 자리로
	var v: Dictionary = _hand([[11, 10]], [])
	assert_true(_h.inject(v["aud"], [AudienceHarness.agent(1, "regular", "entering", _e0, {"enter_left": 1, "bar_planned": true})], "evening"))
	_tick(v)
	var c: Dictionary = _agent(v, 1)
	assert_eq([c["bar_planned"], c["wait"], c["target_kind"], c["state"]], [false, _cfg.bar_fail_wait_ticks, "spot", "moving"], "바 실패")


## T6·T7: 건너기 move_ticks_per_tile 틱, 표시 좌표가 pos_scale ÷ move_ticks 씩. T9·T14: 도착 → watching 유지.
func test_t6_t7_crossing_and_display() -> void:
	var u: Dictionary = _hand([[11, 5]])
	var mover: Dictionary = AudienceHarness.agent(1, "regular", "moving", [11, 3], {"target": [11, 5], "target_kind": "spot", "path": [[11, 4], [11, 5]]})
	assert_true(_h.inject(u["aud"], [mover], "evening"))
	var m: int = _cfg.move_ticks_per_tile
	var step: int = _cfg.pos_scale / m
	var c3: Array = _h.center([11, 3])
	for i: int in range(1, m):
		_tick(u)
		var a: Dictionary = _agent(u, 1)
		assert_eq([a["tile"], a["next"], a["progress"]], [[11, 3], [11, 4], i], "T7/T6 progress %d" % i)
		assert_eq(_moved(u, 1), [1, c3[0], c3[1] + step * i, "moving", "regular"], "표시 좌표 +%d × %d" % [step, i])
	_tick(u)
	var b: Dictionary = _agent(u, 1)
	assert_eq([b["tile"], b["next"], b["progress"]], [[11, 4], null, 0], "move_ticks 번째 틱에 도착")
	assert_eq(_moved(u, 1), [1, c3[0], c3[1] + _cfg.pos_scale, "moving", "regular"])
	for i: int in m:
		_tick(u)
	var w: Dictionary = _agent(u, 1)
	assert_eq([w["state"], w["tile"]], ["watching", [11, 5]], "T6 연쇄 → T9 watching 같은 틱")
	for i: int in 10:
		_tick(u)
	assert_eq([_agent(u, 1)["state"], _agent(u, 1)["tile"]], ["watching", [11, 5]], "T14 제자리")


## T8: 다음 칸 occ ≥ pass_tile_cap → 제자리·blocked +1·대기 +1. pass_override_ticks 연속이면 다음 틱 T7 로 밀고 들어감(occ 3).
func test_t8_blocked_then_override() -> void:
	var u: Dictionary = _hand([[11, 4], [11, 5], [10, 4]])
	var agents: Array = [
		AudienceHarness.agent(1, "regular", "moving", [11, 3], {"target": [11, 5], "target_kind": "spot", "path": [[11, 4], [11, 5]]}),
		AudienceHarness.agent(2, "regular", "watching", [11, 4], {"target": [11, 4], "target_kind": "spot"}),
		AudienceHarness.agent(3, "regular", "watching", [11, 4], {"target": [10, 4], "target_kind": "spot"}),
	]
	assert_true(_h.inject(u["aud"], agents, "evening"))
	assert_eq(_occ(u, [11, 4]), _cfg.pass_tile_cap, "전제: 다음 칸 occ == pass_tile_cap")
	var k: int = _cfg.pass_override_ticks
	for i: int in range(1, k + 1):
		_tick(u)
		var a: Dictionary = _agent(u, 1)
		assert_eq([a["tile"], a["next"], a["blocked"], a["wait"], a["state"]], [[11, 3], null, i, i, "moving"], "T8 막힘 %d" % i)
	_tick(u)
	var b: Dictionary = _agent(u, 1)
	assert_eq([b["next"], b["progress"], b["blocked"]], [[11, 4], 1, 0], "T7 밀고 들어감(blocked 0)")
	assert_eq(b["wait"], k, "밀고 들어간 틱은 대기 없음")
	assert_eq(_occ(u, [11, 4]), _cfg.pass_tile_cap + 1, "그 칸 occ 3")


## T12(나가는 사람은 pass_tile_cap 무시)·T13(입구 도착 → gone)·T15(gone 은 한 번 발행 후 사라짐).
func test_t12_t13_t15_leaving() -> void:
	var u: Dictionary = _hand([[12, 2]])
	var agents: Array = [
		AudienceHarness.agent(1, "walk_in", "leaving", [12, 3], {"target": _e1, "target_kind": "exit", "path": [[12, 2], [12, 1], _e1], "left_early": true, "sat": 5000}),
		AudienceHarness.agent(2, "regular", "watching", [12, 2], {"target": [12, 2], "target_kind": "spot"}),
		AudienceHarness.agent(3, "regular", "watching", [12, 2]),
	]
	assert_true(_h.inject(u["aud"], agents, "evening"))
	_tick(u)
	assert_eq([_agent(u, 1)["next"], _agent(u, 1)["progress"]], [[12, 2], 1], "T12 occ 2 칸으로 바로 건너기")
	var ticks: int = 1
	while not _agent(u, 1).is_empty() and ticks < 100:
		_tick(u)
		ticks += 1
	assert_eq(ticks, 3 * _cfg.move_ticks_per_tile, "세 칸 = 3 × move_ticks 틱")
	var rec: EventRecorder = u["rec"]
	var gone: int = 0
	for mv: Dictionary in rec.of("audience.agent_moved"):
		for e: Array in mv["agents"]:
			if int(e[0]) == 1 and e[3] == "gone":
				gone += 1
				assert_eq([e[1], e[2]], _h.center(_e1), "gone 표시 = 도착한 입구")
	assert_eq(gone, 1, "T15 gone 은 한 번만")
	_tick(u)
	assert_eq(_moved(u, 1), [], "다음 틱에는 없다")
	assert_eq(rec.count("audience.agent_left"), 0, "이미 떠난 사람은 agent_left 를 다시 내지 않는다")


# --- AU6 조기 퇴장 -------------------------------------------------------------------

func test_au6_queued_patience_goes_gone() -> void:
	var u: Dictionary = _hand([[11, 10]])
	var p: int = int(_cfg.type_rule("walk_in")["patience_ticks"])
	var agents: Array = [
		AudienceHarness.agent(1, "regular", "entering", _e0, {"enter_left": 100}),
		AudienceHarness.agent(2, "regular", "entering", _e1, {"enter_left": 100}),
		AudienceHarness.agent(3, "walk_in", "queued", null, {"wait": p}),
	]
	assert_true(_h.inject(u["aud"], agents, "evening"))
	_tick(u, "evening", 7)
	var rec: EventRecorder = u["rec"]
	assert_eq(rec.count("audience.agent_left"), 1)
	var left: Dictionary = rec.of("audience.agent_left")[0]
	assert_eq([left["agent_id"], left["type"], left["reason"], left["day"], left["tick"]], [3, "walk_in", "patience", 1, _h.ctx(1, "evening", 7)["tick"]])
	var want: Dictionary = AudienceConfig.agent_satisfaction(_cfg, AudienceHarness.agent(3, "walk_in", "queued", null, {"wait": p + 1}), null, _cfg.ticket_price_default, 0, 0)
	assert_eq(left["satisfaction_bp"], want["satisfaction_bp"], "확정 만족(crowd 0)")
	assert_eq(_moved(u, 3), [3, _h.center(_e0)[0], _h.center(_e0)[1], "gone", "walk_in"], "맵에 들어온 적 없음 → 바로 gone, c(entrances[0])")
	assert_eq(_agent(u, 3), {}, "제거")
	assert_eq((u["aud"] as AudienceSystem).today["left_early"], 1)


## 맵 안 인내 초과: wait 를 채운 레코드를 restore → T8 한 번 → patience. 공연 끝 left_early 1·audience == admissions − 1.
func test_au6_in_map_patience_then_summary() -> void:
	var u: Dictionary = _hand([[11, 4], [11, 5], [10, 4]])
	var aud: AudienceSystem = u["aud"]
	var rec: EventRecorder = u["rec"]
	var p: int = int(_cfg.type_rule("walk_in")["patience_ticks"])
	var agents: Array = [
		AudienceHarness.agent(1, "walk_in", "moving", [11, 3], {"target": [11, 5], "target_kind": "spot", "path": [[11, 4], [11, 5]], "wait": p}),
		AudienceHarness.agent(2, "regular", "watching", [11, 4], {"target": [11, 4], "target_kind": "spot"}),
		AudienceHarness.agent(3, "regular", "watching", [11, 4], {"target": [10, 4], "target_kind": "spot"}),
	]
	assert_true(_h.inject(aud, agents, "evening"))
	_tick(u)
	assert_eq(rec.count("audience.agent_left"), 1)
	var left: Dictionary = rec.of("audience.agent_left")[0]
	assert_eq([left["agent_id"], left["reason"]], [1, "patience"])
	var a: Dictionary = _agent(u, 1)
	assert_eq([a["state"], a["left_early"], a["target_kind"], a["target"]], ["leaving", true, "exit", _e0], "leaving + 가장 가까운 출구")
	assert_eq(a["path"], [[11, 2], [11, 1], _e0], "SP5 경로")
	assert_eq(a["sat"], left["satisfaction_bp"], "sat 확정")
	var sat: int = a["sat"]
	AudienceHarness.phase(u["bus"], "evening", "show")
	for tip: int in 20:
		_tick(u, "show", tip)
		var b: Dictionary = _agent(u, 1)
		if not b.is_empty():
			assert_eq([b["sat"], b["show_ticks"]], [sat, 0], "퇴장 뒤 sat·집계 불변")
	assert_eq(_agent(u, 1), {}, "입구에서 gone")
	_tick(u, "show", _cfg.show_ticks - 1)
	var sm: Dictionary = rec.of("audience.day_summary")[0]
	assert_eq([sm["admissions"], sm["left_early"], sm["audience"]], [3, 1, 2], "left_early 1, audience == admissions − 1")
	assert_eq(sm["by_type"]["walk_in"], {"admissions": 1, "left_early": 1, "avg_satisfaction_bp": sat}, "조기 퇴장자도 평균에 들어간다")
	assert_eq(rec.of("economy.sales_reported"), [{"admissions": 3, "audience": 2}])


## 관람 자리를 다 예약해 둔 상태의 입장자 → no_spot, 입구에서 바로 나간다.
func test_au6_no_spot() -> void:
	var u: Dictionary = _hand([[11, 10]])
	var agents: Array = [
		AudienceHarness.agent(1, "regular", "watching", [11, 10], {"target": [11, 10], "target_kind": "spot"}),
		AudienceHarness.agent(2, "genre_fan", "entering", _e0, {"enter_left": 1}),
	]
	assert_true(_h.inject(u["aud"], agents, "evening"))
	_tick(u)
	var rec: EventRecorder = u["rec"]
	assert_eq(rec.of("audience.agent_left").size(), 1)
	assert_eq([rec.of("audience.agent_left")[0]["agent_id"], rec.of("audience.agent_left")[0]["reason"]], [2, "no_spot"])
	var a: Dictionary = _agent(u, 2)
	assert_eq([a["state"], a["path"], a["target"]], ["leaving", [], _e0], "입구가 출구, 경로 빈 배열")
	_tick(u)
	assert_eq(_moved(u, 2)[3], "gone", "T13 다음 틱 gone")


# --- AU5·AU7·AU8 하루 ----------------------------------------------------------------

func test_au5_price_lowers_admissions_and_satisfaction() -> void:
	var base: Dictionary = _sc("local_top_baseline")
	var p30: Dictionary = _sc("local_top_price30")
	assert_lt(int(p30["expected"]["admissions"]), int(base["expected"]["admissions"]), "30 < 20 입장")
	for t: String in _cfg.type_ids():
		if int(base["expected"]["e_centi"][t]) > 0:
			assert_lt(int(p30["expected"]["e_centi"][t]), int(base["expected"]["e_centi"][t]), "e_t 감소 %s" % t)
	var res: Dictionary = {}
	for price: int in [10, 20, 30]:
		var sc: Dictionary = base.duplicate(true)
		sc["ticket_price"] = price
		var u: Dictionary = _h.unit(0)
		_h.decide(u, sc, _base)
		_h.run_day(u)
		res[price] = (u["rec"] as EventRecorder).of("audience.day_summary")[0]
	assert_eq(res[20]["admissions"], base["expected"]["admissions"])
	assert_eq(res[30]["admissions"], p30["expected"]["admissions"])
	assert_gt(int(res[10]["admissions"]), int(res[20]["admissions"]), "가격 10 > 20")
	assert_lt(int(res[30]["avg_satisfaction_bp"]), int(res[20]["avg_satisfaction_bp"]), "평균 만족 30 < 20")


func test_au7_day_events_once_with_artist_and_economy() -> void:
	var extra: Array[String] = ["artist.lineup_set", "artist.booked", "time.phase_changed", "economy.day_settled", "tick.advanced"]
	var l: Dictionary = _h.looped(0, null, "baseline_show", true, extra)
	var loop: TickLoop = l["loop"]
	var rec: EventRecorder = l["rec"]
	var acfg: ArtistConfig = (l["artist"] as ArtistSystem).config
	var lu: Dictionary = _sc("local_top_baseline")["lineup"]
	var artist_id: String = ""
	for id: String in acfg.artist_ids():
		var r: Dictionary = acfg.artist(id)
		if r["genre"] == lu["genre"] and r["grade"] == lu["grade"] and r["popularity"] == lu["popularity"] and r["skill"] == lu["skill"]:
			artist_id = id
	assert_ne(artist_id, "", "s07 과 같은 아티스트가 명단에 있다")
	loop.bus.publish("artist.book_requested", {"artist_id": artist_id})
	loop.advance(0)
	assert_eq(rec.count("artist.booked"), 1, "섭외")
	# 틱마다 audience 상태의 에이전트 수(agent_moved 직후 gone 제거 뒤)를 기록
	var alive: Dictionary = {}
	var waud: WeakRef = weakref(l["aud"])   # 버스 ↔ 람다 순환 참조를 만들지 않는다
	loop.bus.subscribe("tick.advanced", func(p: Dictionary) -> void: alive[int(p["tick"])] = (waud.get_ref() as AudienceSystem).agents().size())
	assert_eq(loop.advance(_h.scfg.day_ticks), _h.scfg.day_ticks - _h.scfg.phase_ticks("close"), "close 에서 멈춘다")
	var names: Array[String] = rec.names()
	assert_eq(rec.count("audience.admissions_decided"), 1)
	var i_lineup: int = names.find("artist.lineup_set")
	var i_adm: int = names.find("audience.admissions_decided")
	var i_first_move: int = names.find("audience.agent_moved")
	assert_true(i_lineup >= 0 and i_lineup < i_adm and i_adm < i_first_move, "lineup_set → admissions_decided → 첫 agent_moved")
	var adm: Dictionary = rec.of("audience.admissions_decided")[0]
	assert_eq([adm["admissions"], adm["has_lineup"]], [_sc("local_top_baseline")["expected"]["admissions"], true], "시드 0 로컬 상위 입장")
	# agent_moved: 저녁·공연 틱마다 정확히 1회, 낮 0
	var moved: Array = rec.of("audience.agent_moved")
	var first_tick: int = _h.scfg.phase_start("evening") + 1
	var n_ticks: int = _h.scfg.phase_ticks("evening") + _h.scfg.phase_ticks("show")
	assert_eq(moved.size(), n_ticks, "agent_moved 1,500회")
	for k: int in moved.size():
		var m: Dictionary = moved[k]
		assert_eq(m["tick"], first_tick + k, "agent_moved tick 연속")
		var gone_n: int = 0
		var last_id: int = 0
		for e: Array in m["agents"]:
			assert_eq([typeof(e[0]), typeof(e[1]), typeof(e[2]), typeof(e[3]), typeof(e[4])], [TYPE_INT, TYPE_INT, TYPE_INT, TYPE_STRING, TYPE_STRING], "원소 타입")
			assert_gt(int(e[0]), last_id, "id 오름차순")
			last_id = e[0]
			if e[3] == "gone":
				gone_n += 1
		assert_eq((m["agents"] as Array).size() - gone_n, alive.get(int(m["tick"]), -1), "원소 수 == 그 틱 에이전트 수(tick %d)" % m["tick"])
	# 공연 마지막 틱: agent_moved(전원 gone) → day_summary → sales_reported → phase_changed{close} → day_settled
	for e: Array in moved.back()["agents"]:
		assert_eq(e[3], "gone", "마지막 틱 전원 gone")
	var i_sum: int = names.find("audience.day_summary")
	var i_sales: int = names.find("economy.sales_reported")
	var i_close: int = -1
	for k: int in rec.events.size():
		if rec.events[k][0] == "time.phase_changed" and rec.events[k][1]["to"] == "close":
			i_close = k
	var i_last_move: int = names.rfind("audience.agent_moved")
	assert_true(i_last_move < i_sum and i_sum < i_sales and i_sales < i_close, "agent_moved → day_summary → sales_reported → close")
	assert_eq([rec.count("audience.day_summary"), rec.count("economy.sales_reported"), rec.count("economy.day_settled")], [1, 1, 1])
	var sales: Dictionary = rec.of("economy.sales_reported")[0]
	var settled: Dictionary = rec.of("economy.day_settled")[0]
	assert_eq([settled["admissions"], settled["audience"]], [sales["admissions"], sales["audience"]], "정산이 보고값을 쓴다")
	assert_eq(sales["admissions"], adm["admissions"])


func test_au8_reference_satisfaction() -> void:
	for sid: String in _cfg.scenario_ids():
		var sc: Dictionary = _sc(sid)
		var x: Dictionary = sc["expected"]
		var l: Dictionary = _h.scenario_loop(sc)
		(l["loop"] as TickLoop).advance(_h.scfg.day_ticks)
		var rec: EventRecorder = l["rec"]
		assert_eq(rec.count("audience.day_summary"), 1, "%s: 요약 1회" % sid)
		var sm: Dictionary = rec.of("audience.day_summary")[0]
		assert_eq(sm.keys(), ["day", "has_lineup", "admissions", "audience", "left_early", "bar_buyers", "avg_satisfaction_bp", "crowd_bp", "avg_components", "by_type"], "%s: 요약 키" % sid)
		var rg: Array = x["avg_satisfaction_bp_range"]
		assert_between(int(sm["avg_satisfaction_bp"]), int(rg[0]), int(rg[1]), "%s: 평균 만족 %d 가 %s 안" % [sid, sm["avg_satisfaction_bp"], rg])
		for k: String in ["admissions", "audience", "left_early", "crowd_bp"]:
			assert_eq(sm[k], x[k], "%s: %s" % [sid, k])
		assert_eq(sm["has_lineup"], sc["lineup"] != null)
		for t: String in _cfg.type_ids():
			assert_eq(sm["by_type"][t]["admissions"], x["by_type"][t], "%s: by_type %s" % [sid, t])
		assert_eq(rec.of("economy.sales_reported"), [{"admissions": x["admissions"], "audience": x["audience"]}], "%s: 매출 보고" % sid)
		assert_eq(rec.count("audience.agent_left"), 0, "%s: 조기 퇴장 0 (AT6)" % sid)
		gut.p("%s: 평균 만족 %d (손계산 %d), 바 방문 %d, 대기 bp 평균 %d" % [sid, sm["avg_satisfaction_bp"], x["avg_satisfaction_bp_hand"], sm["bar_buyers"], sm["avg_components"]["wait_bp"]])


# --- AU9 결정성 ------------------------------------------------------------------------

func _det_run(sid: String) -> Dictionary:
	var l: Dictionary = _h.scenario_loop(_sc(sid), -1, ["tick.advanced"])
	var loop: TickLoop = l["loop"]
	var initial: Dictionary = loop.rng.get_state()
	var changes: Array = []
	var last: Array = [initial["audience"]]
	var wloop: WeakRef = weakref(loop)   # 버스 ↔ 람다 순환 참조를 만들지 않는다
	loop.bus.subscribe("tick.advanced", func(p: Dictionary) -> void:
		var s: String = (wloop.get_ref() as TickLoop).rng.get_state()["audience"]
		if s != last[0]:
			changes.append([int(p["tick"]), s])
			last[0] = s)
	loop.advance(_h.scfg.day_ticks)
	var evs: Array = []
	for e: Array in (l["rec"] as EventRecorder).events:
		if e[0] != "tick.advanced":
			evs.append(e)
	return {"events": AudienceHarness.hash_of(evs), "snap": AudienceHarness.hash_of(loop.snapshot()), "initial": initial,
		"final": loop.rng.get_state(), "changes": changes, "n": evs.size(),
		"adm": (l["rec"] as EventRecorder).of("audience.admissions_decided")[0]["admissions"]}


func test_au9_determinism() -> void:
	var a: Dictionary = _det_run("rookie_baseline")
	var b: Dictionary = _det_run("rookie_baseline")
	assert_gt(int(a["n"]), _h.scfg.phase_ticks("show"), "이벤트가 충분히 많다")
	assert_eq(a["events"], b["events"], "audience.*·sales_reported 이벤트 열 해시 동일")
	assert_eq(a["snap"], b["snap"], "TickLoop 스냅샷 해시 동일")
	for s: String in _h.scfg.rng_streams:
		if s != "audience":
			assert_eq(a["final"][s], a["initial"][s], "%s 스트림 불변" % s)
	var sc: Dictionary = _sc("rookie_baseline")
	assert_eq(a["changes"].size(), 1, "audience 스트림은 한 틱에서만 바뀐다")
	assert_eq(a["changes"][0][0], _h.scfg.phase_start("evening"), "저녁 진입 틱(단계 4)")
	assert_eq(a["changes"][0][1], _state_after(sc["seed"], "audience", maxi(1, int(a["adm"]))), "뽑기 수 == max(1, admissions)")


# --- AU10 스냅샷 -----------------------------------------------------------------------

## 단위 시스템 u 를 (ph, tip) 부터 공연 끝까지 진행한다. on_tick(ph, tip) 를 매 틱 뒤에 부른다.
func _finish(u: Dictionary, ph: String, tip: int, on_tick: Callable = Callable()) -> void:
	var aud: AudienceSystem = u["aud"]
	if ph == "evening":
		for t: int in range(tip, _h.scfg.phase_ticks("evening")):
			aud.update(_h.ctx(1, "evening", t))
			if on_tick.is_valid():
				on_tick.call("evening", t)
		AudienceHarness.phase(u["bus"], "evening", "show")
		tip = 0
	for t: int in range(tip, _h.scfg.phase_ticks("show")):
		aud.update(_h.ctx(1, "show", t))
		if on_tick.is_valid():
			on_tick.call("show", t)
	AudienceHarness.phase(u["bus"], "show", "close")


## A(연속) 와 B(스냅샷 → JSON 왕복 → 새 시스템 restore, 커버리지 이벤트 없음) 를 끝까지 돌려 틱마다 에이전트·이벤트 비교.
## 반환 {a_rec_tail, b_rec, b_log: [[ph, tip, before, after]], blocked}
## stride > 1 이면 에이전트 레코드(target·path) 비교를 stride 틱마다 한 번만 한다(SE-052 C: 시간 절감).
## 이벤트 열 해시 비교는 항상 모든 틱을 덮는다(agent_moved 가 틱마다 모든 에이전트 위치를 싣는다). b_log 는 stride 1 일 때만 틱마다 쌓인다.
func _restore_compare(sc: Dictionary, cov: Dictionary, ph: String, tip: int, stride: int = 1) -> Dictionary:
	var ua: Dictionary = _h.unit(sc["seed"])
	_h.decide(ua, sc, cov)
	if ph == "show":
		_h.run((ua["aud"] as AudienceSystem), "evening", 0, _h.scfg.phase_ticks("evening"))
		AudienceHarness.phase(ua["bus"], "evening", "show")
		_h.run((ua["aud"] as AudienceSystem), "show", 0, tip)
	else:
		_h.run((ua["aud"] as AudienceSystem), "evening", 0, tip)
	var snap: Dictionary = AudienceHarness.rt((ua["aud"] as AudienceSystem).snapshot())
	var mark: int = (ua["rec"] as EventRecorder).events.size()
	var ub: Dictionary = _h.unit(sc["seed"] + 1)
	var b_aud: AudienceSystem = ub["aud"]
	assert_true(b_aud.restore(snap), "restore true")
	assert_eq(AudienceHarness.hash_of(b_aud.snapshot()), AudienceHarness.hash_of((ua["aud"] as AudienceSystem).snapshot()), "복원 직후 스냅샷 동일(SH6)")
	var a_log: Array = []
	var b_log: Array = []
	var a_aud: AudienceSystem = ua["aud"]
	var a_prev: Array = [a_aud.agents()]
	var b_prev: Array = [b_aud.agents()]
	_finish(ua, ph, tip, func(p: String, t: int) -> void:
		if t % stride != 0:
			return
		var now: Array = a_aud.agents()
		a_log.append(AudienceHarness.hash_of(now))
		a_prev[0] = now)
	_finish(ub, ph, tip, func(p: String, t: int) -> void:
		if t % stride != 0:
			return
		var now: Array = b_aud.agents()
		b_log.append([p, t, b_prev[0], now])
		b_prev[0] = now)
	var tail: Array = (ua["rec"] as EventRecorder).events.slice(mark)
	assert_eq(AudienceHarness.hash_of((ub["rec"] as EventRecorder).events), AudienceHarness.hash_of(tail), "복원 후 이벤트 열 = 연속 진행")
	var same: int = 0
	for k: int in b_log.size():
		if AudienceHarness.hash_of(b_log[k][3]) == a_log[k]:
			same += 1
	assert_gt(a_log.size(), 0, "비교한 틱이 있다")
	assert_eq(b_log.size(), a_log.size(), "비교 틱 수 동일")
	assert_eq(same, a_log.size(), "%s 틱마다 에이전트 레코드(target·path 포함) 동일" % ("매" if stride == 1 else "%d " % stride))
	return {"b_log": b_log, "b_rec": ub["rec"]}


const AU10A_RECORD_STRIDE: int = 10


func test_au10a_snapshot_mid_evening_and_mid_show() -> void:
	var sc: Dictionary = _sc("rookie_baseline")
	var r1: Dictionary = _restore_compare(sc, _base, "evening", 250, AU10A_RECORD_STRIDE)
	var r2: Dictionary = _restore_compare(sc, _base, "show", _cfg.show_ticks / 2, AU10A_RECORD_STRIDE)
	assert_eq((r1["b_rec"] as EventRecorder).count("audience.day_summary"), 1)
	assert_eq((r2["b_rec"] as EventRecorder).of("audience.day_summary")[0]["admissions"], sc["expected"]["admissions"])
	# 저녁 중간 스냅샷에는 도착 대기·건너는 사람·at_bar 가 있다(전제)
	var ua: Dictionary = _h.unit(sc["seed"])
	_h.decide(ua, sc, _base)
	_h.run(ua["aud"], "evening", 0, 250)
	var states: Dictionary = {}
	for a: Dictionary in (ua["aud"] as AudienceSystem).agents():
		states[a["state"]] = true
		if a["next"] != null:
			states["crossing"] = true
	assert_gt((ua["aud"] as AudienceSystem).arrivals().size(), 0, "도착 대기 남음")
	assert_true(states.has("at_bar") and states.has("crossing"), "at_bar·건너는 사람 있음: %s" % [states.keys()])


## AU10(a) 복원 직후 경로 질의: 커버리지 이벤트 없이 복원한 시스템의 T11(바 → 관람 자리 SP4)·P1(출구 SP5) 경로가
## 연속 진행과 같고 blocked_cells 를 지나지 않는다. 관람 자리를 줄인 커버리지(기준 배치의 blocked_cells 그대로)로 둘 다 만든다.
func test_au10a_paths_after_restore_avoid_blocked_cells() -> void:
	var viewing: Array = []
	for z: int in [18, 19]:
		for x: int in range(8, 14):
			viewing.append([x, z])
	var bar: Array = [[19, 3], [19, 4], [19, 5], [19, 6], [19, 7], [18, 5]]
	var cov: Dictionary = AudienceHarness.small_coverage(viewing, viewing, viewing, bar, _base["blocked_cells"], 40)
	var blocked: Dictionary = _blocked_set(cov)
	for t: Array in viewing + bar:
		assert_false(blocked.has(Vector2i(t[0], t[1])), "전제: 자리 %s 는 막히지 않음" % [t])
	var r: Dictionary = _restore_compare(_sc("local_top_baseline"), cov, "evening", 100)
	var t11_spot: int = 0
	var p1_exit: int = 0
	for row: Array in r["b_log"]:
		var before: Dictionary = AudienceHarness.by_id(row[2])
		for a: Dictionary in row[3]:
			var prev: Dictionary = before.get(int(a["id"]), {})
			if prev.is_empty():
				continue
			var t11: bool = prev["state"] == "at_bar" and a["state"] in ["moving", "leaving"]
			var p1: bool = prev["state"] != "leaving" and a["state"] == "leaving"
			if not (t11 or p1):
				continue
			var from: Array = a["next"] if a["next"] != null else a["tile"]
			assert_true(_path_ok(from, a["path"], blocked), "에이전트 %d 경로가 이어지고 blocked_cells 를 지나지 않음" % a["id"])
			if not (a["path"] as Array).is_empty():
				assert_eq((a["path"] as Array).back(), a["target"], "경로 끝 = 목표")
			if t11 and a["state"] == "moving" and not (a["path"] as Array).is_empty():
				t11_spot += 1
			if p1 and not (a["path"] as Array).is_empty() and AudienceHarness.by_id(row[2]).has(int(a["id"])):
				p1_exit += 1
	assert_gt(t11_spot, 0, "복원 뒤 T11 바 → 관람 자리 경로 질의가 있었다")
	assert_gt(p1_exit, 0, "복원 뒤 P1 출구 경로 질의가 있었다")
	gut.p("복원 뒤 T11 관람 자리 %d 건, P1 출구 %d 건" % [t11_spot, p1_exit])


## AU10(b) TickLoop 수준 systems.audience 왕복(저녁 중간·공연 중간).
func test_au10b_tickloop_roundtrip() -> void:
	var sc: Dictionary = _sc("rookie_baseline")
	for at: int in [_h.scfg.phase_start("evening") + 250, _h.scfg.phase_start("show") + _cfg.show_ticks / 2]:
		var a: Dictionary = _h.scenario_loop(sc)
		var la: TickLoop = a["loop"]
		la.advance(at)
		var snap: Dictionary = AudienceHarness.rt(la.snapshot())
		assert_true(snap["systems"].has("audience"), "systems.audience 있음")
		var mark: int = (a["rec"] as EventRecorder).events.size()
		var b: Dictionary = _h.looped(sc["seed"] + 1, sc["lineup"], "")
		var lb: TickLoop = b["loop"]
		assert_true(lb.restore(snap), "TickLoop restore true (tick %d)" % at)
		assert_eq(AudienceHarness.hash_of((b["aud"] as AudienceSystem).snapshot()), AudienceHarness.hash_of((a["aud"] as AudienceSystem).snapshot()), "audience 상태 동일")
		la.advance(_h.scfg.day_ticks)
		lb.advance(_h.scfg.day_ticks)
		var tail: Array = (a["rec"] as EventRecorder).events.slice(mark)
		assert_eq(AudienceHarness.hash_of((b["rec"] as EventRecorder).events), AudienceHarness.hash_of(tail), "이벤트 열 동일(tick %d)" % at)
		assert_eq(AudienceHarness.hash_of(lb.snapshot()), AudienceHarness.hash_of(la.snapshot()), "close 상태 해시 동일(tick %d)" % at)


func _bad_snapshots(good: Dictionary) -> Array:
	var out: Array = []
	var s: Dictionary
	var ags: Array = good["agents"]
	var spot_i: Array = []
	var queued_i: int = -1
	for i: int in ags.size():
		if ags[i]["target_kind"] == "spot":
			spot_i.append(i)
		if ags[i]["state"] == "queued":
			queued_i = i
	s = good.duplicate(true); s["phase"] = "noon"; out.append(["RU1 phase noon", s])
	s = good.duplicate(true); s.erase("next_id"); out.append(["RU1 키 누락", s])
	s = good.duplicate(true); s["ticket_price"] = 0; out.append(["RU1 ticket_price 0", s])
	s = good.duplicate(true); s["coverage"].erase("blocked_cells"); out.append(["RU2 blocked_cells 없음", s])
	s = good.duplicate(true); s["coverage"]["blocked_cells"].append([99, 0]); out.append(["RU2 맵 밖 좌표", s])
	s = good.duplicate(true); s["lineup"]["genre"] = "jazz"; out.append(["RU3 genre jazz", s])
	s = good.duplicate(true); s["today"]["by_type"].erase("walk_in"); out.append(["RU4 by_type 키", s])
	s = good.duplicate(true); s["today"]["left_early"] = int(s["today"]["admissions"]) + 1; out.append(["RU4 left_early > admissions", s])
	s = good.duplicate(true); s["next_id"] = int(ags.back()["id"]); s["arrivals"] = []; out.append(["RU5 id ≥ next_id", s])
	s = good.duplicate(true); s["agents"][0]["type"] = "vip"; out.append(["RU6 모르는 유형", s])
	s = good.duplicate(true); s["agents"][0]["state"] = "dancing"; out.append(["RU6 state dancing", s])
	s = good.duplicate(true); s["agents"][0]["progress"] = 5; s["agents"][0]["next"] = s["agents"][0]["tile"]; out.append(["RU6 progress 5", s])
	s = good.duplicate(true); s["agents"][0]["sat"] = 10001; out.append(["RU6 sat 10001", s])
	s = good.duplicate(true)
	if queued_i >= 0:
		s["agents"][queued_i]["tile"] = _e0
	else:
		s["agents"][0]["state"] = "queued"
	out.append(["RU6 queued 인데 tile 있음", s])
	s = good.duplicate(true)
	s["agents"][spot_i[1]]["target"] = s["agents"][spot_i[0]]["target"]
	out.append(["RU7 같은 자리 예약 2명", s])
	return out


func test_au10c_restore_rejects() -> void:
	var sc: Dictionary = _sc("rookie_baseline")
	var u: Dictionary = _h.unit(0)
	var aud: AudienceSystem = u["aud"]
	var rec: EventRecorder = u["rec"]
	_h.decide(u, sc, _base)
	_h.run(aud, "evening", 0, 250)
	var good: Dictionary = AudienceHarness.rt(aud.snapshot())
	var before: String = AudienceHarness.hash_of(aud.snapshot())
	rec.clear()
	var cases: Array = _bad_snapshots(good)
	assert_gte(cases.size(), 8, "거부 사본 ≥ 8")
	var errs: int = 0
	for c: Array in cases:
		assert_false(aud.restore(c[1]), "%s: false" % c[0])
		errs += 1
		assert_push_error((c[0] as String).substr(0, 3), "%s: 검사 번호" % c[0])
		assert_push_error_count(errs, "%s: push_error 1회" % c[0])
		assert_eq(AudienceHarness.hash_of(aud.snapshot()), before, "%s: 상태 불변" % c[0])
	assert_eq(rec.events.size(), 0, "이벤트 0")
	assert_true(aud.restore(good), "원본은 통과")
	assert_eq(AudienceHarness.hash_of(aud.snapshot()), before, "SH6 왕복 해시 동일")
	# TickLoop 경로: push_error 2회(시스템 + TickLoop), 해시 불변
	var l: Dictionary = _h.scenario_loop(sc)
	var loop: TickLoop = l["loop"]
	loop.advance(_h.scfg.phase_start("evening") + 250)
	var lgood: Dictionary = AudienceHarness.rt(loop.snapshot())
	var lhash: String = AudienceHarness.hash_of(loop.snapshot())
	for c: Array in _bad_snapshots(lgood["systems"]["audience"]).slice(0, 3):
		var s: Dictionary = lgood.duplicate(true)
		s["systems"]["audience"] = c[1]
		assert_false(loop.restore(s), "TickLoop %s: false" % c[0])
		errs += 2
		assert_push_error_count(errs, "TickLoop %s: push_error 2회" % c[0])
		assert_eq(AudienceHarness.hash_of(loop.snapshot()), lhash, "TickLoop %s: 상태 불변" % c[0])


# --- 공연 끝·계약 위반 ---------------------------------------------------------------

func test_fn2_leftover_arrivals_and_close_leftovers() -> void:
	var u: Dictionary = _hand([[11, 10]])
	var aud: AudienceSystem = u["aud"]
	assert_true(_h.inject(aud, [AudienceHarness.agent(1, "regular", "watching", [11, 10], {"target": [11, 10], "target_kind": "spot"})], "show", [[2, "regular", 0, false]]))
	_tick(u, "show", _cfg.show_ticks - 1)
	assert_push_error("FN2", "도착하지 않은 에이전트는 push_error")
	assert_push_error_count(1)
	var rec: EventRecorder = u["rec"]
	var sm: Dictionary = rec.of("audience.day_summary")[0]
	assert_eq([sm["admissions"], sm["audience"]], [2, 2], "admissions 는 today 그대로")
	assert_eq([aud.agents(), aud.arrivals()], [[], []], "공연 끝에 모두 비움")
	# close 진입에 남은 에이전트(공연 끝 처리 누락) → 비운다
	var v: Dictionary = _hand([[11, 10]])
	assert_true(_h.inject(v["aud"], [AudienceHarness.agent(1, "regular", "watching", [11, 10])], "show"))
	AudienceHarness.phase(v["bus"], "show", "close")
	assert_eq((v["aud"] as AudienceSystem).agents(), [], "close 진입 시 비움")


# --- 리뷰 grep 기준 (SE-034 인계 확정 1~3) -----------------------------------------------

func _audience_sources() -> Dictionary:
	var out: Dictionary = {}
	var dir: DirAccess = DirAccess.open("res://sim")
	for f: String in dir.get_files():
		if f.begins_with("audience") and f.ends_with(".gd"):
			out["res://sim/" + f] = FileAccess.get_file_as_string("res://sim/" + f)
	return out


func test_source_boundaries() -> void:
	var src: Dictionary = _audience_sources()
	assert_eq(src.size(), 2, "audience_config.gd·audience_system.gd")
	var build_re: RegEx = RegEx.create_from_string("BuildSystem|build_system")
	var call_re: RegEx = RegEx.create_from_string("(?:(\\w+)\\.)?(find_path|path_from_entrance|set_occupied)\\(")
	var new_re: RegEx = RegEx.create_from_string("TilePath\\.new\\(")
	var stream_re: RegEx = RegEx.create_from_string("\\.stream\\(([^)]*)\\)(\\.\\w+\\()?")
	var bad_rand: RegEx = RegEx.create_from_string("randf|randi_range|randf_range|randfn|Time\\.|OS\\.get_ticks|extends\\s+Node|get_node\\(")
	var new_count: int = 0
	var draws: int = 0
	for path: String in src:
		var code: String = src[path]
		assert_eq(build_re.search_all(code).size(), 0, "%s: BuildSystem·build_system 참조 0" % path)
		assert_eq(bad_rand.search_all(code).size(), 0, "%s: randf·Time·Node 없음" % path)
		for m: RegExMatch in call_re.search_all(code):
			assert_eq(m.get_string(1), "_tile_path", "%s: %s 는 _tile_path 멤버로만" % [path, m.get_string(0)])
		new_count += new_re.search_all(code).size()
		for m: RegExMatch in stream_re.search_all(code):
			assert_eq([m.get_string(1), m.get_string(2)], ["STREAM", ".randi("], "%s: audience 스트림 .randi() 만" % path)
			draws += 1
	assert_eq(new_count, 3, "TilePath.new( 는 생성자·복원·커버리지 수신 세 곳")
	var sys_src: String = src["res://sim/audience_system.gd"]
	for fn: String in ["func _init(", "func restore(", "func _on_coverage_changed("]:
		var start: int = sys_src.find(fn)
		var end: int = sys_src.find("\nfunc ", start + 1)
		assert_true(start >= 0 and sys_src.substr(start, end - start).contains("TilePath.new("), "%s 안에 TilePath.new(" % fn)
	assert_eq(draws, 2, "뽑는 곳은 AD7·AD11 두 곳")
	assert_eq(AudienceSystem.STREAM, "audience")
