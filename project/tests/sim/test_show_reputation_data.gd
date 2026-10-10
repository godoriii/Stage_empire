extends GutTest
## SE-030 AC1~AC6 (qa) — 공연·명성 데이터 회귀 테스트. 실제 JSON 을 읽어 show.md / reputation.md 규칙(SR3, RG2~RG6,
## FC1~FC4, TU1~TU4)을 테스트 안의 공식 사본으로 다시 계산하고 `reference_scenarios` 의 날별 리터럴과 대조한다.
## 기대 수치는 데이터(show.json / reputation.json / tiers.json / artist.json / economy.json / audience.json)에서 읽고,
## 부록 A 의 핵심 손계산 값(18 / 21 / 8일 / 25일 / 495 / 516 / 29,408 / 30,550)은 리터럴로 한 번 더 단언한다.
## SE-035 의 ShowConfig / ReputationSystem 이 없어도 도는 순수 데이터 테스트다(SE-028/029/031 데이터 테스트 선례).

const SHOW_PATH: String = "res://data/show/show.json"
const REP_PATH: String = "res://data/reputation/reputation.json"
const ART_PATH: String = "res://data/artist/artist.json"
const GENRES_PATH: String = "res://data/genres/genres.json"
const TIERS_PATH: String = "res://data/tiers/tiers.json"
const ECO_PATH: String = "res://data/economy/economy.json"
const AUD_PATH: String = "res://data/audience/audience.json"
const SHOW_MD: String = "../docs/gdd/show.md"
const REP_MD: String = "../docs/gdd/reputation.md"
const EVENTS_MD: String = "../docs/gdd/events.md"
const SHOW_SCHEMA: String = "res://data/schemas/show.schema.json"
const REP_SCHEMA: String = "res://data/schemas/reputation.schema.json"

var _show: Dictionary
var _rep: Dictionary
var _art: Dictionary
var _genre_rows: Array
var _tiers: Dictionary
var _eco: Dictionary
var _aud: Dictionary
var _g: Array
var _rate: int


func _load(path: String) -> Dictionary:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "열 수 없음: " + path)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	assert_true(parsed is Dictionary, "JSON 객체가 아님: " + path)
	return parsed if parsed is Dictionary else {}


func _doc(rel: String) -> String:
	var path: String = ProjectSettings.globalize_path("res://").path_join(rel).simplify_path()
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func before_all() -> void:
	_show = _load(SHOW_PATH)
	_rep = _load(REP_PATH)
	_art = _load(ART_PATH)
	_genre_rows = _load(GENRES_PATH).get("rows", [])
	_tiers = _load(TIERS_PATH)
	_eco = _load(ECO_PATH)
	_aud = _load(AUD_PATH)
	_g = _art.get("mvp_genres", [])
	_rate = int(_eco.get("rate_scale", 0))


func _sorted_keys(d: Dictionary) -> Array:
	var ks: Array = d.keys()
	ks.sort()
	return ks


## JSON 숫자는 float 로 파싱된다. 소수부가 없는 수만 정수로 본다.
func _is_int(v: Variant) -> bool:
	return (v is int) or (v is float and is_equal_approx(float(v), roundf(float(v))))


## 문서 표의 "1,234" 같은 숫자 문자열을 int 로.
func _num(txt: String) -> int:
	return int(txt.replace(",", ""))


## JSON 숫자는 float 로 파싱되므로 비교 전에 재귀적으로 int 로 접는다.
func _ints(v: Variant) -> Variant:
	if v is float:
		return int(v)
	if v is Array:
		var out: Array = []
		for x: Variant in v:
			out.append(_ints(x))
		return out
	if v is Dictionary:
		var d: Dictionary = {}
		for k: Variant in v:
			d[k] = _ints(v[k])
		return d
	return v


func _row(genre_id: String) -> Dictionary:
	for r: Dictionary in _genre_rows:
		if r["id"] == genre_id:
			return r
	return {}


# --- 공식 사본 (show.md SR3, reputation.md RG2~RG6 · FC1~FC4 · TU1~TU4) -------------------------------

func _grade_of(sat: int) -> String:
	var chosen: String = ""
	for gr: Dictionary in _show["grades"]:
		if sat >= int(gr["min_bp"]):
			chosen = gr["id"]
	return chosen


func _aff(a: String, b: String) -> int:
	return roundi(float(_row(a)["affinity"][b]) * float(_rate))


func _factor(adm: int) -> int:
	var f: Dictionary = _rep["admission_factor"]
	return clampi(adm * _rate / int(f["admissions_ref"]), int(f["min_bp"]), int(f["max_bp"]))


## [focus, eff_bp]. FC1 미충족이면 ["none", -1].
func _focus(by: Dictionary, genre: String) -> Array:
	var foc: Dictionary = _rep["focus"]
	var s: int = 0
	for h: String in _g:
		s += int(by[h])
	if s < int(foc["min_genre_sum"]):
		return ["none", -1]
	var num: int = 0
	for h: String in _g:
		num += int(by[h]) * _aff(genre, h)
	var eff: int = num / s
	if eff >= int(foc["identity_share_bp"]):
		return ["identity", eff]
	var breadth: bool = true
	for h: String in _g:
		if int(by[h]) * _rate < int(foc["breadth_min_share_bp"]) * s:
			breadth = false
	return ["breadth" if breadth else "none", eff]


## RG2~RG5. {delta, factor, focus}
func _delta(by: Dictionary, genre: String, grade: String, adm: int) -> Dictionary:
	var b: int = int(_rep["base_by_grade"][grade])
	var f: int = _factor(adm)
	if b < 0:
		return {"delta": -((-b) * f / _rate), "factor": f, "focus": "none"}
	var fk: String = _focus(by, genre)[0]
	var foc: Dictionary = _rep["focus"]
	var bonus: int = 0
	if fk == "identity":
		bonus = int(foc["identity_bonus_bp"])
	elif fk == "breadth":
		bonus = int(foc["breadth_bonus_bp"])
	return {"delta": (b * f / _rate) * (_rate + bonus) / _rate, "factor": f, "focus": fk}


## 시나리오 한 개를 날마다 돌린다. 반환: 날별 배열들 + 최종 by_genre + 해금일.
func _run(sc: Dictionary) -> Dictionary:
	var by: Dictionary = {}
	for h: String in _g:
		by[h] = 0
	var total: int = 0
	var unlocked: int = 1
	var out: Dictionary = {
		"grade": [], "factor_bp": [], "focus": [], "computed_delta": [], "delta": [], "total": [],
		"tier_unlocked_days": [], "cash": [],
	}
	var cycle: Array = sc["show_cycle"]
	for d: int in range(1, int(sc["days"]) + 1):
		var sh: Variant = cycle[(d - 1) % cycle.size()]
		if sh == null:
			for k: String in ["grade", "factor_bp", "focus", "computed_delta", "delta"]:
				(out[k] as Array).append(null)
		else:
			var gr: String = _grade_of(int(sh["satisfaction_bp"]))
			var r: Dictionary = _delta(by, sh["genre"], gr, int(sh["admissions"]))
			var nt: int = maxi(0, total + int(r["delta"]))
			by[sh["genre"]] = maxi(0, int(by[sh["genre"]]) + int(r["delta"]))
			(out["grade"] as Array).append(gr)
			(out["factor_bp"] as Array).append(r["factor"])
			(out["focus"] as Array).append(r["focus"])
			(out["computed_delta"] as Array).append(r["delta"])
			(out["delta"] as Array).append(nt - total)
			total = nt
		(out["total"] as Array).append(total)
		var cash: int = int(sc["cash"]["start"]) + int(sc["cash"]["per_day"]) * d
		(out["cash"] as Array).append(cash)
		var nxt: Dictionary = _tier_row(unlocked + 1)
		if unlocked + 1 <= int(_rep["tier_unlock"]["max_tier"]) and not nxt.is_empty() and cash >= int(nxt["unlock_cash"]) and total >= int(nxt["unlock_reputation"]):
			unlocked += 1
			(out["tier_unlocked_days"] as Array).append(d)
	out["by_genre_final"] = by
	return out


