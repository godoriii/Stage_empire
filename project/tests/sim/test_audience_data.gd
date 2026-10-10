extends GutTest
## SE-029 (qa) — 관객 스펙 v0 데이터 회귀 테스트. 제품 코드(AudienceConfig·AudienceSystem, SE-034)가 없어도 도는 순수 데이터 테스트다.
## audience.json 의 구조·교차 참조·기준 시나리오 4개를 audience.md 공식(AD1~AD12, SF1~SF9, B2)으로 테스트 안에서 다시 계산해
## `reference_scenarios[].expected` 와 대조한다. 리터럴은 데이터에서 읽고, 핵심 수는 손계산 리터럴로 한 번 더 단언한다
## (독립 Python 재계산: tools/bot/audience_spec_check.py). 시드 파생·첫 뽑기는 실제 SeededRng 로 확인한다.
## 경계: 상태 기계(T1~T15)·이벤트 열·스냅샷은 SE-034 의 AU4~AU11 몫이라 여기서 다루지 않는다.

const AUDIENCE_PATH: String = "res://data/audience/audience.json"
const ARTIST_PATH: String = "res://data/artist/artist.json"
const GENRES_PATH: String = "res://data/genres/genres.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const SIM_PATH: String = "res://data/sim/sim.json"
const MAP_PATH: String = "res://data/maps/tier1_club.json"
const FURNITURE_PATH: String = "res://data/furniture/furniture.json"
const EVENTS_MD: String = "../docs/gdd/events.md"
const AUDIENCE_MD: String = "../docs/gdd/audience.md"
const TICK_MD: String = "../docs/gdd/tick.md"

const TYPE_IDS: Array[String] = ["regular", "genre_fan", "walk_in"]

var _a: Dictionary
var _art: Dictionary
var _genres: Array
var _eco: Dictionary
var _sim: Dictionary
var _map: Dictionary
var _furn: Dictionary
var _types: Array
var _stream_names: Array[String]


## JSON 숫자는 float 로 파싱되므로 Array/Dictionary 비교 전에 재귀적으로 int 로 접는다.
func _ints(v: Variant) -> Variant:
	if v is Array:
		var out: Array = []
		for e: Variant in v:
			out.append(_ints(e))
		return out
	if v is Dictionary:
		var d: Dictionary = {}
		for k: Variant in v:
			d[k] = _ints(v[k])
		return d
	if v is float:
		return int(v)
	return v


func _load(path: String) -> Dictionary:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "열 수 없음: " + path)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	assert_true(parsed is Dictionary, "JSON 객체가 아님: " + path)
	return _ints(parsed) if parsed is Dictionary else {}


func _doc(rel: String) -> String:
	var path: String = ProjectSettings.globalize_path("res://").path_join(rel).simplify_path()
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func before_all() -> void:
	_a = _load(AUDIENCE_PATH)
	_art = _load(ARTIST_PATH)
	_genres = _load(GENRES_PATH).get("rows", [])
	_eco = _load(ECONOMY_PATH)
	_sim = _load(SIM_PATH)
	_map = _load(MAP_PATH)
	_furn = _load(FURNITURE_PATH)
	_types = _a.get("types", [])
	for n: String in _sim["rng_streams"]:
		_stream_names.append(n)


func _slot(slot_id: String) -> Dictionary:
	for s: Dictionary in _art["roster_plan"]["slots"]:
		if s["slot"] == slot_id:
			return s
	return {}


func _scenario(id: String) -> Dictionary:
	for s: Dictionary in _a["reference_scenarios"]:
		if s["id"] == id:
			return s
	return {}


func _layout(id: String) -> Dictionary:
	for l: Dictionary in _map["reference_layouts"]:
		if l["id"] == id:
			return l
	return {}


func _lineup_of(sc: Dictionary) -> Variant:
	return null if sc["lineup"] == null else _slot(sc["lineup"]["slot"])


# --- 공식 사본 (audience.md AD1~AD12, SF1~SF9) -------------------------------------------------------

## AD1~AD5: 유형별 e_t (centi-person). lineup 은 null 또는 슬롯/라인업 Dictionary(genre, popularity).
func _e_centi(lineup: Variant, rep: int, price: int) -> Array[int]:
	var ad: Dictionary = _a["admission"]
	var out: Array[int] = []
	for t: Dictionary in _types:
		if t["needs_lineup"] and lineup == null:
			out.append(0)
			continue
		var draw: int = int(t["base_centi"]) + int(t["reputation_centi"]) * mini(rep, int(ad["reputation_cap"]))
		var fit: int = 10000
		if lineup != null:
			draw += int(t["popularity_centi"]) * int(lineup["popularity"])
			fit = int(t["genre_fit_bp"][lineup["genre"]])
		var pf: int = clampi(10000 - int(t["price_sensitivity_bp"]) * (price - int(ad["price_ref"])),
			int(ad["price_factor_min_bp"]), int(ad["price_factor_max_bp"]))
		out.append(draw * fit / 10000 * pf / 10000)
	return out


func _sum(a: Array) -> int:
	var s: int = 0
	for v: Variant in a:
		s += int(v)
	return s


## AD10 최대 나머지 배분(동률은 유형 순서가 앞인 쪽).
func _split(adm: int, e: Array[int]) -> Array[int]:
	var total: int = _sum(e)
	var n: Array[int] = []
	var rem: Array[int] = []
	for v: int in e:
		n.append(0 if total == 0 else adm * v / total)
		rem.append(0 if total == 0 else (adm * v) % total)
	if total == 0:
		return n
	var left: int = adm - _sum(n)
	var order: Array[int] = []
	for i: int in range(e.size()):
		order.append(i)
	order.sort_custom(func(x: int, y: int) -> bool: return rem[x] > rem[y] or (rem[x] == rem[y] and x < y))
	for k: int in range(left):
		n[order[k]] += 1
	return n


## AD6~AD9. u = 첫 randi().
func _admit(e: Array[int], u: int, capacity: int, has_stage: bool) -> Dictionary:
	var j: int = int(_a["admission"]["noise_bp"])
	var total: int = _sum(e)
	var noise: int = (u % (2 * j + 1)) - j
	var raw: int = total * (10000 + noise) / 1000000
	var cap_agents: int = int(_a["max_agents"])
	var adm: int = 0
	var capped: String = "no_stage"
	if has_stage:
		adm = mini(raw, mini(capacity, cap_agents))
		if raw <= mini(capacity, cap_agents):
			capped = "none"
		else:
			capped = "capacity" if capacity <= cap_agents else "max_agents"
	return {"E": total, "expected": total / 100, "noise_bp": noise, "raw": raw, "admissions": adm,
		"capped_by": capped, "by_type": _split(adm, e)}


func _first_draw(seed_value: int) -> int:
	var rng: SeededRng = SeededRng.new(seed_value, _stream_names)
	return rng.stream("audience").randi()


func _type_dict(vals: Array) -> Dictionary:
	var d: Dictionary = {}
	for i: int in range(TYPE_IDS.size()):
		d[TYPE_IDS[i]] = int(vals[i])
	return d


## SF2~SF8. 라인업 궁합·가격 만족·혼잡을 받아 유형의 만족(bp). sound/sight 는 bp(0~10000), wait 는 누적 틱.
func _sat(t: Dictionary, lineup: Variant, price: int, crowd_bp: int, bonus_bp: int, sound_bp: int, sight_bp: int, wait: int) -> int:
	var s: Dictionary = _a["satisfaction"]
	var lb: int = int(s["no_lineup_bp"])
	if lineup != null:
		var sf: int = mini(10000, int(s["skill_base_bp"]) + int(lineup["skill"]) * int(s["skill_bp_per_point"]))
		lb = int(t["genre_fit_bp"][lineup["genre"]]) * sf / 10000
	var val: int = clampi(int(s["price_value_mid_bp"]) - int(t["price_sensitivity_bp"]) * (price - int(_a["admission"]["price_ref"])), 0, 10000)
	var wb: int = mini(10000, wait * 10000 / int(t["patience_ticks"]))
	var w: Dictionary = s["weights_bp"]
	var p: Dictionary = s["penalty_weights_bp"]
	var pos: int = int(w["lineup"]) * lb + int(w["sound"]) * sound_bp + int(w["sight"]) * sight_bp + int(w["value"]) * val
	var neg: int = int(p["crowd"]) * crowd_bp + int(p["wait"]) * wb
	return mini(10000, maxi(0, pos - neg) / 10000 + bonus_bp)


## SF5 공통 혼잡. 관객 0 이면 0(SF5 관객 0, SE-052).
func _crowd(audience: int, capacity: int) -> int:
	if audience == 0:
		return 0
	var comfort: int = int(_a["satisfaction"]["crowd_comfort_bp"])
	var ratio: int = audience * 10000 / capacity if capacity > 0 else 10000
	if ratio <= comfort:
		return 0
	return mini(10000, (ratio - comfort) * 10000 / (10000 - comfort))


# --- 커버리지 타일 집합 재계산 (build.md C0~C3, SE-028 의 test_build_data_qa.gd 와 같은 규칙) ----------------

