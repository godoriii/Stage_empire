extends GutTest
## SE-036 AC4: SaveFile — 왕복 동치, gzip 실제 압축, 손상(잘린 바이트·gzip 아님·JSON 아님·헤더 버전 2·파일 없음) → {} +
## push_error 1, 150명 에이전트 스냅샷 쓰기+읽기 시간. docs/tickets/SE-036.md, docs/gdd/tick.md#스냅샷.

const DIR: String = "user://test_se036_save_file"
## 150명 측정의 느슨한 상한(AC4: 목표 < 1초, 단언 < 3초).
const AGENTS_N: int = 150
const LOOSE_LIMIT_US: int = 3000000

var _cfgs: Dictionary
var _hcfg: AudienceHarness


func before_all() -> void:
	_cfgs = GameSession.load_configs()
	_hcfg = AudienceHarness.new()


func after_each() -> void:
	_rm_dir(DIR)


func _session() -> GameSession:
	var s: GameSession = GameSession.new()
	s.new_game_from_configs(36, _cfgs)
	s.saves_dir = DIR
	var bcfg: BuildConfig = _cfgs["build"]
	for p: Dictionary in bcfg.layout("baseline_show")["placements"]:
		s.bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
	s.advance(0)
	return s


static func _hash(v: Variant) -> String:
	return JSON.stringify(v, "", true)


func _rm_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _doc_bytes(doc: Variant) -> PackedByteArray:
	return JSON.stringify(doc).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)


func _push_warnings() -> int:
	var n: int = 0
	for e: Variant in get_errors():
		if e.is_push_warning():
			n += 1
	return n


# --- 왕복·포맷 --------------------------------------------------------------------

func test_roundtrip_equivalent() -> void:
	var s: GameSession = _session()
	var snap: Dictionary = s.snapshot()
	var path: String = DIR.path_join("rt.sav")
	assert_true(SaveFile.write(path, snap), "쓰기 성공")
	var back: Dictionary = SaveFile.read(path)
	assert_eq(_hash(back), _hash(snap), "read(write(s)) 해시 == s 해시(정수값 float → int 정규화)")
	assert_true(back["tick"] is int and back["seed"] is int, "카운터는 int 로 돌아온다")
	assert_false(FileAccess.file_exists(path + SaveFile.TMP_SUFFIX), "임시 파일이 남지 않는다")
	var s2: GameSession = GameSession.new()
	s2.new_game_from_configs(1, _cfgs)
	assert_true(s2.restore(back), "읽은 스냅샷을 새 세션이 복원한다")
	assert_eq(_hash(s2.snapshot()), _hash(snap), "복원 뒤 해시 동일")


func test_gzip_compresses_and_header_fields() -> void:
	var s: GameSession = _session()
	var snap: Dictionary = s.snapshot()
	var path: String = DIR.path_join("hdr.sav")
	assert_true(SaveFile.write(path, snap))
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	assert_eq([bytes[0], bytes[1]], [SaveFile.GZIP_ID1, SaveFile.GZIP_ID2], "gzip 매직 1f 8b")
	var text: String = bytes.decompress_dynamic(SaveFile.NO_SIZE_LIMIT, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	assert_lt(bytes.size(), text.length(), "파일 크기 < JSON 길이(실제 압축)")
	var doc: Dictionary = JSON.parse_string(text)
	assert_eq((doc.keys() as Array).size(), 2, "최상위 header·snapshot 2키")
	var h: Dictionary = doc["header"]
	assert_eq(int(h["save_version"]), 1, "save_version 1")
	assert_eq(int(h["snapshot_schema_version"]), (_cfgs["sim"] as SimConfig).snapshot_schema_version, "스키마 버전 = sim.json")
	assert_eq(int(h["written_day"]), s.loop.day, "written_day = 스냅샷 day")


func test_overwrite_keeps_latest() -> void:
	var s: GameSession = _session()
	var path: String = DIR.path_join("ow.sav")
	assert_true(SaveFile.write(path, s.snapshot()))
	s.bus.publish("time.speed_requested", {"speed": 2})
	s.advance(0)
	var snap2: Dictionary = s.snapshot()
	assert_true(SaveFile.write(path, snap2), "기존 파일 덮어쓰기")
	assert_eq(_hash(SaveFile.read(path)), _hash(snap2), "마지막에 쓴 값")


# --- 손상 → {} + push_error 1 ----------------------------------------------------

func test_truncated_bytes_rejected() -> void:
	var s: GameSession = _session()
	var path: String = DIR.path_join("cut.sav")
	assert_true(SaveFile.write(path, s.snapshot()))
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	_write_bytes(path, bytes.slice(0, bytes.size() / 2))
	assert_eq(SaveFile.read(path), {}, "잘린 파일 → {}")
	assert_push_error("압축 해제 실패")
	assert_push_error_count(1, "SaveFile push_error 1회")
	assert_engine_error_count(1, "Godot 압축 해제의 엔진 오류 1회(SaveFile 이 막을 수 없다)")


func test_not_gzip_rejected() -> void:
	var path: String = DIR.path_join("plain.sav")
	_write_bytes(path, "{\"header\": {}}".to_utf8_buffer())
	assert_eq(SaveFile.read(path), {}, "gzip 아님 → {}")
	assert_push_error("gzip 파일이 아니다")
	assert_push_error_count(1)


func test_not_json_rejected() -> void:
	var path: String = DIR.path_join("notjson.sav")
	_write_bytes(path, "this is not json".to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP))
	assert_eq(SaveFile.read(path), {}, "JSON 아님 → {}")
	assert_push_error("JSON 이 아니다")
	assert_push_error_count(1)


