extends GutTest
## SE-012 EC2~EC16 — Economy. docs/gdd/economy.md#수용-기준 을 1:1 로 옮겼다.
## 기대 수치는 economy.json(행·reference_scenarios)에서 읽고, 핵심 수는 리터럴로 한 번 더 단언한다.
## 단위 케이스는 EventBus 하나에 time.* 를 테스트가 직접 발행해 구동하고, EC3·EC10·EC14·EC15·EC16(b) 는
## TickLoop 으로 구동한다(economy 를 훅과 함께 등록).

const ECON_EVENTS: Array[String] = [
	"economy.cash_changed", "economy.charge_resolved", "economy.ticket_price_changed",
	"economy.ticket_price_rejected", "economy.day_settled", "economy.bailout_offered", "economy.bailout_taken",
	"economy.bankrupt",
]
const TIME_AND_ECON: Array[String] = [
	"tick.advanced", "time.phase_changed", "time.day_started", "time.speed_changed", "time.speed_rejected",
	"economy.cash_changed", "economy.charge_resolved", "economy.ticket_price_changed",
	"economy.ticket_price_rejected", "economy.day_settled", "economy.bailout_offered", "economy.bailout_taken",
	"economy.bankrupt",
]
## 테스트가 만드는 부족액(임의 값). 정산 뒤 cash == -TEST_DEFICIT 이 되게 건설비를 맞춘다.
const TEST_DEFICIT: int = 100

var _cfg: EconomyConfig
var _scfg: SimConfig
var _row: Dictionary


func before_all() -> void:
	_cfg = EconomyConfig.load()
	_scfg = SimConfig.load()
	_row = _cfg.row(1)


# --- 도우미 -------------------------------------------------------------------

func _raw() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(EconomyConfig.DEFAULT_PATH))


## 단위 구동: [bus, econ, rec]. 기록기는 Economy 보다 먼저 구독한다(생성자 이벤트 0개 확인용).
func _unit(cfg: EconomyConfig = null) -> Array:
	var bus: EventBus = EventBus.new()
	var rec: EventRecorder = EventRecorder.new(bus, TIME_AND_ECON)
	var econ: Economy = Economy.new(cfg if cfg != null else _cfg, bus)
	return [bus, econ, rec]


## TickLoop 구동: [loop, econ, rec]. economy 를 훅과 함께 등록한다(economy.md "틱 업데이트·등록").
func _looped(seed_value: int = 42, cfg: EconomyConfig = null) -> Array:
	var loop: TickLoop = TickLoop.new(_scfg, seed_value)
	var rec: EventRecorder = EventRecorder.new(loop.bus, TIME_AND_ECON)
	var econ: Economy = Economy.new(cfg if cfg != null else _cfg, loop.bus)
	assert_true(loop.register_system("economy", econ.update, econ.snapshot, econ.restore), "economy 등록")
	return [loop, econ, rec]


func _charge(bus: EventBus, reason: Variant, amount: Variant, rid: Variant = "t") -> void:
	bus.publish("economy.charge_proposed", {"request_id": rid, "reason": reason, "amount": amount})


func _refund(bus: EventBus, base: Variant, reason: String = "demolish") -> void:
	bus.publish("economy.refund_proposed", {"request_id": "r", "reason": reason, "base_amount": base})


func _sales(bus: EventBus, admissions: Variant, audience: Variant) -> void:
	bus.publish("economy.sales_reported", {"admissions": admissions, "audience": audience})


func _upkeep(bus: EventBus, total: Variant) -> void:
	bus.publish("economy.upkeep_reported", {"total": total})


func _close(bus: EventBus, d: int) -> void:
	bus.publish("time.phase_changed", {"from": "show", "to": "close", "day": d, "tick": d * _scfg.day_ticks})


func _new_day(bus: EventBus, d: int) -> void:
	bus.publish("time.day_started", {"day": d})
	bus.publish("time.phase_changed", {"from": "close", "to": "day", "day": d, "tick": (d - 1) * _scfg.day_ticks})


func _command(bus: EventBus, cmd: String, payload: Dictionary) -> void:
	bus.publish(cmd, payload)
	bus.dispatch_commands()


func _accept(bus: EventBus) -> void:
	_command(bus, "economy.bailout_accept_requested", {})


func _ehash(econ: Economy) -> String:
	return JSON.stringify(econ.snapshot(), "", true)


## 파산 뒤 비교용: day·phase 를 뺀 경제 상태 해시(SE-016, economy.md "파산 뒤").
func _hash_without_day_phase(econ: Economy) -> String:
	var s: Dictionary = econ.snapshot()
	s.erase("day")
	s.erase("phase")
	return JSON.stringify(s, "", true)


func _lhash(loop: TickLoop) -> String:
	return JSON.stringify(loop.snapshot(), "", true)


func _rt(v: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(v))


func _econ_events(rec: EventRecorder) -> Array:
	var out: Array = []
	for e: Array in rec.events:
		if (e[0] as String).begins_with("economy."):
			out.append(e)
	return out


func _names(events: Array) -> Array:
	var out: Array = []
	for e: Array in events:
		out.append(e[0])
	return out


func _last(rec: EventRecorder, event_name: String) -> Dictionary:
	var all: Array = rec.of(event_name)
	return all[all.size() - 1] if not all.is_empty() else {}


## 공식을 테스트 쪽에서 독립으로 다시 계산한다(economy.md #정산 S1~S14).
func _expect(adm: int, aud: int, upkeep: int, guarantee: int, repay: int, price: int = -1, row: Dictionary = {}) -> Dictionary:
	var r: Dictionary = row if not row.is_empty() else _row
	var scale: int = _cfg.rate_scale
	var p: int = price if price >= 0 else int(r["ticket_price_default"])
	var ticket: int = p * adm
	var buyers: int = int(floor(float(aud * int(r["bar_purchase_rate_bp"])) / scale))
	var bar_rev: int = buyers * int(r["bar_avg_spend"])
	var bar_cost: int = int(floor(float(bar_rev * int(r["bar_cost_rate_bp"])) / scale))
	var revenue: int = ticket + bar_rev
	var rent: int = r["rent_per_day"]
	var opc: int = bar_cost + rent + upkeep + guarantee
	var pretax: int = revenue - opc
	var tax: int = int(floor(float(maxi(0, pretax) * int(r["tax_rate_bp"])) / scale))
	var net: int = pretax - tax
	return {
		"ticket_price": p, "admissions": adm, "audience": aud, "ticket_revenue": ticket, "bar_buyers": buyers,
		"bar_revenue": bar_rev, "bar_cost": bar_cost, "revenue": revenue, "rent": rent, "upkeep": upkeep,
		"guarantee": guarantee, "operating_costs": opc, "pretax": pretax, "tax": tax, "net": net,
		"loan_repayment": repay, "settlement_delta": net + guarantee - repay,
	}


## 정산 뒤 cash == -TEST_DEFICIT 이 되는 건설비(매출·유지비 없음 가정).
func _deficit_build(cash_now: int) -> int:
	return cash_now - int(_row["rent_per_day"]) + TEST_DEFICIT


# --- EC2 ---------------------------------------------------------------------

func test_new_game_state() -> void:
	var u: Array = _unit()
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	assert_eq(econ.cash, _cfg.starting_cash, "cash == starting_cash")
	assert_eq(econ.cash, 5000, "리터럴 5,000")
	assert_eq(econ.ticket_price, _row["ticket_price_default"], "ticket_price == ticket_price_default")
	assert_eq(econ.ticket_price, 20, "리터럴 20")
	assert_eq(econ.bailouts_left, _cfg.bailout_count, "bailouts_left == bailout_count")
	assert_eq(econ.bailouts_left, 2, "리터럴 2")
	assert_false(econ.bankrupt)
	assert_eq(econ.ledger, {"admissions": 0, "audience": 0, "guarantee": 0})
	assert_eq([econ.tier, econ.day, econ.phase, econ.upkeep_per_day, econ.last_settled_day], [1, 1, "day", 0, 0])
	assert_null(econ.pending_bailout)
	assert_eq(econ.loans, [])
	assert_eq(rec.events, [], "생성자는 이벤트를 내지 않는다")
	var keys: Array = econ.snapshot().keys()
	keys.sort()
	assert_eq(keys, ["bailouts_left", "bankrupt", "cash", "day", "last_settled_day", "ledger", "loans", "pending_bailout", "phase", "ticket_price", "tier", "upkeep_per_day"], "#상태 표의 12개 필드")


