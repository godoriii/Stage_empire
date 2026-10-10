class_name BotPlay
extends RefCounted
## SE-042 봇 플레이어 본체 (qa). 규칙: docs/gdd/bot_metrics.md R1~R6, 정책 3종 + v0_replay, 봇 RNG, 지표 M1~M12, 통계 형식.
## 한 판 = GameSession 헤드리스 + 명령 이벤트만 발행 + 상태 이벤트 구독으로 지표 계산(R3·R5).
## 정책 값은 tools/bot/policies/<id>.json 에서 읽는다(코드에 수치를 넣지 않는다). 게임 수치는 res://data 에서 읽는다.
## 러너(bot_runner.gd, SceneTree)와 단위 테스트(test_bot_runner.gd)가 같은 함수를 쓴다.

const DATA_ROOT: String = "res://data"
const BOT_DIR: String = "res://../tools/bot"
const POLICY_DIR: String = BOT_DIR + "/policies"
const TARGETS_FILE: String = POLICY_DIR + "/targets.json"
const TICKET: String = "SE-042"
const SPEC: String = "docs/gdd/bot_metrics.md"
const SPEC_VERSION: int = 1
const CALIBRATION_POLICY: String = "v0_replay"
const STAT_POLICIES: Array[String] = ["frugal", "aggressive", "random"]

const GRADES: Array[String] = ["disaster", "poor", "ok", "good", "rave"]
const GRADE_SKIPPED: String = "skipped"
const FAIL_GRADES: Array[String] = ["disaster", "poor"]
const BELOW_GOOD_GRADES: Array[String] = ["disaster", "poor", "ok"]
const GOOD_GRADES: Array[String] = ["good", "rave"]
const ROTATIONS: Array[int] = [0, 90, 180, 270]
const PROMPT_KINDS: Array[String] = ["rookie_unlock", "promotion", "sold_out", "first_failure", "bailout"]
## M1: 3일차 close 까지, M8: 10일 close 까지 (bot_metrics.md 대리 지표 표).
const SWING_DAYS: int = 3
const PROMPT_DAYS: int = 10
## 봇 RNG (bot_metrics.md #봇-rng): 시드 = game_seed × RNG_SEED_MUL + rng_salt, 하루 정확히 RNG_DRAWS_PER_DAY 회.
const RNG_SEED_MUL: int = 1000
const RNG_DRAWS_PER_DAY: int = 8
const BP: int = 10000
const UNREACHED_SORT_DAY: int = 31   # M9: 미도달을 31 로 셈
const PHASE_CLOSE: String = "close"

# --- 한 판 상태 --------------------------------------------------------------------------
var _p: Dictionary
var _d: Dictionary
var _s: GameSession
var _rng: RandomNumberGenerator = null
var _subs: Array = []

# 관측 상태(bot_metrics.md #관측-상태)
var _cash: int = 0
var _rep: int = 0
var _price: int = 0
var _roster: Dictionary = {}        # id -> {grade, popularity}
var _discovered: Dictionary = {}
var _yday: Dictionary = {}
var _today: Dictionary = {}
var _pending_bailout: Variant = null
var _queue_state: Array = []        # build_queue 항목별: 0 대기, 1 발행, 2 거절

# 지표
var _swing_min: int = 0
var _swing_max: int = 0
var _first_profit_day: Variant = null
var _payback_day: Variant = null
var _rep500_day: Variant = null
var _tier2_day: Variant = null
var _bankrupt_day: Variant = null
var _bailouts_taken: int = 0
var _final_cash: int = 0
var _grade_days: Dictionary = {}
var _rej_booking: Dictionary = {}
var _rej_build: Dictionary = {}
var _shows: int = 0
var _booked: Dictionary = {}
var _price_changes: int = 0
var _prompt_day: Dictionary = {}
var _soldout_days: int = 0
var _soldout_sat_sum: int = 0
var _soldout_below_good: int = 0
var _fail_days: int = 0
var _skip_days: int = 0
var _net_fail_sum: int = 0
var _net_skip_sum: int = 0
var _rep_fail_sum: int = 0
var _zero_adm: int = 0