func _tier_row(tier: int) -> Dictionary:
	for r: Dictionary in _tiers["rows"]:
		if int(r["tier"]) == tier:
			return r
	return {}


func _first_day(series: Array, threshold: int) -> Variant:
	for i: int in range(series.size()):
		if int(series[i]) >= threshold:
			return i + 1
	return null


func _scenario(id: String) -> Dictionary:
	for sc: Dictionary in _rep["reference_scenarios"]:
		if sc["id"] == id:
			return sc
	return {}


func _rookie_unlock() -> int:
	for gr: Dictionary in _art["grades"]:
		if gr["id"] == "rookie":
			return int(gr["unlock_reputation"])
	return -1


## 입장 계수(bp): _factor 와 별도로 쓰는 인라인 식. 독립 재계산용.
func _factor_inline(adm: int) -> int:
	var f: Dictionary = _rep["admission_factor"]
	var raw: int = adm * _rate / int(f["admissions_ref"])
	return mini(maxi(raw, int(f["min_bp"])), int(f["max_bp"]))


## 보정 없는 하루 Δ(양수 등급): ⌊base × 계수 ÷ rate⌋.
func _plain_delta(grade: String, adm: int) -> int:
	return int(_rep["base_by_grade"][grade]) * _factor_inline(adm) / _rate


## 정체성 보정이 붙은 하루 Δ: ⌊⌊base × 계수 ÷ rate⌋ × (rate + 보너스) ÷ rate⌋ (이중 내림, RG5).
func _identity_delta(grade: String, adm: int) -> int:
	return _plain_delta(grade, adm) * (_rate + int(_rep["focus"]["identity_bonus_bp"])) / _rate


# =====================================================================================================
# AC4 / SH10 / SH11: show.json 필드 · 등급 임계
# =====================================================================================================

func test_show_json_fields() -> void:
	assert_eq(_show.keys().size(), 4, "최상위 키 4개")
	for k: String in ["version", "satisfaction_source", "grades", "reference_scenarios"]:
		assert_true(_show.has(k), k)
	assert_eq(int(_show["version"]), 1)
	assert_eq(_show["satisfaction_source"], "audience.day_summary.avg_satisfaction_bp", "SR1 진실의 출처")
	var grades: Array = _show["grades"]
	assert_eq(grades.size(), 5)
	var ids: Array = []
	for gr: Dictionary in grades:
		assert_eq(gr.keys().size(), 3, "grade 행 필드 id/name/min_bp")
		assert_true(gr.has("id") and gr.has("name") and gr.has("min_bp"))
		assert_true(String(gr["name"]).length() >= 1, "표시 이름")
		ids.append(gr["id"])
	assert_eq(ids, ["disaster", "poor", "ok", "good", "rave"])
	assert_eq(ids, _art["show_grades"], "SL2: artist.json show_grades 와 id·순서 같음")
	var names: Array = []
	for gr: Dictionary in grades:
		names.append(gr["name"])
	assert_eq(names, ["참사", "부진", "보통", "호평", "열광"])


func test_show_json_has_no_satisfaction_weights() -> void:
	# SH11: 만족 가중치는 audience.json 한 곳. show.json 에 가중치·해금 임계 키가 없다.
	var txt: String = JSON.stringify(_show)
	for bad: String in ["weights", "weight", "penalty", "skill_", "crowd_comfort", "unlock_reputation", "unlock_cash"]:
		assert_false(txt.contains(bad), "show.json 에 '%s' 키/문구 없음" % bad)
	assert_true(_aud["satisfaction"].has("weights_bp"), "가중치는 audience.json satisfaction")


func test_grade_thresholds_monotonic_ac3() -> void:
	var mins: Array = []
	for gr: Dictionary in _show["grades"]:
		mins.append(int(gr["min_bp"]))
	assert_eq(mins, [0, 3000, 5000, 6000, 7500], "임계 리터럴(손계산 기준)")
	assert_eq(mins[0], 0, "SL3: 첫 행 0")
	for i: int in range(1, mins.size()):
		assert_true(int(mins[i]) > int(mins[i - 1]), "엄격히 증가 %d" % i)
	assert_true(int(mins[mins.size() - 1]) <= _rate, "마지막 ≤ rate_scale")


func test_grade_boundaries() -> void:
	var grades: Array = _show["grades"]
	assert_eq(_grade_of(0), "disaster")
	assert_eq(_grade_of(_rate), "rave")
	for k: int in range(1, grades.size()):
		var m: int = int(grades[k]["min_bp"])
		assert_eq(_grade_of(m - 1), grades[k - 1]["id"], "min_bp-1 → 이전 등급 (%d)" % m)
		assert_eq(_grade_of(m), grades[k]["id"], "min_bp → 이 등급 (%d)" % m)
	# 모든 0..10000 에서 정확히 하나
	for s: int in range(0, _rate + 1, 250):
		assert_ne(_grade_of(s), "", "만족 %d 는 어느 등급이든 가진다" % s)


func test_show_reference_scenarios_recomputed() -> void:
	# SH12: audience.json 같은 id 시나리오로 재계산(입력 = 손계산 평균, 범위 양 끝 등급 동일).
	var aud_by: Dictionary = {}
	for a: Dictionary in _aud["reference_scenarios"]:
		aud_by[a["id"]] = a
	var seen: Array = []
	for sc: Dictionary in _show["reference_scenarios"]:
		seen.append(sc["id"])
		var a: Dictionary = aud_by.get(sc["audience_scenario"], {})
		assert_false(a.is_empty(), sc["id"] + ": audience 시나리오 존재")
		if a.is_empty():
			continue
		var x: Dictionary = _ints(sc["expected"])
		var ax: Dictionary = a["expected"]
		if a["lineup"] == null:
			assert_eq(x, {"event": "show.skipped", "reason": "no_lineup"}, sc["id"])
		elif not bool(sc["has_stage"]):
			assert_eq(x, {"event": "show.skipped", "reason": "no_stage"}, sc["id"])
		else:
			var sat: int = int(ax["avg_satisfaction_bp_hand"])
			var rng: Array = ax["avg_satisfaction_bp_range"]
			assert_eq(x["event"], "show.ended")
			assert_eq(x["satisfaction_bp"], sat, sc["id"] + " satisfaction")
			assert_eq(x["grade"], _grade_of(sat), sc["id"] + " grade")
			assert_eq(_grade_of(int(rng[0])), _grade_of(int(rng[1])), sc["id"] + ": 범위 양 끝 같은 등급")
			assert_eq(x["grade_over_range"], _grade_of(int(rng[1])))
			assert_eq(x["admissions"], int(ax["admissions"]))
			assert_eq(x["audience"], int(ax["audience"]))
			assert_eq(x["expected_admissions"], int(ax["admissions"]))
			assert_eq(x["revenue_hint"], int(ax["admissions"]) * int(a["ticket_price"]), sc["id"] + " revenue_hint = 입장 × 가격")
	assert_eq(seen, ["no_lineup", "local_top_baseline", "rookie_baseline", "local_top_price30", "no_stage"])


