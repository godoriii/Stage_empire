extends GutTest
## SE-002 AC5: GridView 가 데이터 테이블로 초기화되고 좌표 변환이 맞다.

const EPS: float = 0.0001

var _grid: GridView


func before_each() -> void:
	_grid = GridView.new()
	add_child_autofree(_grid)


func test_size_from_data_tables() -> void:
	var n: int = ViewTestUtil.expected_grid_size("tier_1")
	assert_eq(n, 24, "tiers.json tier_1.grid_size (테이블이 바뀌면 이 기대값도 game-designer 티켓으로)")
	assert_eq(_grid.get_grid_size(), Vector2i(n, n), "GridView 크기 = tiers.json tier_1.grid_size")
	var t: float = ViewTestUtil.expected_tile_size_m()
	assert_eq(t, 1.0, "sim.json tile_size_m")
	assert_eq(_grid.get_tile_size_m(), t, "GridView 타일 크기 = sim.json tile_size_m")
	assert_eq(_grid.get_extent_m(), Vector2(n, n) * t)

	# 메시: 바닥 + 타일 선 (n+1)*2 개 선분 = 정점 4(n+1)개.
	var floor_node: MeshInstance3D = _grid.get_node_or_null(^"Floor") as MeshInstance3D
	var lines: MeshInstance3D = _grid.get_node_or_null(^"TileLines") as MeshInstance3D
	assert_not_null(floor_node, "바닥 메시")
	assert_not_null(lines, "타일 선 메시")
	if lines != null:
		var arrays: Array = (lines.mesh as ArrayMesh).surface_get_arrays(0)
		assert_eq((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 4 * (n + 1), "선 정점 수")
	if floor_node != null:
		var aabb: AABB = floor_node.get_aabb()
		assert_almost_eq(aabb.size.x, float(n) * t, EPS, "바닥 너비")
		assert_almost_eq(floor_node.position.y + aabb.end.y, 0.0, EPS, "바닥 윗면 y=0")

	# view 코드에 그리드 크기 리터럴이 없다.
	var hits: PackedStringArray = ViewTestUtil.grep(
		ViewTestUtil.list_sources(["res://view"], "gd"), "(?<![\\w.])24(?![\\w.])")
	assert_eq(hits.size(), 0, "project/view/**/*.gd 에 24 리터럴 없음: %s" % ", ".join(hits))


func test_world_tile_roundtrip() -> void:
	assert_eq(_grid.world_to_tile(Vector3(3.4, 0.0, 7.9)), Vector2i(3, 7))
	assert_eq(_grid.tile_to_world(Vector2i(3, 7)), Vector3(3.5, 0.0, 7.5), "타일 중심, y=0")
	var n: Vector2i = _grid.get_grid_size()
	for x: int in n.x:
		for z: int in n.y:
			var tile: Vector2i = Vector2i(x, z)
			var w: Vector3 = _grid.tile_to_world(tile)
			assert_eq(_grid.world_to_tile(w), tile, "중심 왕복 %s" % tile)
			# 타일 경계 바로 안쪽도 같은 타일.
			var t: float = _grid.get_tile_size_m()
			assert_eq(_grid.world_to_tile(w + Vector3(-0.49, 0.0, 0.49) * t), tile)
			assert_eq(_grid.world_to_tile(Vector3(x, 0.0, z) * t), tile, "타일 최소 모서리는 그 타일")


func test_outside_is_not_inside() -> void:
	var n: Vector2i = _grid.get_grid_size()
	assert_true(_grid.is_inside(Vector2i(0, 0)))
	assert_true(_grid.is_inside(n - Vector2i.ONE))
	for tile: Vector2i in [Vector2i(-1, 0), Vector2i(0, -1), Vector2i(n.x, 0), Vector2i(0, n.y), n, Vector2i(-5, -5)]:
		assert_false(_grid.is_inside(tile), "%s 는 밖" % tile)
	assert_false(_grid.is_inside(_grid.world_to_tile(Vector3(-0.01, 0.0, 5.0))), "x 음수 월드 좌표는 밖")
	assert_false(_grid.is_inside(_grid.world_to_tile(Vector3(5.0, 0.0, float(n.y) * _grid.get_tile_size_m()))), "z = 끝 경계는 밖")
	assert_false(_grid.get_math().is_world_inside(Vector3(1000.0, 0.0, 1.0)))
