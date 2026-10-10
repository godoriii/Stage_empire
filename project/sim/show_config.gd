class_name ShowConfig
extends RefCounted
## 공연 설정 (SE-035). show.json + (읽기 전용) artist.json·economy.json.
## 규칙: docs/gdd/show.md #설정-로드-검사 SL1~SL4, #공개-api, SR3(등급 판정).
## 스키마로 못 하는 교차 검사를 한다. 실패하면 push_error 1회, null. 모든 필드는 읽기 전용으로 취급한다.
## reference_scenarios 는 런타임이 읽지 않는다(테스트·qa 용, 정수 정규화한 깊은 복사본).

const DEFAULT_PATH: String = "res://data/show/show.json"
const ARTIST_PATH: String = "res://data/artist/artist.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const LOG_TAG: String = "ShowConfig"

## SL1: 이 로더가 읽는 show.json version.
const SUPPORTED_VERSION: int = 1
## SL4: 만족도 진실의 출처(스키마 enum 1값과 같은 문자열, show.md SR1).
const SATISFACTION_SOURCE: String = "audience.day_summary.avg_satisfaction_bp"
## SL3: 첫 등급의 min_bp(항상 하나가 고르도록).
const FIRST_MIN_BP: int = 0
## min_bp(id) 가 모르는 등급에 돌려주는 값.
const UNKNOWN_MIN_BP: int = -1

var version: int = 0
## economy.json rate_scale(만족 bp 의 분모, SL1 에서 EconomyConfig.REQUIRED_RATE_SCALE 과 같음을 확인).
var rate_scale: int = 0
var satisfaction_source: String = ""
## 새 게임 티켓 가격 = economy.json rows[START_TIER].ticket_price_default.
var ticket_price_default: int = 0
## artist.json mvp_genres(스냅샷 SS3 검사용).
var mvp_genres: Array[String] = []
## artist.json show_grades(등급 id 와 순서의 단일 출처).
var show_grades: Array[String] = []
var reference_scenarios: Array = []

var _ids: Array[String] = []     # grades 순서(나쁜 것 → 좋은 것)
var _names: Dictionary = {}      # id -> 표시 이름
var _min_bp: Dictionary = {}     # id -> int


## show.json 을 읽고 artist.json·economy.json 을 기본 경로에서 읽어 검증한다. 실패하면 push_error, null.
static func load(path: String = DEFAULT_PATH) -> ShowConfig:
	var s: Variant = JsonUtil.read_json(path, LOG_TAG)
	var a: Variant = JsonUtil.read_json(ARTIST_PATH, LOG_TAG)
	var e: Variant = JsonUtil.read_json(ECONOMY_PATH, LOG_TAG)
	if s == null or a == null or e == null:
		return null
	return from_dicts(s, a, e)


## 메모리 상 Dictionary(JSON 파싱 결과와 같은 모양)에서 만든다. 테스트의 변형 사본 검증용.
static func from_dicts(show: Dictionary, artist: Dictionary, economy: Dictionary) -> ShowConfig:
	var cfg: ShowConfig = ShowConfig.new()
	var err: String = cfg._parse(show, artist, economy)
	if err != "":
		push_error("[%s] %s" % [LOG_TAG, err])
		return null
	return cfg


# --- 읽기 전용 조회 ---------------------------------------------------------------

## grades 순서의 등급 id(복사본).
func grade_ids() -> Array[String]:
	return _ids.duplicate()


## 표시 이름. 없으면 "".
func grade_name(id: String) -> String:
	return _names.get(id, "")


## 등급 하한. 없으면 -1.
func min_bp(id: String) -> int:
	return _min_bp.get(id, UNKNOWN_MIN_BP)


## SR3: min_bp ≤ satisfaction_bp 인 마지막 행의 id. 첫 행 min_bp 가 0 이라 0 이상이면 항상 하나를 고른다.
## 음수 입력은 첫 행(호출자가 DS1 로 막는다).
func grade_for(satisfaction_bp: int) -> String:
	var out: String = _ids[0]
	for id: String in _ids:
		if _min_bp[id] <= satisfaction_bp:
			out = id
	return out


