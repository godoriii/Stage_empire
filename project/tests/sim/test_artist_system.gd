extends GutTest
## SE-033 — ArtistSystem. docs/gdd/artist.md#수용-기준 AR2~AR10 과 티켓 AC1~AC6 을 옮겼다.
## 기대 수치는 artist.json(grades·reference_scenarios·show_grades)·economy.json(guarantee_by_grade)에서 읽고, 아티스트 id 는
## ArtistConfig.artist_ids() 에서 등급으로 고른다(id·명단 수 리터럴 없음). 이벤트 이름·reason·등급 id 는 리터럴로 단언한다.
## 공통 전제: ArtistSystem 을 Economy 보다 먼저 같은 버스에 구독(system_order: artist → economy). 단위 케이스는
## time.*·show.ended·reputation.changed 를 테스트가 직접 발행하고, AR2·AR5·AR9·AR10(b)는 TickLoop 으로 구동한다.

const RECORDED: Array[String] = [
	"economy.charge_proposed", "economy.cash_changed", "economy.charge_resolved",
	"artist.booked", "artist.booking_rejected", "artist.lineup_set", "artist.grown",
]
const ARTIST_EVENTS: Array[String] = ["artist.booked", "artist.booking_rejected", "artist.lineup_set", "artist.grown"]
const HANDSHAKE_OK: Array[String] = [
	"economy.charge_proposed", "economy.cash_changed", "economy.charge_resolved", "artist.booked",
]

var _acfg: ArtistConfig
var _ecfg: EconomyConfig
var _scfg: SimConfig


func before_all() -> void:
	_acfg = ArtistConfig.load()
	_ecfg = EconomyConfig.load()
	_scfg = SimConfig.load()


# --- 도우미 -------------------------------------------------------------------

## [bus, artist, econ, rec]. artist 를 economy 보다 먼저 구독시킨다. with_economy=false 면 econ 은 null.
func _unit(with_economy: bool = true) -> Array:
	var bus: EventBus = EventBus.new()
	var rec: EventRecorder = EventRecorder.new(bus, RECORDED)
	var artist: ArtistSystem = ArtistSystem.new(_acfg, bus)
	var econ: Economy = Economy.new(_ecfg, bus) if with_economy else null
	return [bus, artist, econ, rec]


## [loop, artist, econ, rec] — 둘 다 훅과 함께 등록. rec 은 RECORDED + 시간 이벤트.
func _looped(seed_value: int = 42) -> Array:
	var loop: TickLoop = TickLoop.new(_scfg, seed_value)
	var names: Array[String] = RECORDED.duplicate()
	names.append_array(EventRecorder.TIME_EVENTS)
	var rec: EventRecorder = EventRecorder.new(loop.bus, names)
	var artist: ArtistSystem = ArtistSystem.new(_acfg, loop.bus)
	var econ: Economy = Economy.new(_ecfg, loop.bus)
	assert_true(loop.register_system("artist", artist.update, artist.snapshot, artist.restore), "artist 등록")
	assert_true(loop.register_system("economy", econ.update, econ.snapshot, econ.restore), "economy 등록")
	return [loop, artist, econ, rec]


func _book(bus: EventBus, id: Variant) -> void:
	bus.publish("artist.book_requested", {"artist_id": id})
	bus.dispatch_commands()


func _phase(bus: EventBus, from: String, to: String, day: int) -> void:
	bus.publish("time.phase_changed", {"from": from, "to": to, "day": day, "tick": 0})


func _show(bus: EventBus, day: Variant, id: Variant, grade: Variant) -> void:
	bus.publish("show.ended", {"day": day, "artist_id": id, "grade": grade})


func _rep(bus: EventBus, total: Variant) -> void:
	bus.publish("reputation.changed", {"total": total})


## 섭외 → 저녁 → 공연 → show.ended → 다음 날 낮. 섭외 결과 이벤트 이름을 돌려준다.
func _play_day(bus: EventBus, artist: ArtistSystem, id: String, show_grade: String) -> String:
	var d: int = artist.day
	_book(bus, id)
	var out: String = "booked" if artist.lineup_today == id else "rejected"
	_phase(bus, "day", "evening", d)
	_phase(bus, "evening", "show", d)
	_show(bus, d, id, show_grade)
	bus.publish("time.day_started", {"day": d + 1})
	_phase(bus, "show", "day", d + 1)
	return out


## 등급이 grade 인 첫 아티스트 id(데이터 행 순서).
func _id_of(grade: String, nth: int = 0) -> String:
	var n: int = 0
	for id: String in _acfg.artist_ids():
		if _acfg.artist(id)["grade"] == grade:
			if n == nth:
				return id
			n += 1
	fail_test("등급 %s 의 %d번째 아티스트가 없다" % [grade, nth])
	return ""


## 시나리오 시작값(grade, popularity, skill)과 같은 실제 아티스트 id. 없으면 "".
func _id_matching(sc: Dictionary) -> String:
	for id: String in _acfg.artist_ids():
		var a: Dictionary = _acfg.artist(id)
		if a["grade"] == sc["grade"] and a["popularity"] == sc["popularity"] and a["skill"] == sc["skill"]:
			return id
	return ""


