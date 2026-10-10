class_name AudienceConfig
extends RefCounted
## 관객 설정 (SE-034). audience.json + (읽기 전용) artist.json·genres.json·economy.json·sim.json·tier1_club.json.
## 규칙: docs/gdd/audience.md #설정-로드-검사 AL1~AL10, #공개-api, #입장-수 AD1~AD10, #만족 SF1~SF8.
## 스키마로 못 하는 교차 검사와, 테스트 사본이 빠뜨릴 수 있는 필드·타입 검사를 한다. 실패하면 push_error 1회, null.
## JSON 숫자의 정수값 float 는 int 로 정규화해 보관한다(JsonUtil). 모든 필드는 읽기 전용으로 취급한다.
## 정적 순수 함수 3개(expected_by_type·admissions_from·agent_satisfaction)는 상태·이벤트·난수가 없다.

const DEFAULT_PATH: String = "res://data/audience/audience.json"
const ARTIST_PATH: String = "res://data/artist/artist.json"
const GENRES_PATH: String = "res://data/genres/genres.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const SIM_PATH: String = "res://data/sim/sim.json"
const MAP_PATH: String = MapConfig.DEFAULT_PATH
const LOG_TAG: String = "AudienceConfig"

## AL1: 이 로더가 읽는 테이블 version 과 bp 분모(economy.json rate_scale, 단위 정의).
const SUPPORTED_VERSION: int = 2
const REQUIRED_RATE_SCALE: int = 10000
## AL2: MVP 관객 유형 수(PRD "MVP 관객 유형 3").
const TYPE_COUNT: int = 3
## U2: 1명 = 100 centi-person(단위 정의).
const CENTI_PER_PERSON: int = 100
## AL5: pos_scale 은 이 수의 배수(짝수)여야 타일 중앙 c(t) = x × P + P/2 가 정수다.
const POS_HALF_DIVISOR: int = 2
## AD7: noise_bp ∈ [−J, +J] → 경우의 수 2J + 1 의 "2".
const NOISE_SIDES: int = 2
## AD9 capped_by 라벨(events.md).
const CAPPED_NONE: String = "none"
const CAPPED_CAPACITY: String = "capacity"
const CAPPED_MAX_AGENTS: String = "max_agents"
const CAPPED_NO_STAGE: String = "no_stage"
const CAPPED_LABELS: Array[String] = [CAPPED_NONE, CAPPED_CAPACITY, CAPPED_MAX_AGENTS, CAPPED_NO_STAGE]
## AL6: 구간 id(sim.json phases).
const PHASE_EVENING: String = "evening"
const PHASE_SHOW: String = "show"
## 맵 타일 종류 중 입구(build.md "타일 종류").
const KIND_ENTRANCE: String = MapConfig.KIND_ENTRANCE

const ADMISSION_KEYS: Array[String] = ["price_ref", "reputation_cap", "noise_bp", "price_factor_min_bp", "price_factor_max_bp"]
const FLOW_KEYS: Array[String] = [
	"arrival_window_ticks", "entry_ticks", "move_ticks_per_tile", "spot_tile_cap", "pass_tile_cap", "bar_ticks",
	"bar_fail_wait_ticks", "pass_override_ticks",
]
## 0 이 허용되지 않는 흐름 값(스키마 minimum 1).
const FLOW_POSITIVE_KEYS: Array[String] = [
	"arrival_window_ticks", "entry_ticks", "move_ticks_per_tile", "spot_tile_cap", "pass_tile_cap", "bar_ticks",
	"pass_override_ticks",
]
const SAT_INT_KEYS: Array[String] = ["skill_base_bp", "skill_bp_per_point", "no_lineup_bp", "price_value_mid_bp", "crowd_comfort_bp"]
const WEIGHT_KEYS: Array[String] = ["lineup", "sound", "sight", "value"]
const PENALTY_KEYS: Array[String] = ["crowd", "wait"]
const SPOT_WEIGHT_KEYS: Array[String] = ["sound", "sight", "bar"]
const TYPE_INT_KEYS: Array[String] = [
	"base_centi", "popularity_centi", "reputation_centi", "price_sensitivity_bp", "bar_visit_bp", "patience_ticks",
]
## agent_satisfaction 결과 요소 키(day_summary.avg_components 와 같은 이름·순서).
const COMPONENT_KEYS: Array[String] = ["lineup_bp", "sound_bp", "sight_bp", "value_bp", "wait_bp"]
const KEY_SATISFACTION: String = "satisfaction_bp"

