extends GutTest
## SE-056 AC6 (qa): docs/gdd/events.md 의 session.* 계약 <-> GameSession 코드 대조.
## 문서를 파싱해서 읽고(리터럴로 베끼지 않는다) 코드 쪽은 소스 상수와 실제 발행 이벤트에서 읽는다.
##   1. 문서 session.* 행의 이름 집합 == game_session.gd 의 "session.*" 문자열 상수 집합 (save_failed 같은 것이 되살아나면 실패)
##   2. load_failed.reason 열거(문서 순서) == SN4 의 ①~⑤ 순서 == game_session.gd REASON_* 선언 순서 == 실제 발행된 reason 집합
##   3. saved / load_failed / loaded 페이로드 키 == 실제 발행 페이로드 키 (불러오기 성공과 새 게임 둘 다)
##   4. loaded.phase 열거 == sim.json 구간 id
##   5. 명령 페이로드 키(save/load: slot, new_game: seed)로 발행하면 코드가 그 키를 읽는다
## 문서 위치: res://../docs (리포지토리). 변이 사본처럼 docs 가 없거나 다른 사본을 쓰려면 SE_DOCS_DIR (docs 디렉터리 경로).
## 소스 위치: res://core/game_session.gd (사본 실행이면 사본의 것).

const DIR: String = "user://test_se056_qa"
const SEED: int = 56
const PIPE: String = "¦"                 # 표 안의 이스케이프된 | (\|) 를 임시로 바꿀 문자
const SRC_PATH: String = "res://core/game_session.gd"
const DOC_REASONS: String = "session.load_failed"

var _cfgs: Dictionary
var _md: String = ""
var _recorders: Array = []                    # 기록기를 살려 둔다(해제되면 버스가 "무효 핸들러" 경고를 낸다)


func before_all() -> void:
	_cfgs = GameSession.load_configs()
	_md = _events_md()


func after_each() -> void:
	var d: DirAccess = DirAccess.open(DIR)
	if d != null:
		for f: String in d.get_files():
			d.remove(f)
		DirAccess.remove_absolute(DIR)


# --- 문서 파싱 ---------------------------------------------------------------------

func _events_md() -> String:
	var dir: String = OS.get_environment("SE_DOCS_DIR")
	if dir.is_empty():
		dir = ProjectSettings.globalize_path("res://").path_join("../docs")
	var path: String = dir.path_join("gdd/events.md")
	assert_true(FileAccess.file_exists(path), "events.md 를 읽을 수 있다: %s" % path)
	return FileAccess.get_file_as_string(path)


## "| `이름` | …" 형식 행의 칸 목록(이스케이프된 | 는 PIPE 로 바꿔 둔다). 없으면 빈 배열.
func _row(ev: String) -> PackedStringArray:
	for line: String in _md.split("\n"):
		if line.begins_with("| `%s` |" % ev):
			return line.replace("\\|", PIPE).split("|")
	return PackedStringArray()


## 문서의 session.* 행 이름(이벤트·명령 전부).
func _doc_session_names() -> Array[String]:
	var out: Array[String] = []
	var re: RegEx = RegEx.create_from_string("^\\| `(session\\.[a-z_]+)` \\|")
	for line: String in _md.split("\n"):
		var m: RegExMatch = re.search(line)
		if m != null and not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	out.sort()
	return out


## 페이로드 칸(둘째 칸)의 첫 {...} 안 키 목록(정렬).
func _doc_keys(ev: String) -> Array[String]:
	var cells: PackedStringArray = _row(ev)
	var out: Array[String] = []
	if cells.size() < 3:
		return out
	var cell: String = cells[2]
	var open: int = cell.find("{")
	var close: int = cell.find("}", open)
	if open < 0 or close < 0:
		return out
	var body: String = cell.substr(open + 1, close - open - 1)
	for m: RegExMatch in RegEx.create_from_string("(?:^|, )([a-z_]+):").search_all(body):
		out.append(m.get_string(1))
	out.sort()
	return out


## 페이로드 칸의 `<필드>: "a"|"b"|…` 열거(문서 순서).
func _doc_enum(ev: String, field: String) -> Array[String]:
	var cells: PackedStringArray = _row(ev)
	var out: Array[String] = []
	if cells.size() < 3:
		return out
	var re: RegEx = RegEx.create_from_string("(?<![a-z_])%s: (\"[a-z_]+\"(?:%s\"[a-z_]+\")*)" % [field, PIPE])
	var m: RegExMatch = re.search(cells[2])
	if m == null:
		return out
	for w: RegExMatch in RegEx.create_from_string("\"([a-z_]+)\"").search_all(m.get_string(1)):
		out.append(w.get_string(1))
	return out


