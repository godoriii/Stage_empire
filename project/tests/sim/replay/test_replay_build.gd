extends GutTest
## SE-032 리플레이 — 같은 시드·같은 명령 열 → 같은 build 이벤트 열·같은 상태 해시. 중간 스냅샷(JSON 왕복) 복원 후 이어 진행
## = 연속 진행(build.md #결정성과-rng, #스냅샷, tick.md SH6). TickLoop 에 build·economy 를 system_order 순으로 등록한다.

const RECORDED: Array[String] = [
	"time.phase_changed", "time.day_started", "economy.charge_proposed", "economy.cash_changed",
	"economy.charge_resolved", "economy.refund_proposed", "economy.upkeep_reported", "economy.day_settled",
	"build.placed", "build.rejected", "build.demolished", "build.coverage_changed",
]
const SEED: int = 20261009

var _bcfg: BuildConfig
var _ecfg: EconomyConfig
var _scfg: SimConfig


func before_all() -> void:
	_bcfg = BuildConfig.load()
	_ecfg = EconomyConfig.load()
	_scfg = SimConfig.load()


func _new_loop() -> Array:
	var loop: TickLoop = TickLoop.new(_scfg, SEED)
	var rec: EventRecorder = EventRecorder.new(loop.bus, RECORDED)
	var build: BuildSystem = BuildSystem.new(_bcfg, loop.bus)
	var econ: Economy = Economy.new(_ecfg, loop.bus)
	loop.register_system("build", build.update, build.snapshot, build.restore)
	loop.register_system("economy", econ.update, econ.snapshot, econ.restore)
	return [loop, rec, build, econ]


## 스크립트: [[명령 이름, 페이로드]...] 묶음마다 advance(n).
func _script() -> Array:
	var steps: Array = []
	var first: Array = []
	for p: Dictionary in _bcfg.layout("baseline_show")["placements"]:
		first.append(["build.place_requested", p.duplicate(true)])
	steps.append([first, 5])
	steps.append([[
		["build.place_requested", {"furniture_id": "speaker_floor", "cell": [5, 10], "rotation": 0}],
		["build.place_requested", {"furniture_id": "stage_medium", "cell": [2, 2], "rotation": 0}],
		["build.demolish_requested", {"entity_id": "f3"}],
		["build.place_requested", {"furniture_id": "exit_door", "cell": [3, 22], "rotation": 0}],
	], 10])
	steps.append([[["build.place_requested", {"furniture_id": "light_spot", "cell": [6, 6], "rotation": 0}]], _scfg.day_ticks])
	steps.append([[["time.next_day_requested", {}]], 3])
	steps.append([[
		["build.demolish_requested", {"entity_id": "f1"}],
		["build.place_requested", {"furniture_id": "stage_medium", "cell": [3, 16], "rotation": 0}],
	], 2])
	return steps


func _run(steps: Array, l: Array) -> void:
	var loop: TickLoop = l[0]
	for s: Array in steps:
		for c: Array in s[0]:
			loop.bus.publish(c[0], c[1])
		loop.advance(s[1])


func _hash(loop: TickLoop) -> String:
	return JSON.stringify(loop.snapshot(), "", true)


func test_replay_same_seed_same_stream() -> void:
	var a: Array = _new_loop()
	var b: Array = _new_loop()
	_run(_script(), a)
	_run(_script(), b)
	var ra: EventRecorder = a[1]
	assert_gt(ra.count("build.placed"), 8, "스크립트가 실제로 배치한다")
	assert_gt(ra.count("build.demolished"), 1)
	assert_eq(ra.count("build.coverage_changed") - ra.count("build.placed") - ra.count("build.demolished"), 1, "sync 1회(저녁 1번)")
	assert_eq(JSON.stringify(ra.events), JSON.stringify((b[1] as EventRecorder).events), "같은 이벤트 열")
	assert_eq(_hash(a[0]), _hash(b[0]), "같은 상태 해시")


func test_replay_snapshot_split_equals_continuous() -> void:
	var steps: Array = _script()
	for split: int in range(1, steps.size()):
		var cont: Array = _new_loop()
		_run(steps, cont)
		var first: Array = _new_loop()
		_run(steps.slice(0, split), first)
		var snap: Variant = JSON.parse_string(JSON.stringify((first[0] as TickLoop).snapshot()))
		var resumed: Array = _new_loop()
		assert_true((resumed[0] as TickLoop).restore(snap), "split %d 복원" % split)
		_run(steps.slice(split), resumed)
		assert_eq(_hash(resumed[0]), _hash(cont[0]), "split %d: 복원 후 진행 = 연속 진행" % split)
		var tail: Array = (cont[1] as EventRecorder).events.slice((first[1] as EventRecorder).events.size())
		assert_eq(JSON.stringify((resumed[1] as EventRecorder).events), JSON.stringify(tail), "split %d: 이후 이벤트 열 동일" % split)
		assert_eq((resumed[2] as BuildSystem).coverage(), (cont[2] as BuildSystem).coverage(), "split %d: 커버리지" % split)