# --- EC3 ---------------------------------------------------------------------

func test_settles_once_on_close_entry() -> void:
	var l: Array = _looped()
	var loop: TickLoop = l[0]
	var rec: EventRecorder = l[2]
	assert_eq(loop.advance(_scfg.day_ticks), _scfg.day_ticks)
	var settled: Array = rec.of("economy.day_settled")
	assert_eq(settled.size(), 1, "close 진입에서 정확히 1회")
	assert_eq(settled[0]["day"], 1)
	var i_settled: int = -1
	var i_tick: int = -1
	var i_prev: int = -1
	for i: int in rec.events.size():
		var e: Array = rec.events[i]
		if e[0] == "economy.day_settled":
			i_settled = i
		if e[0] == "tick.advanced" and e[1]["tick"] == _scfg.day_ticks:
			i_tick = i
		if e[0] == "tick.advanced" and e[1]["tick"] == _scfg.day_ticks - 1:
			i_prev = i
	assert_true(i_prev < i_settled and i_settled < i_tick, "정산은 close 진입 틱 안, 그 틱의 tick.advanced 보다 먼저 (%d<%d<%d)" % [i_prev, i_settled, i_tick])
	rec.clear()
	loop.bus.publish("time.phase_changed", {"from": "show", "to": "close", "day": 1, "tick": _scfg.day_ticks})
	assert_eq(rec.count("economy.day_settled"), 0, "같은 날 close 를 다시 받아도 정산 0회")
	loop.bus.publish("time.next_day_requested", {})
	loop.advance(0)
	loop.advance(_scfg.day_ticks)
	assert_eq(rec.of("economy.day_settled").size(), 1, "다음 날 close 에서 1회 더")
	assert_eq(_last(rec, "economy.day_settled")["day"], 2)


# --- EC4 ---------------------------------------------------------------------

func test_immediate_vs_settlement_items() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	var start: int = econ.cash
	var g: int = _cfg.guarantee("local")
	_charge(bus, "build", 1000, "b1")
	assert_eq(econ.cash, start - 1000, "build 즉시 −1000")
	assert_eq(_econ_events(rec), [
		["economy.cash_changed", {"cash": start - 1000, "delta": -1000, "reason": "build"}],
		["economy.charge_resolved", {"request_id": "b1", "reason": "build", "amount": 1000, "approved": true, "decline_reason": "", "cash": start - 1000}],
	], "cash_changed → charge_resolved")
	assert_eq(econ.ledger["guarantee"], 0, "capital 은 ledger 에 안 들어감")
	_charge(bus, "guarantee", g, "a1")
	assert_eq(econ.cash, start - 1000 - g, "guarantee 즉시 −400")
	assert_eq(econ.ledger["guarantee"], g, "operating 은 ledger.guarantee 누적")
	var before_sales: int = econ.cash
	_sales(bus, 100, 100)
	assert_eq(econ.cash, before_sales, "sales_reported 는 정산 전까지 cash 불변")
	rec.clear()
	_close(bus, 1)
	var s: Dictionary = rec.of("economy.day_settled")[0]
	var want: Dictionary = _expect(100, 100, 0, g, 0)
	for k: String in want:
		assert_eq(s[k], want[k], "day_settled.%s" % k)
	assert_eq(s["guarantee"], 400, "day_settled.guarantee == 400")
	assert_eq(s["operating_costs"], s["bar_cost"] + s["rent"] + s["upkeep"] + 400, "개런티는 operating_costs 에 포함, 건설비는 없음")
	assert_eq(s["pretax"], s["revenue"] - s["operating_costs"], "pretax 에 건설비 없음")
	assert_eq(s["settlement_delta"], s["revenue"] - s["bar_cost"] - s["rent"] - s["upkeep"] - s["tax"], "settlement_delta 에 개런티·건설비 없음")
	assert_eq(econ.cash, before_sales + s["settlement_delta"])
	assert_eq(s["cash"], econ.cash)


# --- EC5 ---------------------------------------------------------------------

func test_charge_declines() -> void:
	var d: Dictionary = _raw()
	d["bailout_count"] = 0
	var cfg0: EconomyConfig = EconomyConfig.from_dict(d)
	var u: Array = _unit(cfg0)
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	var c: int = econ.cash
	var cases: Array = [
		# [라벨, 페이로드, 기대 resolved]
		["C2 모르는 사유", {"request_id": "x1", "reason": "food", "amount": 100}, {"request_id": "x1", "reason": "food", "amount": 100, "decline_reason": "invalid"}],
		["C2 음수", {"request_id": "x2", "reason": "build", "amount": -1}, {"request_id": "x2", "reason": "build", "amount": -1, "decline_reason": "invalid"}],
		["C2 비정수 1.5", {"request_id": "x3", "reason": "build", "amount": 1.5}, {"request_id": "x3", "reason": "build", "amount": 0, "decline_reason": "invalid"}],
		["C2 문자열 금액", {"request_id": "x4", "reason": "build", "amount": "100"}, {"request_id": "x4", "reason": "build", "amount": 0, "decline_reason": "invalid"}],
		["C2 금액 없음", {"request_id": "x5", "reason": "build"}, {"request_id": "x5", "reason": "build", "amount": 0, "decline_reason": "invalid"}],
		["C2 id·사유가 문자열 아님", {"request_id": 7, "reason": 3, "amount": 10}, {"request_id": "", "reason": "", "amount": 10, "decline_reason": "invalid"}],
		["C3 cash < amount", {"request_id": "x6", "reason": "build", "amount": c + 1}, {"request_id": "x6", "reason": "build", "amount": c + 1, "decline_reason": "insufficient_cash"}],
	]
	for cs: Array in cases:
		var before: String = _ehash(econ)
		rec.clear()
		bus.publish("economy.charge_proposed", cs[1])
		var want: Dictionary = (cs[2] as Dictionary).duplicate()
		want["approved"] = false
		want["cash"] = c
		assert_eq(_econ_events(rec), [["economy.charge_resolved", want]], "%s: charge_resolved 1개" % cs[0])
		assert_eq(rec.count("economy.cash_changed"), 0, "%s: cash_changed 0개" % cs[0])
		assert_eq(_ehash(econ), before, "%s: 상태 불변" % cs[0])
	# 상태 입력의 정수값 float 는 방어적으로 int 로 정규화(economy.md 입력 계약).
	rec.clear()
	_charge(bus, "build", 100.0, "f1")
	assert_eq(econ.cash, c - 100, "정수값 float 금액은 승인")
	assert_typeof(_last(rec, "economy.charge_resolved")["amount"], TYPE_INT)
	c = econ.cash
	# amount == cash 는 승인되어 cash == 0.
	rec.clear()
	_charge(bus, "build", c, "all")
	assert_eq(econ.cash, 0, "amount == cash 승인 → 0")
	assert_true(_last(rec, "economy.charge_resolved")["approved"])
	# C1: 파산 뒤(구제 0회 설정에서 정산이 음수).
	_close(bus, 1)
	assert_true(econ.bankrupt, "준비: 파산")
	var before_b: String = _ehash(econ)
	rec.clear()
	_charge(bus, "build", 0, "z")
	assert_eq(_econ_events(rec), [["economy.charge_resolved", {"request_id": "z", "reason": "build", "amount": 0, "approved": false, "decline_reason": "bankrupt", "cash": econ.cash}]], "C1 bankrupt")
	assert_eq(_ehash(econ), before_b, "C1: 상태 불변")


# --- EC6 ---------------------------------------------------------------------

