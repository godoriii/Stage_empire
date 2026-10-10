class_name UiPreset
extends RefCounted
## SE-039: 샌드박스 --se-ui-preset=<day|close> 용 가짜 sim 출력(이벤트 이름 + 페이로드 열). 버스에 발행하지 않는다 —
## 샌드박스가 UiRoot.inject 로 패널 핸들러에 직접 넣는다(SE-037 BuildPreset·SE-038 CrowdPreset 과 같은 방식).
## 값은 전부 데이터 기준 시나리오에서 온다(리터럴 없음):
##   정산 = economy.json reference_scenarios[tier1_baseline].expected, 공연 = show.json [local_top_baseline].expected,
##   명성 = reputation.json [local_daily_good_30].expected 의 PRESET_DAY_INDEX 번째 날, 관객 = audience.json [local_top_baseline].
##   라인업 = 명성 시나리오 장르의 첫 등급(artist.json grades[0]) 아티스트 중 인기 최고(artists.json).
## day   = 낮 구간(sim.json phases[0]) + 섭외 패널 열림.  close = 마감 구간(phases 마지막) + 그날 리포트 이벤트 전부.

const ARG: String = "--se-ui-preset="
const NONE: String = ""
const DAY: String = "day"
const CLOSE: String = "close"
const IDS: PackedStringArray = ["day", "close"]
## 명성 시나리오에서 고르는 날(0 부터). 프리셋 표시용 선택 값이지 규칙 수치가 아니다.
const PRESET_DAY_INDEX: int = 2
const ECONOMY_SCENARIO: String = "tier1_baseline"
const SHOW_SCENARIO: String = "local_top_baseline"
const REPUTATION_SCENARIO: String = "local_daily_good_30"
const AUDIENCE_SCENARIO: String = "local_top_baseline"
const REPUTATION_PATH: String = "res://data/reputation/reputation.json"
const AUDIENCE_PATH: String = "res://data/audience/audience.json"
const SHOW_PATH: String = "res://data/show/show.json"
## economy.day_settled 페이로드 키(events.md) — expected 에서 같은 이름만 옮긴다.
## 만족 요소(audience.day_summary.avg_components) 가짜 값 = 공연 만족 satisfaction_bp + 오프셋. 오프셋 합 0 →
## 다섯 요소 평균 = satisfaction_bp(캡처용 그럴듯한 값, 규칙 수치 아님).
const COMPONENT_OFFSETS_BP: Dictionary = {"lineup_bp": 470, "sound_bp": 70, "sight_bp": -130, "value_bp": -330, "wait_bp": -80}
const SETTLED_KEYS: PackedStringArray = [
	"ticket_revenue", "bar_buyers", "bar_revenue", "bar_cost", "revenue", "rent", "upkeep", "guarantee",
	"operating_costs", "pretax", "tax", "net", "loan_repayment", "settlement_delta",
]


static func resolve(user_args: PackedStringArray) -> String:
	for a: String in user_args:
		if a.begins_with(ARG):
			return a.trim_prefix(ARG).strip_edges().to_lower()
	return NONE


static func is_valid_id(id: String) -> bool:
	return IDS.has(id)


static func _scenario(path: String, id: String) -> Dictionary:
	for r: Dictionary in UiData._rows(UiData.read_json(path), "reference_scenarios"):
		if str(r.get("id", "")) == id:
			return r
	return {}


