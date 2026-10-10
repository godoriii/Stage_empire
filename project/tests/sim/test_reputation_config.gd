extends GutTest
## SE-035 — ReputationConfig. docs/gdd/reputation.md#수용-기준 RP1(RL1~RL7 교차 검사)과 공개 API 조회를 옮겼다.
## 기대 수치는 reputation.json·tiers.json·genres.json·economy.json 에서 읽는다(리터럴 임계 없음).

var _rep: Dictionary
var _artist: Dictionary
var _genres: Dictionary
var _tiers: Dictionary
var _economy: Dictionary


func before_all() -> void:
	_rep = JsonUtil.read_json(ReputationConfig.DEFAULT_PATH)
	_artist = JsonUtil.read_json(ReputationConfig.ARTIST_PATH)
	_genres = JsonUtil.read_json(ReputationConfig.GENRES_PATH)
	_tiers = JsonUtil.read_json(ReputationConfig.TIERS_PATH)
	_economy = JsonUtil.read_json(ReputationConfig.ECONOMY_PATH)


func _copies() -> Array:
	return [_rep.duplicate(true), _artist.duplicate(true), _genres.duplicate(true), _tiers.duplicate(true), _economy.duplicate(true)]


func _genre_row(genres: Dictionary, id: String) -> Dictionary:
	for r: Dictionary in genres["rows"]:
		if r["id"] == id:
			return r
	return {}


## RL1~RL7 을 하나씩 깬 사본: [라벨, push_error 문구 일부, rep, artist, genres, tiers, economy].
func _broken() -> Array:
	var out: Array = []
	var c: Array
	c = _copies(); c[0]["version"] = 2
	out.append(["version 2", "RL1"] + c)
	c = _copies(); c[4]["rate_scale"] = 1000
	out.append(["economy rate_scale 1000", "RL1"] + c)
	c = _copies(); (c[0]["base_by_grade"] as Dictionary).erase("rave")
	out.append(["base_by_grade 에서 rave 제거", "RL2"] + c)
	c = _copies(); c[0]["base_by_grade"]["ok"] = 0
	out.append(["ok: 0", "RL4"] + c)
	c = _copies(); c[0]["base_by_grade"]["poor"] = 15
	out.append(["poor: 15 (증가 위반)", "RL4"] + c)
	c = _copies(); c[0]["base_by_grade"]["poor"] = -1
	out.append(["poor: -1 (최소 Δ 0)", "RL4"] + c)
	c = _copies(); c[0]["admission_factor"]["min_bp"] = int(c[0]["admission_factor"]["max_bp"]) + 1
	out.append(["min_bp > max_bp", "RL5"] + c)
	c = _copies(); _genre_row(c[2], "indie")["affinity"]["rock"] = 0.6
	out.append(["affinity.indie.rock 0.6 (비대칭)", "RL3"] + c)
	c = _copies(); _genre_row(c[2], "rock")["affinity"]["rock"] = 0.9
	out.append(["affinity.rock.rock 0.9", "RL3"] + c)
	c = _copies(); c[0]["focus"]["breadth_min_share_bp"] = 4000
	out.append(["breadth_min_share_bp 4000", "RL6"] + c)
	c = _copies(); c[0]["tier_unlock"]["max_tier"] = 7
	out.append(["max_tier 7", "RL7"] + c)
	c = _copies(); c[0]["tier_unlock"]["max_tier"] = ReputationConfig.START_TIER
	out.append(["max_tier 1", "RL7"] + c)
	return out


# --- RP1 ------------------------------------------------------------------------

func test_config_loads_and_cross_checks() -> void:
	var cfg: ReputationConfig = ReputationConfig.load()
	assert_not_null(cfg, "실제 데이터 로드 성공")
	assert_not_null(ReputationConfig.from_dicts(_rep, _artist, _genres, _tiers, _economy), "from_dicts 도 성공")
	var broken: Array = _broken()
	assert_true(broken.size() >= 8, "RL1~RL7 을 깬 사본 8건 이상")
	var errs: int = 0
	for b: Array in broken:
		assert_null(ReputationConfig.from_dicts(b[2], b[3], b[4], b[5], b[6]), "%s → null" % b[0])
		errs += 1
		assert_push_error(b[1], "%s: 의도한 검사(%s)" % [b[0], b[1]])
		assert_push_error_count(errs, "%s: push_error 1회" % b[0])


func test_config_accessors() -> void:
	var cfg: ReputationConfig = ReputationConfig.load()
	var g: Array[String] = Array(_artist["mvp_genres"], TYPE_STRING, "", null)
	assert_eq(cfg.genre_ids(), g, "genre_ids == mvp_genres 순서")
	for grade: String in _artist["show_grades"]:
		assert_eq(cfg.base(grade), int(_rep["base_by_grade"][grade]))
	assert_eq(cfg.base("legend"), ReputationConfig.UNKNOWN_BASE)
	var af: Dictionary = _rep["admission_factor"]
	var ref: int = int(af["admissions_ref"])
	assert_eq(cfg.admission_factor_bp(ref), int(af["max_bp"]), "기준 입장 = max_bp")
	assert_eq(cfg.admission_factor_bp(0), int(af["min_bp"]), "0 명 = min_bp")
	assert_eq(cfg.admission_factor_bp(2 * ref), int(af["max_bp"]), "상한")
	var rs: int = int(_economy["rate_scale"])
	for x: String in g:
		for y: String in g:
			assert_eq(cfg.affinity_bp(x, y), roundi(float(_genre_row(_genres, x)["affinity"][y]) * rs), "U3 %s-%s" % [x, y])
	assert_eq(cfg.affinity_bp("rock", "jazz"), ReputationConfig.UNKNOWN_AFFINITY)
	assert_eq(cfg.max_tier, int(_rep["tier_unlock"]["max_tier"]))
	for r: Dictionary in _tiers["rows"]:
		var t: int = int(r["tier"])
		if t > ReputationConfig.START_TIER and t <= cfg.max_tier:
			assert_eq(cfg.tier_threshold(t), {"unlock_reputation": int(r["unlock_reputation"]), "unlock_cash": int(r["unlock_cash"])})
	assert_eq(cfg.tier_threshold(99), {})
	assert_eq(cfg.scenario("nope"), {})
	assert_eq(cfg.scenario("local_daily_good_30")["days"], int(_rep["reference_scenarios"][0]["days"]))
	assert_push_error_count(0, "조회는 오류 없음")
