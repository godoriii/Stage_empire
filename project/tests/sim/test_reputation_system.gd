extends GutTest
## SE-035 — ReputationSystem. docs/gdd/reputation.md#수용-기준 RP2~RP10 과 티켓 AC3·AC4·AC5, SE-030 QA 인계 경계 4종
## (FC1 장르 합 정확히 min_genre_sum, FC4 정확히 breadth_min_share_bp, RG5 이중 내림, TU3 total == unlock_reputation)을 옮겼다.
## 기대 수치는 reputation.json(reference_scenarios·base_by_grade)·tiers.json·artist.json·show.json 에서 읽는다(500·30,000 리터럴 없음).
## 입력(show.started, show.ended, economy.day_settled, time.day_started)은 테스트가 직접 발행한다. RP9(b)·RP10 은 TickLoop.

const REP_EVENTS: Array[String] = ["reputation.changed", "reputation.tier_unlocked"]
const RECORDED: Array[String] = [
	"show.started", "show.ended", "economy.day_settled", "reputation.changed", "reputation.tier_unlocked",
]

var _cfg: ReputationConfig
var _show: ShowConfig
var _acfg: ArtistConfig
var _scfg: SimConfig
var _t2: Dictionary   # tiers.json 다음 티어 임계


func before_all() -> void:
	_cfg = ReputationConfig.load()
	_show = ShowConfig.load()
	_acfg = ArtistConfig.load()
	_scfg = SimConfig.load()
	_t2 = _cfg.tier_threshold(ReputationConfig.START_TIER + 1)


# --- 도우미 -------------------------------------------------------------------

func _unit(bus: EventBus = null) -> Array:
	var b: EventBus = bus if bus != null else EventBus.new()
	var rec: EventRecorder = EventRecorder.new(b, RECORDED)
	var rep: ReputationSystem = ReputationSystem.new(_cfg, b)
	return [b, rep, rec]


func _hash(sys: Object) -> String:
	return JSON.stringify(sys.call("snapshot"), "", true)


func _rt(v: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(v))


func _started(bus: EventBus, day: int, genre: String) -> void:
	bus.publish("show.started", {"day": day, "artist_id": "s07", "genre": genre, "expected_admissions": 0})


func _ended(bus: EventBus, day: int, grade: Variant, adm: Variant) -> void:
	bus.publish("show.ended", {
		"day": day, "artist_id": "s07", "satisfaction_bp": 0, "grade": grade, "admissions": adm, "audience": adm,
		"revenue_hint": 0, "incidents": [],
	})


func _settled(bus: EventBus, day: int, cash: Variant) -> void:
	bus.publish("economy.day_settled", {"day": day, "cash": cash})


## 기준 시나리오를 버스로 돈다(reputation.md #기준-시나리오 순서). 반환 {u, total[], computed[], focus[], factor[],
## grade[], delta[], unlock_days[], settled_index[]}. 날 d 의 공연 = show_cycle[(d − 1) mod len], 현금 = start + per_day × d.
func _run(sc: Dictionary, u: Array = []) -> Dictionary:
	if u.is_empty():
		u = _unit()
	var bus: EventBus = u[0]
	var rep: ReputationSystem = u[1]
	var rec: EventRecorder = u[2]
	var out: Dictionary = {"u": u, "total": [], "computed": [], "focus": [], "factor": [], "grade": [], "delta": [], "unlock_days": []}
	var cyc: Array = sc["show_cycle"]
	for d: int in range(1, int(sc["days"]) + 1):
		if d > 1:
			bus.publish("time.day_started", {"day": d})
		var s: Variant = cyc[(d - 1) % cyc.size()]
		var n_changed: int = rec.count("reputation.changed")
		if s == null:
			for k: String in ["computed", "focus", "factor", "grade", "delta"]:
				out[k].append(null)
		else:
			var grade: String = _show.grade_for(s["satisfaction_bp"])
			var cd: Dictionary = ReputationSystem.compute_delta(_cfg, rep.by_genre(), s["genre"], grade, s["admissions"])
			_started(bus, d, s["genre"])
			_ended(bus, d, grade, s["admissions"])
			assert_eq(rec.count("reputation.changed"), n_changed + 1, "%s %d일: reputation.changed 1회" % [sc["id"], d])
			out["computed"].append(cd["delta"])
			out["focus"].append(cd["focus"])
			out["factor"].append(cd["factor_bp"])
			out["grade"].append(grade)
			out["delta"].append(rec.of("reputation.changed")[-1]["delta"])
		var n_unlock: int = rec.count("reputation.tier_unlocked")
		_settled(bus, d, int(sc["cash"]["start"]) + int(sc["cash"]["per_day"]) * d)
		if rec.count("reputation.tier_unlocked") > n_unlock:
			out["unlock_days"].append(d)
			assert_eq(rec.names()[-1], "reputation.tier_unlocked", "해금은 정산 바로 뒤")
			assert_eq(rec.names()[-2], "economy.day_settled")
		out["total"].append(rep.total)
	return out


