extends GutTest
## SE-033 QA 추가 테스트(qa). test_artist_system.gd 가 덮지 않는 수용 기준·계약을 채운다.
##  1. 승급 공연 수 표(artist.md "승급까지 공연 수", T1·T2) — artist.json `checks.promotion_shows` 8x3 칸(SE-046, 리터럴 아님)과
##     ArtistConfig.grow() 반복 결과, 그리고 ArtistSystem 버스 경로(artist.grown)를 대조한다.
##     checks 자체는 artist.md 표(파싱)·GR1~GR4 닫힌 식·roster_plan 과 따로 대조한다(test_promotion_checks_*).
##  2. H2 `guarantee` = economy 가 돌려준 amount(결정 1).
##  3. 같은 틱 경계의 두 명령(E5 선례): 첫 명령의 현금 변화를 둘째가 본다.
##  4. build 와 artist 가 같은 버스·같은 경계에서 공존할 때 서로의 charge_resolved 를 무시한다(H4).
##  5. artist.lineup_set 소비 계약(audience.md LS3): 키 6개·타입·장르가 audience 유형 genre_fit_bp 키에 있음.
##  6. system_order 에서 artist 위치(tick.md), 복원한 구간이 K2 판정에 반영됨.
## checks 값은 artist.json 의 local 인기(6~27)·승급 임계(40)·델타(+1/+2/+3)가 바뀌면 의도적으로 실패한다(데이터 회귀 방지; 표만 고쳐도 문서·규칙 대조가 잡는다).

const RECORDED: Array[String] = [
	"economy.charge_proposed", "economy.cash_changed", "economy.charge_resolved",
	"artist.booked", "artist.booking_rejected", "artist.lineup_set", "artist.grown",
	"build.placed", "build.rejected",
]
const HANDSHAKE_OK: Array[String] = [
	"economy.charge_proposed", "economy.cash_changed", "economy.charge_resolved", "artist.booked",
]
const HANDSHAKE_NO: Array[String] = [
	"economy.charge_proposed", "economy.charge_resolved", "artist.booking_rejected",
]
const ARTIST_JSON: String = "res://data/artist/artist.json"
const ARTIST_MD: String = "res://../docs/gdd/artist.md"
const TABLE_GRADES: Array[String] = ["ok", "good", "rave"]
const TABLE_HEADING: String = "### 승급까지 공연 수"

var _acfg: ArtistConfig
var _ecfg: EconomyConfig
var _scfg: SimConfig
var _bcfg: BuildConfig
## artist.json `checks`(SE-046 B). 정수는 JsonUtil.as_int 로 접는다.
var _checks: Dictionary
## 시작 인기 → 승급까지 공연 수 [보통(ok), 호평(good), 열광(rave)]. checks.promotion_shows 에서 만든다.
var _promo: Dictionary = {}
var _fastest_min: int = 0
var _slowest_max: int = 0


func before_all() -> void:
	_acfg = ArtistConfig.load()
	_ecfg = EconomyConfig.load()
	_scfg = SimConfig.load()
	_bcfg = BuildConfig.load()
	_checks = (JSON.parse_string(FileAccess.get_file_as_string(ARTIST_JSON)) as Dictionary)["checks"]
	for row: Dictionary in _checks["promotion_shows"]:
		var cells: Array = []
		for sg: String in TABLE_GRADES:
			cells.append(JsonUtil.as_int(row[sg]))
		_promo[JsonUtil.as_int(row["popularity"])] = cells
	_fastest_min = JsonUtil.as_int(_checks["fastest_promotion_min_shows"])
	_slowest_max = JsonUtil.as_int(_checks["slowest_promotion_max_shows"])


# --- 도우미 -------------------------------------------------------------------

## [bus, artist, econ, rec]. artist → economy 순으로 구독. with_economy=false 면 econ null.
func _unit(with_economy: bool = true) -> Array:
	var bus: EventBus = EventBus.new()
	var rec: EventRecorder = EventRecorder.new(bus, RECORDED)
	var artist: ArtistSystem = ArtistSystem.new(_acfg, bus)
	var econ: Economy = Economy.new(_ecfg, bus) if with_economy else null
	return [bus, artist, econ, rec]


