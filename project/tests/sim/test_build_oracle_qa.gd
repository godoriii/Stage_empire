extends GutTest
## SE-032 QA — 독립 오라클 차분 테스트 + B8 다중 타일 경계.
##
## fixtures/build_oracle.json 은 tools/bot/build_oracle.py 가 만든다. 그 스크립트는 GDScript 구현(project/world/)을 읽지 않고
## docs/gdd/build.md 의 규칙(G·B·D·C)만으로 파이썬에서 다시 구현한 것이다. 고정 시드 난수 명령 열(8 에피소드 × 100 명령)을
## 오라클에 돌린 단계별 결과(판정 이유·cash·커버리지 15키)를 픽스처로 두고, 같은 명령 열을 BuildSystem + Economy 에 돌려 단계마다 대조한다.
## 자금 부족은 배제(cash 1,000,000)하고 규칙 판정과 커버리지만 본다(자금 부족은 test_build_system.gd BC14).
## 픽스처 갱신: python3 tools/bot/build_oracle.py --write (데이터가 바뀌어 규칙 결과가 달라지면 다시 만든다).

const FIXTURE: String = "res://tests/sim/fixtures/build_oracle.json"
const RECORDED: Array[String] = [
	"economy.cash_changed", "build.placed", "build.rejected", "build.demolished", "build.coverage_changed",
]

var _bcfg: BuildConfig
var _ecfg: EconomyConfig


func before_all() -> void:
	_bcfg = BuildConfig.load()
	_ecfg = EconomyConfig.load()


func _unit(cash: int) -> Array:
	var bus: EventBus = EventBus.new()
	var rec: EventRecorder = EventRecorder.new(bus, RECORDED)
	var build: BuildSystem = BuildSystem.new(_bcfg, bus)
	var econ: Economy = Economy.new(_ecfg, bus)
	var s: Dictionary = econ.snapshot()
	s["cash"] = cash
	assert_true(econ.restore(s), "cash 설정")
	return [bus, build, econ, rec]


func _result(rec: EventRecorder) -> String:
	for i: int in range(rec.events.size() - 1, -1, -1):
		var e: Array = rec.events[i]
		match e[0]:
			"build.placed":
				return "placed:" + e[1]["entity_id"]
			"build.demolished":
				return "demolished:" + e[1]["entity_id"]
			"build.rejected":
				return e[1]["reason"]
	return "(none)"


func _cov_vector(cov: Dictionary, keys: Array) -> Array:
	var derived: Dictionary = {
		"sound_count": (cov["sound_tiles"] as Array).size(),
		"sight_count": (cov["sight_tiles"] as Array).size(),
		"bar_count": (cov["bar_tiles"] as Array).size(),
	}
	var out: Array = []
	for k: String in keys:
		var v: Variant = derived[k] if derived.has(k) else cov[k]
		out.append(int(v))
	return out


func test_oracle_fixture_exists_and_covers_all_reasons() -> void:
	var fx: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	assert_true(fx is Dictionary, "픽스처 로드")
	var seen: Dictionary = {}
	var steps: int = 0
	for ep: Dictionary in fx["episodes"]:
		for st: Dictionary in ep["steps"]:
			seen[String(st["result"]).split(":")[0]] = true
			steps += 1
	assert_gt(steps, 500, "단계 수")
	# 오라클이 이 명령 열로 실제로 부딪히는 판정(자금 부족·파산·구간은 제외)
	for r: String in ["placed", "demolished", "not_found", "unknown_furniture", "bad_rotation", "out_of_bounds", "blocked_tile",
			"overlap", "wall_required", "limit_reached", "path_blocked"]:
		assert_true(seen.has(r), "픽스처에 '%s' 가 있다" % r)


