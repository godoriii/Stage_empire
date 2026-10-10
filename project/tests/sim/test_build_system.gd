extends GutTest
## SE-032 — BuildSystem. docs/gdd/build.md#수용-기준 BC1~BC19, BC21~BC23, BC27~BC31 과 SE-028 리뷰 후속 A(BC32)를 1:1 로 옮겼다.
## 기대 수치는 furniture.json 행·tier1_club.json reference_layouts[].expected·economy.json 에서 읽는다(BC21 포함 — SE-044 에서
## baseline_plus_two_speakers 레이아웃으로 데이터화). 공통 전제(build.md): 새 게임, BuildSystem 과 Economy 를 system_order 순으로
## 같은 버스에 구독, 명령은 publish 후 dispatch_commands()(또는 TickLoop.advance(0)). SE-044 AC3(blocked_cells)·AC5(phase 검증) 포함.

const RECORDED: Array[String] = [
	"economy.charge_proposed", "economy.cash_changed", "economy.charge_resolved", "economy.refund_proposed",
	"economy.upkeep_reported", "build.placed", "build.rejected", "build.demolished", "build.coverage_changed",
]
const HANDSHAKE_OK: Array[String] = [
	"economy.charge_proposed", "economy.cash_changed", "economy.charge_resolved", "build.placed",
	"economy.upkeep_reported", "build.coverage_changed",
]

var _bcfg: BuildConfig
var _ecfg: EconomyConfig
var _scfg: SimConfig


func before_all() -> void:
	_bcfg = BuildConfig.load()
	_ecfg = EconomyConfig.load()
	_scfg = SimConfig.load()


# --- 도우미 -------------------------------------------------------------------

## [bus, build, econ, rec]. build 를 economy 보다 먼저 구독시킨다(system_order). econ 은 with_economy=false 면 null.
func _unit(with_economy: bool = true) -> Array:
	var bus: EventBus = EventBus.new()
	var rec: EventRecorder = EventRecorder.new(bus, RECORDED)
	var build: BuildSystem = BuildSystem.new(_bcfg, bus)
	var econ: Economy = Economy.new(_ecfg, bus) if with_economy else null
	return [bus, build, econ, rec]


## [loop, build, econ, rec] — 둘 다 훅과 함께 등록.
func _looped(seed_value: int = 42) -> Array:
	var loop: TickLoop = TickLoop.new(_scfg, seed_value)
	var rec: EventRecorder = EventRecorder.new(loop.bus, RECORDED)
	var build: BuildSystem = BuildSystem.new(_bcfg, loop.bus)
	var econ: Economy = Economy.new(_ecfg, loop.bus)
	assert_true(loop.register_system("build", build.update, build.snapshot, build.restore), "build 등록")
	assert_true(loop.register_system("economy", econ.update, econ.snapshot, econ.restore), "economy 등록")
	return [loop, build, econ, rec]


func _place(bus: EventBus, fid: Variant, cell: Variant, rot: Variant = 0) -> void:
	bus.publish("build.place_requested", {"furniture_id": fid, "cell": cell, "rotation": rot})
	bus.dispatch_commands()


func _demolish(bus: EventBus, eid: Variant) -> void:
	bus.publish("build.demolish_requested", {"entity_id": eid})
	bus.dispatch_commands()


func _phase(bus: EventBus, from: String, to: String) -> void:
	bus.publish("time.phase_changed", {"from": from, "to": to, "day": 1, "tick": 0})


## 마지막 명령의 결과: build.placed 의 entity_id 또는 build.rejected 의 reason.
func _outcome(rec: EventRecorder) -> String:
	for i: int in range(rec.events.size() - 1, -1, -1):
		var e: Array = rec.events[i]
		if e[0] == "build.placed":
			return "placed"
		if e[0] == "build.rejected":
			return e[1]["reason"]
	return "(none)"


func _last(rec: EventRecorder, name: String) -> Dictionary:
	var a: Array = rec.of(name)
	return a.back() if not a.is_empty() else {}


func _row(fid: String) -> Dictionary:
	return _bcfg.furniture(fid)


func _bhash(build: BuildSystem) -> String:
	return JSON.stringify(build.snapshot(), "", true)


func _lhash(loop: TickLoop) -> String:
	return JSON.stringify(loop.snapshot(), "", true)


func _rt(v: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(v))


func _place_layout(bus: EventBus, layout_id: String, loop: TickLoop = null) -> Array:
	var placements: Array = _bcfg.layout(layout_id)["placements"]
	for p: Dictionary in placements:
		bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
		if loop != null:
			loop.advance(0)
		else:
			bus.dispatch_commands()
	return placements


## 커버리지 + 경제 결과를 reference_layouts[].expected 의 모든 키와 대조한다(모르는 키는 실패).
func _assert_expected(cov: Dictionary, build: BuildSystem, cash: int, expected: Dictionary, label: String) -> void:
	var paid_sum: int = 0
	for inst: Dictionary in build.instances:
		paid_sum += int(inst["paid"])
	var blocked: Array = []
	for t: Array in cov["viewing_tiles"]:
		if not (cov["sight_tiles"] as Array).has(t):
			blocked.append(t)
	var derived: Dictionary = {
		"sound_count": (cov["sound_tiles"] as Array).size(),
		"sight_count": (cov["sight_tiles"] as Array).size(),
		"bar_count": (cov["bar_tiles"] as Array).size(),
		"build_cost": paid_sum,
		"cash_after": cash,
		"sight_blocked_cells": blocked,
	}
	for k: String in expected:
		if cov.has(k):
			assert_eq(cov[k], expected[k], "%s: %s" % [label, k])
		elif derived.has(k):
			assert_eq(derived[k], expected[k], "%s: %s" % [label, k])
		else:
			fail_test("%s: expected 키 '%s' 를 대조할 수 없다" % [label, k])


# --- BC1~BC19 배치·철거 판정 ----------------------------------------------------