func _set_cash(econ: Economy, cash: int) -> void:
	var s: Dictionary = econ.snapshot()
	s["cash"] = cash
	assert_true(econ.restore(s), "economy 현금 설정")


func _id_of(grade: String, nth: int = 0) -> String:
	var n: int = 0
	for id: String in _acfg.artist_ids():
		if _acfg.artist(id)["grade"] == grade:
			if n == nth:
				return id
			n += 1
	fail_test("등급 %s 의 %d번째 아티스트가 없다" % [grade, nth])
	return ""


func _phase(bus: EventBus, from: String, to: String, day: int) -> void:
	bus.publish("time.phase_changed", {"from": from, "to": to, "day": day, "tick": 0})


func _rt(v: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(v))


func _hash(sys: Object) -> String:
	return JSON.stringify(sys.call("snapshot"), "", true)


## 섭외 → 저녁 → 공연 → show.ended → 다음 날 낮. 섭외 성공이면 true.
func _play_day(bus: EventBus, artist: ArtistSystem, id: String, show_grade: String) -> bool:
	var d: int = artist.day
	bus.publish("artist.book_requested", {"artist_id": id})
	bus.dispatch_commands()
	var booked: bool = artist.lineup_today == id
	_phase(bus, "day", "evening", d)
	_phase(bus, "evening", "show", d)
	bus.publish("show.ended", {"day": d, "artist_id": id, "grade": show_grade})
	bus.publish("time.day_started", {"day": d + 1})
	_phase(bus, "show", "day", d + 1)
	return booked


# --- 1. 승급 공연 수 표 ------------------------------------------------------------

func test_promotion_table_config_grow() -> void:
	var rule: Dictionary = _acfg.grade_rule("local")
	var checked: int = 0
	for id: String in _acfg.artist_ids():
		var a: Dictionary = _acfg.artist(id)
		if a["grade"] != "local":
			continue
		assert_true(_promo.has(a["popularity"]), "%s: 시작 인기 %d 가 checks.promotion_shows 에 있다" % [id, a["popularity"]])
		if not _promo.has(a["popularity"]):
			continue
		for k: int in TABLE_GRADES.size():
			var sg: String = TABLE_GRADES[k]
			var e: Dictionary = {
				"id": id, "grade": "local", "popularity": a["popularity"], "skill": a["skill"],
				"shows_played": 0, "discovered_here": false, "relationship": 0,
			}
			var n: int = 0
			var promoted_calls: Array = []
			while n < 100:
				n += 1
				e = _acfg.grow(e, sg)
				if e["promoted"]:
					promoted_calls.append(n)
					break
			var label: String = "%s(%d) %s" % [id, a["popularity"], sg]
			assert_eq(n, _promo[a["popularity"]][k], label + ": 승급까지 공연 수")
			assert_eq(promoted_calls, [n], label + ": 승급은 그 공연 하나")
			assert_eq(e["grade"], "rookie", label + ": 승급 등급")
			assert_eq(e["shows_played"], n)
			assert_eq(e["skill"], mini(_acfg.stat_max, a["skill"] + int(rule["skill_per_show"]) * n), label + ": 실력 = 시작 + 공연당 × n (상한)")
			assert_true(e["popularity"] >= int(rule["promote_at_popularity"]) and e["popularity"] - e["popularity_delta"] < int(rule["promote_at_popularity"]),
				label + ": 직전 공연까지는 임계 미만")
			# 승급 뒤 한 번 더: 다시 승급하지 않는다.
			var after: Dictionary = _acfg.grow(e, sg)
			assert_false(after["promoted"], label + ": 승급 뒤 재승급 없음")
			assert_eq(after["grade"], "rookie")
		checked += 1
	assert_eq(checked, _promo.size(), "local 8명 전원 검사")
	# T1·T2
	var fastest: int = 999
	var slowest: int = 0
	for key: int in _promo:
		fastest = mini(fastest, _promo[key][2])
		slowest = maxi(slowest, _promo[key][1])
	assert_true(fastest >= _fastest_min, "T1 가장 빠른 승급(열광만) %d >= checks.fastest_promotion_min_shows %d" % [fastest, _fastest_min])
	assert_true(slowest <= _slowest_max, "T2 가장 느린 승급(호평만) %d <= checks.slowest_promotion_max_shows %d" % [slowest, _slowest_max])