func _first_reach(totals: Array, threshold: int) -> Variant:
	for i: int in totals.size():
		if totals[i] >= threshold:
			return i + 1
	return null


# --- RP2 (AC3 등급별 Δ) ----------------------------------------------------------

func test_delta_by_grade() -> void:
	var ref: int = _cfg.admissions_ref
	var rs: int = _cfg.rate_scale
	for grade: String in _cfg.show_grades:
		var b: int = _cfg.base(grade)
		var r: Dictionary = ReputationSystem.compute_delta(_cfg, {}, "indie", grade, ref)
		assert_eq(r["delta"], b, "%s: 빈 벡터·기준 입장 → base" % grade)
		assert_eq(r["focus"], "none")
		assert_eq(r["eff_bp"], ReputationSystem.EFF_NOT_JUDGED)
		var z: Dictionary = ReputationSystem.compute_delta(_cfg, {}, "indie", grade, 0)
		if b < 0:
			assert_eq(z["delta"], -((-b) * _cfg.factor_min_bp / rs), "%s: 입장 0 → −⌊|b| × min_bp⌋" % grade)
			assert_lt(z["delta"], 0, "%s: 실패 Δ < 0" % grade)
		else:
			assert_eq(z["delta"], b * _cfg.factor_min_bp / rs, "%s: 입장 0 → ⌊b × min_bp⌋" % grade)
		assert_eq(ReputationSystem.compute_delta(_cfg, {}, "indie", grade, 2 * ref), r, "%s: 2 × ref = ref (상한)" % grade)
	assert_eq(ReputationSystem.compute_delta(_cfg, {}, "jazz", "good", ref), {}, "모르는 장르 → {}")
	assert_eq(ReputationSystem.compute_delta(_cfg, {}, "indie", "legend", ref), {}, "모르는 등급 → {}")
	assert_eq(ReputationSystem.compute_delta(_cfg, {}, "indie", "good", -1), {}, "음수 입장 → {}")
	var bg: Dictionary = {"indie": _cfg.min_genre_sum}
	var before: String = JSON.stringify(bg)
	ReputationSystem.compute_delta(_cfg, bg, "indie", "good", ref)
	assert_eq(JSON.stringify(bg), before, "입력 불변")


## SE-030 QA 인계 RG5: 이중 내림 ⌊⌊b × f⌋ × (1 + bonus)⌋. ok 등급 + 정체성 보정 + 기준 시나리오 입장.
func test_double_floor() -> void:
	var adm: int = _cfg.scenario("local_daily_good_30")["show_cycle"][0]["admissions"]
	var rs: int = _cfg.rate_scale
	var b: int = _cfg.base("ok")
	var f: int = _cfg.admission_factor_bp(adm)
	var bonus: int = _cfg.identity_bonus_bp
	var single: int = b * f * (rs + bonus) / (rs * rs)
	var double: int = (b * f / rs) * (rs + bonus) / rs
	assert_ne(single, double, "전제: 이 입력에서 한 번 내림과 두 번 내림이 다르다")
	var r: Dictionary = ReputationSystem.compute_delta(_cfg, {"indie": _cfg.min_genre_sum}, "indie", "ok", adm)
	assert_eq(r["focus"], "identity")
	assert_eq(r["delta"], double, "RG5 이중 내림")
	# 실패 등급은 보정 없이 크기를 먼저 내림하고 부호를 붙인다.
	var rd: Dictionary = ReputationSystem.compute_delta(_cfg, {"indie": _cfg.min_genre_sum}, "indie", "disaster", adm)
	assert_eq(rd["delta"], -((-_cfg.base("disaster")) * f / rs))
	assert_eq(rd["bonus_bp"], 0)
	assert_eq(rd["focus"], "none")