func _hash(sys: Object) -> String:
	return JSON.stringify(sys.call("snapshot"), "", true)


func _rt(v: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(v))


func _set_cash(econ: Economy, cash: int) -> void:
	var s: Dictionary = econ.snapshot()
	s["cash"] = cash
	assert_true(econ.restore(s), "economy 현금 설정")


func _set_bankrupt(econ: Economy) -> void:
	var s: Dictionary = econ.snapshot()
	s["bankrupt"] = true
	assert_true(econ.restore(s), "economy 파산 설정")


func _economy_events(rec: EventRecorder) -> int:
	var n: int = 0
	for nm: String in rec.names():
		if nm.begins_with("economy."):
			n += 1
	return n


## 거절 1건만 났는지 + 페이로드 + 상태·현금 불변.
func _assert_reject(u: Array, payload: Dictionary, reason: String, expect_id: Variant, ahash: String, ehash: String, label: String) -> void:
	var rec: EventRecorder = u[3]
	rec.clear()
	u[0].publish("artist.book_requested", payload)
	(u[0] as EventBus).dispatch_commands()
	assert_eq(rec.count("artist.booking_rejected"), 1, label + ": booking_rejected 1건")
	assert_eq(rec.count("artist.booked"), 0, label + ": booked 0")
	var r: Array = rec.of("artist.booking_rejected")
	if not r.is_empty():
		assert_eq(r[0], {"day": (u[1] as ArtistSystem).day, "artist_id": expect_id, "reason": reason}, label + ": 페이로드")
	assert_eq(_hash(u[1]), ahash, label + ": artist 상태 불변")
	if u[2] != null:
		assert_eq(_hash(u[2]), ehash, label + ": economy 상태(현금) 불변")


# --- AR2 / AC1 섭외 성공 -----------------------------------------------------------

func test_book_success_handshake() -> void:
	var l: Array = _looped(1)
	var loop: TickLoop = l[0]
	var artist: ArtistSystem = l[1]
	var econ: Economy = l[2]
	var rec: EventRecorder = l[3]
	var id: String = _id_of("local")
	var amount: int = _ecfg.guarantee("local")
	var cash0: int = econ.cash
	var led0: int = int(econ.ledger["guarantee"])
	assert_eq(artist.check_book(id), "", "check_book 통과")
	loop.bus.publish("artist.book_requested", {"artist_id": id})
	loop.advance(0)
	var names: Array = []
	for nm: String in rec.names():
		if RECORDED.has(nm):
			names.append(nm)
	assert_eq(names, Array(HANDSHAKE_OK), "이벤트 열 proposed → cash_changed → resolved → booked")
	var rid: String = "artist:book:1:" + id
	assert_eq(rec.of("economy.charge_proposed")[0], {"request_id": rid, "reason": "guarantee", "amount": amount})
	var cc: Dictionary = rec.of("economy.cash_changed")[0]
	assert_eq(cc["reason"], "guarantee")
	assert_eq(cc["delta"], -amount)
	var res: Dictionary = rec.of("economy.charge_resolved")[0]
	assert_eq(res["approved"], true)
	assert_eq(res["request_id"], rid)
	assert_eq(rec.of("artist.booked")[0], {"day": 1, "artist_id": id, "grade": "local", "guarantee": amount})
	assert_eq(econ.cash, cash0 - amount, "현금 감소 = 개런티")
	assert_eq(int(econ.ledger["guarantee"]), led0 + amount, "ledger.guarantee 증가")
	assert_eq(artist.lineup_today, id)
	assert_eq(artist.booked_day, 1)
	assert_true(artist.entry(id)["discovered_here"], "discovered_here = true")
	assert_false(artist.has_pending(), "경계에서 pending 없음")


# --- AR3 / AC2 거절 5종 ----------------------------------------------------------

func test_reject_unknown_artist() -> void:
	var u: Array = _unit()
	var ah: String = _hash(u[1])
	var eh: String = _hash(u[2])
	_assert_reject(u, {"artist_id": "nobody_here"}, "unknown_artist", "nobody_here", ah, eh, "없는 id")
	assert_eq(_economy_events(u[3]), 0, "K1 거절에는 economy.* 없음")
	_assert_reject(u, {}, "unknown_artist", null, ah, eh, "artist_id 누락")
	assert_eq(_economy_events(u[3]), 0)
	_assert_reject(u, {"artist_id": 5}, "unknown_artist", 5, ah, eh, "artist_id: 5")
	assert_eq(_economy_events(u[3]), 0)
	assert_eq((u[1] as ArtistSystem).check_book(5), "unknown_artist")
	# K1 이 K2 보다 먼저: 저녁에 모르는 id 는 unknown_artist.
	_phase(u[0], "day", "evening", 1)
	ah = _hash(u[1])
	eh = _hash(u[2])
	_assert_reject(u, {"artist_id": "nobody_here"}, "unknown_artist", "nobody_here", ah, eh, "저녁 + 없는 id")