## checks.promotion_shows 가 artist.md 표(문서)와 같다. 문서의 마크다운 표를 파싱한다(굵게 `**n**` 제거).
func test_promotion_checks_match_doc_table() -> void:
	var path: String = ProjectSettings.globalize_path("res://").path_join("../docs/gdd/artist.md").simplify_path()
	assert_true(FileAccess.file_exists(path), "artist.md 를 찾을 수 있다: " + path)
	if not FileAccess.file_exists(path):
		return
	var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
	var start: int = -1
	for i: int in lines.size():
		if lines[i].begins_with(TABLE_HEADING):
			start = i
			break
	assert_ne(start, -1, "artist.md 에 '%s' 절이 있다" % TABLE_HEADING)
	if start < 0:
		return
	var doc: Dictionary = {}  # slot → [popularity, ok, good, rave]
	for i: int in range(start + 1, lines.size()):
		var ln: String = lines[i].strip_edges()
		if ln.begins_with("#"):
			break
		if not ln.begins_with("| s"):
			continue
		var cells: PackedStringArray = ln.replace("**", "").trim_prefix("|").trim_suffix("|").split("|")
		assert_eq(cells.size(), 5, "문서 표 행은 5칸: " + ln)
		if cells.size() != 5:
			continue
		var nums: Array = []
		for c: int in range(1, 5):
			assert_true(cells[c].strip_edges().is_valid_int(), "정수 칸: " + cells[c])
			nums.append(cells[c].strip_edges().to_int())
		doc[cells[0].strip_edges()] = nums
	var rows: Array = _checks["promotion_shows"]
	assert_eq(doc.size(), rows.size(), "문서 표 행 수 == checks.promotion_shows 행 수")
	for row: Dictionary in rows:
		var slot: String = row["slot"]
		assert_true(doc.has(slot), "문서 표에 슬롯 %s" % slot)
		if not doc.has(slot):
			continue
		var got: Array = [JsonUtil.as_int(row["popularity"])]
		for sg: String in TABLE_GRADES:
			got.append(JsonUtil.as_int(row[sg]))
		assert_eq(got, doc[slot], "%s: [인기, 보통, 호평, 열광] 문서 == 데이터" % slot)
	# 문서 본문의 T1·T2 판정 문구(5회 ≥ 하한 5, 17회 ≤ 25)도 checks 와 같은 수.
	var body: String = "\n".join(lines.slice(start))
	assert_true(body.contains("가장 빠른 승급(열광만) %d회 ≥ 하한 %d" % [_min_of(2), _fastest_min]), "문서 T1 문구 == 데이터")
	assert_true(body.contains("가장 느린 승급(호평만) %d회 ≤ 티어 2 목표 %d일" % [_max_of(1), _slowest_max]), "문서 T2 문구 == 데이터")


## checks.promotion_shows 가 규칙(GR1·GR4: n = ⌈(promote_at − 인기) ÷ Δ⌉)·roster_plan 과 같다. 재시뮬레이션 없이 정수 닫힌 식.
func test_promotion_checks_match_rules_and_roster() -> void:
	var from_grade: String = _checks["promotion_from"]
	var rule: Dictionary = _acfg.grade_rule(from_grade)
	var at: int = int(rule["promote_at_popularity"])
	var deltas: Dictionary = rule["popularity_delta_by_show_grade"]
	var roster: Array = (JSON.parse_string(FileAccess.get_file_as_string(ARTIST_JSON)) as Dictionary)["roster_plan"]["slots"]
	var plan: Dictionary = {}  # slot → popularity (promotion_from 등급만)
	for sl: Dictionary in roster:
		if sl["grade"] == from_grade:
			plan[sl["slot"]] = JsonUtil.as_int(sl["popularity"])
	var rows: Array = _checks["promotion_shows"]
	assert_eq(rows.size(), plan.size(), "checks 행 수 == roster_plan %s 슬롯 수" % from_grade)
	var seen: Dictionary = {}
	for row: Dictionary in rows:
		var slot: String = row["slot"]
		assert_false(seen.has(slot), "슬롯 중복 없음: " + slot)
		seen[slot] = true
		assert_true(plan.has(slot), "roster_plan 의 %s 슬롯 %s" % [from_grade, slot])
		if not plan.has(slot):
			continue
		var pop: int = JsonUtil.as_int(row["popularity"])
		assert_eq(pop, plan[slot], "%s: 인기 == roster_plan" % slot)
		for sg: String in TABLE_GRADES:
			var d: int = int(deltas[sg])
			assert_true(d > 0, "%s: Δ>0" % sg)
			@warning_ignore("integer_division")
			var want: int = (at - pop + d - 1) / d  # 정수 올림
			assert_eq(JsonUtil.as_int(row[sg]), want, "%s %s: ⌈(%d−%d)÷%d⌉" % [slot, sg, at, pop, d])
	assert_eq(seen.size(), plan.size(), "local 슬롯 전부 커버")