func test_tax_floor_zero_on_loss_and_zero_rate() -> void:
	var base: Dictionary = _cfg.scenario("tier1_baseline")
	var bank: Dictionary = _cfg.scenario("tier1_bankrupt")
	var g: int = _cfg.guarantee("local")
	var inputs: Dictionary = {"ticket_price": _row["ticket_price_default"], "admissions": base["admissions"], "audience": base["audience"], "upkeep": base["upkeep_per_day"], "guarantee": g, "loan_repayment": 0}
	var r: Dictionary = Economy.compute_settlement(_row, _cfg.rate_scale, inputs)
	assert_eq([r["pretax"], r["tax"]], [1268, 126], "pretax 1,268 → tax 126 (⌊126.8⌋)")
	var loss_in: Dictionary = inputs.duplicate()
	loss_in["admissions"] = bank["admissions"]
	loss_in["audience"] = bank["audience"]
	var rl: Dictionary = Economy.compute_settlement(_row, _cfg.rate_scale, loss_in)
	assert_eq([rl["pretax"], rl["tax"], rl["net"]], [-706, 0, -706], "손실일 세금 0")
	# tax_rate_bp 0 사본 → 항상 0.
	var d: Dictionary = _raw()
	d["rows"][0]["tax_rate_bp"] = 0
	var cfg0: EconomyConfig = EconomyConfig.from_dict(d)
	var r0: Dictionary = Economy.compute_settlement(cfg0.row(1), cfg0.rate_scale, inputs)
	assert_eq(r0["tax"], 0, "tax_rate_bp 0 → tax 0")
	assert_eq(r0["net"], r0["pretax"])
	# 손실 이월 없음: 손실 다음 날 세금은 그날 pretax 로만.
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var rec: EventRecorder = u[2]
	_upkeep(bus, base["upkeep_per_day"])
	_charge(bus, "guarantee", g)
	_sales(bus, bank["admissions"], bank["audience"])
	_close(bus, 1)
	assert_eq(_last(rec, "economy.day_settled")["tax"], 0, "1일 손실 → 0")
	_new_day(bus, 2)
	_charge(bus, "guarantee", g)
	_sales(bus, base["admissions"], base["audience"])
	_close(bus, 2)
	var s2: Dictionary = _last(rec, "economy.day_settled")
	assert_eq(s2["pretax"], 1268)
	assert_eq(s2["tax"], s2["pretax"] * int(_row["tax_rate_bp"]) / _cfg.rate_scale, "2일 세금 = 그날 pretax 기준(이월 없음)")
	assert_eq(s2["tax"], 126)


# --- EC7 ---------------------------------------------------------------------

func test_demolish_refund_floor() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	var c: int = econ.cash
	var rate: int = _cfg.demolish_refund_rate_bp
	for pair: Array in [[1000, 700], [999, 699]]:
		rec.clear()
		_refund(bus, pair[0])
		assert_eq(pair[0] * rate / _cfg.rate_scale, pair[1], "공식 ⌊base × bp ÷ scale⌋ == 리터럴")
		c += pair[1]
		assert_eq(econ.cash, c, "base %d → +%d" % pair)
		assert_eq(_econ_events(rec), [["economy.cash_changed", {"cash": c, "delta": pair[1], "reason": "demolish_refund"}]])
	rec.clear()
	_refund(bus, 1)
	assert_eq(econ.cash, c, "base 1 → +0")
	assert_eq(_econ_events(rec), [], "환불 0 이면 cash_changed 없음")
	var before: String = _ehash(econ)
	_refund(bus, 1000, "sell")
	_refund(bus, -5)
	_refund(bus, "x")
	assert_eq(_ehash(econ), before, "reason 다름·음수·비정수 → 무시")
	assert_eq(_econ_events(rec), [])
	assert_push_warning_count(3, "무시할 때 push_warning")
	_close(bus, 1)
	var s: Dictionary = _last(rec, "economy.day_settled")
	assert_eq(s["pretax"], -int(_row["rent_per_day"]), "환불은 pretax 에 안 들어감")
	assert_eq(econ.cash, c + s["settlement_delta"])


# --- EC8 ---------------------------------------------------------------------

func test_reference_scenario_baseline() -> void:
	var sc: Dictionary = _cfg.scenario("tier1_baseline")
	var exp: Dictionary = sc["expected"]
	var checks: Dictionary = sc["checks"]
	var g: int = _cfg.guarantee(sc["guarantee_grade"])
	var inputs: Dictionary = {"ticket_price": _row["ticket_price_default"], "admissions": sc["admissions"], "audience": sc["audience"], "upkeep": sc["upkeep_per_day"], "guarantee": g, "loan_repayment": 0}
	var r: Dictionary = Economy.compute_settlement(_row, _cfg.rate_scale, inputs)
	var matched: int = 0
	for k: String in exp:
		if r.has(k):
			assert_eq(r[k], exp[k], "compute_settlement.%s == expected" % k)
			matched += 1
	assert_eq(matched, 14, "S1~S14 키 14개 대조")
	assert_eq([r["net"], r["settlement_delta"], r["tax"]], [1142, 1542, 126], "리터럴 net·settlement_delta·tax")

	# 버스로 하루: build → 개런티 → sales → upkeep → close.
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	var start: int = econ.cash
	_charge(bus, "build", sc["initial_build_spend"])
	_charge(bus, "guarantee", g)
	_sales(bus, sc["admissions"], sc["audience"])
	_upkeep(bus, sc["upkeep_per_day"])
	_close(bus, 1)
	var s: Dictionary = _last(rec, "economy.day_settled")
	var payload_keys: Array = s.keys()
	payload_keys.sort()
	assert_eq(payload_keys, ["admissions", "audience", "bar_buyers", "bar_cost", "bar_revenue", "cash", "day", "guarantee", "loan_repayment", "net", "operating_costs", "pretax", "rent", "revenue", "settlement_delta", "tax", "ticket_price", "ticket_revenue", "upkeep"], "day_settled 페이로드 키 19개(events.md)")
	for k: String in payload_keys:
		assert_typeof(s[k], TYPE_INT, "day_settled.%s 는 int" % k)
	matched = 0
	for k: String in exp:
		if s.has(k):
			assert_eq(s[k], exp[k], "day_settled.%s == expected" % k)
			matched += 1
	assert_eq(matched, 14)
	assert_eq(econ.cash - (start - int(sc["initial_build_spend"])), exp["day_cash_delta"], "건설 뒤 하루 현금 변화 == day_cash_delta (= net)")
	assert_eq(exp["day_cash_delta"], exp["net"])

	# 임대료 대비 순이익(bp).
	var ratio_bp: int = int(exp["net"]) * _cfg.rate_scale / int(_row["rent_per_day"])
	assert_eq(ratio_bp, 19033, "⌊1,142 × 10,000 ÷ 600⌋")
	assert_between(ratio_bp, int(checks["net_to_rent_min_bp"]), int(checks["net_to_rent_max_bp"]), "checks 범위 안")

	# 티어 2 자금 도달일(tiers.json 은 테스트가 직접 읽는다).
	var tiers: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/tiers/tiers.json"))
	var unlock: int = 0
	for t: Dictionary in tiers["rows"]:
		if t["id"] == "tier_2":
			unlock = int(t["unlock_cash"])
	assert_eq(unlock, 30000, "tiers.json tier_2 unlock_cash")
	var need: int = unlock - _cfg.starting_cash + int(sc["initial_build_spend"])
	var days: int = (need + int(exp["net"]) - 1) / int(exp["net"])
	assert_eq(days, exp["days_to_tier2_cash"], "⌈(unlock − start + build) ÷ net⌉ == expected")
	assert_eq(days, 25, "리터럴 25일")
	assert_lte(days, int(checks["tier2_max_days"]), "≤ tier2_max_days")
	# 일자 검증(economy.md): 같은 정책으로 날을 돌리면 24일 정산 뒤 미달, 25일 정산 뒤 도달.
	var cash_by_day: Array = [econ.cash]
	for dd: int in range(2, days + 1):
		_new_day(bus, dd)
		_charge(bus, "guarantee", g)
		_sales(bus, sc["admissions"], sc["audience"])
		_close(bus, dd)
		cash_by_day.append(_last(rec, "economy.day_settled")["cash"])
	assert_eq([cash_by_day[days - 2], cash_by_day[days - 1]], [29408, 30550], "24일 29,408 / 25일 30,550")
	assert_lt(cash_by_day[days - 2], unlock)
	assert_gte(cash_by_day[days - 1], unlock)


# --- EC9 ---------------------------------------------------------------------

