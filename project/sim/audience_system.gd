class_name AudienceSystem
extends RefCounted
## audience 시스템 v0 (SE-034). 규칙: docs/gdd/audience.md (#입력-계약 LS1~LS4, #상태, #입장-수 AD1~AD12, #자리-선택 SP1~SP5,
## #상태-기계 UP1~UP6·T1~T15·MV1~MV3·P1, #만족 SF0~SF9, #공연-끝 FN1~FN4, #이벤트, #결정성과-rng R1~R5, #스냅샷 RU1~RU7).
## 이벤트: docs/gdd/events.md 의 audience.* 4행과 economy.sales_reported(발행 주체 audience).
##
## - 오늘의 관객(입장 결정, 에이전트 배열, 하루 집계)만 소유한다. 현금·라인업·커버리지는 이벤트로만 받는다(원칙 4).
## - 입력은 생성자에서 구독한 이벤트 6종뿐. 생성자는 이벤트를 내지 않는다. 다른 시스템을 직접 호출·참조하지 않는다.
## - 가구 점유는 build.coverage_changed.blocked_cells(스냅샷 coverage.blocked_cells) 하나로만 안다. 경로는 자기 TilePath
##   (_tile_path)에만 묻고, 그 인스턴스는 생성자·복원·커버리지 수신 세 곳에서만 만든다.
## - 난수는 audience 스트림의 .randi() 뿐이고 artist.lineup_set 처리(AD7 1회 + AD11 N−1 회) 안에서만 뽑는다(R1~R3).
## - 순회는 유형 순서·id 오름차순·입구 z → x·자리 순위 전순서 키뿐이다(R4). Dictionary 순회 순서에 기대는 결과 없음.
## - TickLoop 에는 register_system("audience", update, snapshot, restore) 로 등록한다.

# 발행
const EV_ADMISSIONS: String = "audience.admissions_decided"
const EV_MOVED: String = "audience.agent_moved"
const EV_LEFT: String = "audience.agent_left"
const EV_SUMMARY: String = "audience.day_summary"
const EV_SALES: String = "economy.sales_reported"
# 구독
const EV_COVERAGE: String = "build.coverage_changed"
const EV_LINEUP: String = "artist.lineup_set"
const EV_REPUTATION: String = "reputation.changed"
const EV_PRICE: String = "economy.ticket_price_changed"
const EV_PHASE: String = "time.phase_changed"
const EV_DAY: String = "time.day_started"

## R1: 이 시스템이 주인인 RNG 스트림.
const STREAM: String = "audience"
const PHASE_DAY: String = "day"
const PHASE_EVENING: String = "evening"
const PHASE_SHOW: String = "show"
const PHASE_CLOSE: String = "close"
## 새 게임 값(#상태).
const NEW_GAME_DAY: int = 1
const FIRST_ID: int = 1
const SAT_UNSET: int = -1

# 에이전트 상태 7종
const S_QUEUED: String = "queued"
const S_ENTERING: String = "entering"
const S_MOVING: String = "moving"
const S_AT_BAR: String = "at_bar"
const S_WATCHING: String = "watching"
const S_LEAVING: String = "leaving"
const S_GONE: String = "gone"
const STATES: Array[String] = [S_QUEUED, S_ENTERING, S_MOVING, S_AT_BAR, S_WATCHING, S_LEAVING, S_GONE]
## MV1: 타일을 점유하는 상태(queued·gone 은 점유하지 않는다).
const OCCUPYING: Array[String] = [S_ENTERING, S_MOVING, S_AT_BAR, S_WATCHING, S_LEAVING]
# target_kind
const TK_NONE: String = ""
const TK_BAR: String = "bar"
const TK_SPOT: String = "spot"
const TK_EXIT: String = "exit"
const TARGET_KINDS: Array[String] = [TK_NONE, TK_BAR, TK_SPOT, TK_EXIT]
## claims(t) 를 세는 target_kind(MV3).
const CLAIM_KINDS: Array[String] = [TK_BAR, TK_SPOT]
# agent_left reason
const REASON_PATIENCE: String = "patience"
const REASON_NO_SPOT: String = "no_spot"
## P1: 조기 퇴장자의 혼잡 요소.
const LEAVER_CROWD_BP: int = 0

const SNAPSHOT_FIELDS: Array[String] = [
	"day", "phase", "ticket_price", "reputation_total", "lineup", "coverage", "today", "arrivals", "agents", "next_id",
]
const COVERAGE_FIELDS: Array[String] = [
	"has_stage", "capacity", "satisfaction_bonus_bp", "viewing_tiles", "sound_tiles", "sight_tiles", "bar_tiles", "blocked_cells",
]
const COVERAGE_INT_FIELDS: Array[String] = ["capacity", "satisfaction_bonus_bp"]
const COVERAGE_TILE_FIELDS: Array[String] = ["viewing_tiles", "sound_tiles", "sight_tiles", "bar_tiles", "blocked_cells"]
const LINEUP_FIELDS: Array[String] = ["artist_id", "genre", "grade", "popularity", "skill"]
## #상태 today 9키 + left_totals(조기 퇴장자 확정값 누적 — SE-034 결정, 티켓 결과 절 D1).
const TODAY_FIELDS: Array[String] = [
	"day", "admissions", "expected", "noise_bp", "capped_by", "has_lineup", "by_type", "left_early", "bar_buyers", "left_totals",
]
const TODAY_INT_FIELDS: Array[String] = ["day", "admissions", "expected", "noise_bp", "left_early", "bar_buyers"]
const LEFT_BY_TYPE_FIELDS: Array[String] = ["left_early", "satisfaction_bp"]
## arrivals 원소 [id, type, spawn_tick, bar_planned] 의 위치.
const A_ID: int = 0
const A_TYPE: int = 1
const A_SPAWN: int = 2
const A_BAR: int = 3
const ARRIVAL_SIZE: int = 4
## 에이전트 레코드 19키(#에이전트-레코드, 이 순서로 만든다).
const AGENT_FIELDS: Array[String] = [
	"id", "type", "state", "tile", "next", "progress", "target", "target_kind", "path", "enter_left", "bar_left",
	"bar_planned", "wait", "blocked", "show_ticks", "sound_ticks", "sight_ticks", "left_early", "sat",
]
const AGENT_COUNT_FIELDS: Array[String] = [
	"progress", "enter_left", "bar_left", "wait", "blocked", "show_ticks", "sound_ticks", "sight_ticks",
]
const AGENT_BOOL_FIELDS: Array[String] = ["bar_planned", "left_early"]
const AGENT_TILE_FIELDS: Array[String] = ["tile", "next", "target"]

