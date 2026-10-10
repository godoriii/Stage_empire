class_name AudienceHarness
extends RefCounted
## 테스트 전용(SE-034): AudienceSystem 단위·TickLoop 구성, 커버리지 페이로드, 손으로 만든 에이전트 레코드·스냅샷.
## 단언은 하지 않는다(GutTest 쪽에서). 상태 이벤트를 발행하는 것은 테스트가 audience 입력을 흉내 낼 때뿐이다.

const AUDIENCE_EVENTS: Array[String] = [
	"audience.admissions_decided", "audience.agent_moved", "audience.agent_left", "audience.day_summary",
	"economy.sales_reported",
]
## 기준 시나리오 lineup 의 artist_id 대신 쓰는 접두어(관객은 artist_id 를 검증하지 않는다).
const ARTIST_PREFIX: String = "slot_"

var acfg: AudienceConfig
var scfg: SimConfig
var bcfg: BuildConfig
var ecfg: EconomyConfig
var map: MapConfig


func _init() -> void:
	acfg = AudienceConfig.load()
	scfg = SimConfig.load()
	bcfg = BuildConfig.load()
	ecfg = EconomyConfig.load()
	map = MapConfig.load()


# --- 커버리지·라인업 페이로드 -------------------------------------------------------

## 기준 배치의 build.coverage_changed {cause:"sync"} 페이로드(Coverage.compute 그대로, blocked_cells 포함).
func coverage_payload(layout_id: String = "baseline_show") -> Dictionary:
	var placements: Array = bcfg.layout(layout_id)["placements"]
	var cov: Dictionary = Coverage.compute(bcfg.map, bcfg.furniture_table, bcfg.rate_scale, placements)
	cov["cause"] = "sync"
	return cov


## 손으로 만든 커버리지(8필드 + cause).
static func small_coverage(viewing: Array, sound: Array, sight: Array, bar: Array, blocked: Array = [], capacity: int = 10, bonus: int = 0) -> Dictionary:
	return {
		"cause": "sync", "has_stage": true, "capacity": capacity, "satisfaction_bonus_bp": bonus,
		"viewing_tiles": viewing.duplicate(true), "sound_tiles": sound.duplicate(true), "sight_tiles": sight.duplicate(true),
		"bar_tiles": bar.duplicate(true), "blocked_cells": blocked.duplicate(true),
	}


## artist.lineup_set 페이로드. lu = null 또는 {slot, genre, grade, popularity, skill}.
static func lineup_payload(day: int, lu: Variant) -> Dictionary:
	if lu == null:
		return {"day": day, "artist_id": null, "genre": null, "grade": null, "popularity": 0, "skill": 0}
	return {
		"day": day, "artist_id": ARTIST_PREFIX + String(lu["slot"]), "genre": lu["genre"], "grade": lu["grade"],
		"popularity": lu["popularity"], "skill": lu["skill"],
	}


# --- 단위 구성 ---------------------------------------------------------------------

## {bus, rng, aud, rec}. rec 은 audience 이벤트 5종 + extra.
func unit(seed_value: int = 0, extra: Array[String] = []) -> Dictionary:
	var bus: EventBus = EventBus.new()
	var names: Array[String] = AUDIENCE_EVENTS.duplicate()
	names.append_array(extra)
	var rec: EventRecorder = EventRecorder.new(bus, names)
	var rng: SeededRng = SeededRng.new(seed_value, scfg.rng_streams)
	var aud: AudienceSystem = AudienceSystem.new(acfg, bus, rng, map)
	return {"bus": bus, "rng": rng, "aud": aud, "rec": rec}


static func phase(bus: EventBus, from: String, to: String, day: int = 1) -> void:
	bus.publish("time.phase_changed", {"from": from, "to": to, "day": day, "tick": 0})


