extends GutTest
## SE-035 — ShowSystem. docs/gdd/show.md#수용-기준 SH2~SH9 와 티켓 AC1·AC2·AC5, SE-030 QA 인계(SR3 정확히 임계값, 입장 0 명인 날)를 옮겼다.
## 기대 수치는 show.json(grades·reference_scenarios)·audience.json(reference_scenarios)에서 읽는다. 이벤트 이름·reason·등급 id 는
## 리터럴로 단언한다. 입력 이벤트는 테스트가 직접 발행한다(audience 실제 시스템 없음). SH8 은 TickLoop + ShowDayHarness.

const SHOW_EVENTS: Array[String] = ["show.started", "show.skipped", "show.ended"]
const AUDIENCE_PATH: String = "res://data/audience/audience.json"

var _cfg: ShowConfig
var _scfg: SimConfig
var _show_json: Dictionary
var _aud: Dictionary   # id -> audience 시나리오


func before_all() -> void:
	_cfg = ShowConfig.load()
	_scfg = SimConfig.load()
	_show_json = JsonUtil.read_json(ShowConfig.DEFAULT_PATH)
	for sc: Dictionary in JsonUtil.int_deep(JsonUtil.read_json(AUDIENCE_PATH))["reference_scenarios"]:
		_aud[sc["id"]] = sc


# --- 도우미 -------------------------------------------------------------------

## [bus, show, rec]. rng_loop 를 주면 그 루프의 버스를 쓴다(SH9 RNG 불변 확인).
func _unit(rng_loop: TickLoop = null) -> Array:
	var bus: EventBus = rng_loop.bus if rng_loop != null else EventBus.new()
	var rec: EventRecorder = EventRecorder.new(bus, SHOW_EVENTS)
	var show: ShowSystem = ShowSystem.new(_cfg, bus)
	return [bus, show, rec]


func _phase(bus: EventBus, from: String, to: String, day: int) -> void:
	bus.publish("time.phase_changed", {"from": from, "to": to, "day": day, "tick": 0})


## 저녁 진입 → build sync → 라인업 → (admissions ≥ 0 이면) 입장 결정. lineup = {artist_id, genre} 또는 null.
func _evening(bus: EventBus, day: int, lineup: Variant, has_stage: bool, admissions: int = -1) -> void:
	_phase(bus, "day", "evening", day)
	bus.publish("build.coverage_changed", {"cause": "sync", "has_stage": has_stage})
	var aid: Variant = lineup["artist_id"] if lineup != null else null
	var genre: Variant = lineup["genre"] if lineup != null else null
	bus.publish("artist.lineup_set", {"day": day, "artist_id": aid, "genre": genre, "grade": null, "popularity": 0, "skill": 0})
	if admissions >= 0:
		bus.publish("audience.admissions_decided", {"day": day, "admissions": admissions, "has_lineup": lineup != null})


func _sum(day: int, adm: int, aud: int, sat: int, has_lineup: bool = true) -> Dictionary:
	return {
		"day": day, "has_lineup": has_lineup, "admissions": adm, "audience": aud, "left_early": adm - aud, "bar_buyers": 0,
		"avg_satisfaction_bp": sat, "crowd_bp": 0,
		"avg_components": {"lineup_bp": 0, "sound_bp": 0, "sight_bp": 0, "value_bp": 0, "wait_bp": 0}, "by_type": {},
	}


## 하루 공연: 저녁 → 공연 진입 → 요약. 
func _play(bus: EventBus, day: int, lineup: Variant, has_stage: bool, adm: int, sat: int) -> void:
	_evening(bus, day, lineup, has_stage, adm)
	_phase(bus, "evening", "show", day)
	bus.publish("audience.day_summary", _sum(day, adm, adm, sat, lineup != null))


func _lineup(genre: String = "indie") -> Dictionary:
	return {"artist_id": "s07", "genre": genre}


func _hash(sys: Object) -> String:
	return JSON.stringify(sys.call("snapshot"), "", true)


func _rt(v: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(v))


# --- SH2 (AC1 등급 경계, SE-030 QA 인계 SR3 정확히 임계값) -----------------------