func test_build_system_matches_independent_oracle() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var keys: Array = fx["cov_keys"]
	var ep_i: int = 0
	var mismatches: int = 0
	for ep: Dictionary in fx["episodes"]:
		var u: Array = _unit(int(fx["big_cash"]))
		var bus: EventBus = u[0]
		var build: BuildSystem = u[1]
		var econ: Economy = u[2]
		var rec: EventRecorder = u[3]
		var cmds: Array = ep["commands"]
		var steps: Array = ep["steps"]
		assert_eq(cmds.size(), steps.size(), "명령·단계 수")
		for i: int in cmds.size():
			var c: Dictionary = cmds[i]
			rec.clear()
			if c["op"] == "place":
				bus.publish("build.place_requested", {
					"furniture_id": c["furniture_id"], "cell": [int(c["cell"][0]), int(c["cell"][1])], "rotation": int(c["rotation"]),
				})
			else:
				bus.publish("build.demolish_requested", {"entity_id": c["entity_id"]})
			bus.dispatch_commands()
			var want: Dictionary = steps[i]
			var got_result: String = _result(rec)
			var got_cov: Array = _cov_vector(build.coverage(), keys)
			var want_cov: Array = []
			for v: Variant in want["cov"]:
				want_cov.append(int(v))
			var label: String = "에피소드 %d 단계 %d %s" % [ep_i, i, JSON.stringify(c)]
			if got_result != want["result"] or econ.cash != int(want["cash"]) or got_cov != want_cov:
				mismatches += 1
				if mismatches <= 5:
					fail_test("%s: 구현 [%s, cash %d, %s] 오라클 [%s, cash %d, %s]" % [
						label, got_result, econ.cash, got_cov, want["result"], int(want["cash"]), want_cov])
		ep_i += 1
	assert_eq(mismatches, 0, "구현 == 독립 오라클 불일치 단계 수")


## B8: 다중 타일 가구는 등면 가장자리 셀마다 전부 mountable 이어야 한다(일부만 벽이면 거절).
## tier1_club 에서는 등면 이웃이 벽 + 비벽 섞이는 배치가 없다(입구 [11..12,0] 바로 아래가 완충 타일이라 buildable 이 아님) —
## 그래서 위쪽 벽의 [9,0] 또는 [10,0] 을 기둥('P', mountable 아님)으로 바꾼 맵 사본으로 확인한다(MK5 는 기둥도 walkable 아님이라 통과).
func _cfg_with_pillar_at(x: int) -> BuildConfig:
	var f: Variant = MapConfig.read_json(FurnitureConfig.DEFAULT_PATH)
	var m: Variant = MapConfig.read_json(MapConfig.DEFAULT_PATH)
	var t: Variant = MapConfig.read_json(MapConfig.TIERS_PATH)
	var e: Variant = MapConfig.read_json(BuildConfig.ECONOMY_PATH)
	var row0: String = m["tiles"][0]
	m["tiles"][0] = row0.substr(0, x) + "P" + row0.substr(x + 1)
	return BuildConfig.from_dicts(f, m, t, e)


func _check_locker(cfg: BuildConfig, cell: Array, rot: int) -> String:
	var bus: EventBus = EventBus.new()
	var build: BuildSystem = BuildSystem.new(cfg, bus)
	return build.check_place("locker", cell, rot)


func test_b8_partial_wall_multi_tile() -> void:
	var row: Dictionary = _bcfg.furniture("locker")
	assert_eq(row["footprint"], [2, 1], "전제: locker 2x1")
	assert_true(row["wall_required"], "전제: wall_required")
	# 기준: 원래 맵에서 [9,1] r180 (등면 [9,0] [10,0] 둘 다 벽) 통과.
	assert_eq(_check_locker(_bcfg, [9, 1], 180), "", "둘 다 벽")
	# [10,0] 만 기둥: 첫 이웃 [9,0] 은 벽, 둘째 [10,0] 은 기둥 → 거절 ("첫 이웃만 검사"하면 놓친다)
	var c10: BuildConfig = _cfg_with_pillar_at(10)
	assert_not_null(c10, "사본 로드")
	assert_eq(_check_locker(c10, [9, 1], 180), "wall_required", "[9,0] 벽 + [10,0] 기둥")
	# [9,0] 만 기둥: 첫 이웃이 기둥, 둘째 [10,0] 은 벽 → 거절 ("마지막 이웃만 검사"하면 놓친다)
	var c9: BuildConfig = _cfg_with_pillar_at(9)
	assert_not_null(c9, "사본 로드")
	assert_eq(_check_locker(c9, [9, 1], 180), "wall_required", "[9,0] 기둥 + [10,0] 벽")
	# 기둥에서 떨어진 위치는 그대로 통과.
	assert_eq(_check_locker(c9, [14, 1], 180), "", "다른 위치")