# --- RP3 (AC3 실패·하한) ---------------------------------------------------------

func test_failure_and_floor() -> void:
	var sc: Dictionary = _cfg.scenario("failure_floor_6")
	var x: Dictionary = sc["expected"]
	var out: Dictionary = _run(sc)
	var rec: EventRecorder = out["u"][2]
	var rep: ReputationSystem = out["u"][1]
	assert_eq(out["computed"], x["computed_delta"], "계산 Δ")
	assert_eq(out["delta"], x["delta"], "적용 Δ(하한 뒤)")
	assert_eq(out["total"], x["total"], "total")
	assert_eq(out["grade"], x["grade"])
	assert_eq(out["factor"], x["factor_bp"])
	assert_eq(rep.by_genre(), x["by_genre_final"])
	assert_eq(rec.count("reputation.changed"), (sc["show_cycle"] as Array).filter(func(s: Variant) -> bool: return s != null).size(),
		"공연 없는 날 reputation.* 0건")
	for i: int in (sc["show_cycle"] as Array).size():
		var s: Variant = sc["show_cycle"][i]
		if s != null and _cfg.base(out["grade"][i]) < 0:
			assert_lt(out["computed"][i], 0, "%d일 실패 Δ < 0" % (i + 1))
	for e: Dictionary in rec.of("reputation.changed"):
		assert_gte(e["total"], 0)
		for g: String in _cfg.genre_ids():
			assert_gte(e["by_genre"][g], 0)
		assert_eq((e["by_genre"] as Dictionary).keys(), Array(_cfg.genre_ids()), "by_genre 키 = mvp_genres 순서")


# --- RP4 (장르 집중·확산) ---------------------------------------------------------

func test_focus_identity_breadth() -> void:
	for id: String in ["local_daily_good_30", "rotation_good_30"]:
		var sc: Dictionary = _cfg.scenario(id)
		var out: Dictionary = _run(sc)
		assert_eq(out["focus"], sc["expected"]["focus"], id + ": 날별 focus")
		assert_eq(out["computed"], sc["expected"]["computed_delta"], id + ": 날별 계산 Δ")
		assert_eq((out["u"][1] as ReputationSystem).by_genre(), sc["expected"]["by_genre_final"], id + ": 장르 벡터")
	# reputation.md #장르-집중과-확산 예 표 7행(rock / indie / electronic → 장르별 eff_bp·focus).
	var table: Array = [
		[[0, 100, 0], [5000, "none"], [10000, "identity"], [4000, "none"]],
		[[50, 50, 0], [7500, "identity"], [7500, "identity"], [3000, "none"]],
		[[0, 50, 50], [3500, "none"], [7000, "identity"], [7000, "identity"]],
		[[50, 0, 50], [6000, "none"], [4500, "none"], [6000, "none"]],
		[[33, 33, 33], [5666, "breadth"], [6333, "breadth"], [5333, "breadth"]],
		[[20, 60, 20], [5400, "breadth"], [7800, "identity"], [4800, "breadth"]],
		[[10, 90, 0], [5500, "none"], [9500, "identity"], [3800, "none"]],
	]
	var g: Array[String] = _cfg.genre_ids()
	for row: Array in table:
		var bg: Dictionary = {}
		for i: int in g.size():
			bg[g[i]] = row[0][i]
		for i: int in g.size():
			var r: Dictionary = ReputationSystem.compute_delta(_cfg, bg, g[i], "good", _cfg.admissions_ref)
			assert_eq([r["eff_bp"], r["focus"]], row[i + 1], "%s 에서 %s 공연" % [row[0], g[i]])