func test_show_numeric_targets_sg1_sg4() -> void:
	# SG1~SG4 수치 목표(show.md; 규칙 ST0~ST3 과 구분). 경계에서 200 bp 이상 떨어짐은 입장 수 기준 시나리오에 대해서만(만석은 test_full_house_margin).
	var aud_by: Dictionary = {}
	for a: Dictionary in _aud["reference_scenarios"]:
		aud_by[a["id"]] = a
	var mins: Array = []
	for gr: Dictionary in _show["grades"]:
		mins.append(int(gr["min_bp"]))
	for id: String in ["local_top_baseline", "rookie_baseline", "local_top_price30"]:
		var r: Array = aud_by[id]["expected"]["avg_satisfaction_bp_range"]
		for m: int in mins:
			# 범위 전체가 경계의 같은 쪽에 있고 거리 ≥ 200
			assert_false(int(r[0]) < m and int(r[1]) >= m, "%s 범위가 경계 %d 를 가로지름" % [id, m])
			var dist: int = mini(absi(int(r[0]) - m), absi(int(r[1]) - m))
			assert_true(dist >= 200 or m == 0, "%s ↔ 경계 %d 거리 %d ≥ 200 (SG3)" % [id, m, dist])
	assert_eq(_grade_of(6732), "good")
	assert_eq(_grade_of(5730), "ok", "SG2: 가격 30 은 한 단계 아래")
	var no_lineup: int = int(aud_by["no_lineup"]["expected"]["avg_satisfaction_bp_hand"])
	assert_eq(_grade_of(no_lineup), "poor", "SG4: 단골만 온 날 수준은 poor 구간")


# =====================================================================================================
# AC3 / AC4: reputation.json 필드 · base 단조 · 실패 감소 · 하한
# =====================================================================================================

func test_reputation_json_fields() -> void:
	for k: String in ["version", "base_by_grade", "admission_factor", "focus", "tier_unlock", "checks", "reference_scenarios"]:
		assert_true(_rep.has(k), k)
	assert_eq(_rep.keys().size(), 7)
	assert_eq(int(_rep["version"]), 1)
	assert_eq((_rep["base_by_grade"] as Dictionary).keys().size(), 5)
	assert_eq(_rep["base_by_grade"].keys(), _art["show_grades"], "RL2: base_by_grade 키·순서 = show_grades")
	# 값은 고정하지 않는다(reputation.md Q3~Q5·Q9 는 "데이터만" 바꾸는 항목). 키 집합·정수 타입·범위만 본다.
	# 값 일치는 test_reference_scenarios_match_formula(reference_scenarios.expected 재계산)가 맡는다.
	var af: Dictionary = _rep["admission_factor"]
	assert_eq(_sorted_keys(af), ["admissions_ref", "max_bp", "min_bp"])
	for k: String in af:
		assert_true(_is_int(af[k]), "admission_factor.%s 정수" % k)
	assert_true(int(af["admissions_ref"]) >= 1, "admissions_ref ≥ 1 (0 으로 나누지 않는다)")
	assert_true(int(af["min_bp"]) >= 1 and int(af["min_bp"]) <= int(af["max_bp"]), "0 < min_bp ≤ max_bp")
	var fo: Dictionary = _rep["focus"]
	assert_eq(_sorted_keys(fo), ["breadth_bonus_bp", "breadth_min_share_bp", "identity_bonus_bp", "identity_share_bp", "min_genre_sum"])
	for k: String in fo:
		assert_true(_is_int(fo[k]) and int(fo[k]) >= 0, "focus.%s 0 이상 정수" % k)
	assert_true(int(fo["min_genre_sum"]) >= 1, "min_genre_sum ≥ 1 (FC1 나눗셈 보호)")
	for k: String in ["identity_share_bp", "breadth_min_share_bp"]:
		assert_true(int(fo[k]) <= _rate, "focus.%s ≤ rate_scale" % k)
	var tu: Dictionary = _rep["tier_unlock"]
	assert_eq(_sorted_keys(tu), ["max_tier"])
	assert_true(_is_int(tu["max_tier"]) and int(tu["max_tier"]) >= 2 and int(tu["max_tier"]) <= 6, "RL7: 2 ≤ max_tier ≤ 6")
	assert_eq(_rep["checks"]["main_scenario"], "local_daily_good_30")
	var ids: Array = []
	for sc: Dictionary in _rep["reference_scenarios"]:
		ids.append(sc["id"])
		for k: String in ["id", "description", "days", "show_cycle", "cash", "expected"]:
			assert_true(sc.has(k), "%s.%s" % [sc["id"], k])
		for k: String in ["grade", "factor_bp", "focus", "computed_delta", "delta", "total", "by_genre_final", "tier_unlocked_days", "day_reach_rookie_unlock", "day_reach_tier2_reputation", "day_reach_tier2_cash"]:
			assert_true(sc["expected"].has(k), "%s.expected.%s" % [sc["id"], k])
		for k: String in ["grade", "factor_bp", "focus", "computed_delta", "delta", "total"]:
			assert_eq((sc["expected"][k] as Array).size(), int(sc["days"]), "%s.%s 길이 = days" % [sc["id"], k])
	assert_eq(ids, ["local_daily_good_30", "rotation_good_30", "failure_floor_6", "reputation_first_40"])


func test_base_by_grade_ac3() -> void:
	var b: Dictionary = _ints(_rep["base_by_grade"])
	assert_eq(_sorted_keys(b), ["disaster", "good", "ok", "poor", "rave"], "5 등급 키 (값은 Q3: 데이터만)")
	var seq: Array = []
	for gid: String in _art["show_grades"]:
		seq.append(int(b[gid]))
	for i: int in range(1, seq.size()):
		assert_true(int(seq[i]) > int(seq[i - 1]), "base 엄격히 증가 %d" % i)
	assert_true(b["disaster"] < 0 and b["poor"] < 0, "실패 등급 음수")
	assert_true(b["ok"] > 0 and b["good"] > 0 and b["rave"] > 0, "나머지 양수(0 없음)")
	var f: Dictionary = _rep["admission_factor"]
	assert_true(int(f["min_bp"]) <= int(f["max_bp"]))
	for gid: String in ["disaster", "poor"]:
		assert_true((-int(b[gid])) * int(f["min_bp"]) / _rate >= 1, "RL4: %s 최소 입장에서도 Δ ≠ 0" % gid)
	assert_true(absi(int(b["disaster"])) > int(b["good"]), "RT6: 참사 1회 손실 ≥ 호평 1회 이득")


func test_failure_delta_negative_for_all_admissions() -> void:
	# RT4 / AC3: 실패 등급 Δ < 0 — 입장 0 ~ 500, 장르 벡터가 비었든 가득하든
	var empty: Dictionary = {}
	var full: Dictionary = {}
	for h: String in _g:
		empty[h] = 0
		full[h] = 1000
	for gid: String in ["disaster", "poor"]:
		for adm: int in range(0, 501):
			for by: Dictionary in [empty, full]:
				var r: Dictionary = _delta(by, "indie", gid, adm)
				assert_true(int(r["delta"]) < 0, "%s adm=%d Δ=%d" % [gid, adm, int(r["delta"])])
				assert_eq(r["focus"], "none", "실패에는 장르 보정 없음(RG4)")
	for gid: String in ["ok", "good", "rave"]:
		for adm: int in [0, 1, 50, 100, 500]:
			assert_true(int(_delta(empty, "indie", gid, adm)["delta"]) > 0, "%s 양수" % gid)