func test_grade_boundaries() -> void:
	var ids: Array[String] = _cfg.grade_ids()
	var n: int = 0
	for k: int in range(1, ids.size()):
		var m: int = _cfg.min_bp(ids[k])
		assert_eq(_cfg.grade_for(m - 1), ids[k - 1], "임계 − 1 (%d) → %s" % [m - 1, ids[k - 1]])
		assert_eq(_cfg.grade_for(m), ids[k], "정확히 임계 %d → %s (SR3 ≤)" % [m, ids[k]])
		n += 2
	assert_eq(_cfg.grade_for(0), "disaster")
	assert_eq(_cfg.grade_for(_cfg.rate_scale), "rave")
	n += 2
	assert_eq(n, 10, "경계 10건(5등급)")
	# 시스템 경로에서도 정확히 임계값이 그 등급이 된다.
	for k: int in range(1, ids.size()):
		var u: Array = _unit()
		_play(u[0], 1, _lineup(), true, 50, _cfg.min_bp(ids[k]))
		assert_eq((u[2] as EventRecorder).of("show.ended")[0]["grade"], ids[k], "show.ended 정확히 임계 → %s" % ids[k])


# --- SH3 (AC1 기준 시나리오) ----------------------------------------------------

func test_reference_scenarios() -> void:
	var n: int = 0
	for sc: Dictionary in _show_json["reference_scenarios"]:
		n += 1
		var a: Dictionary = _aud[sc["audience_scenario"]]
		var ax: Dictionary = a["expected"]
		var x: Dictionary = JsonUtil.int_deep(sc["expected"])
		var lineup: Variant = null if a["lineup"] == null else {"artist_id": a["lineup"]["slot"], "genre": a["lineup"]["genre"]}
		var results: Array = []
		var sats: Array = [ax["avg_satisfaction_bp_hand"]]
		sats.append_array(ax["avg_satisfaction_bp_range"])
		for sat: int in sats:
			var u: Array = _unit()
			var bus: EventBus = u[0]
			if int(a["ticket_price"]) != _cfg.ticket_price_default:
				bus.publish("economy.ticket_price_changed", {"price": a["ticket_price"], "from": _cfg.ticket_price_default})
			_evening(bus, 1, lineup, sc["has_stage"], ax["admissions"])
			_phase(bus, "evening", "show", 1)
			bus.publish("audience.day_summary", _sum(1, ax["admissions"], ax["audience"], sat, lineup != null))
			results.append(u[2])
		var rec: EventRecorder = results[0]
		var label: String = sc["id"]
		if x["event"] == "show.skipped":
			assert_eq(rec.names(), ["show.skipped"], label + ": show.skipped 만")
			assert_eq(rec.of("show.skipped")[0], {"day": 1, "reason": x["reason"]}, label)
			continue
		assert_eq(rec.names(), ["show.started", "show.ended"], label + ": started → ended")
		assert_eq(rec.of("show.started")[0], {
			"day": 1, "artist_id": lineup["artist_id"], "genre": lineup["genre"], "expected_admissions": x["expected_admissions"],
		}, label + ": show.started")
		var e: Dictionary = rec.of("show.ended")[0]
		for key: String in ["satisfaction_bp", "grade", "admissions", "audience", "revenue_hint"]:
			assert_eq(e[key], x[key], "%s: show.ended.%s" % [label, key])
		assert_eq(e["incidents"], [], label + ": incidents []")
		assert_eq(e["artist_id"], lineup["artist_id"])
		assert_true(e["artist_id"] is String, "artist_id 는 String")
		for r: int in [1, 2]:
			assert_eq((results[r] as EventRecorder).of("show.ended")[0]["grade"], x["grade_over_range"], "%s: 범위 끝 등급" % label)
	assert_eq(n, (_show_json["reference_scenarios"] as Array).size())
	assert_push_warning_count(0)
	assert_push_error_count(0)


# --- SH4 (AC1 라인업 없는 날) ----------------------------------------------------