var config: AudienceConfig
var bus: EventBus
var rng: SeededRng
var map: MapConfig

# 상태 (읽기 전용으로 취급한다. 바꾸는 것은 AudienceSystem 자신뿐). arrivals·agents 는 arrivals()/agents() 로 읽는다.
var day: int = NEW_GAME_DAY
var phase: String = PHASE_DAY
var ticket_price: int = 0
var reputation_total: int = 0
## null 또는 {artist_id, genre, grade, popularity, skill}
var lineup: Variant = null
## 마지막 build.coverage_changed 의 8개 필드.
var coverage: Dictionary = {}
## null 또는 {day, admissions, expected, noise_bp, capped_by, has_lineup, by_type, left_early, bar_buyers, left_totals}
var today: Variant = null
var next_id: int = FIRST_ID

var _arrivals: Array = []      # [id, type, spawn_tick, bar_planned], id 오름차순
var _agents: Array = []        # 에이전트 레코드, id 오름차순

# 파생값(스냅샷 제외): 복원·커버리지 수신 때 다시 만든다.
var _tile_path: TilePath
var _entrances: Array = []     # [x, z], z → x 오름차순
var _spot_rank: Dictionary = {} # type -> Array[[x, z]]
var _bar_rank: Array = []
var _sound: Dictionary = {}    # 타일 키 -> true
var _sight: Dictionary = {}
var _occ: Dictionary = {}      # 타일 키 -> 점유 수(MV1)
var _claims: Dictionary = {}   # 타일 키 -> 예약 수(MV3)


## 새 게임 상태로 만들고 6개 입력 이벤트를 구독한다. 이벤트를 내지 않는다. 난수를 뽑지 않는다.
func _init(p_config: AudienceConfig, p_bus: EventBus, p_rng: SeededRng, p_map: MapConfig) -> void:
	if p_config == null or p_bus == null or p_rng == null or p_map == null:
		push_error("[AudienceSystem] config·bus·rng·map 이 필요하다")
		return
	config = p_config
	bus = p_bus
	rng = p_rng
	map = p_map
	_entrances = map.entrances()
	ticket_price = config.ticket_price_default
	coverage = _empty_coverage()
	_tile_path = TilePath.new(map)
	_rebuild_ranks()
	bus.subscribe(EV_COVERAGE, _on_coverage_changed)
	bus.subscribe(EV_LINEUP, _on_lineup_set)
	bus.subscribe(EV_REPUTATION, _on_reputation_changed)
	bus.subscribe(EV_PRICE, _on_ticket_price_changed)
	bus.subscribe(EV_PHASE, _on_phase_changed)
	bus.subscribe(EV_DAY, _on_day_started)


## TickLoop 단계 2 (UP1~UP6). evening·show 에서만 일한다. 난수를 뽑지 않는다.
func update(ctx: Dictionary) -> void:
	var ph: Variant = ctx.get("phase")
	if ph != PHASE_EVENING and ph != PHASE_SHOW:
		return
	var tick: int = int(ctx["tick"])
	var tip: int = int(ctx["tick_in_phase"])
	if ph == PHASE_EVENING:                                                                       # UP1 (T1)
		while not _arrivals.is_empty() and int(_arrivals[0][A_SPAWN]) <= tip:
			_agents.append(_new_agent(_arrivals.pop_front()))
	var in_show: bool = ph == PHASE_SHOW
	for a: Dictionary in _agents:                                                                 # UP2
		_step(a, tick)
		if in_show and not a["left_early"] and a["state"] != S_GONE:                              # UP3 (SF0)
			_collect_show(a)
	var last: bool = in_show and tip == config.show_ticks - 1
	var summary: Dictionary = {}
	if last:                                                                                      # UP4 (FN1~FN3)
		summary = _finish_show()
	bus.publish(EV_MOVED, {"tick": tick, "agents": _moved_payload()})                            # UP5
	_agents = _agents.filter(func(a: Dictionary) -> bool: return a["state"] != S_GONE)
	if last:                                                                                      # UP6 (FN4)
		bus.publish(EV_SUMMARY, summary)
		bus.publish(EV_SALES, {"admissions": summary["admissions"], "audience": summary["audience"]})


# --- 읽기 전용 조회 ---------------------------------------------------------------

## 도착한 에이전트 레코드의 깊은 복사본(id 오름차순).
func agents() -> Array:
	return _agents.duplicate(true)


## 아직 도착하지 않은 [id, type, spawn_tick, bar_planned] 의 깊은 복사본(id 오름차순).
func arrivals() -> Array:
	return _arrivals.duplicate(true)


## 입구 타일 [x, z] 목록(z → x 오름차순, 복사본).
func entrances() -> Array:
	return _entrances.duplicate(true)


# --- 스냅샷 ------------------------------------------------------------------------

## #상태 표의 필드 10개(깊은 복사, 기본형만). 파생값 제외. 상태 불변, 이벤트·난수 없음(SH1·SH4).
func snapshot() -> Dictionary:
	return {
		"day": day,
		"phase": phase,
		"ticket_price": ticket_price,
		"reputation_total": reputation_total,
		"lineup": (lineup as Dictionary).duplicate(true) if lineup != null else null,
		"coverage": coverage.duplicate(true),
		"today": (today as Dictionary).duplicate(true) if today != null else null,
		"arrivals": _arrivals.duplicate(true),
		"agents": _agents.duplicate(true),
		"next_id": next_id,
	}


## RU1~RU7 을 전부 검사한 뒤 적용한다. 첫 위반에서 push_error 1회, false, 상태 불변, 이벤트 0(SH3·SH4).
## 성공하면 파생값(tile_path = 맵 + coverage.blocked_cells, 자리 순위, occ, claims)을 다시 만든다. 이벤트 없음, 다른 시스템을 부르지 않는다.
func restore(d: Dictionary) -> bool:
	var parsed: Variant = _parse_snapshot(d)
	if parsed is String:
		push_error("[AudienceSystem] restore: " + String(parsed))
		return false
	day = parsed["day"]
	phase = parsed["phase"]
	ticket_price = parsed["ticket_price"]
	reputation_total = parsed["reputation_total"]
	lineup = parsed["lineup"]
	coverage = parsed["coverage"]
	today = parsed["today"]
	_arrivals = parsed["arrivals"]
	_agents = parsed["agents"]
	next_id = parsed["next_id"]
	_tile_path = TilePath.new(map)
	_tile_path.set_occupied(coverage["blocked_cells"], true)
	_rebuild_ranks()
	_rebuild_occupancy()
	return true