func test_bailout_offered_then_accepted() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	_charge(bus, "build", _deficit_build(econ.cash))
	rec.clear()
	_close(bus, 1)
	assert_eq(econ.cash, -TEST_DEFICIT, "준비: 정산 뒤 음수")
	var loan_amt: int = _row["bailout_loan_amount"]
	var amount: int = TEST_DEFICIT + loan_amt
	var interest: int = amount * int(_row["bailout_interest_bp"]) / _cfg.rate_scale
	var total: int = amount + interest
	var n: int = _row["bailout_repay_days"]
	var first: int = total / n + (1 if total % n > 0 else 0)
	assert_eq(_names(_econ_events(rec)), ["economy.cash_changed", "economy.day_settled", "economy.bailout_offered"])
	var offered: Dictionary = _last(rec, "economy.bailout_offered")
	assert_eq(offered, {"day": 1, "kind": "loan", "deficit": TEST_DEFICIT, "amount": amount, "interest": interest, "total_due": total, "repay_days": n, "first_installment": first, "bailouts_left_after": _cfg.bailout_count - 1}, "bailout_offered 공식")
	assert_eq([amount, interest, total, first], [3100, 310, 3410, 341], "리터럴")
	assert_not_null(econ.pending_bailout)
	# 명령은 경계 처리 전까지 적용되지 않는다.
	rec.clear()
	bus.publish("economy.bailout_accept_requested", {})
	assert_eq(econ.cash, -TEST_DEFICIT, "dispatch 전에는 그대로")
	bus.dispatch_commands()
	assert_eq(econ.cash, loan_amt, "수락 → cash == bailout_loan_amount")
	assert_eq(econ.cash, 3000, "리터럴 3,000")
	assert_eq(econ.bailouts_left, _cfg.bailout_count - 1, "bailouts_left 1 감소")
	assert_null(econ.pending_bailout)
	assert_eq(econ.loans.size(), 1)
	assert_eq(econ.loans[0], {"day_taken": 1, "amount": amount, "total_due": total, "installments": Economy.split_installments(total, n), "paid": 0})
	assert_eq(_econ_events(rec), [
		["economy.cash_changed", {"cash": loan_amt, "delta": amount, "reason": "bailout"}],
		["economy.bailout_taken", {"day": 1, "kind": "loan", "amount": amount, "total_due": total, "repay_days": n, "bailouts_left": _cfg.bailout_count - 1, "cash": loan_amt, "auto": false}],
	], "cash_changed → bailout_taken {auto:false}")
	var before: String = _ehash(econ)
	rec.clear()
	_accept(bus)
	assert_eq(_ehash(econ), before, "두 번째 수락은 무시")
	assert_eq(rec.events, [])


# --- EC10 --------------------------------------------------------------------

## d = 1 일 close 에서 구제 제안 → (manual 이면 close 에서 수락) → 다음 날 → 2일 close. 결과 묶음.
func _run_bailout_day(manual: bool) -> Dictionary:
	var l: Array = _looped()
	var loop: TickLoop = l[0]
	var econ: Economy = l[1]
	var rec: EventRecorder = l[2]
	_charge(loop.bus, "build", _deficit_build(econ.cash))
	loop.advance(_scfg.day_ticks)
	var offered: Dictionary = _last(rec, "economy.bailout_offered")
	if manual:
		loop.bus.publish("economy.bailout_accept_requested", {})
		loop.advance(0)
	rec.clear()
	loop.bus.publish("time.next_day_requested", {})
	loop.advance(0)
	var next_day_events: Array = rec.events.duplicate(true)
	var loans: Array = econ.loans.duplicate(true)
	rec.clear()
	loop.advance(_scfg.day_ticks)
	return {"offered": offered, "next_day_events": next_day_events, "loans": loans, "settled2": _last(rec, "economy.day_settled")}


func test_bailout_auto_accepted_on_next_day() -> void:
	var a: Dictionary = _run_bailout_day(false)
	var d: int = a["offered"]["day"]
	assert_eq(d, 1, "준비: 1일 close 에서 제안")
	assert_eq(_names(a["next_day_events"]), ["time.day_started", "time.phase_changed", "time.speed_changed", "economy.cash_changed", "economy.bailout_taken"], "자동 수락 이벤트 순서(E2 FIFO)")
	var taken: Dictionary = a["next_day_events"][4][1]
	assert_true(taken["auto"], "auto: true")
	assert_eq(taken["day"], d, "bailout_taken.day == 제안일")
	assert_eq(a["loans"][0]["day_taken"], d, "loans[0].day_taken == 제안일")
	assert_eq(a["settled2"]["day"], d + 1)
	assert_eq(a["settled2"]["loan_repayment"], a["offered"]["first_installment"], "다음 정산에서 첫 회차")
	var m: Dictionary = _run_bailout_day(true)
	assert_eq(m["loans"][0]["day_taken"], d, "수동 수락도 day_taken == 제안일")
	assert_eq(m["settled2"], a["settled2"], "수동 수락과 d + 1 일 day_settled 동일")
	assert_push_warning_count(0, "정상 경로(TickLoop)에서는 S0 경고 없음")

	# S0 (SE-012 후속): EventBus 만으로 d 일 close 에서 제안 → time.day_started 없이 d + 1 일 close.
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	_charge(bus, "build", _deficit_build(econ.cash))
	_close(bus, d)
	var offered: Dictionary = _last(rec, "economy.bailout_offered")
	assert_false(offered.is_empty(), "준비: d 일 close 에서 구제 제안")
	assert_not_null(econ.pending_bailout)
	var amount: int = offered["amount"]
	var loan_amt: int = _row["bailout_loan_amount"]
	var left_before: int = econ.bailouts_left
	rec.clear()
	_close(bus, d + 1)
	assert_push_warning_count(1, "S0: push_warning 1회")
	var settled: Dictionary = _last(rec, "economy.day_settled")
	var want: Array = [
		["economy.cash_changed", {"cash": loan_amt, "delta": amount, "reason": "bailout"}],
		["economy.bailout_taken", {"day": d, "kind": "loan", "amount": amount, "total_due": offered["total_due"], "repay_days": offered["repay_days"], "bailouts_left": left_before - 1, "cash": loan_amt, "auto": true}],
	]
	if int(settled.get("settlement_delta", 0)) != 0:
		want.append(["economy.cash_changed", {"cash": settled["cash"], "delta": settled["settlement_delta"], "reason": "settlement"}])
	want.append(["economy.day_settled", settled])
	assert_eq(_econ_events(rec), want, "cash_changed{bailout} → bailout_taken{auto:true, day:d} → (cash_changed{settlement}) → day_settled")
	assert_eq(settled["day"], d + 1)
	assert_eq(econ.bailouts_left, left_before - 1, "bailouts_left 1 감소")
	assert_eq(econ.loans[0]["day_taken"], d, "loans[0].day_taken == 제안일")
	assert_eq(settled["loan_repayment"], offered["first_installment"], "첫 회차는 이번 정산 S13")
	assert_null(econ.pending_bailout, "B2 시점의 pending_bailout 은 null(덮어쓰기 없음)")
	# 결과는 빠진 time.day_started 가 왔을 때와 같다.
	var n: Array = _unit()
	var nbus: EventBus = n[0]
	var necon: Economy = n[1]
	var nrec: EventRecorder = n[2]
	_charge(nbus, "build", _deficit_build(necon.cash))
	_close(nbus, d)
	_new_day(nbus, d + 1)
	_close(nbus, d + 1)
	assert_eq(_last(nrec, "economy.day_settled"), settled, "time.day_started 가 있었을 때와 day_settled 동일")
	assert_eq(_ehash(econ), _ehash(necon), "time.day_started 가 있었을 때와 상태 동일")
	# 같은 날 close 를 한 번 더: 아무 일도 없음(1회성, pending_bailout 그대로).
	var before: String = _ehash(econ)
	rec.clear()
	_close(bus, d + 1)
	assert_eq(rec.events.size(), 1, "다시 보낸 time.phase_changed 1개뿐")
	assert_eq(_econ_events(rec), [], "economy 이벤트 0")
	assert_eq(_ehash(econ), before, "상태 불변")
	assert_push_warning_count(1, "중복 close 는 S0 경고를 더 내지 않음")


# --- EC11 --------------------------------------------------------------------

