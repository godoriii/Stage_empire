class_name Economy
extends RefCounted
## 경제 시스템 v0 (SE-012). 규칙: docs/gdd/economy.md (R1~R6, 입력 계약, C1~C4, F1~F3, S1~S17, B1~B3, P1~P5,
## #스냅샷). 이벤트: docs/gdd/events.md 의 economy.* 행.
##
## - 현금(cash)은 이 시스템만 바꾼다. 다른 시스템은 이벤트로 지출·환불·매출을 제안·보고만 한다.
## - 입력은 생성자에서 구독한 이벤트뿐이다(다른 시스템 직접 호출 없음). 생성자는 이벤트를 내지 않는다.
## - 정산은 time.phase_changed {to:"close"} 핸들러(tick.md 한 틱의 단계 4)에서 날마다 1회.
## - 모든 금액은 int, 비율은 rate_scale 분의 정수(bp). 난수를 쓰지 않는다. 수치는 전부 EconomyConfig 에서.
## - TickLoop 에는 register_system("economy", update, snapshot, restore) 로 등록한다(update 는 no-op).

# 상태 이벤트(발행)
const EV_CASH_CHANGED: String = "economy.cash_changed"
const EV_CHARGE_RESOLVED: String = "economy.charge_resolved"
const EV_PRICE_CHANGED: String = "economy.ticket_price_changed"
const EV_PRICE_REJECTED: String = "economy.ticket_price_rejected"
const EV_DAY_SETTLED: String = "economy.day_settled"
const EV_BAILOUT_OFFERED: String = "economy.bailout_offered"
const EV_BAILOUT_TAKEN: String = "economy.bailout_taken"
const EV_BANKRUPT: String = "economy.bankrupt"
# 입력(구독): 상태 이벤트 4종 + 명령 2종 + 시간 2종
const EV_CHARGE_PROPOSED: String = "economy.charge_proposed"
const EV_REFUND_PROPOSED: String = "economy.refund_proposed"
const EV_SALES_REPORTED: String = "economy.sales_reported"
const EV_UPKEEP_REPORTED: String = "economy.upkeep_reported"
const CMD_TICKET_PRICE: String = "economy.ticket_price_requested"
const CMD_BAILOUT_ACCEPT: String = "economy.bailout_accept_requested"
const EV_PHASE_CHANGED: String = "time.phase_changed"
const EV_DAY_STARTED: String = "time.day_started"

# 페이로드 문자열 값(events.md)
const REASON_SETTLEMENT: String = "settlement"
const REASON_BAILOUT: String = "bailout"
const REASON_DEMOLISH_REFUND: String = "demolish_refund"
const REFUND_REASON_DEMOLISH: String = "demolish"
const DECLINE_NONE: String = ""
const DECLINE_BANKRUPT: String = "bankrupt"
const DECLINE_INVALID: String = "invalid"
const DECLINE_INSUFFICIENT: String = "insufficient_cash"
const PRICE_INVALID: String = "invalid"
const PRICE_NOT_ALLOWED: String = "not_allowed"
const PRICE_OUT_OF_RANGE: String = "out_of_range"
const KIND_LOAN: String = "loan"
const PHASE_DAY: String = "day"
const PHASE_CLOSE: String = "close"
## 새 게임 날(tick.md 카운터 표 "day 새 게임 1").
const NEW_GAME_DAY: int = 1

const LEDGER_ADMISSIONS: String = "admissions"
const LEDGER_AUDIENCE: String = "audience"
const LEDGER_GUARANTEE: String = "guarantee"
## snapshot() 의 키(economy.md #상태 표).
const SNAPSHOT_FIELDS: Array[String] = [
	"cash", "tier", "day", "phase", "ticket_price", "upkeep_per_day", "ledger", "last_settled_day",
	"bailouts_left", "pending_bailout", "loans", "bankrupt",
]
const PENDING_INT_FIELDS: Array[String] = ["day", "deficit", "amount", "interest", "total_due", "repay_days"]
const LOAN_INT_FIELDS: Array[String] = ["day_taken", "amount", "total_due", "paid"]

var config: EconomyConfig
var bus: EventBus