## id 로 기준 시나리오(깊은 복사). 없으면 {}, 오류 없음.
func scenario(id: String) -> Dictionary:
	for sc: Variant in reference_scenarios:
		if sc is Dictionary and (sc as Dictionary).get("id") == id:
			return (sc as Dictionary).duplicate(true)
	return {}


# --- 파싱·검사 ---------------------------------------------------------------------

## 성공이면 "", 실패면 첫 위반 문자열.
func _parse(show: Dictionary, artist: Dictionary, economy: Dictionary) -> String:
	var v: Variant = JsonUtil.as_int(show.get("version"))                                     # SL1
	if v == null or v != SUPPORTED_VERSION:
		return "SL1 show.json version 은 %d 이어야 한다: %s" % [SUPPORTED_VERSION, show.get("version")]
	version = v
	var eco: EconomyConfig = EconomyConfig.from_dict(economy)
	if eco == null:
		return "SL1 economy.json 을 읽을 수 없다"
	if eco.rate_scale != EconomyConfig.REQUIRED_RATE_SCALE:
		return "SL1 economy.json rate_scale 은 %d 이어야 한다: %d" % [EconomyConfig.REQUIRED_RATE_SCALE, eco.rate_scale]
	rate_scale = eco.rate_scale
	if not eco.has_row(EconomyConfig.START_TIER):
		return "SL1 economy.json 에 시작 티어 행이 없다"
	var tp: Variant = JsonUtil.as_int(eco.row(EconomyConfig.START_TIER).get("ticket_price_default"))
	if tp == null or tp < 1:
		return "SL1 ticket_price_default 가 1 이상 정수가 아니다: %s" % [tp]
	ticket_price_default = tp

	var sg: Variant = _string_list(artist.get("show_grades"))                                 # SL2 준비
	var mg: Variant = _string_list(artist.get("mvp_genres"))
	if sg == null or (sg as Array).is_empty() or mg == null:
		return "SL2 artist.json show_grades·mvp_genres 가 문자열 배열이 아니다"
	show_grades.assign(sg)
	mvp_genres.assign(mg)

	var rows: Variant = show.get("grades")
	if not (rows is Array) or (rows as Array).is_empty():
		return "SL2 grades 가 비어 있거나 배열이 아니다"
	var prev: int = FIRST_MIN_BP
	for i: int in (rows as Array).size():
		var r: Variant = rows[i]
		if not (r is Dictionary):
			return "SL2 grades[%d] 가 객체가 아니다" % i
		var id: Variant = (r as Dictionary).get("id")
		var nm: Variant = (r as Dictionary).get("name")
		var mb: Variant = JsonUtil.as_int((r as Dictionary).get("min_bp"))
		if not (id is String) or not (nm is String) or mb == null:
			return "SL2 grades[%d] 형식 오류(id·name 문자열, min_bp 정수): %s" % [i, r]
		if _min_bp.has(id):
			return "SL2 grades id '%s' 중복" % id
		if i == 0 and mb != FIRST_MIN_BP:                                                    # SL3
			return "SL3 grades[0].min_bp 는 %d 이어야 한다: %d" % [FIRST_MIN_BP, mb]
		if i > 0 and mb <= prev:
			return "SL3 min_bp 가 엄격히 증가하지 않는다: %s(%d) ≤ %d" % [id, mb, prev]
		prev = mb
		_ids.append(id)
		_names[id] = nm
		_min_bp[id] = mb
	if prev > rate_scale:
		return "SL3 마지막 min_bp %d > rate_scale %d" % [prev, rate_scale]
	if _ids != show_grades:                                                                  # SL2
		return "SL2 grades id 순서 %s != artist.json show_grades %s" % [_ids, show_grades]

	var src: Variant = show.get("satisfaction_source")                                       # SL4
	if src != SATISFACTION_SOURCE:
		return "SL4 satisfaction_source 는 '%s' 이어야 한다: %s" % [SATISFACTION_SOURCE, src]
	satisfaction_source = src

	var sc: Variant = show.get("reference_scenarios", [])
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