func test_floor_zero_total_and_by_genre_separately() -> void:
	# RG6: 총합·장르별 각각 하한 0. 실패를 20일 연속 넣어도 둘 다 음수가 되지 않는다.
	var sc: Dictionary = {
		"days": 20, "cash": {"start": 0, "per_day": 0},
		"show_cycle": [{"genre": "rock", "satisfaction_bp": 1000, "admissions": 10}],
	}
	var r: Dictionary = _run(sc)
	for t: Variant in r["total"]:
		assert_true(int(t) >= 0)
	for h: String in _g:
		assert_true(int(r["by_genre_final"][h]) >= 0)
	for d: Variant in r["delta"]:
		assert_eq(int(d), 0, "0 에서 실패하면 실제 변화량 0")
	# 분리: indie 3일 호평(54/54) 뒤 rock 참사 → rock 은 0 에서 막혀도 total 은 54 − 24 = 30 (Q7)
	var mix: Dictionary = {
		"days": 4, "cash": {"start": 0, "per_day": 0},
		"show_cycle": [
			{"genre": "indie", "satisfaction_bp": 6732, "admissions": 83},
			{"genre": "indie", "satisfaction_bp": 6732, "admissions": 83},
			{"genre": "indie", "satisfaction_bp": 6732, "admissions": 83},
			{"genre": "rock", "satisfaction_bp": 1000, "admissions": 83},
		],
	}
	var m: Dictionary = _run(mix)
	# 기대값은 데이터(base_by_grade, admission_factor)에서 닫힌 식으로 다시 계산한다(리터럴 18/54/30 없음).
	var good_d: int = _plain_delta("good", 83)
	var bad_d: int = -((-int(_rep["base_by_grade"]["disaster"])) * _factor_inline(83) / _rate)
	assert_true(2 * good_d < int(_rep["focus"]["min_genre_sum"]), "전제: 3일째까지 FC1 미충족(보정 없음)이라 닫힌 식이 성립")
	assert_eq(m["total"], [good_d, 2 * good_d, 3 * good_d, maxi(0, 3 * good_d + bad_d)])
	assert_eq(int(m["by_genre_final"]["rock"]), 0)
	assert_eq(int(m["by_genre_final"]["indie"]), 3 * good_d)
	assert_true(3 * good_d + bad_d > 0, "분리 검증 전제: total 은 하한에 막히지 않는다")


func test_no_duplicated_unlock_thresholds_ar14() -> void:
	# RP13 / AR14: 해금 임계는 tiers.json(티어) · artist.json(섭외) 한 곳. reputation.json / show.json 에는 키도 값 복제도 없다.
	var keys: Array = []
	_collect_keys(_rep, keys)
	_collect_keys(_show, keys)
	for k: Variant in keys:
		assert_false(String(k).begins_with("unlock_"), "unlock_* 키 금지: " + String(k))
	# rookie 임계(150)·티어 2 임계(500)·자금(30000)이 checks/설정 값으로 중복 저장되지 않았다(시나리오 expected 의 도달일은 날짜일 뿐)
	var dump: String = JSON.stringify([_rep["base_by_grade"], _rep["admission_factor"], _rep["focus"], _rep["tier_unlock"], _rep["checks"]])
	assert_false(dump.contains("30000"), "자금 임계 복제 없음")
	var t2: Dictionary = _tier_row(2)
	assert_eq(int(t2["unlock_reputation"]), 500, "PRD 티어 2 명성")
	assert_eq(int(t2["unlock_cash"]), 30000, "PRD 티어 2 자금")
	assert_eq(_rookie_unlock(), 150, "artist.json rookie 해금")
	assert_true(_rep["tier_unlock"].has("max_tier") and _rep["tier_unlock"].keys().size() == 1)
	# 문서도 임계 값을 한 곳(데이터)에서 읽는다고 적었는지
	var rep_md: String = _doc(REP_MD)
	if not rep_md.is_empty():
		assert_true(rep_md.contains("값을 복제하지 않는다"), "reputation.md AR14 문구")


func _collect_keys(v: Variant, out: Array) -> void:
	if v is Dictionary:
		for k: Variant in v:
			out.append(k)
			_collect_keys(v[k], out)
	elif v is Array:
		for x: Variant in v:
			_collect_keys(x, out)


# =====================================================================================================
# AC2 / RP12 / RP15: 기준 시나리오 재계산 · 부록 A 손계산
# =====================================================================================================

func test_reference_scenarios_match_formula() -> void:
	for sc: Dictionary in _rep["reference_scenarios"]:
		var got: Dictionary = _run(sc)
		var ex: Dictionary = _ints(sc["expected"])
		for k: String in ["grade", "factor_bp", "focus", "computed_delta", "delta", "total"]:
			var g: Array = got[k]
			var e: Array = ex[k]
			assert_eq(g.size(), e.size(), "%s.%s 길이" % [sc["id"], k])
			for i: int in range(mini(g.size(), e.size())):
				assert_eq(g[i], e[i], "%s.%s 일 %d" % [sc["id"], k, i + 1])
		assert_eq(_ints(got["by_genre_final"]), ex["by_genre_final"], sc["id"] + " by_genre_final")
		assert_eq(got["tier_unlocked_days"], ex["tier_unlocked_days"], sc["id"] + " 해금일")
		var cash_series: Array = got["cash"]
		assert_eq(_first_day(got["total"], _rookie_unlock()), ex["day_reach_rookie_unlock"], sc["id"] + " 150 도달")
		assert_eq(_first_day(got["total"], int(_tier_row(2)["unlock_reputation"])), ex["day_reach_tier2_reputation"], sc["id"] + " 500 도달")
		assert_eq(_first_day(cash_series, int(_tier_row(2)["unlock_cash"])), ex["day_reach_tier2_cash"], sc["id"] + " 자금 도달")


