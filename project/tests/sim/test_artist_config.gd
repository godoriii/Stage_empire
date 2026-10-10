extends GutTest
## SE-033 — ArtistConfig. docs/gdd/artist.md#수용-기준 AR1(L1~L8 교차 검사)과 티켓 AC6(실제 데이터 로드 + 장르·등급 집계)을 옮겼다.
## 기대 수치는 artist.json(roster_plan·grades)·economy.json(guarantee_by_grade)에서 읽는다. 아티스트 수·id 리터럴 없음.

var _artists: Dictionary
var _rules: Dictionary
var _genres: Dictionary
var _economy: Dictionary


func before_all() -> void:
	_artists = JsonUtil.read_json(ArtistConfig.DEFAULT_ARTISTS_PATH, ArtistConfig.LOG_TAG)
	_rules = JsonUtil.read_json(ArtistConfig.DEFAULT_RULES_PATH, ArtistConfig.LOG_TAG)
	_genres = JsonUtil.read_json(ArtistConfig.GENRES_PATH, ArtistConfig.LOG_TAG)
	_economy = JsonUtil.read_json(ArtistConfig.ECONOMY_PATH, ArtistConfig.LOG_TAG)


# --- 도우미 -------------------------------------------------------------------

## [artists, rules, genres, economy] 깊은 복사본.
func _copies() -> Array:
	return [_artists.duplicate(true), _rules.duplicate(true), _genres.duplicate(true), _economy.duplicate(true)]


func _first_row_index(grade: String) -> int:
	var rows: Array = _artists["rows"]
	for i: int in rows.size():
		if rows[i]["grade"] == grade:
			return i
	return -1


func _grade_index(grade: String) -> int:
	var grades: Array = _rules["grades"]
	for i: int in grades.size():
		if grades[i]["id"] == grade:
			return i
	return -1


## L1~L8 을 하나씩 깬 사본: [라벨, push_error 문구 일부, artists, rules, genres, economy].
func _broken() -> Array:
	var out: Array = []
	var li: int = _first_row_index("local")
	var lg: int = _grade_index("local")
	var c: Array

	c = _copies(); c[0]["version"] = 2
	out.append(["artists version 2", "L1"] + c)
	c = _copies(); c[1]["stat_max"] = 99
	out.append(["stat_max 99", "L1"] + c)
	c = _copies(); c[1]["relationship_min"] = 1
	out.append(["relationship_min 1", "L1"] + c)
	c = _copies()
	var kept: Array = []
	for g: Dictionary in c[2]["rows"]:
		if g["id"] != "indie":
			kept.append(g)
	c[2]["rows"] = kept
	out.append(["genres 에서 indie 제거", "L2"] + c)
	c = _copies(); c[0]["rows"][li]["genre"] = "jazz"
	out.append(["행 genre jazz", "L3"] + c)
	c = _copies(); c[0]["rows"][li]["grade"] = "midlevel"
	out.append(["행 grade midlevel", "L4"] + c)
	c = _copies(); (c[3]["guarantee_by_grade"] as Dictionary).erase("rookie")
	out.append(["economy guarantee_by_grade 에 rookie 없음", "L4"] + c)
	c = _copies(); c[1]["grades"].append((c[1]["grades"][lg] as Dictionary).duplicate(true))
	out.append(["grades id 중복", "L4"] + c)
	c = _copies(); c[1]["grades"][0]["unlock_reputation"] = 10
	out.append(["grades[0].unlock_reputation 10", "L5"] + c)
	c = _copies(); c[1]["grades"][lg]["promote_at_popularity"] = null
	out.append(["promote_to 있음 + promote_at_popularity null", "L5"] + c)
	c = _copies(); c[1]["grades"][lg]["promote_to"] = "local"
	out.append(["promote_to 자기 자신", "L5"] + c)
	c = _copies(); c[0]["rows"][li]["bio_key"] = "artist.bio.someone_else"
	out.append(["bio_key 불일치", "L6"] + c)
	c = _copies(); c[0]["rows"][li]["rider"] = ["x"]
	out.append(["rider [x]", "L6"] + c)
	c = _copies(); c[0]["rows"][li]["personality"] = ["shy", "showman"]
	out.append(["personality 배타 쌍", "L7"] + c)
	c = _copies(); c[0]["rows"][li]["personality"] = ["shy", "shy"]
	out.append(["personality 같은 태그 2개", "L7"] + c)
	c = _copies(); c[0]["rows"][li]["personality"] = ["shy", "unknown_tag"]
	out.append(["personality 모르는 태그", "L7"] + c)
	c = _copies(); c[1]["personality_exclusive_pairs"].append(["shy", "unknown_tag"])
	out.append(["배타 쌍에 모르는 태그", "L7"] + c)
	c = _copies(); c[0]["rows"][li]["popularity"] = c[1]["grades"][lg]["promote_at_popularity"]
	out.append(["로컬 인기 = 승급 임계", "L8"] + c)
	c = _copies(); c[0]["rows"].append((c[0]["rows"][li] as Dictionary).duplicate(true))
	out.append(["명단 id 중복", "중복"] + c)
	return out


