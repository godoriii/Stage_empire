extends GutTest
## SE-037 AC2(고스트·배치 명령·회전·취소), AC3(철거 명령). 가짜 버스(EventBus, sim 미등록)의 명령 큐로 단언한다.
## 유효성 추정 케이스는 build.md BC6·BC7·BC8·BC9 와 같은 좌표(맵 tier1_club.json).

var _bus: EventBus
var _catalog: BuildCatalog
var _view: FurnitureView
var _ghost: PlacementGhost
var _params: BuildViewParams


func before_all() -> void:
	InputActions.register_build()


func before_each() -> void:
	_bus = EventBus.new()
	_catalog = BuildTestUtil.catalog()
	var t: float = ViewTestUtil.expected_tile_size_m()
	_view = FurnitureView.new()
	add_child_autofree(_view)
	_view.bind(_bus, _catalog, t)
	_ghost = PlacementGhost.new()
	add_child_autofree(_ghost)
	_ghost.bind(_bus, _catalog, _view, t)
	_params = _ghost.params


func _commands() -> Array:
	return _bus.get_pending_commands()


func test_hover_valid_tile_shows_green_ghost() -> void:
	assert_false(_ghost.is_ghost_visible(), "선택 전에는 고스트 없음")
	_ghost.hover(Vector2i(5, 5))
	assert_false(_ghost.is_ghost_visible(), "선택 없이 호버만으로는 고스트 없음")
	assert_true(_ghost.select("speaker_floor"))
	assert_true(_ghost.is_ghost_visible(), "선택 뒤 호버 타일에 고스트")
	assert_true(_ghost.is_valid(), "빈 바닥 = 유효 추정")
	assert_eq(_ghost.get_ghost_color(), _params.ghost_valid_color, "녹색(params.ghost_valid_color)")
	var box: MeshInstance3D = _ghost.get_node(^"GhostBox") as MeshInstance3D
	var want: Vector3 = BuildCatalog.center_world(Vector2i.ONE, Vector2i(5, 5), 0, ViewTestUtil.expected_tile_size_m())
	assert_almost_eq(box.position.x, want.x, 0.0001, "고스트 위치 x = G5")
	assert_almost_eq(box.position.z, want.z, 0.0001, "고스트 위치 z = G5")
	assert_gt(_ghost.get_radius_preview_count(), 0, "sound_radius > 0 → 반경 미리보기 타일")


func test_out_of_bounds_and_blocked_tiles_are_red() -> void:
	_ghost.select("stage_small")
	_ghost.hover(Vector2i(21, 5))   # BC6: x 21..24 → 맵 밖
	assert_eq(_ghost.get_reason(), "out_of_bounds")
	assert_eq(_ghost.get_ghost_color(), _params.ghost_invalid_color, "빨강")
	_ghost.select("speaker_floor")
	_ghost.hover(Vector2i(-1, 5))
	assert_eq(_ghost.get_reason(), "out_of_bounds", "음수 좌표")
	for c: Vector2i in [Vector2i(7, 8), Vector2i(11, 1), Vector2i(0, 5), Vector2i(11, 0)]:   # BC7 기둥·완충·벽·입구
		_ghost.hover(c)
		assert_eq(_ghost.get_reason(), "blocked_tile", "%s 배치 불가 타일" % c)
		assert_eq(_ghost.get_ghost_color(), _params.ghost_invalid_color)


func test_overlap_with_placed_furniture_is_red() -> void:
	_bus.publish("build.placed", BuildTestUtil.placed("f1", "stage_small", Vector2i(10, 20), 0))
	_ghost.select("speaker_floor")
	_ghost.hover(Vector2i(11, 21))   # BC8
	assert_eq(_ghost.get_reason(), "overlap")
	assert_eq(_ghost.get_ghost_color(), _params.ghost_invalid_color)
	_bus.publish("build.demolished", BuildTestUtil.demolished("f1", "stage_small", Vector2i(10, 20), 0))
	assert_true(_ghost.is_valid(), "철거 뒤 같은 자리 = 유효(점유 변화에 바로 반영)")


func test_wall_required_needs_wall_behind() -> void:
	# BC9: poster_board [5,5] r0 ✗, [5,22] r0 ✓, [5,1] r0 ✗, [5,1] r180 ✓, [7,9] r180(등이 기둥) ✗,
	#      toilet_booth [1,21] r0 ✓, [1,19] r90 ✗, [1,19] r270 ✓.
	var cases: Array = [
		["poster_board", Vector2i(5, 5), 0, "wall_required"],
		["poster_board", Vector2i(5, 22), 0, ""],
		["poster_board", Vector2i(5, 1), 0, "wall_required"],
		["poster_board", Vector2i(5, 1), 180, ""],
		["poster_board", Vector2i(7, 9), 180, "wall_required"],
		["toilet_booth", Vector2i(1, 21), 0, ""],
		["toilet_booth", Vector2i(1, 19), 90, "wall_required"],
		["toilet_booth", Vector2i(1, 19), 270, ""],
	]
	for c: Array in cases:
		assert_eq(_ghost.estimate_reason(c[0], c[1], c[2]), c[3], "%s %s r%d" % [c[0], c[1], c[2]])
	# 회전으로 무효 → 유효가 되는 흐름(R 키).
	_ghost.select("poster_board")
	_ghost.hover(Vector2i(5, 1))
	assert_eq(_ghost.get_reason(), "wall_required")
	_ghost.rotate_selection()
	_ghost.rotate_selection()
	assert_eq(_ghost.get_rotation_deg(), 180)
	assert_true(_ghost.is_valid(), "r180 이면 등이 북쪽 벽")
	assert_eq(_ghost.get_ghost_color(), _params.ghost_valid_color)


