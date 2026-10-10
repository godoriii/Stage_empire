class_name ArtistConfig
extends RefCounted
## 아티스트 설정 (SE-033). artists.json(명단) + artist.json(규칙) + (읽기 전용) genres.json·economy.json.
## 규칙: docs/gdd/artist.md #설정-로드-검사 L1~L8, #공개-api, #성장 GR1~GR5.
## 스키마로 못 하는 교차 검사와 CI 검증기가 보지 않는 maxItems·형식(L6·L7)을 여기서 한다. 실패하면 push_error, null.
## 명단 구성(12행·3장르 × 4·roster_plan 일치)은 검사하지 않는다(테스트 사본이 적은 행으로 로드될 수 있게, artist.md).
## 모든 필드는 읽기 전용으로 취급한다. JSON 숫자의 정수값 float 는 int 로 정규화해 보관한다.

const DEFAULT_ARTISTS_PATH: String = "res://data/artists/artists.json"
const DEFAULT_RULES_PATH: String = "res://data/artist/artist.json"
const GENRES_PATH: String = "res://data/genres/genres.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"

## L1: 이 로더가 읽는 테이블 version 과 인기·실력 상한(단위 정의, 스키마 enum 과 같은 값).
const SUPPORTED_VERSION: int = 1
const REQUIRED_STAT_MAX: int = 100
## guarantee_mode 중 v0 가 아는 값(스키마 enum 과 같은 값).
const GUARANTEE_MODE_BY_GRADE: String = "by_grade"
## guarantee(grade) 가 모르는 등급에 돌려주는 값(EconomyConfig.GUARANTEE_UNKNOWN 과 같은 규약).
const GUARANTEE_UNKNOWN: int = -1
## L6: bio_key = 접두어 + id.
const BIO_KEY_PREFIX: String = "artist.bio."
## L7: 성격 태그 개수(artist.md "태그 2개").
const PERSONALITY_COUNT: int = 2
## 배타 쌍 원소 수.
const PAIR_SIZE: int = 2
## 새 게임 동적 값(artist.md #상태 roster: shows_played 0, relationship 0).
const NEW_GAME_SHOWS_PLAYED: int = 0
const NEW_GAME_RELATIONSHIP: int = 0
## |float| 이 이 값 이상이면 int64 로 바꿀 수 없다(2^63, 타입 한계 정의).
const INT64_FLOAT_LIMIT: float = 9223372036854775808.0

const ROW_FIELDS: Array[String] = ["id", "name", "genre", "grade", "popularity", "skill", "personality", "rider", "bio_key"]
const GRADE_FIELDS: Array[String] = [
	"id", "unlock_reputation", "promote_to", "promote_at_popularity", "popularity_delta_by_show_grade", "skill_per_show",
]

var version: int = 0
var stat_max: int = 0
var relationship_min: int = 0
var relationship_max: int = 0
var guarantee_mode: String = ""
var mvp_genres: Array[String] = []
var booking_phases: Array[String] = []
## 공연 등급 id(나쁜 것 → 좋은 것).
var show_grades: Array[String] = []
var personality_tags: Array[String] = []
## [[tag, tag], …]
var personality_exclusive_pairs: Array = []
## 성장 기준 시나리오(정수 정규화한 깊은 복사본). 런타임은 읽지 않는다(테스트·qa 용).
var reference_scenarios: Array = []

var _rows: Array = []              # 명단 행(정수 정규화), 데이터 행 순서
var _index: Dictionary = {}        # id -> 행 번호
var _ids: Array[String] = []       # 데이터 행 순서
var _grades: Dictionary = {}       # grade id -> 규칙(정수 정규화)
var _grade_ids: Array[String] = [] # grades 순서
var _guarantee: Dictionary = {}    # grade id -> int (economy.json guarantee_by_grade 중 grades 에 있는 것)


## 두 테이블을 읽고 genres.json·economy.json 을 기본 경로에서 읽어(읽기 전용) 검증한다. 실패하면 push_error, null.
static func load(artists_path: String = DEFAULT_ARTISTS_PATH, rules_path: String = DEFAULT_RULES_PATH) -> ArtistConfig:
	var a: Variant = read_json(artists_path)
	var r: Variant = read_json(rules_path)
	var g: Variant = read_json(GENRES_PATH)
	var e: Variant = read_json(ECONOMY_PATH)
	if a == null or r == null or g == null or e == null:
		return null
	return from_dicts(a, r, g, e)