var version: int = 0
## economy.json rate_scale (bp 분모).
var rate_scale: int = 0
var max_agents: int = 0
var pos_scale: int = 0
## artist.json stat_max (라인업 인기·실력 상한, LS3·RU3).
var stat_max: int = 0
## artist.json mvp_genres (genre_fit_bp 키 집합, 데이터 순서).
var genres: Array[String] = []
## sim.json 구간 틱 수.
var evening_ticks: int = 0
var show_ticks: int = 0
## economy.json rows[맵 티어].ticket_price_default (새 게임 ticket_price).
var ticket_price_default: int = 0

# admission (AD1~AD9)
var price_ref: int = 0
var reputation_cap: int = 0
var noise_bp: int = 0
var price_factor_min_bp: int = 0
var price_factor_max_bp: int = 0
# flow (T1~T15)
var arrival_window_ticks: int = 0
var entry_ticks: int = 0
var move_ticks_per_tile: int = 0
var spot_tile_cap: int = 0
var pass_tile_cap: int = 0
var bar_ticks: int = 0
var bar_fail_wait_ticks: int = 0
var pass_override_ticks: int = 0
# satisfaction (SF1~SF8)
var weight_lineup_bp: int = 0
var weight_sound_bp: int = 0
var weight_sight_bp: int = 0
var weight_value_bp: int = 0
var penalty_crowd_bp: int = 0
var penalty_wait_bp: int = 0
var skill_base_bp: int = 0
var skill_bp_per_point: int = 0
var no_lineup_bp: int = 0
var price_value_mid_bp: int = 0
var crowd_comfort_bp: int = 0

## 깊은 복사본을 돌려주는 읽기 전용 속성(공개 API).
var admission: Dictionary:
	get:
		return _admission.duplicate(true)
var flow: Dictionary:
	get:
		return _flow.duplicate(true)
var satisfaction: Dictionary:
	get:
		return _satisfaction.duplicate(true)
## checks·reference_scenarios 는 런타임이 읽지 않는다(테스트·qa 용).
var checks: Dictionary:
	get:
		return _checks.duplicate(true)

var _admission: Dictionary = {}
var _flow: Dictionary = {}
var _satisfaction: Dictionary = {}
var _checks: Dictionary = {}
var _scenarios: Array = []
var _type_ids: Array[String] = []
var _types: Dictionary = {}      # id -> 정규화한 유형 행
var _entrances: Array = []       # [x, z], z → x 오름차순


## audience.json 과 나머지 5개 테이블을 기본 경로에서 읽어(읽기 전용) 검증한다. 실패하면 push_error, null.
static func load(path: String = DEFAULT_PATH) -> AudienceConfig:
	var a: Variant = JsonUtil.read_json(path, LOG_TAG)
	var art: Variant = JsonUtil.read_json(ARTIST_PATH, LOG_TAG)
	var g: Variant = JsonUtil.read_json(GENRES_PATH, LOG_TAG)
	var e: Variant = JsonUtil.read_json(ECONOMY_PATH, LOG_TAG)
	var s: Variant = JsonUtil.read_json(SIM_PATH, LOG_TAG)
	var m: Variant = JsonUtil.read_json(MAP_PATH, LOG_TAG)
	if a == null or art == null or g == null or e == null or s == null or m == null:
		return null
	return from_dicts(a, art, g, e, s, m)


## 메모리 상 Dictionary(JSON 파싱 결과와 같은 모양)에서 만든다. 테스트의 변형 사본 검증용.
static func from_dicts(audience: Dictionary, artist: Dictionary, genres_d: Dictionary, economy: Dictionary, sim: Dictionary, map: Dictionary) -> AudienceConfig:
	var cfg: AudienceConfig = AudienceConfig.new()
	var err: String = cfg._parse(audience, artist, genres_d, economy, sim, map)
	if err != "":
		push_error("[%s] %s" % [LOG_TAG, err])
		return null
	return cfg