func test_bc01_place_stage_handshake() -> void:
	var u: Array = _unit()
	var rec: EventRecorder = u[3]
	_place(u[0], "stage_small", [10, 20], 0)
	assert_eq(rec.names(), HANDSHAKE_OK, "AC2 이벤트 순서 6개")
	var row: Dictionary = _row("stage_small")
	var placed: Dictionary = _last(rec, "build.placed")
	var cells: Array = []
	for z: int in range(20, 23):
		for x: int in range(10, 14):
			cells.append([x, z])
	assert_eq(placed, {"entity_id": "f1", "furniture_id": "stage_small", "cell": [10, 20], "rotation": 0, "cells": cells, "cost": row["build_cost"]})
	assert_eq(cells.size(), 12, "12칸")
	assert_eq(_last(rec, "economy.charge_proposed"), {"request_id": "build:place:f1", "reason": "build", "amount": row["build_cost"]})
	assert_eq((u[2] as Economy).cash, _bcfg.starting_cash - int(row["build_cost"]), "cash 4,000")
	assert_eq(_last(rec, "economy.upkeep_reported"), {"total": row["upkeep_per_day"]})
	var cov: Dictionary = _last(rec, "build.coverage_changed")
	assert_eq(cov["cause"], "placed")
	assert_true(cov["has_stage"])
	cov.erase("cause")
	assert_eq(cov, (u[1] as BuildSystem).coverage(), "coverage() == 페이로드 − cause")
	assert_eq((u[2] as Economy).upkeep_per_day, row["upkeep_per_day"], "economy 가 유지비를 받았다")


func test_bc02_not_allowed_outside_day() -> void:
	var u: Array = _unit()
	var rec: EventRecorder = u[3]
	_phase(u[0], "day", "evening")
	rec.clear()
	_place(u[0], "speaker_floor", [5, 5], 0)
	assert_eq(rec.names(), ["build.rejected"])
	assert_eq(_outcome(rec), "not_allowed")
	assert_eq(rec.count("economy.charge_proposed"), 0, "지출 제안 0")


func test_bc03_invalid_payloads() -> void:
	var u: Array = _unit()
	var bus: EventBus = u[0]
	var rec: EventRecorder = u[3]
	_place(bus, "speaker_floor", "5,5", 0)
	assert_eq(_last(rec, "build.rejected"), {"action": "place", "reason": "invalid", "furniture_id": "speaker_floor", "cell": "5,5", "rotation": 0, "entity_id": null})
	bus.publish("build.place_requested", {"furniture_id": "speaker_floor", "rotation": 0})
	bus.dispatch_commands()
	assert_eq(_last(rec, "build.rejected"), {"action": "place", "reason": "invalid", "furniture_id": "speaker_floor", "cell": null, "rotation": 0, "entity_id": null})
	_place(bus, "speaker_floor", [5, 5], "0")
	assert_eq(_last(rec, "build.rejected"), {"action": "place", "reason": "invalid", "furniture_id": "speaker_floor", "cell": [5, 5], "rotation": "0", "entity_id": null})
	_place(bus, 7, [5, 5], 0)
	assert_eq(_outcome(rec), "invalid", "furniture_id 가 String 아님")
	_place(bus, "speaker_floor", [5, 5, 1], 0)
	assert_eq(_outcome(rec), "invalid", "cell 길이 3")
	assert_eq(rec.count("build.rejected"), 5)
	assert_eq(rec.count("economy.charge_proposed"), 0)


func test_bc04_unknown_furniture() -> void:
	var u: Array = _unit()
	_place(u[0], "stage_huge", [5, 5], 0)
	assert_eq(_outcome(u[3]), "unknown_furniture")


func test_bc05_bad_rotation() -> void:
	var u: Array = _unit()
	_place(u[0], "speaker_floor", [5, 5], 45)
	assert_eq(_outcome(u[3]), "bad_rotation", "45 도")
	assert_false(_row("standing_table")["rotatable"], "전제: standing_table 회전 불가")
	_place(u[0], "standing_table", [5, 5], 90)
	assert_eq(_outcome(u[3]), "bad_rotation", "회전 불가 가구 90 도")


func test_bc06_out_of_bounds() -> void:
	var u: Array = _unit()
	_place(u[0], "stage_small", [21, 5], 0)
	assert_eq(_outcome(u[3]), "out_of_bounds", "x 21..24")
	_place(u[0], "speaker_floor", [-1, 5], 0)
	assert_eq(_outcome(u[3]), "out_of_bounds", "x -1")


## SE-032-bug: 64비트 cell 좌표(int32 로 잘리면 맵 안 셀이 되는 값). 버그 티켓 표의 좌표 + int64 경계.
func _big_cells() -> Array:
	var p32: int = 1 << 32
	return [[p32 + 5, 5], [5, p32 + 5], [-p32 + 5, 5], [p32 + 11, 0], [9223372036854775807, 5], [-9223372036854775807 - 1, 5]]


func test_bug_64bit_cells_out_of_bounds() -> void:
	var u: Array = _unit()
	var build: BuildSystem = u[1]
	var rec: EventRecorder = u[3]
	# [5,5]·[11,0] 을 미리 차지해 두면, 잘린 좌표는 overlap·blocked_tile 이 되어 버그가 드러난다.
	_place(u[0], "speaker_floor", [5, 5], 0)
	assert_eq(_outcome(rec), "placed")
	var before: String = _bhash(build)
	rec.clear()
	for cell: Array in _big_cells():
		for fid: String in ["speaker_floor", "stage_small"]:
			assert_eq(build.check_place(fid, cell, 0), "out_of_bounds", "check_place %s %s" % [fid, cell])
			_place(u[0], fid, cell, 0)
			assert_eq(_last(rec, "build.rejected"), {"action": "place", "reason": "out_of_bounds", "furniture_id": fid, "cell": cell, "rotation": 0, "entity_id": null}, "명령 %s %s" % [fid, cell])
	assert_eq(rec.count("build.placed"), 0)
	assert_eq(rec.count("economy.charge_proposed"), 0, "지출 제안 0")
	assert_eq(_bhash(build), before, "instances 불변")