# 상태 (읽기 전용으로 취급한다. 바꾸는 것은 Economy 자신뿐)
var cash: int = 0
var tier: int = 0
var day: int = 0
var phase: String = ""
var ticket_price: int = 0
var upkeep_per_day: int = 0
var ledger: Dictionary = {}
var last_settled_day: int = 0
var bailouts_left: int = 0
## null 또는 {day, kind, deficit, amount, interest, total_due, repay_days, installments}
var pending_bailout: Variant = null
## 원소 {day_taken, amount, total_due, installments: Array(int), paid: int}, 받은 순서.
var loans: Array = []
var bankrupt: bool = false


## 새 게임 상태로 만들고 입력 이벤트를 구독한다. 이벤트를 내지 않는다.
func _init(p_config: EconomyConfig, p_bus: EventBus) -> void:
	if p_config == null or p_bus == null:
		push_error("[Economy] config 와 bus 가 필요하다")
		return
	config = p_config
	bus = p_bus
	tier = EconomyConfig.START_TIER
	cash = config.starting_cash
	day = NEW_GAME_DAY
	phase = PHASE_DAY
	ticket_price = config.row(tier)["ticket_price_default"]
	upkeep_per_day = 0
	ledger = _new_ledger()
	last_settled_day = 0
	bailouts_left = config.bailout_count
	pending_bailout = null
	loans = []
	bankrupt = false
	bus.subscribe(EV_CHARGE_PROPOSED, _on_charge_proposed)
	bus.subscribe(EV_REFUND_PROPOSED, _on_refund_proposed)
	bus.subscribe(EV_SALES_REPORTED, _on_sales_reported)
	bus.subscribe(EV_UPKEEP_REPORTED, _on_upkeep_reported)
	bus.subscribe(CMD_TICKET_PRICE, _on_ticket_price_requested)
	bus.subscribe(CMD_BAILOUT_ACCEPT, _on_bailout_accept_requested)
	bus.subscribe(EV_PHASE_CHANGED, _on_phase_changed)
	bus.subscribe(EV_DAY_STARTED, _on_day_started)


## TickLoop 단계 2. v0 는 틱마다 할 일이 없다(등록은 스냅샷 훅 때문에 필수).
func update(_ctx: Dictionary) -> void:
	pass


## #상태 표의 필드 전부(기본형, 깊은 복사). 상태를 바꾸지 않고 이벤트를 내지 않는다(SH1, SH4).
func snapshot() -> Dictionary:
	return {
		"cash": cash,
		"tier": tier,
		"day": day,
		"phase": phase,
		"ticket_price": ticket_price,
		"upkeep_per_day": upkeep_per_day,
		"ledger": ledger.duplicate(true),
		"last_settled_day": last_settled_day,
		"bailouts_left": bailouts_left,
		"pending_bailout": (pending_bailout as Dictionary).duplicate(true) if pending_bailout != null else null,
		"loans": loans.duplicate(true),
		"bankrupt": bankrupt,
	}


## snapshot() 결과(JSON 왕복 포함)를 적용한다. 정수값 float 는 int 로 정규화. 필드가 빠졌거나 타입·범위가
## 틀리면 push_error 1회, false, 상태 불변. 이벤트를 내지 않는다(SH3, SH4).
func restore(d: Dictionary) -> bool:
	var parsed: Variant = _parse_snapshot(d)
	if parsed is String:
		push_error("[Economy] restore: " + String(parsed))
		return false
	var s: Dictionary = parsed
	cash = s["cash"]
	tier = s["tier"]
	day = s["day"]
	phase = s["phase"]
	ticket_price = s["ticket_price"]
	upkeep_per_day = s["upkeep_per_day"]
	ledger = s["ledger"]
	last_settled_day = s["last_settled_day"]
	bailouts_left = s["bailouts_left"]
	pending_bailout = s["pending_bailout"]
	loans = s["loans"]
	bankrupt = s["bankrupt"]
	return true