# --- AR1 ------------------------------------------------------------------------

func test_config_loads_and_cross_checks() -> void:
	var cfg: ArtistConfig = ArtistConfig.load()
	assert_not_null(cfg, "실제 데이터 로드 성공")
	if cfg == null:
		return
	assert_not_null(ArtistConfig.from_dicts(_artists, _rules, _genres, _economy), "from_dicts 도 같은 데이터로 성공")
	var errs: int = 0
	var broken: Array = _broken()
	assert_true(broken.size() >= 8, "L1~L8 을 깬 사본 8건 이상")
	for b: Array in broken:
		assert_null(ArtistConfig.from_dicts(b[2], b[3], b[4], b[5]), "%s → null" % b[0])
		errs += 1
		assert_push_error(b[1], "%s: 의도한 검사(%s)" % [b[0], b[1]])
		assert_push_error_count(errs, "%s: push_error 1회" % b[0])
	# 개런티는 economy.json 값 그대로(EconomyConfig.guarantee 와 같은 규약).
	var gbg: Dictionary = _economy["guarantee_by_grade"]
	for g: String in cfg.grade_ids():
		assert_eq(cfg.guarantee(g), int(gbg[g]), "guarantee(%s) == economy guarantee_by_grade" % g)
	assert_eq(cfg.guarantee("midlevel"), ArtistConfig.GUARANTEE_UNKNOWN, "모르는 등급 -1")
	errs += 1
	assert_push_error_count(errs, "guarantee(midlevel) push_error 1회")


func test_config_accessors() -> void:
	var cfg: ArtistConfig = ArtistConfig.load()
	var rows: Array = _artists["rows"]
	var ids: Array[String] = cfg.artist_ids()
	assert_eq(ids.size(), rows.size())
	for i: int in rows.size():
		assert_eq(ids[i], rows[i]["id"], "artist_ids 는 데이터 행 순서")
		assert_true(cfg.has_artist(ids[i]))
		var a: Dictionary = cfg.artist(ids[i])
		assert_eq(a["popularity"], int(rows[i]["popularity"]))
		assert_eq(cfg.genre_of(ids[i]), rows[i]["genre"])
		a["popularity"] = -5
		assert_eq(cfg.artist(ids[i])["popularity"], int(rows[i]["popularity"]), "artist() 는 깊은 복사")
	assert_false(cfg.has_artist("nobody"))
	assert_false(cfg.has_artist(5))
	assert_eq(cfg.artist("nobody"), {})
	assert_eq(cfg.grade_rule("midlevel"), {})
	assert_eq(cfg.scenario("nope"), {})
	for g: Dictionary in _rules["grades"]:
		assert_eq(cfg.unlock_reputation(g["id"]), int(g["unlock_reputation"]))
		assert_eq(cfg.grade_rule(g["id"])["skill_per_show"], int(g["skill_per_show"]))
	assert_eq(cfg.mvp_genres, Array(_rules["mvp_genres"], TYPE_STRING, "", null))
	assert_eq(cfg.booking_phases, Array(_rules["booking_phases"], TYPE_STRING, "", null))
	assert_eq(cfg.show_grades, Array(_rules["show_grades"], TYPE_STRING, "", null))
	assert_eq(cfg.stat_max, int(_rules["stat_max"]))
	assert_eq(cfg.relationship_min, int(_rules["relationship_min"]))
	assert_eq(cfg.relationship_max, int(_rules["relationship_max"]))
	assert_eq(cfg.reference_scenarios.size(), (_rules["reference_scenarios"] as Array).size())
	var sc: Dictionary = cfg.scenario(_rules["reference_scenarios"][0]["id"])
	assert_true(sc["popularity"] is int, "시나리오 수치는 int 로 정규화")