func test_loan_installments() -> void:
	var bank: Dictionary = _cfg.scenario("tier1_bankrupt")
	var amounts: Array = bank["expected"]["bailout_amounts"]
	var loan_amt: int = _row["bailout_loan_amount"]
	var rent: int = _row["rent_per_day"]
	# (a) 원금 3,742(부족액 742) → total_due 4,116, 412 × 6 + 411 × 4.
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	_charge(bus, "build", econ.cash)
	_upkeep(bus, int(amounts[0]) - loan_amt - rent)
	_close(bus, 1)
	var pb: Dictionary = econ.pending_bailout
	assert_eq(pb["total_due"], 4116)
	var want: Array = []
	for i: int in 6:
		want.append(412)
	for i: int in 4:
		want.append(411)
	assert_eq(pb["installments"], want, "412 × 6 + 411 × 4")
	var sum: int = 0
	for x: int in pb["installments"]:
		sum += x
	assert_eq(sum, 4116, "회차 합 == total_due")
	_accept(bus)
	_upkeep(bus, 0)
	var repaid: Array = []
	for d: int in range(2, 13):
		_new_day(bus, d)
		_sales(bus, 100, 100)
		_close(bus, d)
		repaid.append(_last(rec, "economy.day_settled")["loan_repayment"])
		if d == 2:
			assert_eq(econ.loans[0]["paid"], 1, "첫 상환은 수락 뒤 첫 정산")
		if d == 11:
			assert_eq(econ.loans, [], "10회 뒤 loans 에서 제거")
	var want_rep: Array = want.duplicate()
	want_rep.append(0)
	assert_eq(repaid, want_rep, "정산마다 1회차, 11회째는 0")
	# (b) 두 대출이 겹치면 받은 순서로 합산: 412 + 369 = 781.
	u = _unit()
	bus = u[0]
	econ = u[1]
	rec = u[2]
	_charge(bus, "build", econ.cash)
	_upkeep(bus, int(amounts[0]) - loan_amt - rent)
	_close(bus, 1)
	_accept(bus)
	_upkeep(bus, 0)
	_new_day(bus, 2)
	var deficit2: int = int(amounts[1]) - loan_amt
	_charge(bus, "build", econ.cash - rent - 412 + deficit2)
	_close(bus, 2)
	assert_eq(econ.cash, -deficit2, "준비: 2일 정산 뒤 −354")
	var pb2: Dictionary = econ.pending_bailout
	assert_eq([pb2["amount"], pb2["total_due"], pb2["installments"][0], pb2["installments"][9]], [3354, 3689, 369, 368])
	_accept(bus)
	assert_eq(econ.loans.size(), 2)
	_new_day(bus, 3)
	_sales(bus, 100, 100)
	_close(bus, 3)
	assert_eq(_last(rec, "economy.day_settled")["loan_repayment"], 781, "412 + 369")
	assert_eq([econ.loans[0]["paid"], econ.loans[1]["paid"]], [2, 1], "받은 순서")


# --- EC12 --------------------------------------------------------------------

func test_bankrupt_after_bailouts_exhausted() -> void:
	var sc: Dictionary = _cfg.scenario("tier1_bankrupt")
	var exp: Dictionary = sc["expected"]
	var g: int = _cfg.guarantee(sc["guarantee_grade"])
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	_charge(bus, "build", sc["initial_build_spend"])
	_upkeep(bus, sc["upkeep_per_day"])
	var cash_by_day: Array = []
	var offered_days: Array = []
	var amounts: Array = []
	var bankrupt_events: Array = []
	var no_show_days: Array = []
	for d: int in range(1, 31):
		if d > 1:
			_new_day(bus, d)
		rec.clear()
		_charge(bus, "guarantee", g)   # book_if_affordable: cash ≥ 400 이면 승인, 아니면 C3 거절
		if _last(rec, "economy.charge_resolved")["approved"]:
			_sales(bus, sc["admissions"], sc["audience"])
		else:
			assert_eq(_last(rec, "economy.charge_resolved")["decline_reason"], "insufficient_cash")
			no_show_days.append(d)
		_close(bus, d)
		cash_by_day.append(_last(rec, "economy.day_settled")["cash"])
		for o: Dictionary in rec.of("economy.bailout_offered"):
			offered_days.append(o["day"])
			amounts.append(o["amount"])
			_accept(bus)   # 제안된 close 에서 바로 수락
		bankrupt_events.append_array(rec.of("economy.bankrupt"))
		if econ.bankrupt:
			break
	assert_eq(cash_by_day, exp["cash_by_day"], "cash_by_day == expected")
	assert_eq(cash_by_day, [4294, 3588, 2882, 2176, 1470, 764, 58, -742, 1882, 764, -354, 1513, 26, -1555], "리터럴")
	assert_eq(offered_days, exp["bailout_offered_days"])
	assert_eq(offered_days, [8, 11], "리터럴")
	assert_eq(amounts, exp["bailout_amounts"])
	assert_eq(amounts, [3742, 3354], "리터럴")
	assert_eq(no_show_days, [8, 14], "개런티 거절일(economy.md 파산 시나리오 표)")
	assert_eq(bankrupt_events, [{"day": exp["bankrupt_day"], "cash": cash_by_day[cash_by_day.size() - 1], "bailouts_used": 2}], "economy.bankrupt 정확히 1회")
	assert_eq(int(exp["bankrupt_day"]), 14, "리터럴 14")
	assert_true(econ.bankrupt)
	assert_eq([econ.day, econ.phase], [14, "close"], "파산일 close")
	# 파산 뒤(SE-016): 지출·환불·매출·유지비·가격·정산·구제 입력은 무시하고 time.* 의 day·phase 추적만 유지.
	var before: String = _hash_without_day_phase(econ)
	rec.clear()
	_charge(bus, "build", 0, "after")
	_refund(bus, 1000)
	_sales(bus, 100, 100)
	_upkeep(bus, 0)
	_command(bus, "economy.ticket_price_requested", {"price": 25})   # 파산일 close 구간에서 처리
	_accept(bus)
	_new_day(bus, 15)
	assert_eq([econ.day, econ.phase], [15, "day"], "파산 뒤에도 time.day_started·phase_changed 를 따라온다")
	_command(bus, "economy.ticket_price_requested", {"price": 30})   # 15일 day 구간에서 처리
	bus.publish("time.phase_changed", {"from": "day", "to": "show", "day": 15, "tick": 14 * _scfg.day_ticks + _scfg.phase_start("show")})
	assert_eq(econ.phase, "show")
	_close(bus, 15)
	assert_eq(econ.day, 15, "day == 15")
	assert_eq(econ.phase, "close", "phase == close")
	assert_eq(_hash_without_day_phase(econ), before, "day·phase 를 뺀 상태 불변(정산·S0·자동 수락 없음)")
	assert_eq(_econ_events(rec), [
		["economy.charge_resolved", {"request_id": "after", "reason": "build", "amount": 0, "approved": false, "decline_reason": "bankrupt", "cash": econ.cash}],
		["economy.ticket_price_rejected", {"price": 25, "reason": "not_allowed", "phase": "close"}],
		["economy.ticket_price_rejected", {"price": 30, "reason": "not_allowed", "phase": "day"}],
	], "지출은 C1 거절, 가격은 not_allowed(처리 시점 구간), 나머지는 이벤트 없음")
	assert_eq(rec.of("economy.ticket_price_rejected")[1]["phase"], "day", "15일 day 구간 요청은 phase == \"day\"(낡은 \"close\" 아님)")
	for ev: String in ["economy.day_settled", "economy.bailout_offered", "economy.bailout_taken", "economy.cash_changed", "economy.bankrupt"]:
		assert_eq(rec.of(ev).size(), 0, "파산 뒤 %s 0건" % ev)
	# 잘못된 time.* 페이로드는 파산 전과 같이 push_warning 후 무시.
	bus.publish("time.day_started", {"day": "x"})
	assert_push_warning("time.day_started 페이로드 무시", "파산 뒤에도 페이로드 검사")
	assert_eq([econ.day, econ.phase], [15, "close"], "잘못된 페이로드는 day 를 바꾸지 않는다")
	# SE-022 AC3: 잘못된 time.phase_changed 페이로드(to 가 문자열이 아님)도 파산 뒤 push_warning 후 무시.
	var before_bad: String = _ehash(econ)
	rec.clear()
	bus.publish("time.phase_changed", {"to": 1, "day": 15})
	assert_push_warning("time.phase_changed 페이로드 무시", "파산 뒤에도 phase_changed 페이로드 검사")
	assert_push_warning_count(2, "day_started 1 + phase_changed 1")
	assert_eq([econ.day, econ.phase], [15, "close"], "잘못된 phase_changed 는 day·phase 를 바꾸지 않는다")
	assert_eq(_ehash(econ), before_bad, "잘못된 phase_changed 뒤 경제 상태 해시 불변")
	assert_eq(_econ_events(rec), [], "잘못된 phase_changed 뒤 economy.* 이벤트 0")


