class_name ReputationConfig
extends RefCounted
## 명성 설정 (SE-035). reputation.json + (읽기 전용) artist.json·genres.json·tiers.json·economy.json.
## 규칙: docs/gdd/reputation.md #설정-로드-검사 RL1~RL7, #공개-api, U3(affinity → bp), RG3(입장 계수).
## 티어 해금 임계는 tiers.json, 섭외 해금 임계는 artist.json 한 곳에만 있다(AR14) — 이 클래스는 tiers.json 값을 읽기만 한다.
## 실패하면 push_error 1회, null. 모든 필드는 읽기 전용으로 취급한다.

const DEFAULT_PATH: String = "res://data/reputation/reputation.json"
const ARTIST_PATH: String = "res://data/artist/artist.json"
const GENRES_PATH: String = "res://data/genres/genres.json"
const TIERS_PATH: String = "res://data/tiers/tiers.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const LOG_TAG: String = "ReputationConfig"

## RL1: 이 로더가 읽는 reputation.json version.
const SUPPORTED_VERSION: int = 1
## 시작 티어(reputation.md #상태 unlocked_tier 새 게임 값). 해금 판정은 START_TIER + 1 부터.
const START_TIER: int = 1
## base(grade) 가 모르는 등급에 돌려주는 값. 유효한 base 는 0 이 아니다(RL4).
const UNKNOWN_BASE: int = 0
## affinity_bp 가 모르는 장르 쌍에 돌려주는 값.
const UNKNOWN_AFFINITY: int = -1
## U3 affinity 실수 범위.
const AFFINITY_MIN: float = 0.0
const AFFINITY_MAX: float = 1.0

const FOCUS_INT_FIELDS: Array[String] = [
	"min_genre_sum", "identity_share_bp", "identity_bonus_bp", "breadth_min_share_bp", "breadth_bonus_bp",
]

var version: int = 0
var rate_scale: int = 0
## artist.json show_grades(등급 id 와 순서의 단일 출처).
var show_grades: Array[String] = []
# admission_factor
var admissions_ref: int = 0
var factor_min_bp: int = 0
var factor_max_bp: int = 0
# focus
var min_genre_sum: int = 0
var identity_share_bp: int = 0
var identity_bonus_bp: int = 0
var breadth_min_share_bp: int = 0
var breadth_bonus_bp: int = 0
# tier_unlock
var max_tier: int = 0
## checks·reference_scenarios(정수 정규화 깊은 복사). 런타임은 읽지 않는다(테스트·qa 용).
var checks: Dictionary = {}
var reference_scenarios: Array = []

var _genres: Array[String] = []   # mvp_genres 순서
var _base: Dictionary = {}        # grade -> int
var _aff: Dictionary = {}         # g -> {h -> bp}
var _tiers: Dictionary = {}       # tier(int) -> {unlock_reputation, unlock_cash}


## reputation.json 을 읽고 나머지를 기본 경로에서 읽어(읽기 전용) 검증한다. 실패하면 push_error, null.
static func load(path: String = DEFAULT_PATH) -> ReputationConfig:
	var r: Variant = JsonUtil.read_json(path, LOG_TAG)
	var a: Variant = JsonUtil.read_json(ARTIST_PATH, LOG_TAG)
	var g: Variant = JsonUtil.read_json(GENRES_PATH, LOG_TAG)
	var t: Variant = JsonUtil.read_json(TIERS_PATH, LOG_TAG)
	var e: Variant = JsonUtil.read_json(ECONOMY_PATH, LOG_TAG)
	if r == null or a == null or g == null or t == null or e == null:
		return null
	return from_dicts(r, a, g, t, e)


## 메모리 상 Dictionary 에서 만든다. 테스트의 변형 사본 검증용.
static func from_dicts(reputation: Dictionary, artist: Dictionary, genres: Dictionary, tiers: Dictionary,
		economy: Dictionary) -> ReputationConfig:
	var cfg: ReputationConfig = ReputationConfig.new()
	var err: String = cfg._parse(reputation, artist, genres, tiers, economy)
	if err != "":
		push_error("[%s] %s" % [LOG_TAG, err])
		return null
	return cfg


# --- 읽기 전용 조회 ---------------------------------------------------------------

## mvp_genres 순서(복사본).
func genre_ids() -> Array[String]:
	return _genres.duplicate()


## base_by_grade[grade]. 모르는 등급이면 0(유효한 base 는 0 이 아니다).
func base(grade: String) -> int:
	return _base.get(grade, UNKNOWN_BASE)


