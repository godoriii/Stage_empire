extends GutTest
## SE-002 AC6, AC7: 화면 → 타일 레이캐스트 판정과 커서 표시.

const EPS: float = 0.0001

var _vp: SubViewport
var _cam: IsoCamera
var _grid: GridView
var _cursor: TileCursor


func before_each() -> void:
	_vp = ViewTestUtil.make_viewport(self)
	autofree(_vp)
	_grid = GridView.new()
	_vp.add_child(_grid)
	_cam = ViewTestUtil.make_camera(_vp)
	_cam.set_bounds(_grid.get_extent_m())
	_cam.focus_on(_grid.get_center_world())
	_cursor = TileCursor.new()
	_cursor.track_mouse = false
	_vp.add_child(_cursor)
	_cursor.setup(_cam.get_camera(), _grid)


func _screen_of(world: Vector3) -> Vector2:
	return _cam.get_camera().unproject_position(world)


func test_screen_to_tile_all_rotations_and_zooms() -> void:
	var n: Vector2i = _grid.get_grid_size()
	var tiles: Array[Vector2i] = [Vector2i(5, 5), Vector2i(0, n.y - 1)]
	assert_eq(tiles[1], Vector2i(0, 23), "티켓의 (0,23) = 티어 1 마지막 행")
	var t: float = _grid.get_tile_size_m()
	var combos: int = 0
	var yaws: Array[int] = []
	for r: int in 4:
		yaws.append(roundi(_cam.get_yaw_deg()))
		for z: int in _cam.get_zoom_level_count():
			_cam.set_zoom_index(z)
			assert_eq(_cam.get_zoom_index(), z)
			for tile: Vector2i in tiles:
				var center: Vector3 = _grid.tile_to_world(tile)
				var got: Vector2i = _cursor.screen_to_tile(_screen_of(center))
				assert_eq(got, tile, "요 %d° 줌 %d 타일 %s 중심" % [yaws[-1], z, tile])
				# 타일 안쪽 네 모서리 근처도 같은 타일.
				for corner: Vector3 in [Vector3(-0.45, 0, -0.45), Vector3(0.45, 0, -0.45), Vector3(-0.45, 0, 0.45), Vector3(0.45, 0, 0.45)]:
					assert_eq(_cursor.screen_to_tile(_screen_of(center + corner * t)), tile,
						"요 %d° 줌 %d 타일 %s 모서리 %s" % [yaws[-1], z, tile, corner])
			combos += 1
		_cam.rotate_cw()
	assert_eq(combos, 16, "4방향 × 4줌")
	assert_eq(yaws, [45, 135, 225, 315] as Array[int], "네 방향 모두 확인")


func test_cursor_follows_tile_and_hides_outside() -> void:
	watch_signals(_cursor)
	var y_off: float = _cursor.params.cursor_y_offset_m
	assert_gt(y_off, 0.0, "커서는 바닥 위로 살짝 뜬다")
	assert_lt(y_off, 0.1, "오프셋은 작다")

	for r: int in 4:
		for tile: Vector2i in [Vector2i(5, 5), Vector2i(0, _grid.get_grid_size().y - 1), Vector2i(12, 3)]:
			_cursor.update_hover(_screen_of(_grid.tile_to_world(tile)))
			assert_true(_cursor.visible, "그리드 안에서는 보인다 %s" % tile)
			assert_true(_cursor.is_hovering())
			assert_eq(_cursor.get_hovered_tile(), tile)
			var expected: Vector3 = _grid.tile_to_world(tile) + Vector3(0.0, y_off, 0.0)
			assert_true(_cursor.position.is_equal_approx(expected), "커서 위치 %s == 타일 중심 %s" % [_cursor.position, expected])
			var label: Label3D = _cursor.get_node(^"CoordLabel") as Label3D
			assert_eq(label.text, "%d, %d" % [tile.x, tile.y], "좌표 라벨")
		_cam.rotate_cw()
	assert_signal_emitted(_cursor, "hovered_tile_changed")

	var outside: Array[Vector3] = [Vector3(-3.0, 0.0, -3.0), Vector3(-0.5, 0.0, 5.0),
		Vector3(_grid.get_extent_m().x + 2.0, 0.0, 5.0), Vector3(5.0, 0.0, _grid.get_extent_m().y + 0.5)]
	for w: Vector3 in outside:
		_cursor.update_hover(_screen_of(_grid.tile_to_world(Vector2i(5, 5))))
		assert_true(_cursor.visible)
		_cursor.update_hover(_screen_of(w))
		assert_false(_cursor.visible, "그리드 밖 %s 에서는 숨김" % w)
		assert_false(_cursor.is_hovering())
	assert_signal_emitted_with_parameters(_cursor, "hovered_tile_changed",
		[_grid.world_to_tile(outside[-1]), false])


func test_cursor_has_highlight_mesh_sized_to_tile() -> void:
	var mesh: MeshInstance3D = _cursor.get_node_or_null(^"Highlight") as MeshInstance3D
	assert_not_null(mesh)
	var plane: PlaneMesh = mesh.mesh as PlaneMesh
	assert_not_null(plane, "강조 메시는 PlaneMesh")
	var expected: float = _grid.get_tile_size_m() * _cursor.params.cursor_fill_ratio
	assert_almost_eq(plane.size.x, expected, EPS)
	assert_lte(plane.size.x, _grid.get_tile_size_m(), "타일보다 크지 않다")