## SE-022 AC4 — restore() 로 만든 bankrupt: true + pending_bailout != null 상태(범위 검사 ⑦ 없음 → 복원 통과,
## producer 결정 로그 2026-10-09). 이어 time.day_started 가 와도 day 만 따라가고 자동 수락하지 않는다
## (economy.md "파산 뒤", _on_day_started 의 `if bankrupt: return` 이 _accept_bailout(true) 앞에 있어야 함).
func test_bankrupt_restore_keeps_pending_bailout() -> void:
	var src: Economy = _econ_with_loan_and_pending()[1]
	var good: Dictionary = _rt(src.snapshot())
	assert_false(good["bankrupt"], "전제: 원본은 파산 아님")
	assert_not_null(good["pending_bailout"], "전제: pending_bailout 있음")
	assert_eq((good["pending_bailout"]["installments"] as Array).size(), int(good["pending_bailout"]["repay_days"]), "전제: installments 개수 == repay_days")
	var s: Dictionary = good.duplicate(true)
	s["bankrupt"] = true
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	assert_true(econ.restore(s), "bankrupt: true + pending_bailout != null 은 복원된다(⑦ 없음)")
	assert_push_error_count(0, "복원 push_error 0")
	assert_true(econ.bankrupt, "전제: 복원 뒤 bankrupt")
	assert_not_null(econ.pending_bailout, "전제: 복원 뒤 pending_bailout 있음")
	var pb0: Dictionary = (econ.pending_bailout as Dictionary).duplicate(true)
	assert_eq(pb0, src.pending_bailout, "전제: 복원한 pending_bailout == 원본")
	var cash0: int = econ.cash
	var rest0: String = _hash_without_day_phase(econ)
	var n: int = econ.day + 1
	assert_eq(n, 3, "리터럴: 복원 day 2 → 다음 날 3")
	rec.clear()
	bus.publish("time.day_started", {"day": n})
	assert_eq(econ.day, n, "파산 뒤에도 day 추적")
	assert_eq(econ.pending_bailout, pb0, "pending_bailout 그대로(자동 수락 없음)")
	assert_eq(rec.of("economy.bailout_taken").size(), 0, "bailout_taken 0건")
	assert_eq(rec.of("economy.cash_changed").size(), 0, "cash_changed 0건")
	assert_eq(econ.cash, cash0, "cash 불변")
	assert_eq(_hash_without_day_phase(econ), rest0, "day·phase 를 뺀 상태 불변")
	assert_eq(_econ_events(rec), [], "economy.* 이벤트 0")
	# 같은 날 close 진입: 파산 뒤라 S0(자동 수락)·정산 없음.
	bus.publish("time.phase_changed", {"from": "close", "to": "day", "day": n, "tick": (n - 1) * _scfg.day_ticks})
	_close(bus, n)
	assert_eq([econ.day, econ.phase], [n, "close"], "phase 추적")
	assert_eq(econ.pending_bailout, pb0, "close 뒤에도 pending_bailout 그대로(S0 없음)")
	assert_eq(_hash_without_day_phase(econ), rest0, "close 뒤에도 day·phase 를 뺀 상태 불변(정산 없음)")
	assert_eq(_econ_events(rec), [], "close 뒤에도 economy.* 이벤트 0")
	assert_push_warning_count(0, "S0 push_warning 없음")


# --- EC13 --------------------------------------------------------------------

func _price(bus: EventBus, payload: Dictionary) -> void:
	_command(bus, "economy.ticket_price_requested", payload)


func test_ticket_price_rules() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	var p0: int = econ.ticket_price
	# P1 비정수
	for pl: Dictionary in [{"price": "20"}, {"price": true}, {"price": null}, {}]:
		rec.clear()
		_price(bus, pl)
		assert_eq(_econ_events(rec), [["economy.ticket_price_rejected", {"price": pl.get("price"), "reason": "invalid", "phase": "day"}]], "P1 %s" % [pl])
	# P3 범위 밖
	var lo: int = int(_row["ticket_price_min"]) - 1
	var hi: int = int(_row["ticket_price_max"]) + 1
	assert_eq([lo, hi], [4, 41], "리터럴 범위 밖 값")
	for v: int in [lo, hi]:
		rec.clear()
		_price(bus, {"price": v})
		assert_eq(_econ_events(rec), [["economy.ticket_price_rejected", {"price": v, "reason": "out_of_range", "phase": "day"}]], "P3 %d" % v)
	assert_eq(econ.ticket_price, p0)
	# P4 같은 값
	rec.clear()
	_price(bus, {"price": p0})
	assert_eq(rec.events, [], "P4 같은 값 무시")
	# P5 정상
	_price(bus, {"price": 25})
	assert_eq(_econ_events(rec), [["economy.ticket_price_changed", {"price": 25, "from": p0}]], "P5")
	assert_eq(econ.ticket_price, 25)
	# P2 낮 아닌 구간
	bus.publish("time.phase_changed", {"from": "day", "to": "evening", "day": 1, "tick": _scfg.phase_start("evening")})
	rec.clear()
	_price(bus, {"price": 30})
	assert_eq(_econ_events(rec), [["economy.ticket_price_rejected", {"price": 30, "reason": "not_allowed", "phase": "evening"}]], "P2 evening")
	assert_eq(econ.ticket_price, 25)
	# float 명령은 버스가 거부(tick.md E4).
	var before: String = _ehash(econ)
	rec.clear()
	assert_false(bus.publish("economy.ticket_price_requested", {"price": 25.0}), "25.0 → publish false")
	assert_push_error_count(1)
	assert_false(bus.publish("economy.ticket_price_requested", {"price": 25.5}), "25.5 → publish false")
	assert_push_error_count(2)
	bus.dispatch_commands()
	assert_eq(_econ_events(rec), [], "ticket_price_* 이벤트 0개")
	assert_eq(_ehash(econ), before, "상태 해시 불변")
	# 파산 뒤(낮 구간이어도) not_allowed.
	var s: Dictionary = econ.snapshot()
	s["bankrupt"] = true
	s["phase"] = "day"
	assert_true(econ.restore(s))
	rec.clear()
	_price(bus, {"price": 30})
	assert_eq(_econ_events(rec), [["economy.ticket_price_rejected", {"price": 30, "reason": "not_allowed", "phase": "day"}]], "파산 뒤 not_allowed")


# --- EC14 --------------------------------------------------------------------

## close 진입 틱(phase_changed {to:"close"} ~ tick.advanced)의 이벤트.
func _close_tick_events(rec: EventRecorder) -> Array:
	var out: Array = []
	var on: bool = false
	for e: Array in rec.events:
		if e[0] == "time.phase_changed" and e[1]["to"] == "close":
			on = true
		if on:
			out.append(e)
			if e[0] == "tick.advanced":
				break
	return out


func test_settlement_event_order() -> void:
	# (a) 구제 제안
	var l: Array = _looped()
	_charge((l[0] as TickLoop).bus, "build", _deficit_build((l[1] as Economy).cash))
	(l[0] as TickLoop).advance(_scfg.day_ticks)
	var ev: Array = _close_tick_events(l[2])
	assert_eq(_names(ev), ["time.phase_changed", "economy.cash_changed", "economy.day_settled", "economy.bailout_offered", "time.speed_changed", "tick.advanced"], "구제 제안 순서")
	assert_eq(ev[1][1]["reason"], "settlement")
	assert_eq(ev[4][1]["speed"], 0)
	# (b) 파산
	var d: Dictionary = _raw()
	d["bailout_count"] = 0
	l = _looped(42, EconomyConfig.from_dict(d))
	_charge((l[0] as TickLoop).bus, "build", _deficit_build((l[1] as Economy).cash))
	(l[0] as TickLoop).advance(_scfg.day_ticks)
	ev = _close_tick_events(l[2])
	assert_eq(_names(ev), ["time.phase_changed", "economy.cash_changed", "economy.day_settled", "economy.bankrupt", "time.speed_changed", "tick.advanced"], "파산 순서")
	# (c) settlement_delta == 0 → cash_changed 없음: 티켓 매출 = 임대료, 바 0.
	var rent: int = _row["rent_per_day"]
	var price: int = _row["ticket_price_default"]
	assert_eq(rent % price, 0, "전제: 임대료가 티켓가로 나누어떨어진다")
	l = _looped()
	_sales((l[0] as TickLoop).bus, rent / price, 0)
	(l[0] as TickLoop).advance(_scfg.day_ticks)
	ev = _close_tick_events(l[2])
	assert_eq(_names(ev), ["time.phase_changed", "economy.day_settled", "time.speed_changed", "tick.advanced"], "delta 0 이면 cash_changed 없음")
	assert_eq(ev[1][1]["settlement_delta"], 0)
	# (d) 흑자: 제안·파산 없음
	l = _looped()
	_sales((l[0] as TickLoop).bus, 100, 100)
	(l[0] as TickLoop).advance(_scfg.day_ticks)
	ev = _close_tick_events(l[2])
	assert_eq(_names(ev), ["time.phase_changed", "economy.cash_changed", "economy.day_settled", "time.speed_changed", "tick.advanced"])