## SN4 행의 ①~⑤ 사유 이름(문서 순서).
func _doc_sn4_order() -> Array[String]:
	var out: Array[String] = []
	for line: String in _md.split("\n"):
		if line.begins_with("| SN4 |"):
			for m: RegExMatch in RegEx.create_from_string("[①②③④⑤] `([a-z_]+)`").search_all(line):
				out.append(m.get_string(1))
	return out


# --- 코드 쪽 ------------------------------------------------------------------------

func _src() -> String:
	assert_true(FileAccess.file_exists(SRC_PATH), "소스를 읽을 수 있다")
	return FileAccess.get_file_as_string(SRC_PATH)


## game_session.gd 의 `const REASON_*: String = "x"` 값(선언 순서).
func _code_reasons() -> Array[String]:
	var out: Array[String] = []
	for m: RegExMatch in RegEx.create_from_string("(?m)^const REASON_[A-Z_]+: String = \"([a-z_]+)\"").search_all(_src()):
		out.append(m.get_string(1))
	return out


## game_session.gd 가 가진 "session.*" 문자열 리터럴 전부(정렬, 중복 제거).
func _code_session_names() -> Array[String]:
	var out: Array[String] = []
	for m: RegExMatch in RegEx.create_from_string("\"(session\\.[a-z_]+)\"").search_all(_src()):
		if not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	out.sort()
	return out


static func _sorted_keys(d: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for k: Variant in d.keys():
		out.append(String(k))
	out.sort()
	return out


# --- 세션 도우미 ---------------------------------------------------------------------

func _session() -> GameSession:
	var s: GameSession = GameSession.new()
	assert_true(s.new_game_from_configs(SEED, _cfgs), "new_game 성공")
	s.saves_dir = DIR
	return s


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _write_doc(path: String, save_version: int, snap: Dictionary) -> void:
	var header: Dictionary = {"save_version": save_version, "written_day": 1, "snapshot_schema_version": snap.get("schema_version")}
	_write_bytes(path, JSON.stringify({"header": header, "snapshot": snap}).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP))


## 명령 하나를 발행하고 경계까지 돌린 뒤 session.* 이벤트를 모은다. [[이름, 페이로드], …]
func _run(s: GameSession, cmd: String, payload: Dictionary) -> Array:
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.saved", "session.load_failed", "session.loaded"])
	_recorders.append(rec)
	s.bus.publish(cmd, payload)
	s.advance(0)
	return rec.events


## 5종 사유를 각각 일으켜 실제로 발행된 load_failed 페이로드를 모은다.
func _emitted_load_failed() -> Array:
	var s: GameSession = _session()
	_run(s, "session.save_requested", {"slot": "good"})
	var snap: Dictionary = SaveFile.read(s.slot_path("good"))
	var noeco: Dictionary = snap.duplicate(true)
	(noeco["systems"] as Dictionary).erase("economy")
	_write_bytes(s.slot_path("garbage"), "not a save file".to_utf8_buffer())
	_write_doc(s.slot_path("savever"), 2, snap)
	_write_doc(s.slot_path("noeco"), 1, noeco)
	var out: Array = []
	for p: Dictionary in [{}, {"slot": "nope"}, {"slot": "garbage"}, {"slot": "savever"}, {"slot": "noeco"}]:
		var ev: Array = _run(s, "session.load_requested", p)
		assert_eq(ev.size(), 1, "load_failed 1건: %s" % [p])
		if ev.size() == 1:
			out.append(ev[0])
	for e: Variant in get_errors():
		e.handled = true                                    # restore_failed 의 TickLoop push_error 1건은 예상된 것
	return out


# --- 테스트 -------------------------------------------------------------------------

func test_doc_is_parseable() -> void:
	## 파서가 빈 결과로 "일치" 하지 못하게: 문서에서 실제로 읽혔는지 확인.
	assert_eq(_doc_session_names().size(), 6, "문서 session.* 행 6개(saved·load_failed·loaded·save_requested·load_requested·new_game_requested)")
	assert_eq(_doc_enum(DOC_REASONS, "reason").size(), 5, "reason 열거 5종")
	assert_eq(_doc_sn4_order().size(), 5, "SN4 ①~⑤ 5종")
	for ev: String in _doc_session_names():
		assert_gt(_doc_keys(ev).size(), 0, "%s 페이로드 키가 읽힌다" % ev)