# --- 데이터·정책 로드 ----------------------------------------------------------------------

static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("[BotPlay] 파일 없음: %s" % path)
		return null
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if v == null:
		push_error("[BotPlay] JSON 파싱 실패: %s" % path)
		return null
	return JsonUtil.int_deep(v)


## 게임 데이터 테이블에서 정책이 보는 값만 모은다(읽기 전용).
static func load_data() -> Dictionary:
	var eco: Dictionary = read_json(DATA_ROOT + "/economy/economy.json")
	var tier1: Dictionary = {}
	for r: Dictionary in eco["rows"]:
		if int(r["tier"]) == 1:
			tier1 = r
	var art: Dictionary = read_json(DATA_ROOT + "/artists/artists.json")
	var rules: Dictionary = read_json(DATA_ROOT + "/artist/artist.json")
	var unlock: Dictionary = {}
	for g: Dictionary in rules["grades"]:
		unlock[g["id"]] = int(g["unlock_reputation"])
	var fur: Dictionary = read_json(DATA_ROOT + "/furniture/furniture.json")
	var fur_ids: Array = []
	var fur_cost: Dictionary = {}
	for r: Dictionary in fur["rows"]:
		fur_ids.append(r["id"])
		fur_cost[r["id"]] = int(r["build_cost"])
	var map: Dictionary = read_json(DATA_ROOT + "/maps/tier1_club.json")
	var layouts: Dictionary = {}
	for l: Dictionary in map["reference_layouts"]:
		layouts[l["id"]] = l["placements"]
	var tiers: Dictionary = read_json(DATA_ROOT + "/tiers/tiers.json")
	var tier2_rep: int = 0
	for r: Dictionary in tiers["rows"]:
		if int(r["tier"]) == 2:
			tier2_rep = int(r["unlock_reputation"])
	return {
		"starting_cash": int(eco["starting_cash"]),
		"price_default": int(tier1["ticket_price_default"]),
		"price_min": int(tier1["ticket_price_min"]),
		"price_max": int(tier1["ticket_price_max"]),
		"guarantee": eco["guarantee_by_grade"],
		"artists": art["rows"],
		"unlock_rep": unlock,
		"furniture_ids": fur_ids,
		"furniture_cost": fur_cost,
		"layouts": layouts,
		"map_w": int(map["width"]),
		"map_d": int(map["depth"]),
		"tier2_rep": tier2_rep,
		"rookie_rep": int(unlock["rookie"]),
	}


static func policy_path(id: String) -> String:
	return "%s/%s.json" % [POLICY_DIR, id]


static func load_policy(id: String) -> Dictionary:
	var v: Variant = read_json(policy_path(id))
	return v if v is Dictionary else {}


static func policy_sha1(id: String) -> String:
	var hc: HashingContext = HashingContext.new()
	hc.start(HashingContext.HASH_SHA1)
	hc.update(FileAccess.get_file_as_bytes(policy_path(id)))
	return hc.finish().hex_encode()


# --- 한 판 ---------------------------------------------------------------------------------

## 한 판을 돌려 결과 dict(runs[] 원소 형식)를 돌려준다. trace 이면 "trace": [[day, cash, rep], …](close 경계)를 덧붙인다.
static func play_game(policy: Dictionary, game_seed: int, days: int, configs: Dictionary, data: Dictionary, trace: bool = false) -> Dictionary:
	var g: BotPlay = BotPlay.new()
	var res: Dictionary = g._play(policy, game_seed, days, configs, data, trace)
	g._detach()
	return res