## 메모리 상 Dictionary(JSON 파싱 결과와 같은 모양)에서 만든다. 테스트의 변형 사본 검증용.
static func from_dicts(artists: Dictionary, rules: Dictionary, genres: Dictionary, economy: Dictionary) -> ArtistConfig:
	var cfg: ArtistConfig = ArtistConfig.new()
	var err: String = cfg._parse(artists, rules, genres, economy)
	if err != "":
		push_error("[ArtistConfig] " + err)
		return null
	return cfg


## 파일을 읽어 JSON 객체를 돌려준다. 없거나 객체가 아니면 push_error, null.
static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("[ArtistConfig] 파일 없음: %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("[ArtistConfig] JSON 객체가 아님: %s" % path)
		return null
	return parsed


## int, 또는 정수값인 유한 float(|f| < 2^63)만 int 로. 그 밖(bool·문자열·1.5·null)은 null.
static func as_int(v: Variant) -> Variant:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v) and absf(v) < INT64_FLOAT_LIMIT:
		return int(v)
	return null


# --- 읽기 전용 조회 ---------------------------------------------------------------

## 데이터 행 순서의 id 목록(복사본).
func artist_ids() -> Array[String]:
	return _ids.duplicate()


func has_artist(id: Variant) -> bool:
	return id is String and _index.has(id)


## 명단 행의 깊은 복사본. 없으면 {}.
func artist(id: String) -> Dictionary:
	if not _index.has(id):
		return {}
	return (_rows[_index[id]] as Dictionary).duplicate(true)


## 행의 장르(없으면 "").
func genre_of(id: String) -> String:
	if not _index.has(id):
		return ""
	return _rows[_index[id]]["genre"]


## grades 순서의 등급 id 목록(복사본).
func grade_ids() -> Array[String]:
	return _grade_ids.duplicate()


## 등급 규칙의 깊은 복사본. 없으면 {}.
func grade_rule(grade: String) -> Dictionary:
	if not _grades.has(grade):
		return {}
	return (_grades[grade] as Dictionary).duplicate(true)


## v0 by_grade 개런티(economy.json guarantee_by_grade[grade]). 없는 등급이면 push_error 후 -1(economy 와 같은 규약).
func guarantee(grade: String) -> int:
	if not _guarantee.has(grade):
		push_error("[ArtistConfig] guarantee: grades 또는 guarantee_by_grade 에 없는 등급 '%s'" % grade)
		return GUARANTEE_UNKNOWN
	return _guarantee[grade]


## 등급 섭외 가용 명성. 없는 등급이면 push_error 후 -1.
func unlock_reputation(grade: String) -> int:
	if not _grades.has(grade):
		push_error("[ArtistConfig] unlock_reputation: 모르는 등급 '%s'" % grade)
		return GUARANTEE_UNKNOWN
	return _grades[grade]["unlock_reputation"]


## id 로 성장 기준 시나리오(복사본). 없으면 {}, 오류 없음.
func scenario(id: String) -> Dictionary:
	for sc: Dictionary in reference_scenarios:
		if sc.get("id") == id:
			return sc.duplicate(true)
	return {}


## GR1~GR5 (순수 함수). entry 는 roster 원소 형식. 결과 = 새 원소 + promoted·popularity_delta·skill_delta.
## 입력은 바꾸지 않는다. 등급·공연 등급을 모르면 push_error 후 {}.
func grow(entry: Dictionary, show_grade: String) -> Dictionary:
	var grade: Variant = entry.get("grade")
	if not (grade is String) or not _grades.has(grade):
		push_error("[ArtistConfig] grow: 모르는 등급 '%s'" % [grade])
		return {}
	if not show_grades.has(show_grade):
		push_error("[ArtistConfig] grow: 모르는 공연 등급 '%s'" % show_grade)
		return {}
	var r: Dictionary = _grades[grade]
	var pop: int = int(entry.get("popularity", 0))
	var skl: int = int(entry.get("skill", 0))
	var pop2: int = clampi(pop + int(r["popularity_delta_by_show_grade"][show_grade]), 0, stat_max)  # GR1
	var skl2: int = clampi(skl + int(r["skill_per_show"]), 0, stat_max)                              # GR2
	var promoted: bool = r["promote_to"] != null and pop2 >= int(r["promote_at_popularity"])         # GR4
	var out: Dictionary = entry.duplicate(true)
	out["popularity"] = pop2
	out["skill"] = skl2
	out["shows_played"] = int(entry.get("shows_played", 0)) + 1                                      # GR3
	out["grade"] = r["promote_to"] if promoted else grade                                            # GR5
	out["promoted"] = promoted
	out["popularity_delta"] = pop2 - pop
	out["skill_delta"] = skl2 - skl
	return out


