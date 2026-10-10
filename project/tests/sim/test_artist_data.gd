extends GutTest
## SE-031 AC2/AC3/AC4 (qa) — 아티스트 데이터 회귀 테스트. 실제 JSON 을 읽어 artist.md 규칙·12명 슬롯 표·바이오 규칙·
## 개런티 참조·성장 시나리오·수치 목표(T1~T4)·rookie 손익분기를 단언한다. 기대 수치는 artist.json / economy.json 에서 읽고,
## 핵심 수는 손계산 리터럴로 한 번 더 단언한다. SE-033 의 ArtistConfig/ArtistSystem 이 없어도 도는 순수 데이터 테스트다.

const ARTIST_PATH: String = "res://data/artist/artist.json"
const ARTISTS_PATH: String = "res://data/artists/artists.json"
const TEXT_PATH: String = "res://data/text/artists_ko.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const TIERS_PATH: String = "res://data/tiers/tiers.json"
const GENRES_PATH: String = "res://data/genres/genres.json"
const EVENTS_MD: String = "res://../docs/gdd/events.md"

var _rules: Dictionary
var _rows: Array
var _strings: Dictionary
var _economy: Dictionary


func _load(path: String) -> Dictionary:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "열 수 없음: " + path)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	assert_true(parsed is Dictionary, "JSON 객체가 아님: " + path)
	return parsed if parsed is Dictionary else {}


func before_all() -> void:
	_rules = _load(ARTIST_PATH)
	_rows = _load(ARTISTS_PATH).get("rows", [])
	_strings = _load(TEXT_PATH).get("strings", {})
	_economy = _load(ECONOMY_PATH)


func _key(r: Dictionary) -> String:
	var tags: Array = (r["personality"] as Array).duplicate()
	tags.sort()
	return "%s|%s|%d|%d|%s" % [r["genre"], r["grade"], int(r["popularity"]), int(r["skill"]), ",".join(tags)]


func _grade_rule(grade: String) -> Dictionary:
	for g: Dictionary in _rules["grades"]:
		if g["id"] == grade:
			return g
	return {}


## 순수 함수 사본(artist.md GR1~GR5). SE-033 의 ArtistConfig.grow() 와 별개로 데이터만 검증한다.
func _grow(e: Dictionary, show_grade: String) -> Dictionary:
	var r: Dictionary = _grade_rule(e["grade"])
	var cap: int = int(_rules["stat_max"])
	var pop: int = clampi(int(e["popularity"]) + int(r["popularity_delta_by_show_grade"][show_grade]), 0, cap)
	var skl: int = clampi(int(e["skill"]) + int(r["skill_per_show"]), 0, cap)
	var promoted: bool = r["promote_to"] != null and pop >= int(r["promote_at_popularity"])
	return {
		"grade": r["promote_to"] if promoted else e["grade"],
		"popularity": pop, "skill": skl, "shows_played": int(e["shows_played"]) + 1, "promoted": promoted,
	}


func _run_scenario(sc: Dictionary) -> Dictionary:
	var e: Dictionary = {"grade": sc["grade"], "popularity": sc["popularity"], "skill": sc["skill"], "shows_played": 0}
	var promoted_on: int = 0
	var i: int = 0
	for sg: String in sc["show_grades"]:
		i += 1
		var was: String = e["grade"]
		e = _grow(e, sg)
		if e["promoted"] and promoted_on == 0:
			promoted_on = i
		assert_true(was == e["grade"] or e["promoted"], "등급은 승급으로만 바뀐다")
	e["promoted_on_show"] = promoted_on
	return e


# --- AC2: 12명 구성 · 슬롯 표 일치 ---------------------------------------------------------------