## 정산 S1~S12, S14 (순수 함수, 상태 불변). inputs = {ticket_price, admissions, audience, upkeep, guarantee,
## loan_repayment}. 반환 = economy.day_settled 페이로드에서 day·cash 를 뺀 키.
static func compute_settlement(row: Dictionary, rate_scale: int, inputs: Dictionary) -> Dictionary:
	var price: int = inputs["ticket_price"]
	var admissions: int = inputs["admissions"]
	var audience: int = inputs["audience"]
	var upkeep: int = inputs["upkeep"]
	var guarantee: int = inputs["guarantee"]
	var loan_repayment: int = inputs["loan_repayment"]
	var ticket_revenue: int = price * admissions                                              # S1
	var bar_buyers: int = audience * int(row["bar_purchase_rate_bp"]) / rate_scale             # S2
	var bar_revenue: int = bar_buyers * int(row["bar_avg_spend"])                              # S3
	var bar_cost: int = bar_revenue * int(row["bar_cost_rate_bp"]) / rate_scale                # S4
	var revenue: int = ticket_revenue + bar_revenue                                            # S5
	var rent: int = row["rent_per_day"]                                                        # S6
	var operating_costs: int = bar_cost + rent + upkeep + guarantee                            # S7~S9
	var pretax: int = revenue - operating_costs                                                # S10
	var tax: int = maxi(0, pretax) * int(row["tax_rate_bp"]) / rate_scale                      # S11
	var net: int = pretax - tax                                                                # S12
	var settlement_delta: int = revenue - bar_cost - rent - upkeep - tax - loan_repayment      # S14
	return {
		"ticket_price": price,
		"admissions": admissions,
		"audience": audience,
		"ticket_revenue": ticket_revenue,
		"bar_buyers": bar_buyers,
		"bar_revenue": bar_revenue,
		"bar_cost": bar_cost,
		"revenue": revenue,
		"rent": rent,
		"upkeep": upkeep,
		"guarantee": guarantee,
		"operating_costs": operating_costs,
		"pretax": pretax,
		"tax": tax,
		"net": net,
		"loan_repayment": loan_repayment,
		"settlement_delta": settlement_delta,
	}


## R5: total 을 n 회차로. 앞의 total mod n 회차가 q + 1, 나머지가 q (q = total ÷ n). 합 = total.
static func split_installments(total: int, n: int) -> Array:
	var q: int = total / n
	var r: int = total % n
	var out: Array = []
	for k: int in n:
		out.append(q + 1 if k < r else q)
	return out


# --- 입력 핸들러 ----------------------------------------------------------------

## 지출 판정 C1~C4. 항상 charge_resolved 1개(승인이고 amount > 0 이면 cash_changed 가 먼저).
func _on_charge_proposed(p: Dictionary) -> void:
	var rid: String = _str_or_empty(p.get("request_id"))
	var reason: String = _str_or_empty(p.get("reason"))
	var amount: Variant = EconomyConfig.as_int(p.get("amount"))
	var amount_out: int = amount if amount != null else 0
	if bankrupt:                                                                               # C1
		_resolve_charge(rid, reason, amount_out, DECLINE_BANKRUPT)
		return
	if not config.charge_reasons.has(reason) or amount == null or amount < 0:               # C2
		_resolve_charge(rid, reason, amount_out, DECLINE_INVALID)
		return
	if cash < amount:                                                                          # C3
		_resolve_charge(rid, reason, amount_out, DECLINE_INSUFFICIENT)
		return
	cash -= amount                                                                             # C4
	if config.charge_reasons[reason] == EconomyConfig.CLASS_OPERATING:
		if ledger.has(reason):
			ledger[reason] = int(ledger[reason]) + amount
		else:
			push_error("[Economy] operating 사유 '%s' 의 ledger 항목이 없다(v0 는 guarantee 만)" % reason)
	if amount > 0:
		bus.publish(EV_CASH_CHANGED, {"cash": cash, "delta": -amount, "reason": reason})
	_resolve_charge(rid, reason, amount, DECLINE_NONE)


func _resolve_charge(rid: String, reason: String, amount: int, decline: String) -> void:
	bus.publish(EV_CHARGE_RESOLVED, {
		"request_id": rid, "reason": reason, "amount": amount,
		"approved": decline == DECLINE_NONE, "decline_reason": decline, "cash": cash,
	})