## 단위 시스템에서 시나리오대로 입장을 결정한다: 명성·가격·커버리지 → evening → lineup_set.
func decide(u: Dictionary, sc: Dictionary, cov: Dictionary, day: int = 1) -> void:
	var bus: EventBus = u["bus"]
	bus.publish("reputation.changed", {"total": sc["reputation_total"]})
	if int(sc["ticket_price"]) != (u["aud"] as AudienceSystem).ticket_price:
		bus.publish("economy.ticket_price_changed", {"price": sc["ticket_price"], "from": (u["aud"] as AudienceSystem).ticket_price})
	bus.publish("build.coverage_changed", cov)
	phase(bus, "day", "evening", day)
	bus.publish("artist.lineup_set", lineup_payload(day, sc["lineup"]))


## TickLoop 의 단계 2 ctx 와 같은 모양.
func ctx(day: int, ph: String, tip: int) -> Dictionary:
	return {
		"tick": (day - 1) * scfg.day_ticks + scfg.phase_start(ph) + tip + 1, "day": day, "phase": ph,
		"tick_in_day": scfg.phase_start(ph) + tip, "tick_in_phase": tip,
	}


## update 를 tip_from..tip_to-1 까지 부른다. on_tick(tip) 이 있으면 매 틱 뒤에 부른다.
func run(aud: AudienceSystem, ph: String, tip_from: int, tip_to: int, day: int = 1, on_tick: Callable = Callable()) -> void:
	for tip: int in range(tip_from, tip_to):
		aud.update(ctx(day, ph, tip))
		if on_tick.is_valid():
			on_tick.call(tip)


## 단위 시스템 하루: evening 전체 → show 전체(evening 진입·라인업은 호출자가 먼저).
func run_day(u: Dictionary, day: int = 1) -> void:
	var aud: AudienceSystem = u["aud"]
	run(aud, "evening", 0, scfg.phase_ticks("evening"), day)
	phase(u["bus"], "evening", "show", day)
	run(aud, "show", 0, scfg.phase_ticks("show"), day)
	phase(u["bus"], "show", "close", day)


# --- TickLoop 구성 -----------------------------------------------------------------

## {loop, build, aud, econ, artist, rec}. build·economy·audience(+artist) 를 훅과 함께 등록. lineup 이 Dictionary 면
## artist 대신 evening 진입 때 artist.lineup_set 을 발행하는 구독자를 단다(null = 라인업 없음). with_artist 면 실제
## ArtistSystem(섭외는 호출자가). layout 이 "" 이면 가구를 놓지 않는다.
func looped(seed_value: int, lineup: Variant = null, layout_id: String = "baseline_show", with_artist: bool = false, extra: Array[String] = []) -> Dictionary:
	var loop: TickLoop = TickLoop.new(scfg, seed_value)
	var bus: EventBus = loop.bus
	var names: Array[String] = AUDIENCE_EVENTS.duplicate()
	names.append_array(extra)
	var rec: EventRecorder = EventRecorder.new(bus, names)
	var build: BuildSystem = BuildSystem.new(bcfg, bus)
	var artist: ArtistSystem = ArtistSystem.new(ArtistConfig.load(), bus) if with_artist else null
	var aud: AudienceSystem = AudienceSystem.new(acfg, bus, loop.rng, map)
	var econ: Economy = Economy.new(ecfg, bus)
	loop.register_system("build", build.update, build.snapshot, build.restore)
	if artist != null:
		loop.register_system("artist", artist.update, artist.snapshot, artist.restore)
	loop.register_system("audience", aud.update, aud.snapshot, aud.restore)
	loop.register_system("economy", econ.update, econ.snapshot, econ.restore)
	if not with_artist:
		var lu: Variant = lineup
		var wbus: WeakRef = weakref(bus)   # 버스 ↔ 람다 순환 참조를 만들지 않는다
		bus.subscribe("time.phase_changed", func(p: Dictionary) -> void:
			if p.get("to") == "evening":
				(wbus.get_ref() as EventBus).publish("artist.lineup_set", lineup_payload(int(p["day"]), lu)))
	if layout_id != "":
		for p: Dictionary in bcfg.layout(layout_id)["placements"]:
			bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
			loop.advance(0)
	return {"loop": loop, "build": build, "aud": aud, "econ": econ, "artist": artist, "rec": rec}