func test_bug_64bit_cells_restore_rs4() -> void:
	var u: Array = _unit()
	var build: BuildSystem = u[1]
	_place(u[0], "stage_small", [10, 20], 0)
	_place(u[0], "speaker_floor", [5, 5], 0)
	var good: Dictionary = build.snapshot()
	var before: String = _bhash(build)
	var rec: EventRecorder = u[3]
	rec.clear()
	var errs: int = 0
	var p53: int = 1 << 53
	for cell: Array in _big_cells():
		var s: Dictionary = good.duplicate(true)
		s["instances"][1]["cell"] = cell
		assert_false(build.restore(s), "RS4 %s → false" % [cell])
		errs += 1
		assert_push_error("RS4", "RS4 %s: 의도한 검사" % [cell])
		assert_push_error_count(errs, "RS4 %s: push_error 1회" % [cell])
		assert_eq(_bhash(build), before, "RS4 %s: 상태 불변" % [cell])
		# JSON 왕복: |좌표| < 2^53 은 float 로 정확해 RS4 로 거절된다. ±2^63 근처는 float 가 ±2^63 이 되어
		# JsonUtil.as_int 의 2^63 가드(SE-044)로 RS1 타입 오류가 된다(이전에는 플랫폼 정의 캐스트 뒤 RS4).
		# (범위 비교는 absi 를 쓰지 않는다: absi(INT64_MIN) 은 음수로 넘친다.)
		var exact: bool = true
		for v: int in cell:
			exact = exact and v > -p53 and v < p53
		assert_false(build.restore(_rt(s)), "%s JSON 왕복 → false" % [cell])
		errs += 1
		assert_push_error("RS4" if exact else "RS1", "%s JSON 왕복: %s" % [cell, "RS4" if exact else "RS1 (2^63 가드)"])
		assert_push_error_count(errs)
		assert_eq(_bhash(build), before, "%s JSON 왕복: 상태 불변" % [cell])
	assert_eq(rec.events.size(), 0, "이벤트 0")


func test_bc07_blocked_tile() -> void:
	var u: Array = _unit()
	for c: Array in [[7, 8], [11, 1], [0, 5], [11, 0]]:
		_place(u[0], "speaker_floor", c, 0)
		assert_eq(_outcome(u[3]), "blocked_tile", "%s" % [c])
	assert_eq((u[3] as EventRecorder).count("build.rejected"), 4)


func test_bc08_overlap() -> void:
	var u: Array = _unit()
	_place(u[0], "stage_small", [10, 20], 0)
	_place(u[0], "speaker_floor", [11, 21], 0)
	assert_eq(_outcome(u[3]), "overlap")


func test_bc09_wall_required() -> void:
	var u: Array = _unit()
	var steps: Array = [
		["poster_board", [5, 5], 0, "wall_required"],
		["poster_board", [5, 22], 0, "placed"],
		["poster_board", [5, 1], 0, "wall_required"],
		["poster_board", [5, 1], 180, "placed"],
		["poster_board", [7, 9], 180, "wall_required"],
		["toilet_booth", [1, 21], 0, "placed"],
		["toilet_booth", [1, 19], 90, "wall_required"],
		["toilet_booth", [1, 19], 270, "placed"],
	]
	for s: Array in steps:
		_place(u[0], s[0], s[1], s[2])
		assert_eq(_outcome(u[3]), s[3], "%s %s r%d" % [s[0], s[1], s[2]])
	assert_eq(_last(u[3], "build.placed")["cells"], [[1, 19], [2, 19]], "[1,19] r270 점유")


func test_bc10_limit_reached() -> void:
	var u: Array = _unit()
	_place(u[0], "stage_small", [10, 20], 0)
	_place(u[0], "stage_medium", [2, 2], 0)
	assert_eq(_outcome(u[3]), "limit_reached")


func test_bc11_path_blocked_isolates_corner() -> void:
	var u: Array = _unit()
	_place(u[0], "speaker_floor", [2, 1], 0)
	assert_eq(_outcome(u[3]), "placed")
	_place(u[0], "speaker_floor", [1, 2], 0)
	assert_eq(_outcome(u[3]), "path_blocked", "[1,1] 이 갇힌다(B10 (a))")


func test_bc12_path_blocked_cuts_room() -> void:
	var u: Array = _unit()
	_place(u[0], "bench", [11, 2], 0)
	assert_eq(_outcome(u[3]), "placed")
	_place(u[0], "speaker_floor", [10, 1], 0)
	assert_eq(_outcome(u[3]), "placed")
	_place(u[0], "speaker_floor", [13, 1], 0)
	assert_eq(_outcome(u[3]), "path_blocked", "입구·완충만 남고 방이 끊긴다")


func test_bc13_path_blocked_stage_front_row() -> void:
	var u: Array = _unit()
	_place(u[0], "stage_small", [10, 20], 0)
	_place(u[0], "bench", [10, 19], 0)
	assert_eq(_outcome(u[3]), "placed")
	_place(u[0], "bench", [12, 19], 0)
	assert_eq(_outcome(u[3]), "path_blocked", "무대 앞 행 [10..13,19] 이 다 막힘(B10 (b))")
	# (b) 는 무대를 놓을 때도 걸린다: 앞 행이 벽(z=0)인 무대.
	var v: Array = _unit()
	_place(v[0], "stage_small", [2, 1], 0)
	assert_eq(_outcome(v[3]), "path_blocked", "앞 행이 벽뿐인 무대")


func test_bc14_insufficient_cash() -> void:
	var u: Array = _unit()
	var build: BuildSystem = u[1]
	var econ: Economy = u[2]
	var rec: EventRecorder = u[3]
	var s: Dictionary = econ.snapshot()
	s["cash"] = 100
	assert_true(econ.restore(s))
	var before: String = _bhash(build)
	_place(u[0], "bar_counter", [2, 2], 0)
	assert_eq(rec.names(), ["economy.charge_proposed", "economy.charge_resolved", "build.rejected"])
	var res: Dictionary = _last(rec, "economy.charge_resolved")
	assert_false(res["approved"])
	assert_eq(res["decline_reason"], "insufficient_cash")
	assert_eq(_last(rec, "build.rejected"), {"action": "place", "reason": "insufficient_cash", "furniture_id": "bar_counter", "cell": [2, 2], "rotation": 0, "entity_id": null})
	assert_eq(_bhash(build), before, "instances·next_entity 불변")
	assert_eq(econ.cash, 100, "cash 불변")