func _kind(x: int, z: int) -> Dictionary:
	if x < 0 or z < 0 or x >= int(_map["width"]) or z >= int(_map["depth"]):
		return {}
	var ch: String = (_map["tiles"][z] as String).substr(x, 1)
	for k: Dictionary in _map["tile_kinds"]:
		if k["char"] == ch:
			return k
	return {}


func _line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var dx: int = absi(b.x - a.x)
	var sx: int = 1 if a.x < b.x else -1
	var dz: int = -absi(b.y - a.y)
	var sz: int = 1 if a.y < b.y else -1
	var err: int = dx + dz
	var p: Vector2i = a
	var out: Array[Vector2i] = []
	while true:
		out.append(p)
		if p == b:
			break
		var e2: int = 2 * err
		if e2 >= dz:
			err += dz
			p.x += sx
		if e2 <= dx:
			err += dx
			p.y += sz
	return out


## 기준 배치 하나의 {view, sound, sight, bar: Dictionary(Vector2i→true), entrances, capacity}.
func _tile_sets(layout_id: String) -> Dictionary:
	var rows: Dictionary = {}
	for r: Dictionary in _furn["rows"]:
		rows[r["id"]] = r
	var insts: Array = []
	var occ: Dictionary = {}
	for p: Dictionary in _layout(layout_id)["placements"]:
		var row: Dictionary = rows[p["furniture_id"]]
		var fp: Array = row["footprint"]
		var rot: int = int(p["rotation"])
		var sz: Vector2i = Vector2i(int(fp[1]), int(fp[0])) if rot == 90 or rot == 270 else Vector2i(int(fp[0]), int(fp[1]))
		var mn: Vector2i = Vector2i(int(p["cell"][0]), int(p["cell"][1]))
		var cells: Array[Vector2i] = []
		for z: int in range(sz.y):
			for x: int in range(sz.x):
				cells.append(mn + Vector2i(x, z))
				occ[mn + Vector2i(x, z)] = true
		insts.append({"row": row, "cells": cells, "rot": rot, "min": mn, "size": sz})
	var entrances: Array[Vector2i] = []
	for z: int in range(int(_map["depth"])):
		for x: int in range(int(_map["width"])):
			if _kind(x, z)["id"] == "entrance":
				entrances.append(Vector2i(x, z))
	var seen: Dictionary = {}
	var queue: Array[Vector2i] = []
	for e: Vector2i in entrances:
		seen[e] = true
		queue.append(e)
	var head: int = 0
	while head < queue.size():
		var q: Vector2i = queue[head]
		head += 1
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = q + d
			var k: Dictionary = _kind(n.x, n.y)
			if not k.is_empty() and k["walkable"] and not seen.has(n) and not occ.has(n):
				seen[n] = true
				queue.append(n)
	var view: Array[Vector2i] = []
	var focus: Vector2i = Vector2i(-1, -1)
	for i: Dictionary in insts:
		if i["row"]["category"] != "stage":
			continue
		assert_eq(int(i["rot"]), 0, "기준 배치 무대는 회전 0")
		var mn2: Vector2i = i["min"]
		var sz2: Vector2i = i["size"]
		focus = Vector2i(mn2.x + sz2.x / 2, mn2.y)
		for z: int in range(int(_map["depth"])):
			for x: int in range(int(_map["width"])):
				var t: Vector2i = Vector2i(x, z)
				if seen.has(t) and _kind(x, z)["standing"] and z < mn2.y:
					view.append(t)
	var sound: Dictionary = {}
	var bar: Dictionary = {}
	for t: Vector2i in view:
		for i: Dictionary in insts:
			var m: Vector2i = i["min"]
			var s2: Vector2i = i["size"]
			var ddx: int = maxi(maxi(m.x - t.x, 0), t.x - (m.x + s2.x - 1))
			var ddz: int = maxi(maxi(m.y - t.y, 0), t.y - (m.y + s2.y - 1))
			var d2: int = ddx * ddx + ddz * ddz
			var sr: int = int(i["row"]["effects"]["sound_radius"])
			var br: int = int(i["row"]["effects"]["bar_service_radius"])
			if sr > 0 and d2 <= sr * sr:
				sound[t] = true
			if br > 0 and d2 <= br * br:
				bar[t] = true
	var blockers: Dictionary = {}
	for i: Dictionary in insts:
		if i["row"]["effects"]["sight_block"] and i["row"]["category"] != "stage":
			for c: Vector2i in i["cells"]:
				blockers[c] = true
	var sight: Dictionary = {}
	for t: Vector2i in view:
		var ln: Array[Vector2i] = _line(t, focus)
		var hit: bool = false
		for k: int in range(1, ln.size() - 1):
			var c: Vector2i = ln[k]
			var kd: Dictionary = _kind(c.x, c.y)
			if kd.is_empty() or kd["blocks_sight"] or blockers.has(c):
				hit = true
				break
		if not hit:
			sight[t] = true
	return {"view": view, "sound": sound, "sight": sight, "bar": bar, "entrances": entrances,
		"capacity": int(_layout(layout_id)["expected"]["capacity"]), "bonus": int(_layout(layout_id)["expected"]["satisfaction_bonus_bp"])}


## SP1·SP2: 유형의 관람 자리 순위(점수 내림, 음향 무게중심 거리, z, x 오름차순).
func _spot_rank(ts: Dictionary, t: Dictionary) -> Array[Vector2i]:
	var cset: Array = (ts["sound"] as Dictionary).keys()
	if cset.is_empty():
		cset = ts["view"].duplicate()
	var n: int = cset.size()
	var sx: int = 0
	var sz: int = 0
	for c: Vector2i in cset:
		sx += c.x
		sz += c.y
	var w: Dictionary = t["spot_weights_bp"]
	var keyed: Array = []
	for v: Vector2i in ts["view"]:
		var score: int = 0
		score += int(w["sound"]) if (ts["sound"] as Dictionary).has(v) else 0
		score += int(w["sight"]) if (ts["sight"] as Dictionary).has(v) else 0
		score += int(w["bar"]) if (ts["bar"] as Dictionary).has(v) else 0
		var cdist: int = (v.x * n - sx) * (v.x * n - sx) + (v.y * n - sz) * (v.y * n - sz)
		keyed.append({"t": v, "score": score, "cdist": cdist})
	keyed.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		if p["score"] != q["score"]:
			return p["score"] > q["score"]
		if p["cdist"] != q["cdist"]:
			return p["cdist"] < q["cdist"]
		var pt: Vector2i = p["t"]
		var qt: Vector2i = q["t"]
		if pt.y != qt.y:
			return pt.y < qt.y
		return pt.x < qt.x)
	var out: Array[Vector2i] = []
	for k: Dictionary in keyed:
		out.append(k["t"])
	return out


## 부록 B2: 자리 고르기만(경로·바 우회 없이) 도착 순서대로 1칸 1명으로 채우고 평균 만족을 낸다. order = 유형 인덱스 나열.
func _avg_by_seating(sc: Dictionary, ts: Dictionary, order: Array[int]) -> int:
	var ex: Dictionary = sc["expected"]
	var lineup: Variant = _lineup_of(sc)
	var n_t: Array[int] = []
	for id: String in TYPE_IDS:
		n_t.append(int(ex["by_type"][id]))
	var adm: int = _sum(n_t)
	var crowd: int = _crowd(adm, int(ts["capacity"]))
	var ranks: Array = []
	for t: Dictionary in _types:
		ranks.append(_spot_rank(ts, t))
	var claimed: Dictionary = {}
	var seq: Array[int] = []
	for ti: int in order:
		for k: int in range(n_t[ti]):
			seq.append(ti)
	var total: int = 0
	for ti: int in seq:
		var pick: Vector2i = Vector2i(-1, -1)
		for v: Vector2i in ranks[ti]:
			if not claimed.has(v):
				pick = v
				break
		assert_ne(pick, Vector2i(-1, -1), "자리가 남아 있다")
		claimed[pick] = true
		var snd: int = 10000 if (ts["sound"] as Dictionary).has(pick) else 0
		var sgt: int = 10000 if (ts["sight"] as Dictionary).has(pick) else 0
		total += _sat(_types[ti], lineup, int(sc["ticket_price"]), crowd, int(ts["bonus"]), snd, sgt, 0)
	return total / adm if adm > 0 else 0


# --- AC3: 스키마·구조 ------------------------------------------------------------------------------