## SE-030 QA 인계 FC1: 장르 합이 정확히 min_genre_sum 이면 판정, 하나 모자라면 none.
func test_focus_min_sum_boundary() -> void:
	var at: Dictionary = ReputationSystem.compute_delta(_cfg, {"indie": _cfg.min_genre_sum}, "indie", "good", _cfg.admissions_ref)
	assert_eq(at["focus"], "identity", "S == min_genre_sum → 판정")
	assert_eq(at["eff_bp"], _cfg.rate_scale)
	assert_eq(at["bonus_bp"], _cfg.identity_bonus_bp)
	var below: Dictionary = ReputationSystem.compute_delta(_cfg, {"indie": _cfg.min_genre_sum - 1}, "indie", "good", _cfg.admissions_ref)
	assert_eq(below["focus"], "none", "S == min_genre_sum − 1 → none")
	assert_eq(below["eff_bp"], ReputationSystem.EFF_NOT_JUDGED)
	assert_eq(below["delta"], _cfg.base("good"))


## SE-030 QA 인계 FC4: 가장 적은 장르 점유율이 정확히 breadth_min_share_bp 이면 breadth, 1 모자라면 none.
func test_breadth_share_boundary() -> void:
	var g: Array[String] = _cfg.genre_ids()
	var s: int = _cfg.rate_scale   # S = rate_scale 이면 점유율 bp == 그 장르 값
	var small: int = _cfg.breadth_min_share_bp
	var bg: Dictionary = {}
	var rest: int = s - small
	for i: int in g.size() - 1:
		bg[g[i]] = rest / (g.size() - 1)
	bg[g[0]] += rest - (rest / (g.size() - 1)) * (g.size() - 1)
	bg[g[-1]] = small
	var r: Dictionary = ReputationSystem.compute_delta(_cfg, bg, g[0], "good", _cfg.admissions_ref)
	assert_lt(r["eff_bp"], _cfg.identity_share_bp, "전제: %s 공연은 정체성 아님" % g[0])
	assert_eq(r["focus"], "breadth", "정확히 %d bp → breadth" % small)
	assert_eq(r["bonus_bp"], _cfg.breadth_bonus_bp)
	bg[g[-1]] = small - 1
	bg[g[1]] += 1
	var r2: Dictionary = ReputationSystem.compute_delta(_cfg, bg, g[0], "good", _cfg.admissions_ref)
	assert_lt(r2["eff_bp"], _cfg.identity_share_bp)
	assert_eq(r2["focus"], "none", "%d bp − 1 → none" % small)


# --- RP5 (AC3 30일) --------------------------------------------------------------

func test_reference_30_days() -> void:
	var sc: Dictionary = _cfg.scenario("local_daily_good_30")
	var x: Dictionary = sc["expected"]
	var out: Dictionary = _run(sc)
	assert_eq(out["total"], x["total"], "30일 total")
	assert_eq(out["delta"], x["delta"])
	var d500: Variant = _first_reach(out["total"], int(_t2["unlock_reputation"]))
	assert_eq(d500, x["day_reach_tier2_reputation"], "명성 tier2 임계 도달일 == 기대일")
	assert_eq(_first_reach(out["total"], _acfg.unlock_reputation("rookie")), x["day_reach_rookie_unlock"], "rookie 해금 명성 도달일")
	var rng: Array = _cfg.checks["tier2_reputation_day_range"]
	assert_between(int(d500), int(rng[0]), int(rng[1]), "RT1 범위")
	gut.p("local_daily_good_30: 명성 %d 도달 %s일" % [int(_t2["unlock_reputation"]), d500])


# --- RP6 (AC4 해금 1회) -----------------------------------------------------------