func test_bc15_bankrupt() -> void:
	var u: Array = _unit()
	var econ: Economy = u[2]
	var s: Dictionary = econ.snapshot()
	s["bankrupt"] = true
	assert_true(econ.restore(s))
	_place(u[0], "speaker_floor", [5, 5], 0)
	assert_eq(_outcome(u[3]), "bankrupt")
	assert_eq((u[1] as BuildSystem).instances.size(), 0)


func test_bc16_demolish_refund_chain() -> void:
	var u: Array = _unit()
	var econ: Economy = u[2]
	var rec: EventRecorder = u[3]
	var cost: int = _row("stage_small")["build_cost"]
	_place(u[0], "stage_small", [10, 20], 0)
	rec.clear()
	_demolish(u[0], "f1")
	assert_eq(rec.names(), ["build.demolished", "economy.refund_proposed", "economy.upkeep_reported", "build.coverage_changed", "economy.cash_changed"])
	var dem: Dictionary = _last(rec, "build.demolished")
	assert_eq(dem["entity_id"], "f1")
	assert_eq(dem["base_amount"], cost)
	assert_eq((dem["cells"] as Array).size(), 12)
	assert_eq(_last(rec, "economy.refund_proposed"), {"request_id": "build:demolish:f1", "reason": "demolish", "base_amount": cost})
	assert_eq(_last(rec, "economy.upkeep_reported"), {"total": 0})
	var cov: Dictionary = _last(rec, "build.coverage_changed")
	assert_eq(cov["cause"], "demolished")
	assert_false(cov["has_stage"])
	var refund: int = cost * _bcfg.demolish_refund_rate_bp / _bcfg.rate_scale
	assert_eq(_last(rec, "economy.cash_changed")["delta"], refund, "환불 700")
	assert_eq(econ.cash, _bcfg.starting_cash - cost + refund, "cash 4,700")
	assert_eq((u[1] as BuildSystem).coverage(), Coverage.compute(_bcfg.map, _bcfg.furniture_table, _bcfg.rate_scale, []), "빈 방 커버리지로 돌아감")


func test_bc17_demolish_rejects() -> void:
	var u: Array = _unit()
	var rec: EventRecorder = u[3]
	_place(u[0], "stage_small", [10, 20], 0)
	_demolish(u[0], "f1")
	_demolish(u[0], "f1")
	assert_eq(_last(rec, "build.rejected"), {"action": "demolish", "reason": "not_found", "furniture_id": null, "cell": null, "rotation": null, "entity_id": "f1"})
	_demolish(u[0], "f99")
	assert_eq(_outcome(rec), "not_found")
	_demolish(u[0], 5)
	assert_eq(_last(rec, "build.rejected"), {"action": "demolish", "reason": "invalid", "furniture_id": null, "cell": null, "rotation": null, "entity_id": 5})
	(u[0] as EventBus).publish("build.demolish_requested", {})
	(u[0] as EventBus).dispatch_commands()
	assert_eq(_last(rec, "build.rejected")["reason"], "invalid", "키 없음")
	assert_eq(_last(rec, "build.rejected")["entity_id"], null)


func test_bc18_demolish_not_allowed_in_show() -> void:
	var u: Array = _unit()
	var rec: EventRecorder = u[3]
	_place(u[0], "stage_small", [10, 20], 0)
	_phase(u[0], "evening", "show")
	_demolish(u[0], "f1")
	assert_eq(_last(rec, "build.rejected"), {"action": "demolish", "reason": "not_allowed", "furniture_id": "stage_small", "cell": [10, 20], "rotation": 0, "entity_id": "f1"})
	assert_eq((u[1] as BuildSystem).instances.size(), 1, "인스턴스 유지")
	assert_eq(rec.count("economy.refund_proposed"), 0)


func test_bc19_entity_numbers_not_reused() -> void:
	var u: Array = _unit()
	_place(u[0], "stage_small", [10, 20], 0)
	_demolish(u[0], "f1")
	_place(u[0], "speaker_floor", [5, 5], 0)
	assert_eq(_last(u[3], "build.placed")["entity_id"], "f2")
	# 거절된 배치는 번호를 쓰지 않는다.
	_place(u[0], "speaker_floor", [0, 5], 0)
	assert_eq(_outcome(u[3]), "blocked_tile")
	_place(u[0], "speaker_floor", [6, 5], 0)
	assert_eq(_last(u[3], "build.placed")["entity_id"], "f3")
	assert_eq((u[1] as BuildSystem).next_entity, 4)


# --- AC2 E5·H4 -----------------------------------------------------------------

func test_ac2_second_command_sees_updated_cash() -> void:
	var u: Array = _unit()
	var econ: Economy = u[2]
	var cost: int = _row("speaker_floor")["build_cost"]
	var s: Dictionary = econ.snapshot()
	s["cash"] = cost
	assert_true(econ.restore(s))
	var bus: EventBus = u[0]
	bus.publish("build.place_requested", {"furniture_id": "speaker_floor", "cell": [5, 5], "rotation": 0})
	bus.publish("build.place_requested", {"furniture_id": "speaker_floor", "cell": [6, 5], "rotation": 0})
	assert_eq(bus.dispatch_commands(), 2, "같은 경계에서 명령 2개")
	var rec: EventRecorder = u[3]
	assert_eq(rec.names(), HANDSHAKE_OK + ["economy.charge_proposed", "economy.charge_resolved", "build.rejected"], "첫 명령 연쇄가 끝난 뒤 두 번째")
	assert_eq(_outcome(rec), "insufficient_cash", "두 번째는 갱신된 cash 0 으로 판정")
	assert_eq(_last(rec, "economy.charge_proposed")["request_id"], "build:place:f2")
	assert_eq(econ.cash, 0)