func test_reject_not_allowed() -> void:
	var u: Array = _unit()
	var id: String = _id_of("local")
	_phase(u[0], "day", "evening", 1)
	var ah: String = _hash(u[1])
	var eh: String = _hash(u[2])
	assert_eq((u[1] as ArtistSystem).check_book(id), "not_allowed")
	_assert_reject(u, {"artist_id": id}, "not_allowed", id, ah, eh, "저녁 구간")
	assert_eq(_economy_events(u[3]), 0, "K2 거절에는 economy.* 없음")
	for ph: String in ["show", "close"]:
		_phase(u[0], "evening", ph, 1)
		_assert_reject(u, {"artist_id": id}, "not_allowed", id, _hash(u[1]), _hash(u[2]), ph + " 구간")


func test_reject_already_booked() -> void:
	var u: Array = _unit()
	var artist: ArtistSystem = u[1]
	var id: String = _id_of("local")
	var other: String = _id_of("local", 1)
	_book(u[0], id)
	assert_eq(artist.lineup_today, id, "첫 섭외 성공")
	var ah: String = _hash(artist)
	var eh: String = _hash(u[2])
	assert_eq(artist.check_book(id), "already_booked")
	assert_eq(artist.check_book(other), "already_booked")
	_assert_reject(u, {"artist_id": id}, "already_booked", id, ah, eh, "같은 id 두 번째")
	assert_eq(_economy_events(u[3]), 0, "K3 거절에는 economy.* 없음")
	_assert_reject(u, {"artist_id": other}, "already_booked", other, ah, eh, "다른 id 두 번째")
	assert_eq(_economy_events(u[3]), 0)


func test_reject_grade_locked() -> void:
	var u: Array = _unit()
	var rookie: String = _id_of("rookie")
	assert_true(_acfg.unlock_reputation("rookie") > 0, "전제: rookie 해금 명성 > 0")
	var ah: String = _hash(u[1])
	var eh: String = _hash(u[2])
	assert_eq((u[1] as ArtistSystem).check_book(rookie), "grade_locked")
	_assert_reject(u, {"artist_id": rookie}, "grade_locked", rookie, ah, eh, "명성 0 에서 rookie")
	assert_eq(_economy_events(u[3]), 0, "K4 거절에는 economy.* 없음")


func test_reject_insufficient_cash() -> void:
	var u: Array = _unit()
	var econ: Economy = u[2]
	var rec: EventRecorder = u[3]
	var id: String = _id_of("local")
	var amount: int = _ecfg.guarantee("local")
	_set_cash(econ, amount - 1)
	var ah: String = _hash(u[1])
	var eh: String = _hash(econ)
	_assert_reject(u, {"artist_id": id}, "insufficient_cash", id, ah, eh, "현금 < 개런티")
	assert_eq(rec.names(), ["economy.charge_proposed", "economy.charge_resolved", "artist.booking_rejected"])
	var res: Dictionary = rec.of("economy.charge_resolved")[0]
	assert_eq(res["approved"], false)
	assert_eq(res["decline_reason"], "insufficient_cash")
	assert_eq(econ.cash, amount - 1, "현금 불변")
	assert_false((u[1] as ArtistSystem).has_pending())


# --- AR4 등급 가용·발굴 면제 -------------------------------------------------------

func test_grade_unlock_and_discovery_exemption() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var artist: ArtistSystem = u[1]
	var rec: EventRecorder = u[3]
	var rookie: String = _id_of("rookie")
	var unlock: int = _acfg.unlock_reputation("rookie")
	_rep(bus, unlock - 1)
	assert_eq(artist.reputation_total, unlock - 1)
	_assert_check_book_pure(artist, rec, rookie, "grade_locked", "명성 임계 − 1")
	_assert_reject(u, {"artist_id": rookie}, "grade_locked", rookie, _hash(artist), _hash(u[2]), "임계 − 1")
	_rep(bus, unlock)
	_assert_check_book_pure(artist, rec, rookie, "", "명성 = 임계")
	rec.clear()
	_book(bus, rookie)
	assert_eq(rec.count("artist.booked"), 1, "임계에서 rookie 섭외 성공")
	assert_eq(rec.of("artist.booked")[0]["guarantee"], _ecfg.guarantee("rookie"))
	# 잘못된 reputation.changed 는 경고 후 무시.
	_rep(bus, -1)
	_rep(bus, "x")
	assert_push_warning_count(2, "잘못된 total 경고")
	assert_eq(artist.reputation_total, unlock)

	# 별도 실행: local 을 local_top_all_rave 만큼 키워 rookie 로 승급 → 명성 0 에서도 섭외(K4 면제).
	var sc: Dictionary = _acfg.scenario("local_top_all_rave")
	var v: Array = _unit()
	var vbus: EventBus = v[0]
	var va: ArtistSystem = v[1]
	var vrec: EventRecorder = v[3]
	var id: String = _id_matching(sc)
	assert_ne(id, "", "시나리오 시작값과 같은 아티스트가 명단에 있다")
	if id == "":
		return
	for sg: String in sc["show_grades"]:
		assert_eq(_play_day(vbus, va, id, sg), "booked")
	assert_eq(va.entry(id)["grade"], sc["expected"]["grade"], "승급")
	assert_eq(va.reputation_total, 0, "명성 0")
	_assert_check_book_pure(va, vrec, id, "", "발굴 아티스트 면제")
	_assert_check_book_pure(va, vrec, rookie, "grade_locked", "발굴 안 된 rookie 는 잠김")
	vrec.clear()
	_book(vbus, id)
	assert_eq(vrec.count("artist.booked"), 1, "승급한 발굴 아티스트 섭외 성공")
	assert_eq(vrec.of("artist.booked")[0]["grade"], "rookie")
	assert_eq(vrec.of("artist.booked")[0]["guarantee"], _ecfg.guarantee("rookie"), "개런티 = rookie")