func test_tier_unlock_once() -> void:
	for id: String in ["local_daily_good_30", "reputation_first_40", "rotation_good_30", "failure_floor_6"]:
		var sc: Dictionary = _cfg.scenario(id)
		var out: Dictionary = _run(sc)
		assert_eq(out["unlock_days"], sc["expected"]["tier_unlocked_days"], id + ": 해금일")
		var rec: EventRecorder = out["u"][2]
		for e: Dictionary in rec.of("reputation.tier_unlocked"):
			assert_eq(e, {"tier": ReputationConfig.START_TIER + 1, "day": sc["expected"]["tier_unlocked_days"][0]})
	# reputation_first_40: 명성만 충족한 날(25~34일) 0건은 위 해금일 비교가 보장. 해금 뒤 스냅샷 왕복 → 다음 정산 0건.
	var sc40: Dictionary = _cfg.scenario("reputation_first_40")
	var o: Dictionary = _run(sc40)
	var rep: ReputationSystem = o["u"][1]
	assert_eq(rep.unlocked_tier, ReputationConfig.START_TIER + 1)
	var fresh: Array = _unit()
	assert_true((fresh[1] as ReputationSystem).restore(_rt(rep.snapshot())), "해금 뒤 복원")
	_settled(fresh[0], int(sc40["days"]) + 1, int(_t2["unlock_cash"]) * 2)
	assert_eq((fresh[2] as EventRecorder).count("reputation.tier_unlocked"), 0, "복원 뒤 재발행 없음")
	# 구제 전 cash 음수 → 0건.
	var neg: Array = _unit()
	var s: Dictionary = (neg[1] as ReputationSystem).snapshot()
	s["total"] = int(_t2["unlock_reputation"])
	assert_true((neg[1] as ReputationSystem).restore(s))
	_settled(neg[0], 1, -1)
	assert_eq((neg[2] as EventRecorder).count("reputation.tier_unlocked"), 0, "cash 음수 0건")


## SE-030 QA 인계 TU3: total == unlock_reputation 정확히 + cash == unlock_cash 정확히 → 해금. 하나라도 1 모자라면 0.
func test_tier_unlock_exact_threshold() -> void:
	var rep_t: int = int(_t2["unlock_reputation"])
	var cash_t: int = int(_t2["unlock_cash"])
	var cases: Array = [
		[rep_t, cash_t, 1, "둘 다 정확히 임계"],
		[rep_t - 1, cash_t * 2, 0, "명성 임계 − 1, 자금 충분(명성 미달)"],
		[rep_t * 2, cash_t - 1, 0, "자금 임계 − 1, 명성 충분(자금 미달)"],
	]
	for c: Array in cases:
		var u: Array = _unit()
		var s: Dictionary = (u[1] as ReputationSystem).snapshot()
		s["total"] = c[0]
		assert_true((u[1] as ReputationSystem).restore(s))
		_settled(u[0], 1, c[1])
		assert_eq((u[2] as EventRecorder).count("reputation.tier_unlocked"), c[2], c[3])
		_settled(u[0], 2, cash_t * 3)
		assert_eq((u[2] as EventRecorder).count("reputation.tier_unlocked"), 1 if c[2] == 1 else int(c[0] >= rep_t), c[3] + " → 다음 정산")


# --- RP7 (가드) ------------------------------------------------------------------

func test_guards() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var rep: ReputationSystem = u[1]
	var rec: EventRecorder = u[2]
	_started(bus, 1, "indie")
	var h: String = _hash(rep)
	_ended(bus, 1, 3, 50)                 # RG1 grade 비문자열
	_ended(bus, 1, "good", -1)            # RG1 음수 입장
	_ended(bus, 1, "열광", 50)            # RG1a
	assert_push_error_count(3, "RG1·RG1a push_error")
	assert_eq(_hash(rep), h)
	_ended(bus, 2, "good", 50)            # RG1b 다른 날
	assert_push_warning_count(1, "RG1b 경고")
	assert_eq(_hash(rep), h)
	_ended(bus, 1, "good", 50)
	assert_eq(rec.count("reputation.changed"), 1)
	var h2: String = _hash(rep)
	_ended(bus, 1, "good", 50)            # RG1c
	assert_eq(rec.count("reputation.changed"), 1, "RG1c 이벤트 0")
	assert_eq(_hash(rep), h2, "RG1c 불변")
	bus.publish("show.started", {"day": 1, "artist_id": "x", "genre": "jazz", "expected_admissions": 0})
	assert_push_error_count(4, "jazz push_error")
	assert_eq(_hash(rep), h2)
	_settled(bus, 1, "x")                 # TU1
	assert_push_error_count(5, "TU1 push_error")
	assert_eq(_hash(rep), h2)
	assert_push_warning_count(1)
	# show.started 없이 show.ended → RG1b 경고(새 시스템).
	var v: Array = _unit()
	_ended(v[0], 1, "good", 50)
	assert_push_warning_count(2)
	assert_eq((v[2] as EventRecorder).count("reputation.changed"), 0)


