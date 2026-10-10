extends GutTest
## SE-036 GameSession: AC1(systems 키), AC-33a(생성·등록 순서, 저녁 진입 이벤트 순서, artist 설정·스냅샷 누락 실패),
## AC-35a/b(실제 audience 포함 하루 이벤트 순서·라인업 없는 날), AC5(오토세이브·경계), AC6(session 명령·재발행 규칙),
## SE-049(session.loaded 4필드, 공연 중 로드 → 연속 진행과 동일). docs/tickets/SE-036.md, docs/gdd/tick.md#스냅샷.

const DIR: String = "user://test_se036_session"
const SEED: int = 36
const ARTIST: String = "thumbnail_soda"
const LAYOUT: String = "baseline_show"
const SYSTEMS: Array[String] = ["build", "artist", "audience", "show", "economy", "reputation"]
const RELOAD_EVENTS: Array[String] = [
	"session.loaded", "build.placed", "build.coverage_changed", "reputation.changed", "show.started", "time.phase_changed",
	"artist.lineup_set", "economy.cash_changed", "time.day_started", "audience.admissions_decided",
]
## 연속 진행 비교에 쓰는 이벤트(tick.advanced·audience.agent_moved 는 상태 해시가 대신한다).
const COMPARE_EVENTS: Array[String] = [
	"time.phase_changed", "time.day_started", "time.speed_changed", "build.coverage_changed", "artist.lineup_set",
	"artist.grown", "audience.admissions_decided", "audience.agent_left", "audience.day_summary", "economy.sales_reported",
	"show.started", "show.skipped", "show.ended", "reputation.changed", "economy.cash_changed", "economy.day_settled",
	"reputation.tier_unlocked",
]

var _cfgs: Dictionary


func before_all() -> void:
	_cfgs = GameSession.load_configs()


func after_each() -> void:
	_rm_dir(DIR)


# --- 도우미 ----------------------------------------------------------------------

func _session(layout: bool = true, seed_value: int = SEED) -> GameSession:
	var s: GameSession = GameSession.new()
	assert_true(s.new_game_from_configs(seed_value, _cfgs), "new_game 성공")
	s.saves_dir = DIR
	if layout:
		var bcfg: BuildConfig = _cfgs["build"]
		for p: Dictionary in bcfg.layout(LAYOUT)["placements"]:
			s.bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
		s.advance(0)
	return s


func _day_ticks() -> int:
	var c: SimConfig = _cfgs["sim"]
	return c.phase_ticks("day") + c.phase_ticks("evening") + c.phase_ticks("show")


func _book(s: GameSession) -> void:
	s.bus.publish("artist.book_requested", {"artist_id": ARTIST})
	s.advance(0)


static func _hash(v: Variant) -> String:
	return JSON.stringify(v, "", true)


func _rm_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


func _push_warnings() -> int:
	var n: int = 0
	for e: Variant in get_errors():
		if e.is_push_warning():
			n += 1
	return n


# --- AC1 · AC-33a ------------------------------------------------------------------

func test_systems_keys_in_system_order() -> void:
	var s: GameSession = _session(false)
	var snap: Dictionary = s.snapshot()
	assert_eq(snap.keys().size(), TickLoop.SNAPSHOT_KEYS.size(), "최상위 10키")
	assert_eq((snap["systems"] as Dictionary).keys(), SYSTEMS, "systems 키 = system_order 순, staff·crisis 없음")
	assert_not_null(s.build)
	assert_not_null(s.artist)
	assert_not_null(s.audience)
	assert_not_null(s.show)
	assert_not_null(s.economy)
	assert_not_null(s.reputation)
	assert_eq(s.bus, s.loop.bus, "bus 는 TickLoop 의 버스")
	assert_eq(s.audience.rng, s.loop.rng, "audience 는 TickLoop 의 SeededRng 를 쓴다(SE-034-bug)")


func test_new_game_fails_without_artist_config() -> void:
	var cfgs: Dictionary = _cfgs.duplicate()
	cfgs["artist"] = null
	var s: GameSession = GameSession.new()
	assert_false(s.new_game_from_configs(SEED, cfgs), "ArtistConfig null → 실패")
	assert_push_error("'artist'")
	assert_push_error_count(1)
	assert_null(s.loop, "세션은 만들어지지 않는다")
	assert_true(s.new_game_from_configs(SEED, _cfgs), "실패 뒤 정상 설정으로는 시작할 수 있다")
	assert_false(s.new_game_from_configs(SEED, _cfgs), "두 번째 new_game 은 거부")
	assert_push_error_count(2)