func _assert_check_book_pure(artist: ArtistSystem, rec: EventRecorder, id: String, reason: String, label: String) -> void:
	var h: String = _hash(artist)
	var n: int = rec.events.size()
	assert_eq(artist.check_book(id), reason, label + ": check_book")
	assert_eq(_hash(artist), h, label + ": check_book 상태 불변")
	assert_eq(rec.events.size(), n, label + ": check_book 이벤트 없음")


# --- AR5 / AC3 라인업 ------------------------------------------------------------

func test_lineup_set_once_per_day() -> void:
	var l: Array = _looped(3)
	var loop: TickLoop = l[0]
	var artist: ArtistSystem = l[1]
	var rec: EventRecorder = l[3]
	var id: String = _id_of("local")
	# 낮 배속 2 → 저녁 진입 클램프로 time.speed_changed 가 나게 해 순서를 본다.
	loop.bus.publish("time.speed_requested", {"speed": 2})
	loop.bus.publish("artist.book_requested", {"artist_id": id})
	loop.advance(0)
	assert_eq(artist.lineup_today, id)
	rec.clear()
	loop.advance(_scfg.phase_ticks("day"))
	assert_eq(loop.phase, "evening")
	assert_eq(rec.count("artist.lineup_set"), 1, "저녁 진입 틱에 1회")
	var names: Array[String] = rec.names()
	var i: int = names.find("time.phase_changed")
	assert_eq(names.slice(i), ["time.phase_changed", "artist.lineup_set", "time.speed_changed", "tick.advanced"],
		"phase_changed 뒤 · speed_changed·tick.advanced 앞")
	var e: Dictionary = artist.entry(id)
	assert_eq(rec.of("artist.lineup_set")[0], {
		"day": 1, "artist_id": id, "genre": _acfg.artist(id)["genre"], "grade": e["grade"],
		"popularity": e["popularity"], "skill": e["skill"],
	})
	loop.advance(_scfg.phase_ticks("evening") + _scfg.phase_ticks("show"))
	assert_eq(loop.phase, "close")
	assert_eq(rec.count("artist.lineup_set"), 1, "공연·마감에는 다시 안 남")
	assert_eq(artist.lineup_today, id, "라인업은 마감까지 유지")
	loop.bus.publish("time.next_day_requested", {})
	loop.advance(0)
	assert_eq(artist.day, 2)
	assert_eq(artist.lineup_today, null, "다음 날 라인업 초기화")
	assert_eq(artist.booked_day, 0)
	rec.clear()
	loop.advance(_scfg.phase_ticks("day"))
	assert_eq(rec.of("artist.lineup_set"), [{
		"day": 2, "artist_id": null, "genre": null, "grade": null, "popularity": 0, "skill": 0,
	}], "섭외 없는 날")


# --- AR6 / AC4 성장 ---------------------------------------------------------------