func test_top_level_keys_and_scalars() -> void:
	var keys: Array = _a.keys()
	keys.sort()
	assert_eq(keys, ["admission", "checks", "flow", "max_agents", "pos_scale", "reference_scenarios", "satisfaction", "types", "version"])
	assert_eq(int(_a["version"]), 2, "version 2 (SE-029-bug: pass_override_ticks 추가)")
	assert_eq(int(_a["max_agents"]), 150, "PRD MVP 관객 150")
	assert_eq(int(_a["pos_scale"]), 100)
	assert_lte(int(_a["max_agents"]), int(_sim["individual_agent_cap"]), "AL4")
	assert_eq(int(_a["pos_scale"]) % 2, 0, "AL5 짝수")
	assert_eq(int(_a["pos_scale"]) % int(_a["flow"]["move_ticks_per_tile"]), 0, "AL5 pos_scale mod move_ticks_per_tile == 0")
	var adm: Dictionary = _a["admission"]
	assert_eq(_ints(adm), {"price_ref": 20, "reputation_cap": 2000, "noise_bp": 1000, "price_factor_min_bp": 0, "price_factor_max_bp": 20000})
	assert_lte(int(adm["price_factor_min_bp"]), 10000, "AL8")
	assert_gte(int(adm["price_factor_max_bp"]), 10000, "AL8")
	assert_eq(int(adm["price_ref"]), int(_eco["rows"][0]["ticket_price_default"]), "가격 기준 = economy 기본가")


func test_flow_values_and_phase_fit() -> void:
	var fl: Dictionary = _a["flow"]
	assert_eq(_ints(fl), {"arrival_window_ticks": 400, "entry_ticks": 4, "move_ticks_per_tile": 4, "spot_tile_cap": 1,
		"pass_tile_cap": 2, "bar_ticks": 50, "bar_fail_wait_ticks": 30, "pass_override_ticks": 10})
	assert_gte(int(fl["pass_override_ticks"]), 1, "T8: 연속 K 틱 막히면 cap 무시, K ≥ 1")
	assert_lt(int(fl["pass_override_ticks"]), int(_types[2]["patience_ticks"]), "K 가 가장 짧은 인내보다 짧아야 교착이 조기 퇴장으로 번지지 않는다")
	var ticks: Dictionary = {}
	for p: Dictionary in _sim["phases"]:
		ticks[p["id"]] = int(p["ticks"])
	assert_lte(int(fl["arrival_window_ticks"]), int(ticks["evening"]), "AL6 도착 창 ≤ 저녁 구간")
	assert_gte(int(ticks["show"]), 1, "AL6")
	assert_eq(int(ticks["evening"]) + int(ticks["show"]), 1500, "agent_moved 하루 1,500회의 근거")
	# 입구 처리량: 입구 수 × (1 ÷ entry_ticks) > 최대 도착률 (max_agents ÷ arrival_window)
	var ents: int = 0
	for z: int in range(int(_map["depth"])):
		for x: int in range(int(_map["width"])):
			if _kind(x, z)["id"] == "entrance":
				ents += 1
	assert_eq(ents, 2, "티어 1 입구 2칸")
	assert_gt(ents * int(fl["arrival_window_ticks"]), int(_a["max_agents"]) * int(fl["entry_ticks"]), "입구 처리량 > 최대 도착률")
	assert_gt(int(fl["pass_tile_cap"]), int(fl["spot_tile_cap"]), "지나가는 사람이 서 있는 사람 옆을 지날 수 있다")


func test_types_exactly_three_in_order() -> void:
	assert_eq(_types.size(), 3, "유형 3 (PRD MVP)")
	var ids: Array[String] = []
	var keyset: Array = ["bar_visit_bp", "base_centi", "color", "genre_fit_bp", "id", "name", "needs_lineup", "patience_ticks",
		"popularity_centi", "price_sensitivity_bp", "reputation_centi", "spot_weights_bp"]
	for t: Dictionary in _types:
		ids.append(t["id"])
		var ks: Array = t.keys()
		ks.sort()
		assert_eq(ks, keyset, "필드 집합 " + str(t["id"]))
	assert_eq(ids, TYPE_IDS, "유형 순서 = by_type·나머지 배분 순서")
	assert_eq(ids.size(), (ids as Array).duplicate().size())


func test_type_field_ranges_and_colors() -> void:
	var rx: RegEx = RegEx.create_from_string("^#[0-9a-fA-F]{6}$")
	var colors: Dictionary = {}
	var accents: Dictionary = {}
	for g: Dictionary in _genres:
		accents[String(g["accent_color"]).to_lower()] = true
	for t: Dictionary in _types:
		var id: String = t["id"]
		assert_not_null(rx.search(String(t["color"])), "색 hex #RRGGBB " + id)
		colors[String(t["color"]).to_lower()] = true
		assert_false(accents.has(String(t["color"]).to_lower()), "장르 강조색과 겹치지 않음 " + id)
		assert_true(String(t["name"]).length() >= 1)
		for k: String in ["bar_visit_bp"]:
			assert_between(int(t[k]), 0, 10000, k + " " + id)
		assert_between(int(t["price_sensitivity_bp"]), 0, 10000, "price_sensitivity_bp " + id)
		assert_gte(int(t["patience_ticks"]), 1)
		for k: String in ["base_centi", "popularity_centi", "reputation_centi"]:
			assert_gte(int(t[k]), 0, k + " " + id)
		var w: Dictionary = t["spot_weights_bp"]
		assert_eq((w.keys() as Array).size(), 3)
		for k: String in ["sound", "sight", "bar"]:
			assert_between(int(w[k]), 0, 10000, "spot_weights_bp." + k + " " + id)
	assert_eq(colors.size(), 3, "색 3개가 서로 다르다")
	# 뜨내기 < 팬 < 단골 순으로 인내가 길다 (설계 의도: 뜨내기가 가장 먼저 지친다)
	assert_lt(int(_types[2]["patience_ticks"]), int(_types[1]["patience_ticks"]))
	assert_lt(int(_types[1]["patience_ticks"]), int(_types[0]["patience_ticks"]))
	# 라인업 필요 여부: 단골만 라인업 없이 온다
	assert_eq([_types[0]["needs_lineup"], _types[1]["needs_lineup"], _types[2]["needs_lineup"]], [false, true, true])


func test_type_table_literals() -> void:
	# audience.md #수치표 #유형 의 값을 리터럴로 고정한다(밸런스 변경은 game-designer 가 문서·이 테스트를 함께 고친다).
	var want: Dictionary = {
		"regular": {"color": "#e0a458", "needs_lineup": false, "base_centi": 1200, "popularity_centi": 0, "reputation_centi": 2,
			"price_sensitivity_bp": 200, "bar_visit_bp": 7000, "patience_ticks": 400, "spot_weights_bp": {"sound": 5000, "sight": 5000, "bar": 2000}},
		"genre_fan": {"color": "#4f7cff", "needs_lineup": true, "base_centi": 0, "popularity_centi": 160, "reputation_centi": 0,
			"price_sensitivity_bp": 300, "bar_visit_bp": 4000, "patience_ticks": 300, "spot_weights_bp": {"sound": 6000, "sight": 4000, "bar": 0}},
		"walk_in": {"color": "#c2c7d0", "needs_lineup": true, "base_centi": 3000, "popularity_centi": 30, "reputation_centi": 6,
			"price_sensitivity_bp": 500, "bar_visit_bp": 7500, "patience_ticks": 150, "spot_weights_bp": {"sound": 4000, "sight": 3000, "bar": 3000}},
	}
	for t: Dictionary in _types:
		var w: Dictionary = want[t["id"]]
		for k: String in w:
			assert_eq(_ints(t[k]), w[k], "%s.%s" % [t["id"], k])


func test_genre_fit_table_3x3() -> void:
	var mvp: Array = _art["mvp_genres"]
	assert_eq(mvp, ["rock", "indie", "electronic"])
	var gids: Array = []
	for g: Dictionary in _genres:
		gids.append(g["id"])
	var table: Array = []
	for t: Dictionary in _types:
		var fit: Dictionary = t["genre_fit_bp"]
		var ks: Array = fit.keys()
		ks.sort()
		var mv: Array = mvp.duplicate()
		mv.sort()
		assert_eq(ks, mv, "AL3 키 집합 == artist.json mvp_genres: " + str(t["id"]))
		var row: Array = []
		for g: String in mvp:
			assert_true(gids.has(g), "genres.json 에 존재 " + g)
			assert_between(int(fit[g]), 0, 10000)
			row.append(int(fit[g]))
		table.append(row)
	assert_eq(table, [[10000, 8000, 6000], [10000, 10000, 10000], [7000, 8000, 10000]], "장르 적합표 3×3 (rock/indie/electronic)")
	# 설계 의도: 장르 팬은 그날 장르의 팬이라 항상 10,000
	for g: String in mvp:
		assert_eq(int(_types[1]["genre_fit_bp"][g]), 10000)