func _play(policy: Dictionary, game_seed: int, days: int, configs: Dictionary, data: Dictionary, trace: bool) -> Dictionary:
	_p = policy
	_d = data
	_s = GameSession.new()
	if not _s.new_game_from_configs(game_seed, configs):
		push_error("[BotPlay] new_game 실패 seed %d" % game_seed)
		return {}
	_s.autosave_enabled = false                                  # R1
	if _p.get("rng_salt") != null:
		_rng = RandomNumberGenerator.new()
		_rng.seed = game_seed * RNG_SEED_MUL + int(_p["rng_salt"])
	_init_observation()
	_subscribe()
	var tr: Array = []
	var day_ticks: int = (configs["sim"] as SimConfig).day_ticks
	for day: int in range(1, days + 1):
		if day > 1:
			_yday = _today
		_today = _fresh_day()
		_pending_bailout = null
		_day_start(day)
		_s.advance(day_ticks)                                    # R2 ②
		if _s.loop.phase != PHASE_CLOSE:
			push_error("[BotPlay] seed %d %d일: close 에 도달하지 못했다(%s)" % [game_seed, day, _s.loop.phase])
			break
		if trace:
			tr.append([day, _s.cash(), _s.reputation_total()])
		if _bankrupt_day != null:                                 # R1: 파산하면 그날 끝
			break
		_close_decision()
		if day < days:
			_s.bus.publish("time.next_day_requested", {})
			_s.advance(0)
	var out: Dictionary = _result(game_seed)
	if trace:
		out["trace"] = tr
	return out


func _init_observation() -> void:
	_cash = int(_d["starting_cash"])
	_price = int(_d["price_default"])
	_swing_min = _cash
	_swing_max = _cash
	for a: Dictionary in _d["artists"]:
		_roster[a["id"]] = {"grade": a["grade"], "popularity": int(a["popularity"])}
	for g: String in GRADES:
		_grade_days[g] = 0
	_grade_days[GRADE_SKIPPED] = 0
	for k: String in PROMPT_KINDS:
		_prompt_day[k] = null
	_queue_state.resize((_p.get("build_queue", []) as Array).size())
	_queue_state.fill(0)
	_yday = {}
	_today = _fresh_day()


func _fresh_day() -> Dictionary:
	return {"capped_by": null, "admissions": null, "capacity": null, "grade": null, "skipped": false, "rep_delta": 0}


func _subscribe() -> void:
	var names: Array[String] = [
		"economy.cash_changed", "economy.day_settled", "economy.bailout_offered", "economy.bailout_taken",
		"economy.bankrupt", "economy.ticket_price_changed", "reputation.changed", "reputation.tier_unlocked",
		"artist.grown", "artist.booked", "artist.booking_rejected", "build.rejected",
		"audience.admissions_decided", "show.ended", "show.skipped",
	]
	for n: String in names:
		var c: Callable = Callable(self, "_on_" + n.replace(".", "_"))
		_s.bus.subscribe(n, c)
		_subs.append([n, c])


## 버스 ↔ 봇 순환 참조를 끊는다(판마다 세션을 버린다).
func _detach() -> void:
	if _s != null and _s.bus != null:
		for e: Array in _subs:
			_s.bus.unsubscribe(e[0], e[1])
	_subs.clear()


func _cur_day() -> int:
	return _s.loop.day


func _mark_prompt(kind: String, day: int) -> void:
	if _prompt_day[kind] == null:
		_prompt_day[kind] = day


# --- 상태 이벤트 구독 ------------------------------------------------------------------------

func _on_economy_cash_changed(p: Dictionary) -> void:
	_cash = int(p["cash"])
	if _cur_day() <= SWING_DAYS:
		_swing_min = mini(_swing_min, _cash)
		_swing_max = maxi(_swing_max, _cash)


func _on_economy_day_settled(p: Dictionary) -> void:
	var day: int = int(p["day"])
	var net: int = int(p["net"])
	_final_cash = int(p["cash"])
	if _first_profit_day == null and net > 0:
		_first_profit_day = day
	if _payback_day == null and _final_cash >= int(_d["starting_cash"]):
		_payback_day = day
	if _today["grade"] != null and FAIL_GRADES.has(_today["grade"]):
		_fail_days += 1
		_net_fail_sum += net
		_rep_fail_sum += int(_today["rep_delta"])
	if _today["skipped"]:
		_skip_days += 1
		_net_skip_sum += net


func _on_economy_bailout_offered(p: Dictionary) -> void:
	_pending_bailout = p
	_mark_prompt("bailout", int(p["day"]))


func _on_economy_bailout_taken(_p2: Dictionary) -> void:
	_bailouts_taken += 1
	_pending_bailout = null


func _on_economy_bankrupt(p: Dictionary) -> void:
	_bankrupt_day = int(p["day"])