# --- 읽기 전용 조회 ---------------------------------------------------------------

## 유형 id(데이터 순서 = 유형 순서, 복사본).
func type_ids() -> Array[String]:
	return _type_ids.duplicate()


func has_type(id: Variant) -> bool:
	return (id is String or id is StringName) and _types.has(String(id))


## 유형 행의 깊은 복사본. 없으면 {}.
func type_rule(id: String) -> Dictionary:
	if not _types.has(id):
		return {}
	return (_types[id] as Dictionary).duplicate(true)


## 유형 행 참조(복사 없음, 호출자는 바꾸지 않는다 — 시뮬레이션 핫패스용, FurnitureConfig.row_ref 와 같은 규약).
func rule_ref(id: String) -> Dictionary:
	return _types[id]


## 유형 색(군중 인스턴스, SE-038). 없으면 "".
func color(id: String) -> String:
	if not _types.has(id):
		return ""
	return _types[id]["color"]


## 맵(tier1_club.json)의 입구 타일 [x, z] 목록, z → x 오름차순(복사본).
func entrances() -> Array:
	return _entrances.duplicate(true)


## id 로 기준 시나리오(복사본). 없으면 {}, 오류 없음.
func scenario(id: String) -> Dictionary:
	for sc: Dictionary in _scenarios:
		if sc.get("id") == id:
			return sc.duplicate(true)
	return {}


func scenario_ids() -> Array[String]:
	var out: Array[String] = []
	for sc: Dictionary in _scenarios:
		out.append(sc["id"])
	return out


# --- 정적 순수 함수 ---------------------------------------------------------------

## AD1~AD5 → {type: e_t (centi)}, 키 순서 = 유형 순서. lineup = null 또는 {genre, popularity, …}.
static func expected_by_type(cfg: AudienceConfig, lineup: Variant, reputation_total: int, ticket_price: int) -> Dictionary:
	var out: Dictionary = {}
	var rep: int = clampi(reputation_total, 0, cfg.reputation_cap)                               # AD1
	for id: String in cfg._type_ids:
		var r: Dictionary = cfg._types[id]
		if r["needs_lineup"] and lineup == null:                                                  # AD2
			out[id] = 0
			continue
		var draw: int = int(r["base_centi"]) + int(r["reputation_centi"]) * rep
		var fit: int = cfg.rate_scale                                                             # AD3
		if lineup != null:
			draw += int(r["popularity_centi"]) * int(lineup["popularity"])
			fit = int(r["genre_fit_bp"][lineup["genre"]])
		var price_bp: int = clampi(cfg.rate_scale - int(r["price_sensitivity_bp"]) * (ticket_price - cfg.price_ref),
			cfg.price_factor_min_bp, cfg.price_factor_max_bp)                                     # AD4
		out[id] = draw * fit / cfg.rate_scale * price_bp / cfg.rate_scale                         # AD5
	return out


## AD6~AD10 → {expected, noise_bp, raw, admissions, capped_by, by_type}. u = audience 스트림의 .randi() 값(uint32).
static func admissions_from(e_by_type: Dictionary, u: int, capacity: int, has_stage: bool, cfg: AudienceConfig) -> Dictionary:
	var e_total: int = 0
	for id: String in cfg._type_ids:
		e_total += int(e_by_type.get(id, 0))
	var j: int = cfg.noise_bp
	var noise: int = posmod(u, NOISE_SIDES * j + 1) - j                                          # AD7
	var raw: int = maxi(0, e_total * (cfg.rate_scale + noise) / (cfg.rate_scale * CENTI_PER_PERSON))  # AD8
	var adm: int = 0                                                                              # AD9
	var capped: String = CAPPED_NO_STAGE
	if has_stage:
		var limit: int = maxi(0, mini(capacity, cfg.max_agents))
		adm = mini(raw, limit)
		if raw <= limit:
			capped = CAPPED_NONE
		elif capacity <= cfg.max_agents:
			capped = CAPPED_CAPACITY
		else:
			capped = CAPPED_MAX_AGENTS
	return {
		"expected": e_total / CENTI_PER_PERSON, "noise_bp": noise, "raw": raw, "admissions": adm, "capped_by": capped,
		"by_type": split_by_type(cfg, e_by_type, adm),
	}