# --- 파싱·검사 ---------------------------------------------------------------------

## 성공이면 "", 실패면 오류 문자열(첫 위반).
func _parse(artists: Dictionary, rules: Dictionary, genres: Dictionary, economy: Dictionary) -> String:
	# L1 버전·상한·관계도 범위
	var av: Variant = as_int(artists.get("version"))
	var rv: Variant = as_int(rules.get("version"))
	if av == null or av != SUPPORTED_VERSION or rv == null or rv != SUPPORTED_VERSION:
		return "L1 artists.json·artist.json version 은 %d 이어야 한다: %s, %s" % [SUPPORTED_VERSION, artists.get("version"), rules.get("version")]
	version = rv
	var sm: Variant = as_int(rules.get("stat_max"))
	if sm == null or sm != REQUIRED_STAT_MAX:
		return "L1 stat_max 는 %d 이어야 한다: %s" % [REQUIRED_STAT_MAX, rules.get("stat_max")]
	stat_max = sm
	var rmin: Variant = as_int(rules.get("relationship_min"))
	var rmax: Variant = as_int(rules.get("relationship_max"))
	if rmin == null or rmax == null or not (rmin <= NEW_GAME_RELATIONSHIP and NEW_GAME_RELATIONSHIP <= rmax):
		return "L1 relationship_min ≤ %d ≤ relationship_max 가 아니다: %s, %s" % [NEW_GAME_RELATIONSHIP, rules.get("relationship_min"), rules.get("relationship_max")]
	relationship_min = rmin
	relationship_max = rmax

	# 기본 형식(스키마가 보장하지만 사본 테스트·CI 부분집합 검증기 대비)
	var gm: Variant = rules.get("guarantee_mode")
	if gm != GUARANTEE_MODE_BY_GRADE:
		return "guarantee_mode 는 '%s' 만 지원한다(v0): %s" % [GUARANTEE_MODE_BY_GRADE, gm]
	guarantee_mode = gm
	var lists: Dictionary = {}
	for key: String in ["mvp_genres", "booking_phases", "show_grades", "personality_tags"]:
		var l: Variant = _unique_strings(rules.get(key))
		if l == null:
			return "%s 는 비어 있지 않고 중복 없는 문자열 배열이어야 한다" % key
		lists[key] = l
	mvp_genres.assign(lists["mvp_genres"])
	booking_phases.assign(lists["booking_phases"])
	show_grades.assign(lists["show_grades"])
	personality_tags.assign(lists["personality_tags"])
	for ph: String in booking_phases:
		if not SimConfig.PHASE_IDS.has(ph):
			return "booking_phases 의 '%s' 가 구간 id 가 아니다(%s)" % [ph, SimConfig.PHASE_IDS]

	# L2 mvp_genres ⊂ genres.json rows[].id
	var genre_rows: Variant = genres.get("rows")
	if not (genre_rows is Array):
		return "L2 genres.json rows 가 배열이 아니다"
	var genre_ids: Dictionary = {}
	for gr: Variant in genre_rows:
		if gr is Dictionary and gr.get("id") is String:
			genre_ids[gr["id"]] = true
	for g: String in mvp_genres:
		if not genre_ids.has(g):
			return "L2 mvp_genres 의 '%s' 가 genres.json 에 없다" % g

	# 등급 규칙 형식 + L4(grades id 유일, economy guarantee_by_grade 키) + L5
	var grades_raw: Variant = rules.get("grades")
	if not (grades_raw is Array) or (grades_raw as Array).is_empty():
		return "grades 는 비어 있지 않은 배열이어야 한다"
	var gbg: Variant = economy.get("guarantee_by_grade")
	if not (gbg is Dictionary):
		return "L4 economy.json guarantee_by_grade 가 객체가 아니다"
	for raw: Variant in grades_raw:
		var parsed: Variant = _parse_grade(raw)
		if parsed is String:
			return parsed
		var gid: String = parsed["id"]
		if _grades.has(gid):
			return "L4 grades[].id '%s' 가 중복이다" % gid
		var amount: Variant = as_int((gbg as Dictionary).get(gid))
		if amount == null or amount < 0:
			return "L4 등급 '%s' 가 economy.json guarantee_by_grade 에 0 이상 정수로 없다" % gid
		_grades[gid] = parsed
		_grade_ids.append(gid)
		_guarantee[gid] = amount
	if int(_grades[_grade_ids[0]]["unlock_reputation"]) != 0:
		return "L5 grades[0].unlock_reputation 은 0 이어야 한다(새 게임에 섭외 가능한 등급): %s" % _grades[_grade_ids[0]]["unlock_reputation"]
	for gid: String in _grade_ids:
		var r: Dictionary = _grades[gid]
		if (r["promote_to"] == null) != (r["promote_at_popularity"] == null):
			return "L5 '%s': promote_to 와 promote_at_popularity 는 둘 다 null 이거나 둘 다 값이어야 한다" % gid
		if r["promote_to"] != null and (not _grades.has(r["promote_to"]) or r["promote_to"] == gid):
			return "L5 '%s': promote_to '%s' 가 다른 grades[].id 가 아니다" % [gid, r["promote_to"]]

	# L7 배타 쌍 어휘
	var pairs: Variant = rules.get("personality_exclusive_pairs")
	if not (pairs is Array):
		return "L7 personality_exclusive_pairs 는 배열이어야 한다"
	for p: Variant in pairs:
		if not (p is Array) or (p as Array).size() != PAIR_SIZE or not (p[0] is String) or not (p[1] is String):
			return "L7 personality_exclusive_pairs 원소는 문자열 %d개 배열이어야 한다: %s" % [PAIR_SIZE, p]
		for t: String in p:
			if not personality_tags.has(t):
				return "L7 personality_exclusive_pairs 의 '%s' 가 personality_tags 에 없다" % t
		personality_exclusive_pairs.append([p[0], p[1]])

	# 명단 행: 형식, id 유일, L3·L4·L6·L7·L8
	var rows: Variant = artists.get("rows")
	if not (rows is Array) or (rows as Array).is_empty():
		return "artists.json rows 는 비어 있지 않은 배열이어야 한다"
	for raw: Variant in rows:
		var row: Variant = _parse_row(raw)
		if row is String:
			return row
		var id: String = row["id"]
		if _index.has(id):
			return "명단 id '%s' 가 중복이다" % id
		if not mvp_genres.has(row["genre"]):                                                    # L3
			return "L3 '%s' 의 genre '%s' 가 mvp_genres %s 에 없다" % [id, row["genre"], mvp_genres]
		if not _grades.has(row["grade"]):                                                       # L4
			return "L4 '%s' 의 grade '%s' 가 grades 에 없다" % [id, row["grade"]]
		if row["bio_key"] != BIO_KEY_PREFIX + id:                                               # L6
			return "L6 '%s' 의 bio_key '%s' 가 '%s' 가 아니다" % [id, row["bio_key"], BIO_KEY_PREFIX + id]
		if not (row["rider"] as Array).is_empty():
			return "L6 '%s' 의 rider 는 빈 배열이어야 한다(v0)" % id
		var tags: Array = row["personality"]                                                    # L7
		for t: Variant in tags:
			if not (t is String) or not personality_tags.has(t):
				return "L7 '%s' 의 성격 태그 '%s' 가 personality_tags 에 없다" % [id, t]
		if tags.size() != PERSONALITY_COUNT or tags[0] == tags[1]:
			return "L7 '%s' 의 personality 는 서로 다른 %d개여야 한다: %s" % [id, PERSONALITY_COUNT, tags]
		for p: Array in personality_exclusive_pairs:
			if (tags[0] == p[0] and tags[1] == p[1]) or (tags[0] == p[1] and tags[1] == p[0]):
				return "L7 '%s' 의 personality %s 가 배타 쌍이다" % [id, tags]
		var rule: Dictionary = _grades[row["grade"]]                                            # L8
		if rule["promote_at_popularity"] != null and int(row["popularity"]) >= int(rule["promote_at_popularity"]):
			return "L8 '%s' 의 popularity %d 가 승급 임계 %d 이상이다" % [id, row["popularity"], rule["promote_at_popularity"]]
		_index[id] = _rows.size()
		_ids.append(id)
		_rows.append(row)

	var scs: Variant = rules.get("reference_scenarios")
	if not (scs is Array):
		return "reference_scenarios 는 배열이어야 한다"
	for sc: Variant in scs:
		if not (sc is Dictionary):
			return "reference_scenarios[] 원소는 객체여야 한다"
		reference_scenarios.append(_int_deep(sc))
	return ""