func test_skipped_days() -> void:
	# 라인업 없음 → no_lineup, 요약이 와도 ended 0, 경고 없음(DS3).
	var u: Array = _unit()
	_play(u[0], 1, null, true, 12, 4600)
	assert_eq((u[2] as EventRecorder).names(), ["show.skipped"])
	assert_eq((u[2] as EventRecorder).of("show.skipped")[0], {"day": 1, "reason": "no_lineup"})
	assert_eq((u[1] as ShowSystem).status, "skipped")
	# 라인업 + 무대 없음 → no_stage.
	u = _unit()
	_play(u[0], 1, _lineup(), false, 0, 0)
	assert_eq((u[2] as EventRecorder).names(), ["show.skipped"])
	assert_eq((u[2] as EventRecorder).of("show.skipped")[0]["reason"], "no_stage")
	# 둘 다 없음 → no_lineup.
	u = _unit()
	_play(u[0], 1, null, false, 0, 0)
	assert_eq((u[2] as EventRecorder).of("show.skipped")[0]["reason"], "no_lineup")
	# artist 미등록(라인업 이벤트 없음) → no_lineup.
	u = _unit()
	_phase(u[0], "day", "evening", 1)
	(u[0] as EventBus).publish("build.coverage_changed", {"cause": "sync", "has_stage": true})
	_phase(u[0], "evening", "show", 1)
	assert_eq((u[2] as EventRecorder).names(), ["show.skipped"])
	assert_eq((u[2] as EventRecorder).of("show.skipped")[0]["reason"], "no_lineup")
	# 어제 받은 라인업은 오늘 공연이 아니다(lineup_day != day).
	u = _unit()
	_play(u[0], 1, _lineup(), true, 50, 6000)
	(u[0] as EventBus).publish("time.day_started", {"day": 2})
	(u[2] as EventRecorder).clear()
	_phase(u[0], "day", "evening", 2)
	_phase(u[0], "evening", "show", 2)
	assert_eq((u[2] as EventRecorder).of("show.skipped"), [{"day": 2, "reason": "no_lineup"}])
	assert_push_warning_count(0)


## SE-030 QA 인계 F7: 라인업·무대가 있는데 입장 0 명인 날은 스펙 그대로(DS5) 평균 0 → disaster.
func test_zero_admissions_day_is_disaster() -> void:
	var u: Array = _unit()
	_play(u[0], 1, _lineup(), true, 0, 0)
	var e: Array = (u[2] as EventRecorder).of("show.ended")
	assert_eq(e.size(), 1, "show.ended 1회")
	assert_eq(e[0]["grade"], "disaster", "입장 0 → disaster(스펙 그대로, 정책은 SE-042)")
	assert_eq(e[0]["admissions"], 0)
	assert_eq(e[0]["revenue_hint"], 0)


# --- SH5 (가드) ------------------------------------------------------------------