func test_h2_h4_charge_resolved_matching() -> void:
	var u: Array = _unit(false)
	var bus: EventBus = u[0]
	var build: BuildSystem = u[1]
	var rec: EventRecorder = u[3]
	_place(bus, "speaker_floor", [5, 5], 0)
	assert_eq(rec.names(), ["economy.charge_proposed"], "economy 없음: 응답 대기")
	bus.publish("economy.charge_resolved", {"request_id": "build:place:f1", "reason": "guarantee", "amount": 200, "approved": true, "decline_reason": "", "cash": 0})
	bus.publish("economy.charge_resolved", {"request_id": "other", "reason": "build", "amount": 200, "approved": true, "decline_reason": "", "cash": 0})
	assert_eq(build.instances.size(), 0, "H4: reason·request_id 불일치는 무시")
	bus.publish("economy.charge_resolved", {"request_id": "build:place:f1", "reason": "build", "amount": 150, "approved": true, "decline_reason": "", "cash": 0})
	assert_eq(build.instances.size(), 1, "H2")
	assert_eq(build.instances[0]["paid"], 150, "paid = 승인 금액")
	assert_eq(_last(rec, "build.placed")["cost"], 150)
	# 대기 없는 응답은 무시.
	bus.publish("economy.charge_resolved", {"request_id": "build:place:f2", "reason": "build", "amount": 1, "approved": true, "decline_reason": "", "cash": 0})
	assert_eq(build.instances.size(), 1)
	# H3 의 그 밖 decline → charge_invalid
	_place(bus, "speaker_floor", [6, 5], 0)
	bus.publish("economy.charge_resolved", {"request_id": "build:place:f2", "reason": "build", "amount": 200, "approved": false, "decline_reason": "invalid", "cash": 0})
	assert_eq(_outcome(rec), "charge_invalid")


# --- 기준 배치 ------------------------------------------------------------------

## BC21: reference_layouts[baseline_plus_two_speakers] 8개를 명령으로 배치 → expected 전 키(SE-044, 리터럴 없음).
func test_bc21_two_more_speakers() -> void:
	var u: Array = _unit()
	var rec: EventRecorder = u[3]
	var placements: Array = _place_layout(u[0], "baseline_plus_two_speakers")
	assert_eq(rec.count("build.placed"), placements.size(), "8개 모두 placed")
	assert_eq(rec.count("build.rejected"), 0)
	var expected: Dictionary = _bcfg.layout("baseline_plus_two_speakers")["expected"]
	var last: Dictionary = _last(rec, "build.coverage_changed")
	last.erase("cause")
	assert_eq(last, (u[1] as BuildSystem).coverage(), "마지막 coverage_changed == coverage()")
	_assert_expected(last, u[1], (u[2] as Economy).cash, expected, "baseline_plus_two_speakers")
	assert_gt(expected["sound_bp"], _bcfg.layout("baseline_show")["expected"]["sound_bp"], "스피커가 음향을 올린다")


func test_bc22_empty_room() -> void:
	var u: Array = _unit()
	var layout: Dictionary = _bcfg.layout("empty_room")
	assert_eq((layout["placements"] as Array).size(), 0)
	_assert_expected((u[1] as BuildSystem).coverage(), u[1], (u[2] as Economy).cash, layout["expected"], "empty_room")


func test_bc23_baseline_show() -> void:
	var u: Array = _unit()
	var rec: EventRecorder = u[3]
	var placements: Array = _place_layout(u[0], "baseline_show")
	var placed: Array = rec.of("build.placed")
	assert_eq(placed.size(), placements.size(), "6개 모두 placed")
	for i: int in placed.size():
		assert_eq(placed[i]["entity_id"], "f%d" % (i + 1))
	assert_eq(rec.count("build.rejected"), 0)
	var expected: Dictionary = _bcfg.layout("baseline_show")["expected"]
	var last: Dictionary = _last(rec, "build.coverage_changed")
	last.erase("cause")
	assert_eq(last, (u[1] as BuildSystem).coverage(), "마지막 coverage_changed == coverage()")
	_assert_expected(last, u[1], (u[2] as Economy).cash, expected, "baseline_show")
	assert_eq(_last(rec, "economy.upkeep_reported")["total"], expected["upkeep_per_day"], "마지막 upkeep_reported 123")


# --- 결정성·스냅샷 ---------------------------------------------------------------

func test_bc27_rng_untouched() -> void:
	var l: Array = _looped(7)
	var loop: TickLoop = l[0]
	var before: Dictionary = loop.rng.get_state()
	_place_layout(loop.bus, "baseline_show", loop)
	loop.bus.publish("build.demolish_requested", {"entity_id": "f2"})
	loop.advance(1)
	assert_eq((l[1] as BuildSystem).instances.size(), 5, "배치·철거가 실제로 일어났다")
	assert_eq(loop.rng.get_state(), before, "모든 스트림(world 포함) 불변")