func _on_economy_ticket_price_changed(p: Dictionary) -> void:
	_price = int(p["price"])
	_price_changes += 1


func _on_reputation_changed(p: Dictionary) -> void:
	var day: int = int(p["day"])
	_rep = int(p["total"])
	_today["rep_delta"] = int(p["delta"])
	if _rep500_day == null and _rep >= int(_d["tier2_rep"]):
		_rep500_day = day
	if _rep >= int(_d["rookie_rep"]):
		_mark_prompt("rookie_unlock", day)


func _on_reputation_tier_unlocked(p: Dictionary) -> void:
	if int(p["tier"]) == 2 and _tier2_day == null:
		_tier2_day = int(p["day"])


func _on_artist_grown(p: Dictionary) -> void:
	var id: String = p["artist_id"]
	_roster[id] = {"grade": p["grade"], "popularity": int(p["popularity"])}
	if p["promoted"]:
		_discovered[id] = true
		_mark_prompt("promotion", int(p["day"]))


func _on_artist_booked(p: Dictionary) -> void:
	_booked[p["artist_id"]] = true


func _on_artist_booking_rejected(p: Dictionary) -> void:
	_count(_rej_booking, String(p["reason"]))


func _on_build_rejected(p: Dictionary) -> void:
	_count(_rej_build, String(p["reason"]))
	if p["action"] != "place":
		return
	var q: Array = _p.get("build_queue", [])
	for i: int in q.size():
		var it: Dictionary = q[i]
		if _queue_state[i] == 1 and p["furniture_id"] == it["furniture_id"] and p["cell"] == it["cell"] and p["rotation"] == it["rotation"]:
			_queue_state[i] = 2
			return


func _on_audience_admissions_decided(p: Dictionary) -> void:
	_today["capped_by"] = p["capped_by"]
	_today["admissions"] = int(p["admissions"])
	_today["capacity"] = int(p["capacity"])
	if p["capped_by"] == "capacity":
		_mark_prompt("sold_out", int(p["day"]))


func _on_show_ended(p: Dictionary) -> void:
	var grade: String = p["grade"]
	_today["grade"] = grade
	_grade_days[grade] = int(_grade_days[grade]) + 1
	_shows += 1
	if int(p["admissions"]) == 0:
		_zero_adm += 1
	if FAIL_GRADES.has(grade):
		_mark_prompt("first_failure", int(p["day"]))
	if _today["capped_by"] == "capacity":
		_soldout_days += 1
		_soldout_sat_sum += int(p["satisfaction_bp"])
		if BELOW_GOOD_GRADES.has(grade):
			_soldout_below_good += 1


func _on_show_skipped(_p2: Dictionary) -> void:
	_today["skipped"] = true
	_grade_days[GRADE_SKIPPED] = int(_grade_days[GRADE_SKIPPED]) + 1


static func _count(d: Dictionary, key: String) -> void:
	d[key] = int(d.get(key, 0)) + 1


# --- 정책: 낮 시작 · close ------------------------------------------------------------------

func _draw() -> int:
	return _rng.randi()


func _book_cost(id: String) -> int:
	return int(_d["guarantee"][_roster[id]["grade"]])


func _bookable(id: String) -> bool:
	if _discovered.has(id):
		return true
	return _rep >= int(_d["unlock_rep"][_roster[id]["grade"]])