func test_appendix_a_hand_calc_literals() -> void:
	# 부록 A. 독립 재계산 (indie 매일). 입력(입장·평균 만족)은 시나리오에서, 수치는 데이터에서 읽고
	# 닫힌 식으로 기대값을 만든다: total(d) = d·p (d ≤ k), k·p + (d−k)·q (d > k).
	# p = 보정 없는 Δ, q = 정체성 Δ, k = 처음으로 장르 합 S = k·p 가 min_genre_sum 에 닿는 날 수(보정은 k+1 일부터).
	# 리터럴 숫자 기대값(18/21/516 ...)은 손계산 스크립트 tools/bot/se030_hand_calc.py 가 맡는다.
	var sc: Dictionary = _scenario("local_daily_good_30")
	assert_false(sc.is_empty())
	var inp: Dictionary = sc["show_cycle"][0]
	var adm: int = int(inp["admissions"])
	var grade: String = _grade_of(int(inp["satisfaction_bp"]))
	assert_eq(grade, "good", "이 시나리오는 호평 입력")
	var p: int = _plain_delta(grade, adm)
	var q: int = _identity_delta(grade, adm)
	assert_true(p >= 1, "RL4: 양수 등급 Δ ≥ 1")
	var min_sum: int = int(_rep["focus"]["min_genre_sum"])
	var k: int = (min_sum + p - 1) / p
	assert_eq(_aff("indie", "indie"), _rate, "순수 인디 벡터의 eff = rate_scale")
	assert_true(_rate >= int(_rep["focus"]["identity_share_bp"]), "순수 벡터는 identity 문턱을 넘는다")
	var r: Dictionary = _run(sc)
	var tot: Array = r["total"]
	var want: Array = []
	for d: int in range(1, int(sc["days"]) + 1):
		want.append(d * p if d <= k else k * p + (d - k) * q)
	assert_eq(tot, want, "total(d) 닫힌 식")
	var foc: Array = r["focus"].slice(0, k + 1)
	var want_foc: Array = []
	for d: int in range(1, k + 2):
		want_foc.append("none" if d <= k else "identity")
	assert_eq(foc, want_foc, "정체성 보너스는 k+1 일부터(갱신 전 S ≥ min_genre_sum)")
	assert_eq(r["computed_delta"].slice(0, k + 1), _rep_arr(p, k, q), "일별 Δ")
	# 도달일: 닫힌 식의 계열에서 임계를 처음 넘는 날(두 임계는 tiers.json / artist.json 에서 읽는다)
	var rookie: int = _rookie_unlock()
	var need: int = int(_tier_row(2)["unlock_reputation"])
	assert_eq(_first_day(tot, rookie), _first_day(want, rookie), "신인 해금 도달일")
	assert_eq(_first_day(tot, need), _first_day(want, need), "티어 2 명성 도달일")
	assert_true(_first_day(want, need) != null, "30일 안에 티어 2 명성 도달")
	# 현금: economy 기준 시나리오에서 시작·일 순이익을 읽는다
	var es: Dictionary = {}
	for e: Dictionary in _eco["reference_scenarios"]:
		if e["id"] == sc["cash_from_economy_scenario"]:
			es = e
	var start: int = int(_eco["starting_cash"]) - int(es["initial_build_spend"])
	var net: int = int(es["expected"]["net"])
	var cash: Array = r["cash"]
	for d: int in range(1, int(sc["days"]) + 1):
		assert_eq(int(cash[d - 1]), start + net * d, "현금 d=%d" % d)
	var cash_need: int = int(_tier_row(2)["unlock_cash"])
	var day_rep: Variant = _first_day(want, need)
	var day_cash: Variant = _first_day(cash, cash_need)
	assert_eq(r["tier_unlocked_days"], [maxi(int(day_rep), int(day_cash))], "해금은 두 조건이 모두 찬 첫날 1회")
	var gate: int = maxi(int(day_rep), int(day_cash))
	if gate > 1:
		assert_true(int(tot[gate - 2]) < need or int(cash[gate - 2]) < cash_need, "전날에는 둘 중 하나 미달")


func _rep_arr(p: int, k: int, q: int) -> Array:
	var out: Array = []
	for d: int in range(1, k + 2):
		out.append(p if d <= k else q)
	return out


func test_cash_series_matches_economy_scenario() -> void:
	var sc: Dictionary = _scenario("local_daily_good_30")
	var es: Dictionary = {}
	for e: Dictionary in _eco["reference_scenarios"]:
		if e["id"] == sc["cash_from_economy_scenario"]:
			es = e
	assert_false(es.is_empty())
	assert_eq(int(sc["cash"]["start"]), int(_eco["starting_cash"]) - int(es["initial_build_spend"]))
	assert_eq(int(sc["cash"]["per_day"]), int(es["expected"]["net"]))
	assert_eq(int(es["expected"]["days_to_tier2_cash"]), 25, "economy 자금 도달 25일")
	# 독립 재유도: net = pretax − tax(10%, 흑자일만)
	var x: Dictionary = es["expected"]
	var pretax: int = int(x["ticket_revenue"]) + int(x["bar_revenue"]) - int(x["rent"]) - int(x["upkeep"]) - int(x["guarantee"]) - int(x["bar_cost"])
	var tax: int = pretax * int(_eco["rows"][0]["tax_rate_bp"]) / _rate if pretax > 0 else 0
	assert_eq(pretax - tax, int(x["net"]))


func test_rt_targets() -> void:
	var c: Dictionary = _rep["checks"]
	var m: Dictionary = _ints(_scenario(c["main_scenario"])["expected"])
	var lo: int = int(c["tier2_reputation_day_range"][0])
	var hi: int = int(c["tier2_reputation_day_range"][1])
	assert_eq([lo, hi], [20, 30])
	assert_true(int(m["day_reach_tier2_reputation"]) >= lo and int(m["day_reach_tier2_reputation"]) <= hi, "RT1 AC2: 500 도달 20~30")
	assert_true(int(m["day_reach_rookie_unlock"]) >= int(c["rookie_unlock_day_range"][0]) and int(m["day_reach_rookie_unlock"]) <= int(c["rookie_unlock_day_range"][1]), "RT2 (artist.md T6)")
	assert_true(absi(int(m["day_reach_tier2_reputation"]) - int(m["day_reach_tier2_cash"])) <= int(c["tier2_reputation_cash_gap_max_days"]), "RT3")
	# RT5: 집중 vs 확산 500 도달일 차 ≤ 2
	var a: Dictionary = _ints(_scenario("local_daily_good_30")["expected"])
	var b: Dictionary = _ints(_scenario("rotation_good_30")["expected"])
	assert_true(absi(int(a["day_reach_tier2_reputation"]) - int(b["day_reach_tier2_reputation"])) <= 2, "RT5")
	if int(_rep["focus"]["identity_bonus_bp"]) == int(_rep["focus"]["breadth_bonus_bp"]):
		assert_eq(a["total"], b["total"], "보너스가 같으면 두 전략의 궤적이 같다(Q5)")


func test_rotation_orders_all_reach_tier2_same_day() -> void:
	# 순환 전략의 6가지 순서는 서로 같은 날 도달한다(확산 보너스는 순서와 무관). 집중 전략과의 차이는 RT5(≤ 2일).
	# 수치 리터럴(25일)은 없다: 도달일은 모두 이 파일의 공식 재계산에서 나온다. 두 보너스가 같은지(Q5)는 요구하지 않는다.
	var perms: Array = [
		["rock", "indie", "electronic"], ["rock", "electronic", "indie"], ["indie", "rock", "electronic"],
		["indie", "electronic", "rock"], ["electronic", "rock", "indie"], ["electronic", "indie", "rock"],
	]
	var main: Dictionary = _run(_scenario("local_daily_good_30"))
	var need: int = int(_tier_row(2)["unlock_reputation"])
	var main_day: Variant = _first_day(main["total"], need)
	assert_true(main_day != null, "집중 전략은 30일 안에 티어 2 명성 도달")
	var first_perm_day: Variant = null
	for p: Array in perms:
		var cyc: Array = []
		for gid: String in p:
			cyc.append({"genre": gid, "satisfaction_bp": 6732, "admissions": 83})
		var r: Dictionary = _run({"days": 30, "cash": _scenario("local_daily_good_30")["cash"], "show_cycle": cyc})
		var day: Variant = _first_day(r["total"], need)
		assert_true(day != null, "순환 %s: 30일 안에 도달" % ",".join(p))
		if first_perm_day == null:
			first_perm_day = day
		assert_eq(day, first_perm_day, "순환 %s: 순서와 무관" % ",".join(p))
		if day != null and main_day != null:
			assert_true(absi(int(day) - int(main_day)) <= 2, "순환 %s: 집중과 ≤ 2일 차(RT5)" % ",".join(p))