## AD10 최대 나머지 배분. 같은 나머지는 유형 순서가 앞인 쪽. 반환 키 순서 = 유형 순서.
static func split_by_type(cfg: AudienceConfig, e_by_type: Dictionary, admissions: int) -> Dictionary:
	var ids: Array[String] = cfg._type_ids
	var e_total: int = 0
	for id: String in ids:
		e_total += int(e_by_type.get(id, 0))
	var out: Dictionary = {}
	var rem: Array[int] = []
	var assigned: int = 0
	for id: String in ids:
		var share: int = admissions * int(e_by_type.get(id, 0))
		var n: int = share / e_total if e_total > 0 else 0
		out[id] = n
		assigned += n
		rem.append(share % e_total if e_total > 0 else 0)
	if e_total == 0:
		return out
	var order: Array[int] = []
	for i: int in ids.size():
		order.append(i)
	order.sort_custom(func(x: int, y: int) -> bool: return rem[x] > rem[y] or (rem[x] == rem[y] and x < y))
	for k: int in admissions - assigned:
		var id: String = ids[order[k]]
		out[id] = int(out[id]) + 1
	return out


## SF1~SF8 → {satisfaction_bp, lineup_bp, sound_bp, sight_bp, value_bp, wait_bp}. agent 는 에이전트 레코드(type, wait,
## show_ticks, sound_ticks, sight_ticks 를 읽는다). lineup = null 또는 {genre, skill, …}.
static func agent_satisfaction(cfg: AudienceConfig, agent: Dictionary, lineup: Variant, ticket_price: int, crowd_bp: int, bonus_bp: int) -> Dictionary:
	var r: Dictionary = cfg._types[agent["type"]]
	var scale: int = cfg.rate_scale
	var shows: int = int(agent["show_ticks"])
	var sound: int = int(agent["sound_ticks"]) * scale / shows if shows > 0 else 0                # SF1
	var sight: int = int(agent["sight_ticks"]) * scale / shows if shows > 0 else 0
	var lineup_bp: int = cfg.no_lineup_bp                                                         # SF2
	if lineup != null:
		var skill_factor: int = mini(scale, cfg.skill_base_bp + int(lineup["skill"]) * cfg.skill_bp_per_point)
		lineup_bp = int(r["genre_fit_bp"][lineup["genre"]]) * skill_factor / scale
	var value: int = clampi(cfg.price_value_mid_bp - int(r["price_sensitivity_bp"]) * (ticket_price - cfg.price_ref), 0, scale)  # SF3
	var wait_bp: int = mini(scale, int(agent["wait"]) * scale / int(r["patience_ticks"]))         # SF4
	var pos: int = cfg.weight_lineup_bp * lineup_bp + cfg.weight_sound_bp * sound + cfg.weight_sight_bp * sight \
		+ cfg.weight_value_bp * value                                                             # SF6
	var neg: int = cfg.penalty_crowd_bp * crowd_bp + cfg.penalty_wait_bp * wait_bp                # SF7
	var sat: int = mini(scale, maxi(0, pos - neg) / scale + bonus_bp)                             # SF8
	return {
		KEY_SATISFACTION: sat, "lineup_bp": lineup_bp, "sound_bp": sound, "sight_bp": sight, "value_bp": value,
		"wait_bp": wait_bp,
	}


## SF5 공통 혼잡(공연 끝 1회). 관객 0 이면 0(SF5 관객 0, SE-052). 그 밖에 capacity 0 이면 ratio = rate_scale.
static func crowd_bp_of(cfg: AudienceConfig, audience: int, capacity: int) -> int:
	if audience == 0:
		return 0
	var scale: int = cfg.rate_scale
	var ratio: int = audience * scale / capacity if capacity > 0 else scale
	if ratio <= cfg.crowd_comfort_bp:
		return 0
	return mini(scale, (ratio - cfg.crowd_comfort_bp) * scale / (scale - cfg.crowd_comfort_bp))


# --- 파싱·검사 ---------------------------------------------------------------------

