extends GutTest
## SE-035 QA 추가 테스트(qa). 기존 테스트가 덮지 않는 통합 경로를 ShowDayHarness(가짜 build·audience)로 확인한다.
## - 공연 중 TickLoop 전체 스냅샷 → JSON 왕복 → 새 하네스 복원 → 남은 틱 진행 == 연속 진행(artist·show·economy·reputation 함께).
## - 해금 뒤 TickLoop 스냅샷 복원 → 다음 날 정산에서 reputation.tier_unlocked 재발행 없음.
## - 하루 전체를 돌려도 어떤 RNG 스트림도 움직이지 않는다(show·reputation 은 난수 0).
## 기대값은 데이터(tiers.json 임계, audience.json 기준 시나리오)에서 읽는다. SE-034 병합 뒤 가짜 audience 를 실제로 바꿔 한 번 더 돌려야 한다.

const NAMES: Array[String] = [
	"time.phase_changed", "artist.lineup_set", "audience.admissions_decided", "show.started", "show.skipped",
	"audience.day_summary", "show.ended", "artist.grown", "reputation.changed", "economy.sales_reported",
	"economy.day_settled", "reputation.tier_unlocked",
]

var _scfg: SimConfig
var _acfg: ArtistConfig
var _rcfg: ReputationConfig
var _t2: Dictionary
var _adm: int
var _sat: int
var _local_id: String = ""


func before_all() -> void:
	_scfg = SimConfig.load()
	_acfg = ArtistConfig.load()
	_rcfg = ReputationConfig.load()
	_t2 = _rcfg.tier_threshold(ReputationConfig.START_TIER + 1)
	for a: Dictionary in JsonUtil.int_deep(JsonUtil.read_json("res://data/audience/audience.json"))["reference_scenarios"]:
		if a["id"] == "local_top_baseline":
			_adm = a["expected"]["admissions"]
			_sat = a["expected"]["avg_satisfaction_bp_hand"]
	for id: String in _acfg.artist_ids():
		if _acfg.artist(id)["grade"] == "local" and _local_id == "":
			_local_id = id


## 해금 직전 상태(명성 임계 − 1, 현금 임계의 2배)의 하네스. seed 는 같게 만든다.
func _mk() -> ShowDayHarness:
	var h: ShowDayHarness = ShowDayHarness.new(_scfg, _acfg, EconomyConfig.load(), ShowConfig.load(), _rcfg, NAMES, _adm, _sat, 11)
	return h


func _arm(h: ShowDayHarness) -> void:
	var s: Dictionary = h.rep.snapshot()
	s["total"] = int(_t2["unlock_reputation"]) - 1
	assert_true(h.rep.restore(s))
	var es: Dictionary = h.econ.snapshot()
	es["cash"] = int(_t2["unlock_cash"]) * 2
	assert_true(h.econ.restore(es))


func _rt(v: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(v))


func _book(h: ShowDayHarness) -> void:
	h.loop.bus.publish("artist.book_requested", {"artist_id": _local_id})
	h.loop.advance(0)


func test_midshow_tickloop_restore_equals_continuous() -> void:
	var tail: int = 100   # 공연 마지막 100틱(show.ended·day_settled·tier_unlocked 가 이 안에 있다)
	var cont: ShowDayHarness = _mk()
	_arm(cont)
	_book(cont)
	cont.loop.advance(cont.day_ticks() - tail)
	assert_eq(cont.show.status, "running", "스냅샷 시점은 공연 중")
	assert_eq(cont.rec.count("show.ended"), 0)
	var snap: Variant = _rt(cont.loop.snapshot())
	var fresh: ShowDayHarness = _mk()
	fresh.set("_has_lineup", true)   # 가짜 audience 의 하네스 내부 플래그(시스템 상태가 아니다)
	assert_true(fresh.loop.restore(snap), "TickLoop 전체 복원")
	assert_eq(fresh.rec.events.size(), 0, "복원은 이벤트를 내지 않는다")
	assert_eq(JSON.stringify(fresh.loop.snapshot()), JSON.stringify(cont.loop.snapshot()), "복원 직후 전 시스템 스냅샷 동치")
	cont.rec.clear()
	cont.loop.advance(tail)
	fresh.loop.advance(tail)
	assert_eq(fresh.rec.to_json(), cont.rec.to_json(), "복원 뒤 진행의 이벤트 열 == 연속 진행")
	assert_eq(fresh.rec.count("show.ended"), 1, "show.ended 정확히 1회")
	assert_eq(fresh.rec.count("reputation.changed"), 1)
	assert_eq(fresh.rec.count("reputation.tier_unlocked"), 1, "해금 1회")
	assert_eq(JSON.stringify(fresh.loop.snapshot()), JSON.stringify(cont.loop.snapshot()), "끝 상태 동치")


func test_unlock_not_reissued_after_tickloop_restore() -> void:
	var h: ShowDayHarness = _mk()
	_arm(h)
	h.play_day(_local_id)
	assert_eq(h.rec.count("reputation.tier_unlocked"), 1)
	var snap: Variant = _rt(h.loop.snapshot())
	var fresh: ShowDayHarness = _mk()
	assert_true(fresh.loop.restore(snap))
	assert_eq(fresh.rep.unlocked_tier, ReputationConfig.START_TIER + 1, "unlocked_tier 복원")
	fresh.rec.clear()
	fresh.loop.bus.publish("time.next_day_requested", {})
	fresh.loop.advance(0)
	fresh.play_day(_local_id)
	assert_eq(fresh.rec.count("show.ended"), 1, "다음 날 공연은 정상")
	assert_eq(fresh.rec.count("economy.day_settled"), 1)
	assert_eq(fresh.rec.count("reputation.tier_unlocked"), 0, "복원 뒤 다음 정산에 재발행 없음")


func test_full_day_leaves_all_rng_streams_untouched() -> void:
	# show·reputation 은 난수 0. 하루 전체를 돌려도 (artist·economy 포함) 스트림 상태가 처음과 같아야 한다.
	var h: ShowDayHarness = _mk()
	var before: String = JSON.stringify(h.loop.rng.get_state())
	_arm(h)
	h.play_day(_local_id)
	assert_eq(h.rec.count("show.ended"), 1)
	assert_eq(JSON.stringify(h.loop.rng.get_state()), before, "전 RNG 스트림 불변")
	# 같은 시드 두 번 → 같은 이벤트 열.
	var h2: ShowDayHarness = _mk()
	_arm(h2)
	h2.play_day(_local_id)
	assert_eq(h2.rec.to_json(), h.rec.to_json(), "결정적")