func test_failure_floor_scenario_hand_values() -> void:
	# 등급·입력은 시나리오 데이터에서, Δ 는 닫힌 식(실패는 보정 없음 RG4, 하한 RG6)으로 다시 계산한다.
	var sc: Dictionary = _scenario("failure_floor_6")
	var r: Dictionary = _run(sc)
	var cyc: Array = sc["show_cycle"]
	var grades: Array = []
	var factors: Array = []
	var comp: Array = []
	var total: Array = []
	var delta: Array = []
	var t: int = 0
	var by_indie: int = 0
	for i: int in range(cyc.size()):
		if cyc[i] == null:
			grades.append(null)
			factors.append(null)
			comp.append(null)
			delta.append(null)
			total.append(t)
			continue
		var gid: String = _grade_of(int(cyc[i]["satisfaction_bp"]))
		var adm: int = int(cyc[i]["admissions"])
		var b: int = int(_rep["base_by_grade"][gid])
		var f: int = _factor_inline(adm)
		var c: int = -((-b) * f / _rate) if b < 0 else (b * f / _rate)
		grades.append(gid)
		factors.append(f)
		comp.append(c)
		var nt: int = maxi(0, t + c)
		delta.append(nt - t)
		t = nt
		total.append(t)
		by_indie = maxi(0, by_indie + c)
	assert_eq(r["grade"], grades)
	assert_eq(r["factor_bp"], factors, "계수 하한·상한")
	assert_eq(r["computed_delta"], comp, "계산값(하한 전)")
	assert_eq(r["delta"], delta, "실제 변화량(하한 후)")
	assert_eq(r["total"], total)
	assert_eq(r["tier_unlocked_days"], [])
	assert_true((r["delta"] as Array).has(0), "하한에 막혀 실제 변화량 0 인 날이 있다(RG6 검증 입력)")


func test_tier_unlock_needs_both_conditions() -> void:
	# TU3 AND: 명성이 먼저 차도(25일) 자금(35일)이 찰 때까지 해금 없음, 해금은 정확히 1회
	var r: Dictionary = _run(_scenario("reputation_first_40"))
	var row2: Dictionary = _tier_row(2)
	var day_rep: Variant = _first_day(r["total"], int(row2["unlock_reputation"]))
	var day_cash: Variant = _first_day(r["cash"], int(row2["unlock_cash"]))
	assert_true(day_rep != null and day_cash != null and int(day_rep) < int(day_cash), "이 시나리오는 명성이 먼저 찬다")
	assert_eq(r["tier_unlocked_days"], [day_cash], "명성이 먼저 차도 자금이 찰 때까지 해금 없음")
	assert_true(int(r["total"][int(day_rep) - 1]) >= int(row2["unlock_reputation"]) and int(r["cash"][int(day_rep) - 1]) < int(row2["unlock_cash"]), "명성 도달일: 명성만 충족")
	# 자금만 먼저 충족하는 경우(명성 0): 해금 없음
	var cash_only: Dictionary = _run({"days": 5, "cash": {"start": 40000, "per_day": 0}, "show_cycle": [null]})
	assert_eq(cash_only["tier_unlocked_days"], [])
	# max_tier 를 넘는 해금은 명성·자금이 훨씬 커도 없다
	var big: Dictionary = _run({"days": 60, "cash": {"start": 100000, "per_day": 1000}, "show_cycle": [{"genre": "indie", "satisfaction_bp": 7600, "admissions": 122}]})
	assert_true((big["tier_unlocked_days"] as Array).size() >= 1 and (big["tier_unlocked_days"] as Array).size() <= int(_rep["tier_unlock"]["max_tier"]) - 1, "해금 횟수는 max_tier − 1 을 넘지 않는다")


func test_focus_judgement_table_in_reputation_md() -> void:
	# reputation.md "보정 판정 예" 7행: 비율 → 오늘 장르별 (eff_bp, focus). 기대값은 문서 표에서 읽는다.
	var md: String = _doc(REP_MD)
	if md.is_empty():
		pending("reputation.md 없음")
		return
	assert_eq(_g, ["rock", "indie", "electronic"], "표의 열 순서 = mvp_genres")
	var ratio_re: RegEx = RegEx.create_from_string("^\\s*(\\d+) / (\\d+) / (\\d+)\\s*$")
	var cell_re: RegEx = RegEx.create_from_string("([\\d,]+)\\s+\\**(none|identity|breadth)\\**")
	var rows: int = 0
	for line: String in md.split("\n"):
		if not line.begins_with("| "):
			continue
		var cells: PackedStringArray = line.split("|")
		if cells.size() < 6:
			continue
		var rm: RegExMatch = ratio_re.search(cells[1])
		if rm == null:
			continue
		rows += 1
		var by: Dictionary = {}
		for i: int in range(_g.size()):
			by[_g[i]] = int(rm.get_string(i + 1))
		for i: int in range(_g.size()):
			var cm: RegExMatch = cell_re.search(cells[2 + i])
			assert_not_null(cm, "표 칸 해석 %s" % cells[2 + i])
			if cm == null:
				continue
			var res: Array = _focus(by, _g[i])
			assert_eq(res[0], cm.get_string(2), "focus %s %s" % [str(by), _g[i]])
			assert_eq(res[1], _num(cm.get_string(1)), "eff_bp %s %s" % [str(by), _g[i]])
	assert_eq(rows, 7, "보정 판정 예 7행")
	# FC1: 장르 합이 min_genre_sum − 1 이면 판정 불가, min_genre_sum 이면 가능(순수 인디)
	var ms: int = int(_rep["focus"]["min_genre_sum"])
	assert_eq(_focus({"rock": 0, "indie": ms - 1, "electronic": 0}, "indie"), ["none", -1])
	assert_eq(_focus({"rock": 0, "indie": ms, "electronic": 0}, "indie")[0], "identity")
	# 정체성이 아니고 세 장르 점유율이 모두 문턱 이상이면 관객 폭(40/40/20 은 문턱 ≤ 20% 일 때)
	if int(_rep["focus"]["breadth_min_share_bp"]) <= 2000:
		assert_eq(_focus({"rock": 40, "indie": 40, "electronic": 20}, "electronic")[0], "breadth", "세 장르 모두 문턱 이상이고 정체성 아님 → 관객 폭")


func test_focus_exact_boundaries() -> void:
	# FC4 경계: 점유율이 문턱(breadth_min_share_bp)과 정확히 같은 장르가 있으면 관객 폭(≥), 1 단위 모자라면 탈락.
	# 벡터 합을 rate_scale 로 맞추면 점유율 비교 by×rate ≥ T×S 가 by ≥ T 로 떨어진다.
	var t: int = int(_rep["focus"]["breadth_min_share_bp"])
	var idn: int = int(_rep["focus"]["identity_share_bp"])
	var exact: Dictionary = {"rock": t, "indie": t, "electronic": _rate - 2 * t}
	var eff: int = int(_focus(exact, "rock")[1])
	if eff >= idn or exact["electronic"] < t:
		pending("현재 데이터에서는 이 벡터가 정체성이거나 문턱 미만이라 경계 케이스를 만들 수 없다")
		return
	assert_eq(_focus(exact, "rock")[0], "breadth", "점유율 정확히 문턱은 포함(≥)")
	var under: Dictionary = {"rock": t - 1, "indie": t + 1, "electronic": _rate - 2 * t}
	assert_eq(_focus(under, "rock")[0], "none", "문턱 − 1 은 관객 폭 아님")
	# FC3 경계(eff 가 identity_share_bp 와 정확히 같으면 identity)는 문서 표의 경계 행(0 / 50 / 50 의 indie)이
	# test_focus_judgement_table_in_reputation_md 에서 데이터와 함께 추적한다.