func _min_of(k: int) -> int:
	var v: int = 1 << 30
	for key: int in _promo:
		v = mini(v, _promo[key][k])
	return v


func _max_of(k: int) -> int:
	var v: int = 0
	for key: int in _promo:
		v = maxi(v, _promo[key][k])
	return v


func test_promotion_table_through_bus() -> void:
	var local_ids: Array[String] = []
	for id: String in _acfg.artist_ids():
		if _acfg.artist(id)["grade"] == "local":
			local_ids.append(id)
	var top_cost: int = _ecfg.guarantee("rookie")
	for id: String in local_ids:
		var a: Dictionary = _acfg.artist(id)
		for k: int in TABLE_GRADES.size():
			var sg: String = TABLE_GRADES[k]
			var want: int = _promo[a["popularity"]][k]
			var u: Array = _unit()
			_set_cash(u[2], top_cost * (want + 2))
			var rec: EventRecorder = u[3]
			var grown_promoted: Array = []
			var n: int = 0
			while n < want:
				n += 1
				assert_true(_play_day(u[0], u[1], id, sg), "%s %s #%d 섭외" % [id, sg, n])
				var g: Array = rec.of("artist.grown")
				assert_eq(g.size(), n, "%s %s #%d: grown 누적 %d" % [id, sg, n, n])
				if not g.is_empty() and g.back()["promoted"]:
					grown_promoted.append(n)
			assert_eq(grown_promoted, [want], "%s %s: promoted true 는 %d번째 공연 하나" % [id, sg, want])
			var e: Dictionary = (u[1] as ArtistSystem).entry(id)
			assert_eq(e["grade"], "rookie")
			assert_eq(e["shows_played"], want)
			assert_eq(e["skill"], mini(_acfg.stat_max, a["skill"] + int(_acfg.grade_rule("local")["skill_per_show"]) * want))
			# 명성 0 이어도 발굴 면제로 승급한 본인은 rookie 개런티로 섭외 가능
			assert_eq((u[1] as ArtistSystem).check_book(id), "", "%s: 승급 직후 섭외 가능(K4 면제)" % id)


# --- 2. H2: 승인 금액이 기록된다 -----------------------------------------------------

func test_h2_guarantee_is_resolved_amount() -> void:
	var u: Array = _unit(false)
	var bus: EventBus = u[0]
	var artist: ArtistSystem = u[1]
	var rec: EventRecorder = u[3]
	var id: String = _id_of("local")
	var amount: int = _ecfg.guarantee("local")
	bus.publish("artist.book_requested", {"artist_id": id})
	bus.dispatch_commands()
	var rid: String = rec.of("economy.charge_proposed")[0]["request_id"]
	bus.publish("economy.charge_resolved", {"request_id": rid, "reason": "guarantee", "amount": amount + 7, "approved": true, "decline_reason": "", "cash": 0})
	assert_eq(rec.of("artist.booked")[0]["guarantee"], amount + 7, "guarantee = economy 가 승인한 금액")
	assert_eq(artist.lineup_today, id)
	# 정수가 아닌 amount 는 제안 금액으로(결정 1), 정수값 float 는 int 로.
	for pair: Array in [["x", amount], [float(amount + 3), amount + 3]]:
		var v: Array = _unit(false)
		(v[0] as EventBus).publish("artist.book_requested", {"artist_id": id})
		(v[0] as EventBus).dispatch_commands()
		var r2: String = (v[3] as EventRecorder).of("economy.charge_proposed")[0]["request_id"]
		(v[0] as EventBus).publish("economy.charge_resolved", {"request_id": r2, "reason": "guarantee", "amount": pair[0], "approved": true, "decline_reason": "", "cash": 0})
		assert_eq((v[3] as EventRecorder).of("artist.booked")[0]["guarantee"], pair[1], "amount %s → %s" % [pair[0], pair[1]])