# --- EC15 --------------------------------------------------------------------

## 고정 입력 열로 4일을 돌린다(지출·매출·가격 명령·구제 자동 수락 포함).
func _scripted_run() -> Dictionary:
	var l: Array = _looped(42)
	var loop: TickLoop = l[0]
	var econ: Economy = l[1]
	var rec: EventRecorder = l[2]
	var rng0: String = loop.rng.get_state()["economy"]
	var g: int = _cfg.guarantee("local")
	_charge(loop.bus, "build", 1000)
	_charge(loop.bus, "guarantee", g)
	_upkeep(loop.bus, 150)
	loop.bus.publish("economy.ticket_price_requested", {"price": 25})
	loop.advance(_scfg.phase_start("show"))
	_sales(loop.bus, 80, 80)
	loop.advance(_scfg.day_ticks)
	var rng_after_settle: String = loop.rng.get_state()["economy"]
	for d: int in [2, 3, 4]:
		loop.bus.publish("time.next_day_requested", {})
		loop.advance(0)
		if d == 3:
			_charge(loop.bus, "build", econ.cash)   # 정산 뒤 음수 → 구제 제안 → 4일 자동 수락
		else:
			_charge(loop.bus, "guarantee", g)
			_sales(loop.bus, 90, 85)
		loop.advance(_scfg.day_ticks)
	return {
		"events": JSON.stringify(_econ_events(rec), "", true),
		"hash": _lhash(loop),
		"rng0": rng0,
		"rng_after_settle": rng_after_settle,
		"rng_end": loop.rng.get_state()["economy"],
		"has_econ": loop.snapshot()["systems"].has("economy"),
		"loans": econ.loans.size(),
	}


func test_determinism_no_rng() -> void:
	var a: Dictionary = _scripted_run()
	var b: Dictionary = _scripted_run()
	assert_true(a["has_econ"], "스냅샷에 systems.economy")
	assert_eq(a["loans"], 1, "준비: 구제가 실제로 일어났다")
	assert_eq(a["events"], b["events"], "economy.* 이벤트 열 동일")
	assert_eq(a["hash"], b["hash"], "TickLoop 상태 해시(systems.economy 포함) 동일")
	assert_eq(a["rng_after_settle"], a["rng0"], "정산 전후 economy 스트림 불변")
	assert_eq(a["rng_end"], a["rng0"], "4일 내내 economy 스트림 불변")


# --- EC16 --------------------------------------------------------------------

## 1일 구제 수락 → 2일 정산에서 1회차 상환 + 두 번째 구제 제안(pending) 상태까지(단위 버스).
func _econ_with_loan_and_pending() -> Array:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	_charge(bus, "build", _deficit_build(econ.cash))
	_close(bus, 1)
	_accept(bus)
	_new_day(bus, 2)
	_charge(bus, "build", econ.cash - TEST_DEFICIT)
	_close(bus, 2)
	return u


## 복원 뒤 양쪽에 똑같이 주는 입력 열(단위 버스).
func _feed(bus: EventBus) -> void:
	_new_day(bus, 3)   # pending 자동 수락
	_charge(bus, "guarantee", _cfg.guarantee("local"))
	_sales(bus, 100, 100)
	_upkeep(bus, 50)
	_close(bus, 3)
	_new_day(bus, 4)
	_sales(bus, 60, 60)
	_close(bus, 4)


## 복원 뒤 양쪽 TickLoop 에 똑같이 주는 입력 열.
func _feed_loop(loop: TickLoop) -> void:
	loop.bus.publish("time.next_day_requested", {})
	loop.advance(0)
	_charge(loop.bus, "guarantee", _cfg.guarantee("local"))
	_sales(loop.bus, 100, 100)
	loop.advance(_scfg.day_ticks)


func test_snapshot_roundtrip() -> void:
	# (a) Economy 단독 왕복
	var ua: Array = _econ_with_loan_and_pending()
	var econ_a: Economy = ua[1]
	var rec_a: EventRecorder = ua[2]
	assert_eq(econ_a.loans.size(), 1, "전제: loans 1개")
	assert_gte(int(econ_a.loans[0]["paid"]), 1, "전제: paid ≥ 1")
	assert_not_null(econ_a.pending_bailout, "전제: pending_bailout 있음")
	var s: Dictionary = _rt(econ_a.snapshot())
	assert_eq(JSON.stringify(econ_a.snapshot(), "", true), _ehash(econ_a), "snapshot 두 번 호출 동일(SH1)")
	var ub: Array = _unit()
	var econ_b: Economy = ub[1]
	var rec_b: EventRecorder = ub[2]
	assert_true(econ_b.restore(s), "JSON 왕복 스냅샷 복원")
	assert_eq(rec_b.events, [], "복원은 이벤트를 내지 않는다")
	assert_eq(_ehash(econ_b), _ehash(econ_a), "복원 직후 해시 동일(SH6)")
	assert_typeof(econ_b.loans[0]["installments"][0], TYPE_INT, "installments 정수 정규화")
	rec_a.clear()
	_feed(ua[0])
	_feed(ub[0])
	assert_eq(_ehash(econ_b), _ehash(econ_a), "복원 후 진행 == 연속 진행")
	assert_eq(_econ_events(rec_b), _econ_events(rec_a), "economy.* 이벤트 열 동일")

	# (b) TickLoop 수준 왕복
	var la: Array = _looped(42)
	var loop_a: TickLoop = la[0]
	var e_a: Economy = la[1]
	var r_a: EventRecorder = la[2]
	_charge(loop_a.bus, "build", _deficit_build(e_a.cash))
	loop_a.advance(_scfg.day_ticks)
	loop_a.bus.publish("economy.bailout_accept_requested", {})
	loop_a.advance(0)
	loop_a.bus.publish("time.next_day_requested", {})
	loop_a.advance(0)
	_charge(loop_a.bus, "build", e_a.cash - TEST_DEFICIT)
	loop_a.advance(_scfg.day_ticks)
	assert_eq([e_a.loans.size(), e_a.loans[0]["paid"], e_a.pending_bailout != null], [1, 1, true], "전제: 대출 진행 중 + pending")
	var snap: Dictionary = loop_a.snapshot()
	assert_false(snap.has("economy"), "최상위 economy 키 없음")
	assert_eq(snap["systems"].keys(), ["economy"])
	assert_eq(JSON.stringify(snap["systems"]["economy"], "", true), _ehash(e_a), "systems.economy == Economy.snapshot()")
	var parsed: Dictionary = _rt(snap)
	var lb: Array = _looped(7)
	var loop_b: TickLoop = lb[0]
	var e_b: Economy = lb[1]
	var r_b: EventRecorder = lb[2]
	assert_true(loop_b.restore(parsed), "TickLoop.restore true")
	assert_eq(r_b.events, [], "복원 중 이벤트 0개")
	assert_eq(_lhash(loop_b), _lhash(loop_a), "복원 직후 TickLoop 해시 동일")
	r_a.clear()
	_feed_loop(loop_a)
	_feed_loop(loop_b)
	assert_eq(_lhash(loop_b), _lhash(loop_a), "복원 후 진행 == 연속 진행(systems.economy 포함)")
	assert_eq(_econ_events(r_b), _econ_events(r_a), "economy.* 이벤트 열 동일")
	assert_eq(_ehash(e_b), _ehash(e_a))

	# (c) 잘못된 스냅샷: Economy.restore false·상태 불변, TickLoop.restore false·양쪽 해시 불변, 이벤트 0개.
	var good: Dictionary = _rt(econ_a.snapshot())
	var bads: Dictionary = {}
	var x: Dictionary = good.duplicate(true)
	x.erase("cash")
	bads["필드 누락"] = x
	x = good.duplicate(true)
	x["loans"][0]["installments"][0] = 1.5
	bads["installments 1.5"] = x
	x = good.duplicate(true)
	x["cash"] = "100"
	bads["cash 문자열"] = x
	var errs: int = 0
	for label: String in bads:
		var before_e: String = _ehash(econ_b)
		rec_b.clear()
		assert_false(econ_b.restore(bads[label]), "Economy: %s → false" % label)
		errs += 1
		assert_push_error_count(errs, label + ": push_error 1회")
		assert_eq(_ehash(econ_b), before_e, label + ": 상태 불변")
		assert_eq(rec_b.events, [], label + ": 이벤트 0개")
	for label: String in bads:
		var sb: Dictionary = parsed.duplicate(true)
		sb["systems"]["economy"] = bads[label]
		var before_l: String = _lhash(loop_b)
		var before_eb: String = _ehash(e_b)
		r_b.clear()
		assert_false(loop_b.restore(sb), "TickLoop: %s → false" % label)
		errs += 2   # Economy.restore 1 + TickLoop 7단계 1
		assert_push_error_count(errs, label + ": push_error 2회(시스템 + TickLoop)")
		assert_eq(_lhash(loop_b), before_l, label + ": TickLoop 해시 불변")
		assert_eq(_ehash(e_b), before_eb, label + ": Economy 해시 불변")
		assert_eq(r_b.events, [], label + ": 이벤트 0개")