func test_restore_fails_without_artist_entry() -> void:
	var s: GameSession = _session(false)
	var snap: Dictionary = s.snapshot()
	var before: String = _hash(snap)
	(snap["systems"] as Dictionary).erase("artist")
	assert_false(s.restore(snap), "systems.artist 없음 → 복원 실패")
	assert_push_error("artist")
	assert_push_error_count(1)
	assert_eq(_hash(s.snapshot()), before, "상태 불변")


func test_new_game_from_data_root() -> void:
	var s: GameSession = GameSession.new()
	assert_true(s.new_game(SEED, "res://data"), "기본 data_root 로 시작")
	assert_eq(s.loop.master_seed, SEED)
	assert_eq(s.cash(), s.economy.cash)


## AC-33a: 저녁 진입 틱 = time.phase_changed → build.coverage_changed(sync) → artist.lineup_set → time.speed_changed → tick.advanced.
func test_evening_entry_event_order() -> void:
	var s: GameSession = _session()
	_book(s)
	s.bus.publish("time.speed_requested", {"speed": 3})
	s.advance(0)
	var rec: EventRecorder = EventRecorder.new(s.bus, [
		"time.phase_changed", "build.coverage_changed", "artist.lineup_set", "time.speed_changed", "tick.advanced",
	])
	var c: SimConfig = _cfgs["sim"]
	s.advance(c.phase_ticks("day") - 1)
	rec.clear()
	assert_eq(s.advance(1), 1)
	assert_eq(rec.names(), ["time.phase_changed", "build.coverage_changed", "artist.lineup_set", "time.speed_changed", "tick.advanced"])
	assert_eq(rec.of("build.coverage_changed")[0]["cause"], "sync")
	assert_eq(rec.of("artist.lineup_set")[0]["artist_id"], ARTIST)


# --- AC-35a · AC-35b ---------------------------------------------------------------

func test_full_day_last_show_tick_order() -> void:
	var s: GameSession = _session()
	_book(s)
	var rec: EventRecorder = EventRecorder.new(s.bus, [
		"audience.day_summary", "show.ended", "artist.grown", "reputation.changed", "economy.sales_reported",
		"time.phase_changed", "economy.day_settled", "show.started", "audience.admissions_decided", "time.speed_changed",
		"show.skipped",
	])
	s.advance(_day_ticks() - 1)
	var names: Array[String] = rec.names()
	var i_show: int = -1
	for i: int in names.size():
		if names[i] == "time.phase_changed" and rec.events[i][1]["to"] == "show":
			i_show = i
	assert_gt(i_show, -1, "show 진입")
	assert_eq(names[i_show + 1], "show.started", "show.started 는 phase:show 직후")
	assert_eq(rec.of("show.started")[0]["expected_admissions"], rec.of("audience.admissions_decided")[0]["admissions"],
		"expected_admissions == admissions_decided.admissions")
	rec.clear()
	assert_eq(s.advance(1), 1)
	var last: Array[String] = rec.names().filter(func(n: String) -> bool: return n != "time.speed_changed")
	assert_eq(last, [
		"audience.day_summary", "show.ended", "artist.grown", "reputation.changed", "economy.sales_reported",
		"time.phase_changed", "economy.day_settled",
	], "공연 마지막 틱 순서")
	assert_eq(rec.of("time.phase_changed")[0]["to"], "close")
	assert_eq(_push_warnings(), 0, "push_warning 0")


func test_no_lineup_day() -> void:
	var s: GameSession = _session()
	var rec: EventRecorder = EventRecorder.new(s.bus, [
		"audience.admissions_decided", "show.skipped", "audience.day_summary", "show.ended", "reputation.changed", "show.started",
	])
	assert_eq(s.advance(_day_ticks()), _day_ticks())
	assert_eq(rec.of("audience.admissions_decided").size(), 1)
	assert_eq(rec.of("audience.admissions_decided")[0]["has_lineup"], false)
	assert_eq(rec.of("show.skipped"), [{"day": 1, "reason": "no_lineup"}])
	assert_eq(rec.of("audience.day_summary").size(), 1)
	assert_eq(rec.of("audience.day_summary")[0]["has_lineup"], false)
	assert_eq(rec.count("show.ended"), 0)
	assert_eq(rec.count("show.started"), 0)
	assert_eq(rec.count("reputation.changed"), 0)
	assert_eq(_push_warnings(), 0)


# --- AC5 오토세이브 --------------------------------------------------------------------