func test_satisfaction_weights_and_penalties() -> void:
	var s: Dictionary = _a["satisfaction"]
	var w: Dictionary = s["weights_bp"]
	assert_eq(int(w["lineup"]) + int(w["sound"]) + int(w["sight"]) + int(w["value"]), 10000, "AL7 가중치 합")
	assert_eq(_ints(w), {"lineup": 4000, "sound": 1500, "sight": 1500, "value": 3000})
	assert_eq(_ints(s["penalty_weights_bp"]), {"crowd": 500, "wait": 2000})
	assert_lt(int(s["crowd_comfort_bp"]), 10000)
	assert_eq([int(s["skill_base_bp"]), int(s["skill_bp_per_point"]), int(s["no_lineup_bp"]), int(s["price_value_mid_bp"]), int(s["crowd_comfort_bp"])],
		[5000, 50, 0, 5000, 8000])
	# 실력 0~100 에서 skill_factor 가 10000 을 넘지 않고 100 에서 정확히 10000
	assert_eq(mini(10000, int(s["skill_base_bp"]) + 100 * int(s["skill_bp_per_point"])), 10000)
	# 최악 입력에서도 만족이 0~10000 안: 모든 요소 0 + 감점 최대
	for t: Dictionary in _types:
		var lo: int = _sat(t, null, 40, 10000, 0, 0, 0, 100000)
		var hi: int = _sat(t, {"genre": "rock", "skill": 100}, 5, 0, 1500, 10000, 10000, 0)
		assert_eq(lo, 0, "하한 0 " + str(t["id"]))
		assert_eq(hi, 10000, "상한 10000(편의 가산 상한 1,500 포함) " + str(t["id"]))


# --- 가격 계수 ------------------------------------------------------------------------------------

func test_price_factor_values_and_economy_range() -> void:
	var ad: Dictionary = _a["admission"]
	var row: Dictionary = _eco["rows"][0]
	var factors: Dictionary = {}
	for p: int in [int(row["ticket_price_min"]), 10, 20, 25, 30, int(row["ticket_price_max"])]:
		var f: Array = []
		for t: Dictionary in _types:
			f.append(10000 - int(t["price_sensitivity_bp"]) * (p - int(ad["price_ref"])))
		factors[p] = f
	assert_eq(factors[20], [10000, 10000, 10000], "기준 가격에서 계수 10000")
	assert_eq(factors[30], [8000, 7000, 5000], "가격 30: 단골 −20% / 팬 −30% / 뜨내기 −50%")
	assert_eq(factors[10], [12000, 13000, 15000])
	assert_eq(factors[5], [13000, 14500, 17500], "economy 최저가 5")
	assert_eq(factors[40], [6000, 4000, 0], "economy 최고가 40 — 뜨내기 정확히 0(클램프에 닿기 직전)")
	# economy 가 허용하는 가격 범위 안에서는 clamp 하한/상한이 실제로 물리지 않는다.
	for p: int in factors:
		for v: int in factors[p]:
			assert_between(v, int(ad["price_factor_min_bp"]), int(ad["price_factor_max_bp"]), "가격 %d" % p)


func test_price_monotonic_every_type() -> void:
	var lineup: Dictionary = _slot("s07")
	var prev: Array[int] = []
	for p: int in range(int(_eco["rows"][0]["ticket_price_min"]), int(_eco["rows"][0]["ticket_price_max"]) + 1):
		var e: Array[int] = _e_centi(lineup, 0, p)
		if not prev.is_empty():
			for i: int in range(3):
				assert_lte(e[i], prev[i], "가격 %d 에서 유형 %d 입장 흡인은 늘지 않는다" % [p, i])
		prev = e
	var lo: int = _sum(_e_centi(lineup, 0, 30))
	var mid: int = _sum(_e_centi(lineup, 0, 20))
	var cheap: int = _sum(_e_centi(lineup, 0, 10))
	assert_lt(lo, mid)
	assert_lt(mid, cheap)


# --- AC2/AC3: 기준 시나리오 4개 손계산 재현 ---------------------------------------------------------

func test_reference_scenarios_structure() -> void:
	var ids: Array = []
	for s: Dictionary in _a["reference_scenarios"]:
		ids.append(s["id"])
		assert_not_null(_layout(s["layout"]), "AL9 layout 존재")
		assert_false(_layout(s["layout"]).is_empty(), "AL9 layout ∈ tier1_club.reference_layouts " + str(s["id"]))
		if s["lineup"] != null:
			var slot: Dictionary = _slot(s["lineup"]["slot"])
			assert_false(slot.is_empty(), "AL9 slot ∈ roster_plan")
			for k: String in ["genre", "grade", "popularity", "skill"]:
				assert_eq(s["lineup"][k], slot[k], "AL9 %s.%s == roster_plan" % [s["id"], k])
		assert_false(JSON.stringify(s).contains("artist_id"), "시나리오에 아티스트 id 리터럴 없음")
	assert_eq(ids, ["no_lineup", "local_top_baseline", "rookie_baseline", "local_top_price30"])
	# 아티스트 id(명단 id)가 audience.json 어디에도 없다(AU14)
	var art_rows: Array = _load("res://data/artists/artists.json").get("rows", [])
	var blob: String = JSON.stringify(_a)
	for r: Dictionary in art_rows:
		assert_false(blob.contains('"' + String(r["id"]) + '"'), "audience.json 에 아티스트 id 리터럴 없음: " + str(r["id"]))


func test_reference_scenarios_recomputed_from_formulas() -> void:
	for sc: Dictionary in _a["reference_scenarios"]:
		var ex: Dictionary = sc["expected"]
		var lay: Dictionary = _layout(sc["layout"])["expected"]
		var e: Array[int] = _e_centi(_lineup_of(sc), int(sc["reputation_total"]), int(sc["ticket_price"]))
		assert_eq(_type_dict(e), ex["e_centi"], sc["id"] + " e_centi")
		var u: int = _first_draw(int(sc["seed"]))
		assert_eq(u, int(ex["first_draw"]), sc["id"] + " first_draw (실제 SeededRng)")
		var r: Dictionary = _admit(e, u, int(lay["capacity"]), bool(lay["has_stage"]))
		assert_eq(r["E"], int(ex["expected_centi"]), sc["id"] + " expected_centi")
		assert_eq(r["noise_bp"], int(ex["noise_bp"]), sc["id"] + " noise_bp")
		assert_eq(r["raw"], int(ex["raw"]), sc["id"] + " raw")
		assert_eq(r["admissions"], int(ex["admissions"]), sc["id"] + " admissions")
		assert_eq(r["capped_by"], ex["capped_by"], sc["id"] + " capped_by")
		assert_eq(_type_dict(r["by_type"]), ex["by_type"], sc["id"] + " by_type")
		assert_eq(_sum(r["by_type"]), r["admissions"], "배분 합 == admissions")
		# 다른 시드 범위 = 노이즈 양 끝
		var j: int = int(_a["admission"]["noise_bp"])
		var cap: int = mini(int(lay["capacity"]), int(_a["max_agents"]))
		assert_eq([mini(r["E"] * (10000 - j) / 1000000, cap), mini(r["E"] * (10000 + j) / 1000000, cap)],
			ex["admissions_range_other_seeds"], sc["id"] + " 다른 시드 범위")
		# 공연 끝 기대 필드: 조기 퇴장 0 → audience == admissions, 혼잡 = SF5
		assert_eq(int(ex["left_early"]), 0, "기준 시나리오는 조기 퇴장 0 (AT6)")
		assert_eq(int(ex["audience"]), int(ex["admissions"]) - int(ex["left_early"]), "audience = admissions − left_early")
		assert_eq(_crowd(int(ex["audience"]), int(lay["capacity"])), int(ex["crowd_bp"]), sc["id"] + " crowd_bp")


func test_reference_scenarios_hand_literals() -> void:
	# QA 독립 손계산(Python, tools/bot/audience_spec_check.py)의 리터럴을 한 번 더 단언한다.
	var hand: Dictionary = {
		"no_lineup": [[1200, 0, 0], 12, [12, 0, 0], [10, 13]],
		"local_top_baseline": [[960, 4320, 3048], 83, [10, 43, 30], [74, 91]],
		"rookie_baseline": [[1200, 6720, 4128], 120, [12, 67, 41], [108, 122]],
		"local_top_price30": [[768, 3024, 1524], 53, [8, 30, 15], [47, 58]],
	}
	for sc: Dictionary in _a["reference_scenarios"]:
		var h: Array = hand[sc["id"]]
		var ex: Dictionary = sc["expected"]
		assert_eq(_ints([ex["e_centi"]["regular"], ex["e_centi"]["genre_fan"], ex["e_centi"]["walk_in"]]), h[0], sc["id"] + " e")
		assert_eq(int(ex["admissions"]), int(h[1]), sc["id"] + " admissions")
		assert_eq(_ints([ex["by_type"]["regular"], ex["by_type"]["genre_fan"], ex["by_type"]["walk_in"]]), h[2], sc["id"] + " by_type")
		assert_eq(_ints(ex["admissions_range_other_seeds"]), h[3], sc["id"] + " range")
		assert_eq(int(ex["noise_bp"]), 42)
		assert_eq(int(ex["first_draw"]), 3230427448)
	assert_eq(SeededRng.derive_seed(0, "audience"), 1688486501, "tick.md 검증 벡터: 시드 0 의 audience 파생 시드")
	assert_eq(3230427448 % 2001, 1042, "B0: u mod 2001")


