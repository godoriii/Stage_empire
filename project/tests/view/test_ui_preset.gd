extends GutTest
## SE-039: 샌드박스 --se-ui-preset=<day|close>(캡처 2장의 입력). 값은 데이터 기준 시나리오에서 온다.

const SANDBOX_SCENE: String = "res://view/scenes/grid_sandbox.tscn"


func _sandbox() -> GridSandbox:
	var s: GridSandbox = (load(SANDBOX_SCENE) as PackedScene).instantiate() as GridSandbox
	add_child_autofree(s)
	return s


func test_resolve_and_ids() -> void:
	assert_eq(UiPreset.resolve(PackedStringArray(["--se-ui-preset=Close"])), UiPreset.CLOSE)
	assert_eq(UiPreset.resolve(PackedStringArray(["--x"])), UiPreset.NONE)
	assert_eq(UiPreset.events("bogus", UiData.load_default(), UiArtistCatalog.load_default()), [])


func test_close_preset_payloads_match_data() -> void:
	var data: UiData = UiData.load_default()
	var evs: Array = UiPreset.events(UiPreset.CLOSE, data, UiArtistCatalog.load_default())
	var names: PackedStringArray = PackedStringArray()
	for ev: Array in evs:
		names.append(str(ev[0]))
		if ev[0] == "economy.day_settled":
			var x: Dictionary = (UiTestUtil.json(UiTestUtil.ECONOMY_PATH)["reference_scenarios"][0] as Dictionary)["expected"]
			assert_eq(int(ev[1]["net"]), int(x["net"]), "정산 = economy tier1_baseline")
	for must: String in ["session.loaded", "show.ended", "economy.day_settled", "reputation.changed", "artist.grown", "artist.lineup_set"]:
		assert_true(names.has(must), "close 프리셋에 %s" % must)
	assert_eq(str((evs[0][1] as Dictionary)["phase"]), UiTestUtil.close_phase())


func test_sandbox_setup_ui_day_and_bad_id() -> void:
	var s: GridSandbox = _sandbox()
	assert_false(s.setup_ui("bogus"), "없는 id 거부")
	assert_push_error_count(1, "없는 id → push_error")
	assert_null(s.get_ui_root())
	assert_true(s.setup_ui(UiPreset.DAY))
	var r: UiRoot = s.get_ui_root()
	assert_not_null(r)
	assert_true(r.artist_panel.visible, "day = 섭외 패널 열림")
	assert_false(r.day_report.visible, "day 에는 리포트 숨김")
	assert_eq(r.hud.get_phase(), UiTestUtil.phase_ids()[0])
	assert_eq(s.get_build_preset(), BuildPreset.BASELINE, "배치 baseline 함께")
	assert_eq(r.artist_panel.get_rows().size(), (UiTestUtil.json(UiTestUtil.ARTISTS_PATH)["rows"] as Array).size())


func test_sandbox_setup_ui_close_shows_report() -> void:
	var s: GridSandbox = _sandbox()
	assert_true(s.setup_ui(UiPreset.CLOSE))
	var r: UiRoot = s.get_ui_root()
	assert_true(r.day_report.visible, "close = 리포트")
	assert_true(r.day_report.has_show())
	assert_false(r.artist_panel.visible)