func test_bc28_snapshot_roundtrip() -> void:
	var a: Array = _looped(11)
	var loop_a: TickLoop = a[0]
	var placements: Array = _place_layout(loop_a.bus, "baseline_show", loop_a)
	var snap: Dictionary = loop_a.snapshot()
	var sb: Dictionary = snap["systems"]["build"]
	assert_eq(sb.keys(), ["instances", "next_entity", "phase"])
	assert_eq(sb["next_entity"], 7)
	assert_eq(sb["phase"], "day")
	assert_eq((sb["instances"] as Array).size(), 6)
	for i: int in placements.size():
		var inst: Dictionary = sb["instances"][i]
		var p: Dictionary = placements[i]
		assert_eq(inst, {"entity_id": "f%d" % (i + 1), "furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"], "paid": _row(p["furniture_id"])["build_cost"]})
	# SH1: 두 번 찍어도 같다. SH6: 자기 왕복.
	assert_eq(_lhash(loop_a), JSON.stringify(snap, "", true))
	var build_a: BuildSystem = a[1]
	var self_hash: String = _bhash(build_a)
	assert_true(build_a.restore(_rt(build_a.snapshot())), "SH6 자기 왕복")
	assert_eq(_bhash(build_a), self_hash)
	# JSON 왕복 → 새 루프
	var b: Array = _looped(11)
	var loop_b: TickLoop = b[0]
	var rec_b: EventRecorder = b[3]
	assert_true(loop_b.restore(_rt(snap)), "restore true")
	assert_eq(rec_b.events.size(), 0, "복원은 이벤트 0")
	assert_eq(_lhash(loop_b), _lhash(loop_a), "해시 동일")
	var build_b: BuildSystem = b[1]
	assert_eq(build_b.coverage(), build_a.coverage(), "coverage 재계산")
	_assert_expected(build_b.coverage(), build_b, (b[2] as Economy).cash, _bcfg.layout("baseline_show")["expected"], "복원 후")
	# 연속 진행 동치
	var rec_a: EventRecorder = a[3]
	rec_a.clear()
	for lp: TickLoop in [loop_a, loop_b]:
		lp.bus.publish("build.demolish_requested", {"entity_id": "f2"})
		lp.bus.publish("build.place_requested", {"furniture_id": "speaker_floor", "cell": [5, 10], "rotation": 0})
		lp.bus.publish("build.place_requested", {"furniture_id": "stage_medium", "cell": [2, 2], "rotation": 0})
		lp.advance(1)
	assert_eq(JSON.stringify(rec_b.events), JSON.stringify(rec_a.events), "같은 명령 열 → 같은 이벤트 열")
	assert_eq(_lhash(loop_b), _lhash(loop_a), "같은 해시")
	assert_eq(build_b.find_path([11, 0], [9, 20]), build_a.find_path([11, 0], [9, 20]), "경로도 같다")
	# close 경계 스냅샷 → phase close → place not_allowed
	loop_a.advance(_scfg.day_ticks)
	assert_eq(loop_a.phase, "close")
	var close_snap: Variant = _rt(loop_a.snapshot())
	assert_eq(close_snap["systems"]["build"]["phase"], "close")
	var c: Array = _looped(11)
	assert_true((c[0] as TickLoop).restore(close_snap))
	var build_c: BuildSystem = c[1]
	assert_eq(build_c.phase, "close")
	(c[0] as TickLoop).bus.publish("build.place_requested", {"furniture_id": "speaker_floor", "cell": [3, 3], "rotation": 0})
	(c[0] as TickLoop).advance(0)
	assert_eq(_outcome(c[3]), "not_allowed", "close 에서 복원한 Build 는 배치 거절")


## RS1~RS7 위반 사본. [라벨, 변형 함수 결과].
func _bad_snapshots(good: Dictionary) -> Array:
	var out: Array = []
	var s: Dictionary
	s = good.duplicate(true); s["instances"][0]["entity_id"] = "f01"; out.append(["RS2 앞자리 0", s])
	s = good.duplicate(true); s["instances"][1]["entity_id"] = "f-1"; out.append(["RS2 음수 번호", s])
	s = good.duplicate(true); s["next_entity"] = -1; out.append(["RS1 next_entity 음수", s])
	s = good.duplicate(true); s["next_entity"] = 2; out.append(["RS2 n ≥ next_entity", s])
	s = good.duplicate(true); s["instances"][1]["entity_id"] = "f1"; out.append(["RS2 증가 아님", s])
	s = good.duplicate(true); s["instances"][1]["furniture_id"] = "stage_huge"; out.append(["RS3 없는 furniture_id", s])
	s = good.duplicate(true); s["instances"][1]["rotation"] = 45; out.append(["RS3 회전", s])
	s = good.duplicate(true); s["instances"][1]["cell"] = [0, 5]; out.append(["RS4 벽 위", s])
	s = good.duplicate(true); s["instances"][1]["cell"] = [11, 21]; out.append(["RS5 겹침", s])
	s = good.duplicate(true)
	s["instances"].append({"entity_id": "f9", "furniture_id": "stage_small", "cell": [2, 2], "rotation": 0, "paid": 0})
	s["next_entity"] = 10
	out.append(["RS6 무대 2개", s])
	s = good.duplicate(true); s["instances"][0]["paid"] = -1; out.append(["RS7 paid 음수", s])
	s = good.duplicate(true); s["phase"] = "night"; out.append(["RS1 phase", s])
	s = good.duplicate(true); s["instances"][0].erase("paid"); out.append(["RS1 키 누락", s])
	s = good.duplicate(true); s.erase("next_entity"); out.append(["RS1 필드 누락", s])
	return out


func test_bc29_restore_rejects() -> void:
	var u: Array = _unit()
	var build: BuildSystem = u[1]
	var rec: EventRecorder = u[3]
	_place(u[0], "stage_small", [10, 20], 0)
	_place(u[0], "speaker_floor", [9, 20], 0)
	var good: Dictionary = build.snapshot()
	var before: String = _bhash(build)
	var cov_before: Dictionary = build.coverage()
	rec.clear()
	var errs: int = 0
	for b: Array in _bad_snapshots(good):
		assert_false(build.restore(_rt(b[1])), "%s: false" % b[0])
		errs += 1
		assert_push_error_count(errs, "%s: push_error 1회" % b[0])
		assert_eq(_bhash(build), before, "%s: 상태 불변" % b[0])
	assert_eq(build.coverage(), cov_before, "커버리지 불변")
	assert_eq(rec.events.size(), 0, "이벤트 0")
	# TickLoop 경로: push_error 2회(시스템 + TickLoop), 양쪽 해시 불변.
	var l: Array = _looped(3)
	var loop: TickLoop = l[0]
	_place_layout(loop.bus, "baseline_show", loop)
	var lgood: Dictionary = loop.snapshot()
	var lhash: String = _lhash(loop)
	for b: Array in _bad_snapshots(lgood["systems"]["build"]):
		var s: Dictionary = lgood.duplicate(true)
		s["systems"]["build"] = b[1]
		assert_false(loop.restore(_rt(s)), "TickLoop %s: false" % b[0])
		errs += 2
		assert_push_error_count(errs, "TickLoop %s: push_error 2회" % b[0])
		assert_eq(_lhash(loop), lhash, "TickLoop %s: 상태 불변" % b[0])


