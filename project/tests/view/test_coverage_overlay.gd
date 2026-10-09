extends GutTest
## SE-037 AC4: CoverageOverlay — build.coverage_changed 주입 → 데칼 타일 색이 커버리지와 일치(표본 5타일),
## O(overlay_cycle) 로 off → 음향 → 시야 → 바 → off 순환, HUD 문구. 샌드박스 baseline 프리셋 근사가 데이터 기대값과 같은지.

var _bus: EventBus
var _overlay: CoverageOverlay
var _params: BuildViewParams


func before_all() -> void:
	InputActions.register_build()


func before_each() -> void:
	_bus = EventBus.new()
	_overlay = CoverageOverlay.new()
	add_child_autofree(_overlay)
	_overlay.bind(_bus, ViewTestUtil.expected_tile_size_m())
	_params = _overlay.params


## 관람 6타일, 음향 2·시야 3·바 1(서로 다르게).
func _payload() -> Dictionary:
	return {
		"cause": "placed", "has_stage": true, "floor_free": 400, "viewing_count": 6,
		"viewing_tiles": [[3, 1], [4, 1], [5, 1], [3, 2], [4, 2], [5, 2]],
		"sound_tiles": [[3, 1], [4, 2]],
		"sight_tiles": [[3, 1], [4, 1], [5, 2]],
		"bar_tiles": [[5, 1]],
		"sound_bp": 3333, "sight_bp": 5000, "bar_bp": 1666, "capacity": 100, "evac_capacity": 80, "evac_shortfall": 20,
		"light_grade": 0, "satisfaction_bonus_bp": 0, "upkeep_per_day": 10,
	}


func test_decal_colors_match_coverage_sample() -> void:
	_bus.publish("build.coverage_changed", _payload())
	assert_eq(_overlay.get_decal_count(), 0, "기본 모드 off → 데칼 없음")
	assert_true(_overlay.set_mode("sound"))
	var covered: Color = _params.overlay_covered_colors["sound"]
	var uncovered: Color = _params.overlay_uncovered_color
	# 표본 5타일: 덮임 2, 안 덮임 2, 관람 밖 1.
	assert_eq(_overlay.get_tile_color(Vector2i(3, 1)), covered, "[3,1] 음향 덮임")
	assert_eq(_overlay.get_tile_color(Vector2i(4, 2)), covered, "[4,2] 음향 덮임")
	assert_eq(_overlay.get_tile_color(Vector2i(4, 1)), uncovered, "[4,1] 관람·안 덮임")
	assert_eq(_overlay.get_tile_color(Vector2i(5, 2)), uncovered, "[5,2] 관람·안 덮임")
	assert_eq(_overlay.get_tile_color(Vector2i(10, 10)).a, 0.0, "[10,10] 관람 밖 → 데칼 없음")
	assert_eq(_overlay.get_decal_count(), 6, "데칼 수 = viewing_tiles")
	# 데칼 셀 = viewing_tiles(페이로드 순서), 인스턴스 수 = 셀 수.
	var want_cells: Array[Vector2i] = []
	for pair: Array in _payload()["viewing_tiles"]:
		want_cells.append(Vector2i(pair[0], pair[1]))
	assert_eq(_overlay.get_decal_cells(), want_cells, "데칼 셀 = viewing_tiles")
	var mmi: MultiMeshInstance3D = _overlay.get_node(^"Decals") as MultiMeshInstance3D
	assert_eq(mmi.multimesh.instance_count, want_cells.size(), "MultiMesh 인스턴스 수")
	assert_true(mmi.multimesh.use_colors, "인스턴스 색 사용")
	assert_true(mmi.visible)