func test_ended_once_and_guards() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var show: ShowSystem = u[1]
	var rec: EventRecorder = u[2]
	# LN1: 낮에 온 라인업 → 경고·무시.
	var h0: String = _hash(show)
	bus.publish("artist.lineup_set", {"day": 1, "artist_id": "s07", "genre": "indie", "grade": "local", "popularity": 1, "skill": 1})
	assert_push_warning_count(1, "LN1 경고")
	assert_eq(_hash(show), h0, "LN1 상태 불변")
	# LN2: 형식 오류 → push_error·무시.
	_phase(bus, "day", "evening", 1)
	var h1: String = _hash(show)
	bus.publish("artist.lineup_set", {"day": 1, "artist_id": 7, "genre": "indie"})
	bus.publish("artist.lineup_set", {"day": 1, "artist_id": "s07", "genre": null})
	assert_push_error_count(2, "LN2 push_error 2회")
	assert_eq(_hash(show), h1, "LN2 상태 불변")
	bus.publish("build.coverage_changed", {"cause": "sync", "has_stage": true})
	bus.publish("artist.lineup_set", {"day": 1, "artist_id": "s07", "genre": "indie"})
	bus.publish("audience.admissions_decided", {"day": 1, "admissions": 50})
	_phase(bus, "evening", "show", 1)
	assert_eq(rec.names(), ["show.started"])
	# ST0: 같은 날 두 번째 to:"show" → 경고.
	var h2: String = _hash(show)
	_phase(bus, "show", "show", 1)
	assert_push_warning_count(2, "ST0 경고")
	assert_eq(rec.names(), ["show.started"], "ST0 이벤트 없음")
	assert_eq(_hash(show), h2, "ST0 상태 불변")
	# DS1: 범위 밖 만족·audience > admissions·키 누락 → push_error, 이벤트 0, 상태 불변.
	bus.publish("audience.day_summary", _sum(1, 50, 50, _cfg.rate_scale + 1))
	bus.publish("audience.day_summary", _sum(1, 50, 51, 6000))
	var missing: Dictionary = _sum(1, 50, 50, 6000)
	missing.erase("avg_satisfaction_bp")
	bus.publish("audience.day_summary", missing)
	assert_push_error_count(5, "DS1 push_error 3회")
	assert_eq(rec.names(), ["show.started"], "DS1 이벤트 0")
	assert_eq(_hash(show), h2, "DS1 상태 불변")
	# DS2: 다른 날 → 경고·무시.
	bus.publish("audience.day_summary", _sum(2, 50, 50, 6000))
	assert_push_warning_count(3, "DS2 경고")
	assert_eq(_hash(show), h2, "DS2 상태 불변")
	# DS5 → ended 1회.
	bus.publish("audience.day_summary", _sum(1, 50, 50, 6000))
	assert_eq(rec.count("show.ended"), 1)
	assert_eq(show.status, "ended")
	# DS4: 같은 날 두 번째 요약 → 경고, ended 추가 0.
	var h3: String = _hash(show)
	bus.publish("audience.day_summary", _sum(1, 50, 50, 6000))
	assert_push_warning_count(4, "DS4 경고")
	assert_eq(rec.count("show.ended"), 1, "show.ended 하루 1회")
	assert_eq(_hash(show), h3)
	# close 진입은 ended 상태라 경고 없음.
	_phase(bus, "show", "close", 1)
	assert_push_warning_count(4, "정상 close 경고 없음")
	# CL1: 요약 없이 close → 경고, ended 0, status ended.
	u = _unit()
	_evening(u[0], 1, _lineup(), true, 10)
	_phase(u[0], "evening", "show", 1)
	_phase(u[0], "show", "close", 1)
	assert_push_warning_count(5, "CL1 경고")
	assert_eq((u[2] as EventRecorder).count("show.ended"), 0, "CL1 show.ended 0")
	assert_eq((u[1] as ShowSystem).status, "ended")
	# 요약 has_lineup false 인데 running → 경고 1회 후 그대로 진행.
	u = _unit()
	_evening(u[0], 1, _lineup(), true, 10)
	_phase(u[0], "evening", "show", 1)
	(u[0] as EventBus).publish("audience.day_summary", _sum(1, 10, 10, 6000, false))
	assert_push_warning_count(6, "has_lineup 불일치 경고")
	assert_eq((u[2] as EventRecorder).count("show.ended"), 1, "show 의 라인업 기준으로 진행")
	# 그 밖의 무효 입력: 다른 날 입장 결정·has_stage 비 bool → 경고·무시.
	var h4: String = _hash(u[1])
	(u[0] as EventBus).publish("audience.admissions_decided", {"day": 9, "admissions": 3})
	(u[0] as EventBus).publish("build.coverage_changed", {"has_stage": 1})
	assert_push_warning_count(8)
	assert_eq(_hash(u[1]), h4)


# --- SH6 ------------------------------------------------------------------------

func test_revenue_hint_follows_price() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var price: int = _cfg.ticket_price_default + _cfg.ticket_price_default / 2
	bus.publish("economy.ticket_price_changed", {"price": price, "from": _cfg.ticket_price_default})
	assert_eq((u[1] as ShowSystem).ticket_price, price)
	var h: String = _hash(u[1])
	bus.publish("economy.ticket_price_changed", {"price": 0, "from": price})
	bus.publish("economy.ticket_price_changed", {"price": "x", "from": price})
	assert_push_warning_count(2, "잘못된 가격 경고 2회")
	assert_eq(_hash(u[1]), h, "잘못된 가격 무시")
	_play(bus, 1, _lineup(), true, 53, 5730)
	assert_eq((u[2] as EventRecorder).of("show.ended")[0]["revenue_hint"], 53 * price, "revenue_hint = admissions × price")


# --- SH7 ------------------------------------------------------------------------