func _day_start(day: int) -> void:
	var committed: int = 0
	var is_random: bool = _p["artist_pick"] == "uniform_random"
	var u: Array = []
	if is_random:                                                 # 하루 8회 고정 순서(⑧은 close 에서)
		for i: int in RNG_DRAWS_PER_DAY - 1:
			u.append(_draw())
	if day == 1:                                                  # 개점 배치(R4: 건설보다 앞)
		for pl: Dictionary in _d["layouts"][_p["opening_layout"]]:
			_s.bus.publish("build.place_requested", {"furniture_id": pl["furniture_id"], "cell": pl["cell"], "rotation": pl["rotation"]})
			committed += int(_d["furniture_cost"][pl["furniture_id"]])
	# 섭외
	var guarantee: int = 0
	var pick: String = ""
	if is_random:
		var order: Array = []
		for a: Dictionary in _d["artists"]:
			order.append(a["id"])
		pick = order[int(u[0]) % order.size()]
	else:
		pick = _pick_artist(_cash - committed)
	if pick != "":
		_s.bus.publish("artist.book_requested", {"artist_id": pick})
		guarantee = _book_cost(pick)
	# 가격
	_price_command(day, u)
	# 건설
	if is_random:
		if int(u[2]) % BP < int(_p["random_build_bp"]):
			var fids: Array = _d["furniture_ids"]
			_s.bus.publish("build.place_requested", {
				"furniture_id": fids[int(u[3]) % fids.size()],
				"cell": [int(u[4]) % int(_d["map_w"]), int(u[5]) % int(_d["map_d"])],
				"rotation": ROTATIONS[int(u[6]) % ROTATIONS.size()]})
	else:
		_build_queue(_cash - committed - guarantee)


func _pick_artist(avail: int) -> String:
	var mode: String = _p["artist_pick"]
	if mode == "fixed":
		var fid: String = _p["artist_id"]
		return fid if _affordable(fid, avail) else ""
	var best: String = ""
	var best_pop: int = -1
	for a: Dictionary in _d["artists"]:
		var id: String = a["id"]
		if mode == "max_popularity_local" and _roster[id]["grade"] != "local":
			continue
		if not _bookable(id) or not _affordable(id, avail):
			continue
		var pop: int = int(_roster[id]["popularity"])
		if pop > best_pop:                                        # 동률은 rows[] 앞쪽
			best = id
			best_pop = pop
	return best


func _affordable(id: String, avail: int) -> bool:
	var reserve: Variant = _p.get("book_reserve")
	return reserve == null or avail >= _book_cost(id) + int(reserve)


func _price_command(day: int, u: Array) -> void:
	var mode: String = _p["price_mode"]
	var want: int = _price
	if mode == "uniform_random":
		var lo: int = int(_d["price_min"])
		var hi: int = int(_d["price_max"])
		want = lo + int(u[1]) % (hi - lo + 1)
	elif mode == "fixed":
		if day == 1 and _p.get("price_fixed") != null:
			want = int(_p["price_fixed"])
	elif mode == "demand_step" and day > 1 and not _yday.is_empty():
		var step: int = int(_p["price_step"])
		var grade: Variant = _yday["grade"]
		var pmin: int = int(_p["price_min"])
		var pmax: int = int(_p["price_max"])
		var low_fill: bool = false
		if _yday["admissions"] != null:
			low_fill = int(_yday["admissions"]) * BP < int(_p["price_low_fill_bp"]) * int(_yday["capacity"])
		if _yday["capped_by"] == "capacity" and grade != null and GOOD_GRADES.has(grade):
			want = mini(_price + step, pmax)
		elif (grade != null and BELOW_GOOD_GRADES.has(grade)) or low_fill:
			want = maxi(_price - step, pmin)
	if want != _price:
		_s.bus.publish("economy.ticket_price_requested", {"price": want})


func _build_queue(avail: int) -> void:
	var q: Array = _p.get("build_queue", [])
	var issued: int = 0
	var cap: int = int(_p["build_max_per_day"])
	var left: int = avail
	for i: int in q.size():
		if issued >= cap:
			break
		if _queue_state[i] != 0:
			continue
		var it: Dictionary = q[i]
		var cost: int = int(_d["furniture_cost"][it["furniture_id"]])
		if left - cost < int(_p["build_min_cash_after"]):
			break                                                 # 큐 앞에서부터: 못 사면 거기서 멈춘다
		_s.bus.publish("build.place_requested", {"furniture_id": it["furniture_id"], "cell": it["cell"], "rotation": it["rotation"]})
		_queue_state[i] = 1
		left -= cost
		issued += 1


func _close_decision() -> void:
	var accept: bool = false
	var mode: String = _p["bailout_accept"]
	if mode == "random":
		var r: int = _draw()                                      # ⑧ 구제 제안이 없어도 뽑고 버린다
		accept = _pending_bailout != null and r % BP < int(_p["random_accept_bp"])
	elif mode == "always":
		accept = _pending_bailout != null
	if accept:
		_s.bus.publish("economy.bailout_accept_requested", {})