func test_roster_composition() -> void:
	var plan: Dictionary = _rules["roster_plan"]
	assert_eq(_rows.size(), 12, "12행")
	assert_eq(_rows.size(), int(plan["total"]))
	var genres: Dictionary = {}
	var grades: Dictionary = {}
	var ids: Dictionary = {}
	for r: Dictionary in _rows:
		genres[r["genre"]] = int(genres.get(r["genre"], 0)) + 1
		grades[r["grade"]] = int(grades.get(r["grade"], 0)) + 1
		ids[r["id"]] = true
	assert_eq(ids.size(), 12, "id 유일")
	var mvp: Array = _rules["mvp_genres"]
	assert_eq(mvp, ["rock", "indie", "electronic"])
	assert_eq(genres.size(), 3)
	for g: String in mvp:
		assert_eq(int(genres.get(g, 0)), 4, "장르 %s 4명" % g)
	assert_eq(int(grades.get("local", 0)), 8)
	assert_eq(int(grades.get("rookie", 0)), 4)
	assert_eq(grades.size(), 2, "v0 는 local/rookie 만")
	var pops: Dictionary = {}
	var skills: Dictionary = {}
	for r: Dictionary in _rows:
		pops[int(r["popularity"])] = true
		skills[int(r["skill"])] = true
	assert_eq(pops.size(), 12, "인기 12개 서로 다름")
	assert_eq(skills.size(), 12, "실력 12개 서로 다름")
	# 장르가 genres.json 에 존재
	var gids: Array = []
	for gr: Dictionary in _load(GENRES_PATH)["rows"]:
		gids.append(gr["id"])
	for g: String in mvp:
		assert_true(gids.has(g), "mvp 장르 %s ∈ genres.json" % g)


func test_roster_matches_slots_in_order() -> void:
	var slots: Array = _rules["roster_plan"]["slots"]
	assert_eq(slots.size(), _rows.size())
	for i: int in range(mini(slots.size(), _rows.size())):
		assert_eq(_key(_rows[i]), _key(slots[i]), "행 %d ↔ 슬롯 %s (N1: 순서 s01→s12)" % [i, slots[i]["slot"]])
		assert_eq(slots[i]["slot"], "s%02d" % (i + 1))


func test_roster_matches_handoff_table_literals() -> void:
	# 티켓 결과 절 인계 표를 리터럴로 한 번 더(슬롯 표 ↔ artists.json 기계 대조).
	var expect: Array = [
		"rock|local|6|34|diligent,shy", "rock|local|15|22|hothead,loyal", "rock|local|24|40|moody,perfectionist",
		"rock|rookie|46|52|ambitious,showman", "indie|local|9|46|perfectionist,shy", "indie|local|18|28|easygoing,loyal",
		"indie|local|27|18|free_spirit,showman", "indie|rookie|42|60|diligent,moody", "electronic|local|12|30|easygoing,free_spirit",
		"electronic|local|21|38|ambitious,diligent", "electronic|rookie|50|44|hothead,showman",
		"electronic|rookie|55|64|ambitious,perfectionist",
	]
	var got: Array = []
	for r: Dictionary in _rows:
		got.append(_key(r))
	assert_eq(got, expect)


func test_row_field_rules() -> void:
	var rx: RegEx = RegEx.create_from_string("^[a-z0-9_]+$")
	for r: Dictionary in _rows:
		var id: String = r["id"]
		assert_not_null(rx.search(id), "id 형식 " + id)
		var nm: String = r["name"]
		assert_true(nm.length() >= 1 and nm.length() <= 16, "name 1~16자 " + id)
		assert_eq(r["bio_key"], "artist.bio." + id, "N4/L6 bio_key")
		assert_eq((r["rider"] as Array).size(), 0, "rider 빈 배열(v0) " + id)
		assert_true(int(r["popularity"]) >= 0 and int(r["popularity"]) <= 100)
		assert_true(int(r["skill"]) >= 0 and int(r["skill"]) <= 100)


# --- AC2/규칙: 성격 태그 · 배타 쌍 · L8 -----------------------------------------------------------