func test_session_names_doc_equals_code() -> void:
	assert_eq(_code_session_names(), _doc_session_names(), "문서 session.* 행 이름 집합 == game_session.gd 의 session.* 상수 집합")


func test_load_failed_reason_enum_doc_equals_code() -> void:
	var doc: Array[String] = _doc_enum(DOC_REASONS, "reason")
	assert_eq(doc, _doc_sn4_order(), "load_failed 행 열거 순서 == SN4 ①~⑤ 순서")
	assert_eq(_code_reasons(), doc, "game_session.gd REASON_* 선언 순서와 값 == 문서 열거")
	var emitted: Array[String] = []
	for e: Array in _emitted_load_failed():
		emitted.append(String(e[1]["reason"]))
	assert_eq(emitted, doc, "실제로 발행된 reason(입력 순서 = SN4 순서) == 문서 열거")


func test_payload_keys_doc_equals_emitted() -> void:
	var failed: Array = _emitted_load_failed()
	for e: Array in failed:
		assert_eq(String(e[0]), "session.load_failed")
		assert_eq(_sorted_keys(e[1]), _doc_keys("session.load_failed"), "load_failed 키: %s" % [e[1]])
	var s: GameSession = _session()
	var saved: Array = _run(s, "session.save_requested", {"slot": "k"})
	assert_eq(saved.size(), 1, "saved 1건")
	assert_eq(_sorted_keys(saved[0][1]), _doc_keys("session.saved"), "saved 키")
	var loaded: Array = _run(s, "session.load_requested", {"slot": "k"})
	assert_eq(loaded.size(), 1, "loaded 1건(불러오기)")
	assert_eq(String(loaded[0][0]), "session.loaded")
	assert_eq(_sorted_keys(loaded[0][1]), _doc_keys("session.loaded"), "loaded 키(불러오기)")
	var fresh: Array = _run(s, "session.new_game_requested", {"seed": SEED + 1})
	assert_eq(fresh.size(), 1, "loaded 1건(새 게임)")
	assert_eq(_sorted_keys(fresh[0][1]), _doc_keys("session.loaded"), "loaded 키(새 게임)")


func test_loaded_phase_enum_doc_equals_sim_config() -> void:
	var doc: Array[String] = _doc_enum("session.loaded", "phase")
	var ids: Array[String] = []
	var scfg: SimConfig = _cfgs["sim"]
	for p: Dictionary in scfg.phases:
		ids.append(String(p["id"]))
	assert_eq(doc, ids, "session.loaded.phase 열거(문서 순서) == sim.json 구간 id")


func test_command_payload_keys_doc_is_what_code_reads() -> void:
	## 문서 명령 페이로드 키로 만든 명령이 코드에서 효과를 낸다 (다른 키 이름이면 invalid·무시가 된다).
	var save_keys: Array[String] = _doc_keys("session.save_requested")
	var load_keys: Array[String] = _doc_keys("session.load_requested")
	var new_keys: Array[String] = _doc_keys("session.new_game_requested")
	assert_eq(save_keys, ["slot"], "문서 save_requested 키")
	assert_eq(load_keys, ["slot"], "문서 load_requested 키")
	assert_eq(new_keys, ["seed"], "문서 new_game_requested 키")
	var s: GameSession = _session()
	var saved: Array = _run(s, "session.save_requested", {save_keys[0]: "docslot"})
	assert_eq(saved, [["session.saved", {"slot": "docslot", "day": 1}]], "저장 명령이 문서 키를 읽는다")
	var loaded: Array = _run(s, "session.load_requested", {load_keys[0]: "docslot"})
	assert_eq(loaded.size(), 1)
	assert_eq(String(loaded[0][0]), "session.loaded", "불러오기 명령이 문서 키를 읽는다")
	var fresh: Array = _run(s, "session.new_game_requested", {new_keys[0]: 9})
	assert_eq(fresh.size(), 1)
	assert_eq(String(fresh[0][0]), "session.loaded", "새 게임 명령이 문서 키를 읽는다")
	var ref: GameSession = GameSession.new()
	assert_true(ref.new_game_from_configs(9, _cfgs))
	assert_eq(JSON.stringify(s.snapshot(), "", true), JSON.stringify(ref.snapshot(), "", true), "seed 9 가 실제로 적용됐다")


