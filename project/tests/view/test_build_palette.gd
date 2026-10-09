extends GutTest
## SE-037 AC5: 하단 팔레트 — 가구 버튼 수 = furniture.json 행 수(데이터에서), 카테고리 탭, 버튼 글자에 build_cost·upkeep_per_day,
## 버튼 → 고스트 선택, 철거 버튼, build.rejected 토스트.

const PALETTE_SCENE: String = "res://ui/build/build_palette.tscn"

var _bus: EventBus
var _catalog: BuildCatalog
var _ghost: PlacementGhost
var _overlay: CoverageOverlay
var _palette: BuildPalette


func before_all() -> void:
	InputActions.register_build()


func before_each() -> void:
	_bus = EventBus.new()
	_catalog = BuildTestUtil.catalog()
	var t: float = ViewTestUtil.expected_tile_size_m()
	var view: FurnitureView = FurnitureView.new()
	add_child_autofree(view)
	view.bind(_bus, _catalog, t)
	_ghost = PlacementGhost.new()
	add_child_autofree(_ghost)
	_ghost.bind(_bus, _catalog, view, t)
	_overlay = CoverageOverlay.new()
	add_child_autofree(_overlay)
	_overlay.bind(_bus, t)
	_palette = (load(PALETTE_SCENE) as PackedScene).instantiate() as BuildPalette
	add_child_autofree(_palette)
	_palette.bind(_bus, _catalog, _ghost, _overlay)


func _rows() -> Array:
	return BuildTestUtil.furniture_json()["rows"]


func test_item_buttons_equal_furniture_rows() -> void:
	var rows: Array = _rows()
	var buttons: Array[Button] = _palette.get_item_buttons()
	assert_eq(buttons.size(), rows.size(), "가구 버튼 수 = furniture.json 행 수")
	for i: int in rows.size():
		assert_eq(str(buttons[i].get_meta(BuildPalette.META_FURNITURE_ID)), rows[i]["id"], "버튼 %d = 행 %s (테이블 순서)" % [i, rows[i]["id"]])


func test_category_tabs_from_data() -> void:
	var cats: Array[String] = []
	for r: Dictionary in _rows():
		if not cats.has(r["category"]):
			cats.append(r["category"])
	var tabs: Array[Button] = _palette.get_tab_buttons()
	assert_eq(tabs.size(), cats.size(), "탭 수 = 데이터의 카테고리 수")
	var schema: Dictionary = ViewTestUtil.read_json("res://data/schemas/furniture.schema.json")
	assert_true(JSON.stringify(schema).contains("amenity"), "전제: 스키마에 카테고리 enum")
	for i: int in cats.size():
		assert_eq(str(tabs[i].get_meta(BuildPalette.META_CATEGORY)), cats[i], "탭 %d = %s" % [i, cats[i]])
		assert_ne(tabs[i].text, "", "탭 글자")
	assert_eq(_palette.get_current_category(), cats[0], "처음 탭 선택")


func test_button_text_has_cost_and_upkeep() -> void:
	for r: Dictionary in _rows():
		var b: Button = _palette.get_item_button(r["id"])
		assert_not_null(b, "%s 버튼" % r["id"])
		assert_string_contains(b.text, str(r["name"]))
		assert_string_contains(b.text, "건설 %d" % int(r["build_cost"]))
		assert_string_contains(b.text, "유지 %d/일" % int(r["upkeep_per_day"]))


func test_tab_switch_shows_only_that_category() -> void:
	var cat: String = str(BuildTestUtil.row("bar_counter")["category"])
	assert_true(_palette.select_category(cat))
	for b: Button in _palette.get_item_buttons():
		var row_cat: String = str(BuildTestUtil.row(str(b.get_meta(BuildPalette.META_FURNITURE_ID)))["category"])
		assert_eq(b.is_visible_in_tree(), row_cat == cat, "%s 표시 = 카테고리 %s 일 때만" % [b.name, cat])
	assert_false(_palette.select_category("weapons"), "없는 카테고리")


func test_item_button_selects_ghost_and_demolish_button() -> void:
	_palette.get_item_button("bar_counter").pressed.emit()
	assert_eq(_ghost.get_mode(), PlacementGhost.Mode.PLACE)
	assert_eq(_ghost.get_selected_id(), "bar_counter", "버튼 → 고스트 선택")
	assert_string_contains(_palette.get_status_text(), str(BuildTestUtil.row("bar_counter")["name"]), "상태 문구에 선택 이름")
	_palette.get_demolish_button().pressed.emit()
	assert_eq(_ghost.get_mode(), PlacementGhost.Mode.DEMOLISH, "철거 버튼 → 철거 모드")
	assert_string_contains(_palette.get_status_text(), "철거")
	assert_eq(_bus.get_pending_commands().size(), 0, "팔레트 조작만으로는 명령 없음")


func test_rejected_shows_toast_then_hides() -> void:
	assert_false(_palette.is_toast_visible())
	_bus.publish("build.rejected", {"action": "place", "reason": "insufficient_cash", "furniture_id": "bar_counter",
		"cell": [2, 2], "rotation": 0, "entity_id": null})
	assert_true(_palette.is_toast_visible(), "build.rejected → 토스트")
	assert_string_contains(_palette.get_toast_text(), "insufficient_cash", "reason 표시")
	assert_string_contains(_palette.get_toast_text(), "자금 부족")
	var timer: Timer = _palette.get_toast_timer()
	assert_almost_eq(timer.wait_time, 3.0, 0.001, "토스트 3초(씬 Timer)")
	assert_false(timer.is_stopped(), "타이머 시작")
	timer.timeout.emit()
	assert_false(_palette.is_toast_visible(), "타임아웃 → 숨김")


func test_status_shows_overlay_hud_text() -> void:
	_overlay.set_mode("sound")
	assert_string_contains(_palette.get_status_text(), _overlay.get_hud_text(), "오버레이 문구가 상태에 반영")
