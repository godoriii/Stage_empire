extends GutTest
## SE-039 AC4: 마감 리포트 = show.md R1~R13 합성. 순서 = UiParams.report_rows(2차 확정 전 초안).

const SCENE: String = "res://ui/panels/day_report.tscn"
const R_ALL: PackedStringArray = ["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12", "R13"]

var bus: EventBus
var report: DayReport
var data: UiData
var catalog: UiArtistCatalog


func before_each() -> void:
	bus = EventBus.new()
	data = UiData.load_default()
	catalog = UiArtistCatalog.load_default()
	report = UiTestUtil.make_panel(self, SCENE, bus) as DayReport
	report.set_artist_config(catalog)


## UiPreset close 의 이벤트(데이터 기준 시나리오 값)를 버스로 발행한다.
func _publish_show_day() -> Array:
	var evs: Array = UiPreset.events(UiPreset.CLOSE, data, catalog)
	for ev: Array in evs:
		if ev[0] != "session.loaded":
			bus.publish(str(ev[0]), ev[1] as Dictionary)
	UiTestUtil.enter_phase(bus, UiTestUtil.close_phase(), 3)
	return evs


func _payload(evs: Array, name: String) -> Dictionary:
	var out: Dictionary = {}
	for ev: Array in evs:
		if ev[0] == name:
			out = ev[1]
	return out


func test_rows_cover_r1_to_r13_in_params_order() -> void:
	var ids: PackedStringArray = report.get_row_ids()
	assert_eq(ids, UiParams.load_default().report_rows, "행 순서 = report_rows")
	assert_eq(ids, PackedStringArray(["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R13", "R9", "R10", "R11", "R12"]),
		"SE-039 2차 확정 순서(show.md)")
	for r: String in R_ALL:
		assert_true(ids.has(r), "%s 행 존재(필드 누락 0)" % r)


func test_show_day_shows_all_fields() -> void:
	var evs: Array = _publish_show_day()
	assert_true(report.visible, "close 에서 보임")
	for r: String in R_ALL:
		assert_true(report.is_row_visible(r), "%s 보임" % r)
		assert_false(report.get_row_text(r).is_empty(), "%s 문구" % r)
	var s: Dictionary = _payload(evs, "economy.day_settled")
	var ended: Dictionary = _payload(evs, "show.ended")
	assert_true(report.get_row_text("R6").contains(str(s["revenue"])), "R6 매출")
	assert_true(report.get_row_text("R7").contains(str(s["rent"])), "R7 비용")
	assert_true(report.get_row_text("R8").contains(str(s["net"])), "R8 순이익")
	assert_true(report.get_row_text("R4").contains(str(ended["admissions"])), "R4 관객")
	assert_true(report.get_row_text("R3").contains(data.grade_name(str(ended["grade"]))), "R3 등급 이름 = show.json grades[].name")
	var name: String = str(catalog.artist(str(ended["artist_id"]))["name"])
	assert_true(report.get_row_text("R2").contains(name), "R2 아티스트 이름")
	var rep: Dictionary = _payload(evs, "reputation.changed")
	assert_true(report.get_row_text("R9").contains("+%d" % int(rep["delta"])), "R9 부호 표시")


func test_no_show_day_hides_r3_r5_r11() -> void:
	bus.publish("show.skipped", {"day": 1, "reason": "no_lineup"})
	bus.publish("economy.day_settled", {"day": 1, "net": -5, "cash": 10, "revenue": 0})
	UiTestUtil.enter_phase(bus, UiTestUtil.close_phase(), 1)
	for r: String in ["R3", "R5", "R11"]:
		assert_false(report.is_row_visible(r), "%s 숨김" % r)
	assert_true(report.get_row_text("R9").begins_with("ui.report.r9_none"), "R9 변화 없음")
	assert_true(report.get_row_text("R2").contains("ui.report.skip.no_lineup"), "R2 공연 없음 사유")
	assert_true(report.is_row_visible("R1") and report.is_row_visible("R12"), "나머지는 보임")


func test_next_day_publishes_once_and_only_in_close() -> void:
	_publish_show_day()
	report.get_next_button().pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "time.next_day_requested"), [{}], "다음 날 1건")
	UiTestUtil.enter_phase(bus, UiTestUtil.phase_ids()[0], 4)
	assert_false(report.visible, "close 외 구간 숨김")
	report.get_next_button().pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "time.next_day_requested").size(), 1, "close 밖에서는 발행 안 함")


func test_hidden_outside_close() -> void:
	for ph: String in UiTestUtil.phase_ids():
		UiTestUtil.enter_phase(bus, ph)
		assert_eq(report.visible, ph == UiTestUtil.close_phase(), "%s 구간 보임 = close" % ph)


func test_unlock_progress_reads_tiers_json() -> void:
	var tiers: Array = UiTestUtil.json(UiTestUtil.TIERS_PATH)["rows"]
	var next: Dictionary = data.next_tier_row(data.current_tier)
	assert_false(next.is_empty())
	_publish_show_day()
	var txt: String = report.get_row_text("R12")
	assert_true(txt.contains(str(int(next["unlock_reputation"]))) and txt.contains(str(int(next["unlock_cash"]))),
		"R12 다음 티어 조건(tiers.json): %s" % txt)
	assert_gt(tiers.size(), 1)
	bus.publish("reputation.tier_unlocked", {"tier": int(next["tier"]), "day": 3})
	assert_true(report.get_row_text("R12").begins_with("ui.report.r12_unlocked"), "해금 문구")


