extends GutTest
## SE-036 GameSession: AC1(systems 키), AC-33a(생성·등록 순서, 저녁 진입 이벤트 순서, artist 설정·스냅샷 누락 실패),
## AC-35a/b(실제 audience 포함 하루 이벤트 순서·라인업 없는 날), AC5(오토세이브·경계), AC6(session 명령·재발행 규칙),
## SE-049(session.loaded 4필드, 공연 중 로드 → 연속 진행과 동일). docs/tickets/SE-036.md, docs/gdd/tick.md#스냅샷.
## SE-056 AC1~AC5(session.* 계약 SN1~SN5, docs/gdd/events.md #session-명령-규칙)는 파일 끝 절.

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
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.saved", "session.load_failed", "session.loaded"])
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
	assert_eq(rec.of("session.load_failed"), [{"slot": "nope", "reason": "missing"}, {"slot": "../x", "reason": "invalid"}],
		"SE-056: SN4 사유 이름(missing·invalid)")
	assert_eq(rec.count("session.saved"), 1, "SE-056 SN3: 잘못된 슬롯 저장은 이벤트 없음")
	assert_eq(_hash(s.snapshot()), moved_hash, "실패한 로드는 상태 불변")
	assert_push_error_count(1, "SE-056: 잘못된 슬롯 저장 push_error 1, 불러오기 ①②는 0")
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


# --- SE-056 session.* 계약(events.md SN1~SN5) ---------------------------------------------

const SESSION_EVENTS: Array[String] = ["session.saved", "session.loaded", "session.load_failed"]


## 저장된 슬롯 하나와 그 뒤로 500틱 움직인 세션. [세션, 움직인 상태 해시].
func _moved_session() -> Array:
	var s: GameSession = _session()
	_book(s)
	s.bus.publish("session.save_requested", {"slot": "good"})
	s.advance(0)
	s.advance(500)
	return [s, _hash(s.snapshot())]


## 세이브 파일 문서({header, snapshot})를 SaveFile 을 거치지 않고 그대로 쓴다.
func _write_doc(path: String, save_version: int, snap: Variant) -> void:
	var header: Dictionary = {"save_version": save_version, "written_day": 1}
	if snap is Dictionary:
		header["snapshot_schema_version"] = (snap as Dictionary).get("schema_version")
	_write_bytes(path, JSON.stringify({"header": header, "snapshot": snap}).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP))


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _load_reason(s: GameSession, payload: Dictionary) -> Array:
	var rec: EventRecorder = EventRecorder.new(s.bus, SESSION_EVENTS)
	s.bus.publish("session.load_requested", payload)
	s.advance(0)
	return rec.events


## AC1: SN4 5종, 판정 순서(겹치면 앞 사유), 상태 불변, push_error ①~④ 0 · ⑤ tick.md 규칙(TickLoop 1).
func test_se056_ac1_load_failed_reasons_in_sn4_order() -> void:
	var mv: Array = _moved_session()
	var s: GameSession = mv[0]
	var moved: String = mv[1]
	var snap: Dictionary = SaveFile.read(s.slot_path("good"))
	var v_bad: Dictionary = snap.duplicate(true)
	v_bad["schema_version"] = int(snap["schema_version"]) + 1
	var v_bad_noeco: Dictionary = v_bad.duplicate(true)
	(v_bad_noeco["systems"] as Dictionary).erase("economy")
	var no_systems: Dictionary = v_bad.duplicate(true)                 # 최상위 키 9개 + 버전 불일치 → corrupt 가 앞
	no_systems.erase("systems")
	var noeco: Dictionary = snap.duplicate(true)
	(noeco["systems"] as Dictionary).erase("economy")
	_write_bytes(s.slot_path("garbage"), "not a save file".to_utf8_buffer())
	_write_doc(s.slot_path("toplist"), 1, [1, 2, 3])
	_write_doc(s.slot_path("nosys"), 1, no_systems)
	_write_doc(s.slot_path("schema"), 1, v_bad)
	_write_doc(s.slot_path("schema_noeco"), 1, v_bad_noeco)
	_write_doc(s.slot_path("savever"), 2, snap)
	_write_doc(s.slot_path("noeco"), 1, noeco)
	var cases: Array = [
		[{"slot": "A"}, "invalid", "SN1 위반(대문자) — 파일도 없지만 ① 이 앞"],
		[{}, "invalid", "slot 키 없음"],
		[{"slot": 3}, "invalid", "String 아님"],
		[{"slot": "nope"}, "missing", "파일 없음"],
		[{"slot": "garbage"}, "corrupt", "gzip·JSON 아님"],
		[{"slot": "toplist"}, "corrupt", "snapshot 이 객체가 아님"],
		[{"slot": "nosys"}, "corrupt", "최상위 키 부족(버전도 틀리지만 ③ 이 앞)"],
		[{"slot": "schema"}, "version_mismatch", "schema_version != sim.json"],
		[{"slot": "savever"}, "version_mismatch", "save_version 2"],
		[{"slot": "schema_noeco"}, "version_mismatch", "버전 불일치 + restore 실패 조건 → ④ 가 앞"],
	]
	for c: Array in cases:
		var ev: Array = _load_reason(s, c[0])
		assert_eq(ev, [["session.load_failed", {"slot": (c[0] as Dictionary).get("slot"), "reason": c[1]}]], c[2])
		assert_eq(_hash(s.snapshot()), moved, "상태 불변: " + c[2])
	assert_push_error_count(0, "①~④ push_error 0")
	var ev5: Array = _load_reason(s, {"slot": "noeco"})
	assert_eq(ev5, [["session.load_failed", {"slot": "noeco", "reason": "restore_failed"}]], "⑤ restore() false")
	assert_eq(_hash(s.snapshot()), moved, "⑤ 상태 불변")
	assert_push_error_count(1, "⑤ = TickLoop.restore push_error 1(tick.md)")
	var ok: Array = _load_reason(s, {"slot": "good"})
	assert_eq(ok[0][0], "session.loaded", "정상 슬롯은 불러온다")


