extends GutTest
## SE-012 D5 (qa) — 기준·파산 시나리오를 TickLoop + Economy 로 30 게임일 돌린다.
## 입력은 economy.md 입력 계약 이벤트(charge_proposed, sales_reported, upkeep_reported, bailout_accept_requested,
## time.next_day_requested)를 하네스가 발행한다. 기대값은 economy.json reference_scenarios 에서 읽고
## 핵심 수는 리터럴로 한 번 더 단언한다. 표는 "QA30|" 접두어로 stdout 에 찍는다(리포트용).

const DAYS: int = 30
const ECON_EVENTS: Array[String] = [
	"economy.cash_changed", "economy.charge_resolved", "economy.day_settled", "economy.bailout_offered",
	"economy.bailout_taken", "economy.bankrupt",
]

var _cfg: EconomyConfig
var _scfg: SimConfig


func before_all() -> void:
	_cfg = EconomyConfig.load()
	_scfg = SimConfig.load()


## 시나리오를 days 게임일 돌리고 일자별 행을 돌려준다.
## booking: 낮에 개런티를 시도하고 승인되면 공연(sales_reported)하는 `book_if_affordable`.
## accept: "manual" = 제안된 close 에서 바로 수락, "auto" = 수락 명령 없이 다음 날(time.day_started)에 자동 수락.
func _run(scenario_id: String, days: int, accept: String = "manual", seed_value: int = 42) -> Dictionary:
	var sc: Dictionary = _cfg.scenario(scenario_id)
	var loop: TickLoop = TickLoop.new(_scfg, seed_value)
	var rec: EventRecorder = EventRecorder.new(loop.bus, ECON_EVENTS)
	var econ: Economy = Economy.new(_cfg, loop.bus)
	assert_true(loop.register_system("economy", econ.update, econ.snapshot, econ.restore), "economy 등록")
	var g: int = _cfg.guarantee(sc["guarantee_grade"])
	var rows: Array = []
	var offered_days: Array = []
	var offered_amounts: Array = []
	var bankrupt_events: Array = []
	var settled_count: int = 0
	var rng0: String = loop.rng.get_state()["economy"]
	# 1일차 낮: 건설(자본 지출)·유지비 보고.
	if int(sc["initial_build_spend"]) > 0:
		loop.bus.publish("economy.charge_proposed", {"request_id": "build:1", "reason": "build", "amount": sc["initial_build_spend"]})
	loop.bus.publish("economy.upkeep_reported", {"total": sc["upkeep_per_day"]})
	for d: int in range(1, days + 1):
		rec.clear()
		# 낮: 개런티 시도(book_if_affordable).
		loop.bus.publish("economy.charge_proposed", {"request_id": "guarantee:%d" % d, "reason": "guarantee", "amount": g})
		var resolved: Dictionary = rec.of("economy.charge_resolved").back()
		var show_held: bool = resolved["approved"]
		if show_held:
			loop.bus.publish("economy.sales_reported", {"admissions": sc["admissions"], "audience": sc["audience"]})
		# close 진입(정산)까지.
		loop.advance(_scfg.day_ticks)
		var settled: Array = rec.of("economy.day_settled")
		settled_count += settled.size()
		var row: Dictionary = {
			"day": d, "show": show_held, "decline": resolved["decline_reason"],
			"settled": settled.size() == 1, "settled_cash": -1, "net": 0, "loan_repayment": 0, "event": "",
		}
		if settled.size() == 1:
			row["settled_cash"] = settled[0]["cash"]
			row["net"] = settled[0]["net"]
			row["loan_repayment"] = settled[0]["loan_repayment"]
		for o: Dictionary in rec.of("economy.bailout_offered"):
			offered_days.append(o["day"])
			offered_amounts.append(o["amount"])
			row["event"] = "구제 %d 제안(원금 %d)" % [offered_days.size(), o["amount"]]
			if accept == "manual":
				loop.bus.publish("economy.bailout_accept_requested", {})
				loop.advance(0)
		for b: Dictionary in rec.of("economy.bankrupt"):
			bankrupt_events.append(b)
			row["event"] = "파산(게임 오버)"
		row["end_cash"] = econ.cash
		rows.append(row)
		if d < days:
			loop.bus.publish("time.next_day_requested", {})
			loop.advance(0)
	return {
		"rows": rows, "econ": econ, "loop": loop, "offered_days": offered_days, "offered_amounts": offered_amounts,
		"bankrupt_events": bankrupt_events, "settled_count": settled_count,
		"rng_same": loop.rng.get_state()["economy"] == rng0,
	}