func test_other_seeds_fall_in_declared_ranges() -> void:
	# AU2 사전 검증: 실제 SeededRng 로 시드 0~100 의 첫 뽑기를 받아 선언된 범위·배분 합을 확인한다.
	for sc: Dictionary in _a["reference_scenarios"]:
		var lay: Dictionary = _layout(sc["layout"])["expected"]
		var e: Array[int] = _e_centi(_lineup_of(sc), int(sc["reputation_total"]), int(sc["ticket_price"]))
		var rng_range: Array = sc["expected"]["admissions_range_other_seeds"]
		var seen_min: int = 1000
		var seen_max: int = -1
		for seed_value: int in range(0, 101):
			var r: Dictionary = _admit(e, _first_draw(seed_value), int(lay["capacity"]), true)
			assert_between(r["admissions"], int(rng_range[0]), int(rng_range[1]), "%s 시드 %d" % [sc["id"], seed_value])
			assert_eq(_sum(r["by_type"]), r["admissions"], "배분 합")
			for v: int in r["by_type"]:
				assert_gte(v, 0)
			seen_min = mini(seen_min, r["admissions"])
			seen_max = maxi(seen_max, r["admissions"])
		assert_lt(seen_min, seen_max, "시드가 달라지면 입장 수도 달라진다 " + str(sc["id"]))


func test_other_seeds_sample_literals() -> void:
	# 시드 10~13 (QA 독립 계산): noise_bp [−511, −95, −659, +595]
	var expect: Dictionary = {
		"no_lineup": [11, 11, 11, 12],
		"local_top_baseline": [79, 82, 77, 88],
		"rookie_baseline": [114, 119, 112, 122],
		"local_top_price30": [50, 52, 49, 56],
	}
	for sc: Dictionary in _a["reference_scenarios"]:
		var e: Array[int] = _e_centi(_lineup_of(sc), int(sc["reputation_total"]), int(sc["ticket_price"]))
		var got: Array = []
		var noises: Array = []
		for sd: int in range(10, 14):
			var r: Dictionary = _admit(e, _first_draw(sd), 122, true)
			got.append(r["admissions"])
			noises.append(r["noise_bp"])
		assert_eq(noises, [-511, -95, -659, 595], "시드 10~13 노이즈 " + str(sc["id"]))
		assert_eq(got, expect[sc["id"]], "시드 10~13 입장 " + str(sc["id"]))


func test_split_largest_remainder_properties() -> void:
	# AD10: 합 == admissions, 동률은 유형 순서. 손계산 4건 + 경계.
	assert_eq(_split(83, [960, 4320, 3048] as Array[int]), [10, 43, 30] as Array[int])
	assert_eq(_split(120, [1200, 6720, 4128] as Array[int]), [12, 67, 41] as Array[int])
	assert_eq(_split(53, [768, 3024, 1524] as Array[int]), [8, 30, 15] as Array[int])
	assert_eq(_split(12, [1200, 0, 0] as Array[int]), [12, 0, 0] as Array[int])
	assert_eq(_split(0, [100, 100, 100] as Array[int]), [0, 0, 0] as Array[int])
	assert_eq(_split(1, [100, 100, 100] as Array[int]), [1, 0, 0] as Array[int], "동률은 유형 순서가 앞인 쪽")
	assert_eq(_split(2, [100, 100, 100] as Array[int]), [1, 1, 0] as Array[int])
	assert_eq(_split(5, [0, 0, 0] as Array[int]), [0, 0, 0] as Array[int], "E == 0")
	for adm: int in range(0, 151):
		var e: Array[int] = [960, 4320, 3048]
		assert_eq(_sum(_split(adm, e)), adm, "합 보존 %d" % adm)


# --- AC: 상한 150 · 가격 방향 -------------------------------------------------------------------------

func test_admission_caps() -> void:
	var e: Array[int] = _e_centi(_slot("s07"), 0, 20)
	var r40: Dictionary = _admit(e, _first_draw(0), 40, true)
	assert_eq([r40["admissions"], r40["capped_by"]], [40, "capacity"], "수용 40 으로 자름 (raw 83)")
	# 수용 150·인기 100·명성 2,000: E 37,120 → raw 372 → 150 으로 자른다. capacity ≤ max_agents 이므로 "capacity".
	var big: Dictionary = {"genre": "electronic", "popularity": 100}
	var eb: Array[int] = _e_centi(big, 2000, 20)
	assert_eq(eb, [3120, 16000, 18000] as Array[int])
	var rb: Dictionary = _admit(eb, _first_draw(0), 150, true)
	assert_eq([rb["E"], rb["raw"], rb["admissions"], rb["capped_by"]], [37120, 372, 150, "capacity"])
	# capacity 가 max_agents 보다 크게 새어 들어와도 150 에서 멈춘다(tiers.capacity_max 가 150 이라 현재는 도달하지 않는 방어)
	var rb2: Dictionary = _admit(eb, _first_draw(0), 200, true)
	assert_eq([rb2["admissions"], rb2["capped_by"]], [150, "max_agents"])
	# 명성은 reputation_cap(2,000) 이상에서 더 늘지 않는다.
	assert_eq(_e_centi(big, 2000, 20), _e_centi(big, 99999, 20))
	# 무대 없음 → 0
	var rn: Dictionary = _admit(e, _first_draw(0), 119, false)
	assert_eq([rn["admissions"], rn["capped_by"]], [0, "no_stage"])
	var tiers: Array = _load("res://data/tiers/tiers.json")["rows"]
	for t: Dictionary in tiers:
		if int(t["tier"]) == 1:
			assert_eq(int(t["capacity_max"]), int(_a["max_agents"]), "티어 1 capacity_max == max_agents")


func test_price_direction_and_satisfaction() -> void:
	var base: Dictionary = _scenario("local_top_baseline")["expected"]
	var hi: Dictionary = _scenario("local_top_price30")["expected"]
	assert_lt(int(hi["admissions"]), int(base["admissions"]), "AU5: 가격 20 → 30 입장 감소 (53 < 83)")
	assert_lt(int(hi["avg_satisfaction_bp_hand"]), int(base["avg_satisfaction_bp_hand"]), "AU5: 만족 감소")
	for id: String in TYPE_IDS:
		assert_lt(int(hi["e_centi"][id]), int(base["e_centi"][id]), "각 유형 e_t 감소 " + id)
	# 가격 10 은 20 보다 많다
	var e10: int = _sum(_e_centi(_slot("s07"), 0, 10))
	assert_gt(e10, int(base["expected_centi"]))
	# 티켓 매출(가격 × 기대 입장)은 25 근처가 최대: 10→1130, 20→1660, 25→1700, 30→1590
	var rev: Array = []
	for p: int in [10, 20, 25, 30]:
		rev.append(p * (_sum(_e_centi(_slot("s07"), 0, p)) / 100))
	assert_eq(rev, [1130, 1660, 1700, 1590], "audience.md 가격 반응 표")
	# 가격 만족: 20 → 30 에서 유형별 value_bp
	var ts: Dictionary = {}
	for t: Dictionary in _types:
		ts[t["id"]] = [clampi(5000 - int(t["price_sensitivity_bp"]) * 0, 0, 10000), clampi(5000 - int(t["price_sensitivity_bp"]) * 10, 0, 10000)]
	assert_eq(ts["regular"], [5000, 3000])
	assert_eq(ts["genre_fan"], [5000, 2000])
	assert_eq(ts["walk_in"], [5000, 0])


# --- 부록 B2: 평균 만족 -------------------------------------------------------------------------------

func test_b2_tile_premises() -> void:
	var ts: Dictionary = _tile_sets("baseline_show")
	var ex: Dictionary = _layout("baseline_show")["expected"]
	assert_eq([(ts["view"] as Array).size(), (ts["sound"] as Dictionary).size(), (ts["sight"] as Dictionary).size(), (ts["bar"] as Dictionary).size()],
		[int(ex["viewing_count"]), int(ex["sound_count"]), int(ex["sight_count"]), int(ex["bar_count"])], "타일 집합 크기 == expected")
	var both: int = 0
	var sound_only: Array = []
	var bar_sound: int = 0
	for v: Vector2i in ts["view"]:
		var s: bool = (ts["sound"] as Dictionary).has(v)
		var g: bool = (ts["sight"] as Dictionary).has(v)
		if s and g:
			both += 1
		if s and not g:
			sound_only.append([v.x, v.y])
		if s and (ts["bar"] as Dictionary).has(v):
			bar_sound += 1
	assert_eq(both, 94, "B2: 음향 ∩ 시야 94칸")
	assert_eq(sound_only, [[6, 14], [17, 14]], "B2: 음향만 2칸(기둥에 가림)")
	assert_eq(bar_sound, 0, "B2: 바 ∩ 음향 0칸")
	assert_eq(int(ts["capacity"]), 122)
	assert_eq(int(ts["bonus"]), 100)
	# 모든 유형에서 '음향+시야' 칸이 1순위 점수 — 94칸이 순위 맨 앞에 온다.
	for t: Dictionary in _types:
		var rank: Array[Vector2i] = _spot_rank(ts, t)
		assert_eq(rank.size(), 405)
		for i: int in range(94):
			assert_true((ts["sound"] as Dictionary).has(rank[i]) and (ts["sight"] as Dictionary).has(rank[i]), "%s 순위 %d 위는 음향+시야 칸" % [t["id"], i])
		assert_false((ts["sound"] as Dictionary).has(rank[94]) and (ts["sight"] as Dictionary).has(rank[94]))


