extends GutTest
## SE-036 qa 보강(독립 확인). sim-engineer 테스트가 덮지 않은 곳:
## - session.load_requested 의 reason "corrupt"·"restore_failed", session.save_requested 쓰기 실패
##   (기존은 missing·invalid 만 명령 경로로 확인), 오토세이브 쓰기 실패가 진행을 막지 않는 것.
## - SE-056: 계약 SN3·SN4 에 맞춰 단언을 고쳤다 — 저장 실패는 이벤트 없음(push_error 만), 불러오기 ③ corrupt 는 push_error 0.
## - 세이브 파일 헤더(save_version·snapshot_schema_version·written_day)를 SaveFile 을 거치지 않고 gzip→JSON 으로 직접 읽어 확인.
## docs/tickets/SE-036.md AC4·AC5·AC6.

const DIR: String = "user://test_se036_qa"
const SEED: int = 36
const ARTIST: String = "thumbnail_soda"
const LAYOUT: String = "baseline_show"

var _cfgs: Dictionary


func before_all() -> void:
	_cfgs = GameSession.load_configs()


func after_each() -> void:
	_rm_dir(DIR)


func _rm_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


static func _hash(v: Variant) -> String:
	return JSON.stringify(v, "", true)


func _session() -> GameSession:
	var s: GameSession = GameSession.new()
	assert_true(s.new_game_from_configs(SEED, _cfgs), "new_game 성공")
	s.saves_dir = DIR
	var bcfg: BuildConfig = _cfgs["build"]
	for p: Dictionary in bcfg.layout(LAYOUT)["placements"]:
		s.bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
	s.bus.publish("artist.book_requested", {"artist_id": ARTIST})
	s.advance(0)
	return s


func _day_ticks() -> int:
	var c: SimConfig = _cfgs["sim"]
	return c.phase_ticks("day") + c.phase_ticks("evening") + c.phase_ticks("show")


func _write_raw(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


## 세이브 파일 → 헤더·스냅샷 (SaveFile 을 쓰지 않는 독립 해석).
func _raw_doc(path: String) -> Dictionary:
	var raw: PackedByteArray = FileAccess.get_file_as_bytes(path).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


func test_header_fields_read_independently() -> void:
	var s: GameSession = _session()
	s.advance(_day_ticks())
	s.bus.publish("time.next_day_requested", {})
	s.advance(0)
	s.advance(_day_ticks())
	var d2: Dictionary = _raw_doc(s.autosave_path(2))
	assert_eq(d2.keys().size(), 2, "최상위 키 header·snapshot")
	var h: Dictionary = d2["header"]
	assert_eq(int(h["save_version"]), 1, "save_version")
	assert_eq(int(h["written_day"]), 2, "written_day = 저장한 날")
	assert_eq(int(h["snapshot_schema_version"]), int(d2["snapshot"]["schema_version"]), "헤더 스키마 버전 == 스냅샷 값")
	assert_eq(int(d2["snapshot"]["day"]), 2)
	assert_eq(d2["snapshot"]["phase"], "close", "오토세이브는 close 진입 경계")
	assert_eq(d2["snapshot"]["systems"].keys().size(), 6, "systems 6개")
	var d1: Dictionary = _raw_doc(s.autosave_path(1))
	assert_eq(int(d1["header"]["written_day"]), 1)
	assert_true(FileAccess.get_file_as_bytes(s.autosave_path(1)).size() < JSON.stringify(d1).length(), "gzip 압축")
	assert_eq(DirAccess.get_files_at(DIR).size(), 2, ".tmp 잔여 없이 오토세이브 2개")


func test_load_requested_corrupt_reason() -> void:
	var s: GameSession = _session()
	s.advance(500)
	var before: String = _hash(s.snapshot())
	_write_raw(s.slot_path("bad"), "not a save file".to_utf8_buffer())
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.load_failed", "session.loaded"])
	s.bus.publish("session.load_requested", {"slot": "bad"})
	s.advance(0)
	assert_eq(rec.of("session.load_failed"), [{"slot": "bad", "reason": "corrupt"}])
	assert_eq(rec.count("session.loaded"), 0)
	assert_eq(_hash(s.snapshot()), before, "손상 파일 로드는 상태 불변")
	assert_push_error_count(0, "SN4 ③ corrupt 는 push_error 0 (SE-056)")


func test_load_requested_restore_failed_reason() -> void:
	var s: GameSession = _session()
	var snap: Dictionary = s.snapshot()
	(snap["systems"] as Dictionary).erase("economy")
	assert_true(SaveFile.write(s.slot_path("noeco"), snap), "헤더·gzip·JSON 은 유효한 파일")
	s.advance(500)
	var before: String = _hash(s.snapshot())
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.load_failed", "session.loaded"])
	s.bus.publish("session.load_requested", {"slot": "noeco"})
	s.advance(0)
	assert_eq(rec.of("session.load_failed"), [{"slot": "noeco", "reason": "restore_failed"}])
	assert_eq(rec.count("session.loaded"), 0)
	assert_eq(_hash(s.snapshot()), before, "restore 실패는 상태 불변(원자성)")
	assert_push_error_count(1, "TickLoop.restore push_error 1")


func test_save_requested_write_failed_reason() -> void:
	var s: GameSession = _session()
	_write_raw(DIR.path_join("blocker"), PackedByteArray([1]))
	s.saves_dir = DIR.path_join("blocker").path_join("sub")    # 부모가 파일이라 디렉터리를 만들 수 없다
	var before: String = _hash(s.snapshot())
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.saved", "session.save_failed"])
	s.bus.publish("session.save_requested", {"slot": "x"})
	s.advance(0)
	assert_eq(rec.events, [], "SN3: 쓰기 실패는 이벤트 없음(session.saved·save_failed 0, SE-056)")
	assert_eq(_hash(s.snapshot()), before, "저장 실패는 상태 불변")
	assert_gte(get_errors().size(), 1, "push_error 기록")
	for e: Variant in get_errors():
		e.handled = true


func test_autosave_write_failure_does_not_block_day() -> void:
	var s: GameSession = _session()
	var ref: GameSession = _session()
	ref.autosave_enabled = false
	_write_raw(DIR.path_join("blocker"), PackedByteArray([1]))
	s.saves_dir = DIR.path_join("blocker").path_join("sub")
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.saved", "session.save_failed"])
	s.advance(_day_ticks())
	ref.advance(_day_ticks())
	assert_eq(s.loop.phase, "close", "오토세이브가 실패해도 하루는 close 까지 간다")
	assert_eq(rec.events, [], "SN3: 오토세이브 쓰기 실패도 이벤트 없음(SE-056)")
	assert_eq(_hash(s.snapshot()), _hash(ref.snapshot()), "오토세이브 실패는 게임 상태에 영향 없음")
	for e: Variant in get_errors():
		e.handled = true