# --- 3. 같은 경계의 두 명령(E5) ------------------------------------------------------

func test_same_boundary_two_commands() -> void:
	var amount: int = _ecfg.guarantee("local")
	var a: String = _id_of("local")
	var b: String = _id_of("local", 1)
	# (a) 현금이 개런티 1회분: 첫 명령 성공 → 둘째는 already_booked(economy 호출 없음), 현금 0.
	var u: Array = _unit()
	_set_cash(u[2], amount)
	var led0: int = int((u[2] as Economy).ledger["guarantee"])
	(u[0] as EventBus).publish("artist.book_requested", {"artist_id": a})
	(u[0] as EventBus).publish("artist.book_requested", {"artist_id": b})
	assert_eq((u[0] as EventBus).dispatch_commands(), 2, "같은 경계에서 명령 2개")
	assert_eq((u[3] as EventRecorder).names(), HANDSHAKE_OK + ["artist.booking_rejected"], "첫 연쇄가 끝난 뒤 둘째")
	assert_eq((u[3] as EventRecorder).of("artist.booking_rejected")[0], {"day": 1, "artist_id": b, "reason": "already_booked"})
	assert_eq((u[2] as Economy).cash, 0)
	assert_eq(int((u[2] as Economy).ledger["guarantee"]), led0 + amount, "개런티 1회분만")
	assert_eq((u[1] as ArtistSystem).lineup_today, a)
	# (b) 현금 부족: 둘 다 insufficient_cash(첫 거절이 상태를 남기지 않아 둘째도 같은 판정).
	var v: Array = _unit()
	_set_cash(v[2], amount - 1)
	(v[0] as EventBus).publish("artist.book_requested", {"artist_id": a})
	(v[0] as EventBus).publish("artist.book_requested", {"artist_id": b})
	(v[0] as EventBus).dispatch_commands()
	assert_eq((v[3] as EventRecorder).names(), HANDSHAKE_NO + HANDSHAKE_NO)
	var rej: Array = (v[3] as EventRecorder).of("artist.booking_rejected")
	assert_eq([rej[0]["reason"], rej[1]["reason"]], ["insufficient_cash", "insufficient_cash"])
	assert_eq([rej[0]["artist_id"], rej[1]["artist_id"]], [a, b])
	assert_eq((v[2] as Economy).cash, amount - 1)
	assert_eq((v[1] as ArtistSystem).lineup_today, null)
	assert_false((v[1] as ArtistSystem).has_pending())
	# (c) 거절 뒤 같은 경계의 다음 명령은 성공할 수 있다: 첫 명령 id 모름 → 둘째 정상.
	var w: Array = _unit()
	(w[0] as EventBus).publish("artist.book_requested", {"artist_id": "nobody_here"})
	(w[0] as EventBus).publish("artist.book_requested", {"artist_id": a})
	(w[0] as EventBus).dispatch_commands()
	assert_eq((w[3] as EventRecorder).names(), ["artist.booking_rejected"] + HANDSHAKE_OK)
	assert_eq((w[1] as ArtistSystem).lineup_today, a)


# --- 4. build 와 공존(H4) ----------------------------------------------------------

## [bus, build, artist, econ, rec] — build → artist → economy(system_order).
func _trio() -> Array:
	var bus: EventBus = EventBus.new()
	var rec: EventRecorder = EventRecorder.new(bus, RECORDED)
	var build: BuildSystem = BuildSystem.new(_bcfg, bus)
	var artist: ArtistSystem = ArtistSystem.new(_acfg, bus)
	var econ: Economy = Economy.new(_ecfg, bus)
	return [bus, build, artist, econ, rec]