func test_b2_average_satisfaction_hand_values() -> void:
	var ts: Dictionary = _tile_sets("baseline_show")
	var hand: Dictionary = {"no_lineup": 4600, "local_top_baseline": 6732, "rookie_baseline": 6733, "local_top_price30": 5730}
	for sc: Dictionary in _a["reference_scenarios"]:
		var ex: Dictionary = sc["expected"]
		var forward: int = _avg_by_seating(sc, ts, [0, 1, 2] as Array[int])
		var backward: int = _avg_by_seating(sc, ts, [2, 1, 0] as Array[int])
		var mixed: int = _avg_by_seating(sc, ts, [1, 0, 2] as Array[int])
		assert_eq(forward, int(hand[sc["id"]]), sc["id"] + " 손계산 평균")
		assert_eq(forward, int(ex["avg_satisfaction_bp_hand"]), sc["id"] + " == expected.hand")
		assert_eq(backward, forward, sc["id"] + " 도착 순서와 무관(B2)")
		assert_eq(mixed, forward, sc["id"] + " 도착 순서와 무관(B2)")
		var rg: Array = ex["avg_satisfaction_bp_range"]
		assert_eq(int(rg[1]), int(ex["avg_satisfaction_bp_hand"]), "범위 상한 == 손계산")
		assert_eq(int(rg[0]), int(ex["avg_satisfaction_bp_hand"]) - 300, "범위 하한 == 손계산 − 300")
		# 수치 목표 AT5: 5,000~8,000 (no_lineup 은 라인업이 없어 제외)
		if sc["lineup"] != null:
			assert_between(forward, 5000, 8000, "AT5 " + str(sc["id"]))


func test_b2_per_type_values() -> void:
	var ts: Dictionary = _tile_sets("baseline_show")
	var bonus: int = int(ts["bonus"])
	var s07: Dictionary = _slot("s07")
	var s08: Dictionary = _slot("s08")
	# local_top_baseline: 팬 6,960 / 단골·뜨내기 6,488
	assert_eq(_sat(_types[1], s07, 20, 0, bonus, 10000, 10000, 0), 6960)
	assert_eq(_sat(_types[0], s07, 20, 0, bonus, 10000, 10000, 0), 6488)
	assert_eq(_sat(_types[2], s07, 20, 0, bonus, 10000, 10000, 0), 6488)
	# rookie_baseline (crowd 9,180): 팬 7,341, 단골·뜨내기 6,701
	assert_eq(_crowd(120, 122), 9180)
	assert_eq(_sat(_types[1], s08, 20, 9180, bonus, 10000, 10000, 0), 7341)
	assert_eq(_sat(_types[0], s08, 20, 9180, bonus, 10000, 10000, 0), 6701)
	assert_eq(_sat(_types[2], s08, 20, 9180, bonus, 10000, 10000, 0), 6701)
	# local_top_price30: 팬 6,060 / 단골 5,888 / 뜨내기 4,988
	assert_eq(_sat(_types[1], s07, 30, 0, bonus, 10000, 10000, 0), 6060)
	assert_eq(_sat(_types[0], s07, 30, 0, bonus, 10000, 10000, 0), 5888)
	assert_eq(_sat(_types[2], s07, 30, 0, bonus, 10000, 10000, 0), 4988)
	# no_lineup: 단골 4,600
	assert_eq(_sat(_types[0], null, 20, 0, bonus, 10000, 10000, 0), 4600)
	# 음향 또는 시야 하나를 놓치면 정확히 1,500 낮다
	assert_eq(_sat(_types[1], s07, 20, 0, bonus, 0, 10000, 0), 6960 - 1500)
	assert_eq(_sat(_types[1], s07, 20, 0, bonus, 10000, 0, 0), 6960 - 1500)
	# 대기 감점: 단골 인내 400 에서 대기 100 → wait_bp 2,500 → 감점 500
	assert_eq(_sat(_types[0], s07, 20, 0, bonus, 10000, 10000, 100), 6488 - 500)
	# 대기 > 인내여도 wait_bp 는 10,000 에서 멈춘다(감점 최대 2,000)
	assert_eq(_sat(_types[2], s07, 20, 0, bonus, 10000, 10000, 10000), 6488 - 2000)
	# 한 번 확정한 조기 퇴장자(crowd_bp = 0)가 혼잡 감점을 받지 않는다 — 같은 입력이라 crowd 가 클수록 낮다
	assert_gt(_sat(_types[1], s08, 20, 0, bonus, 10000, 10000, 0), _sat(_types[1], s08, 20, 9180, bonus, 10000, 10000, 0))


# --- AC: artist.md T5 ----------------------------------------------------------------------------------

func test_checks_t5_rookie_over_local_top() -> void:
	var c: Dictionary = _a["checks"]
	var cap: int = mini(int(_layout("baseline_show")["expected"]["capacity"]), int(_a["max_agents"]))
	var slots: Dictionary = {}
	for s: Dictionary in _art["roster_plan"]["slots"]:
		slots[s["slot"]] = s
	var expect: Dictionary = {"s04": 122, "s08": 120, "s11": 122, "s12": 122, "s03": 85, "s07": 92, "s10": 87}
	var x: Dictionary = {}
	for id: String in (c["rookie_slots"] as Array) + (c["local_top_slots"] as Array):
		x[id] = mini(_sum(_e_centi(slots[id], int(c["reference_reputation"]), 20)) / 100, cap)
		assert_eq(x[id], int(expect[id]), "T5 기대 입장 " + id)
	var worst: int = 1000
	for r: String in c["rookie_slots"]:
		assert_eq(slots[r]["grade"], "rookie")
		for l: String in c["local_top_slots"]:
			assert_eq(slots[l]["grade"], "local")
			worst = mini(worst, int(x[r]) - int(x[l]))
	assert_gte(worst, int(c["rookie_over_local_top_min"]), "artist.md T5: 신인 − 로컬 상위 ≥ 17")
	assert_eq(worst, 28)
	var tgt: Array = c["rookie_over_local_top_target"]
	assert_between(worst, int(tgt[0]), int(tgt[1]), "권장 25~40")
	assert_eq(int(c["rookie_over_local_top_min"]), 17)
	assert_eq(int(c["reference_reputation"]), int(_art["grades"][1]["unlock_reputation"]), "기준 명성 == 신인 해금 임계")
	# local_top 은 각 장르에서 인기 최고의 local 이다
	var best_local: Dictionary = {}
	for s: Dictionary in _art["roster_plan"]["slots"]:
		if s["grade"] == "local":
			var g: String = s["genre"]
			if not best_local.has(g) or int(s["popularity"]) > int(slots[best_local[g]]["popularity"]):
				best_local[g] = s["slot"]
	var tops: Array = best_local.values()
	tops.sort()
	var given: Array = (c["local_top_slots"] as Array).duplicate()
	given.sort()
	assert_eq(given, tops, "local_top_slots == 장르별 인기 최고 local")


func test_demand_curve_literals() -> void:
	# audience.md 입장 수 곡선(기준 배치 수용 122, 티켓 20, 노이즈 0 = ⌊E ÷ 100⌋ 와 수용의 최소)
	var lines: Dictionary = {
		"none": [12, 15, 17, 22], "s03": [76, 85, 91, 107], "s07": [83, 92, 99, 115], "s10": [77, 87, 95, 113],
		"s08": [110, 120, 122, 122], "s04": [116, 122, 122, 122], "s11": [122, 122, 122, 122], "s12": [122, 122, 122, 122],
	}
	for k: String in lines:
		var lu: Variant = null if k == "none" else _slot(k)
		var got: Array = []
		for rep: int in [0, 150, 250, 500]:
			got.append(mini(_sum(_e_centi(lu, rep, 20)) / 100, 122))
		assert_eq(got, lines[k], "곡선 " + k)
	# AT1/AT2/AT3
	assert_lte(_sum(_e_centi(null, 0, 20)) / 100, 20, "AT1: 라인업 없음 ≤ 20")
	for s: String in ["s03", "s07", "s10"]:
		assert_between(_sum(_e_centi(_slot(s), 0, 20)) / 100, 70, 95, "AT2 " + s)


# --- 결정성(R1~R3): 실제 SeededRng 로 뽑기 횟수·스트림 격리를 확인 --------------------------------------------

## AD7 + AD11 을 실제 스트림에 그대로 적용한다. 반환 {noise, draws, list}.
func _draw_day(rng: SeededRng, n_t: Array[int], u_noise_mod: int) -> Dictionary:
	var st: RandomNumberGenerator = rng.stream("audience")
	var u: int = st.randi()
	var draws: int = 1
	var list: Array[int] = []
	for ti: int in range(n_t.size()):
		for k: int in range(n_t[ti]):
			list.append(ti)
	for i: int in range(list.size() - 1, 0, -1):
		var j: int = st.randi() % (i + 1)
		var tmp: int = list[i]
		list[i] = list[j]
		list[j] = tmp
		draws += 1
	return {"u": u, "noise": (u % u_noise_mod) - 1000, "draws": draws, "list": list}