## RG3: clamp(⌊admissions × rate_scale ÷ admissions_ref⌋, min_bp, max_bp). 음수 입장은 0 으로 본다.
func admission_factor_bp(admissions: int) -> int:
	return clampi(maxi(admissions, 0) * rate_scale / admissions_ref, factor_min_bp, factor_max_bp)


## U3 변환 뒤 유사도 bp. 모르는 쌍이면 -1.
func affinity_bp(g: String, h: String) -> int:
	if not _aff.has(g) or not (_aff[g] as Dictionary).has(h):
		return UNKNOWN_AFFINITY
	return _aff[g][h]


## {unlock_reputation, unlock_cash}(tiers.json). 없으면 {}.
func tier_threshold(tier: int) -> Dictionary:
	if not _tiers.has(tier):
		return {}
	return (_tiers[tier] as Dictionary).duplicate()


## id 로 기준 시나리오(깊은 복사). 없으면 {}, 오류 없음.
func scenario(id: String) -> Dictionary:
	for sc: Variant in reference_scenarios:
		if sc is Dictionary and (sc as Dictionary).get("id") == id:
			return (sc as Dictionary).duplicate(true)
	return {}


# --- 파싱·검사 ---------------------------------------------------------------------

func _parse(rep: Dictionary, artist: Dictionary, genres: Dictionary, tiers: Dictionary, economy: Dictionary) -> String:
	var v: Variant = JsonUtil.as_int(rep.get("version"))                                      # RL1
	if v == null or v != SUPPORTED_VERSION:
		return "RL1 reputation.json version 은 %d 이어야 한다: %s" % [SUPPORTED_VERSION, rep.get("version")]
	version = v
	var rs: Variant = JsonUtil.as_int(economy.get("rate_scale"))
	if rs == null or rs != EconomyConfig.REQUIRED_RATE_SCALE:
		return "RL1 economy.json rate_scale 은 %d 이어야 한다: %s" % [EconomyConfig.REQUIRED_RATE_SCALE, economy.get("rate_scale")]
	rate_scale = rs

	var sg: Variant = _string_list(artist.get("show_grades"))                     # RL2
	var mg: Variant = _string_list(artist.get("mvp_genres"))
	if sg == null or (sg as Array).is_empty() or mg == null or (mg as Array).is_empty():
		return "RL2 artist.json show_grades·mvp_genres 가 비어 있지 않은 문자열 배열이 아니다"
	show_grades.assign(sg)
	_genres.assign(mg)
	var bbg: Variant = rep.get("base_by_grade")
	if not (bbg is Dictionary) or (bbg as Dictionary).size() != show_grades.size():
		return "RL2 base_by_grade 키 집합이 show_grades %s 와 다르다: %s" % [show_grades, bbg]
	for g: String in show_grades:
		if not (bbg as Dictionary).has(g):
			return "RL2 base_by_grade 에 '%s' 가 없다" % g
		var b: Variant = JsonUtil.as_int(bbg[g])
		if b == null:
			return "RL2 base_by_grade.%s 가 정수가 아니다: %s" % [g, bbg[g]]
		_base[g] = b

	var af: Variant = rep.get("admission_factor")                                             # RL5 (RL4 가 min_bp 를 쓴다)
	if not (af is Dictionary):
		return "RL5 admission_factor 가 객체가 아니다"
	var ref: Variant = JsonUtil.as_int((af as Dictionary).get("admissions_ref"))
	var mn: Variant = JsonUtil.as_int((af as Dictionary).get("min_bp"))
	var mx: Variant = JsonUtil.as_int((af as Dictionary).get("max_bp"))
	if ref == null or mn == null or mx == null or ref < 1 or mn < 1 or mn > mx:
		return "RL5 admissions_ref ≥ 1, 1 ≤ min_bp ≤ max_bp 이어야 한다: %s" % [af]
	admissions_ref = ref
	factor_min_bp = mn
	factor_max_bp = mx

	var neg: int = 0                                                                          # RL4
	var pos: int = 0
	for i: int in show_grades.size():
		var b: int = _base[show_grades[i]]
		if b == 0:
			return "RL4 base 가 0 인 등급 '%s'" % show_grades[i]
		if i > 0 and b <= _base[show_grades[i - 1]]:
			return "RL4 base 가 show_grades 순서로 엄격히 증가하지 않는다: %s" % [_base]
		if b < 0:
			neg += 1
			if (-b) * factor_min_bp / rate_scale < 1:
				return "RL4 실패 등급 '%s' 의 최소 Δ ⌊%d × %d ÷ %d⌋ 가 0 이다" % [show_grades[i], -b, factor_min_bp, rate_scale]
		else:
			pos += 1
	if neg < 1 or pos < 1:
		return "RL4 실패 등급(base < 0)과 양수 등급이 각각 1개 이상이어야 한다: %s" % [_base]

	var rows: Variant = genres.get("rows")                                                    # RL3
	if not (rows is Array):
		return "RL3 genres.json rows 가 배열이 아니다"
	var by_id: Dictionary = {}
	for r: Variant in rows:
		if r is Dictionary and (r as Dictionary).get("id") is String:
			by_id[r["id"]] = r
	for g: String in _genres:
		if not by_id.has(g):
			return "RL3 mvp 장르 '%s' 가 genres.json 에 없다" % g
		var aff: Variant = (by_id[g] as Dictionary).get("affinity")
		if not (aff is Dictionary):
			return "RL3 genres.json '%s' 에 affinity 가 없다" % g
		var row_bp: Dictionary = {}
		for h: String in _genres:
			var x: Variant = (aff as Dictionary).get(h)
			if not (x is float or x is int) or x < AFFINITY_MIN or x > AFFINITY_MAX:
				return "RL3 affinity.%s.%s 가 0~1 수가 아니다: %s" % [g, h, x]
			row_bp[h] = roundi(float(x) * rate_scale)
		_aff[g] = row_bp
	for g: String in _genres:
		if _aff[g][g] != rate_scale:
			return "RL3 affinity_bp[%s][%s] = %d != %d" % [g, g, _aff[g][g], rate_scale]
		for h: String in _genres:
			if _aff[g][h] != _aff[h][g]:
				return "RL3 affinity 비대칭 %s-%s: %d != %d" % [g, h, _aff[g][h], _aff[h][g]]

	var fc: Variant = rep.get("focus")                                                        # RL6
	if not (fc is Dictionary):
		return "RL6 focus 가 객체가 아니다"
	var f: Dictionary = {}
	for key: String in FOCUS_INT_FIELDS:
		var x: Variant = JsonUtil.as_int((fc as Dictionary).get(key))
		if x == null or x < 0:
			return "RL6 focus.%s 가 0 이상 정수가 아니다: %s" % [key, (fc as Dictionary).get(key)]
		f[key] = x
	if f["min_genre_sum"] < 1:
		return "RL6 min_genre_sum < 1"
	if f["breadth_min_share_bp"] * _genres.size() > rate_scale:
		return "RL6 breadth_min_share_bp %d × %d > %d(관객 폭에 닿을 수 없다)" % [f["breadth_min_share_bp"], _genres.size(), rate_scale]
	if f["identity_share_bp"] > rate_scale:
		return "RL6 identity_share_bp %d > %d" % [f["identity_share_bp"], rate_scale]
	min_genre_sum = f["min_genre_sum"]
	identity_share_bp = f["identity_share_bp"]
	identity_bonus_bp = f["identity_bonus_bp"]
	breadth_min_share_bp = f["breadth_min_share_bp"]
	breadth_bonus_bp = f["breadth_bonus_bp"]

	var tu: Variant = rep.get("tier_unlock")                                                  # RL7
	var mt: Variant = JsonUtil.as_int((tu as Dictionary).get("max_tier")) if tu is Dictionary else null
	if mt == null or mt < START_TIER + 1:
		return "RL7 tier_unlock.max_tier 는 %d 이상 정수여야 한다: %s" % [START_TIER + 1, tu]
	var trows: Variant = tiers.get("rows")
	if not (trows is Array):
		return "RL7 tiers.json rows 가 배열이 아니다"
	for r: Variant in trows:
		if not (r is Dictionary):
			continue
		var tn: Variant = JsonUtil.as_int((r as Dictionary).get("tier"))
		var ur: Variant = JsonUtil.as_int((r as Dictionary).get("unlock_reputation"))
		var uc: Variant = JsonUtil.as_int((r as Dictionary).get("unlock_cash"))
		if tn != null and ur != null and uc != null:
			_tiers[tn] = {"unlock_reputation": ur, "unlock_cash": uc}
	for t: int in range(START_TIER + 1, mt + 1):
		if not _tiers.has(t):
			return "RL7 tiers.json 에 tier %d 행(unlock_reputation·unlock_cash 정수)이 없다" % t
	max_tier = mt

	var ck: Variant = rep.get("checks", {})
	checks = JsonUtil.int_deep(ck) if ck is Dictionary else {}
	var sc: Variant = rep.get("reference_scenarios", [])
	reference_scenarios = JsonUtil.int_deep(sc) if sc is Array else []
	return ""


## 문자열 배열이면 Array[String], 아니면 null.
static func _string_list(v: Variant) -> Variant:
	if not (v is Array):
		return null
	var out: Array[String] = []
	for e: Variant in v:
		if not (e is String):
			return null
		out.append(e)
	return out