func test_delta_table_in_reputation_md() -> void:
	# reputation.md "하루 Δ 표" 25칸. 열: 입장 50 · 83 · 100 (보정 없음), 83 · 100 (정체성 보정, 순수 인디 벡터).
	# 기대값은 문서 표에서 읽는다(리터럴 없음): 데이터를 바꾸고 표를 안 고치면 이 테스트가 문서 불일치를 알린다.
	# 'ok' 83명 보정은 이중 내림(⌊⌊b×f⌋×(1+보너스)⌋)이라 한 번에 내린 값과 다를 수 있다 — _identity_delta 가 순서를 고정한다.
	var md: String = _doc(REP_MD)
	if md.is_empty():
		pending("reputation.md 없음")
		return
	var names: Dictionary = {"참사": "disaster", "부진": "poor", "보통": "ok", "호평": "good", "열광": "rave"}
	var seen: int = 0
	var empty: Dictionary = {"rock": 0, "indie": 0, "electronic": 0}
	var pure: Dictionary = {"rock": 0, "indie": 500, "electronic": 0}
	for line: String in md.split("\n"):
		if not line.begins_with("| "):
			continue
		var cells: PackedStringArray = line.split("|")
		if cells.size() < 8 or not names.has(cells[1].strip_edges()):
			continue
		var gid: String = names[cells[1].strip_edges()]
		var vals: Array = []
		for i: int in range(2, 7):
			var m: RegEx = RegEx.create_from_string("[−-]?\\d[\\d,]*")
			var hits: Array[RegExMatch] = m.search_all(cells[i].replace("(보정 없음)", ""))
			assert_eq(hits.size(), 1, "%s 칸 %d: 숫자 하나" % [gid, i - 1])
			var txt: String = hits[0].get_string()
			var neg: bool = txt.begins_with("−") or txt.begins_with("-")
			vals.append((-1 if neg else 1) * _num(txt.trim_prefix("−").trim_prefix("-")))
		seen += 1
		assert_eq(int(_delta(empty, "indie", gid, 50)["delta"]), vals[0], gid + " 50명")
		assert_eq(int(_delta(empty, "indie", gid, 83)["delta"]), vals[1], gid + " 83명")
		assert_eq(int(_delta(empty, "indie", gid, 100)["delta"]), vals[2], gid + " 100명")
		assert_eq(int(_delta(pure, "indie", gid, 83)["delta"]), vals[3], gid + " 83명 + 보정")
		assert_eq(int(_delta(pure, "indie", gid, 100)["delta"]), vals[4], gid + " 100명 + 보정")
		if int(_rep["base_by_grade"][gid]) > 0:
			assert_eq(_identity_delta(gid, 83), vals[3], gid + " 83명 보정: 닫힌 식(이중 내림)")
	assert_eq(seen, 5, "표의 5 등급 행")


# =====================================================================================================
# AC4: genres.json affinity
# =====================================================================================================

func test_affinity_3x3_symmetric_diagonal() -> void:
	assert_eq(_g, ["rock", "indie", "electronic"])
	for a: String in _g:
		var row: Dictionary = _row(a)
		assert_true(row.has("affinity"), a + " affinity 있음")
		assert_eq((row["affinity"] as Dictionary).keys().size(), 3, a + " affinity 키 정확히 3개(자기 포함)")
		for b: String in _g:
			assert_true(row["affinity"].has(b), "%s→%s" % [a, b])
			var v: float = float(row["affinity"][b])
			assert_true(v >= 0.0 and v <= 1.0, "범위 0~1")
			assert_eq(_aff(a, b), _aff(b, a), "대칭 %s-%s" % [a, b])
		assert_eq(_aff(a, a), _rate, "대각 1.0")
	assert_eq(_aff("rock", "indie"), 5000)
	assert_eq(_aff("indie", "electronic"), 4000)
	assert_eq(_aff("rock", "electronic"), 2000)


func test_affinity_other_five_genres_empty_allowed() -> void:
	var others: int = 0
	for r: Dictionary in _genre_rows:
		if not _g.has(r["id"]):
			others += 1
			assert_false(r.has("affinity"), "MVP 밖 %s 는 affinity 비움(RP11)" % r["id"])
	assert_eq(others, 5)
	assert_eq(_genre_rows.size(), 8)
	for r: Dictionary in _genre_rows:
		assert_true(r.has("id") and r.has("name") and r.has("accent_color"), "기존 필드 유지")


func test_genres_schema_affinity_description_only_change() -> void:
	var s: Dictionary = _load("res://data/schemas/genres.schema.json")
	var aff: Dictionary = s["properties"]["rows"]["items"]["properties"]["affinity"]
	assert_eq(aff["type"], "object")
	assert_eq(_ints(aff["additionalProperties"]), {"type": "number", "minimum": 0, "maximum": 1})
	assert_false(s["properties"]["rows"]["items"]["required"].has("affinity"), "affinity 는 필수가 아니다(5장르 비움 허용)")


# =====================================================================================================
# 스키마 파일 구조 (런타임이 아니라 정의 자체 가드)
# =====================================================================================================

func test_schemas_pin_core_constraints() -> void:
	var ss: Dictionary = _load(SHOW_SCHEMA)
	assert_eq(ss["required"], ["version", "satisfaction_source", "grades", "reference_scenarios"])
	assert_eq(ss["additionalProperties"], false)
	assert_eq(_ints(ss["properties"]["version"]), {"type": "integer", "enum": [1]})
	assert_eq(ss["properties"]["satisfaction_source"]["enum"], ["audience.day_summary.avg_satisfaction_bp"])
	assert_eq(_ints(ss["properties"]["grades"])["minItems"], 5)
	assert_eq(_ints(ss["properties"]["grades"])["maxItems"], 5)
	assert_eq(ss["$defs"]["show_grade"]["enum"], ["disaster", "poor", "ok", "good", "rave"])
	var rs: Dictionary = _load(REP_SCHEMA)
	assert_eq(rs["additionalProperties"], false)
	assert_eq(rs["required"].size(), 7)
	var bg: Dictionary = rs["properties"]["base_by_grade"]
	assert_eq(_ints(bg["properties"]["disaster"]), {"type": "integer", "maximum": -1})
	assert_eq(_ints(bg["properties"]["poor"]), {"type": "integer", "maximum": -1})
	for gid: String in ["ok", "good", "rave"]:
		assert_eq(_ints(bg["properties"][gid]), {"type": "integer", "minimum": 1})
	assert_eq(bg["additionalProperties"], false)
	var mt: Dictionary = _ints(rs["properties"]["tier_unlock"]["properties"]["max_tier"])
	assert_eq(mt["maximum"], 6)
	assert_eq(mt["minimum"], 2, "RL7 과 일치(SE-048 A: 스키마 하한 1 → 2)")


# =====================================================================================================
# AC1 / AC5: 문서 · events.md 5행
# =====================================================================================================