## 환불 F1~F3.
func _on_refund_proposed(p: Dictionary) -> void:
	if bankrupt:                                                                               # F1
		return
	var base: Variant = EconomyConfig.as_int(p.get("base_amount"))
	if p.get("reason") != REFUND_REASON_DEMOLISH or base == null or base < 0:                # F2
		push_warning("[Economy] refund_proposed 무시: reason=%s base_amount=%s" % [p.get("reason"), p.get("base_amount")])
		return
	var refund: int = int(base) * config.demolish_refund_rate_bp / config.rate_scale          # F3
	cash += refund
	if refund > 0:
		bus.publish(EV_CASH_CHANGED, {"cash": cash, "delta": refund, "reason": REASON_DEMOLISH_REFUND})


## 매출 보고: ledger 누적. 이벤트 없음.
func _on_sales_reported(p: Dictionary) -> void:
	if bankrupt:
		return
	var adm: Variant = EconomyConfig.as_int(p.get("admissions"))
	var aud: Variant = EconomyConfig.as_int(p.get("audience"))
	if adm == null or aud == null or adm < 0 or aud < 0:
		push_warning("[Economy] sales_reported 무시: %s" % [p])
		return
	ledger[LEDGER_ADMISSIONS] = int(ledger[LEDGER_ADMISSIONS]) + adm
	ledger[LEDGER_AUDIENCE] = int(ledger[LEDGER_AUDIENCE]) + aud


## 유지비 보고: upkeep_per_day 교체. 이벤트 없음.
func _on_upkeep_reported(p: Dictionary) -> void:
	if bankrupt:
		return
	var total: Variant = EconomyConfig.as_int(p.get("total"))
	if total == null or total < 0:
		push_warning("[Economy] upkeep_reported 무시: %s" % [p])
		return
	upkeep_per_day = total


## 티켓 가격 P1~P5 (명령, 경계 처리에서 전달된다).
func _on_ticket_price_requested(p: Dictionary) -> void:
	var raw: Variant = p.get("price")
	if not p.has("price") or not (raw is int):                                                # P1
		_reject_price(raw, PRICE_INVALID)
		return
	var price: int = raw
	if bankrupt or phase != PHASE_DAY:                                                         # P2
		_reject_price(price, PRICE_NOT_ALLOWED)
		return
	var r: Dictionary = config.row(tier)
	if price < int(r["ticket_price_min"]) or price > int(r["ticket_price_max"]):             # P3
		_reject_price(price, PRICE_OUT_OF_RANGE)
		return
	if price == ticket_price:                                                                  # P4
		return
	var from: int = ticket_price                                                               # P5
	ticket_price = price
	bus.publish(EV_PRICE_CHANGED, {"price": price, "from": from})


func _reject_price(value: Variant, reason: String) -> void:
	bus.publish(EV_PRICE_REJECTED, {"price": value, "reason": reason, "phase": phase})


## 구제 수동 수락(명령). 제안 중이 아니면 무시.
func _on_bailout_accept_requested(_p: Dictionary) -> void:
	if bankrupt or pending_bailout == null:
		return
	_accept_bailout(false)


## phase·day 추적. close 진입이면 정산(1회성).
func _on_phase_changed(p: Dictionary) -> void:
	if bankrupt:
		return
	var to: Variant = p.get("to")
	var d: Variant = EconomyConfig.as_int(p.get("day"))
	if not (to is String) or d == null:
		push_warning("[Economy] time.phase_changed 페이로드 무시: %s" % [p])
		return
	phase = to
	day = d
	if phase == PHASE_CLOSE and last_settled_day != d:
		_settle(d)


## day 추적. 제안 중인 구제는 자동 수락(auto: true).
func _on_day_started(p: Dictionary) -> void:
	if bankrupt:
		return
	var d: Variant = EconomyConfig.as_int(p.get("day"))
	if d == null:
		push_warning("[Economy] time.day_started 페이로드 무시: %s" % [p])
		return
	day = d
	if pending_bailout != null:
		_accept_bailout(true)


# --- 정산·구제 ------------------------------------------------------------------