func test_growth_reference_scenarios() -> void:
	assert_true(_acfg.reference_scenarios.size() > 0)
	for sc: Dictionary in _acfg.reference_scenarios:
		var e: Dictionary = {
			"id": "scenario", "grade": sc["grade"], "popularity": sc["popularity"], "skill": sc["skill"],
			"shows_played": 0, "discovered_here": false, "relationship": 0,
		}
		var promoted_on: Variant = null
		var promotions: int = 0
		var n: int = 0
		for sg: String in sc["show_grades"]:
			n += 1
			e = _acfg.grow(e, sg)
			if e["promoted"]:
				promotions += 1
				promoted_on = n
		var ex: Dictionary = sc["expected"]
		var label: String = sc["id"]
		assert_eq(e["grade"], ex["grade"], label + ": grade")
		assert_eq(e["popularity"], ex["popularity"], label + ": popularity")
		assert_eq(e["skill"], ex["skill"], label + ": skill")
		assert_eq(e["shows_played"], ex["shows_played"], label + ": shows_played")
		assert_eq(promoted_on, ex["promoted_on_show"], label + ": promoted_on_show")
		assert_true(promotions <= 1, label + ": 승급은 최대 1회")

	# 버스: 시작값이 실제 아티스트와 같은 시나리오를 섭외 → 저녁 → show.ended 로 돌린다.
	var ran: int = 0
	for sc: Dictionary in _acfg.reference_scenarios:
		var id: String = _id_matching(sc)
		if id == "":
			continue
		ran += 1
		var u: Array = _unit()
		var artist: ArtistSystem = u[1]
		var rec: EventRecorder = u[3]
		var top: int = 0
		for g: String in _acfg.grade_ids():
			top = maxi(top, _ecfg.guarantee(g))
		_set_cash(u[2], top * (sc["show_grades"] as Array).size())
		# 승급 뒤 섭외가 K4 면제에 기대지 않게 명성을 모든 등급 임계 이상으로 둔다(변이 "K4 면제 제거"는 AR4 만 깨야 한다).
		var rep: int = 0
		for g: String in _acfg.grade_ids():
			rep = maxi(rep, _acfg.unlock_reputation(g))
		_rep(u[0], rep)
		var promoted_shows: Array = []
		var n: int = 0
		for sg: String in sc["show_grades"]:
			n += 1
			var d: int = artist.day
			var before: Dictionary = artist.entry(id)
			var want: Dictionary = _acfg.grow(before, sg)
			rec.clear()
			assert_eq(_play_day(u[0], artist, id, sg), "booked", "%s #%d 섭외" % [sc["id"], n])
			var grown: Array = rec.of("artist.grown")
			assert_eq(grown.size(), 1, "%s #%d grown 1회" % [sc["id"], n])
			if grown.is_empty():
				break
			assert_eq(grown[0], {
				"day": d, "artist_id": id, "grade": want["grade"],
				"popularity": want["popularity"], "skill": want["skill"],
				"popularity_delta": want["popularity_delta"], "skill_delta": want["skill_delta"],
				"shows_played": want["shows_played"], "promoted": want["promoted"],
			}, "%s #%d grown 페이로드" % [sc["id"], n])
			if grown[0]["promoted"]:
				promoted_shows.append(n)
		var ex: Dictionary = sc["expected"]
		assert_eq(promoted_shows, [] if ex["promoted_on_show"] == null else [ex["promoted_on_show"]],
			"%s: promoted true 는 승급한 공연에서만 1회" % sc["id"])
		var fin: Dictionary = artist.entry(id)
		assert_eq([fin["grade"], fin["popularity"], fin["skill"], fin["shows_played"]],
			[ex["grade"], ex["popularity"], ex["skill"], ex["shows_played"]], "%s: 최종 상태" % sc["id"])
	assert_true(ran > 0, "버스로 돌린 시나리오 1개 이상")


func test_growth_guards() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var artist: ArtistSystem = u[1]
	var rec: EventRecorder = u[3]
	var id: String = _id_of("local")
	var other: String = _id_of("local", 1)
	var best: String = _acfg.show_grades.back()
	_book(bus, id)
	_phase(bus, "day", "evening", 1)
	_phase(bus, "evening", "show", 1)
	var h: String = _hash(artist)
	rec.clear()
	# G1 잘못된 페이로드: 경고·무시
	_show(bus, "1", id, best)
	_show(bus, 1, id, 5)
	_show(bus, 1, 7, best)
	assert_push_warning_count(3, "G1 경고 3회")
	# G2 라인업 없는 날: 무시(경고 없음)
	_show(bus, 1, null, best)
	assert_push_warning_count(3, "G2 경고 없음")
	# G3 라인업과 다른 id·다른 날: 경고·무시
	_show(bus, 1, other, best)
	_show(bus, 2, id, best)
	assert_push_warning_count(5, "G3 경고 2회")
	# G5 공연 등급 id 아님: push_error·무시
	_show(bus, 1, id, "열광")
	assert_push_error("show_grades", "G5 push_error")
	assert_push_error_count(1)
	assert_eq(rec.events.size(), 0, "G1~G5 이벤트 0")
	assert_eq(_hash(artist), h, "G1~G5 상태 불변")
	# G6 정상 1회
	_show(bus, 1, id, best)
	assert_eq(rec.count("artist.grown"), 1, "G6 grown 1회")
	assert_eq(artist.last_grown_day, 1)
	# G4 같은 날 두 번째: 무시(경고 없음)
	var h2: String = _hash(artist)
	_show(bus, 1, id, best)
	assert_eq(rec.count("artist.grown"), 1, "G4 두 번째 무시")
	assert_eq(_hash(artist), h2, "G4 상태 불변")
	assert_push_warning_count(5, "G4 경고 없음")


# --- AR8 미응답·파산 거절 ----------------------------------------------------------