# --- 결과 ------------------------------------------------------------------------------------

func _result(game_seed: int) -> Dictionary:
	var first_prompt: Variant = null
	var d10: int = 0
	for k: String in PROMPT_KINDS:
		var pd: Variant = _prompt_day[k]
		if pd == null:
			continue
		if first_prompt == null or int(pd) < int(first_prompt):
			first_prompt = int(pd)
		if int(pd) <= PROMPT_DAYS:
			d10 += 1
	var grade_days: Dictionary = {}
	for g: String in GRADES:
		grade_days[g] = _grade_days[g]
	grade_days[GRADE_SKIPPED] = _grade_days[GRADE_SKIPPED]
	return {
		"seed": game_seed,
		"bankrupt_day": _bankrupt_day,
		"bailouts_taken": _bailouts_taken,
		"final_cash": _final_cash,
		"final_rep": _rep,
		"metrics": {
			"cash_swing_d3": _swing_max - _swing_min,
			"first_profit_day": _first_profit_day,
			"payback_day": _payback_day,
			"rep500_day": _rep500_day,
			"tier2_day": _tier2_day,
			"first_prompt_day": first_prompt,
			"prompts_d10": d10,
		},
		"grade_days": grade_days,
		"rejections": {"booking": _sorted(_rej_booking), "build": _sorted(_rej_build)},
		"shows": _shows,
		"distinct_artists": _booked.size(),
		"price_changes": _price_changes,
		"pool": {
			"soldout_days": _soldout_days, "soldout_sat_sum": _soldout_sat_sum, "soldout_below_good": _soldout_below_good,
			"fail_days": _fail_days, "skip_days": _skip_days, "net_fail_sum": _net_fail_sum, "net_skip_sum": _net_skip_sum,
			"rep_fail_sum": _rep_fail_sum, "zero_admission_shows": _zero_adm,
		},
	}


static func _sorted(d: Dictionary) -> Dictionary:
	var keys: Array = d.keys()
	keys.sort()
	var out: Dictionary = {}
	for k: Variant in keys:
		out[k] = d[k]
	return out


# --- 통계 (bot_metrics.md #통계-형식) -------------------------------------------------------------

## 최근접 순위 분위수. 값 배열(int 또는 null)을 오름차순(null 은 맨 뒤)으로 정렬한 v[⌈p·n/100⌉ − 1]. null 이면 null.
static func percentile(vals: Array, p: int) -> Variant:
	var nums: Array = []
	var nulls: int = 0
	for v: Variant in vals:
		if v == null:
			nulls += 1
		else:
			nums.append(int(v))
	nums.sort()
	var n: int = vals.size()
	if n == 0:
		return null
	var idx: int = (p * n + 99) / 100 - 1
	if idx < nums.size():
		return nums[idx]
	return null


static func summary_of(vals: Array) -> Dictionary:
	var reached: int = 0
	for v: Variant in vals:
		if v != null:
			reached += 1
	var n: int = vals.size()
	return {
		"n": n, "q1": percentile(vals, 25), "median": percentile(vals, 50), "q3": percentile(vals, 75),
		"reached_bp": (reached * BP / n) if n > 0 else 0,
	}


## 나눗셈 내림(음수 포함). b == 0 이면 null.
static func fdiv(a: int, b: int) -> Variant:
	if b == 0:
		return null
	return floori(float(a) / float(b))


static func _col(runs: Array, getter: Callable) -> Array:
	var out: Array = []
	for r: Dictionary in runs:
		out.append(getter.call(r))
	return out


static func policy_block(id: String, sha1: String, runs: Array) -> Dictionary:
	var summary: Dictionary = {}
	for k: String in ["cash_swing_d3", "first_profit_day", "payback_day", "rep500_day", "tier2_day", "first_prompt_day", "prompts_d10"]:
		summary[k] = summary_of(_col(runs, func(r: Dictionary) -> Variant: return r["metrics"][k]))
	summary["bankrupt_day"] = summary_of(_col(runs, func(r: Dictionary) -> Variant: return r["bankrupt_day"]))
	for k: String in ["final_cash", "final_rep", "bailouts_taken"]:
		summary[k] = summary_of(_col(runs, func(r: Dictionary) -> Variant: return r[k]))
	return {"policy_file_sha1": sha1, "summary": summary, "pooled": _pooled(runs), "runs": runs}


