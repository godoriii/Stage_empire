extends GutTest
## SE-032 AC5 — TilePath(AStarGrid2D 래퍼). 입구 → 관람 타일 경로 존재, 가구 설치 뒤 경로 변경/차단, 결정성, 도달 불가 → [].

var _map: MapConfig


func before_all() -> void:
	_map = MapConfig.load()


func _assert_valid_path(p: Array, from: Array, to: Array, tp: TilePath, label: String) -> void:
	assert_false(p.is_empty(), label + ": 경로 있음")
	if p.is_empty():
		return
	if from.is_empty():
		assert_true(_map.entrances().has(p[0]), label + ": 입구에서 출발")
	else:
		assert_eq(p[0], from, label + ": 출발 포함")
	assert_eq(p.back(), to, label + ": 도착 포함")
	for i: int in p.size():
		assert_true(tp.is_passable(p[i][0], p[i][1]), "%s: %s 통과 가능" % [label, p[i]])
		if i > 0:
			assert_eq(absi(p[i][0] - p[i - 1][0]) + absi(p[i][1] - p[i - 1][1]), 1, label + ": 4방향 한 걸음(대각 금지)")


func test_entrance_to_viewing_tile() -> void:
	var tp: TilePath = TilePath.new(_map)
	var p: Array = tp.path_from_entrance([11, 12])
	_assert_valid_path(p, [11, 0], [11, 12], tp, "입구 → 중앙")
	assert_eq(p.size(), 13, "맨해튼 최단 12걸음")
	var q: Array = tp.path_from_entrance([12, 19])
	_assert_valid_path(q, [12, 0], [12, 19], tp, "가까운 입구 [12,0] 선택")


func test_placement_changes_and_blocks_path() -> void:
	var tp: TilePath = TilePath.new(_map)
	var before: Array = tp.path_from_entrance([11, 12])
	tp.set_occupied([[11, 5]], true)
	var after: Array = tp.path_from_entrance([11, 12])
	_assert_valid_path(after, [], [11, 12], tp, "우회")
	assert_false(after.has([11, 5]), "점유 셀을 피한다")
	assert_ne(after, before)
	# z = 5 한 줄을 다 막으면 도달 불가.
	var row: Array = []
	for x: int in range(1, 23):
		row.append([x, 5])
	tp.set_occupied(row, true)
	assert_eq(tp.path_from_entrance([11, 12]), [], "도달 불가 → []")
	tp.set_occupied([[20, 5]], false)
	var through: Array = tp.path_from_entrance([11, 12])
	_assert_valid_path(through, [], [11, 12], tp, "틈 하나")
	assert_true(through.has([20, 5]))


func test_deterministic() -> void:
	var a: TilePath = TilePath.new(_map)
	var b: TilePath = TilePath.new(_map)
	for t: TilePath in [a, b]:
		t.set_occupied([[11, 5], [12, 7], [10, 9]], true)
	var p1: Array = a.find_path([11, 1], [3, 20])
	assert_eq(a.find_path([11, 1], [3, 20]), p1, "같은 입력 2회 같은 결과")
	assert_eq(b.find_path([11, 1], [3, 20]), p1, "같은 상태의 다른 인스턴스도 같은 결과")


func test_unreachable_and_invalid_endpoints() -> void:
	var tp: TilePath = TilePath.new(_map)
	assert_eq(tp.find_path([11, 0], [0, 5]), [], "벽")
	assert_eq(tp.find_path([11, 0], [7, 8]), [], "기둥")
	assert_eq(tp.find_path([11, 0], [30, 5]), [], "맵 밖")
	assert_eq(tp.find_path([-1, 0], [5, 5]), [], "출발 맵 밖")
	tp.set_occupied([[5, 5]], true)
	assert_eq(tp.find_path([11, 0], [5, 5]), [], "점유 타일")
	tp.set_occupied([[0, 5]], false)
	assert_false(tp.is_passable(0, 5), "벽은 점유 해제로 열리지 않는다")


func test_sync_with_occupancy_and_build_system() -> void:
	var occ: GridOccupancy = GridOccupancy.new()
	occ.add("f1", [[11, 3], [12, 3]])
	var tp: TilePath = TilePath.new(_map)
	tp.set_occupied([[4, 4]], true)
	tp.sync(occ)
	assert_true(tp.is_passable(4, 4), "sync 는 이전 점유를 지운다")
	assert_false(tp.is_passable(11, 3))
	# BuildSystem 이 배치·철거에 맞춰 경로를 갱신한다.
	var cfg: BuildConfig = BuildConfig.load()
	var bus: EventBus = EventBus.new()
	var build: BuildSystem = BuildSystem.new(cfg, bus)
	var _econ: Economy = Economy.new(EconomyConfig.load(), bus)
	bus.publish("build.place_requested", {"furniture_id": "bench", "cell": [11, 2], "rotation": 0})
	bus.dispatch_commands()
	var p: Array = build.path_from_entrance([11, 12])
	assert_false(p.has([11, 2]) or p.has([12, 2]), "벤치를 피한다")
	assert_false(p.is_empty())
	bus.publish("build.demolish_requested", {"entity_id": "f1"})
	bus.dispatch_commands()
	assert_eq(build.path_from_entrance([11, 12]).size(), 13, "철거 뒤 직선 경로")
	assert_eq(build.find_path([11, 0], [11, 2]).size(), 3)