func test_pending_cleanup() -> void:
	var u: Array = _unit(false)
	var bus: EventBus = u[0]
	var artist: ArtistSystem = u[1]
	var rec: EventRecorder = u[3]
	var id: String = _id_of("local")
	var other: String = _id_of("local", 1)
	_book(bus, id)
	assert_eq(rec.names(), ["economy.charge_proposed"], "응답 없음")
	assert_true(artist.has_pending())
	# H4: 다른 사유·다른 request_id 는 무시
	var rid: String = rec.of("economy.charge_proposed")[0]["request_id"]
	bus.publish("economy.charge_resolved", {"request_id": rid, "reason": "build", "amount": 0, "approved": true, "decline_reason": "", "cash": 0})
	bus.publish("economy.charge_resolved", {"request_id": "build:place:f1", "reason": "guarantee", "amount": 0, "approved": true, "decline_reason": "", "cash": 0})
	assert_true(artist.has_pending(), "H4 무시")
	assert_eq(artist.lineup_today, null)
	# H5 update
	artist.update({})
	assert_push_warning_count(1, "H5 push_warning 1회")
	assert_eq(rec.of("artist.booking_rejected"), [{"day": 1, "artist_id": id, "reason": "not_allowed"}])
	assert_false(artist.has_pending())
	assert_eq(artist.lineup_today, null)
	assert_false(artist.entry(id)["discovered_here"], "확정 안 됨")
	artist.update({})
	assert_push_warning_count(1, "한 번만")
	# 다음 명령 시작에서도 정리(대기 제안을 덮어쓰지 않음)
	_book(bus, id)
	_book(bus, other)
	assert_push_warning_count(2)
	assert_eq(rec.count("artist.booking_rejected"), 2)
	assert_eq(rec.of("artist.booking_rejected")[1]["artist_id"], id, "앞 제안이 거절")
	assert_eq(rec.of("economy.charge_proposed")[2]["request_id"], "artist:book:1:" + other)
	# H3 invalid: push_error + not_allowed
	var rid2: String = rec.of("economy.charge_proposed")[2]["request_id"]
	bus.publish("economy.charge_resolved", {"request_id": rid2, "reason": "guarantee", "amount": -1, "approved": false, "decline_reason": "invalid", "cash": 0})
	assert_push_error("invalid", "H3 invalid push_error")
	assert_push_error_count(1)
	assert_eq(rec.of("artist.booking_rejected").back(), {"day": 1, "artist_id": other, "reason": "not_allowed"})
	assert_false(artist.has_pending())

	# economy 가 bankrupt 로 거절 → not_allowed (H3)
	var v: Array = _unit()
	_set_bankrupt(v[2])
	var vrec: EventRecorder = v[3]
	var ah: String = _hash(v[1])
	var eh: String = _hash(v[2])
	_assert_reject(v, {"artist_id": id}, "not_allowed", id, ah, eh, "파산 뒤 섭외")
	assert_eq(vrec.names(), ["economy.charge_proposed", "economy.charge_resolved", "artist.booking_rejected"])
	assert_eq(vrec.of("economy.charge_resolved")[0]["decline_reason"], "bankrupt")


# --- AR9 / AC6 결정성·난수 0 ------------------------------------------------------

## 고정 시나리오를 TickLoop 으로 돌린다. [artist.* 이벤트 JSON, artist 해시, artist 스트림 불변 여부].
func _scripted_run(seed_value: int) -> Array:
	var l: Array = _looped(seed_value)
	var loop: TickLoop = l[0]
	var artist: ArtistSystem = l[1]
	var arec: EventRecorder = EventRecorder.new(loop.bus, ARTIST_EVENTS)
	var r0: String = loop.rng.get_state()["artist"]
	var same: bool = true
	var local_id: String = _id_of("local")
	var rookie: String = _id_of("rookie")
	loop.bus.publish("artist.book_requested", {"artist_id": local_id})
	loop.advance(0)
	same = same and loop.rng.get_state()["artist"] == r0
	loop.advance(_scfg.phase_ticks("day") + _scfg.phase_ticks("evening"))
	same = same and loop.rng.get_state()["artist"] == r0
	_show(loop.bus, 1, local_id, _acfg.show_grades.back())
	_rep(loop.bus, _acfg.unlock_reputation("rookie"))
	same = same and loop.rng.get_state()["artist"] == r0
	loop.advance(_scfg.day_ticks)
	loop.bus.publish("time.next_day_requested", {})
	loop.bus.publish("artist.book_requested", {"artist_id": rookie})
	loop.advance(0)
	loop.advance(_scfg.day_ticks)
	same = same and loop.rng.get_state()["artist"] == r0
	return [arec.to_json(), _hash(artist), same]


func test_determinism_no_rng() -> void:
	var a: Array = _scripted_run(11)
	var b: Array = _scripted_run(11)
	assert_eq(a[0], b[0], "artist.* 이벤트 열 같음")
	assert_eq(a[1], b[1], "snapshot 해시 같음")
	assert_true(a[2] and b[2], "섭외·라인업·성장 전후 artist 스트림 불변")
	assert_true(a[0].contains("artist.grown") and a[0].contains("artist.lineup_set") and a[0].contains("artist.booked"),
		"시나리오가 섭외·라인업·성장을 모두 거친다")
	var c: Array = _scripted_run(12345)
	assert_eq(c[0], a[0], "시드가 달라도 artist 결과 같음(난수 0)")
	assert_eq(c[1], a[1])