func test_compute_result_pure() -> void:
	for sc: Dictionary in _show_json["reference_scenarios"]:
		var x: Dictionary = JsonUtil.int_deep(sc["expected"])
		if x["event"] != "show.ended":
			continue
		var a: Dictionary = _aud[sc["audience_scenario"]]
		var s: Dictionary = _sum(1, a["expected"]["admissions"], a["expected"]["audience"], a["expected"]["avg_satisfaction_bp_hand"])
		var before: String = JSON.stringify(s)
		var r: Dictionary = ShowSystem.compute_result(_cfg, s, a["ticket_price"])
		assert_eq(JSON.stringify(s), before, "입력 불변")
		assert_eq(r, {
			"satisfaction_bp": x["satisfaction_bp"], "grade": x["grade"], "admissions": x["admissions"], "audience": x["audience"],
			"revenue_hint": x["revenue_hint"], "incidents": [],
		}, sc["id"] + ": compute_result == show.ended(날짜·artist_id 제외)")
	var bad: Dictionary = _sum(1, 10, 11, 5000)
	assert_eq(ShowSystem.compute_result(_cfg, bad, 20), {}, "audience > admissions → {}")
	assert_eq(ShowSystem.compute_result(_cfg, _sum(1, 10, 10, -1), 20), {}, "만족 음수 → {}")
	assert_eq(ShowSystem.compute_result(_cfg, {"day": 1}, 20), {}, "키 누락 → {}")
	assert_eq(ShowSystem.compute_result(_cfg, _sum(1, 10, 10, 5000), 0), {}, "가격 0 → {}")
	assert_push_error_count(0, "순수 함수는 오류를 내지 않는다")


# --- SH8 (AC2 이벤트 순서, TickLoop) -----------------------------------------------

func test_event_order_tickloop() -> void:
	var names: Array[String] = [
		"time.phase_changed", "tick.advanced", "artist.lineup_set", "audience.day_summary", "economy.sales_reported",
		"economy.day_settled", "artist.grown", "reputation.changed",
	]
	names.append_array(SHOW_EVENTS)
	var sc: Dictionary = _aud["local_top_baseline"]
	var h: ShowDayHarness = ShowDayHarness.new(_scfg, ArtistConfig.load(), EconomyConfig.load(), _cfg, ReputationConfig.load(),
		names, sc["expected"]["admissions"], sc["expected"]["avg_satisfaction_bp_hand"])
	var acfg: ArtistConfig = h.artist.config
	var local_id: String = ""
	for id: String in acfg.artist_ids():
		if acfg.artist(id)["grade"] == "local" and local_id == "":
			local_id = id
	assert_eq(h.play_day(local_id), h.day_ticks(), "하루 틱 전부 처리")
	var ev: Array = h.rec.events
	var seq: Array = []
	var ticks_before: Dictionary = {}
	var ticks: int = 0
	for e: Array in ev:
		if e[0] == "tick.advanced":
			ticks += 1
			continue
		if e[0] == "time.phase_changed":
			seq.append("phase:" + String(e[1]["to"]))
		else:
			seq.append(e[0])
		if not ticks_before.has(e[0]):
			ticks_before[e[0]] = ticks
	var i_show: int = seq.find("phase:show")
	assert_eq(seq[i_show + 1], "show.started", "show.started 는 to:show 바로 뒤")
	assert_eq(seq.count("show.started"), 1)
	assert_eq(seq.count("show.ended"), 1, "show.ended 정확히 1회")
	assert_eq(seq.count("show.skipped"), 0)
	var to_show_ticks: int = _scfg.phase_ticks("day") + _scfg.phase_ticks("evening") - 1
	assert_eq(ticks_before["show.started"], to_show_ticks, "show.started 는 공연 첫 틱 경계(단계 4)")
	assert_eq(ticks_before["show.ended"], h.day_ticks() - 1, "show.ended 는 공연 마지막 틱(단계 2)")
	var order: Array = ["audience.day_summary", "show.ended", "artist.grown", "reputation.changed", "economy.sales_reported",
		"phase:close", "economy.day_settled"]
	var last: int = -1
	for nm: String in order:
		var i: int = seq.find(nm)
		assert_gt(i, last, "%s 순서" % nm)
		last = i
	assert_eq(h.rec.of("show.started")[0]["expected_admissions"], sc["expected"]["admissions"])
	assert_eq(h.rec.of("show.ended")[0]["grade"], _cfg.grade_for(sc["expected"]["avg_satisfaction_bp_hand"]))
	assert_eq(h.rec.of("show.ended")[0]["artist_id"], local_id)