func test_personality_rules() -> void:
	var vocab: Array = _rules["personality_tags"]
	var pairs: Array = _rules["personality_exclusive_pairs"]
	assert_eq(vocab.size(), 10)
	assert_eq(pairs.size(), 3)
	for p: Array in pairs:
		assert_eq(p.size(), 2)
		assert_true(vocab.has(p[0]) and vocab.has(p[1]), "배타 쌍 태그 ∈ 어휘")
	var uses: Dictionary = {}
	for r: Dictionary in _rows:
		var t: Array = r["personality"]
		assert_eq(t.size(), 2, "성격 2개 " + r["id"])
		assert_ne(t[0], t[1], "서로 다름 " + r["id"])
		for x: String in t:
			assert_true(vocab.has(x), "어휘 안 " + x)
			uses[x] = int(uses.get(x, 0)) + 1
		for p: Array in pairs:
			assert_false(t.has(p[0]) and t.has(p[1]), "배타 쌍 위반 %s %s" % [r["id"], str(p)])
	var total: int = 0
	for k: String in uses:
		total += int(uses[k])
	assert_eq(total, 24)
	for tag: String in ["diligent", "perfectionist", "showman", "ambitious"]:
		assert_eq(int(uses.get(tag, 0)), 3, "태그 사용 횟수 " + tag)


func test_new_game_has_no_already_promotable_local() -> void:
	# L8 / T4
	var thr: int = int(_grade_rule("local")["promote_at_popularity"])
	var local_max: int = 0
	var rookie_min: int = 1000
	for r: Dictionary in _rows:
		if r["grade"] == "local":
			local_max = maxi(local_max, int(r["popularity"]))
			assert_lt(int(r["popularity"]), thr, "local 인기 < 승급 임계 " + r["id"])
		else:
			rookie_min = mini(rookie_min, int(r["popularity"]))
	assert_gte(rookie_min, thr, "rookie 최저 인기 ≥ 승급 임계")
	assert_eq(local_max, 27)
	assert_eq(rookie_min, 42)


# --- AC3: 바이오 · 라벨 ---------------------------------------------------------------------------

func test_bio_rules_n5_n6_n7() -> void:
	var tag_keys: Array = []
	for t: String in _rules["personality_tags"]:
		tag_keys.append("artist.tag." + t)
	assert_eq(_strings.size(), 22, "키 22개 = 바이오 12 + 라벨 10 (N7)")
	for r: Dictionary in _rows:
		var key: String = r["bio_key"]
		assert_true(_strings.has(key), "바이오 존재 " + key)
		var b: String = _strings.get(key, "")
		assert_gt(b.length(), 0)
		assert_lte(b.length(), 120, "바이오 ≤ 120자(코드포인트) " + key)
		# 정확히 2문장: 종결 마침표 2개, 끝이 마침표, 다른 문장부호 없음.
		assert_eq(b.count("."), 2, "마침표 2개 " + key)
		assert_true(b.ends_with("."), "마침표로 끝남 " + key)
		for bad: String in ["?", "!", "…", "\n"]:
			assert_false(b.contains(bad), "문장부호 %s 금지 %s" % [bad, key])
		assert_true(b.find(". ") > 0, "문장 사이 공백 " + key)
		assert_false(b.find(". ") == b.length() - 2, "두 번째 문장 존재 " + key)
	for k: String in tag_keys:
		assert_true(_strings.has(k), "라벨 " + k)
		assert_lte(String(_strings.get(k, "")).length(), 8, "라벨 ≤ 8자 " + k)
	for k: String in _strings:
		assert_true(k.begins_with("artist.bio.") or k.begins_with("artist.tag."), "예상 밖 키 " + k)


# --- AC4: 개런티 = economy.json 참조 -------------------------------------------------------------

func test_guarantee_comes_from_economy() -> void:
	var gbg: Dictionary = _economy["guarantee_by_grade"]
	assert_eq(int(gbg["local"]), 400)
	assert_eq(int(gbg["rookie"]), 800)
	for g: Dictionary in _rules["grades"]:
		assert_true(gbg.has(g["id"]), "grades[%s] ∈ guarantee_by_grade (L4)" % g["id"])
	for r: Dictionary in _rows:
		assert_true(gbg.has(r["grade"]), "명단 등급 ∈ guarantee_by_grade " + r["id"])
	# artist.json 에는 개런티 금액 필드가 없다(단일 출처 economy.json).
	assert_false(JSON.stringify(_rules).contains("guarantee_by_grade"), "artist.json 에 개런티 복제 없음")
	assert_false(_rules["grades"][0].has("guarantee"))
	assert_eq(_rules["guarantee_mode"], "by_grade")
	assert_eq(_economy["charge_reasons"]["guarantee"], "operating")