# --- AR10 / AC5 스냅샷 ------------------------------------------------------------

## 섭외·성장 1회 뒤 다음 날 낮에 다시 섭외한 상태(lineup_today 있음).
func _prepared() -> Array:
	var u: Array = _unit()
	var id: String = _id_of("local")
	assert_eq(_play_day(u[0], u[1], id, _acfg.show_grades.back()), "booked")
	_book(u[0], id)
	assert_eq((u[1] as ArtistSystem).lineup_today, id)
	assert_eq((u[1] as ArtistSystem).phase, "day")
	return u


func _continue_inputs(u: Array) -> void:
	var bus: EventBus = u[0]
	var artist: ArtistSystem = u[1]
	var d: int = artist.day
	var id: String = artist.lineup_today
	_phase(bus, "day", "evening", d)
	_phase(bus, "evening", "show", d)
	_show(bus, d, id, _acfg.show_grades[2])
	bus.publish("time.day_started", {"day": d + 1})
	_phase(bus, "show", "day", d + 1)
	_rep(bus, _acfg.unlock_reputation("rookie"))
	_book(bus, _id_of("rookie"))


func test_snapshot_roundtrip_unit() -> void:
	var u: Array = _prepared()
	var artist: ArtistSystem = u[1]
	var snap: Dictionary = artist.snapshot()
	assert_eq(_hash(artist), JSON.stringify(artist.snapshot(), "", true), "SH1 두 번 같음")
	var v: Array = _unit()
	assert_true((v[1] as ArtistSystem).restore(_rt(snap)), "JSON 왕복 restore true")
	assert_true((v[2] as Economy).restore(_rt((u[2] as Economy).snapshot())))
	assert_eq(_hash(v[1]), _hash(artist), "SH6 해시 동치")
	(u[3] as EventRecorder).clear()
	(v[3] as EventRecorder).clear()
	_continue_inputs(u)
	_continue_inputs(v)
	assert_eq(_hash(v[1]), _hash(artist), "복원 후 진행 = 연속 진행")
	assert_eq((v[3] as EventRecorder).to_json(), (u[3] as EventRecorder).to_json(), "이벤트 열 같음")
	assert_true((u[3] as EventRecorder).count("artist.grown") == 1 and (u[3] as EventRecorder).count("artist.booked") == 1)


func test_snapshot_roundtrip_tickloop() -> void:
	var l: Array = _looped(7)
	var loop: TickLoop = l[0]
	var artist: ArtistSystem = l[1]
	var id: String = _id_of("local")
	loop.bus.publish("artist.book_requested", {"artist_id": id})
	loop.advance(0)
	loop.advance(_scfg.phase_ticks("day") + _scfg.phase_ticks("evening"))
	_show(loop.bus, 1, id, _acfg.show_grades.back())
	var snap: Dictionary = loop.snapshot()
	assert_eq(snap["systems"]["artist"], artist.snapshot(), "systems.artist == snapshot()")
	var m: Array = _looped(7)
	var loop2: TickLoop = m[0]
	assert_true(loop2.restore(_rt(snap)), "TickLoop restore true")
	assert_eq(JSON.stringify(loop2.snapshot(), "", true), JSON.stringify(loop.snapshot(), "", true), "왕복 해시 동치")
	var r1: EventRecorder = EventRecorder.new(loop.bus, ARTIST_EVENTS)
	var r2: EventRecorder = EventRecorder.new(loop2.bus, ARTIST_EVENTS)
	for lp: TickLoop in [loop, loop2]:
		lp.advance(_scfg.day_ticks)
		lp.bus.publish("time.next_day_requested", {})
		lp.bus.publish("artist.book_requested", {"artist_id": id})
		lp.advance(_scfg.day_ticks)
	assert_eq(JSON.stringify(loop2.snapshot(), "", true), JSON.stringify(loop.snapshot(), "", true), "advance(day_ticks) 동치")
	assert_eq(r2.to_json(), r1.to_json(), "artist.* 이벤트 열 같음")
	assert_true(r1.count("artist.booked") == 1 and r1.count("artist.lineup_set") == 1)


