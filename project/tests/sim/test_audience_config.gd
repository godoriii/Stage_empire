extends GutTest
## SE-034 — AudienceConfig. docs/gdd/audience.md #설정-로드-검사 AL1~AL10(AU0)과 순수 함수 3개(expected_by_type·admissions_from·
## agent_satisfaction)를 옮겼다. 기대 수치는 audience.json reference_scenarios·expected 와 데이터 행에서 읽는다. 부록 B2 의
## 유형별 만족 손계산 값(4,600 등)은 문서 표의 리터럴이고, 같은 공식을 테스트 안에서 독립적으로 다시 계산해 한 번 더 대조한다.

const AUDIENCE_PATH: String = "res://data/audience/audience.json"
const ARTIST_PATH: String = "res://data/artist/artist.json"
const GENRES_PATH: String = "res://data/genres/genres.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const SIM_PATH: String = "res://data/sim/sim.json"
const MAP_PATH: String = "res://data/maps/tier1_club.json"

var _raw: Dictionary = {}
var _cfg: AudienceConfig


func _read(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func before_all() -> void:
	_raw = {
		"audience": _read(AUDIENCE_PATH), "artist": _read(ARTIST_PATH), "genres": _read(GENRES_PATH),
		"economy": _read(ECONOMY_PATH), "sim": _read(SIM_PATH), "map": _read(MAP_PATH),
	}
	_cfg = AudienceConfig.load()


func _from(d: Dictionary) -> AudienceConfig:
	return AudienceConfig.from_dicts(d["audience"], d["artist"], d["genres"], d["economy"], d["sim"], d["map"])


func _slot(slot_id: String) -> Dictionary:
	for s: Dictionary in _raw["artist"]["roster_plan"]["slots"]:
		if s["slot"] == slot_id:
			return s
	return {}


# --- AU0 로드·교차 검사 --------------------------------------------------------------

func test_au0_config_loads_and_reads_tables() -> void:
	assert_not_null(_cfg, "실제 데이터로 로드")
	var a: Dictionary = _raw["audience"]
	assert_eq(_cfg.version, int(a["version"]))
	assert_eq(_cfg.max_agents, int(a["max_agents"]))
	assert_eq(_cfg.pos_scale, int(a["pos_scale"]))
	assert_eq(_cfg.rate_scale, int(_raw["economy"]["rate_scale"]))
	var ids: Array[String] = []
	for t: Dictionary in a["types"]:
		ids.append(t["id"])
		assert_eq(_cfg.color(t["id"]), t["color"], "color %s" % t["id"])
		assert_eq(_cfg.type_rule(t["id"])["patience_ticks"], int(t["patience_ticks"]))
	assert_eq(_cfg.type_ids(), ids, "유형 순서 = 데이터 순서")
	var genres: Array = []
	genres.append_array(_cfg.genres)
	assert_eq(genres, _raw["artist"]["mvp_genres"], "mvp_genres")
	assert_eq(_cfg.entrances(), MapConfig.load().entrances(), "입구 = MapConfig 입구(z → x)")
	for ph: Dictionary in _raw["sim"]["phases"]:
		if ph["id"] == "evening":
			assert_eq(_cfg.evening_ticks, int(ph["ticks"]))
		if ph["id"] == "show":
			assert_eq(_cfg.show_ticks, int(ph["ticks"]))
	assert_eq(_cfg.ticket_price_default, int(_raw["economy"]["rows"][0]["ticket_price_default"]))
	assert_eq(_cfg.admission, JsonUtil.int_deep(a["admission"]), "admission 사본")
	assert_eq(_cfg.flow, JsonUtil.int_deep(a["flow"]), "flow 사본")
	assert_eq(_cfg.satisfaction, JsonUtil.int_deep(a["satisfaction"]), "satisfaction 사본")
	# 읽기 전용 사본: 바꿔도 설정 불변
	var f: Dictionary = _cfg.flow
	f["entry_ticks"] = 999
	assert_eq(_cfg.flow["entry_ticks"], int(a["flow"]["entry_ticks"]), "flow 는 깊은 복사본")
	var r: Dictionary = _cfg.type_rule(ids[0])
	r["genre_fit_bp"].clear()
	assert_false((_cfg.type_rule(ids[0])["genre_fit_bp"] as Dictionary).is_empty(), "type_rule 은 깊은 복사본")
	assert_eq(_cfg.scenario("no_lineup")["id"], "no_lineup")
	assert_eq(_cfg.scenario("nope"), {}, "없는 시나리오는 {}")
	assert_eq(_cfg.type_rule("nope"), {}, "없는 유형은 {}")


## AL1~AL10 을 하나씩 깬 사본 → null, push_error 1회씩.
func _broken() -> Array:
	var out: Array = []
	var d: Dictionary
	d = _raw.duplicate(true); d["audience"]["version"] = 1; out.append(["AL1 version 1", d])
	d = _raw.duplicate(true); d["economy"]["rate_scale"] = 1000; out.append(["AL1 rate_scale 1000", d])
	d = _raw.duplicate(true); d["audience"]["types"].pop_back(); out.append(["AL2 유형 2개", d])
	d = _raw.duplicate(true); d["audience"]["types"][1]["id"] = d["audience"]["types"][0]["id"]; out.append(["AL2 id 중복", d])
	d = _raw.duplicate(true); d["audience"]["types"][0]["genre_fit_bp"].erase("indie"); out.append(["AL3 indie 제거", d])
	d = _raw.duplicate(true); d["audience"]["types"][2]["genre_fit_bp"]["jazz"] = 5000; out.append(["AL3 jazz 추가", d])
	d = _raw.duplicate(true); d["artist"]["mvp_genres"].append("polka")
	for t: Dictionary in d["audience"]["types"]:
		t["genre_fit_bp"]["polka"] = 1000
	out.append(["AL3 genres.json 에 없는 장르", d])
	d = _raw.duplicate(true); d["audience"]["max_agents"] = int(d["sim"]["individual_agent_cap"]) + 1; out.append(["AL4 max_agents 3001", d])
	d = _raw.duplicate(true); d["audience"]["pos_scale"] = 99; out.append(["AL5 pos_scale 99", d])
	d = _raw.duplicate(true); d["audience"]["pos_scale"] = 102; out.append(["AL5 pos_scale 102 (4 로 안 나눠짐)", d])
	var ev: int = 0
	for ph: Dictionary in _raw["sim"]["phases"]:
		if ph["id"] == "evening":
			ev = int(ph["ticks"])
	d = _raw.duplicate(true); d["audience"]["flow"]["arrival_window_ticks"] = ev + 1; out.append(["AL6 arrival_window 601", d])
	d = _raw.duplicate(true); d["audience"]["satisfaction"]["weights_bp"]["value"] = int(d["audience"]["satisfaction"]["weights_bp"]["value"]) - 1
	out.append(["AL7 가중치 합 9999", d])
	d = _raw.duplicate(true); d["audience"]["admission"]["price_factor_max_bp"] = 9000; out.append(["AL8 price_factor_max 9000", d])
	d = _raw.duplicate(true); d["audience"]["reference_scenarios"][1]["lineup"]["popularity"] = 28; out.append(["AL9 slot 인기 불일치", d])
	d = _raw.duplicate(true); d["audience"]["reference_scenarios"][0]["layout"] = "no_such_layout"; out.append(["AL9 layout 없음", d])
	d = _raw.duplicate(true); d["audience"]["checks"]["rookie_slots"].append("s99"); out.append(["AL9 checks 슬롯 없음", d])
	var min_p: int = 1 << 30
	for t: Dictionary in _raw["audience"]["types"]:
		min_p = mini(min_p, int(t["patience_ticks"]))
	d = _raw.duplicate(true); d["audience"]["flow"]["pass_override_ticks"] = min_p; out.append(["AL10 pass_override_ticks 150", d])
	d = _raw.duplicate(true); d["audience"]["flow"].erase("bar_ticks"); out.append(["flow 필드 누락", d])
	d = _raw.duplicate(true); d["audience"]["types"][0]["patience_ticks"] = 0; out.append(["patience_ticks 0", d])
	return out


func test_au0_cross_checks_reject_broken_copies() -> void:
	assert_not_null(_from(_raw.duplicate(true)), "원본 사본은 통과")
	var cases: Array = _broken()
	assert_gte(cases.size(), 10, "깨는 사본 10건 이상")
	var errs: int = 0
	for c: Array in cases:
		var label: String = c[0]
		assert_null(_from(c[1]), "%s → null" % label)
		errs += 1
		if label.begins_with("AL"):
			assert_push_error(label.substr(0, label.find(" ")), "%s: 오류 문구에 검사 번호" % label)
		assert_push_error_count(errs, "%s: push_error 1회" % label)


# --- 순수 함수: 입장 수 ---------------------------------------------------------------

func test_expected_by_type_reference_scenarios() -> void:
	for sid: String in _cfg.scenario_ids():
		var sc: Dictionary = _cfg.scenario(sid)
		var lu: Variant = sc["lineup"]
		var e: Dictionary = AudienceConfig.expected_by_type(_cfg, lu, sc["reputation_total"], sc["ticket_price"])
		assert_eq(e, sc["expected"]["e_centi"], "%s e_centi" % sid)
		var want: Array = []
		want.append_array(_cfg.type_ids())
		assert_eq(e.keys(), want, "%s 키 순서 = 유형 순서" % sid)


func test_admissions_from_reference_scenarios() -> void:
	var cov: Dictionary = AudienceHarness.new().coverage_payload("baseline_show")
	for sid: String in _cfg.scenario_ids():
		var sc: Dictionary = _cfg.scenario(sid)
		var x: Dictionary = sc["expected"]
		var rng: SeededRng = SeededRng.new(sc["seed"], SimConfig.load().rng_streams)
		var u: int = rng.stream("audience").randi()
		assert_eq(u, x["first_draw"], "%s 첫 randi()" % sid)
		var res: Dictionary = AudienceConfig.admissions_from(x["e_centi"], u, cov["capacity"], cov["has_stage"], _cfg)
		assert_eq(res["expected"], int(x["expected_centi"]) / AudienceConfig.CENTI_PER_PERSON, "%s expected" % sid)
		for k: String in ["noise_bp", "raw", "admissions", "capped_by", "by_type"]:
			assert_eq(res[k], x[k], "%s %s" % [sid, k])


func test_admissions_from_caps_and_labels() -> void:
	var e: Dictionary = {"regular": 1000000, "genre_fan": 0, "walk_in": 0}
	var j: int = _cfg.noise_bp
	var u_zero: int = j   # (u mod (2J+1)) − J = 0
	var r: Dictionary = AudienceConfig.admissions_from(e, u_zero, 40, true, _cfg)
	assert_eq(r["noise_bp"], 0)
	assert_eq([r["admissions"], r["capped_by"]], [40, "capacity"], "수용 40")
	r = AudienceConfig.admissions_from(e, u_zero, _cfg.max_agents, true, _cfg)
	assert_eq([r["admissions"], r["capped_by"]], [_cfg.max_agents, "capacity"], "capacity == max_agents → capacity")
	r = AudienceConfig.admissions_from(e, u_zero, _cfg.max_agents + 50, true, _cfg)
	assert_eq([r["admissions"], r["capped_by"]], [_cfg.max_agents, "max_agents"], "capacity 200 → max_agents")
	r = AudienceConfig.admissions_from(e, u_zero, 122, false, _cfg)
	assert_eq([r["admissions"], r["capped_by"], r["by_type"]["regular"]], [0, "no_stage", 0], "무대 없음")
	r = AudienceConfig.admissions_from({"regular": 1200, "genre_fan": 0, "walk_in": 0}, u_zero, 122, true, _cfg)
	assert_eq([r["admissions"], r["capped_by"], r["raw"]], [12, "none", 12], "상한 아래")
	# 노이즈 양 끝: u mod (2J+1) = 0 → −J, = 2J → +J
	assert_eq(AudienceConfig.admissions_from(e, 0, 122, true, _cfg)["noise_bp"], -j)
	assert_eq(AudienceConfig.admissions_from(e, 2 * j, 122, true, _cfg)["noise_bp"], j)
	assert_eq(AudienceConfig.admissions_from(e, 2 * j + 1, 122, true, _cfg)["noise_bp"], -j)


func test_split_by_type_largest_remainder() -> void:
	# local_top_baseline 부록 B1: 83 명 → 9.57 / 43.06 / 30.38 → 남은 1 명은 나머지가 가장 큰 단골.
	var sc: Dictionary = _cfg.scenario("local_top_baseline")
	var by: Dictionary = AudienceConfig.split_by_type(_cfg, sc["expected"]["e_centi"], sc["expected"]["admissions"])
	assert_eq(by, sc["expected"]["by_type"])
	# 동률은 유형 순서가 앞인 쪽
	by = AudienceConfig.split_by_type(_cfg, {"regular": 1, "genre_fan": 1, "walk_in": 1}, 2)
	assert_eq(by, {"regular": 1, "genre_fan": 1, "walk_in": 0}, "동률 → 앞 유형")
	by = AudienceConfig.split_by_type(_cfg, {"regular": 0, "genre_fan": 0, "walk_in": 0}, 0)
	assert_eq(by, {"regular": 0, "genre_fan": 0, "walk_in": 0}, "E == 0 → 0")
	for n: int in range(0, _cfg.max_agents + 1, 7):
		var s: Dictionary = AudienceConfig.split_by_type(_cfg, {"regular": 960, "genre_fan": 4320, "walk_in": 3048}, n)
		assert_eq(int(s["regular"]) + int(s["genre_fan"]) + int(s["walk_in"]), n, "합 == %d" % n)


# --- 순수 함수: 만족 (부록 B2) ------------------------------------------------------------

## 테스트 쪽 독립 계산(SF2~SF8, 음향·시야 10,000/0).
func _sat_ref(type_id: String, lu: Variant, price: int, crowd: int, bonus: int, sound: int, sight: int, wait: int) -> int:
	var s: Dictionary = _raw["audience"]["satisfaction"]
	var t: Dictionary = {}
	for row: Dictionary in _raw["audience"]["types"]:
		if row["id"] == type_id:
			t = row
	var lb: int = int(s["no_lineup_bp"])
	if lu != null:
		lb = int(t["genre_fit_bp"][lu["genre"]]) * mini(10000, int(s["skill_base_bp"]) + int(lu["skill"]) * int(s["skill_bp_per_point"])) / 10000
	var val: int = clampi(int(s["price_value_mid_bp"]) - int(t["price_sensitivity_bp"]) * (price - int(_raw["audience"]["admission"]["price_ref"])), 0, 10000)
	var wb: int = mini(10000, wait * 10000 / int(t["patience_ticks"]))
	var w: Dictionary = s["weights_bp"]
	var p: Dictionary = s["penalty_weights_bp"]
	var pos: int = int(w["lineup"]) * lb + int(w["sound"]) * sound + int(w["sight"]) * sight + int(w["value"]) * val
	return mini(10000, maxi(0, pos - int(p["crowd"]) * crowd - int(p["wait"]) * wb) / 10000 + bonus)


func _full_agent(type_id: String, wait: int = 0, show: int = 900, sound: int = 900, sight: int = 900) -> Dictionary:
	return AudienceHarness.agent(1, type_id, "watching", [11, 10], {"wait": wait, "show_ticks": show, "sound_ticks": sound, "sight_ticks": sight})


func test_agent_satisfaction_b2_table() -> void:
	var bonus: int = AudienceHarness.new().coverage_payload("baseline_show")["satisfaction_bonus_bp"]
	var s07: Dictionary = _slot("s07")
	var s08: Dictionary = _slot("s08")
	var rookie_crowd: int = _cfg.scenario("rookie_baseline")["expected"]["crowd_bp"]
	# [라벨, 유형, 라인업, 가격, 혼잡, 부록 B2 손계산 값]
	var rows: Array = [
		["no_lineup 단골", "regular", null, 20, 0, 4600],
		["local_top 팬", "genre_fan", s07, 20, 0, 6960],
		["local_top 단골", "regular", s07, 20, 0, 6488],
		["local_top 뜨내기", "walk_in", s07, 20, 0, 6488],
		["rookie 팬", "genre_fan", s08, 20, rookie_crowd, 7341],
		["rookie 단골", "regular", s08, 20, rookie_crowd, 6701],
		["rookie 뜨내기", "walk_in", s08, 20, rookie_crowd, 6701],
		["price30 팬", "genre_fan", s07, 30, 0, 6060],
		["price30 단골", "regular", s07, 30, 0, 5888],
		["price30 뜨내기", "walk_in", s07, 30, 0, 4988],
	]
	for r: Array in rows:
		var got: Dictionary = AudienceConfig.agent_satisfaction(_cfg, _full_agent(r[1]), r[2], r[3], r[4], bonus)
		assert_eq(got["satisfaction_bp"], r[5], "%s: 부록 B2 손계산" % r[0])
		assert_eq(got["satisfaction_bp"], _sat_ref(r[1], r[2], r[3], r[4], bonus, 10000, 10000, 0), "%s: 독립 계산" % r[0])
		assert_eq([got["sound_bp"], got["sight_bp"], got["wait_bp"]], [10000, 10000, 0], "%s: 요소" % r[0])
	# 음향 하나를 놓치면 정확히 weights.sound(1,500) × 10,000 ÷ 10,000 낮다
	var miss: Dictionary = AudienceConfig.agent_satisfaction(_cfg, _full_agent("genre_fan", 0, 900, 0, 900), s07, 20, 0, bonus)
	assert_eq(miss["satisfaction_bp"], 6960 - _cfg.weight_sound_bp, "음향 놓침 −1,500")
	# 대기·공연 0 틱
	var waited: Dictionary = AudienceConfig.agent_satisfaction(_cfg, _full_agent("walk_in", 75, 900, 900, 900), s07, 20, 0, bonus)
	assert_eq(waited["wait_bp"], 75 * 10000 / int(_cfg.type_rule("walk_in")["patience_ticks"]))
	assert_eq(waited["satisfaction_bp"], _sat_ref("walk_in", s07, 20, 0, bonus, 10000, 10000, 75))
	var none: Dictionary = AudienceConfig.agent_satisfaction(_cfg, _full_agent("regular", 0, 0, 0, 0), null, 20, 0, 0)
	assert_eq([none["sound_bp"], none["sight_bp"]], [0, 0], "show_ticks 0 → 0")
	var capped: Dictionary = AudienceConfig.agent_satisfaction(_cfg, _full_agent("regular", 99999), null, 20, 10000, 0)
	assert_eq(capped["wait_bp"], 10000, "대기 상한")
	assert_eq(capped["satisfaction_bp"], _sat_ref("regular", null, 20, 10000, 0, 10000, 10000, 99999), "대기 상한 독립 계산")
	var floor0: Dictionary = AudienceConfig.agent_satisfaction(_cfg, _full_agent("regular", 99999, 0, 0, 0), null, 20, 10000, 0)
	assert_eq(floor0["satisfaction_bp"], 0, "pos < neg → 0 바닥")


## 부록 B2 평균 = (전원 10,000 합 − 1,500 × max(0, 남은 − 94)) ÷ 입장 → avg_satisfaction_bp_hand.
func test_b2_average_hand_values() -> void:
	var cov: Dictionary = AudienceHarness.new().coverage_payload("baseline_show")
	var bonus: int = cov["satisfaction_bonus_bp"]
	var both: int = 0   # 음향 ∩ 시야 관람 타일 수(부록 B2 전제 94)
	for t: Array in cov["sound_tiles"]:
		if (cov["sight_tiles"] as Array).has(t):
			both += 1
	for sid: String in _cfg.scenario_ids():
		var sc: Dictionary = _cfg.scenario(sid)
		var x: Dictionary = sc["expected"]
		var lu: Variant = sc["lineup"]
		var total: int = 0
		for id: String in _cfg.type_ids():
			var a: Dictionary = AudienceConfig.agent_satisfaction(_cfg, _full_agent(id), lu, sc["ticket_price"], x["crowd_bp"], bonus)
			total += int(x["by_type"][id]) * int(a["satisfaction_bp"])
		total -= _cfg.weight_sound_bp * maxi(0, int(x["audience"]) - both)
		assert_eq(total / int(x["admissions"]), x["avg_satisfaction_bp_hand"], "%s 손계산 평균" % sid)


func test_crowd_bp_of() -> void:
	var sc: Dictionary = _cfg.scenario("rookie_baseline")
	assert_eq(AudienceConfig.crowd_bp_of(_cfg, sc["expected"]["audience"], 122), sc["expected"]["crowd_bp"], "rookie 9,180")
	assert_eq(AudienceConfig.crowd_bp_of(_cfg, 83, 122), 0, "편안 구간")
	assert_eq(AudienceConfig.crowd_bp_of(_cfg, 122, 122), 10000, "만석 → 상한")
	assert_eq(AudienceConfig.crowd_bp_of(_cfg, 0, 0), 10000, "capacity 0 → ratio 10,000 (SF5 문자 그대로)")