## SE-015 EC16 (c) 범위 검사 ①~⑥ (economy.md #스냅샷 "범위 검사"). 정상 스냅샷을 duplicate(true) 한 뒤
## 필드 하나만 범위 밖으로 바꾼 사본. 각 사본이 의도한 검사에서 걸리는지 push_error 문구 일부로 확인한다.
func test_restore_rejects_out_of_range() -> void:
	var ua: Array = _econ_with_loan_and_pending()
	var good: Dictionary = _rt((ua[1] as Economy).snapshot())
	var loan_n: int = (good["loans"][0]["installments"] as Array).size()
	assert_eq(good["loans"].size(), 1, "전제: loans 1개")
	assert_gte(int(good["loans"][0]["paid"]), 1, "전제: paid ≥ 1")
	assert_lt(int(good["loans"][0]["paid"]), loan_n, "전제: paid < installments 개수")
	assert_not_null(good["pending_bailout"], "전제: pending_bailout 있음")
	assert_eq((good["pending_bailout"]["installments"] as Array).size(), int(good["pending_bailout"]["repay_days"]), "전제: installments 개수 == repay_days")
	assert_gte(int(good["pending_bailout"]["repay_days"]), 2, "전제: 한 개 빼도 비어 있지 않음(⑤가 타입 검사가 아니라 범위 검사에 걸리게)")
	assert_false(_cfg.has_row(99), "전제: tier 99 행 없음")
	var control: Economy = (_unit()[1] as Economy)
	assert_true(control.restore(good.duplicate(true)), "전제: 바꾸지 않은 사본은 복원된다")

	# [라벨, 사본, push_error 문구 일부]
	var bads: Array = []
	var x: Dictionary = good.duplicate(true)
	x["tier"] = 99
	bads.append(["① tier = 99", x, "경제 행이 없다"])
	x = good.duplicate(true)
	x["day"] = 0
	bads.append(["② day = 0", x, "범위 밖 값"])
	for key: String in ["ticket_price", "upkeep_per_day", "last_settled_day", "bailouts_left"]:
		x = good.duplicate(true)
		x[key] = -1
		bads.append(["③ %s = -1" % key, x, "범위 밖 값"])
	for key: String in EconomyConfig.LEDGER_KEYS:
		x = good.duplicate(true)
		x["ledger"][key] = -1
		bads.append(["④ ledger.%s = -1" % key, x, "ledger.%s 가 0 이상" % key])
	x = good.duplicate(true)
	(x["pending_bailout"]["installments"] as Array).pop_back()
	bads.append(["⑤ pending_bailout.installments 한 개 뺌", x, "installments 개수가 repay_days 와 다르다"])
	x = good.duplicate(true)
	x["loans"][0]["paid"] = loan_n
	bads.append(["⑥ loans[0].paid = installments 개수", x, "loans[].paid 가 0 이상"])
	x = good.duplicate(true)
	x["loans"][0]["paid"] = -1
	bads.append(["⑥ loans[0].paid = -1", x, "loans[].paid 가 0 이상"])
	assert_eq(bads.size(), 12, "①1 + ②1 + ③4 + ④3 + ⑤1 + ⑥2")

	# Economy 단독: false, push_error 정확히 1회, 해시 불변, 이벤트 0.
	var ub: Array = _unit()
	var econ_b: Economy = ub[1]
	var rec_b: EventRecorder = ub[2]
	var errs: int = 0
	for b: Array in bads:
		var label: String = b[0]
		var before_e: String = _ehash(econ_b)
		rec_b.clear()
		assert_false(econ_b.restore(b[1]), "Economy: %s → false" % label)
		errs += 1
		assert_push_error(b[2], label + ": 의도한 범위 검사에서 거부")
		assert_push_error_count(errs, label + ": push_error 1회")
		assert_eq(_ehash(econ_b), before_e, label + ": 상태 불변")
		assert_eq(rec_b.events, [], label + ": 이벤트 0개")

	# TickLoop 경로(②·⑥): systems.economy 에 넣은 스냅샷 → false, 양쪽 해시 불변, push_error 2회.
	var base: Dictionary = _rt((_looped(42)[0] as TickLoop).snapshot())
	var lc: Array = _looped(7)
	var ok_snap: Dictionary = base.duplicate(true)
	ok_snap["systems"]["economy"] = good.duplicate(true)
	assert_true((lc[0] as TickLoop).restore(ok_snap), "전제: 같은 TickLoop 스냅샷에 정상 economy 면 복원된다")
	var lb: Array = _looped(7)
	var loop_b: TickLoop = lb[0]
	var e_b: Economy = lb[1]
	var r_b: EventRecorder = lb[2]
	for i: int in [1, 10, 11]:   # ② day = 0, ⑥ paid = 개수, ⑥ paid = -1
		var label: String = bads[i][0]
		var sb: Dictionary = base.duplicate(true)
		sb["systems"]["economy"] = (bads[i][1] as Dictionary).duplicate(true)
		var before_l: String = _lhash(loop_b)
		var before_eb: String = _ehash(e_b)
		r_b.clear()
		assert_false(loop_b.restore(sb), "TickLoop: %s → false" % label)
		errs += 2   # Economy.restore 1 + TickLoop 7단계 1
		assert_push_error(bads[i][2], label + ": Economy 의 범위 검사 문구")
		assert_push_error_count(errs, label + ": push_error 2회(시스템 + TickLoop)")
		assert_eq(_lhash(loop_b), before_l, label + ": TickLoop 해시 불변")
		assert_eq(_ehash(e_b), before_eb, label + ": Economy 해시 불변")
		assert_eq(r_b.events, [], label + ": 이벤트 0개")


## SE-044 AC5 (docs/reviews/SE-032.md 발견 4): time.phase_changed 의 to 가 구간 id(SimConfig.PHASE_IDS = sim.json phases)가
## 아니면 push_error 1회, day·phase 를 포함해 상태 불변, 이벤트 0, 자기 스냅샷 왕복 true. close 정산도 일어나지 않는다.
func test_unknown_phase_ignored() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var econ: Economy = u[1]
	var rec: EventRecorder = u[2]
	_charge(bus, "build", 1)
	assert_eq(econ.cash, _cfg.starting_cash - 1, "전제: 새 게임과 다른 상태")
	var before: String = _ehash(econ)
	rec.clear()
	bus.publish("time.phase_changed", {"from": "show", "to": "nope", "day": 2, "tick": 0})
	assert_push_error_count(1, "모르는 to → push_error 1회")
	assert_eq([econ.day, econ.phase], [1, "day"], "day·phase 불변")
	assert_eq(_ehash(econ), before, "상태 불변")
	assert_eq(_econ_events(rec), [], "economy.* 이벤트 0(정산 없음)")
	assert_true(econ.restore(_rt(econ.snapshot())), "자기 스냅샷 왕복 true")
	assert_eq(_ehash(econ), before)
	_close(bus, 1)
	assert_eq(econ.phase, "close", "그 뒤 정상 구간은 따라간다")
	assert_eq(rec.count("economy.day_settled"), 1, "정상 close 는 정산")