func test_click_publishes_one_place_command_with_ints() -> void:
	_ghost.select("bar_counter")
	_ghost.rotate_selection()
	_ghost.hover(Vector2i(20, 4))
	assert_true(_ghost.click(), "유효 추정 → 발행")
	var cmds: Array = _commands()
	assert_eq(cmds.size(), 1, "명령 큐에 1건")
	assert_eq(cmds[0]["name"], "build.place_requested")
	var p: Dictionary = cmds[0]["payload"]
	assert_eq(p.keys().size(), 3, "키 3개: furniture_id, cell, rotation")
	assert_eq(p["furniture_id"], "bar_counter")
	assert_eq(p["cell"], [20, 4])
	assert_eq(p["rotation"], 90)
	assert_eq(typeof(p["cell"][0]), TYPE_INT, "cell.x int")
	assert_eq(typeof(p["cell"][1]), TYPE_INT, "cell.z int")
	assert_eq(typeof(p["rotation"]), TYPE_INT, "rotation int")
	_ghost.hover(Vector2i(0, 5))
	assert_false(_ghost.click(), "무효 추정(벽) → 발행하지 않는다")
	assert_eq(_commands().size(), 1, "명령 수 그대로")


func test_rotate_cycles_allowed_rotations() -> void:
	var allowed: Array = BuildTestUtil.furniture_json()["build_rules"]["allowed_rotations"]
	_ghost.select("bar_counter")
	assert_eq(_ghost.get_rotation_deg(), int(allowed[0]), "선택 시 처음 회전")
	for i: int in range(1, allowed.size() + 1):
		BuildTestUtil.press(_ghost, InputActions.BUILD_ROTATE)
		assert_eq(_ghost.get_rotation_deg(), int(allowed[i % allowed.size()]), "R %d번 → %d" % [i, int(allowed[i % allowed.size()])])
	_ghost.select("fog_machine")   # rotatable == false
	assert_false(BuildTestUtil.row("fog_machine")["rotatable"], "전제: fog_machine 회전 불가")
	BuildTestUtil.press(_ghost, InputActions.BUILD_ROTATE)
	assert_eq(_ghost.get_rotation_deg(), int(allowed[0]), "회전 불가 가구는 R 무시")
	assert_eq(_commands().size(), 0, "회전은 명령 없음")


func test_cancel_removes_ghost_and_sends_nothing() -> void:
	_ghost.select("speaker_floor")
	_ghost.hover(Vector2i(5, 5))
	assert_true(_ghost.is_ghost_visible())
	BuildTestUtil.press(_ghost, InputActions.BUILD_CANCEL)
	assert_false(_ghost.is_ghost_visible(), "Esc → 고스트 제거")
	assert_eq(_ghost.get_mode(), PlacementGhost.Mode.NONE)
	assert_eq(_ghost.get_selected_id(), "")
	BuildTestUtil.press(_ghost, InputActions.BUILD_CONFIRM)
	assert_eq(_commands().size(), 0, "취소 뒤 클릭해도 명령 0")


func test_confirm_action_places_via_input() -> void:
	_ghost.select("speaker_floor")
	_ghost.hover(Vector2i(5, 5))
	BuildTestUtil.press(_ghost, InputActions.BUILD_CONFIRM)
	assert_eq(_commands().size(), 1, "build_confirm 액션 → 명령 1건")
	assert_eq(_ghost.get_selected_id(), "speaker_floor", "배치 뒤에도 선택 유지(연속 배치)")


func test_demolish_mode_click_on_furniture_and_empty_tile() -> void:
	_bus.publish("build.placed", BuildTestUtil.placed("f4", "bar_counter", Vector2i(20, 4), 90))
	BuildTestUtil.press(_ghost, InputActions.BUILD_DEMOLISH)
	assert_eq(_ghost.get_mode(), PlacementGhost.Mode.DEMOLISH, "X → 철거 모드")
	_ghost.hover(Vector2i(10, 10))
	assert_false(_ghost.click(), "빈 타일 클릭 → 발행 없음")
	assert_eq(_commands().size(), 0, "빈 타일 → 0건")
	assert_false(_ghost.is_ghost_visible(), "빈 타일에는 철거 상자 없음")
	_ghost.hover(Vector2i(20, 6))   # bar_counter 의 셋째 점유 셀
	assert_true(_ghost.is_ghost_visible(), "가구 위 → 철거 상자")
	assert_eq(_ghost.get_ghost_color(), _params.demolish_color)
	assert_true(_ghost.click())
	var cmds: Array = _commands()
	assert_eq(cmds.size(), 1, "가구 클릭 → 1건")
	assert_eq(cmds[0]["name"], "build.demolish_requested")
	assert_eq(cmds[0]["payload"], {"entity_id": "f4"})
	BuildTestUtil.press(_ghost, InputActions.BUILD_DEMOLISH)
	assert_eq(_ghost.get_mode(), PlacementGhost.Mode.NONE, "X 다시 → 철거 모드 끔")


func test_cursor_hover_signal_and_invalid_tile_hides_ghost() -> void:
	_ghost.select("speaker_floor")
	_ghost.on_cursor_hover(Vector2i(3, 3), true)
	assert_eq(_ghost.get_hovered_tile(), Vector2i(3, 3))
	assert_true(_ghost.is_ghost_visible())
	_ghost.on_cursor_hover(IsoGridMath.INVALID_TILE, false)
	assert_false(_ghost.is_ghost_visible(), "레이가 지면을 못 맞히면 고스트 숨김")
	assert_false(_ghost.click(), "호버 없으면 발행 없음")
	assert_false(_ghost.select("stage_huge"), "모르는 가구 선택 거부")
	assert_eq(_ghost.get_selected_id(), "speaker_floor", "선택 유지")