func test_coexists_with_build_handshake() -> void:
	var amount: int = _ecfg.guarantee("local")
	var cost: int = int(_bcfg.furniture("speaker_floor")["build_cost"])
	var id: String = _id_of("local")
	# (a) 둘 다 살 수 있는 현금: 서로의 charge_resolved 를 무시하고 각자 확정.
	var t: Array = _trio()
	_set_cash(t[3], amount + cost)
	(t[0] as EventBus).publish("build.place_requested", {"furniture_id": "speaker_floor", "cell": [5, 5], "rotation": 0})
	(t[0] as EventBus).publish("artist.book_requested", {"artist_id": id})
	assert_eq((t[0] as EventBus).dispatch_commands(), 2)
	var rec: EventRecorder = t[4]
	assert_eq(rec.count("build.placed"), 1)
	assert_eq(rec.count("artist.booked"), 1)
	assert_eq(rec.count("build.rejected") + rec.count("artist.booking_rejected"), 0)
	assert_eq((t[3] as Economy).cash, 0, "두 지출이 모두 반영")
	assert_eq(rec.of("artist.booked")[0]["guarantee"], amount, "artist 는 build 의 승인 금액을 받지 않는다")
	assert_eq(rec.of("build.placed")[0]["cost"], cost, "build 는 artist 의 승인 금액을 받지 않는다")
	assert_false((t[2] as ArtistSystem).has_pending())
	# (b) 현금이 한 쪽만: 먼저 온 명령이 현금을 가져가고 나머지는 insufficient_cash.
	var t2: Array = _trio()
	_set_cash(t2[3], amount)
	(t2[0] as EventBus).publish("artist.book_requested", {"artist_id": id})
	(t2[0] as EventBus).publish("build.place_requested", {"furniture_id": "speaker_floor", "cell": [5, 5], "rotation": 0})
	(t2[0] as EventBus).dispatch_commands()
	var r2: EventRecorder = t2[4]
	assert_eq(r2.count("artist.booked"), 1, "먼저 온 섭외 성공")
	assert_eq(r2.of("build.rejected")[0]["reason"], "insufficient_cash", "나중 건설은 갱신된 현금 0 으로 거절")
	var t3: Array = _trio()
	_set_cash(t3[3], amount)
	(t3[0] as EventBus).publish("build.place_requested", {"furniture_id": "speaker_floor", "cell": [5, 5], "rotation": 0})
	(t3[0] as EventBus).publish("artist.book_requested", {"artist_id": id})
	(t3[0] as EventBus).dispatch_commands()
	var r3: EventRecorder = t3[4]
	assert_eq(r3.count("build.placed"), 1, "먼저 온 건설 성공")
	assert_eq(r3.of("artist.booking_rejected")[0]["reason"], "insufficient_cash", "나중 섭외는 갱신된 현금(amount − cost)으로 거절")
	assert_eq((t3[3] as Economy).cash, amount - cost)
	assert_eq((t3[2] as ArtistSystem).lineup_today, null)


# --- 5. artist.lineup_set 소비 계약 --------------------------------------------------