## AC2: 저장 실패(슬롯 위반·쓰기 실패) → 이벤트 0, push_error 1, 상태 불변. core 에 save_failed 문자열 0.
func test_se056_ac2_save_failure_no_event() -> void:
	var s: GameSession = _session(false)
	var before: String = _hash(s.snapshot())
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.saved", "session.save_failed", "session.load_failed", "session.loaded"])
	s.bus.publish("session.save_requested", {"slot": "Bad.Slot"})
	s.advance(0)
	assert_eq(rec.events, [], "슬롯 위반 → 이벤트 0")
	assert_push_error_count(1, "슬롯 위반 push_error 1")
	assert_eq(_hash(s.snapshot()), before)
	_write_bytes(DIR.path_join("blocker"), PackedByteArray([1]))
	s.saves_dir = DIR.path_join("blocker").path_join("sub")             # 부모가 파일 → 쓰기 실패
	s.bus.publish("session.save_requested", {"slot": "x"})
	s.advance(0)
	assert_eq(rec.events, [], "쓰기 실패 → 이벤트 0")
	assert_push_error_count(2, "쓰기 실패 push_error 1(SaveFile)")
	for e: Variant in get_errors():
		e.handled = true                                               # 디렉터리 생성 실패 엔진 오류
	assert_eq(_hash(s.snapshot()), before, "저장 실패는 상태 불변")
	for f: String in DirAccess.get_files_at("res://core"):
		if f.ends_with(".gd"):
			var src: String = FileAccess.get_file_as_string("res://core".path_join(f))
			for word: String in ["save_failed", "bad_slot", "not_found"]:
				assert_false(src.contains(word), "core/%s 에 '%s' 없음" % [f, word])


## AC3: SN1 슬롯 형식 ^[a-z0-9_]{1,24}$.
func test_se056_ac3_slot_format() -> void:
	var s: GameSession = _session(false)
	var rec: EventRecorder = EventRecorder.new(s.bus, SESSION_EVENTS)
	var too_long: String = "a".repeat(25)
	var max_len: String = "b".repeat(24)
	for bad: String in ["A", "a-b", too_long, "", "a.b", "a b"]:
		s.bus.publish("session.save_requested", {"slot": bad})
		s.advance(0)
		assert_false(FileAccess.file_exists(s.slot_path(bad)), "저장 안 됨: '%s'" % bad)
	assert_eq(rec.events, [], "SN1 위반 저장 6건 → 이벤트 0")
	assert_push_error_count(6)
	for good: String in ["autosave_day3", "1", max_len]:
		s.bus.publish("session.save_requested", {"slot": good})
	s.advance(0)
	assert_eq(rec.of("session.saved"), [{"slot": "autosave_day3", "day": 1}, {"slot": "1", "day": 1}, {"slot": max_len, "day": 1}])
	rec.clear()
	for bad: String in ["A", "a-b", too_long]:
		s.bus.publish("session.load_requested", {"slot": bad})
	s.bus.publish("session.load_requested", {"name": "1"})
	s.advance(0)
	assert_eq(rec.of("session.load_failed"), [
		{"slot": "A", "reason": "invalid"}, {"slot": "a-b", "reason": "invalid"}, {"slot": too_long, "reason": "invalid"},
		{"slot": null, "reason": "invalid"},
	], "키 없음 → slot null")
	s.bus.publish("session.load_requested", {"slot": "1"})
	s.advance(0)
	assert_eq(rec.count("session.loaded"), 1, "'1' 은 통과")