## 성공이면 "", 실패면 오류 문자열(첫 위반).
func _parse(a: Dictionary, art: Dictionary, g: Dictionary, e: Dictionary, s: Dictionary, m: Dictionary) -> String:
	# AL1 버전·rate_scale
	var ver: Variant = JsonUtil.as_int(a.get("version"))
	if ver == null or ver != SUPPORTED_VERSION:
		return "AL1 version 은 %d 이어야 한다: %s" % [SUPPORTED_VERSION, a.get("version")]
	version = ver
	var rs: Variant = JsonUtil.as_int(e.get("rate_scale"))
	if rs == null or rs != REQUIRED_RATE_SCALE:
		return "AL1 economy.json rate_scale 은 %d 이어야 한다: %s" % [REQUIRED_RATE_SCALE, e.get("rate_scale")]
	rate_scale = rs
	var ma: Variant = JsonUtil.as_int(a.get("max_agents"))
	var ps: Variant = JsonUtil.as_int(a.get("pos_scale"))
	if ma == null or ma < 1 or ps == null or ps < 1:
		return "max_agents·pos_scale 은 1 이상 정수여야 한다: %s, %s" % [a.get("max_agents"), a.get("pos_scale")]
	max_agents = ma
	pos_scale = ps

	# 전역 묶음(스키마 required 필드·정수)
	var adm_err: String = _parse_int_group(a.get("admission"), ADMISSION_KEYS, [], "admission", _admission)
	if adm_err != "":
		return adm_err
	var flow_err: String = _parse_int_group(a.get("flow"), FLOW_KEYS, FLOW_POSITIVE_KEYS, "flow", _flow)
	if flow_err != "":
		return flow_err
	var sat_raw: Variant = a.get("satisfaction")
	if not (sat_raw is Dictionary):
		return "satisfaction 은 객체여야 한다"
	var sat_ints: Dictionary = {}
	var sat_err: String = _parse_int_group(sat_raw, SAT_INT_KEYS, [], "satisfaction", sat_ints)
	if sat_err != "":
		return sat_err
	var weights: Dictionary = {}
	var w_err: String = _parse_int_group(sat_raw.get("weights_bp"), WEIGHT_KEYS, [], "satisfaction.weights_bp", weights)
	if w_err != "":
		return w_err
	var penalties: Dictionary = {}
	var p_err: String = _parse_int_group(sat_raw.get("penalty_weights_bp"), PENALTY_KEYS, [], "satisfaction.penalty_weights_bp", penalties)
	if p_err != "":
		return p_err
	_satisfaction = sat_ints.duplicate()
	_satisfaction["weights_bp"] = weights
	_satisfaction["penalty_weights_bp"] = penalties
	_apply_scalars(weights, penalties)
	if crowd_comfort_bp >= rate_scale:
		return "satisfaction.crowd_comfort_bp 는 %d 미만이어야 한다(SF5 분모): %d" % [rate_scale, crowd_comfort_bp]

	# AL3 준비: artist.json mvp_genres·stat_max, genres.json ids
	var mg: Variant = art.get("mvp_genres")
	if not (mg is Array) or (mg as Array).is_empty():
		return "AL3 artist.json mvp_genres 는 비어 있지 않은 배열이어야 한다"
	for x: Variant in mg:
		if not (x is String) or genres.has(x):
			return "AL3 artist.json mvp_genres 원소는 중복 없는 문자열이어야 한다: %s" % [mg]
		genres.append(x)
	var sm: Variant = JsonUtil.as_int(art.get("stat_max"))
	if sm == null or sm < 0:
		return "artist.json stat_max 는 0 이상 정수여야 한다: %s" % [art.get("stat_max")]
	stat_max = sm
	var genre_ids: Dictionary = {}
	var grows: Variant = g.get("rows")
	if not (grows is Array):
		return "AL3 genres.json rows 는 배열이어야 한다"
	for row: Variant in grows:
		if row is Dictionary and row.get("id") is String:
			genre_ids[row["id"]] = true
	for gid: String in genres:                                                                    # AL3 (값)
		if not genre_ids.has(gid):
			return "AL3 mvp_genres '%s' 가 genres.json rows[].id 에 없다" % gid

	# AL2·AL3 유형
	var raw_types: Variant = a.get("types")
	if not (raw_types is Array) or (raw_types as Array).size() != TYPE_COUNT:
		return "AL2 types 는 %d 행이어야 한다" % TYPE_COUNT
	for rt: Variant in raw_types:
		var parsed: Variant = _parse_type(rt)
		if parsed is String:
			return parsed
		var id: String = parsed["id"]
		if _types.has(id):
			return "AL2 types id 중복: %s" % id
		_types[id] = parsed
		_type_ids.append(id)

	# AL4
	var cap: Variant = JsonUtil.as_int(s.get("individual_agent_cap"))
	if cap == null or max_agents > cap:
		return "AL4 max_agents %d 가 sim.json individual_agent_cap %s 를 넘는다" % [max_agents, s.get("individual_agent_cap")]
	# AL5
	if pos_scale % POS_HALF_DIVISOR != 0 or pos_scale % move_ticks_per_tile != 0:
		return "AL5 pos_scale %d 는 짝수이고 move_ticks_per_tile %d 로 나누어떨어져야 한다" % [pos_scale, move_ticks_per_tile]
	# AL6
	var ticks: Dictionary = {}
	var phases: Variant = s.get("phases")
	if not (phases is Array):
		return "AL6 sim.json phases 는 배열이어야 한다"
	for ph: Variant in phases:
		if ph is Dictionary and ph.get("id") is String:
			ticks[ph["id"]] = JsonUtil.as_int(ph.get("ticks"))
	if not (ticks.get(PHASE_EVENING) is int) or not (ticks.get(PHASE_SHOW) is int):
		return "AL6 sim.json phases 에 evening·show 의 정수 ticks 가 없다"
	evening_ticks = ticks[PHASE_EVENING]
	show_ticks = ticks[PHASE_SHOW]
	if arrival_window_ticks > evening_ticks or show_ticks < 1:
		return "AL6 arrival_window_ticks %d ≤ evening %d, show %d ≥ 1 이어야 한다" % [arrival_window_ticks, evening_ticks, show_ticks]
	# AL7
	var wsum: int = 0
	for k: String in WEIGHT_KEYS:
		wsum += int(weights[k])
	if wsum != rate_scale:
		return "AL7 satisfaction.weights_bp 합 %d 가 %d 가 아니다" % [wsum, rate_scale]
	# AL8
	if price_factor_min_bp > rate_scale or price_factor_max_bp < rate_scale:
		return "AL8 price_factor_min_bp %d ≤ %d ≤ price_factor_max_bp %d 가 아니다" % [price_factor_min_bp, rate_scale, price_factor_max_bp]
	# AL10
	var min_patience: int = -1
	for id: String in _type_ids:
		var p: int = int(_types[id]["patience_ticks"])
		if min_patience < 0 or p < min_patience:
			min_patience = p
	if pass_override_ticks >= min_patience:
		return "AL10 flow.pass_override_ticks %d 는 최소 patience_ticks %d 보다 작아야 한다" % [pass_override_ticks, min_patience]

	# 맵: 입구·티어·기준 배치 id
	var map_err: String = _parse_map(m)
	if map_err != "":
		return map_err
	var tier: Variant = JsonUtil.as_int(m.get("tier"))
	var tpd: Variant = _ticket_price_default(e, tier)
	if tpd == null:
		return "economy.json rows 에 맵 tier %s 의 ticket_price_default(≥ 1) 가 없다" % [m.get("tier")]
	ticket_price_default = tpd

	# AL9 기준 시나리오·checks
	return _parse_scenarios(a, art, m)