## [[이벤트 이름, 페이로드], …]. 없는 id 면 [].
static func events(id: String, data: UiData, catalog: UiArtistCatalog) -> Array:
	if not is_valid_id(id) or data.phase_ids.is_empty():
		return []
	var eco: Dictionary = _scenario(UiData.ECONOMY_PATH, ECONOMY_SCENARIO)
	var eco_x: Dictionary = eco.get("expected", {}) as Dictionary
	var rep: Dictionary = _scenario(REPUTATION_PATH, REPUTATION_SCENARIO)
	var rep_x: Dictionary = rep.get("expected", {}) as Dictionary
	var show_x: Dictionary = _scenario(SHOW_PATH, SHOW_SCENARIO).get("expected", {}) as Dictionary
	var aud_x: Dictionary = _scenario(AUDIENCE_PATH, AUDIENCE_SCENARIO).get("expected", {}) as Dictionary
	var day: int = PRESET_DAY_INDEX + 1
	var total: int = int((rep_x.get("total", []) as Array)[PRESET_DAY_INDEX])
	var prev_total: int = int((rep_x.get("total", []) as Array)[PRESET_DAY_INDEX - 1]) if PRESET_DAY_INDEX > 0 else 0
	var genre: String = str(((rep.get("show_cycle", []) as Array)[0] as Dictionary).get("genre", ""))
	var cash_start: int = int((rep.get("cash", {}) as Dictionary).get("start", 0))
	var per_day: int = int((rep.get("cash", {}) as Dictionary).get("per_day", 0))
	var cash: int = cash_start + per_day * day
	var by_genre: Dictionary = {}
	var prev_by_genre: Dictionary = {}
	for g: String in data.mvp_genres:
		by_genre[g] = total if g == genre else 0
		prev_by_genre[g] = prev_total if g == genre else 0
	var phase: String = data.phase_ids[0] if id == DAY else data.phase_ids[data.phase_ids.size() - 1]
	var out: Array = [
		["session.loaded", {"day": day, "phase": phase, "speed": int(data.phase_default_speed.get(phase, 0)), "show_active": false}],
		["economy.cash_changed", {"cash": cash if id == CLOSE else cash - per_day, "delta": per_day, "reason": "settlement"}],
		["reputation.changed", {"day": day - 1, "delta": int((rep_x.get("delta", []) as Array)[PRESET_DAY_INDEX - 1]), "total": prev_total,
			"by_genre": prev_by_genre}],
	]
	if id == DAY:
		return out
	var rules: Dictionary = UiData.read_json(UiData.ARTIST_PATH) as Dictionary
	var artist_id: String = _lineup_artist(catalog, genre)
	var row: Dictionary = catalog.artist(artist_id)
	var settled: Dictionary = {"day": day, "ticket_price": data.ticket_price_default, "admissions": int(show_x.get("admissions", 0)),
		"audience": int(show_x.get("audience", 0)), "cash": cash}
	for k: String in SETTLED_KEYS:
		settled[k] = int(eco_x.get(k, 0))
	var adm: int = int(show_x.get("admissions", 0))
	out.append_array([
		["artist.lineup_set", {"day": day, "artist_id": artist_id, "genre": genre, "grade": str(row.get("grade", "")),
			"popularity": int(row.get("popularity", 0)), "skill": int(row.get("skill", 0))}],
		["audience.day_summary", {"day": day, "has_lineup": true, "admissions": adm, "audience": int(show_x.get("audience", 0)),
			"left_early": int(aud_x.get("left_early", 0)), "bar_buyers": int(eco_x.get("bar_buyers", 0)),
			"avg_satisfaction_bp": int(show_x.get("satisfaction_bp", 0)), "crowd_bp": int(aud_x.get("crowd_bp", 0)),
			"avg_components": _components(int(show_x.get("satisfaction_bp", 0))), "by_type": {}}],
		["show.ended", {"day": day, "artist_id": artist_id, "satisfaction_bp": int(show_x.get("satisfaction_bp", 0)),
			"grade": str(show_x.get("grade", "")), "admissions": adm, "audience": int(show_x.get("audience", 0)),
			"revenue_hint": int(show_x.get("revenue_hint", 0)), "incidents": []}],
		["artist.grown", _grown(rules, row, artist_id, day, str(show_x.get("grade", "")))],
		["reputation.changed", {"day": day, "delta": int((rep_x.get("delta", []) as Array)[PRESET_DAY_INDEX]), "total": total,
			"by_genre": by_genre}],
		["economy.day_settled", settled],
		["economy.cash_changed", {"cash": cash, "delta": per_day, "reason": "settlement"}],
	])
	return out


## artist.grown: 등급 규칙(artist.json grades[]) popularity_delta_by_show_grade[공연 등급]·skill_per_show 를 한 번 적용.
static func _grown(rules: Dictionary, row: Dictionary, artist_id: String, day: int, show_grade: String) -> Dictionary:
	var grade: String = str(row.get("grade", ""))
	var rule: Dictionary = {}
	for g: Dictionary in UiData._rows(rules, "grades"):
		if str(g.get("id", "")) == grade:
			rule = g
	var dp: int = int((rule.get("popularity_delta_by_show_grade", {}) as Dictionary).get(show_grade, 0))
	var ds: int = int(rule.get("skill_per_show", 0))
	return {"day": day, "artist_id": artist_id, "grade": grade, "popularity": int(row.get("popularity", 0)) + dp,
		"skill": int(row.get("skill", 0)) + ds, "popularity_delta": dp, "skill_delta": ds, "shows_played": day, "promoted": false}


static func _components(satisfaction_bp: int) -> Dictionary:
	var out: Dictionary = {}
	for k: String in COMPONENT_OFFSETS_BP:
		out[k] = satisfaction_bp + int(COMPONENT_OFFSETS_BP[k])
	return out


## 장르가 맞고 첫 등급인 아티스트 중 인기 최고(동률이면 데이터 순서 앞).
static func _lineup_artist(catalog: UiArtistCatalog, genre: String) -> String:
	var rules: Dictionary = UiData.read_json(UiData.ARTIST_PATH) as Dictionary
	var first_grade: String = str(((rules.get("grades", []) as Array)[0] as Dictionary).get("id", ""))
	var best: String = ""
	var best_pop: int = -1
	for id: String in catalog.artist_ids():
		var r: Dictionary = catalog.artist(id)
		if str(r.get("genre", "")) == genre and str(r.get("grade", "")) == first_grade and int(r.get("popularity", 0)) > best_pop:
			best = id
			best_pop = int(r.get("popularity", 0))
	return best
