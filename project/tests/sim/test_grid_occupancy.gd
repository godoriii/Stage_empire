extends GutTest
## SE-032 — GridOccupancy. docs/gdd/build.md G2·G3·G6 과 회전별 방향표(등면 이웃·앞 행·앞 반평면·초점 셀), 거리식, 점유표.


func test_rotated_size_four_rotations() -> void:
	assert_eq(GridOccupancy.rotated_size([3, 1], 0), [3, 1])
	assert_eq(GridOccupancy.rotated_size([3, 1], 90), [1, 3], "BC24")
	assert_eq(GridOccupancy.rotated_size([3, 1], 180), [3, 1])
	assert_eq(GridOccupancy.rotated_size([3, 1], 270), [1, 3])


func test_cells_of_g3_g6() -> void:
	assert_eq(GridOccupancy.cells_of([3, 1], [20, 4], 90), [[20, 4], [20, 5], [20, 6]], "BC24 바 카운터")
	assert_eq(GridOccupancy.cells_of([1, 2], [1, 19], 270), [[1, 19], [2, 19]], "BC9 화장실 r270")
	assert_eq(GridOccupancy.cells_of([2, 3], [5, 5], 0), [[5, 5], [6, 5], [5, 6], [6, 6], [5, 7], [6, 7]], "z → x 순서")
	# 회전은 cell(최소 모서리)을 바꾸지 않는다.
	for rot: int in GridOccupancy.KNOWN_ROTATIONS:
		assert_eq(GridOccupancy.cells_of([4, 3], [7, 7], rot)[0], [7, 7])


func test_direction_table() -> void:
	var bar: Rect2i = GridOccupancy.rect_of([3, 1], [20, 4], 90)
	assert_eq(GridOccupancy.back_neighbors(bar, 90), [[21, 4], [21, 5], [21, 6]], "build.md 예: 등면 이웃")
	assert_eq(GridOccupancy.front_row(bar, 90), [[19, 4], [19, 5], [19, 6]])
	var st: Rect2i = GridOccupancy.rect_of([4, 3], [10, 20], 0)
	assert_eq(GridOccupancy.front_row(st, 0), [[10, 19], [11, 19], [12, 19], [13, 19]], "BC13 무대 앞 행")
	assert_eq(GridOccupancy.front_edge(st, 0), [[10, 20], [11, 20], [12, 20], [13, 20]])
	assert_eq(GridOccupancy.focal_cell(st, 0), [12, 20], "초점 E[⌊4/2⌋]")
	assert_eq(GridOccupancy.back_neighbors(st, 0), [[10, 23], [11, 23], [12, 23], [13, 23]])
	# 2×2 사각형 x 5..6, z 5..6 에서 네 방향
	var r: Rect2i = Rect2i(5, 5, 2, 2)
	assert_eq(GridOccupancy.back_neighbors(r, 180), [[5, 4], [6, 4]])
	assert_eq(GridOccupancy.front_row(r, 180), [[5, 7], [6, 7]])
	assert_eq(GridOccupancy.back_neighbors(r, 270), [[4, 5], [4, 6]])
	assert_eq(GridOccupancy.front_row(r, 270), [[7, 5], [7, 6]])
	assert_eq(GridOccupancy.front_edge(r, 180), [[5, 6], [6, 6]])
	assert_eq(GridOccupancy.front_edge(r, 270), [[6, 5], [6, 6]])
	assert_eq(GridOccupancy.front_edge(r, 90), [[5, 5], [5, 6]])
	assert_true(GridOccupancy.in_front(r, 0, 9, 4) and not GridOccupancy.in_front(r, 0, 5, 5))
	assert_true(GridOccupancy.in_front(r, 90, 4, 0) and not GridOccupancy.in_front(r, 90, 5, 0))
	assert_true(GridOccupancy.in_front(r, 180, 0, 7) and not GridOccupancy.in_front(r, 180, 0, 6))
	assert_true(GridOccupancy.in_front(r, 270, 7, 0) and not GridOccupancy.in_front(r, 270, 6, 0))


func test_dist2() -> void:
	var r: Rect2i = Rect2i(10, 20, 4, 3)
	assert_eq(GridOccupancy.dist2(r, 11, 21), 0, "안쪽")
	assert_eq(GridOccupancy.dist2(r, 12, 19), 1)
	assert_eq(GridOccupancy.dist2(r, 7, 17), 9 + 9)
	assert_eq(GridOccupancy.dist2(r, 16, 23), 9 + 1)


func test_occupancy_table() -> void:
	var o: GridOccupancy = GridOccupancy.new()
	assert_true(o.add("f1", [[1, 1], [2, 1]]))
	assert_false(o.add("f2", [[3, 1], [2, 1]]), "겹치면 거부")
	assert_false(o.is_occupied(3, 1), "거부 시 불변")
	assert_eq(o.owner_of(2, 1), "f1")
	assert_eq(o.owner_of(9, 9), "")
	assert_true(o.add("f2", [[0, 3], [5, 0]]))
	assert_eq(o.cells(), [[5, 0], [1, 1], [2, 1], [0, 3]], "G6 순서")
	assert_eq(o.blocked_set().size(), 4)
	o.remove("f1", [[1, 1], [2, 1]])
	assert_eq(o.size(), 2)
	o.remove("f9", [[5, 0]])
	assert_true(o.is_occupied(5, 0), "다른 entity 셀은 안 지운다")
	o.clear()
	assert_eq(o.size(), 0)


## SE-032-bug: 64비트 비교(Rect2i 변환 전), 오버플로 없음.
func test_rect_in_bounds_64bit() -> void:
	var p32: int = 1 << 32
	assert_true(GridOccupancy.rect_in_bounds([4, 3], [20, 21], 0, 24, 24), "x 20..23, z 21..23")
	assert_false(GridOccupancy.rect_in_bounds([4, 3], [21, 21], 0, 24, 24), "x 24 밖")
	assert_true(GridOccupancy.rect_in_bounds([4, 3], [21, 20], 90, 24, 24), "회전 후 3×4")
	assert_false(GridOccupancy.rect_in_bounds([4, 3], [21, 21], 90, 24, 24))
	assert_false(GridOccupancy.rect_in_bounds([1, 1], [-1, 0], 0, 24, 24))
	for cell: Array in [[p32 + 5, 5], [5, p32 + 5], [-p32 + 5, 5], [9223372036854775807, 5], [-9223372036854775807 - 1, 0]]:
		assert_false(GridOccupancy.rect_in_bounds([4, 3], cell, 0, 24, 24), "%s" % [cell])
	var o: GridOccupancy = GridOccupancy.new()
	o.add("f1", [[5, 5]])
	assert_false(GridOccupancy.fits_cell(p32 + 5, 5))
	assert_true(GridOccupancy.fits_cell(5, 5))
	assert_false(o.is_occupied(p32 + 5, 5), "잘린 좌표로 [5,5] 를 보지 않는다")
	assert_eq(o.owner_of(p32 + 5, 5), "")