# --- RP8 ------------------------------------------------------------------------

func test_skipped_day_no_change() -> void:
	var u: Array = _unit()
	_started(u[0], 1, "rock")
	_ended(u[0], 1, "good", 50)
	var total: int = (u[1] as ReputationSystem).total
	(u[2] as EventRecorder).clear()
	(u[0] as EventBus).publish("time.day_started", {"day": 2})
	_settled(u[0], 2, 0)
	_ended(u[0], 2, "good", 50)           # started 없는 날 → RG1b
	assert_eq((u[2] as EventRecorder).count("reputation.changed"), 0, "공연 없는 날 reputation.changed 0")
	assert_eq((u[1] as ReputationSystem).total, total, "total 불변")
	assert_eq((u[1] as ReputationSystem).show_day, 0)
	assert_eq((u[1] as ReputationSystem).show_genre, null)


# --- RP9 (AC5 결정성·스냅샷) -----------------------------------------------------

func test_determinism_and_snapshot() -> void:
	# (a)
	var runs: Array = []
	for k: int in 2:
		var loop: TickLoop = TickLoop.new(_scfg, 7)
		var rng0: String = JSON.stringify(loop.rng.get_state())
		var out: Dictionary = _run(_cfg.scenario("failure_floor_6"), _unit(loop.bus))
		assert_eq(JSON.stringify(loop.rng.get_state()), rng0, "RNG 스트림 불변")
		runs.append([(out["u"][2] as EventRecorder).to_json(), _hash(out["u"][1])])
	assert_eq(runs[0], runs[1], "결정적")
	# (b) TickLoop 수준: 공연 중(show.started 뒤) systems.reputation 왕복 → show.ended 가 연속 진행과 같다.
	var mk: Callable = func() -> Array:
		var lp: TickLoop = TickLoop.new(_scfg, 7)
		var uu: Array = _unit(lp.bus)
		assert_true(lp.register_system("reputation", uu[1].update, uu[1].snapshot, uu[1].restore))
		return [lp] + uu
	var cont: Array = mk.call()
	_started(cont[1], 1, "rock")
	_ended(cont[1], 1, "good", 90)
	(cont[1] as EventBus).publish("time.day_started", {"day": 2})
	_started(cont[1], 2, "electronic")
	var snap: Variant = _rt((cont[0] as TickLoop).snapshot())
	assert_true((snap as Dictionary)["systems"].has("reputation"), "systems.reputation 존재")
	var fresh: Array = mk.call()
	assert_true((fresh[0] as TickLoop).restore(snap), "TickLoop 복원")
	assert_eq(_hash(fresh[2]), _hash(cont[2]), "복원 = 원본")
	assert_eq((fresh[3] as EventRecorder).events.size(), 0, "복원 뒤 이벤트 없음")
	(cont[3] as EventRecorder).clear()
	for u: Array in [cont, fresh]:
		_ended(u[1], 2, "rave", 120)
	assert_eq((fresh[3] as EventRecorder).to_json(), (cont[3] as EventRecorder).to_json(), "복원 후 진행 = 연속 진행")
	assert_eq((fresh[3] as EventRecorder).count("reputation.changed"), 1)
	# (c) 거부 사본.
	var base: Dictionary = (cont[2] as ReputationSystem).snapshot()
	var bad: Array = []
	var c: Dictionary
	c = base.duplicate(true); c["total"] = -1; bad.append(["total -1", "RR2", c])
	c = base.duplicate(true); c["by_genre"]["jazz"] = 0; bad.append(["by_genre jazz", "RR3", c])
	c = base.duplicate(true); c["by_genre"]["rock"] = -3; bad.append(["by_genre.rock -3", "RR3", c])
	c = base.duplicate(true); c["show_genre"] = "jazz"; bad.append(["show_genre jazz", "RR4", c])
	c = base.duplicate(true); c["show_day"] = 0; c["show_genre"] = "rock"; bad.append(["show_day 0 + show_genre", "RR4", c])
	c = base.duplicate(true); c["unlocked_tier"] = _cfg.max_tier + 1; bad.append(["unlocked_tier max+1", "RR5", c])
	c = base.duplicate(true); c.erase("last_applied_day"); bad.append(["키 누락", "RR1", c])
	c = base.duplicate(true); c["total"] = 1.5; bad.append(["total 1.5", "RR1", c])
	var target: Array = _unit()
	var h0: String = _hash(target[1])
	var errs: int = 0
	for b: Array in bad:
		assert_false((target[1] as ReputationSystem).restore(b[2]), "%s → false" % b[0])
		errs += 1
		assert_push_error(b[1], "%s: %s" % [b[0], b[1]])
		assert_push_error_count(errs, "%s: push_error 1회" % b[0])
		assert_eq(_hash(target[1]), h0, "%s: 상태 불변" % b[0])
	assert_eq((target[2] as EventRecorder).events.size(), 0, "거부 시 이벤트 0")
	# by_genre 키 순서를 바꾼 사본은 true, 복원 뒤 snapshot() 이 원래와 같다.
	var rev: Dictionary = base.duplicate(true)
	var keys: Array = (base["by_genre"] as Dictionary).keys()
	keys.reverse()
	var bg: Dictionary = {}
	for k: String in keys:
		bg[k] = base["by_genre"][k]
	rev["by_genre"] = bg
	assert_true((target[1] as ReputationSystem).restore(_rt(rev)), "키 순서 바꾼 사본 true")
	assert_eq(_hash(target[1]), JSON.stringify(base, "", true), "복원 뒤 mvp_genres 순서")