## SE-058 AC-56e: SN1 슬롯 형식. 문서 SN1 행의 정규식 == 코드 SLOT_PATTERN, 그리고 그 정규식이 코드 판정(is_valid_slot)과 같은 답을 낸다.
func _doc_sn1_pattern() -> String:
	for line: String in _md.split("\n"):
		if line.begins_with("| SN1 |"):
			var m: RegExMatch = RegEx.create_from_string("`(\\^[^`]+\\$)`").search(line)
			if m != null:
				return m.get_string(1)
	return ""


func test_sn1_slot_pattern_doc_equals_code() -> void:
	var doc: String = _doc_sn1_pattern()
	assert_ne(doc, "", "문서 SN1 행에서 정규식이 읽힌다")
	assert_eq(GameSession.SLOT_PATTERN, doc, "game_session.gd SLOT_PATTERN == 문서 SN1 정규식")
	var re: RegEx = RegEx.create_from_string(doc)
	assert_not_null(re, "문서 정규식이 컴파일된다")
	var ok: Array = ["a", "1", "autosave_day12", "a_b_9", "x".repeat(24)]
	var bad: Array = ["", "A", "a-b", "a b", "../x", "a.sav", "x".repeat(25), "é", 5, null, ["a"]]
	for v: Variant in ok:
		assert_true(GameSession.is_valid_slot(v), "유효: %s" % [v])
		assert_not_null(re.search(v), "문서 정규식도 유효: %s" % [v])
	for v: Variant in bad:
		assert_false(GameSession.is_valid_slot(v), "무효: %s" % [v])
		if v is String:
			assert_null(re.search(v), "문서 정규식도 무효: %s" % [v])
	## 알려진 틈(SE-058 QA 리포트 "발견"): PCRE 의 `$` 는 끝의 개행 하나 앞에서도 맞아서 "a\n" 이 SN1 을 통과한다(파일 "a\n.sav").
	## 여기서는 문서 정규식과 코드 판정이 같은 답을 내는지만 고정한다(옳다고 보증하지 않는다).
	for v: String in ["a\n", "a\n\n", "\n"]:
		assert_eq(GameSession.is_valid_slot(v), re.search(v) != null, "문서 정규식 == 코드 판정: %s" % [v.c_escape()])


## SN2 의 틱 중 경로: advance(n) 도중에 들어온 명령은 구동기가 반환한 뒤(_after_drive) 한꺼번에 처리한다.
## 같은 경계에 [불러오기(성공), 저장] 이 쌓이면 저장은 버려진다(`session.saved` 없음, 파일 없음).
## (경계 앞 pre-dispatch 경로는 test_game_session.gd::test_se056_ac4 가 덮는다 — 변이 a3 가 이 경로만 살아남아 qa 가 추가.)
var _mid_fired: bool = false


func _on_tick_publish_pair(_p: Dictionary, s: GameSession) -> void:
	if _mid_fired:
		return
	_mid_fired = true
	s.bus.publish("session.load_requested", {"slot": "good"})
	s.bus.publish("session.save_requested", {"slot": "after"})


func test_sn2_requests_mid_advance_dropped_after_successful_load() -> void:
	var s: GameSession = _session()
	_run(s, "session.save_requested", {"slot": "good"})
	var rec: EventRecorder = EventRecorder.new(s.bus, ["session.saved", "session.load_failed", "session.loaded"])
	_recorders.append(rec)
	_mid_fired = false
	s.bus.subscribe("tick.advanced", _on_tick_publish_pair.bind(s))
	s.advance(5)
	assert_true(_mid_fired, "틱 도중 명령 2개가 발행됐다")
	assert_eq(rec.names(), ["session.loaded"], "불러오기 성공 1건만, 뒤의 저장은 버려진다")
	assert_false(FileAccess.file_exists(s.slot_path("after")), "버려진 저장은 파일을 만들지 않는다")
	assert_eq(s.bus.get_pending_commands(), [], "큐는 복원된 스냅샷의 pending_commands(빈 배열)")
	s.advance(2)                                                     # 남은 요청이 있었다면 다음 경계에서 새 세계에 저장된다
	assert_eq(rec.names(), ["session.loaded"], "다음 경계 뒤에도 저장 이벤트 없음")
	assert_false(FileAccess.file_exists(s.slot_path("after")), "다음 경계 뒤에도 파일 없음")