func _parse_int_group(raw: Variant, keys: Array[String], positive: Array[String], label: String, out: Dictionary) -> String:
	if not (raw is Dictionary):
		return "%s 는 객체여야 한다" % label
	for k: String in keys:
		var v: Variant = JsonUtil.as_int(raw.get(k))
		if v == null or v < 0:
			return "%s.%s 는 0 이상 정수여야 한다: %s" % [label, k, raw.get(k)]
		if positive.has(k) and v < 1:
			return "%s.%s 는 1 이상이어야 한다: %d" % [label, k, v]
		out[k] = v
	return ""


func _apply_scalars(weights: Dictionary, penalties: Dictionary) -> void:
	price_ref = _admission["price_ref"]
	reputation_cap = _admission["reputation_cap"]
	noise_bp = _admission["noise_bp"]
	price_factor_min_bp = _admission["price_factor_min_bp"]
	price_factor_max_bp = _admission["price_factor_max_bp"]
	arrival_window_ticks = _flow["arrival_window_ticks"]
	entry_ticks = _flow["entry_ticks"]
	move_ticks_per_tile = _flow["move_ticks_per_tile"]
	spot_tile_cap = _flow["spot_tile_cap"]
	pass_tile_cap = _flow["pass_tile_cap"]
	bar_ticks = _flow["bar_ticks"]
	bar_fail_wait_ticks = _flow["bar_fail_wait_ticks"]
	pass_override_ticks = _flow["pass_override_ticks"]
	weight_lineup_bp = weights["lineup"]
	weight_sound_bp = weights["sound"]
	weight_sight_bp = weights["sight"]
	weight_value_bp = weights["value"]
	penalty_crowd_bp = penalties["crowd"]
	penalty_wait_bp = penalties["wait"]
	skill_base_bp = _satisfaction["skill_base_bp"]
	skill_bp_per_point = _satisfaction["skill_bp_per_point"]
	no_lineup_bp = _satisfaction["no_lineup_bp"]
	price_value_mid_bp = _satisfaction["price_value_mid_bp"]
	crowd_comfort_bp = _satisfaction["crowd_comfort_bp"]