## S1~S17. 상태를 전부 갱신한 뒤 cash_changed(≠0) → day_settled → bailout_offered | bankrupt.
func _settle(d: int) -> void:
	var repayment: int = 0                                                                     # S13
	var kept: Array = []
	for loan: Dictionary in loans:
		var inst: Array = loan["installments"]
		var paid: int = loan["paid"]
		repayment += int(inst[paid])
		loan["paid"] = paid + 1
		if paid + 1 < inst.size():
			kept.append(loan)
	loans = kept
	var r: Dictionary = compute_settlement(config.row(tier), config.rate_scale, {
		"ticket_price": ticket_price,
		"admissions": ledger[LEDGER_ADMISSIONS],
		"audience": ledger[LEDGER_AUDIENCE],
		"upkeep": upkeep_per_day,
		"guarantee": ledger[LEDGER_GUARANTEE],
		"loan_repayment": repayment,
	})
	var delta: int = r["settlement_delta"]
	cash += delta                                                                              # S15
	last_settled_day = d                                                                       # S16
	ledger = _new_ledger()
	var offer: Dictionary = {}                                                                 # S17
	var went_bankrupt: bool = false
	if cash < 0:
		if bailouts_left > 0:                                                                  # B2
			pending_bailout = _make_offer(d)
			offer = pending_bailout
		else:                                                                                  # B3
			bankrupt = true
			went_bankrupt = true
	if delta != 0:
		bus.publish(EV_CASH_CHANGED, {"cash": cash, "delta": delta, "reason": REASON_SETTLEMENT})
	var settled: Dictionary = r.duplicate()
	settled["day"] = d
	settled["cash"] = cash
	bus.publish(EV_DAY_SETTLED, settled)
	if not offer.is_empty():
		var inst: Array = offer["installments"]
		bus.publish(EV_BAILOUT_OFFERED, {
			"day": offer["day"], "kind": offer["kind"], "deficit": offer["deficit"], "amount": offer["amount"],
			"interest": offer["interest"], "total_due": offer["total_due"], "repay_days": offer["repay_days"],
			"first_installment": inst[0], "bailouts_left_after": bailouts_left - 1,
		})
	elif went_bankrupt:
		bus.publish(EV_BANKRUPT, {"day": d, "cash": cash, "bailouts_used": config.bailout_count - bailouts_left})


## 구제 조건(제안 시점 확정). economy.md #파산과-구제 표.
func _make_offer(d: int) -> Dictionary:
	var r: Dictionary = config.row(tier)
	var deficit: int = -cash
	var amount: int = deficit + int(r["bailout_loan_amount"])
	var interest: int = amount * int(r["bailout_interest_bp"]) / config.rate_scale
	var total_due: int = amount + interest
	var repay_days: int = r["bailout_repay_days"]
	return {
		"day": d, "kind": KIND_LOAN, "deficit": deficit, "amount": amount, "interest": interest,
		"total_due": total_due, "repay_days": repay_days, "installments": split_installments(total_due, repay_days),
	}


## 수락(수동·자동 공통). day_taken·bailout_taken.day 는 제안일(pending_bailout.day).
func _accept_bailout(auto: bool) -> void:
	var pb: Dictionary = pending_bailout
	var amount: int = pb["amount"]
	cash += amount
	bailouts_left -= 1
	loans.append({
		"day_taken": pb["day"], "amount": amount, "total_due": pb["total_due"],
		"installments": (pb["installments"] as Array).duplicate(), "paid": 0,
	})
	pending_bailout = null
	if amount != 0:
		bus.publish(EV_CASH_CHANGED, {"cash": cash, "delta": amount, "reason": REASON_BAILOUT})
	bus.publish(EV_BAILOUT_TAKEN, {
		"day": pb["day"], "kind": pb["kind"], "amount": amount, "total_due": pb["total_due"],
		"repay_days": pb["repay_days"], "bailouts_left": bailouts_left, "cash": cash, "auto": auto,
	})


# --- 내부 ---------------------------------------------------------------------

static func _new_ledger() -> Dictionary:
	return {LEDGER_ADMISSIONS: 0, LEDGER_AUDIENCE: 0, LEDGER_GUARANTEE: 0}


static func _str_or_empty(v: Variant) -> String:
	return String(v) if (v is String or v is StringName) else ""