func test_lineup_payload_contract_for_audience() -> void:
	var types: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/audience/audience.json"))["types"]
	var fit_keys: Array = []
	for ty: Dictionary in types:
		fit_keys.append((ty["genre_fit_bp"] as Dictionary).keys())
	for id: String in _acfg.artist_ids():
		for keys: Array in fit_keys:
			assert_true(keys.has(_acfg.genre_of(id)), "%s 의 장르가 audience 유형 genre_fit_bp 키에 있다(LS3)" % id)
	var keyset: Array = ["artist_id", "day", "genre", "grade", "popularity", "skill"]
	var u: Array = _unit()
	var id: String = _id_of("local")
	(u[0] as EventBus).publish("artist.book_requested", {"artist_id": id})
	(u[0] as EventBus).dispatch_commands()
	(u[3] as EventRecorder).clear()
	_phase(u[0], "day", "evening", 1)
	var p: Dictionary = (u[3] as EventRecorder).of("artist.lineup_set")[0]
	var ks: Array = p.keys()
	ks.sort()
	assert_eq(ks, keyset, "lineup_set 키 6개")
	assert_true(p["day"] is int and p["artist_id"] is String and p["genre"] is String and p["grade"] is String, "문자열·정수 타입")
	assert_true(p["popularity"] is int and p["skill"] is int)
	assert_true(int(p["popularity"]) >= 0 and int(p["popularity"]) <= _acfg.stat_max and int(p["skill"]) >= 0 and int(p["skill"]) <= _acfg.stat_max, "0~stat_max (LS3)")
	# 섭외 없는 날
	var v: Array = _unit()
	_phase(v[0], "day", "evening", 1)
	var q: Dictionary = (v[3] as EventRecorder).of("artist.lineup_set")[0]
	var kq: Array = q.keys()
	kq.sort()
	assert_eq(kq, keyset)
	assert_eq([q["artist_id"], q["genre"], q["grade"], q["popularity"], q["skill"]], [null, null, null, 0, 0])
	# 승급 뒤에는 grade 가 rookie, 인기·실력이 성장 반영값
	var w: Array = _unit()
	var sc: Dictionary = _acfg.scenario("local_top_all_rave")
	var hero: String = ""
	for cand: String in _acfg.artist_ids():
		var a: Dictionary = _acfg.artist(cand)
		if a["grade"] == sc["grade"] and a["popularity"] == sc["popularity"] and a["skill"] == sc["skill"]:
			hero = cand
	assert_ne(hero, "")
	_set_cash(w[2], _ecfg.guarantee("rookie") * 10)
	for sg: String in sc["show_grades"]:
		_play_day(w[0], w[1], hero, sg)
	(w[3] as EventRecorder).clear()
	(w[0] as EventBus).publish("artist.book_requested", {"artist_id": hero})
	(w[0] as EventBus).dispatch_commands()
	_phase(w[0], "day", "evening", (w[1] as ArtistSystem).day)
	var r: Dictionary = (w[3] as EventRecorder).of("artist.lineup_set")[0]
	assert_eq([r["grade"], r["popularity"], r["skill"]], [sc["expected"]["grade"], sc["expected"]["popularity"], sc["expected"]["skill"]], "lineup_set 은 성장 반영 후 값")


# --- 6. system_order · 복원한 구간 ---------------------------------------------------

func test_system_order_and_restored_phase() -> void:
	var order: Array = _scfg.system_order
	var ia: int = order.find("artist")
	assert_true(ia >= 0, "artist 가 system_order 에 있다")
	assert_true(order.find("build") < ia and order.find("staff") < ia, "build·staff 뒤")
	assert_true(ia < order.find("audience") and ia < order.find("economy"), "audience·economy 앞")
	# 복원한 구간이 K2 에 반영된다.
	var u: Array = _unit()
	var id: String = _id_of("local")
	var snap: Dictionary = (u[1] as ArtistSystem).snapshot()
	snap["phase"] = "evening"
	var v: Array = _unit()
	assert_true((v[1] as ArtistSystem).restore(_rt(snap)))
	assert_eq((v[1] as ArtistSystem).check_book(id), "not_allowed", "복원한 evening 에서 섭외 불가")
	assert_eq((v[3] as EventRecorder).events.size(), 0, "restore 는 이벤트 0(lineup_set 재발행 없음)")
	snap["phase"] = "day"
	assert_true((v[1] as ArtistSystem).restore(_rt(snap)))
	assert_eq((v[1] as ArtistSystem).check_book(id), "")
	# 복원 뒤 대기 중이던 제안은 사라진다(pending 은 스냅샷 밖).
	var w: Array = _unit(false)
	(w[0] as EventBus).publish("artist.book_requested", {"artist_id": id})
	(w[0] as EventBus).dispatch_commands()
	assert_true((w[1] as ArtistSystem).has_pending())
	assert_true((w[1] as ArtistSystem).restore(_rt(snap)))
	assert_false((w[1] as ArtistSystem).has_pending(), "restore 성공 뒤 pending 없음")


# --- 7. TickLoop 경로: H5 와 저녁 진입 꼬리 순서 ---------------------------------------

## economy 미등록 TickLoop 에서 응답 없는 제안은 같은 틱의 단계 2(update)에서 거절된다(H5).
func test_h5_flush_via_tickloop_update() -> void:
	var loop: TickLoop = TickLoop.new(_scfg, 9)
	var names: Array[String] = RECORDED.duplicate()
	names.append_array(EventRecorder.TIME_EVENTS)
	var rec: EventRecorder = EventRecorder.new(loop.bus, names)
	var artist: ArtistSystem = ArtistSystem.new(_acfg, loop.bus)
	assert_true(loop.register_system("artist", artist.update, artist.snapshot, artist.restore))
	var id: String = _id_of("local")
	loop.bus.publish("artist.book_requested", {"artist_id": id})
	loop.advance(0)
	assert_true(artist.has_pending(), "경계에서 economy 응답 없음 → 대기")
	assert_eq(rec.count("artist.booking_rejected"), 0, "advance(0) 은 단계 2 를 돌리지 않는다")
	loop.advance(1)
	assert_push_warning_count(1, "H5 push_warning 1회")
	assert_false(artist.has_pending())
	assert_eq(rec.of("artist.booking_rejected"), [{"day": 1, "artist_id": id, "reason": "not_allowed"}])
	var n: Array[String] = rec.names()
	assert_true(n.find("artist.booking_rejected") < n.find("tick.advanced"), "거절은 그 틱의 tick.advanced 앞")
	assert_eq(artist.lineup_today, null)