## 유형 행 하나(AL2·AL3 + 필드 타입). 성공이면 정규화한 Dictionary, 실패면 오류 문자열.
func _parse_type(rt: Variant) -> Variant:
	if not (rt is Dictionary) or not (rt.get("id") is String) or (rt["id"] as String).is_empty():
		return "AL2 types[] 는 id 가 있는 객체여야 한다"
	var id: String = rt["id"]
	var out: Dictionary = {"id": id, "name": str(rt.get("name", "")), "color": rt.get("color")}
	if not (out["color"] is String):
		return "types '%s' 의 color 는 문자열이어야 한다" % id
	if not (rt.get("needs_lineup") is bool):
		return "types '%s' 의 needs_lineup 은 bool 이어야 한다" % id
	out["needs_lineup"] = rt["needs_lineup"]
	for k: String in TYPE_INT_KEYS:
		var v: Variant = JsonUtil.as_int(rt.get(k))
		if v == null or v < 0:
			return "types '%s' 의 %s 는 0 이상 정수여야 한다: %s" % [id, k, rt.get(k)]
		out[k] = v
	if int(out["patience_ticks"]) < 1:
		return "types '%s' 의 patience_ticks 는 1 이상이어야 한다(SF4 분모)" % id
	var fit: Variant = rt.get("genre_fit_bp")                                                     # AL3
	if not (fit is Dictionary) or (fit as Dictionary).size() != genres.size():
		return "AL3 types '%s' 의 genre_fit_bp 키 집합이 mvp_genres %s 와 다르다" % [id, genres]
	var fit_out: Dictionary = {}
	for gid: String in genres:
		var v: Variant = JsonUtil.as_int(fit.get(gid))
		if v == null or v < 0 or v > rate_scale:
			return "AL3 types '%s' 의 genre_fit_bp.%s 가 0~%d 정수가 아니다(키 집합 == mvp_genres)" % [id, gid, rate_scale]
		fit_out[gid] = v
	out["genre_fit_bp"] = fit_out
	var sw: Dictionary = {}
	var sw_err: String = _parse_int_group(rt.get("spot_weights_bp"), SPOT_WEIGHT_KEYS, [], "types '%s'.spot_weights_bp" % id, sw)
	if sw_err != "":
		return sw_err
	out["spot_weights_bp"] = sw
	return out