func test_day_started_clears_previous_day() -> void:
	_publish_show_day()
	bus.publish("time.day_started", {"day": 4})
	assert_false(report.has_show(), "새 날에는 공연 값 초기화")
	assert_true(report.get_row_text("R9").begins_with("ui.report.r9_none"))


func test_bankrupt_disables_next_day() -> void:
	_publish_show_day()
	bus.publish("economy.bankrupt", {"day": 3, "cash": -1, "bailouts_used": 2})
	assert_true(report.get_next_button().disabled, "파산 뒤 다음 날 비활성")
	assert_true(report.get_row_text("R13").begins_with("ui.report.r13_bankrupt"))


## SE-035 인계: R4 는 실제 audience.day_summary 형식(by_type = audience.json 유형 전부, left_early > 0)으로 확인.
func test_r4_uses_real_day_summary_shape() -> void:
	var by_type: Dictionary = {}
	var adm: int = 0
	var left: int = 0
	var i: int = 0
	for ty: Dictionary in UiTestUtil.json("res://data/audience/audience.json")["types"]:
		i += 1
		by_type[str(ty["id"])] = {"admissions": 10 * i, "left_early": i, "avg_satisfaction_bp": 6000}
		adm += 10 * i
		left += i
	bus.publish("audience.day_summary", {"day": 2, "has_lineup": true, "admissions": adm, "audience": adm - left, "left_early": left,
		"bar_buyers": 7, "avg_satisfaction_bp": 6100, "crowd_bp": 5000,
		"avg_components": {"lineup_bp": 6100, "sound_bp": 7000, "sight_bp": 6500, "value_bp": 5900, "wait_bp": 8000}, "by_type": by_type})
	bus.publish("show.ended", {"day": 2, "artist_id": "x", "satisfaction_bp": 6100, "grade": "good", "admissions": adm,
		"audience": adm - left, "revenue_hint": 0, "incidents": []})
	UiTestUtil.enter_phase(bus, UiTestUtil.close_phase(), 2)
	var r4: String = report.get_row_text("R4")
	assert_true(r4.contains(str(adm)) and r4.contains(str(adm - left)) and r4.contains(str(left)), "R4 입장·관람·조기 퇴장: %s" % r4)
	assert_true(report.get_row_text("R5").contains("70"), "R5 sound_bp ÷ 100")


## SE-049: 불러오기 직후 close 면 show.ended 가 재발행되지 않는다 → 공연 칸 숨김, R1 은 session.loaded day.
func test_loaded_in_close_without_events() -> void:
	bus.publish("session.loaded", {"day": 15, "phase": UiTestUtil.close_phase(), "speed": 0, "show_active": false})
	assert_true(report.visible)
	assert_true(report.get_row_text("R1").contains("15"), "R1 = loaded day")
	assert_false(report.is_row_visible("R3"), "공연 값 없음 → 숨김")


## SE-039-bug 회귀: 불러오기 직후 close(실제 ui_ko.json) — 보이는 모든 텍스트에 ui.* 키 폴백 0건, R2 숨김.
func test_loaded_close_leaks_no_keys_se039_bug() -> void:
	var s: GridSandbox = (load("res://view/scenes/grid_sandbox.tscn") as PackedScene).instantiate() as GridSandbox
	add_child_autofree(s)
	assert_true(s.setup_ui(UiPreset.DAY))
	var r: UiRoot = s.get_ui_root()
	var close: String = UiTestUtil.close_phase()
	r.inject("session.loaded", {"day": 3, "phase": close, "speed": 0, "show_active": false})
	r.inject("time.phase_changed", {"from": "show", "to": close, "day": 3, "tick": 0})
	assert_true(r.day_report.visible, "close 리포트 보임")
	assert_false(r.day_report.is_row_visible("R2"), "라인업 정보 없음 → R2 숨김")
	var re: RegEx = RegEx.create_from_string("(^|\\s)ui\\.[a-z0-9_]+\\.")
	var texts: PackedStringArray = PackedStringArray()
	_screen_texts(r.day_report, texts)
	assert_gt(texts.size(), 5, "보이는 텍스트 수집")
	var bad: PackedStringArray = PackedStringArray()
	for t: String in texts:
		if re.search(t) != null:
			bad.append(t)
	assert_eq(bad.size(), 0, "키 폴백 노출 0: %s" % " | ".join(bad))
	# 대조: 같은 정규식이 키 문자열은 잡는다.
	assert_not_null(re.search("공연 · ui.artist.grade."), "대조군")


func test_lineup_info_shows_r2_again() -> void:
	bus.publish("session.loaded", {"day": 3, "phase": UiTestUtil.close_phase(), "speed": 0, "show_active": false})
	assert_false(report.is_row_visible("R2"))
	bus.publish("show.skipped", {"day": 3, "reason": "no_stage"})
	assert_true(report.is_row_visible("R2"), "건너뜀 사유가 오면 R2 보임")


## 보이는 Label/Button 텍스트(숨긴 노드·CanvasLayer 제외) — test_ui_text_table._screen_texts 와 같은 규칙.
func _screen_texts(n: Node, out: PackedStringArray) -> void:
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is CanvasLayer and not (n as CanvasLayer).visible:
		return
	if n is Label:
		out.append((n as Label).text)
	elif n is Button:
		out.append((n as Button).text)
	for c: Node in n.get_children():
		_screen_texts(c, out)