func test_bc30_evening_sync() -> void:
	var u: Array = _unit()
	var rec: EventRecorder = u[3]
	_phase(u[0], "day", "evening")
	assert_eq(rec.count("build.coverage_changed"), 1)
	var cov: Dictionary = _last(rec, "build.coverage_changed")
	assert_eq(cov["cause"], "sync")
	cov.erase("cause")
	assert_eq(cov, (u[1] as BuildSystem).coverage())
	_phase(u[0], "evening", "show")
	_phase(u[0], "show", "close")
	_phase(u[0], "close", "day")
	assert_eq(rec.count("build.coverage_changed"), 1, "다른 구간 전환에는 없음")
	# TickLoop 하루: sync 정확히 1회.
	var l: Array = _looped(5)
	(l[0] as TickLoop).advance(_scfg.day_ticks)
	assert_eq((l[3] as EventRecorder).count("build.coverage_changed"), 1, "하루에 sync 1회")


# --- SE-044 AC3: build.coverage_changed.blocked_cells ------------------------------

## placements(또는 인스턴스)의 G3 점유 셀 합집합, G6(z → x) 순서. 맵을 훑어 만든다(구현의 정렬과 독립).
func _union_cells(placements: Array) -> Array:
	var seen: Dictionary = {}
	for p: Dictionary in placements:
		for c: Array in GridOccupancy.cells_of(_row(p["furniture_id"])["footprint"], p["cell"], int(p["rotation"])):
			seen[Vector2i(c[0], c[1])] = true
	var out: Array = []
	for z: int in _bcfg.map.depth:
		for x: int in _bcfg.map.width:
			if seen.has(Vector2i(x, z)):
				out.append([x, z])
	return out


## 기준 배치 2종(baseline_show 21칸, baseline_plus_two_speakers 23칸 — 수는 데이터 placements 에서 계산)에서
## 모든 coverage_changed 의 마지막 키가 blocked_cells 이고 그 시점 설치 목록의 점유 셀 전체(G6)와 같다. 철거 뒤 줄어든다.
func test_ac3_blocked_cells_layouts_and_demolish() -> void:
	var sizes: Dictionary = {}
	for lid: String in ["baseline_show", "baseline_plus_two_speakers"]:
		var u: Array = _unit()
		var build: BuildSystem = u[1]
		var rec: EventRecorder = u[3]
		assert_eq(build.coverage()["blocked_cells"], [], "%s: 새 게임(빈 방) []" % lid)
		var placements: Array = _place_layout(u[0], lid)
		var events: Array = rec.of("build.coverage_changed")
		assert_eq(events.size(), placements.size(), "%s: 배치마다 1회" % lid)
		for i: int in events.size():
			var ev: Dictionary = events[i]
			assert_eq(ev["cause"], "placed")
			assert_eq(ev.keys().back(), "blocked_cells", "%s #%d: 마지막 키" % [lid, i])
			assert_eq(ev["blocked_cells"], _union_cells(placements.slice(0, i + 1)), "%s #%d: 점유 셀 전체(증분 아님)" % [lid, i])
		var full: Array = _union_cells(placements)
		assert_eq(build.coverage()["blocked_cells"], full, "%s: coverage() 에도 같은 키" % lid)
		sizes[lid] = full.size()
		# 철거: f2 를 빼면 그 점유 칸만큼 줄어든다.
		var removed: Dictionary = placements[1]
		rec.clear()
		_demolish(u[0], "f2")
		var dem: Dictionary = _last(rec, "build.coverage_changed")
		assert_eq(dem["cause"], "demolished")
		var rest: Array = placements.duplicate()
		rest.remove_at(1)
		assert_eq(dem["blocked_cells"], _union_cells(rest), "%s: 철거 뒤 남은 점유 셀" % lid)
		var gone: int = GridOccupancy.cells_of(_row(removed["furniture_id"])["footprint"], removed["cell"], int(removed["rotation"])).size()
		assert_eq((dem["blocked_cells"] as Array).size(), full.size() - gone, "%s: 철거한 칸 수만큼 감소" % lid)
		assert_lt((dem["blocked_cells"] as Array).size(), full.size())
	var extra: int = 0
	var more: Array = _bcfg.layout("baseline_plus_two_speakers")["placements"]
	for p: Dictionary in more.slice((_bcfg.layout("baseline_show")["placements"] as Array).size()):
		extra += GridOccupancy.cells_of(_row(p["furniture_id"])["footprint"], p["cell"], int(p["rotation"])).size()
	assert_eq(sizes["baseline_plus_two_speakers"], sizes["baseline_show"] + extra, "스피커 2개 칸만큼 많다")


## 스냅샷(JSON 왕복) 복원 직후는 이벤트가 없고, 다음 저녁 sync 페이로드에 복원 전과 같은 blocked_cells 가 실린다.
func test_ac3_blocked_cells_after_restore_sync() -> void:
	var a: Array = _looped(13)
	var loop_a: TickLoop = a[0]
	var placements: Array = _place_layout(loop_a.bus, "baseline_plus_two_speakers", loop_a)
	var want: Array = _union_cells(placements)
	assert_eq((a[1] as BuildSystem).coverage()["blocked_cells"], want, "전제: 복원 전")
	var snap: Variant = _rt(loop_a.snapshot())
	var b: Array = _looped(13)
	var loop_b: TickLoop = b[0]
	var rec_b: EventRecorder = b[3]
	assert_true(loop_b.restore(snap), "restore true")
	assert_eq(rec_b.events.size(), 0, "복원은 이벤트 0")
	assert_eq((b[1] as BuildSystem).coverage()["blocked_cells"], want, "복원 뒤 coverage() 재계산")
	loop_b.advance(_scfg.day_ticks)
	var syncs: Array = []
	for ev: Dictionary in rec_b.of("build.coverage_changed"):
		if ev["cause"] == "sync":
			syncs.append(ev)
	assert_eq(syncs.size(), 1, "다음 저녁 sync 1회")
	assert_eq(syncs[0]["blocked_cells"], want, "sync 페이로드에 점유 셀 전체")
	var cov: Dictionary = (syncs[0] as Dictionary).duplicate(true)
	cov.erase("cause")
	assert_eq(cov, (b[1] as BuildSystem).coverage(), "sync 페이로드 == coverage()")


# --- SE-044 AC5: time.phase_changed 의 모르는 구간 id ---------------------------------