## 입구 타일(z → x 오름차순)과 기준 배치 id 확인용 최소 파싱. 전체 검사는 MapConfig(MK1~MK6)가 한다.
func _parse_map(m: Dictionary) -> String:
	var kinds: Variant = m.get("tile_kinds")
	var rows: Variant = m.get("tiles")
	if not (kinds is Array) or not (rows is Array):
		return "맵 tile_kinds·tiles 는 배열이어야 한다"
	var entrance_chars: Dictionary = {}
	for k: Variant in kinds:
		if k is Dictionary and k.get("id") == KIND_ENTRANCE and k.get("char") is String:
			entrance_chars[k["char"]] = true
	for z: int in (rows as Array).size():
		var line: Variant = rows[z]
		if not (line is String):
			return "맵 tiles[%d] 는 문자열이어야 한다" % z
		for x: int in (line as String).length():
			if entrance_chars.has((line as String)[x]):
				_entrances.append([x, z])
	if _entrances.is_empty():
		return "맵에 entrance 타일이 없다"
	return ""


## 타입까지 같은 값인가(다른 타입끼리 == 비교를 피한다).
static func _same(x: Variant, y: Variant) -> bool:
	return typeof(x) == typeof(y) and x == y


static func _ticket_price_default(e: Dictionary, tier: Variant) -> Variant:
	var rows: Variant = e.get("rows")
	if tier == null or not (rows is Array):
		return null
	for r: Variant in rows:
		if r is Dictionary and JsonUtil.as_int(r.get("tier")) == tier:
			var v: Variant = JsonUtil.as_int(r.get("ticket_price_default"))
			return v if v != null and v >= 1 else null
	return null


## AL9. reference_scenarios[].layout ∈ 맵 reference_layouts id, lineup.slot ∈ roster_plan.slots 이고 장르·등급·인기·실력이
## 그 슬롯과 같음, checks 의 슬롯이 roster_plan 에 있음. 성공이면 "".
func _parse_scenarios(a: Dictionary, art: Dictionary, m: Dictionary) -> String:
	var layout_ids: Dictionary = {}
	var raw_layouts: Variant = m.get("reference_layouts", [])
	if raw_layouts is Array:
		for l: Variant in raw_layouts:
			if l is Dictionary and l.get("id") is String:
				layout_ids[l["id"]] = true
	var slots: Dictionary = {}
	var plan: Variant = art.get("roster_plan")
	if plan is Dictionary and plan.get("slots") is Array:
		for sl: Variant in plan["slots"]:
			if sl is Dictionary and sl.get("slot") is String:
				slots[sl["slot"]] = sl
	var raw: Variant = a.get("reference_scenarios", [])
	if not (raw is Array):
		return "AL9 reference_scenarios 는 배열이어야 한다"
	for sc: Variant in raw:
		if not (sc is Dictionary) or not (sc.get("id") is String):
			return "AL9 reference_scenarios[] 는 id 가 있는 객체여야 한다"
		if not layout_ids.has(sc.get("layout")):
			return "AL9 시나리오 '%s' 의 layout '%s' 가 맵 reference_layouts 에 없다" % [sc["id"], sc.get("layout")]
		var lu: Variant = sc.get("lineup")
		if lu != null:
			if not (lu is Dictionary) or not slots.has(lu.get("slot")):
				return "AL9 시나리오 '%s' 의 lineup.slot 이 roster_plan 에 없다" % sc["id"]
			var sl: Dictionary = slots[lu["slot"]]
			for k: String in ["genre", "grade", "popularity", "skill"]:
				if not _same(JsonUtil.int_deep(lu.get(k)), JsonUtil.int_deep(sl.get(k))):
					return "AL9 시나리오 '%s' 의 lineup.%s 가 roster_plan %s 와 다르다" % [sc["id"], k, lu["slot"]]
		_scenarios.append(JsonUtil.int_deep(sc))
	var ch: Variant = a.get("checks", {})
	if not (ch is Dictionary):
		return "AL9 checks 는 객체여야 한다"
	for key: String in ["local_top_slots", "rookie_slots"]:
		var list: Variant = ch.get(key, [])
		if not (list is Array):
			return "AL9 checks.%s 는 배열이어야 한다" % key
		for sid: Variant in list:
			if not slots.has(sid):
				return "AL9 checks.%s 의 슬롯 '%s' 가 roster_plan 에 없다" % [key, sid]
	_checks = JsonUtil.int_deep(ch)
	return ""