# --- SH9 (AC5 결정성·스냅샷) -----------------------------------------------------

func _script_day(bus: EventBus) -> void:
	_evening(bus, 1, _lineup("rock"), true, 70)
	_phase(bus, "evening", "show", 1)
	bus.publish("audience.day_summary", _sum(1, 70, 65, 6100))
	_phase(bus, "show", "close", 1)
	bus.publish("time.day_started", {"day": 2})
	_play(bus, 2, null, true, 12, 4600)


func test_determinism_and_snapshot() -> void:
	# (a) 같은 입력 두 번 → 같은 이벤트 열·스냅샷, 전 RNG 스트림 불변.
	var runs: Array = []
	for k: int in 2:
		var loop: TickLoop = TickLoop.new(_scfg, 42)
		var rng0: String = JSON.stringify(loop.rng.get_state())
		var u: Array = _unit(loop)
		_script_day(u[0])
		assert_eq(JSON.stringify(loop.rng.get_state()), rng0, "RNG 스트림 불변")
		runs.append([(u[2] as EventRecorder).to_json(), _hash(u[1])])
	assert_eq(runs[0], runs[1], "결정적")
	# (b) 공연 중 스냅샷 → JSON 왕복 → 새 시스템 복원 → 요약 → 연속 진행과 같은 show.ended.
	var cont: Array = _unit()
	_evening(cont[0], 3, _lineup("electronic"), true, 90)
	_phase(cont[0], "evening", "show", 3)
	assert_eq((cont[1] as ShowSystem).status, "running")
	var snap: Variant = _rt((cont[1] as ShowSystem).snapshot())
	var fresh: Array = _unit()
	assert_true((fresh[1] as ShowSystem).restore(snap), "복원 성공")
	assert_eq(_hash(fresh[1]), _hash(cont[1]), "복원 = 원본")
	assert_eq((fresh[2] as EventRecorder).events.size(), 0, "복원 뒤 이벤트 없음")
	(cont[2] as EventRecorder).clear()
	for u: Array in [cont, fresh]:
		(u[0] as EventBus).publish("audience.day_summary", _sum(3, 90, 88, 7600))
	assert_eq((fresh[2] as EventRecorder).to_json(), (cont[2] as EventRecorder).to_json(), "복원 후 진행 = 연속 진행")
	assert_eq((fresh[2] as EventRecorder).count("show.ended"), 1)
	# (c) 거부 사본.
	var base: Dictionary = (cont[1] as ShowSystem).snapshot()
	var running: Dictionary = (fresh[1] as ShowSystem).snapshot()
	running["status"] = "running"
	var bad: Array = []
	var c: Dictionary
	c = base.duplicate(true); c["status"] = "playing"; bad.append(["status playing", "SS4", c])
	c = running.duplicate(true); c["lineup"] = null; bad.append(["running 인데 lineup null", "SS4", c])
	c = base.duplicate(true); c["lineup_day"] = int(c["day"]) + 1; bad.append(["lineup_day > day", "SS2", c])
	c = base.duplicate(true); c["lineup"]["genre"] = "jazz"; bad.append(["lineup.genre jazz", "SS3", c])
	c = base.duplicate(true); c.erase("has_stage"); bad.append(["has_stage 누락", "SS1", c])
	c = base.duplicate(true); c["day"] = 1.5; bad.append(["day 1.5", "SS1", c])
	c = base.duplicate(true); c["lineup"]["extra"] = 1; bad.append(["lineup 키 추가", "SS3", c])
	c = base.duplicate(true); c["phase"] = "night"; bad.append(["phase night", "SS2", c])
	var target: Array = _unit()
	var h0: String = _hash(target[1])
	var errs: int = 0
	for b: Array in bad:
		assert_false((target[1] as ShowSystem).restore(b[2]), "%s → false" % b[0])
		errs += 1
		assert_push_error(b[1], "%s: %s" % [b[0], b[1]])
		assert_push_error_count(errs, "%s: push_error 1회" % b[0])
		assert_eq(_hash(target[1]), h0, "%s: 상태 불변" % b[0])
	assert_eq((target[2] as EventRecorder).events.size(), 0, "거부 시 이벤트 0")