func test_header_version_2_rejected() -> void:
	var s: GameSession = _session()
	var snap: Dictionary = s.snapshot()
	var path: String = DIR.path_join("v2.sav")
	_write_bytes(path, _doc_bytes({
		"header": {"save_version": 2, "snapshot_schema_version": snap["schema_version"], "written_day": snap["day"]},
		"snapshot": snap,
	}))
	assert_eq(SaveFile.read(path), {}, "save_version 2 → {}")
	assert_push_error("save_version")
	assert_push_error_count(1)


func test_header_schema_mismatch_and_shape_rejected() -> void:
	var s: GameSession = _session()
	var snap: Dictionary = s.snapshot()
	var path: String = DIR.path_join("bad.sav")
	_write_bytes(path, _doc_bytes({
		"header": {"save_version": 1, "snapshot_schema_version": int(snap["schema_version"]) + 1, "written_day": snap["day"]},
		"snapshot": snap,
	}))
	assert_eq(SaveFile.read(path), {}, "헤더·스냅샷 스키마 버전 불일치 → {}")
	_write_bytes(path, _doc_bytes([1, 2, 3]))
	assert_eq(SaveFile.read(path), {}, "최상위 배열 → {}")
	_write_bytes(path, _doc_bytes({"header": {"save_version": 1}}))
	assert_eq(SaveFile.read(path), {}, "snapshot 없음 → {}")
	assert_push_error_count(3, "경우마다 1회")


func test_missing_file_and_empty_snapshot() -> void:
	assert_eq(SaveFile.read(DIR.path_join("none.sav")), {}, "파일 없음 → {}")
	assert_push_error("파일 없음")
	assert_false(SaveFile.write(DIR.path_join("empty.sav"), {}), "빈 스냅샷(경계 밖 snapshot() 의 실패 값)은 쓰지 않는다")
	assert_false(FileAccess.file_exists(DIR.path_join("empty.sav")), "파일 없음")
	assert_push_error_count(2)


## 손상 파일 로드는 세션 상태를 바꾸지 않는다(AC4 "상태 불변").
func test_corrupt_load_leaves_session_unchanged() -> void:
	var s: GameSession = _session()
	var before: String = _hash(s.snapshot())
	var path: String = DIR.path_join("notjson2.sav")
	_write_bytes(path, "garbage".to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP))
	assert_false(s.load_from(path), "로드 실패")
	assert_eq(_hash(s.snapshot()), before, "상태 해시 불변")
	assert_push_error_count(1, "SaveFile 1회")


# --- 시간(AC4) ----------------------------------------------------------------------

func test_150_agents_write_read_time() -> void:
	var s: GameSession = _session()
	var snap: Dictionary = s.snapshot()
	var agents: Array = []
	var types: Array = _hcfg.acfg.type_ids()
	for i: int in range(AGENTS_N):
		agents.append(AudienceHarness.agent(i + 1, types[i % types.size()], "watching", [i % 10, i / 10],
			{"path": [[1, 2], [2, 2], [3, 2], [4, 2]], "show_ticks": 400, "sound_ticks": 300, "sight_ticks": 200, "sat": 7000}))
	snap["systems"]["audience"]["agents"] = agents
	var path: String = DIR.path_join("big.sav")
	var t0: int = Time.get_ticks_usec()
	var ok: bool = SaveFile.write(path, snap)
	var back: Dictionary = SaveFile.read(path)
	var us: int = Time.get_ticks_usec() - t0
	gut.p("SE-036 150명 스냅샷 쓰기+읽기 %d µs, 파일 %d 바이트" % [us, FileAccess.get_file_as_bytes(path).size()])
	assert_true(ok)
	assert_eq(_hash(back), _hash(snap), "150명 왕복 동치")
	assert_lt(us, LOOSE_LIMIT_US, "쓰기+읽기 < 3초(목표 < 1초)")
	assert_eq(_push_warnings(), 0)