## 기준 시나리오 하나를 TickLoop 으로 구성(명성·가격 적용, 아직 진행 전).
func scenario_loop(sc: Dictionary, seed_value: int = -1, extra: Array[String] = []) -> Dictionary:
	var l: Dictionary = looped(int(sc["seed"]) if seed_value < 0 else seed_value, sc["lineup"], sc["layout"], false, extra)
	var loop: TickLoop = l["loop"]
	loop.bus.publish("reputation.changed", {"total": sc["reputation_total"]})
	if int(sc["ticket_price"]) != (l["aud"] as AudienceSystem).ticket_price:
		loop.bus.publish("economy.ticket_price_requested", {"price": sc["ticket_price"]})
		loop.advance(0)
	return l


# --- 손으로 만든 레코드·스냅샷 --------------------------------------------------------

## 19키 에이전트 레코드. over 로 덮어쓴다.
static func agent(id: int, type_id: String, state: String, tile: Variant, over: Dictionary = {}) -> Dictionary:
	var a: Dictionary = {
		"id": id, "type": type_id, "state": state, "tile": tile, "next": null, "progress": 0, "target": null,
		"target_kind": "", "path": [], "enter_left": 0, "bar_left": 0, "bar_planned": false, "wait": 0, "blocked": 0,
		"show_ticks": 0, "sound_ticks": 0, "sight_ticks": 0, "left_early": false, "sat": -1,
	}
	for k: Variant in over:
		a[k] = over[k]
	return a


## today 스텁(입장 수 = by_type 합).
func today_stub(by_type: Dictionary, day: int = 1) -> Dictionary:
	var n: int = 0
	var by: Dictionary = {}
	var lt_by: Dictionary = {}
	for id: String in acfg.type_ids():
		by[id] = int(by_type.get(id, 0))
		n += int(by[id])
		lt_by[id] = {"left_early": 0, "satisfaction_bp": 0}
	return {
		"day": day, "admissions": n, "expected": n, "noise_bp": 0, "capped_by": "none", "has_lineup": false,
		"by_type": by, "left_early": 0, "bar_buyers": 0,
		"left_totals": {"satisfaction_bp": 0, "lineup_bp": 0, "sound_bp": 0, "sight_bp": 0, "value_bp": 0, "wait_bp": 0, "by_type": lt_by},
	}


## aud 의 현재 스냅샷에 agents·today·next_id·phase 를 넣어 복원한다. 성공 여부를 돌려준다.
func inject(aud: AudienceSystem, agents: Array, ph: String, arrivals: Array = []) -> bool:
	var s: Dictionary = aud.snapshot()
	var by: Dictionary = {}
	var last: int = 0
	for a: Dictionary in agents:
		by[a["type"]] = int(by.get(a["type"], 0)) + 1
		last = maxi(last, int(a["id"]))
	for ar: Array in arrivals:
		by[ar[1]] = int(by.get(ar[1], 0)) + 1
		last = maxi(last, int(ar[0]))
	s["agents"] = agents.duplicate(true)
	s["arrivals"] = arrivals.duplicate(true)
	s["today"] = today_stub(by)
	s["next_id"] = last + 1
	s["phase"] = ph
	return aud.restore(s)


static func rt(v: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(v))


static func hash_of(v: Variant) -> String:
	return JSON.stringify(v, "", true)


## 에이전트 id → 레코드.
static func by_id(agents: Array) -> Dictionary:
	var out: Dictionary = {}
	for a: Dictionary in agents:
		out[int(a["id"])] = a
	return out


## 표시 좌표 c(t).
func center(t: Array) -> Array:
	var p: int = acfg.pos_scale
	return [int(t[0]) * p + p / 2, int(t[1]) * p + p / 2]