# --- 성장 시나리오 7건 + 손계산 --------------------------------------------------------------------

func test_reference_scenarios_match_formula() -> void:
	var scs: Array = _rules["reference_scenarios"]
	assert_eq(scs.size(), 7)
	for sc: Dictionary in scs:
		var got: Dictionary = _run_scenario(sc)
		var ex: Dictionary = sc["expected"]
		var pe: Variant = ex["promoted_on_show"]
		assert_eq(got["grade"], ex["grade"], sc["id"] + " grade")
		assert_eq(got["popularity"], int(ex["popularity"]), sc["id"] + " popularity")
		assert_eq(got["skill"], int(ex["skill"]), sc["id"] + " skill")
		assert_eq(got["shows_played"], int(ex["shows_played"]), sc["id"] + " shows_played")
		assert_eq(got["promoted_on_show"], 0 if pe == null else int(pe), sc["id"] + " promoted_on_show")


func test_reference_scenarios_hand_computed_literals() -> void:
	# 손계산(QA 가 artist.md 공식으로 따로 계산): [id, grade, pop, skill, shows, promoted_on(0=없음)]
	var hand: Dictionary = {
		"local_top_all_good": ["rookie", 43, 33, 8, 7],   # 27+2*8=43 (7회째 41≥40 승급, 이후 rookie +2), 18+2*7+1=33
		"local_bottom_all_good": ["rookie", 40, 68, 17, 17],  # 6+2*17=40, 34+2*17=68
		"local_top_all_rave": ["rookie", 42, 28, 5, 5],   # 27+3*5=42, 18+2*5=28
		"promotion_threshold_exact": ["rookie", 40, 12, 1, 1],
		"floor_and_cap": ["local", 0, 100, 3, 0],         # 1-1=0, 0-1->0, 0+0; skill 99+2->100 cap
		"rookie_cap_no_further_promotion": ["rookie", 100, 52, 2, 0],
		"rookie_disaster_no_demotion": ["rookie", 39, 31, 1, 0],
	}
	for sc: Dictionary in _rules["reference_scenarios"]:
		var h: Array = hand[sc["id"]]
		var got: Dictionary = _run_scenario(sc)
		assert_eq([got["grade"], got["popularity"], got["skill"], got["shows_played"], got["promoted_on_show"]], h, sc["id"])


func test_growth_idempotent_inputs_and_promotion_once() -> void:
	var e: Dictionary = {"grade": "local", "popularity": 39, "skill": 10, "shows_played": 0}
	var a: Dictionary = _grow(e, "ok")
	assert_true(a["promoted"])
	assert_eq(e["popularity"], 39, "입력 불변")
	var b: Dictionary = _grow(a, "rave")
	assert_false(b["promoted"], "rookie 는 다시 승급하지 않음")
	assert_eq(b["grade"], "rookie")


# --- T1 / T2 / T3: 승급까지 공연 수 ----------------------------------------------------------------

func test_promotion_show_counts_t1_t2() -> void:
	var r: Dictionary = _grade_rule("local")
	var thr: int = int(r["promote_at_popularity"])
	var d: Dictionary = r["popularity_delta_by_show_grade"]
	var fastest: int = 1000
	var slowest: int = 0
	var table: Dictionary = {}
	for row: Dictionary in _rows:
		if row["grade"] != "local":
			continue
		var pop: int = int(row["popularity"])
		var counts: Array = []
		for sg: String in ["ok", "good", "rave"]:
			var dd: int = int(d[sg])
			counts.append(int(ceil(float(thr - pop) / float(dd))))
		table[row["id"]] = counts
		fastest = mini(fastest, counts[2])
		slowest = maxi(slowest, counts[1])
		# 시뮬레이션과 닫힌 식이 같다
		for i: int in range(3):
			var sg2: String = ["ok", "good", "rave"][i]
			var e: Dictionary = {"grade": "local", "popularity": pop, "skill": int(row["skill"]), "shows_played": 0}
			var n: int = 0
			while e["grade"] == "local" and n < 100:
				e = _grow(e, sg2)
				n += 1
			assert_eq(n, counts[i], "%s %s 승급 공연 수" % [row["id"], sg2])
	assert_eq(fastest, 5, "T1 가장 빠른 = s07 열광 5")
	assert_eq(slowest, 17, "T2 가장 느린 = s01 호평 17")
	assert_gte(fastest, 5)
	assert_lte(slowest, 25, "티어 2 목표 25일 안")
	# artist.md 승급 표 전 행 대조(보통/호평/열광)
	var doc: Dictionary = {
		"thumbnail_soda": [13, 7, 5], "flipped_setlist": [16, 8, 6], "eight_opener": [19, 10, 7], "window_seat": [22, 11, 8],
		"makgeolli_amp": [25, 13, 9], "found_synth": [28, 14, 10], "blanket_tape": [31, 16, 11], "gray_shutter": [34, 17, 12],
	}
	for k: String in doc:
		assert_eq(table[k], doc[k], "artist.md 승급 표 " + k)