func test_autosave_each_close_and_keep() -> void:
	var s: GameSession = _session(false)
	s.autosave_keep = 2
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.saved"])
	var close_hash: Array = []
	for d: int in range(3):
		assert_eq(s.advance(_day_ticks()), _day_ticks())
		assert_eq(s.loop.phase, "close")
		close_hash.append(_hash(s.snapshot()))
		assert_eq(s.last_autosave_path, DIR.path_join("autosave_day%d.sav" % (d + 1)))
		assert_eq(_hash(SaveFile.read(s.last_autosave_path)), close_hash[d], "오토세이브 = close 진입 경계 상태(정산 포함)")
		s.bus.publish("time.next_day_requested", {})
		s.advance(0)
	assert_eq(rec.of("session.saved"), [
		{"slot": "autosave_day1", "day": 1}, {"slot": "autosave_day2", "day": 2}, {"slot": "autosave_day3", "day": 3},
	])
	assert_eq(s.list_autosave_days(), [2, 3], "보관 수 2 초과분(1일차) 삭제")


func test_autosave_unlimited_by_default_and_disable() -> void:
	var s: GameSession = _session(false)
	assert_eq(s.autosave_keep, GameSession.KEEP_UNLIMITED, "데이터 필드가 없으면 무제한")
	for d: int in range(2):
		s.advance(_day_ticks())
		s.bus.publish("time.next_day_requested", {})
		s.advance(0)
	s.autosave_enabled = false
	s.advance(_day_ticks())
	assert_eq(s.list_autosave_days(), [1, 2], "무제한 보관, 끈 뒤에는 쓰지 않는다")


## 오토세이브는 close 진입 틱 안(핸들러)이 아니라 advance 반환 뒤 경계에서 쓴다. 경계 밖 save_to/load_from 은 false.
func test_save_outside_boundary_rejected() -> void:
	var s: GameSession = _session(false)
	var seen: Array = []
	var path: String = DIR.path_join("inside.sav")
	var on_tick: Callable = func(p: Dictionary) -> void:
		if p["phase"] == "close":
			seen.append(FileAccess.file_exists(s.autosave_path(1)))
			seen.append(s.save_to(path))
			seen.append(s.load_from(path))
			seen.append(s.advance(1))
	s.bus.subscribe("tick.advanced", on_tick)
	s.advance(_day_ticks())
	assert_eq(seen, [false, false, false, 0], "틱 안: 오토세이브 아직 없음, save_to·load_from false, advance 0")
	assert_push_error_count(3, "GameSession 경계 거부 push_error 3")
	assert_true(FileAccess.file_exists(s.autosave_path(1)), "advance 반환 뒤 오토세이브")
	assert_false(FileAccess.file_exists(path))
	s.bus.unsubscribe("tick.advanced", on_tick)
	assert_true(s.save_to(path), "경계에서는 저장된다")


# --- AC6 session 명령 · 재발행 ------------------------------------------------------------

func test_save_and_load_commands() -> void:
	var s: GameSession = _session()
	_book(s)
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.saved", "session.save_failed", "session.load_failed", "session.loaded"])
	assert_true(s.bus.publish("session.save_requested", {"slot": "slot1"}), "명령 큐")
	assert_false(FileAccess.file_exists(s.slot_path("slot1")), "경계 처리 전에는 저장하지 않는다")
	s.advance(0)
	var saved_hash: String = _hash(s.snapshot())
	assert_eq(rec.of("session.saved"), [{"slot": "slot1", "day": 1}])
	assert_eq(_hash(SaveFile.read(s.slot_path("slot1"))), saved_hash, "경계 상태가 저장됐다")
	s.advance(500)
	var moved_hash: String = _hash(s.snapshot())
	s.bus.publish("session.load_requested", {"slot": "nope"})
	s.bus.publish("session.load_requested", {"slot": "../x"})
	s.bus.publish("session.save_requested", {"slot": ""})
	s.advance(0)
	assert_eq(rec.of("session.load_failed"), [{"slot": "nope", "reason": "not_found"}, {"slot": "../x", "reason": "bad_slot"}])
	assert_eq(rec.of("session.save_failed"), [{"slot": "", "reason": "bad_slot"}])
	assert_eq(_hash(s.snapshot()), moved_hash, "실패한 로드는 상태 불변")
	assert_push_error_count(1, "파일 없음 1")
	s.bus.publish("session.load_requested", {"slot": "slot1"})
	s.advance(0)
	assert_eq(rec.of("session.loaded"), [{"day": 1, "phase": "day", "speed": 1, "show_active": false}])
	assert_eq(_hash(s.snapshot()), saved_hash, "로드 = 저장 시점 상태")