func _col(rows: Array, key: String) -> Array:
	var out: Array = []
	for r: Dictionary in rows:
		out.append(r[key])
	return out


func _print_table(title: String, rows: Array) -> void:
	print("QA30|## %s" % title)
	print("QA30|| 일 | 공연 | 정산 뒤 cash | 일말 cash(구제 수락 뒤) | net | 상환 | 비고 |")
	print("QA30||---|---|---|---|---|---|---|")
	for r: Dictionary in rows:
		var show_txt: String = "○" if r["show"] else "× (%s)" % r["decline"]
		var settled_txt: String = str(r["settled_cash"]) if r["settled"] else "(정산 없음)"
		print("QA30|| %d | %s | %s | %d | %d | %d | %s |" % [r["day"], show_txt, settled_txt, r["end_cash"], r["net"], r["loan_repayment"], r["event"]])


# --- tier1_baseline 30일 -------------------------------------------------------

func test_baseline_30_days() -> void:
	var sc: Dictionary = _cfg.scenario("tier1_baseline")
	var exp: Dictionary = sc["expected"]
	var res: Dictionary = _run("tier1_baseline", DAYS)
	var rows: Array = res["rows"]
	_print_table("tier1_baseline 시드 42, 30 게임일", rows)
	assert_eq(rows.size(), DAYS)
	assert_eq(res["settled_count"], DAYS, "날마다 정산 1회")
	assert_eq(res["bankrupt_events"], [], "파산 없음")
	assert_eq(res["offered_days"], [], "구제 제안 없음")
	assert_true(res["rng_same"], "economy 난수 스트림 불변")
	assert_eq(_col(rows, "show").count(true), DAYS, "매일 공연")
	# 매일 net == expected.net(1,142), 하루 현금 변화 == day_cash_delta.
	for r: Dictionary in rows:
		assert_eq(r["net"], exp["net"], "%d일 net" % r["day"])
		assert_eq(r["net"], 1142, "리터럴 net 1,142")
	# cash 열: 1일차 건설 3,000 뒤 매일 +1,142 → 정산 뒤 cash(d) = 5,000 − 3,000 + 1,142 × d.
	var after_build: int = _cfg.starting_cash - int(sc["initial_build_spend"])
	for r: Dictionary in rows:
		assert_eq(r["settled_cash"], after_build + int(exp["day_cash_delta"]) * int(r["day"]), "%d일 정산 뒤 cash" % r["day"])
		assert_eq(r["end_cash"], r["settled_cash"], "구제가 없으니 일말 cash == 정산 뒤 cash")
	assert_eq(rows[0]["settled_cash"], 3142, "1일 3,142")
	assert_eq([rows[23]["settled_cash"], rows[24]["settled_cash"]], [29408, 30550], "24일 29,408 / 25일 30,550")
	# 티어 2 자금(tiers.json tier_2.unlock_cash)에 처음 닿는 날.
	var tiers: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/tiers/tiers.json"))
	var unlock: int = 0
	for t: Dictionary in tiers["rows"]:
		if t["id"] == "tier_2":
			unlock = int(t["unlock_cash"])
	assert_eq(unlock, 30000)
	var reach: int = 0
	for r: Dictionary in rows:
		if reach == 0 and r["settled_cash"] >= unlock:
			reach = r["day"]
	print("QA30|티어 2 자금 도달일 = %d (expected.days_to_tier2_cash = %d, checks.tier2_max_days = %d)" % [reach, exp["days_to_tier2_cash"], sc["checks"]["tier2_max_days"]])
	assert_eq(reach, exp["days_to_tier2_cash"], "첫 도달일 == days_to_tier2_cash")
	assert_eq(reach, 25, "리터럴 25일")
	assert_lte(reach, int(sc["checks"]["tier2_max_days"]), "≤ 30일")
	assert_eq(res["econ"].cash, after_build + 1142 * DAYS, "30일 뒤 cash 2,000 + 1,142 × 30")
	assert_eq(res["econ"].cash, 36260, "리터럴 30일 cash")