## AC4: SN2 — 같은 경계 [load, speed] 에서 불러오기 성공이면 뒤 명령 폐기, 실패면 적용. [load, save] 도 같다.
func test_se056_ac4_commands_after_load_dropped() -> void:
	var mv: Array = _moved_session()
	var s: GameSession = mv[0]
	var moved: String = mv[1]
	var saved: String = _hash(SaveFile.read(s.slot_path("good")))
	assert_eq(s.loop.speed, 1, "전제: 배속 1")
	var rec: EventRecorder = EventRecorder.new(s.bus, ["time.speed_changed", "session.loaded", "session.load_failed", "session.saved"])
	s.bus.publish("session.load_requested", {"slot": "nope"})
	s.bus.publish("time.speed_requested", {"speed": 3})
	s.advance(0)
	assert_eq(rec.names(), ["session.load_failed", "time.speed_changed"], "실패한 불러오기 뒤 명령은 적용(큐 순서)")
	assert_eq(s.loop.speed, 3)
	rec.clear()
	s.bus.publish("session.load_requested", {"slot": "good"})
	s.bus.publish("time.speed_requested", {"speed": 2})
	s.bus.publish("session.save_requested", {"slot": "after"})
	s.advance(0)
	assert_eq(rec.names(), ["session.loaded"], "성공한 불러오기 뒤 speed·save 명령 폐기")
	assert_eq(s.loop.speed, 1, "배속 = 복원값")
	assert_false(FileAccess.file_exists(s.slot_path("after")), "save 명령 미처리")
	assert_eq(s.bus.get_pending_commands(), [], "큐 = 복원 스냅샷의 pending_commands")
	assert_eq(_hash(s.snapshot()), saved, "상태 = 저장 시점")
	assert_ne(saved, moved)


## AC4 보강: 저장은 큐 순서 그대로 — [speed, save] 는 배속이 적용된 상태를 저장한다.
func test_se056_ac4_save_sees_earlier_commands() -> void:
	var s: GameSession = _session(false)
	s.bus.publish("time.speed_requested", {"speed": 2})
	s.bus.publish("session.save_requested", {"slot": "s2"})
	s.advance(0)
	assert_eq(int(SaveFile.read(s.slot_path("s2"))["speed"]), 2, "save 앞 명령이 적용된 뒤 저장")
	assert_eq(_hash(SaveFile.read(s.slot_path("s2"))), _hash(s.snapshot()))


## AC5: new_game_requested {seed:7} → 같은 버스 구독자가 다시 bind 없이 session.loaded + 재발행을 받는다.
## 1일차 상태 해시 == new_game(7). 뒤 명령 폐기, 큐 비움, 진행 결과도 같다.
func test_se056_ac5_new_game_requested() -> void:
	var mv: Array = _moved_session()
	var s: GameSession = mv[0]
	var bus_before: EventBus = s.bus
	var names: Array[String] = RELOAD_EVENTS.duplicate()
	names.append_array(["time.speed_changed", "session.load_failed"])
	var rec: EventRecorder = EventRecorder.new(s.bus, names)
	s.bus.publish("session.new_game_requested", {"seed": 7})
	s.bus.publish("time.speed_requested", {"speed": 3})
	s.advance(0)
	var ref: GameSession = GameSession.new()
	assert_true(ref.new_game_from_configs(7, _cfgs))
	assert_eq(s.bus, bus_before, "같은 EventBus")
	assert_eq(_hash(s.snapshot()), _hash(ref.snapshot()), "1일차 상태 해시 == new_game(7)")
	assert_eq(s.loop.master_seed, 7)
	var expect: Array[String] = ["session.loaded"]
	for i: int in range(ref.build.instances.size()):
		expect.append("build.placed")
	expect.append_array(["build.coverage_changed", "reputation.changed"])
	assert_eq(rec.names(), expect, "session.loaded → 재발행, speed 명령 폐기")
	assert_eq(rec.of("session.loaded")[0], {"day": 1, "phase": "day", "speed": 1, "show_active": false})
	assert_eq(rec.of("build.coverage_changed")[0]["cause"], "sync")
	assert_eq(rec.of("reputation.changed")[0]["delta"], 0)
	assert_eq(s.bus.get_pending_commands(), [], "새 게임 큐 = 빈 큐")
	assert_push_error_count(0)
	# 시스템 구독도 유지: 같은 명령 → 같은 결과
	rec.clear()
	var bcfg: BuildConfig = _cfgs["build"]
	var p0: Dictionary = bcfg.layout(LAYOUT)["placements"][0]
	for x: GameSession in [s, ref]:
		x.bus.publish("build.place_requested", {"furniture_id": p0["furniture_id"], "cell": p0["cell"], "rotation": p0["rotation"]})
		x.advance(300)
	assert_eq(rec.count("build.placed"), 1, "기존 구독자가 새 세계의 이벤트를 받는다")
	assert_eq(_hash(s.snapshot()), _hash(ref.snapshot()), "이후 진행도 new_game(7) 과 같다")


## AC5 보강: seed 가 int 가 아니거나 없으면 무시(push_error 1, 이벤트 0, 상태 불변).
func test_se056_ac5_new_game_bad_seed_ignored() -> void:
	var s: GameSession = _session(false)
	s.advance(50)
	var before: String = _hash(s.snapshot())
	var rec: EventRecorder = EventRecorder.new(s.bus, SESSION_EVENTS)
	s.bus.publish("session.new_game_requested", {})
	s.bus.publish("session.new_game_requested", {"seed": "7"})
	s.advance(0)
	assert_eq(rec.events, [])
	assert_push_error_count(2)
	assert_eq(_hash(s.snapshot()), before)
