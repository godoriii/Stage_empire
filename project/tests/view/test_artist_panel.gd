extends GutTest
## SE-039 AC2: 섭외 패널. 행 수·임계는 artists.json·artist.json 에서 읽는다(리터럴 없음).

const SCENE: String = "res://ui/panels/artist_panel.tscn"
const NOTIFY_SCENE: String = "res://ui/panels/notifications.tscn"

var bus: EventBus
var panel: ArtistPanel
var catalog: UiArtistCatalog


func before_each() -> void:
	bus = EventBus.new()
	catalog = UiArtistCatalog.load_default()
	panel = UiTestUtil.make_panel(self, SCENE, bus) as ArtistPanel
	panel.set_sources(catalog, null)


func _ids() -> Array[String]:
	var out: Array[String] = []
	for r: Dictionary in UiTestUtil.json(UiTestUtil.ARTISTS_PATH)["rows"]:
		out.append(str(r["id"]))
	return out


func test_rows_match_artists_json() -> void:
	var ids: Array[String] = _ids()
	var rows: Array[Control] = panel.get_rows()
	assert_eq(rows.size(), ids.size(), "행 수 = artists.json rows")
	for i: int in range(ids.size()):
		assert_eq(str(rows[i].get_meta(ArtistPanel.META_ARTIST_ID)), ids[i], "순서 %d" % i)


func test_row_shows_name_genre_guarantee_bio() -> void:
	var data: UiData = UiData.load_default()
	var eco: Dictionary = UiTestUtil.json(UiTestUtil.ECONOMY_PATH)
	var bios: Dictionary = UiTestUtil.json("res://data/text/artists_ko.json")["strings"]
	panel.setup(bus, data, UiText.load_default(PackedStringArray([UiText.ARTISTS_PATH])), UiParams.load_default())
	for r: Dictionary in UiTestUtil.json(UiTestUtil.ARTISTS_PATH)["rows"]:
		var txt: String = panel.get_row_text(str(r["id"]))
		assert_true(txt.contains(str(r["name"])), "이름 %s" % r["name"])
		assert_true(txt.contains(data.genre_name(str(r["genre"]))), "장르 이름")
		assert_true(txt.contains(str(int(eco["guarantee_by_grade"][r["grade"]]))), "개런티")
		assert_true(txt.contains(str(int(r["popularity"]))), "인기")
		assert_true(txt.contains(str(bios[r["bio_key"]])), "바이오(artists_ko.json)")


func test_locked_grade_disabled_until_reputation() -> void:
	var grade: String = UiTestUtil.locked_grade()
	var need: int = UiTestUtil.unlock_of(grade)
	var id: String = UiTestUtil.first_artist_of_grade(grade)
	UiTestUtil.enter_phase(bus, UiTestUtil.booking_phase())
	bus.publish("reputation.changed", {"day": 1, "delta": 0, "total": need - 1, "by_genre": {}})
	assert_true(panel.get_book_button(id).disabled, "total < 임계 → 비활성")
	assert_eq(panel.book_reason(id), ArtistPanel.R_GRADE_LOCKED)
	assert_true(panel.get_status_text(id).contains(str(need)), "잠김 문구에 임계 N")
	bus.publish("reputation.changed", {"day": 2, "delta": 1, "total": need, "by_genre": {}})
	assert_false(panel.get_book_button(id).disabled, "total ≥ 임계 → 활성")


func test_book_click_publishes_one_request() -> void:
	UiTestUtil.enter_phase(bus, UiTestUtil.booking_phase())
	var id: String = _ids()[0]
	panel.get_book_button(id).pressed.emit()
	assert_eq(UiTestUtil.commands(bus, "artist.book_requested"), [{"artist_id": id}])


func test_booked_marks_row_and_blocks_others() -> void:
	UiTestUtil.enter_phase(bus, UiTestUtil.booking_phase())
	var ids: Array[String] = _ids()
	bus.publish("artist.booked", {"day": 1, "artist_id": ids[0], "grade": "local", "guarantee": 1})
	assert_eq(panel.get_status_text(ids[0]), "ui.artist.status.today", "행 상태 오늘 공연")
	for id: String in ids:
		assert_true(panel.get_book_button(id).disabled, "하루 1명: %s 비활성" % id)
	bus.publish("time.day_started", {"day": 2})
	UiTestUtil.enter_phase(bus, UiTestUtil.booking_phase(), 2)
	assert_false(panel.get_book_button(ids[0]).disabled, "다음 날 다시 가능")


func test_buttons_disabled_outside_booking_phase() -> void:
	for ph: String in UiTestUtil.phase_ids():
		UiTestUtil.enter_phase(bus, ph)
		var allowed: bool = (UiTestUtil.json(UiTestUtil.ARTIST_PATH)["booking_phases"] as Array).has(ph)
		var any_enabled: bool = false
		for id: String in _ids():
			any_enabled = any_enabled or not panel.get_book_button(id).disabled
		assert_eq(any_enabled, allowed, "%s 구간 활성 버튼 유무 = booking_phases 포함" % ph)


func test_booking_rejected_adds_one_notification() -> void:
	var feed: Notifications = UiTestUtil.make_panel(self, NOTIFY_SCENE, bus) as Notifications
	bus.publish("artist.booking_rejected", {"day": 1, "artist_id": _ids()[0], "reason": "insufficient_cash"})
	assert_eq(feed.get_entries().size(), 1, "알림 1건")
	assert_true(feed.get_entry_texts()[0].contains("ui.reason.artist.insufficient_cash"), "reason 키")


func test_system_check_book_and_roster_are_used() -> void:
	var fake: FakeArtistSystem = FakeArtistSystem.new()
	var ids: Array[String] = _ids()
	fake.reason_by_id[ids[0]] = "insufficient_cash"
	fake.rows = [{"id": ids[1], "grade": catalog.artist(ids[1])["grade"], "popularity": 99, "skill": 88,
		"shows_played": 3, "discovered_here": false, "relationship": 0}]
	panel.set_sources(catalog, fake)
	UiTestUtil.enter_phase(bus, UiTestUtil.booking_phase())
	assert_true(panel.get_book_button(ids[0]).disabled, "check_book != \"\" → 비활성")
	assert_false(panel.get_book_button(ids[1]).disabled)
	assert_true(panel.get_row_text(ids[1]).contains("99"), "roster() 동적 값(인기)")
	bus.publish("artist.grown", {"day": 1, "artist_id": ids[1], "grade": catalog.artist(ids[1])["grade"], "popularity": 77,
		"skill": 66, "popularity_delta": 1, "skill_delta": 1, "shows_played": 4, "promoted": false})
	assert_true(panel.get_row_text(ids[1]).contains("77"), "artist.grown 갱신")
	for c: String in fake.calls:
		assert_true(["roster", "entry", "check_book"].has(c), "허용 멤버만 호출: %s" % c)