# --- tier1_bankrupt 30일 -------------------------------------------------------

func test_bankrupt_30_days_manual_accept() -> void:
	var sc: Dictionary = _cfg.scenario("tier1_bankrupt")
	var exp: Dictionary = sc["expected"]
	var res: Dictionary = _run("tier1_bankrupt", DAYS, "manual")
	var rows: Array = res["rows"]
	_print_table("tier1_bankrupt 시드 42, 30 게임일(구제는 제안된 close 에서 수락)", rows)
	var bd: int = exp["bankrupt_day"]
	# 파산일까지 정산 뒤 cash == cash_by_day.
	var settled_cash: Array = _col(rows, "settled_cash").slice(0, bd)
	assert_eq(settled_cash, exp["cash_by_day"], "cash_by_day == expected")
	assert_eq(settled_cash, [4294, 3588, 2882, 2176, 1470, 764, 58, -742, 1882, 764, -354, 1513, 26, -1555], "리터럴")
	assert_eq(res["offered_days"], exp["bailout_offered_days"])
	assert_eq(res["offered_days"], [8, 11], "리터럴 구제 제안일")
	assert_eq(res["offered_amounts"], exp["bailout_amounts"])
	assert_eq(res["offered_amounts"], [3742, 3354], "리터럴 원금")
	assert_eq(res["bankrupt_events"].size(), 1, "economy.bankrupt 정확히 1회")
	assert_eq(res["bankrupt_events"][0], {"day": 14, "cash": -1555, "bailouts_used": 2})
	assert_eq(bd, 14, "리터럴 파산일")
	# 공연 거절일은 8, 14 뿐(C3).
	var no_show: Array = []
	for r: Dictionary in rows.slice(0, bd):
		if not r["show"]:
			no_show.append(r["day"])
	assert_eq(no_show, [8, 14], "개런티 거절일")
	# 파산 뒤 15~30일: 정산·구제 없음, cash 고정, 개런티는 bankrupt 로 거절.
	assert_eq(res["settled_count"], bd, "정산은 파산일까지 14회")
	for r: Dictionary in rows.slice(bd):
		assert_false(r["settled"], "%d일 정산 없음" % r["day"])
		assert_eq(r["end_cash"], -1555, "%d일 cash 고정" % r["day"])
		assert_eq(r["decline"], "bankrupt", "%d일 개런티 C1 거절" % r["day"])
	assert_true(res["econ"].bankrupt)
	assert_true(res["rng_same"], "economy 난수 스트림 불변")
	assert_lte(bd, DAYS, "30일 안에 파산")


func test_bankrupt_auto_accept_matches_manual() -> void:
	## economy.md: 자동 수락(다음 날 time.day_started)으로 바꿔도 기대값은 같다.
	var exp: Dictionary = _cfg.scenario("tier1_bankrupt")["expected"]
	var res: Dictionary = _run("tier1_bankrupt", DAYS, "auto")
	var rows: Array = res["rows"]
	_print_table("tier1_bankrupt 시드 42, 30 게임일(자동 수락)", rows)
	assert_eq(_col(rows, "settled_cash").slice(0, 14), exp["cash_by_day"], "자동 수락도 cash_by_day 동일")
	assert_eq(res["offered_days"], exp["bailout_offered_days"])
	assert_eq(res["offered_amounts"], exp["bailout_amounts"])
	assert_eq(res["bankrupt_events"].size(), 1)
	assert_eq(res["bankrupt_events"][0]["day"], 14)
	assert_eq(res["econ"].bailouts_left, 0)
	assert_push_warning_count(0, "TickLoop 경로에서는 S0 경고 없음")


func test_seed_independent() -> void:
	## 경제 v0 는 난수를 안 쓰므로 시드가 달라도 같은 cash 열.
	var a: Dictionary = _run("tier1_bankrupt", 16, "manual", 42)
	var b: Dictionary = _run("tier1_bankrupt", 16, "manual", 7)
	assert_eq(_col(a["rows"], "settled_cash"), _col(b["rows"], "settled_cash"), "시드 42 == 시드 7")