## grow() 는 순수 함수: 입력 불변, 모르는 등급·공연 등급은 push_error 후 {}.
func test_grow_is_pure() -> void:
	var cfg: ArtistConfig = ArtistConfig.load()
	var id: String = cfg.artist_ids()[0]
	var e: Dictionary = {
		"id": id, "grade": cfg.artist(id)["grade"], "popularity": cfg.artist(id)["popularity"],
		"skill": cfg.artist(id)["skill"], "shows_played": 0, "discovered_here": true, "relationship": 0,
	}
	var before: Dictionary = e.duplicate(true)
	var g: Dictionary = cfg.grow(e, cfg.show_grades.back())
	assert_eq(e, before, "입력 불변")
	assert_eq(g["shows_played"], 1)
	assert_eq(g["discovered_here"], true, "다른 필드는 그대로")
	assert_true(g.has("promoted") and g.has("popularity_delta") and g.has("skill_delta"))
	assert_eq(cfg.grow(e, "열광"), {})
	assert_push_error("공연 등급")
	var bad: Dictionary = e.duplicate(true)
	bad["grade"] = "boss"
	assert_eq(cfg.grow(bad, cfg.show_grades[0]), {})
	assert_push_error("모르는 등급")
	assert_push_error_count(2)


# --- SE-046 AC2: JsonUtil.as_int 2^63 가드가 artist 로더 경로에도 걸린다 ----------------

## 파일 → JsonUtil.read_json → ArtistConfig.load 경로. |1e19| ≥ 2^63 은 정수로 접지 않는다(test_json_util 과 같은 규약).
func test_loader_rejects_float_beyond_int64() -> void:
	var lg: int = _grade_index("local")
	var rules: Dictionary = _rules.duplicate(true)
	rules["grades"][lg]["unlock_reputation"] = 1e19
	var path: String = "user://se046_artist_rules_1e19.json"
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(rules))
	f.close()
	var reread: Dictionary = JsonUtil.read_json(path, ArtistConfig.LOG_TAG)
	assert_eq(reread["grades"][lg]["unlock_reputation"], 1e19, "파일 왕복 뒤에도 1e19(float)")
	assert_null(JsonUtil.as_int(1e19), "전제: as_int(1e19) == null")
	assert_null(ArtistConfig.load(ArtistConfig.DEFAULT_ARTISTS_PATH, path), "unlock_reputation 1e19 → load null")
	assert_push_error("unlock_reputation", "등급 규칙 정수 검사에서 거절")
	assert_push_error_count(1, "push_error 1회")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# int_deep 경로(reference_scenarios): 1e19 는 int 로 접지 않고 float 그대로 보관한다.
	var c: Array = _copies()
	var sid: String = c[1]["reference_scenarios"][0]["id"]
	c[1]["reference_scenarios"][0]["popularity"] = 1e19
	var cfg: ArtistConfig = ArtistConfig.from_dicts(c[0], c[1], c[2], c[3])
	assert_not_null(cfg, "시나리오는 런타임이 읽지 않으므로 로드 성공")
	if cfg != null:
		assert_true(cfg.scenario(sid)["popularity"] is float, "시나리오 1e19 는 float 로 남는다")
	assert_push_error_count(1, "추가 push_error 없음")


# --- AC6: 실제 데이터 집계(데이터 회귀 방지) --------------------------------------

func test_real_roster_aggregates() -> void:
	var cfg: ArtistConfig = ArtistConfig.load()
	assert_not_null(cfg)
	if cfg == null:
		return
	var plan: Dictionary = _rules["roster_plan"]
	var ids: Array[String] = cfg.artist_ids()
	assert_eq(ids.size(), int(plan["total"]), "명단 수 = roster_plan.total")
	var by_genre: Dictionary = {}
	var by_grade: Dictionary = {}
	for id: String in ids:
		var a: Dictionary = cfg.artist(id)
		by_genre[a["genre"]] = int(by_genre.get(a["genre"], 0)) + 1
		by_grade[a["grade"]] = int(by_grade.get(a["grade"], 0)) + 1
	assert_eq(by_genre.size(), cfg.mvp_genres.size(), "장르 수 = mvp_genres 수")
	for g: String in cfg.mvp_genres:
		assert_eq(int(by_genre.get(g, 0)), int(plan["per_genre"]), "장르 %s = per_genre" % g)
	assert_eq(by_genre.size() * int(plan["per_genre"]), ids.size(), "장르 × per_genre = 전체")
	var counts: Dictionary = plan["grade_counts"]
	assert_eq(by_grade.size(), counts.size(), "등급 종류 수")
	for g: String in counts:
		assert_eq(int(by_grade.get(g, 0)), int(counts[g]), "등급 %s 수" % g)