static func _pooled(runs: Array) -> Dictionary:
	var n: int = runs.size()
	var gd: Dictionary = {}
	var keys: Array[String] = GRADES.duplicate()
	keys.append(GRADE_SKIPPED)
	for g: String in keys:
		gd[g] = 0
	var bankrupt: int = 0
	var tier2: int = 0
	var shows: int = 0
	var pool: Dictionary = {}
	var rb: Dictionary = {}
	var rbu: Dictionary = {}
	for r: Dictionary in runs:
		for g: String in keys:
			gd[g] = int(gd[g]) + int(r["grade_days"][g])
		if r["bankrupt_day"] != null:
			bankrupt += 1
		if r["metrics"]["tier2_day"] != null:
			tier2 += 1
		shows += int(r["shows"])
		for k: String in r["pool"]:
			pool[k] = int(pool.get(k, 0)) + int(r["pool"][k])
		for k: String in r["rejections"]["booking"]:
			rb[k] = int(rb.get(k, 0)) + int(r["rejections"]["booking"][k])
		for k: String in r["rejections"]["build"]:
			rbu[k] = int(rbu.get(k, 0)) + int(r["rejections"]["build"][k])
	var days_total: int = 0
	for g: String in keys:
		days_total += int(gd[g])
	var share: Dictionary = {}
	for g: String in keys:
		share[g] = (int(gd[g]) * BP / days_total) if days_total > 0 else 0
	var sd: int = int(pool.get("soldout_days", 0))
	return {
		"grade_share_bp": share,
		"bankrupt_rate_bp": (bankrupt * BP / n) if n > 0 else 0,
		"tier2_rate_bp": (tier2 * BP / n) if n > 0 else 0,
		"soldout": {
			"days": sd,
			"sat_mean_bp": fdiv(int(pool.get("soldout_sat_sum", 0)), sd),
			"below_good_bp": fdiv(int(pool.get("soldout_below_good", 0)) * BP, sd),
		},
		"fail_vs_skip": {
			"fail_days": int(pool.get("fail_days", 0)), "skip_days": int(pool.get("skip_days", 0)),
			"net_fail_mean": fdiv(int(pool.get("net_fail_sum", 0)), int(pool.get("fail_days", 0))),
			"net_skip_mean": fdiv(int(pool.get("net_skip_sum", 0)), int(pool.get("skip_days", 0))),
			"rep_fail_mean": fdiv(int(pool.get("rep_fail_sum", 0)), int(pool.get("fail_days", 0))),
		},
		"zero_admission_shows": {"count": int(pool.get("zero_admission_shows", 0)), "of_shows": shows},
		"rejections": {"booking": _sorted(rb), "build": _sorted(rbu)},
	}