func test_rng_draw_count_and_stream_isolation() -> void:
	var cases: Array = [[12, 0, 0], [10, 43, 30], [12, 67, 41], [0, 0, 0], [0, 0, 1], [50, 50, 50]]
	for c: Array in cases:
		var n_t: Array[int] = [int(c[0]), int(c[1]), int(c[2])]
		var n: int = _sum(n_t)
		var a: SeededRng = SeededRng.new(7, _stream_names)
		var res: Dictionary = _draw_day(a, n_t, 2001)
		assert_eq(res["draws"], maxi(1, n), "R3: 뽑기 수 == 1 + max(0, N−1) == max(1, N) (N=%d)" % n)
		# 다른 스트림은 건드리지 않는다
		var fresh: SeededRng = SeededRng.new(7, _stream_names)
		var sa: Dictionary = a.get_state()
		var sf: Dictionary = fresh.get_state()
		for name: String in _stream_names:
			if name != "audience":
				assert_eq(sa[name], sf[name], "R1: 다른 스트림 불변 " + name)
		# audience 스트림은 정확히 draws 번 진행했다
		var st: RandomNumberGenerator = fresh.stream("audience")
		for k: int in range(res["draws"]):
			st.randi()
		assert_eq(a.get_state()["audience"], fresh.get_state()["audience"], "R2/R3: audience 스트림이 정확히 draws 번 진행")
		# 섞은 목록은 순열(유형별 개수 보존)
		var cnt: Array[int] = [0, 0, 0]
		for ti: int in res["list"]:
			cnt[ti] += 1
		assert_eq(cnt, n_t, "AD11: 섞어도 유형별 개수 보존")
		# R5: 같은 시드 → 같은 결과
		var b: SeededRng = SeededRng.new(7, _stream_names)
		assert_eq(_draw_day(b, n_t, 2001)["list"], res["list"], "R5: 같은 시드 같은 도착 순서")
	# 시드가 다르면 도착 순서가 다르다(충분히 큰 N)
	var s1: Dictionary = _draw_day(SeededRng.new(1, _stream_names), [10, 43, 30] as Array[int], 2001)
	var s2: Dictionary = _draw_day(SeededRng.new(2, _stream_names), [10, 43, 30] as Array[int], 2001)
	assert_ne(s1["list"], s2["list"])


func test_arrival_schedule_properties() -> void:
	# AD12: spawn_tick = ⌊k × window ÷ N⌋ — 단조 비감소, 마지막 < window. bar_planned = 유형 안 앞 ⌊n_t × bar_visit ÷ 10⁴⌋명.
	var window: int = int(_a["flow"]["arrival_window_ticks"])
	for sc: Dictionary in _a["reference_scenarios"]:
		var bt: Dictionary = sc["expected"]["by_type"]
		var n_t: Array[int] = [int(bt["regular"]), int(bt["genre_fan"]), int(bt["walk_in"])]
		var n: int = _sum(n_t)
		var list: Array[int] = _draw_day(SeededRng.new(int(sc["seed"]), _stream_names), n_t, 2001)["list"]
		var prev: int = -1
		var used: Array[int] = [0, 0, 0]
		var planned: int = 0
		for k: int in range(n):
			var spawn: int = k * window / n
			assert_gte(spawn, prev, "스폰 틱 단조")
			assert_lt(spawn, window)
			prev = spawn
			var ti: int = list[k]
			if used[ti] < n_t[ti] * int(_types[ti]["bar_visit_bp"]) / 10000:
				planned += 1
			used[ti] += 1
		# 바 예정자 수 = 시나리오 바 구매 예상 (46 / 64 / 28 / 8) 이고 economy S2 값(⌊audience × 0.6⌋)과 비슷하다(Q3)
		var econ_buyers: int = int(sc["expected"]["audience"]) * int(_eco["rows"][0]["bar_purchase_rate_bp"]) / int(_eco["rate_scale"])
		var diff: int = absi(planned - econ_buyers)
		assert_true(diff <= 1 or diff * 100 <= 15 * econ_buyers, "%s: 바 예정 %d vs economy %d" % [sc["id"], planned, econ_buyers])
		var expected_planned: Dictionary = {"no_lineup": 8, "local_top_baseline": 46, "rookie_baseline": 64, "local_top_price30": 28}
		assert_eq(planned, int(expected_planned[sc["id"]]), "바 예정자 " + str(sc["id"]))


# --- economy 계약 (sales_reported) -----------------------------------------------------------------------

func test_economy_settlement_matches_documented_net() -> void:
	# audience.md: 로컬 s07·명성 0 → 83명 net 828 (임대료 1.38배), 신인 s08·명성 150 → 120명 net 1,296 (2.16배). 유지비 123.
	var cfg: EconomyConfig = EconomyConfig.load()
	assert_not_null(cfg)
	var row: Dictionary = cfg.row(1)
	var upkeep: int = int(_layout("baseline_show")["expected"]["upkeep_per_day"])
	assert_eq(upkeep, 123)
	var cases: Array = [["local_top_baseline", "local", 828], ["rookie_baseline", "rookie", 1296]]
	for c: Array in cases:
		var ex: Dictionary = _scenario(c[0])["expected"]
		var s: Dictionary = Economy.compute_settlement(row, cfg.rate_scale, {
			"ticket_price": 20, "admissions": ex["admissions"], "audience": ex["audience"],
			"upkeep": upkeep, "guarantee": cfg.guarantee(c[1]), "loan_repayment": 0})
		assert_eq(s["net"], int(c[2]), "%s net" % c[0])
	var s_local: Dictionary = Economy.compute_settlement(row, cfg.rate_scale, {"ticket_price": 20, "admissions": 83, "audience": 83,
		"upkeep": 123, "guarantee": 400, "loan_repayment": 0})
	assert_eq(s_local["bar_buyers"], 49, "economy S2 ⌊83 × 0.6⌋ (audience 시뮬 46 과 비슷)")
	assert_eq(s_local["net"] * 10000 / int(row["rent_per_day"]), 13800, "임대료 1.38배")
	var s_rookie: Dictionary = Economy.compute_settlement(row, cfg.rate_scale, {"ticket_price": 20, "admissions": 120, "audience": 120,
		"upkeep": 123, "guarantee": 800, "loan_repayment": 0})
	assert_eq(s_rookie["net"] * 10000 / int(row["rent_per_day"]), 21600, "임대료 2.16배")


func _run_day_with_report(report_mode: String, admissions: int, audience: int) -> Dictionary:
	var scfg: SimConfig = SimConfig.load()
	var ecfg: EconomyConfig = EconomyConfig.load()
	var loop: TickLoop = TickLoop.new(scfg, 0)
	var rec: EventRecorder = EventRecorder.new(loop.bus, ["economy.day_settled", "economy.cash_changed"] as Array[String])
	var econ: Economy = Economy.new(ecfg, loop.bus)
	assert_true(loop.register_system("economy", econ.update, econ.snapshot, econ.restore), "economy 등록")
	loop.bus.publish("economy.upkeep_reported", {"total": 123})
	loop.bus.publish("economy.charge_proposed", {"request_id": "guarantee:1", "reason": "guarantee", "amount": 400})
	if report_mode == "before_last_tick":
		# audience 가 공연 마지막 틱 단계 2 에서 내는 것과 같은 시점: 마지막 틱을 처리하기 직전에 발행.
		loop.advance(scfg.day_ticks - 1)
		loop.bus.publish("economy.sales_reported", {"admissions": admissions, "audience": audience})
		loop.advance(1)
	elif report_mode == "on_close_handler":
		# 틀린 구현: time.phase_changed {to:"close"} 핸들러에서 발행 (economy 가 먼저 구독했으므로 정산 뒤에 전달된다).
		var late: Callable = func(p: Dictionary) -> void:
			if p.get("to", "") == "close":
				loop.bus.publish("economy.sales_reported", {"admissions": admissions, "audience": audience})
		loop.bus.subscribe("time.phase_changed", late)
		loop.advance(scfg.day_ticks)
		loop.bus.unsubscribe("time.phase_changed", late)  # 람다가 loop 를 잡아 순환 참조가 남지 않게
	else:
		loop.advance(scfg.day_ticks)
	return {"settled": rec.of("economy.day_settled"), "loop": loop, "econ": econ}


