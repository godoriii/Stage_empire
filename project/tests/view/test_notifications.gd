extends GutTest
## SE-039: 우측 알림 피드 — 거절·실패 이벤트마다 1줄, 최대 줄 수는 UiParams.

const SCENE: String = "res://ui/panels/notifications.tscn"

var bus: EventBus
var feed: Notifications


func before_each() -> void:
	bus = EventBus.new()
	feed = UiTestUtil.make_panel(self, SCENE, bus, UiTestUtil.fixture_text()) as Notifications


func test_each_rejection_source_adds_one_entry() -> void:
	var evs: Array = [
		["build.rejected", {"action": "place", "reason": "overlap", "furniture_id": null, "cell": null, "rotation": null, "entity_id": null}],
		["artist.booking_rejected", {"day": 1, "artist_id": "x", "reason": "grade_locked"}],
		["economy.ticket_price_rejected", {"price": 99, "reason": "out_of_range", "phase": "day"}],
		["time.speed_rejected", {"speed": 3, "reason": "not_allowed", "phase": "show"}],
		["session.load_failed", {"slot": "1", "reason": "missing"}],
	]
	var n: int = 0
	for ev: Array in evs:
		bus.publish(str(ev[0]), ev[1] as Dictionary)
		n += 1
		var texts: PackedStringArray = feed.get_entry_texts()
		assert_eq(texts.size(), mini(n, UiParams.load_default().notification_max), "%s → 1줄" % ev[0])
		var src: String = str(Notifications.SOURCES[ev[0]])
		assert_true(texts[texts.size() - 1].contains("%s.%s" % [src, (ev[1] as Dictionary)["reason"]]) or src == "artist",
			"reason 키: %s" % texts[texts.size() - 1])


func test_fixture_text_formats_reason() -> void:
	bus.publish("artist.booking_rejected", {"day": 1, "artist_id": "x", "reason": "insufficient_cash"})
	assert_eq(feed.get_entry_texts(), PackedStringArray(["N_artist:cash!"]))


func test_feed_is_capped_by_params() -> void:
	var cap: int = UiParams.load_default().notification_max
	for i: int in range(cap + 3):
		bus.publish("time.speed_rejected", {"speed": i, "reason": "not_allowed", "phase": "show"})
	assert_eq(feed.get_entries().size(), cap, "최대 줄 수 = notification_max")


func test_saved_adds_confirmation() -> void:
	bus.publish("session.saved", {"slot": "2", "day": 7})
	assert_eq(feed.get_entries().size(), 1)
	assert_true(feed.get_entry_texts()[0].contains("2") and feed.get_entry_texts()[0].contains("7"))