func test_ac5_unknown_phase_ignored() -> void:
	var u: Array = _unit(false)   # Economy 없이 build 만(Economy 쪽은 test_economy.gd 에서 따로)
	var build: BuildSystem = u[1]
	var rec: EventRecorder = u[3]
	var stage: Dictionary = {"entity_id": "f1", "furniture_id": "stage_small", "cell": [10, 20], "rotation": 0, "paid": _row("stage_small")["build_cost"]}
	assert_true(build.restore({"instances": [stage], "next_entity": 2, "phase": "day"}), "전제: 무대 1개 상태")
	var before: String = _bhash(build)
	rec.clear()
	u[0].publish("time.phase_changed", {"from": "day", "to": "nope", "day": 1, "tick": 0})
	assert_push_error_count(1, "모르는 to → push_error 1회")
	assert_eq(build.phase, "day", "phase 불변")
	assert_eq(_bhash(build), before, "상태 불변")
	assert_eq(rec.events.size(), 0, "이벤트 0(sync 없음)")
	assert_true(build.restore(_rt(build.snapshot())), "자기 스냅샷 왕복 true(SH3)")
	assert_eq(_bhash(build), before)
	_phase(u[0], "day", "evening")
	assert_eq(build.phase, "evening", "그 뒤 정상 구간은 따라간다")
	assert_eq(rec.count("build.coverage_changed"), 1, "evening sync")


func test_bc31_charge_unresolved() -> void:
	var u: Array = _unit(false)
	var build: BuildSystem = u[1]
	var rec: EventRecorder = u[3]
	_place(u[0], "speaker_floor", [5, 5], 0)
	assert_eq(rec.names(), ["economy.charge_proposed"])
	build.update({})
	assert_push_warning_count(1, "H5 push_warning 1회")
	assert_eq(_last(rec, "build.rejected"), {"action": "place", "reason": "charge_unresolved", "furniture_id": "speaker_floor", "cell": [5, 5], "rotation": 0, "entity_id": null})
	assert_eq(build.instances.size(), 0, "instances 불변")
	assert_eq(build.next_entity, 1)
	build.update({})
	assert_push_warning_count(1, "한 번만")
	# 다음 명령이 먼저 오면 그 시작에서 정리한다(대기 제안을 덮어쓰지 않음).
	_place(u[0], "speaker_floor", [5, 5], 0)
	_place(u[0], "speaker_floor", [6, 5], 0)
	assert_push_warning_count(2)
	assert_eq(rec.count("build.rejected"), 2)


func test_bc32_check_place_is_pure() -> void:
	var l: Array = _looped(9)
	var loop: TickLoop = l[0]
	var build: BuildSystem = l[1]
	var rec: EventRecorder = l[3]
	_place_layout(loop.bus, "baseline_show", loop)
	loop.bus.publish("build.place_requested", {"furniture_id": "speaker_floor", "cell": [2, 1], "rotation": 0})
	loop.advance(0)
	var h: String = _lhash(loop)
	var bh: String = _bhash(build)
	var rng_state: Dictionary = loop.rng.get_state()
	var n_events: int = rec.events.size()
	var cov: Dictionary = build.coverage()
	var path: Array = build.path_from_entrance([5, 5])
	var results: Array = []
	var fids: Array = _bcfg.furniture_table.ids() + ["stage_huge"]
	for fid: String in fids:
		for rot: int in [0, 90, 180, 270, 45]:
			for cell: Array in [[1, 1], [5, 5], [10, 19], [20, 4], [0, 5], [22, 22], [-1, 3], [1, 21], [12, 19], [1, 2]]:
				results.append(build.check_place(fid, cell, rot))
	results.append(build.check_place("speaker_floor", [1.0, 2.0], 0))
	results.append(build.check_place("speaker_floor", [1], 0))
	assert_eq(results.size(), fids.size() * 5 * 10 + 2, "N 회 호출")
	for r: String in ["", "invalid", "unknown_furniture", "bad_rotation", "out_of_bounds", "blocked_tile", "overlap", "wall_required", "limit_reached", "path_blocked"]:
		assert_true(results.has(r), "판정 '%s' 가 섞여 있다" % r)
	assert_eq(_lhash(loop), h, "스냅샷 해시 불변")
	assert_eq(_bhash(build), bh)
	assert_eq(loop.rng.get_state(), rng_state, "RNG 불변")
	assert_eq(rec.events.size(), n_events, "이벤트 수 불변")
	assert_eq(build.coverage(), cov)
	assert_eq(build.path_from_entrance([5, 5]), path, "경로 그래프 불변")


## check_place 가 명령과 같은 판정을 낸다(B2·자금 제외). UI 미리보기 = 실제 결과.
func test_check_place_matches_command() -> void:
	var cases: Array = [
		["stage_huge", [5, 5], 0], ["speaker_floor", [5, 5], 45], ["stage_small", [21, 5], 0],
		["speaker_floor", [7, 8], 0], ["speaker_floor", [11, 21], 0], ["poster_board", [5, 5], 0],
		["stage_medium", [2, 2], 0], ["bench", [12, 19], 0], ["speaker_floor", [2, 2], 0],
	]
	var u: Array = _unit()
	var build: BuildSystem = u[1]
	_place(u[0], "stage_small", [10, 20], 0)
	_place(u[0], "bench", [10, 19], 0)
	for c: Array in cases:
		var preview: String = build.check_place(c[0], c[1], c[2])
		_place(u[0], c[0], c[1], c[2])
		var got: String = _outcome(u[3])
		assert_eq("placed" if preview == "" else preview, got, "%s" % [c])
		if got == "placed":
			_demolish(u[0], _last(u[3], "build.placed")["entity_id"])


func test_constructor_emits_nothing_and_starts_new_game() -> void:
	var bus: EventBus = EventBus.new()
	var rec: EventRecorder = EventRecorder.new(bus, RECORDED)
	var build: BuildSystem = BuildSystem.new(_bcfg, bus)
	assert_eq(rec.events.size(), 0)
	assert_eq(build.snapshot(), {"instances": [], "next_entity": 1, "phase": "day"})
	assert_eq(build.coverage()["floor_free"], _bcfg.layout("empty_room")["expected"]["floor_free"])
	var a: Dictionary = build.coverage()
	a["floor_free"] = -5
	assert_ne(build.coverage()["floor_free"], -5, "coverage() 는 사본")