## build → artist → economy 를 TickLoop 에 등록하면 저녁 진입 꼬리가 spec 순서(artist.md #라인업 "전달 순서")다.
func test_evening_tail_with_build_registered() -> void:
	var loop: TickLoop = TickLoop.new(_scfg, 4)
	var names: Array[String] = ["build.coverage_changed", "artist.lineup_set"]
	names.append_array(EventRecorder.TIME_EVENTS)
	var rec: EventRecorder = EventRecorder.new(loop.bus, names)
	var build: BuildSystem = BuildSystem.new(_bcfg, loop.bus)
	var artist: ArtistSystem = ArtistSystem.new(_acfg, loop.bus)
	var econ: Economy = Economy.new(_ecfg, loop.bus)
	assert_true(loop.register_system("build", build.update, build.snapshot, build.restore))
	assert_true(loop.register_system("artist", artist.update, artist.snapshot, artist.restore))
	assert_true(loop.register_system("economy", econ.update, econ.snapshot, econ.restore))
	loop.bus.publish("time.speed_requested", {"speed": 2})
	loop.bus.publish("artist.book_requested", {"artist_id": _id_of("local")})
	loop.advance(0)
	rec.clear()
	loop.advance(_scfg.phase_ticks("day"))
	var n: Array[String] = rec.names()
	var i: int = n.find("time.phase_changed")
	assert_eq(n.slice(i), ["time.phase_changed", "build.coverage_changed", "artist.lineup_set", "time.speed_changed", "tick.advanced"],
		"phase_changed → coverage_changed(sync) → lineup_set → speed_changed → tick.advanced")
	assert_eq(rec.of("build.coverage_changed")[0]["cause"], "sync")


# --- 8. 거절 우선순위(K1 → K2 → K3 → K4) ---------------------------------------------

func test_reject_precedence_k2_k3_k4() -> void:
	var local_id: String = _id_of("local")
	var other: String = _id_of("local", 1)
	var rookie: String = _id_of("rookie")
	var u: Array = _unit()
	var artist: ArtistSystem = u[1]
	var rec: EventRecorder = u[3]
	(u[0] as EventBus).publish("artist.book_requested", {"artist_id": local_id})
	(u[0] as EventBus).dispatch_commands()
	assert_eq(artist.lineup_today, local_id)
	# K3 가 K4 보다 먼저: 라인업이 있으면 명성 부족 rookie 도 already_booked.
	assert_eq(artist.check_book(rookie), "already_booked", "K3 > K4 (check_book)")
	rec.clear()
	(u[0] as EventBus).publish("artist.book_requested", {"artist_id": rookie})
	(u[0] as EventBus).dispatch_commands()
	assert_eq(rec.of("artist.booking_rejected")[0]["reason"], "already_booked", "K3 > K4 (이벤트)")
	# K2 가 K3 보다 먼저: 라인업이 있어도 저녁이면 not_allowed.
	_phase(u[0], "day", "evening", 1)
	assert_eq(artist.check_book(other), "not_allowed", "K2 > K3 (check_book)")
	assert_eq(artist.check_book(rookie), "not_allowed", "K2 > K4 (check_book)")
	rec.clear()
	(u[0] as EventBus).publish("artist.book_requested", {"artist_id": other})
	(u[0] as EventBus).dispatch_commands()
	assert_eq(rec.of("artist.booking_rejected")[0]["reason"], "not_allowed", "K2 > K3 (이벤트)")
	# K1 이 K2 보다 먼저는 test_artist_system.test_reject_unknown_artist 가 본다.