func test_rookie_unlock_ratio_t3() -> void:
	var rk: int = int(_grade_rule("rookie")["unlock_reputation"])
	var tier2: int = 0
	for t: Dictionary in _load(TIERS_PATH)["rows"]:
		if int(t["tier"]) == 2:
			tier2 = int(t["unlock_reputation"])
	assert_eq(tier2, 500)
	assert_eq(rk, 150)
	assert_gte(rk * 100, tier2 * 20)
	assert_lte(rk * 100, tier2 * 40)
	assert_eq(int(_grade_rule("local")["unlock_reputation"]), 0, "L5")
	# AR14: rookie 임계는 artist.json 한 곳. 다른 데이터 테이블에 150 이 unlock 으로 복제돼 있지 않음.
	assert_false(JSON.stringify(_economy).contains("unlock_reputation"))


# --- rookie 기대 입장 vs local 손익분기 (artist.md 부록) -------------------------------------------

func _pretax(n: int, guarantee: int) -> int:
	var row: Dictionary = _economy["rows"][0]
	var rs: int = int(_economy["rate_scale"])
	var ticket: int = n * int(row["ticket_price_default"])
	var buyers: int = n * int(row["bar_purchase_rate_bp"]) / rs
	var bar_rev: int = buyers * int(row["bar_avg_spend"])
	var bar_cost: int = bar_rev * int(row["bar_cost_rate_bp"]) / rs
	return ticket + bar_rev - bar_cost - int(row["rent_per_day"]) - int(_economy["reference_scenarios"][0]["upkeep_per_day"]) - guarantee


func test_rookie_breakeven_vs_local() -> void:
	var gl: int = int(_economy["guarantee_by_grade"]["local"])
	var gr: int = int(_economy["guarantee_by_grade"]["rookie"])
	assert_eq(_pretax(100, gl), 1268, "local 100명 pretax(economy 기준 시나리오)")
	assert_eq(_pretax(116, gr), 1259, "116명은 미달")
	assert_eq(_pretax(117, gr), 1286, "117명은 초과")
	var base: int = _pretax(100, gl)
	var need: int = 0
	for n: int in range(100, 300):
		if _pretax(n, gr) >= base:
			need = n - 100
			break
	assert_eq(need, 17, "T5: rookie 가 local(100명) 대비 필요한 추가 입장 = 17")


# --- events.md artist.* 5종 -------------------------------------------------------------------------

func test_events_md_has_artist_rows() -> void:
	var path: String = ProjectSettings.globalize_path("res://").path_join("../docs/gdd/events.md").simplify_path()
	if not FileAccess.file_exists(path):
		pending("events.md 를 찾을 수 없음: " + path)
		return
	var txt: String = FileAccess.get_file_as_string(path)
	for name: String in ["artist.booked", "artist.booking_rejected", "artist.lineup_set", "artist.grown", "artist.book_requested"]:
		assert_true(txt.contains("| `" + name + "` |"), "events.md 행 " + name)
	for reason: String in ["not_allowed", "already_booked", "grade_locked", "insufficient_cash", "unknown_artist"]:
		assert_true(txt.contains("\"" + reason + "\""), "reason " + reason)