# --- 입력 핸들러 -------------------------------------------------------------------

## 8개 필드 저장 + tile_path·자리 순위 재생성. 형식 오류면 push_warning, 무시.
func _on_coverage_changed(p: Dictionary) -> void:
	var parsed: Variant = _parse_coverage(p)
	if parsed is String:
		push_warning("[AudienceSystem] build.coverage_changed 무시: " + String(parsed))
		return
	coverage = parsed
	_tile_path = TilePath.new(map)
	_tile_path.set_occupied(coverage["blocked_cells"], true)
	_rebuild_ranks()


## LS1~LS4 → AD1~AD12 → audience.admissions_decided.
func _on_lineup_set(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	if phase != PHASE_EVENING or not (d is int) or d != day:                                      # LS1
		push_warning("[AudienceSystem] LS1 artist.lineup_set 무시(구간 %s, %d일): %s" % [phase, day, p])
		return
	if today != null:                                                                             # LS2
		push_warning("[AudienceSystem] LS2 오늘(%d일) 입장은 이미 결정됐다: %s" % [day, p])
		return
	var aid: Variant = p.get("artist_id")
	if not (aid == null or aid is String):                                                        # LS3
		push_error("[AudienceSystem] LS3 artist.lineup_set artist_id 가 문자열·null 이 아니다: %s" % [p])
		return
	var lu: Variant = null
	if aid != null:
		var genre: Variant = p.get("genre")
		var pop: Variant = p.get("popularity")
		var skill: Variant = p.get("skill")
		if not (genre is String) or not config.genres.has(genre) or not _is_stat(pop) or not _is_stat(skill):
			push_error("[AudienceSystem] LS3 artist.lineup_set 의 genre·popularity·skill 이 잘못됐다: %s" % [p])
			return
		lu = {"artist_id": aid, "genre": genre, "grade": p.get("grade"), "popularity": pop, "skill": skill}
	lineup = lu                                                                                   # LS4
	_decide_admissions()


func _on_reputation_changed(p: Dictionary) -> void:
	var total: Variant = p.get("total")
	if not (total is int) or total < 0:
		push_warning("[AudienceSystem] reputation.changed 페이로드 무시: %s" % [p])
		return
	reputation_total = total


func _on_ticket_price_changed(p: Dictionary) -> void:
	var price: Variant = p.get("price")
	if not (price is int) or price < 1:
		push_warning("[AudienceSystem] economy.ticket_price_changed 페이로드 무시: %s" % [p])
		return
	ticket_price = price


func _on_phase_changed(p: Dictionary) -> void:
	var to: Variant = p.get("to")
	var d: Variant = p.get("day")
	if not (to is String) or not SimConfig.PHASE_IDS.has(to) or not (d is int) or d < NEW_GAME_DAY:
		push_warning("[AudienceSystem] time.phase_changed 페이로드 무시: %s" % [p])
		return
	phase = to
	day = d
	if phase == PHASE_CLOSE and (not _agents.is_empty() or not _arrivals.is_empty()):
		push_warning("[AudienceSystem] close 진입에 에이전트 %d·도착 대기 %d 가 남았다(공연 끝 처리 누락, 계약 위반). 비운다"
			% [_agents.size(), _arrivals.size()])
		_clear_crowd()


func _on_day_started(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	if not (d is int) or d < NEW_GAME_DAY:
		push_warning("[AudienceSystem] time.day_started 페이로드 무시: %s" % [p])
		return
	day = d
	lineup = null
	today = null
	_clear_crowd()


# --- 입장 수 (AD1~AD12) -------------------------------------------------------------

func _decide_admissions() -> void:
	var e: Dictionary = AudienceConfig.expected_by_type(config, lineup, reputation_total, ticket_price)  # AD1~AD5
	var u: int = rng.stream(STREAM).randi()                                                      # AD7 (항상 1회)
	var res: Dictionary = AudienceConfig.admissions_from(e, u, coverage["capacity"], coverage["has_stage"], config)
	var n: int = res["admissions"]
	var by_type: Dictionary = res["by_type"]
	var order: Array[String] = []                                                                 # AD11
	for t: String in config.type_ids():
		for i: int in int(by_type[t]):
			order.append(t)
	for i: int in range(n - 1, 0, -1):
		var j: int = rng.stream(STREAM).randi() % (i + 1)
		var tmp: String = order[i]
		order[i] = order[j]
		order[j] = tmp
	var quota: Dictionary = {}                                                                    # AD12
	var used: Dictionary = {}
	for t: String in config.type_ids():
		quota[t] = int(by_type[t]) * int(config.rule_ref(t)["bar_visit_bp"]) / config.rate_scale
		used[t] = 0
	for k: int in n:
		var t: String = order[k]
		_arrivals.append([next_id + k, t, k * config.arrival_window_ticks / n, int(used[t]) < int(quota[t])])
		used[t] = int(used[t]) + 1
	next_id += n
	today = {
		"day": day, "admissions": n, "expected": res["expected"], "noise_bp": res["noise_bp"],
		"capped_by": res["capped_by"], "has_lineup": lineup != null, "by_type": by_type.duplicate(),
		"left_early": 0, "bar_buyers": 0, "left_totals": _new_left_totals(),
	}
	bus.publish(EV_ADMISSIONS, {
		"day": day, "admissions": n, "expected": res["expected"], "noise_bp": res["noise_bp"],
		"capacity": coverage["capacity"], "capped_by": res["capped_by"], "has_lineup": lineup != null,
		"by_type": by_type.duplicate(),
	})


# --- 상태 기계 (T1~T15, P1) ---------------------------------------------------------

## 틱 시작 상태로 전이표의 행 하나(T6 연쇄 포함).
func _step(a: Dictionary, tick: int) -> void:
	match a["state"]:
		S_QUEUED:
			_step_queued(a, tick)
		S_ENTERING:
			_step_entering(a, tick)
		S_MOVING, S_LEAVING:
			_step_walk(a, tick)
		S_AT_BAR:
			_step_bar(a, tick)
		_:
			pass                                                                                  # T14 watching, T15 gone


## T2·T3.
func _step_queued(a: Dictionary, tick: int) -> void:
	for e: Array in _entrances:
		if _occ_at(e) == 0:
			a["state"] = S_ENTERING
			a["tile"] = e.duplicate()
			a["enter_left"] = config.entry_ticks
			_occ_add(e, 1)
			return
	_add_wait(a, 1, tick)


## T4·T5.
func _step_entering(a: Dictionary, tick: int) -> void:
	if int(a["enter_left"]) > 1:
		a["enter_left"] = int(a["enter_left"]) - 1
		return
	a["enter_left"] = 0
	a["state"] = S_MOVING
	if a["bar_planned"] and not _pick(a, _bar_rank, TK_BAR):
		a["bar_planned"] = false
		_add_wait(a, config.bar_fail_wait_ticks, tick)
	if not a["left_early"] and a["target_kind"] == TK_NONE and not _pick(a, _spot_rank[a["type"]], TK_SPOT):
		_leave(a, REASON_NO_SPOT, tick)


## T6~T9·T12·T13.
func _step_walk(a: Dictionary, tick: int) -> void:
	var path: Array = a["path"]
	if a["next"] != null:                                                                         # T6
		a["progress"] = int(a["progress"]) + 1
		if int(a["progress"]) >= config.move_ticks_per_tile:
			a["tile"] = a["next"]
			a["next"] = null
			a["progress"] = 0
			if path.is_empty():
				_arrive(a)
		return
	if path.is_empty():                                                                           # T9·T13
		_arrive(a)
		return
	if a["state"] == S_LEAVING or _occ_at(path[0]) < config.pass_tile_cap \
			or int(a["blocked"]) >= config.pass_override_ticks:                                   # T12·T7
		var nxt: Array = path.pop_front()
		_occ_add(a["tile"], -1)
		_occ_add(nxt, 1)
		a["next"] = nxt
		a["progress"] = 1
		a["blocked"] = 0
		return
	a["blocked"] = int(a["blocked"]) + 1                                                          # T8
	_add_wait(a, 1, tick)


## T9 (moving → at_bar·watching), T13 (leaving → gone).
func _arrive(a: Dictionary) -> void:
	if a["state"] == S_LEAVING:
		a["state"] = S_GONE
		_occ_add(a["tile"], -1)
	elif a["target_kind"] == TK_BAR:
		a["state"] = S_AT_BAR
		a["bar_left"] = config.bar_ticks
	else:
		a["state"] = S_WATCHING


## T10·T11.
func _step_bar(a: Dictionary, tick: int) -> void:
	if int(a["bar_left"]) > 1:
		a["bar_left"] = int(a["bar_left"]) - 1
		return
	a["bar_left"] = 0
	if today != null:
		today["bar_buyers"] = int(today["bar_buyers"]) + 1
	a["bar_planned"] = false
	_release(a)
	a["state"] = S_MOVING
	if not _pick(a, _spot_rank[a["type"]], TK_SPOT):
		_leave(a, REASON_NO_SPOT, tick)


## "대기 +k" 후 P1 검사. leaving 은 여기에 오지 않는다(T12 는 막히지 않는다).
func _add_wait(a: Dictionary, k: int, tick: int) -> void:
	a["wait"] = int(a["wait"]) + k
	if not a["left_early"] and int(a["wait"]) > int(config.rule_ref(a["type"])["patience_ticks"]):
		_leave(a, REASON_PATIENCE, tick)


## SP4. 순위 앞에서부터 claims < spot_tile_cap 이고 경로가 있는 첫 타일을 예약한다. 출발 = next ?? tile.
func _pick(a: Dictionary, rank: Array, kind: String) -> bool:
	var start: Array = a["next"] if a["next"] != null else a["tile"]
	for t: Array in rank:
		if _claims_at(t) >= config.spot_tile_cap:
			continue
		var p: Array = _tile_path.find_path(start, t)
		if p.is_empty():
			continue
		p.pop_front()
		a["target"] = t.duplicate()
		a["target_kind"] = kind
		a["path"] = p
		_claim_add(t, 1)
		return true
	return false


## P1 조기 퇴장. 만족 확정(crowd 0) → 예약 해제 → queued 면 gone, 아니면 leaving + SP5 출구 → agent_left.
func _leave(a: Dictionary, reason: String, tick: int) -> void:
	var comp: Dictionary = AudienceConfig.agent_satisfaction(config, a, lineup, ticket_price, LEAVER_CROWD_BP,
		coverage["satisfaction_bonus_bp"])
	var sat: int = comp[AudienceConfig.KEY_SATISFACTION]
	a["sat"] = sat
	a["left_early"] = true
	_release(a)
	a["bar_planned"] = false
	if today != null:
		today["left_early"] = int(today["left_early"]) + 1
		_accumulate_left(a["type"], comp)
	if a["state"] == S_QUEUED:
		a["state"] = S_GONE
	else:
		a["state"] = S_LEAVING
		var start: Array = a["next"] if a["next"] != null else a["tile"]
		var best: Array = []
		var best_exit: Variant = null
		for e: Array in _entrances:                                                               # SP5
			var p: Array = _tile_path.find_path(start, e)
			if not p.is_empty() and (best_exit == null or p.size() < best.size()):
				best = p
				best_exit = e
		if best_exit == null:
			push_warning("[AudienceSystem] SP5 에이전트 %d 의 출구 경로가 없다(%s). 그 자리에서 나간다" % [a["id"], start])
			best = [start]
			best_exit = start
		best.pop_front()
		a["target"] = (best_exit as Array).duplicate()
		a["target_kind"] = TK_EXIT
		a["path"] = best
	bus.publish(EV_LEFT, {
		"day": day, "tick": tick, "agent_id": a["id"], "type": a["type"], "reason": reason, "satisfaction_bp": sat,
	})


## SF0.
func _collect_show(a: Dictionary) -> void:
	a["show_ticks"] = int(a["show_ticks"]) + 1
	if a["state"] == S_WATCHING or a["state"] == S_AT_BAR:
		var k: int = _key(a["tile"])
		if _sound.has(k):
			a["sound_ticks"] = int(a["sound_ticks"]) + 1
		if _sight.has(k):
			a["sight_ticks"] = int(a["sight_ticks"]) + 1


# --- 공연 끝 (FN1~FN4) ---------------------------------------------------------------

## FN1~FN3 후 audience.day_summary 페이로드를 돌려준다(발행은 UP6).
func _finish_show() -> Dictionary:
	if not _arrivals.is_empty():
		push_error("[AudienceSystem] FN2 공연 끝에 도착하지 않은 에이전트 %d 명(데이터 오류 — AL6). 집계에서 뺀다" % _arrivals.size())
		_arrivals.clear()
	var t: Dictionary = today if today != null else {}
	var adm: int = int(t.get("admissions", 0))
	var left: int = int(t.get("left_early", 0))
	var aud: int = maxi(0, adm - left)                                                            # FN1
	var crowd: int = AudienceConfig.crowd_bp_of(config, aud, coverage["capacity"])
	var bonus: int = coverage["satisfaction_bonus_bp"]
	var totals: Dictionary = (t["left_totals"] as Dictionary).duplicate(true) if today != null else _new_left_totals()
	for a: Dictionary in _agents:
		if not a["left_early"]:                                                                   # FN2
			var comp: Dictionary = AudienceConfig.agent_satisfaction(config, a, lineup, ticket_price, crowd, bonus)
			a["sat"] = comp[AudienceConfig.KEY_SATISFACTION]
			_add_components(totals, a["type"], comp)
		a["state"] = S_GONE                                                                       # FN3
	_occ.clear()
	_claims.clear()
	var comps: Dictionary = {}
	for k: String in AudienceConfig.COMPONENT_KEYS:
		comps[k] = int(totals[k]) / adm if adm > 0 else 0
	var by_type: Dictionary = {}
	var t_by: Dictionary = t.get("by_type", {})
	for id: String in config.type_ids():
		var n: int = int(t_by.get(id, 0))
		var row: Dictionary = totals["by_type"][id]
		by_type[id] = {
			"admissions": n, "left_early": row["left_early"],
			"avg_satisfaction_bp": int(row[AudienceConfig.KEY_SATISFACTION]) / n if n > 0 else 0,
		}
	return {
		"day": day,
		"has_lineup": t.get("has_lineup", false),
		"admissions": adm,
		"audience": aud,
		"left_early": left,
		"bar_buyers": int(t.get("bar_buyers", 0)),
		"avg_satisfaction_bp": int(totals[AudienceConfig.KEY_SATISFACTION]) / adm if adm > 0 else 0,   # SF9
		"crowd_bp": crowd,
		"avg_components": comps,
		"by_type": by_type,
	}


## {satisfaction_bp, lineup_bp, …, wait_bp, by_type: {type: {left_early, satisfaction_bp}}} 0 으로.
func _new_left_totals() -> Dictionary:
	var out: Dictionary = {AudienceConfig.KEY_SATISFACTION: 0}
	for k: String in AudienceConfig.COMPONENT_KEYS:
		out[k] = 0
	var by: Dictionary = {}
	for id: String in config.type_ids():
		by[id] = {"left_early": 0, AudienceConfig.KEY_SATISFACTION: 0}
	out["by_type"] = by
	return out


## 조기 퇴장자의 확정값을 today.left_totals 에 더한다.
func _accumulate_left(type_id: String, comp: Dictionary) -> void:
	var totals: Dictionary = today["left_totals"]
	_add_components(totals, type_id, comp)
	var row: Dictionary = totals["by_type"][type_id]
	row["left_early"] = int(row["left_early"]) + 1


func _add_components(totals: Dictionary, type_id: String, comp: Dictionary) -> void:
	var sat: int = comp[AudienceConfig.KEY_SATISFACTION]
	totals[AudienceConfig.KEY_SATISFACTION] = int(totals[AudienceConfig.KEY_SATISFACTION]) + sat
	for k: String in AudienceConfig.COMPONENT_KEYS:
		totals[k] = int(totals[k]) + int(comp[k])
	var row: Dictionary = totals["by_type"][type_id]
	row[AudienceConfig.KEY_SATISFACTION] = int(row[AudienceConfig.KEY_SATISFACTION]) + sat


# --- 표시 좌표·발행 ------------------------------------------------------------------

func _moved_payload() -> Array:
	var out: Array = []
	for a: Dictionary in _agents:
		var xy: Array = _display(a)
		out.append([a["id"], xy[0], xy[1], a["state"], a["type"]])
	return out


## #표시-좌표: queued 또는 tile == null → c(entrances[0]), 건너는 중 → 보간, 그 밖 → c(tile).
func _display(a: Dictionary) -> Array:
	if a["state"] == S_QUEUED or a["tile"] == null:
		return _center(_entrances[0])
	var c: Array = _center(a["tile"])
	if a["next"] == null:
		return c
	var n: Array = _center(a["next"])
	var pr: int = a["progress"]
	var m: int = config.move_ticks_per_tile
	return [c[0] + (n[0] - c[0]) * pr / m, c[1] + (n[1] - c[1]) * pr / m]


func _center(t: Array) -> Array:
	var p: int = config.pos_scale
	var half: int = p / AudienceConfig.POS_HALF_DIVISOR
	return [int(t[0]) * p + half, int(t[1]) * p + half]


# --- 파생값 -------------------------------------------------------------------------

func _new_agent(arr: Array) -> Dictionary:
	return {
		"id": arr[A_ID], "type": arr[A_TYPE], "state": S_QUEUED, "tile": null, "next": null, "progress": 0,
		"target": null, "target_kind": TK_NONE, "path": [], "enter_left": 0, "bar_left": 0, "bar_planned": arr[A_BAR],
		"wait": 0, "blocked": 0, "show_ticks": 0, "sound_ticks": 0, "sight_ticks": 0, "left_early": false, "sat": SAT_UNSET,
	}


func _empty_coverage() -> Dictionary:
	return {
		"has_stage": false, "capacity": 0, "satisfaction_bonus_bp": 0, "viewing_tiles": [], "sound_tiles": [],
		"sight_tiles": [], "bar_tiles": [], "blocked_cells": [],
	}


## SP1~SP3 자리 순위와 음향·시야 집합.
func _rebuild_ranks() -> void:
	_sound = _set_of(coverage["sound_tiles"])
	_sight = _set_of(coverage["sight_tiles"])
	var bar: Dictionary = _set_of(coverage["bar_tiles"])
	var view: Array = coverage["viewing_tiles"]
	var spot_c: Array = coverage["sound_tiles"] if not (coverage["sound_tiles"] as Array).is_empty() else view   # SP2
	var cen: Dictionary = _centroid(spot_c)
	_spot_rank = {}
	for id: String in config.type_ids():                                                         # SP1
		var w: Dictionary = config.rule_ref(id)["spot_weights_bp"]
		var keyed: Array = []
		for t: Array in view:
			var k: int = _key(t)
			var score: int = (int(w["sound"]) if _sound.has(k) else 0) + (int(w["sight"]) if _sight.has(k) else 0) \
				+ (int(w["bar"]) if bar.has(k) else 0)
			keyed.append([-score, _cdist(t, cen), t[1], t[0], t])
		_spot_rank[id] = _sorted_tiles(keyed)
	var bar_c: Dictionary = _centroid(coverage["bar_tiles"])                                           # SP3
	var bar_keyed: Array = []
	for t: Array in coverage["bar_tiles"]:
		bar_keyed.append([_cdist(t, bar_c), t[1], t[0], t])
	_bar_rank = _sorted_tiles(bar_keyed)


## 키 배열([정렬 키…, z, x, 타일]) 을 사전순 오름차순으로 정렬해 타일 목록으로. z·x 가 타일마다 달라 전순서다.
func _sorted_tiles(keyed: Array) -> Array:
	keyed.sort_custom(func(x: Array, y: Array) -> bool: return _lex_less(x, y))
	var out: Array = []
	for k: Array in keyed:
		out.append((k.back() as Array).duplicate())
	return out


static func _lex_less(x: Array, y: Array) -> bool:
	for i: int in x.size():
		if x[i] != y[i]:
			return x[i] < y[i]
	return false


## {n, sx: Σx, sz: Σz}.
static func _centroid(tiles: Array) -> Dictionary:
	var sx: int = 0
	var sz: int = 0
	for t: Array in tiles:
		sx += int(t[0])
		sz += int(t[1])
	return {"n": tiles.size(), "sx": sx, "sz": sz}


## SP2 cdist = (x·n − Σx)² + (z·n − Σz)².
static func _cdist(t: Array, cen: Dictionary) -> int:
	var dx: int = int(t[0]) * int(cen["n"]) - int(cen["sx"])
	var dz: int = int(t[1]) * int(cen["n"]) - int(cen["sz"])
	return dx * dx + dz * dz


func _set_of(tiles: Array) -> Dictionary:
	var out: Dictionary = {}
	for t: Array in tiles:
		out[_key(t)] = true
	return out


func _rebuild_occupancy() -> void:
	_occ.clear()
	_claims.clear()
	for a: Dictionary in _agents:
		if OCCUPYING.has(a["state"]):
			_occ_add(a["next"] if a["next"] != null else a["tile"], 1)
		if CLAIM_KINDS.has(a["target_kind"]) and a["target"] != null:
			_claim_add(a["target"], 1)


func _clear_crowd() -> void:
	_arrivals.clear()
	_agents.clear()
	_occ.clear()
	_claims.clear()


func _key(t: Array) -> int:
	return int(t[1]) * map.width + int(t[0])


func _occ_at(t: Array) -> int:
	return int(_occ.get(_key(t), 0))


func _claims_at(t: Array) -> int:
	return int(_claims.get(_key(t), 0))


func _occ_add(t: Array, delta: int) -> void:
	_bump(_occ, _key(t), delta)


func _claim_add(t: Array, delta: int) -> void:
	_bump(_claims, _key(t), delta)


static func _bump(counts: Dictionary, k: int, delta: int) -> void:
	var v: int = int(counts.get(k, 0)) + delta
	if v == 0:
		counts.erase(k)
	else:
		counts[k] = v


## 예약 해제(MV3) 후 target 을 비운다.
func _release(a: Dictionary) -> void:
	if CLAIM_KINDS.has(a["target_kind"]) and a["target"] != null:
		_claim_add(a["target"], -1)
	a["target"] = null
	a["target_kind"] = TK_NONE


func _is_stat(v: Variant) -> bool:
	return v is int and v >= 0 and v <= config.stat_max


# --- 검사 (입력·RU1~RU7) ---------------------------------------------------------------

## 커버리지 8필드(입력 계약·RU2). 성공이면 정규화한 Dictionary(필드 순서 고정), 실패면 오류 문자열.
## 좌표는 int 2원소 배열이고 맵 안이어야 한다(맵 밖 좌표를 받으면 자기 스냅샷이 RU2 로 거부되므로 입력에서도 거절한다).
func _parse_coverage(d: Variant) -> Variant:
	if not (d is Dictionary):
		return "coverage 가 객체가 아니다"
	for k: String in COVERAGE_FIELDS:
		if not (d as Dictionary).has(k):
			return "coverage 필드 누락: %s" % k
	if not (d["has_stage"] is bool):
		return "coverage.has_stage 가 bool 이 아니다: %s" % [d["has_stage"]]
	var out: Dictionary = {"has_stage": d["has_stage"]}
	for k: String in COVERAGE_INT_FIELDS:
		var v: Variant = JsonUtil.as_int(d[k])
		if v == null or v < 0:
			return "coverage.%s 가 0 이상 정수가 아니다: %s" % [k, d[k]]
		out[k] = v
	for k: String in COVERAGE_TILE_FIELDS:
		var raw: Variant = d[k]
		if not (raw is Array):
			return "coverage.%s 가 배열이 아니다" % k
		var tiles: Array = []
		for c: Variant in raw:
			var t: Variant = _tile_of(c)
			if t == null:
				return "coverage.%s 원소가 맵 안 [x, z] 정수 쌍이 아니다: %s" % [k, c]
			tiles.append(t)
		out[k] = tiles
	var ordered: Dictionary = {}
	for k: String in COVERAGE_FIELDS:
		ordered[k] = out[k]
	return ordered


## 맵 안 [x, z] 정수 쌍이면 [x, z](int), 아니면 null.
func _tile_of(v: Variant) -> Variant:
	var t: Variant = JsonUtil.as_int_pair(v)
	if t == null or not map.in_bounds(t[0], t[1]):
		return null
	return t


## RU1~RU7. 성공이면 적용할 Dictionary(정규화한 깊은 복사), 실패면 오류 문자열.
func _parse_snapshot(d: Dictionary) -> Variant:
	for k: String in SNAPSHOT_FIELDS:                                                            # RU1
		if not d.has(k):
			return "RU1 필드 누락: %s" % k
	var ints: Dictionary = {}
	for k: String in ["day", "ticket_price", "reputation_total", "next_id"]:
		var v: Variant = JsonUtil.as_int(d[k])
		if v == null:
			return "RU1 %s 가 정수가 아니다: %s" % [k, d[k]]
		ints[k] = v
	var ph: Variant = d["phase"]
	if not (ph is String or ph is StringName) or not SimConfig.PHASE_IDS.has(String(ph)):
		return "RU1 phase 가 구간 id 가 아니다: %s" % [ph]
	if ints["day"] < NEW_GAME_DAY or ints["ticket_price"] < 1 or ints["reputation_total"] < 0 or ints["next_id"] < FIRST_ID:
		return "RU1 범위 위반(day ≥ 1, ticket_price ≥ 1, reputation_total ≥ 0, next_id ≥ 1): %s" % [ints]
	if not (d["lineup"] == null or d["lineup"] is Dictionary) or not (d["today"] == null or d["today"] is Dictionary):
		return "RU1 lineup·today 는 객체 또는 null 이어야 한다"
	if not (d["arrivals"] is Array) or not (d["agents"] is Array):
		return "RU1 arrivals·agents 는 배열이어야 한다"
	var cov: Variant = _parse_coverage(d["coverage"])                                            # RU2
	if cov is String:
		return "RU2 " + String(cov)
	var lu: Variant = _parse_lineup(d["lineup"])                                                 # RU3
	if lu is String:
		return lu
	var td: Variant = _parse_today(d["today"])                                                   # RU4
	if td is String:
		return td
	var arrivals_out: Array = []                                                                  # RU5·RU6
	var agents_out: Array = []
	for raw: Variant in d["agents"]:
		var ag: Variant = _parse_agent(raw)
		if ag is String:
			return ag
		agents_out.append(ag)
	for raw: Variant in d["arrivals"]:
		var ar: Variant = _parse_arrival(raw)
		if ar is String:
			return ar
		arrivals_out.append(ar)
	if agents_out.size() + arrivals_out.size() > config.max_agents:
		return "RU5 arrivals + agents %d 명이 max_agents %d 를 넘는다" % [agents_out.size() + arrivals_out.size(), config.max_agents]
	var last_id: int = 0
	for ag: Dictionary in agents_out:
		if int(ag["id"]) <= last_id or int(ag["id"]) >= ints["next_id"]:
			return "RU5 에이전트 id %d 가 엄격히 증가하지 않거나 next_id %d 이상이다" % [ag["id"], ints["next_id"]]
		last_id = ag["id"]
	for ar: Array in arrivals_out:
		if int(ar[A_ID]) <= last_id or int(ar[A_ID]) >= ints["next_id"]:
			return "RU5 도착 대기 id %d 가 엄격히 증가하지 않거나 next_id %d 이상이다" % [ar[A_ID], ints["next_id"]]
		last_id = ar[A_ID]
	var claims: Dictionary = {}                                                                   # RU7
	for ag: Dictionary in agents_out:
		if CLAIM_KINDS.has(ag["target_kind"]) and ag["target"] != null:
			var k: int = _key(ag["target"])
			claims[k] = int(claims.get(k, 0)) + 1
			if int(claims[k]) > config.spot_tile_cap:
				return "RU7 자리 %s 의 예약 수가 spot_tile_cap %d 를 넘는다" % [ag["target"], config.spot_tile_cap]
	return {
		"day": ints["day"], "phase": String(ph), "ticket_price": ints["ticket_price"],
		"reputation_total": ints["reputation_total"], "lineup": lu, "coverage": cov, "today": td,
		"arrivals": arrivals_out, "agents": agents_out, "next_id": ints["next_id"],
	}


## RU3.
func _parse_lineup(v: Variant) -> Variant:
	if v == null:
		return null
	for k: String in LINEUP_FIELDS:
		if not (v as Dictionary).has(k):
			return "RU3 lineup 필드 누락: %s" % k
	var aid: Variant = v["artist_id"]
	var genre: Variant = v["genre"]
	var pop: Variant = JsonUtil.as_int(v["popularity"])
	var skill: Variant = JsonUtil.as_int(v["skill"])
	if not (aid is String or aid is StringName) or not (genre is String or genre is StringName) \
			or not config.genres.has(String(genre)) or not _is_stat(pop) or not _is_stat(skill):
		return "RU3 lineup 이 잘못됐다(artist_id 문자열, genre ∈ genre_fit_bp 키, 인기·실력 0~%d): %s" % [config.stat_max, v]
	return {
		"artist_id": String(aid), "genre": String(genre), "grade": JsonUtil.int_deep(v["grade"]), "popularity": pop,
		"skill": skill,
	}


## RU4.
func _parse_today(v: Variant) -> Variant:
	if v == null:
		return null
	for k: String in TODAY_FIELDS:
		if not (v as Dictionary).has(k):
			return "RU4 today 필드 누락: %s" % k
	var out: Dictionary = {}
	for k: String in TODAY_FIELDS:
		out[k] = null
	for k: String in TODAY_INT_FIELDS:
		var n: Variant = JsonUtil.as_int(v[k])
		if n == null:
			return "RU4 today.%s 가 정수가 아니다: %s" % [k, v[k]]
		out[k] = n
	if not (v["capped_by"] is String) or not AudienceConfig.CAPPED_LABELS.has(v["capped_by"]) or not (v["has_lineup"] is bool):
		return "RU4 today.capped_by·has_lineup 이 잘못됐다: %s, %s" % [v["capped_by"], v["has_lineup"]]
	out["capped_by"] = v["capped_by"]
	out["has_lineup"] = v["has_lineup"]
	if out["day"] < NEW_GAME_DAY or out["expected"] < 0 or out["bar_buyers"] < 0 or out["left_early"] < 0 \
			or out["left_early"] > out["admissions"] or out["admissions"] > config.max_agents:
		return "RU4 today 범위 위반(0 ≤ left_early ≤ admissions ≤ max_agents %d 등): %s" % [config.max_agents, v]
	var by: Variant = _parse_type_map(v["by_type"], "today.by_type")
	if by is String:
		return by
	out["by_type"] = by
	var lt: Variant = _parse_left_totals(v["left_totals"])
	if lt is String:
		return lt
	out["left_totals"] = lt
	return out


## {type: int ≥ 0}, 키 집합 == 유형 id. 유형 순서로 다시 담는다.
func _parse_type_map(v: Variant, label: String) -> Variant:
	if not (v is Dictionary) or (v as Dictionary).size() != config.type_ids().size():
		return "RU4 %s 키가 유형 id 전부와 다르다: %s" % [label, v]
	var out: Dictionary = {}
	for id: String in config.type_ids():
		var n: Variant = JsonUtil.as_int((v as Dictionary).get(id))
		if n == null or n < 0:
			return "RU4 %s.%s 가 0 이상 정수가 아니다: %s" % [label, id, v]
		out[id] = n
	return out


func _parse_left_totals(v: Variant) -> Variant:
	if not (v is Dictionary):
		return "RU4 today.left_totals 가 객체가 아니다"
	var out: Dictionary = {}
	var keys: Array[String] = [AudienceConfig.KEY_SATISFACTION]
	keys.append_array(AudienceConfig.COMPONENT_KEYS)
	for k: String in keys:
		var n: Variant = JsonUtil.as_int((v as Dictionary).get(k))
		if n == null or n < 0:
			return "RU4 today.left_totals.%s 가 0 이상 정수가 아니다: %s" % [k, (v as Dictionary).get(k)]
		out[k] = n
	var by: Variant = (v as Dictionary).get("by_type")
	if not (by is Dictionary) or (by as Dictionary).size() != config.type_ids().size():
		return "RU4 today.left_totals.by_type 키가 유형 id 전부와 다르다"
	var by_out: Dictionary = {}
	for id: String in config.type_ids():
		var row: Variant = (by as Dictionary).get(id)
		if not (row is Dictionary):
			return "RU4 today.left_totals.by_type.%s 가 객체가 아니다" % id
		var r: Dictionary = {}
		for k: String in LEFT_BY_TYPE_FIELDS:
			var n: Variant = JsonUtil.as_int((row as Dictionary).get(k))
			if n == null or n < 0:
				return "RU4 today.left_totals.by_type.%s.%s 가 0 이상 정수가 아니다" % [id, k]
			r[k] = n
		by_out[id] = r
	out["by_type"] = by_out
	return out


## RU5 원소 [id, type, spawn_tick, bar_planned].
func _parse_arrival(v: Variant) -> Variant:
	if not (v is Array) or (v as Array).size() != ARRIVAL_SIZE:
		return "RU5 arrivals 원소는 [id, type, spawn_tick, bar_planned] 이어야 한다: %s" % [v]
	var id: Variant = JsonUtil.as_int(v[A_ID])
	var spawn: Variant = JsonUtil.as_int(v[A_SPAWN])
	if id == null or id < FIRST_ID or spawn == null or spawn < 0 or not config.has_type(v[A_TYPE]) or not (v[A_BAR] is bool):
		return "RU5 arrivals 원소 타입 오류: %s" % [v]
	return [id, String(v[A_TYPE]), spawn, v[A_BAR]]


## RU6 에이전트 레코드 19키.
func _parse_agent(v: Variant) -> Variant:
	if not (v is Dictionary):
		return "RU6 에이전트가 객체가 아니다"
	for k: String in AGENT_FIELDS:
		if not (v as Dictionary).has(k):
			return "RU6 에이전트 필드 누락: %s" % k
	var out: Dictionary = {}
	for k: String in AGENT_FIELDS:
		out[k] = null
	var id: Variant = JsonUtil.as_int(v["id"])
	if id == null or id < FIRST_ID:
		return "RU6 에이전트 id 가 1 이상 정수가 아니다: %s" % [v["id"]]
	out["id"] = id
	if not config.has_type(v["type"]):
		return "RU6 에이전트 %d 의 type '%s' 가 유형 id 가 아니다" % [id, v["type"]]
	out["type"] = String(v["type"])
	if not (v["state"] is String or v["state"] is StringName) or not STATES.has(String(v["state"])):
		return "RU6 에이전트 %d 의 state '%s' 가 7종이 아니다" % [id, v["state"]]
	out["state"] = String(v["state"])
	for k: String in AGENT_TILE_FIELDS:
		if v[k] == null:
			continue
		var t: Variant = _tile_of(v[k])
		if t == null:
			return "RU6 에이전트 %d 의 %s 가 맵 안 [x, z] 가 아니다: %s" % [id, k, v[k]]
		out[k] = t
	if not (v["target_kind"] is String) or not TARGET_KINDS.has(v["target_kind"]):
		return "RU6 에이전트 %d 의 target_kind '%s' 가 잘못됐다" % [id, v["target_kind"]]
	out["target_kind"] = v["target_kind"]
	if not (v["path"] is Array):
		return "RU6 에이전트 %d 의 path 가 배열이 아니다" % id
	var path: Array = []
	for c: Variant in v["path"]:
		var t: Variant = _tile_of(c)
		if t == null:
			return "RU6 에이전트 %d 의 path 원소가 맵 안 [x, z] 가 아니다: %s" % [id, c]
		path.append(t)
	out["path"] = path
	for k: String in AGENT_COUNT_FIELDS:
		var n: Variant = JsonUtil.as_int(v[k])
		if n == null or n < 0:
			return "RU6 에이전트 %d 의 %s 가 0 이상 정수가 아니다: %s" % [id, k, v[k]]
		out[k] = n
	for k: String in AGENT_BOOL_FIELDS:
		if not (v[k] is bool):
			return "RU6 에이전트 %d 의 %s 가 bool 이 아니다" % [id, k]
		out[k] = v[k]
	var sat: Variant = JsonUtil.as_int(v["sat"])
	if sat == null or not (sat == SAT_UNSET or (sat >= 0 and sat <= config.rate_scale)):
		return "RU6 에이전트 %d 의 sat 이 −1 또는 0~%d 가 아니다: %s" % [id, config.rate_scale, v["sat"]]
	out["sat"] = sat
	if (out["state"] == S_QUEUED) != (out["tile"] == null):
		return "RU6 에이전트 %d: queued ⇔ tile == null 이 아니다(state %s, tile %s)" % [id, out["state"], out["tile"]]
	if out["progress"] > config.move_ticks_per_tile:
		return "RU6 에이전트 %d 의 progress %d 가 0~%d 밖이다" % [id, out["progress"], config.move_ticks_per_tile]
	if (out["next"] == null) != (out["progress"] == 0):
		return "RU6 에이전트 %d: next == null ⇔ progress == 0 이 아니다" % id
	return out