# --- RP10 (show·artist 와 함께 이벤트 순서, TickLoop) -------------------------------

func test_event_order_with_show() -> void:
	var names: Array[String] = ["audience.day_summary", "show.ended", "artist.grown", "reputation.changed",
		"economy.day_settled", "reputation.tier_unlocked"]
	var asc: Dictionary = {}
	for a: Dictionary in JsonUtil.int_deep(JsonUtil.read_json("res://data/audience/audience.json"))["reference_scenarios"]:
		if a["id"] == "local_top_baseline":
			asc = a
	var h: ShowDayHarness = ShowDayHarness.new(_scfg, _acfg, EconomyConfig.load(), _show, _cfg, names,
		asc["expected"]["admissions"], asc["expected"]["avg_satisfaction_bp_hand"])
	# 해금 날: 명성 임계 − 1(오늘 공연으로 넘음), 현금은 임계 + 넉넉히(정산 뒤에도 임계 이상).
	var s: Dictionary = h.rep.snapshot()
	s["total"] = int(_t2["unlock_reputation"]) - 1
	assert_true(h.rep.restore(s))
	var es: Dictionary = h.econ.snapshot()
	es["cash"] = int(_t2["unlock_cash"]) * 2
	assert_true(h.econ.restore(es))
	var local_id: String = ""
	for id: String in _acfg.artist_ids():
		if _acfg.artist(id)["grade"] == "local" and local_id == "":
			local_id = id
	h.play_day(local_id)
	assert_eq(h.rec.names(), names, "day_summary → show.ended → artist.grown → reputation.changed → day_settled → tier_unlocked")
	assert_eq(h.rec.of("reputation.tier_unlocked")[0], {"tier": ReputationConfig.START_TIER + 1, "day": 1})