## 등급 규칙 한 행. 성공이면 정규화한 Dictionary, 실패면 오류 문자열.
func _parse_grade(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return "grades[] 원소는 객체여야 한다"
	for key: String in GRADE_FIELDS:
		if not (raw as Dictionary).has(key):
			return "grades[] 필드 누락: %s" % key
	var gid: Variant = raw["id"]
	if not (gid is String):
		return "grades[].id 는 문자열이어야 한다"
	var unlock: Variant = as_int(raw["unlock_reputation"])
	var sps: Variant = as_int(raw["skill_per_show"])
	if unlock == null or unlock < 0 or sps == null or sps < 0:
		return "grades '%s': unlock_reputation·skill_per_show 는 0 이상 정수여야 한다" % gid
	var pt: Variant = raw["promote_to"]
	if pt != null and not (pt is String):
		return "grades '%s': promote_to 는 문자열 또는 null 이어야 한다" % gid
	var pap: Variant = null
	if raw["promote_at_popularity"] != null:
		pap = as_int(raw["promote_at_popularity"])
		if pap == null or pap < 0 or pap > stat_max:
			return "grades '%s': promote_at_popularity 는 0~%d 정수 또는 null 이어야 한다" % [gid, stat_max]
	var deltas_raw: Variant = raw["popularity_delta_by_show_grade"]
	if not (deltas_raw is Dictionary):
		return "grades '%s': popularity_delta_by_show_grade 는 객체여야 한다" % gid
	var deltas: Dictionary = {}
	for sg: String in show_grades:
		var dv: Variant = as_int((deltas_raw as Dictionary).get(sg))
		if dv == null:
			return "grades '%s': popularity_delta_by_show_grade.%s 가 정수가 아니다" % [gid, sg]
		deltas[sg] = dv
	return {
		"id": gid, "unlock_reputation": unlock, "promote_to": pt, "promote_at_popularity": pap,
		"popularity_delta_by_show_grade": deltas, "skill_per_show": sps,
	}


## 명단 한 행. 성공이면 정규화한 Dictionary, 실패면 오류 문자열.
func _parse_row(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return "rows[] 원소는 객체여야 한다"
	for key: String in ROW_FIELDS:
		if not (raw as Dictionary).has(key):
			return "rows[] 필드 누락: %s (%s)" % [key, raw.get("id")]
	var id: Variant = raw["id"]
	if not (id is String) or (id as String).is_empty():
		return "rows[].id 는 비어 있지 않은 문자열이어야 한다: %s" % [id]
	for key: String in ["name", "genre", "grade", "bio_key"]:
		if not (raw[key] is String):
			return "'%s' 의 %s 는 문자열이어야 한다" % [id, key]
	var pop: Variant = as_int(raw["popularity"])
	var skl: Variant = as_int(raw["skill"])
	if pop == null or pop < 0 or pop > stat_max or skl == null or skl < 0 or skl > stat_max:
		return "'%s' 의 popularity·skill 은 0~%d 정수여야 한다" % [id, stat_max]
	if not (raw["personality"] is Array) or not (raw["rider"] is Array):
		return "'%s' 의 personality·rider 는 배열이어야 한다" % id
	var out: Dictionary = (raw as Dictionary).duplicate(true)
	out["popularity"] = pop
	out["skill"] = skl
	return out


## 비어 있지 않고 중복 없는 문자열 배열이면 Array, 아니면 null.
static func _unique_strings(v: Variant) -> Variant:
	if not (v is Array) or (v as Array).is_empty():
		return null
	var out: Array = []
	for e: Variant in v:
		if not (e is String) or out.has(e):
			return null
		out.append(e)
	return out


## 정수값 float → int (재귀). 그 밖의 값은 그대로.
static func _int_deep(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var n: Variant = as_int(v)
			return n if n != null else v
		TYPE_ARRAY:
			var arr: Array = []
			for e: Variant in v:
				arr.append(_int_deep(e))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k: Variant in v:
				d[k] = _int_deep(v[k])
			return d
	return v