## 부분 결과(part) 여러 개 → 최종 결과 dict. part = {policy, days, first_seed, count, policy_file_sha1, runs}.
## 시드 순서로 합치고 구간이 겹치거나 비면 오류(빈 dict + push_error). 합친 결과는 한 번에 돌린 결과와 같다(판 사이 상태 공유 없음).
static func merge_parts(parts: Array, targets: Dictionary) -> Dictionary:
	var by: Dictionary = {}
	var sha: Dictionary = {}
	var days: int = -1
	for part: Dictionary in parts:
		var id: String = part["policy"]
		if days >= 0 and int(part["days"]) != days:
			push_error("[BotPlay] merge: 일수가 다른 부분 결과가 섞였다(%d vs %d)" % [days, int(part["days"])])
			return {}
		days = int(part["days"])
		if sha.has(id) and sha[id] != part["policy_file_sha1"]:
			push_error("[BotPlay] merge: 정책 파일 sha1 이 다르다(%s)" % id)
			return {}
		sha[id] = part["policy_file_sha1"]
		if not by.has(id):
			by[id] = []
		(by[id] as Array).append_array(part["runs"])
	var first: int = -1
	var count: int = -1
	var blocks: Dictionary = {}
	var order: Array[String] = []
	for id: String in STAT_POLICIES:
		if not by.has(id):
			continue
		var runs: Array = by[id]
		runs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["seed"]) < int(b["seed"]))
		for i: int in runs.size():
			if int(runs[i]["seed"]) != int(runs[0]["seed"]) + i:
				push_error("[BotPlay] merge: %s 시드 구간이 이어지지 않는다(%d 번째 = %d)" % [id, i, int(runs[i]["seed"])])
				return {}
		if first >= 0 and (first != int(runs[0]["seed"]) or count != runs.size()):
			push_error("[BotPlay] merge: 정책마다 시드 구간이 다르다(%s)" % id)
			return {}
		first = int(runs[0]["seed"])
		count = runs.size()
		order.append(id)
		blocks[id] = policy_block(id, sha[id], runs)
	if order.is_empty():
		push_error("[BotPlay] merge: 통계 정책 결과가 없다")
		return {}
	var out: Dictionary = {
		"ticket": TICKET, "spec": SPEC, "spec_version": SPEC_VERSION, "days": days,
		"seeds": {"first": first, "count": count}, "policies": order, "by_policy": blocks,
		"cross_policy": _cross(blocks),
		"calibration": _calibration(by, sha, days, targets),
	}
	return out


static func _med_or_31(runs: Array, key: String) -> int:
	var vals: Array = []
	for r: Dictionary in runs:
		var v: Variant = r["metrics"][key]
		vals.append(UNREACHED_SORT_DAY if v == null else int(v))
	return int(percentile(vals, 50))


static func _med_top(runs: Array, key: String) -> int:
	return int(percentile(_col(runs, func(r: Dictionary) -> Variant: return r[key]), 50))


static func _cross(blocks: Dictionary) -> Dictionary:
	var spread_rep: Variant = null
	var spread_cash: Variant = null
	if blocks.has("frugal") and blocks.has("aggressive"):
		spread_rep = _med_or_31(blocks["frugal"]["runs"], "rep500_day") - _med_or_31(blocks["aggressive"]["runs"], "rep500_day")
	if blocks.has("frugal") and blocks.has("random"):
		spread_cash = _med_top(blocks["frugal"]["runs"], "final_cash") - _med_top(blocks["random"]["runs"], "final_cash")
	var total: int = 0
	var bankrupt: int = 0
	for id: String in blocks:
		for r: Dictionary in blocks[id]["runs"]:
			total += 1
			if r["bankrupt_day"] != null:
				bankrupt += 1
	return {
		"spread_rep500_days": spread_rep, "spread_final_cash": spread_cash,
		"bankrupt_rate_bp_pooled": (bankrupt * BP / total) if total > 0 else 0,
	}


static func _calibration(by: Dictionary, sha: Dictionary, days: int, targets: Dictionary) -> Variant:
	if not by.has(CALIBRATION_POLICY):
		return null
	var want: Dictionary = targets.get("calibration", {})
	var run: Dictionary = {}
	for r: Dictionary in by[CALIBRATION_POLICY]:
		if int(r["seed"]) == int(want.get("seed", -1)):
			run = r
	if run.is_empty():
		return null
	var m: Dictionary = {
		"seed": int(run["seed"]), "tier2_day": run["metrics"]["tier2_day"], "rep500_day": run["metrics"]["rep500_day"],
		"final_cash": run["final_cash"], "final_rep": run["final_rep"],
	}
	var match_v: Variant = null
	if days == int(want.get("days", -1)):
		match_v = (m["tier2_day"] == want["tier2_day"] and m["rep500_day"] == want["rep500_day"]
			and m["final_cash"] == want["final_cash"] and m["final_rep"] == want["final_rep"]
			and run["bankrupt_day"] == null and int(run["bailouts_taken"]) == 0)
	m["match"] = match_v
	return {CALIBRATION_POLICY: m}


static func to_json(v: Variant) -> String:
	return JSON.stringify(v, "  ", false) + "\n"