func test_each_mode_uses_its_tile_array() -> void:
	_bus.publish("build.coverage_changed", _payload())
	_overlay.set_mode("sight")
	assert_eq(_overlay.get_tile_color(Vector2i(4, 1)), _params.overlay_covered_colors["sight"], "시야 [4,1] 덮임")
	assert_eq(_overlay.get_tile_color(Vector2i(4, 2)), _params.overlay_uncovered_color, "시야 [4,2] 안 덮임")
	_overlay.set_mode("bar")
	assert_eq(_overlay.get_tile_color(Vector2i(5, 1)), _params.overlay_covered_colors["bar"], "바 [5,1] 덮임")
	assert_eq(_overlay.get_tile_color(Vector2i(3, 1)), _params.overlay_uncovered_color, "바 [3,1] 안 덮임")


func test_overlay_cycle_action_rotates_modes_and_hud() -> void:
	_bus.publish("build.coverage_changed", _payload())
	assert_eq(_overlay.get_mode(), "off")
	assert_string_contains(_overlay.get_hud_text(), "끔")
	var want: Array[String] = ["sound", "sight", "bar", "off"]
	var labels: Array[String] = ["음향 — 덮임 2 / 관람 6", "시야 — 덮임 3 / 관람 6", "바 서비스 — 덮임 1 / 관람 6", "끔"]
	for i: int in want.size():
		BuildTestUtil.press(_overlay, InputActions.OVERLAY_CYCLE)
		assert_eq(_overlay.get_mode(), want[i], "O %d번 → %s" % [i + 1, want[i]])
		assert_string_contains(_overlay.get_hud_text(), labels[i])
		assert_string_contains(_overlay.get_hud_text(), "(O)", "HUD 에 전환 키 이름(InputMap)")
	assert_eq(_overlay.get_decal_count(), 0, "off → 데칼 숨김")
	assert_eq(CoverageOverlay.MODES.size(), 4, "3모드 + off")


func test_session_loaded_clears_and_no_data_text() -> void:
	_overlay.set_mode("sound")
	assert_string_contains(_overlay.get_hud_text(), "데이터 없음", "coverage_changed 전")
	_bus.publish("build.coverage_changed", _payload())
	assert_eq(_overlay.get_decal_count(), 6)
	_bus.publish("session.loaded", {"day": 2})
	assert_eq(_overlay.get_decal_count(), 0, "session.loaded → 지움")
	assert_false(_overlay.has_coverage())
	assert_false(_overlay.set_mode("crowd"), "없는 모드 거부")


func test_baseline_preset_coverage_matches_layout_expected() -> void:
	var catalog: BuildCatalog = BuildTestUtil.catalog()
	var layout: Dictionary = {}
	for l: Dictionary in BuildTestUtil.map_json()["reference_layouts"]:
		if l["id"] == BuildPreset.BASELINE_LAYOUT_ID:
			layout = l
	assert_false(layout.is_empty(), "tier1_club.json 에 기준 배치가 있다")
	var placed: Array[Dictionary] = BuildPreset.placed_payloads(catalog, BuildPreset.BASELINE_LAYOUT_ID)
	assert_eq(placed.size(), (layout["placements"] as Array).size(), "배치 수 = placements")
	assert_eq(placed[0]["entity_id"], "f1")
	var cov: Dictionary = BuildPreset.coverage_payload(catalog, placed, BuildPreset.BASELINE_LAYOUT_ID)
	var want: Dictionary = layout["expected"]
	assert_eq((cov["viewing_tiles"] as Array).size(), int(want["viewing_count"]), "관람 타일 수 = expected.viewing_count")
	assert_eq((cov["sound_tiles"] as Array).size(), int(want["sound_count"]), "음향 = expected.sound_count")
	assert_eq((cov["bar_tiles"] as Array).size(), int(want["bar_count"]), "바 = expected.bar_count")
	assert_eq((cov["sight_tiles"] as Array).size(), int(want["sight_count"]), "시야 = expected.sight_count")
	assert_eq(cov["sound_bp"], want["sound_bp"], "스칼라는 expected 그대로")
	assert_true(EventBus.is_valid_value(cov, true), "페이로드가 버스 E4 형식")
