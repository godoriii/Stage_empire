class_name ShowDayHarness
extends RefCounted
## 테스트 전용(SE-035): TickLoop 에 artist·show·economy·reputation 을 실제로, build·audience 를 가짜로 등록해 하루를 돌린다.
## audience 실제 시스템(SE-034)에 의존하지 않고 이벤트 계약(events.md·audience.md)대로 가짜가 발행한다:
## - 가짜 build: time.phase_changed {to:"evening"} 수신 시 build.coverage_changed {cause:"sync", has_stage}.
## - 가짜 audience: artist.lineup_set 수신 시 audience.admissions_decided, 공연 마지막 틱 단계 2(update)에서
##   audience.day_summary → economy.sales_reported.
## 구독·등록 순서는 sim.json system_order(build, artist, audience, show, economy, reputation)를 따른다.

const EV_SUMMARY: String = "audience.day_summary"
const EV_SALES: String = "economy.sales_reported"
const EV_ADMISSIONS: String = "audience.admissions_decided"
const EV_COVERAGE: String = "build.coverage_changed"
const PHASE_EVENING: String = "evening"
const PHASE_SHOW: String = "show"

var loop: TickLoop
var artist: ArtistSystem
var show: ShowSystem
var econ: Economy
var rep: ReputationSystem
var rec: EventRecorder
var admissions: int = 0
var avg_satisfaction_bp: int = 0
var has_stage: bool = true

var _has_lineup: bool = false


func _init(scfg: SimConfig, acfg: ArtistConfig, ecfg: EconomyConfig, shcfg: ShowConfig, rcfg: ReputationConfig,
		names: Array[String], p_admissions: int, p_avg_bp: int, seed_value: int = 0) -> void:
	admissions = p_admissions
	avg_satisfaction_bp = p_avg_bp
	loop = TickLoop.new(scfg, seed_value)
	rec = EventRecorder.new(loop.bus, names)
	loop.bus.subscribe("time.phase_changed", _fake_build_on_phase)
	artist = ArtistSystem.new(acfg, loop.bus)
	loop.bus.subscribe("artist.lineup_set", _fake_audience_on_lineup)
	show = ShowSystem.new(shcfg, loop.bus)
	econ = Economy.new(ecfg, loop.bus)
	rep = ReputationSystem.new(rcfg, loop.bus)
	loop.register_system("artist", artist.update, artist.snapshot, artist.restore)
	loop.register_system("audience", _fake_audience_update)
	loop.register_system("show", show.update, show.snapshot, show.restore)
	loop.register_system("economy", econ.update, econ.snapshot, econ.restore)
	loop.register_system("reputation", rep.update, rep.snapshot, rep.restore)


## 하루 틱 수(낮 + 저녁 + 공연). close 는 홀드라 여기서 멈춘다.
func day_ticks() -> int:
	return loop.config.phase_ticks("day") + loop.config.phase_ticks(PHASE_EVENING) + loop.config.phase_ticks(PHASE_SHOW)


## 낮에 섭외 명령 → 하루 끝(close 진입)까지 진행.
func play_day(artist_id: String) -> int:
	loop.bus.publish("artist.book_requested", {"artist_id": artist_id})
	loop.advance(0)
	return loop.advance(day_ticks())


func _fake_build_on_phase(p: Dictionary) -> void:
	if p.get("to") == PHASE_EVENING:
		loop.bus.publish(EV_COVERAGE, {"cause": "sync", "has_stage": has_stage})


func _fake_audience_on_lineup(p: Dictionary) -> void:
	_has_lineup = p.get("artist_id") != null
	loop.bus.publish(EV_ADMISSIONS, {"day": p["day"], "admissions": admissions, "has_lineup": _has_lineup})


func _fake_audience_update(ctx: Dictionary) -> void:
	if ctx["phase"] != PHASE_SHOW or ctx["tick_in_phase"] != loop.config.phase_ticks(PHASE_SHOW) - 1:
		return
	loop.bus.publish(EV_SUMMARY, {
		"day": ctx["day"], "has_lineup": _has_lineup, "admissions": admissions, "audience": admissions, "left_early": 0,
		"bar_buyers": 0, "avg_satisfaction_bp": avg_satisfaction_bp, "crowd_bp": 0,
		"avg_components": {"lineup_bp": 0, "sound_bp": 0, "sight_bp": 0, "value_bp": 0, "wait_bp": 0}, "by_type": {},
	})
	loop.bus.publish(EV_SALES, {"admissions": admissions, "audience": admissions})