## 스냅샷 검사·정규화. 성공이면 적용할 Dictionary(깊은 복사), 실패면 오류 문자열.
func _parse_snapshot(d: Dictionary) -> Variant:
	for key: String in SNAPSHOT_FIELDS:
		if not d.has(key):
			return "필드 누락: %s" % key
	var out: Dictionary = {}
	for key: String in ["cash", "tier", "day", "ticket_price", "upkeep_per_day", "last_settled_day", "bailouts_left"]:
		var v: Variant = EconomyConfig.as_int(d[key])
		if v == null:
			return "%s 가 정수가 아니다: %s" % [key, d[key]]
		out[key] = v
	if not config.has_row(out["tier"]):
		return "tier %d 의 경제 행이 없다" % out["tier"]
	if out["day"] < NEW_GAME_DAY or out["upkeep_per_day"] < 0 or out["last_settled_day"] < 0 or out["bailouts_left"] < 0 or out["ticket_price"] < 0:
		return "범위 밖 값(day ≥ 1, upkeep_per_day·last_settled_day·bailouts_left·ticket_price ≥ 0)"
	var ph: Variant = d["phase"]
	if not (ph is String or ph is StringName) or String(ph).is_empty():
		return "phase 가 문자열이 아니다"
	out["phase"] = String(ph)
	if not (d["bankrupt"] is bool):
		return "bankrupt 가 bool 이 아니다"
	out["bankrupt"] = d["bankrupt"]
	var lg: Variant = d["ledger"]
	if not (lg is Dictionary):
		return "ledger 가 객체가 아니다"
	var new_ledger: Dictionary = _new_ledger()
	for key: String in [LEDGER_ADMISSIONS, LEDGER_AUDIENCE, LEDGER_GUARANTEE]:
		var v: Variant = EconomyConfig.as_int((lg as Dictionary).get(key))
		if v == null or v < 0:
			return "ledger.%s 가 0 이상 정수가 아니다" % key
		new_ledger[key] = v
	out["ledger"] = new_ledger
	var pb: Variant = d["pending_bailout"]
	if pb == null:
		out["pending_bailout"] = null
	elif pb is Dictionary:
		var npb: Variant = _parse_record(pb, PENDING_INT_FIELDS, "pending_bailout")
		if npb is String:
			return npb
		var kind: Variant = (pb as Dictionary).get("kind")
		if not (kind is String or kind is StringName):
			return "pending_bailout.kind 가 문자열이 아니다"
		npb["kind"] = String(kind)
		if (npb["installments"] as Array).size() != npb["repay_days"]:
			return "pending_bailout.installments 개수가 repay_days 와 다르다"
		out["pending_bailout"] = npb
	else:
		return "pending_bailout 은 null 또는 객체여야 한다"
	var raw_loans: Variant = d["loans"]
	if not (raw_loans is Array):
		return "loans 가 배열이 아니다"
	var new_loans: Array = []
	for e: Variant in raw_loans:
		if not (e is Dictionary):
			return "loans[] 원소가 객체가 아니다"
		var loan: Variant = _parse_record(e, LOAN_INT_FIELDS, "loans[]")
		if loan is String:
			return loan
		if loan["paid"] < 0 or loan["paid"] >= (loan["installments"] as Array).size():
			return "loans[].paid 가 0 이상 installments 개수 미만이 아니다"
		new_loans.append(loan)
	out["loans"] = new_loans
	return out


## 정수 필드 목록 + installments(비어 있지 않은 정수 배열)를 검사·정규화한다. 실패면 오류 문자열.
static func _parse_record(rec: Dictionary, int_fields: Array[String], label: String) -> Variant:
	var out: Dictionary = {}
	for key: String in int_fields:
		var v: Variant = EconomyConfig.as_int(rec.get(key))
		if v == null:
			return "%s.%s 가 정수가 아니다: %s" % [label, key, rec.get(key)]
		out[key] = v
	var inst: Variant = rec.get("installments")
	if not (inst is Array) or (inst as Array).is_empty():
		return "%s.installments 가 비어 있지 않은 배열이 아니다" % label
	var arr: Array = []
	for x: Variant in inst:
		var n: Variant = EconomyConfig.as_int(x)
		if n == null:
			return "%s.installments 원소가 정수가 아니다: %s" % [label, x]
		arr.append(n)
	out["installments"] = arr
	return out