func test_events_md_has_five_rows_and_payloads() -> void:
	var txt: String = _doc(EVENTS_MD)
	if txt.is_empty():
		pending("events.md 를 찾을 수 없음")
		return
	var rows: Dictionary = {}
	for l: String in txt.split("\n"):
		for name: String in ["show.started", "show.skipped", "show.ended", "reputation.changed", "reputation.tier_unlocked"]:
			if l.begins_with("| `" + name + "` |"):
				rows[name] = l
	assert_eq(rows.keys().size(), 5, "5행 모두 존재")
	for name: String in rows:
		assert_true((rows[name] as String).ends_with("| SE-030 |"), name + " 스펙 티켓 SE-030")
	var st: String = rows.get("show.started", "")
	for k: String in ["day: int", "artist_id: String", "genre: String", "expected_admissions: int"]:
		assert_true(st.contains(k), "show.started " + k)
	var sk: String = rows.get("show.skipped", "")
	assert_true(sk.contains("day: int") and sk.contains("no_lineup") and sk.contains("no_stage"))
	var en: String = rows.get("show.ended", "")
	for k: String in ["day: int", "artist_id: String", "satisfaction_bp: int", "admissions: int", "audience: int", "revenue_hint: int", "incidents: Array"]:
		assert_true(en.contains(k), "show.ended " + k)
	var last: int = -1
	for gid: String in ["disaster", "poor", "ok", "good", "rave"]:
		var pos: int = en.find("\"" + gid + "\"")
		assert_true(pos > last, "show.ended grade 영문 id %s 순서" % gid)
		last = pos
	assert_false(en.contains("참사\"") or en.contains("\"열광"), "grade 는 영문 id 만")
	var rc: String = rows.get("reputation.changed", "")
	for k: String in ["day: int", "delta: int", "total: int", "by_genre"]:
		assert_true(rc.contains(k), "reputation.changed " + k)
	assert_true(rc.contains("하한"), "delta 는 하한 적용 뒤 실제 변화량")
	var tu: String = rows.get("reputation.tier_unlocked", "")
	assert_true(tu.contains("tier: int") and tu.contains("day: int"))
	# show.md / reputation.md 본문이 말하는 이벤트 이름은 전부 events.md 에 있다
	var rx: RegEx = RegEx.create_from_string("`((?:show|reputation|audience|economy|build|artist|time)\\.[a-z_]+)`")
	for rel: String in [SHOW_MD, REP_MD]:
		var md: String = _doc(rel)
		assert_false(md.is_empty(), rel)
		var names: Dictionary = {}
		for m: RegExMatch in rx.search_all(md):
			names[m.get_string(1)] = true
		assert_true(names.size() >= 10, rel + ": 이벤트 이름이 충분히 잡힘")
		for n: String in names:
			if n.ends_with(".json") or n.ends_with(".md"):
				continue
			assert_true(txt.contains("`" + n + "`"), "%s 의 %s 가 events.md 에 있다" % [rel, n])


func test_docs_consistent_with_ticket_deltas() -> void:
	# 티켓 초안과 다른 점 4개가 show.md / reputation.md / events.md 에 일관되게 적혔다.
	var show_md: String = _doc(SHOW_MD)
	var rep_md: String = _doc(REP_MD)
	var ev: String = _doc(EVENTS_MD)
	if show_md.is_empty() or rep_md.is_empty() or ev.is_empty():
		pending("문서를 찾을 수 없음")
		return
	# (1) 구독 추가
	for n: String in ["audience.admissions_decided", "economy.ticket_price_changed", "time.day_started"]:
		assert_true(show_md.contains("`" + n), "show.md 구독 " + n)
		assert_true(ev.contains("`" + n + "`"), "events.md " + n)
	assert_true(rep_md.contains("show.started") and rep_md.contains("time.day_started"))
	assert_false(rep_md.contains("| `time.phase_changed"), "reputation 은 time.phase_changed 를 구독하지 않는다")
	# (2) show.skipped {day, reason}
	assert_true(show_md.contains("\"no_lineup\"") and show_md.contains("\"no_stage\""))
	# (3) delta = 하한 적용 뒤 실제 변화량
	assert_true(rep_md.contains("하한을 적용한 뒤 실제 변화량"))
	# (4) show.json 에 만족 가중치 없음, 진실의 출처 SR1/SR2
	assert_true(show_md.contains("SR1") and show_md.contains("SR2") and show_md.contains("에는 가중치가 없다"))
	# 규칙 번호가 수용 기준과 맞물림
	for id: String in ["SH1", "SH9", "SH13", "ST1", "SG1", "SG4"]:
		assert_true(show_md.contains("| " + id + " |"), "show.md " + id)
	for id: String in ["RP1", "RP10", "RP15", "RT1", "RT6"]:
		assert_true(rep_md.contains("| " + id + " |"), "reputation.md " + id)
	# artist.md 성장 절이 audience 평균을 진실의 출처로 적는다(audience.md Q7 과 모순 없음)
	var art_md: String = _doc("../docs/gdd/artist.md")
	assert_true(art_md.contains("만족도의 진실의 출처는 `audience.day_summary.avg_satisfaction_bp`"))
	assert_false(art_md.contains("만족도의 진실의 출처는 show.md)"), "옛 문구 제거")


func test_system_order_matches_event_chain_assumption() -> void:
	# show.md 의 이벤트 순서(show.ended → artist.grown → reputation.changed)는 sim.json system_order 에 기댄다.
	var sim: Dictionary = _load("res://data/sim/sim.json")
	var order: Array = sim["system_order"]
	assert_true(order.find("audience") < order.find("show"), "show 는 audience 뒤")
	assert_true(order.find("artist") < order.find("reputation"), "artist(성장) → reputation(명성)")
	assert_eq(order[order.size() - 1], "reputation", "reputation 이 마지막")
	assert_true(order.find("show") < order.find("economy"))
	# 공연 구간 길이: 공연 마지막 틱 = 3,300, 공연 진입 경계 = 2,400 (day 1800 + evening 600)
	var ticks: Dictionary = {}
	for p: Dictionary in sim["phases"]:
		ticks[p["id"]] = int(p["ticks"])
	assert_eq(int(ticks["day"]) + int(ticks["evening"]), 2400)
	assert_eq(int(ticks["day"]) + int(ticks["evening"]) + int(ticks["show"]), 3300)


func test_full_house_margin_documented() -> void:
	# 민감도: 부록 C 의 만석(122명) 평균(문서에서 읽는다)은 호평 구간이고, 한 단계 내려가면 Δ 가 줄어든다.
	var md: String = _doc(REP_MD)
	if md.is_empty():
		pending("reputation.md 없음")
		return
	var m: RegExMatch = RegEx.create_from_string("10일 122\\(만석\\) / ([\\d,]+) /").search(md)
	assert_not_null(m, "부록 C 에 10일 만석 평균이 있다")
	if m == null:
		return
	var sat: int = _num(m.get_string(1))
	assert_eq(_grade_of(sat), "good", "만석 평균은 호평 구간(문서 서술: 호평 하한 근처)")
	var good_min: int = 0
	for gr: Dictionary in _show["grades"]:
		if gr["id"] == "good":
			good_min = int(gr["min_bp"])
	assert_true(sat >= good_min, "호평 하한 이상 (여유 %d bp)" % (sat - good_min))
	var by: Dictionary = {"rock": 0, "indie": 400, "electronic": 0}
	var good_d: int = int(_delta(by, "indie", "good", 122)["delta"])
	var ok_d: int = int(_delta(by, "indie", "ok", 122)["delta"])
	assert_eq(good_d, _identity_delta("good", 122), "호평 Δ 닫힌 식")
	assert_eq(ok_d, _identity_delta("ok", 122), "보통 Δ 닫힌 식")
	assert_true(ok_d < good_d, "호평 → 보통이면 Δ 가 줄어든다")