## 재발행 규칙: session.loaded → build.placed(설치 순서 전부, 원래 페이로드와 같음) → build.coverage_changed{sync} →
## reputation.changed{delta 0}. show.started·time.phase_changed·artist.lineup_set·economy.cash_changed 재발행 0.
## 재발행 뒤 상태 해시 == 파일 스냅샷 해시(구독 시스템 상태 불변).
func test_reload_republish_rules() -> void:
	var c: SimConfig = _cfgs["sim"]
	var s: GameSession = GameSession.new()
	s.new_game_from_configs(SEED, _cfgs)
	s.saves_dir = DIR
	var placed_rec: EventRecorder = EventRecorder.new(s.bus, ["build.placed", "build.coverage_changed"])
	var bcfg: BuildConfig = _cfgs["build"]
	for p: Dictionary in bcfg.layout(LAYOUT)["placements"]:
		s.bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
	s.advance(0)
	_book(s)
	s.advance(c.phase_ticks("day") + c.phase_ticks("evening") + 10)    # 공연 10틱째
	var path: String = DIR.path_join("show.sav")
	assert_true(s.save_to(path))
	var saved_hash: String = _hash(s.snapshot())
	var s2: GameSession = GameSession.new()
	s2.new_game_from_configs(1, _cfgs)
	var rec: EventRecorder = EventRecorder.new(s2.bus, RELOAD_EVENTS)
	assert_true(s2.load_from(path))
	var names: Array[String] = rec.names()
	var n_placed: int = s.build.instances.size()
	var expect: Array[String] = ["session.loaded"]
	for i: int in range(n_placed):
		expect.append("build.placed")
	expect.append_array(["build.coverage_changed", "reputation.changed"])
	assert_eq(names, expect, "재발행 순서, 그 밖 이벤트 0")
	assert_eq(rec.of("session.loaded")[0], {"day": 1, "phase": "show", "speed": 1, "show_active": true}, "공연 중 로드 → show_active true")
	assert_eq(_hash(rec.of("build.placed")), _hash(placed_rec.of("build.placed")), "build.placed 페이로드 = 원래 설치 이벤트")
	var cov: Dictionary = rec.of("build.coverage_changed")[0]
	var orig_cov: Dictionary = placed_rec.of("build.coverage_changed")[-1]
	assert_eq(cov["cause"], "sync")
	cov.erase("cause")
	orig_cov.erase("cause")
	assert_eq(_hash(cov), _hash(orig_cov), "커버리지 = 마지막 커버리지(cause 만 sync)")
	var rc: Dictionary = rec.of("reputation.changed")[0]
	assert_eq([rc["delta"], rc["total"]], [0, s.reputation_total()])
	assert_eq(_hash(s2.snapshot()), saved_hash, "재발행 뒤 해시 == 저장 시점 해시")
	assert_eq(s2.hud_state(), s.hud_state(), "HUD 접근자(cash 등) 동일")
	assert_eq(s2.cash(), s.economy.cash, "economy 는 재발행 없이 cash() 로 읽는다")


## AC3(공연 중): 공연 중 저장 → 새 세션 로드 → close 까지 진행한 상태 해시·이벤트 열 == 연속 진행.
func test_mid_show_load_matches_continuous() -> void:
	var c: SimConfig = _cfgs["sim"]
	var s: GameSession = _session()
	_book(s)
	var mid: int = c.phase_ticks("day") + c.phase_ticks("evening") + c.phase_ticks("show") / 2
	s.advance(mid)
	var path: String = DIR.path_join("mid.sav")
	assert_true(s.save_to(path))
	var rec_a: EventRecorder = EventRecorder.new(s.bus, COMPARE_EVENTS)
	s.advance(_day_ticks())
	var s2: GameSession = GameSession.new()
	s2.new_game_from_configs(SEED + 1, _cfgs)
	s2.saves_dir = DIR
	assert_true(s2.load_from(path))
	assert_true(s2.show_active())
	var rec_b: EventRecorder = EventRecorder.new(s2.bus, COMPARE_EVENTS)
	s2.advance(_day_ticks())
	assert_eq(s2.loop.phase, "close")
	assert_eq(_hash(s2.snapshot()), _hash(s.snapshot()), "close 상태 해시 동일")
	assert_eq(rec_b.to_json(), rec_a.to_json(), "이벤트 열 동일")
	assert_gt(rec_a.count("show.ended"), 0)
	assert_false(s2.show_active(), "공연 끝")