## 정상 스냅샷에서 한 필드만 바꾼 사본: [라벨, 사본, push_error 문구 일부].
func _bad_snapshots(good: Dictionary) -> Array:
	var out: Array = []
	var s: Dictionary
	s = good.duplicate(true); s["roster"][0]["id"] = "nobody_here"; out.append(["모르는 id", s, "RA3"])
	s = good.duplicate(true); (s["roster"] as Array).pop_back(); out.append(["명단 id 하나 누락", s, "RA3"])
	s = good.duplicate(true); s["roster"][1] = (s["roster"][0] as Dictionary).duplicate(true); out.append(["같은 id 두 번", s, "RA3"])
	s = good.duplicate(true); s["roster"][0]["popularity"] = _acfg.stat_max + 1; out.append(["popularity stat_max+1", s, "RA4"])
	s = good.duplicate(true); s["roster"][0]["skill"] = -1; out.append(["skill -1", s, "RA4"])
	s = good.duplicate(true); s["roster"][0]["grade"] = "boss"; out.append(["grade boss", s, "RA4"])
	s = good.duplicate(true); s["lineup_today"] = "nobody"; out.append(["lineup_today nobody", s, "RA5"])
	s = good.duplicate(true); s["booked_day"] = 0; out.append(["lineup 있는데 booked_day 0", s, "RA5"])
	s = good.duplicate(true); s["last_grown_day"] = int(good["day"]) + 1; out.append(["last_grown_day > day", s, "RA6"])
	s = good.duplicate(true); s["roster"][0]["discovered_here"] = 1; out.append(["discovered_here 1", s, "RA3"])
	s = good.duplicate(true); s.erase("phase"); out.append(["phase 누락", s, "RA1"])
	s = good.duplicate(true); s["booked_day"] = 1.5; out.append(["booked_day 1.5", s, "RA1"])
	s = good.duplicate(true); s["phase"] = "night"; out.append(["phase night", s, "RA2"])
	s = good.duplicate(true); s["reputation_total"] = -1; out.append(["reputation_total -1", s, "RA2"])
	s = good.duplicate(true); s["roster"][0]["relationship"] = _acfg.relationship_max + 1; out.append(["relationship 범위 밖", s, "RA4"])
	s = good.duplicate(true); s["roster"][0]["shows_played"] = -1; out.append(["shows_played -1", s, "RA4"])
	s = good.duplicate(true); s["lineup_today"] = null; out.append(["lineup null 인데 booked_day 있음", s, "RA5"])
	return out


func test_snapshot_restore_rejects() -> void:
	var u: Array = _prepared()
	var artist: ArtistSystem = u[1]
	var rec: EventRecorder = u[3]
	var good: Dictionary = artist.snapshot()
	var before: String = _hash(artist)
	rec.clear()
	var errs: int = 0
	var bads: Array = _bad_snapshots(good)
	assert_true(bads.size() >= 10)
	for b: Array in bads:
		assert_false(artist.restore(_rt(b[1])), "%s: false" % b[0])
		errs += 1
		assert_push_error(b[2], "%s: 의도한 검사(%s)" % [b[0], b[2]])
		assert_push_error_count(errs, "%s: push_error 1회" % b[0])
		assert_eq(_hash(artist), before, "%s: 상태 불변" % b[0])
	assert_eq(rec.events.size(), 0, "이벤트 0")
	# roster 순서를 뒤섞은 사본은 받아들이고 데이터 행 순서로 담는다.
	var shuffled: Dictionary = good.duplicate(true)
	(shuffled["roster"] as Array).reverse()
	assert_true(artist.restore(_rt(shuffled)), "순서 뒤섞은 roster → true")
	assert_eq(_hash(artist), before, "복원 뒤 snapshot() 이 원래와 같음")
	# TickLoop 경로: push_error 2회(시스템 + TickLoop), 양쪽 해시 불변.
	var l: Array = _looped(5)
	var loop: TickLoop = l[0]
	loop.bus.publish("artist.book_requested", {"artist_id": _id_of("local")})
	loop.advance(0)
	var lgood: Dictionary = loop.snapshot()
	var lhash: String = JSON.stringify(lgood, "", true)
	for b: Array in _bad_snapshots(lgood["systems"]["artist"]):
		var s: Dictionary = lgood.duplicate(true)
		s["systems"]["artist"] = b[1]
		assert_false(loop.restore(_rt(s)), "TickLoop %s: false" % b[0])
		errs += 2
		assert_push_error_count(errs, "TickLoop %s: push_error 2회" % b[0])
		assert_eq(JSON.stringify(loop.snapshot(), "", true), lhash, "TickLoop %s: 상태 불변" % b[0])


# --- 입력 페이로드 방어 -----------------------------------------------------------

func test_time_payload_guards() -> void:
	var u: Array = _unit(false)
	var bus: EventBus = u[0]
	var artist: ArtistSystem = u[1]
	var rec: EventRecorder = u[3]
	var h: String = _hash(artist)
	bus.publish("time.phase_changed", {"from": "day", "to": "night", "day": 1, "tick": 0})
	bus.publish("time.phase_changed", {"from": "day", "to": "evening", "tick": 0})
	bus.publish("time.day_started", {"day": "2"})
	assert_push_warning_count(3, "잘못된 time.* 경고")
	assert_eq(_hash(artist), h, "상태 불변")
	assert_eq(rec.events.size(), 0, "이벤트 0")
	assert_eq(ArtistSystem.new(_acfg, EventBus.new()).snapshot()["roster"].size(), _acfg.artist_ids().size(),
		"새 게임 roster = 명단 행 수")