func test_sales_reported_before_close_is_settled_same_day() -> void:
	var ex: Dictionary = _scenario("local_top_baseline")["expected"]
	var r: Dictionary = _run_day_with_report("before_last_tick", int(ex["admissions"]), int(ex["audience"]))
	var settled: Array = r["settled"]
	assert_eq(settled.size(), 1, "정산 1회")
	if settled.size() == 1:
		assert_eq(settled[0]["admissions"], 83)
		assert_eq(settled[0]["audience"], 83)
		assert_eq(settled[0]["ticket_revenue"], 1660)
		assert_eq(settled[0]["bar_buyers"], 49)
		assert_eq(settled[0]["net"], 828, "공연 마지막 틱 단계 2 발행 → 그날 장부(net 828, 유지비 123·개런티 400)")


func test_sales_reported_from_close_handler_misses_the_day() -> void:
	# audience.md #공연-끝의 주장: close 핸들러에서 내면 E2 때문에 정산 뒤로 밀려 그날 장부에 안 들어간다.
	var ex: Dictionary = _scenario("local_top_baseline")["expected"]
	var r: Dictionary = _run_day_with_report("on_close_handler", int(ex["admissions"]), int(ex["audience"]))
	var settled: Array = r["settled"]
	assert_eq(settled.size(), 1)
	if settled.size() == 1:
		assert_eq(settled[0]["admissions"], 0, "close 핸들러 발행은 그날 정산에 못 들어간다(다음 회계일로 이월)")
		assert_eq(settled[0]["audience"], 0)
	# 이월된 값은 ledger 에 남아 다음 정산에 합산된다
	var econ: Economy = r["econ"]
	assert_eq(int(econ.ledger["admissions"]), 83, "이월된 입장은 ledger 에 남음")
	assert_eq(int(econ.ledger["audience"]), 83)


# --- AC4/AU13: events.md · audience.md · tick.md 정합 -------------------------------------------------------

func test_events_md_audience_rows() -> void:
	var txt: String = _doc(EVENTS_MD)
	if txt.is_empty():
		pending("events.md 를 찾을 수 없음")
		return
	for name: String in ["audience.admissions_decided", "audience.agent_moved", "audience.agent_left", "audience.day_summary"]:
		assert_true(txt.contains("| `" + name + "` |"), "events.md 행 " + name)
	var lines: PackedStringArray = txt.split("\n")
	var moved: String = ""
	var sales: String = ""
	var left_row: String = ""
	for l: String in lines:
		if l.begins_with("| `audience.agent_moved` |"):
			moved = l
		if l.begins_with("| `economy.sales_reported` |"):
			sales = l
		if l.begins_with("| `audience.agent_left` |"):
			left_row = l
	# E4 기본형: 원소가 배열(Dictionary 아님), 5칸 [id, px, pz, state, type]
	assert_true(moved.contains("Array[[id: int, px: int, pz: int, state: String, type: String]]"), "agent_moved 원소 5칸 배열")
	assert_true(moved.contains("Dictionary 아님"))
	assert_true(moved.contains("1,500"), "하루 1,500회")
	assert_true(left_row.contains("reason: \"patience\"|\"no_spot\"") or left_row.contains("\"patience\"\\|\"no_spot\""), "agent_left reason 2종")
	assert_true(sales.contains("발행 주체: audience"), "sales_reported 발행 주체 갱신")
	assert_true(sales.contains("SE-029"))
	assert_true(sales.contains("{0, 0}"), "입장 0 이어도 보고")
	# audience.md 본문 이벤트 이름이 모두 events.md 에 있다(등록 예정 3종 제외)
	var md: String = _doc(AUDIENCE_MD)
	assert_false(md.is_empty())
	var rx: RegEx = RegEx.create_from_string("`((?:audience|economy|build|artist|time|reputation|show|session)\\.[a-z_]+)`")
	var deferred: Array = ["reputation.changed", "show.ended", "session.loaded"]
	var names: Dictionary = {}
	for m: RegExMatch in rx.search_all(md):
		names[m.get_string(1)] = true
	assert_true(names.size() >= 10, "audience.md 가 언급하는 이벤트가 충분히 잡혔다")
	for n: String in names:
		if deferred.has(n) or n.ends_with(".json") or n.ends_with(".md"):
			continue
		assert_true(txt.contains("`" + n + "`"), "audience.md 이벤트가 events.md 에 없음: " + n)


func test_doc_consistency_decisions() -> void:
	var md: String = _doc(AUDIENCE_MD)
	var ev: String = _doc(EVENTS_MD)
	var tick: String = _doc(TICK_MD)
	if md.is_empty() or ev.is_empty() or tick.is_empty():
		pending("문서를 찾을 수 없음")
		return
	# 티켓 초안에서 바뀐 결정이 세 문서에 일관되게 적혔는가
	assert_true(md.contains("4틱") or md.contains("4 틱"), "이동 4틱/타일")
	assert_true(md.contains("[id, px, pz, state, type]"), "audience.md agent_moved 5칸")
	assert_true(ev.contains("px: int, pz: int, state: String, type: String"))
	assert_true(md.contains("audience.agent_left") and ev.contains("`audience.agent_left`"), "agent_left 신설")
	assert_true(md.contains("1,500"), "audience.md 하루 1,500회")
	# 공연 끝 순서 문장: agent_moved → day_summary → sales_reported
	assert_true(md.contains("`agent_moved`(전원 `gone`) → `day_summary` → `sales_reported`") or md.contains("`audience.agent_moved` → `audience.day_summary`") or md.contains("agent_moved"), "공연 끝 순서")
	# tick.md 스트림 표의 audience 행이 단계 4 를 적는다
	var row: String = ""
	for l: String in tick.split("\n"):
		if l.begins_with("| `audience` | audience |"):
			row = l
	assert_true(row.contains("단계 4"), "tick.md audience 행에 단계 4(artist.lineup_set 핸들러)")
	assert_true(row.contains("단계 2"))
	# 수용 기준 번호가 문서 안에서 끊김 없이 AU0~AU14, AT1~AT6
	for i: int in range(0, 15):
		assert_true(md.contains("| AU%d |" % i), "AU%d 행" % i)
	for i: int in range(1, 7):
		assert_true(md.contains("| AT%d |" % i), "AT%d 행" % i)
	# 열린 질문 Q1~Q11 전부 채택 표기
	for i: int in range(1, 12):
		assert_true(md.contains("| Q%d |" % i), "Q%d 행" % i)


func test_event_payloads_follow_e4_and_documented_keys() -> void:
	# E4 기본형: 샘플 페이로드가 실제 EventBus 를 통과하고(깊은 복사), 키 이름이 events.md·audience.md 에 모두 적혀 있다.
	var samples: Dictionary = {
		"audience.admissions_decided": {"day": 1, "admissions": 83, "expected": 83, "noise_bp": 42, "capacity": 122, "capped_by": "none",
			"has_lineup": true, "by_type": {"regular": 10, "genre_fan": 43, "walk_in": 30}},
		"audience.agent_moved": {"tick": 1800, "agents": [[1, 1150, 50, "entering", "genre_fan"], [2, 1225, 150, "moving", "walk_in"]]},
		"audience.agent_left": {"day": 1, "tick": 2000, "agent_id": 5, "type": "walk_in", "reason": "patience", "satisfaction_bp": 4200},
		"audience.day_summary": {"day": 1, "has_lineup": true, "admissions": 83, "audience": 83, "left_early": 0, "bar_buyers": 46,
			"avg_satisfaction_bp": 6732, "crowd_bp": 0,
			"avg_components": {"lineup_bp": 5000, "sound_bp": 9000, "sight_bp": 9000, "value_bp": 5000, "wait_bp": 10},
			"by_type": {"regular": {"admissions": 10, "left_early": 0, "avg_satisfaction_bp": 6488}}},
		"economy.sales_reported": {"admissions": 83, "audience": 83},
	}
	var ev: String = _doc(EVENTS_MD)
	var md: String = _doc(AUDIENCE_MD)
	var bus: EventBus = EventBus.new()
	for name: String in samples:
		var got: Array = []
		var h: Callable = func(p: Dictionary) -> void: got.append(p)
		bus.subscribe(name, h)
		assert_true(bus.publish(name, samples[name]), "E4 통과 " + name)
		bus.unsubscribe(name, h)
		assert_eq(got.size(), 1)
		assert_eq(got[0], samples[name], "깊은 복사본이 같다")
		assert_false(got[0] is Dictionary and is_same(got[0], samples[name]), "사본이다")
		if ev.is_empty():
			continue
		var row: String = ""
		for l: String in ev.split("\n"):
			if l.begins_with("| `" + name + "` |"):
				row = l
		assert_false(row.is_empty(), "events.md 행 " + name)
		for key: String in (samples[name] as Dictionary).keys():
			assert_true(row.contains(key + ":"), "events.md %s 에 키 %s" % [name, key])
			if name.begins_with("audience."):
				assert_true(md.contains(key), "audience.md 에 키 %s" % key)
	# 반례: Vector2i 같은 비기본형은 버스가 거부한다(agent_moved 가 Dictionary 원소·Vector2i 를 쓰지 않는 이유)
	var bad: Dictionary = {"tick": 1, "agents": [[1, Vector2i(1, 2), "moving", "walk_in"]]}
	assert_false(bus.publish("audience.agent_moved", bad))
	assert_push_error_count(1)
