class_name SaveFile
extends RefCounted
## 세이브 파일 포맷 (SE-036). TickLoop.snapshot() 을 JSON → gzip 으로 쓰고 읽는다(PRD "기술 요구사항" 세이브).
## 파일 = gzip( JSON.stringify({header: {save_version, snapshot_schema_version, written_day}, snapshot: {…}}) ).
## 읽기 실패(파일 없음·gzip 아님·잘림·JSON 아님·헤더 형식/버전 불일치)는 push_error 1회(SaveFile) + {}.
## 잘린 gzip 은 Godot 의 압축 해제가 엔진 오류("Decompression failed")를 따로 1회 낸다(막을 수 없다).
## 마이그레이션: save_version 1 뿐이라 틀만 있다(_migrate). snapshot_schema_version 불일치는 TickLoop.restore 2단계가 거부한다.

const SAVE_VERSION: int = 1
const HEADER_KEY: String = "header"
const SNAPSHOT_KEY: String = "snapshot"
const H_SAVE_VERSION: String = "save_version"
const H_SCHEMA_VERSION: String = "snapshot_schema_version"
const H_WRITTEN_DAY: String = "written_day"
const COMPRESSION: int = FileAccess.COMPRESSION_GZIP
## gzip 매직 바이트(RFC 1952 ID1·ID2).
const GZIP_ID1: int = 0x1f
const GZIP_ID2: int = 0x8b
## decompress_dynamic 의 "출력 크기 제한 없음".
const NO_SIZE_LIMIT: int = -1
const TMP_SUFFIX: String = ".tmp"


## snapshot 을 path 에 쓴다. 임시 파일에 쓴 뒤 이름을 바꿔 기존 파일이 반쯤 덮이지 않게 한다. 실패하면 push_error 1회, false.
static func write(path: String, snapshot: Dictionary) -> bool:
	var bytes: PackedByteArray = encode(snapshot)
	if bytes.is_empty():
		return false
	var dir: String = path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var mk: Error = DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			push_error("[SaveFile] 디렉터리를 만들지 못했다: %s (%s)" % [dir, error_string(mk)])
			return false
	var tmp: String = path + TMP_SUFFIX
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[SaveFile] 쓰기 열기 실패: %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	f.store_buffer(bytes)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var mv: Error = DirAccess.rename_absolute(tmp, path)
	if mv != OK:
		push_error("[SaveFile] 이름 바꾸기 실패: %s → %s (%s)" % [tmp, path, error_string(mv)])
		return false
	return true


## path 를 읽어 스냅샷을 돌려준다(정수값 float 는 int 로 정규화). 실패하면 push_error 1회, {}.
static func read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _fail("파일 없음: %s" % path)
	return decode(FileAccess.get_file_as_bytes(path), path)


## 스냅샷 → 파일 바이트(gzip). 스냅샷이 비었거나 schema_version·day 가 정수가 아니면 push_error 1회, 빈 배열.
static func encode(snapshot: Dictionary) -> PackedByteArray:
	var ver: Variant = JsonUtil.as_int(snapshot.get("schema_version"))
	var d: Variant = JsonUtil.as_int(snapshot.get("day"))
	if snapshot.is_empty() or ver == null or d == null:
		push_error("[SaveFile] 쓸 스냅샷이 비었거나 schema_version·day 가 정수가 아니다")
		return PackedByteArray()
	var doc: Dictionary = {
		HEADER_KEY: {H_SAVE_VERSION: SAVE_VERSION, H_SCHEMA_VERSION: ver, H_WRITTEN_DAY: d},
		SNAPSHOT_KEY: snapshot,
	}
	return JSON.stringify(doc).to_utf8_buffer().compress(COMPRESSION)


## 파일 바이트 → 스냅샷. label 은 오류 메시지용. 실패하면 push_error 1회, {}.
static func decode(bytes: PackedByteArray, label: String = "") -> Dictionary:
	if bytes.size() < 2 or bytes[0] != GZIP_ID1 or bytes[1] != GZIP_ID2:
		return _fail("gzip 파일이 아니다: %s" % label)
	var raw: PackedByteArray = bytes.decompress_dynamic(NO_SIZE_LIMIT, COMPRESSION)
	if raw.is_empty():
		return _fail("압축 해제 실패(잘렸거나 손상): %s" % label)
	var json: JSON = JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK:
		return _fail("JSON 이 아니다(%d행: %s): %s" % [json.get_error_line(), json.get_error_message(), label])
	var doc: Variant = json.data
	if not (doc is Dictionary):
		return _fail("최상위가 객체가 아니다: %s" % label)
	var header: Variant = (doc as Dictionary).get(HEADER_KEY)
	var snap: Variant = (doc as Dictionary).get(SNAPSHOT_KEY)
	if not (header is Dictionary) or not (snap is Dictionary):
		return _fail("header·snapshot 객체가 없다: %s" % label)
	var sv: Variant = JsonUtil.as_int((header as Dictionary).get(H_SAVE_VERSION))
	if sv == null or sv != SAVE_VERSION:
		return _fail("save_version %s 를 읽을 수 없다(지원 %d): %s" % [(header as Dictionary).get(H_SAVE_VERSION), SAVE_VERSION, label])
	var hv: Variant = JsonUtil.as_int((header as Dictionary).get(H_SCHEMA_VERSION))
	if hv == null or hv != JsonUtil.as_int((snap as Dictionary).get("schema_version")):
		return _fail("헤더 snapshot_schema_version 과 스냅샷 schema_version 이 다르다: %s" % label)
	return _migrate(JsonUtil.int_deep(snap))


## save_version 별 변환 자리(v1 뿐이라 그대로 돌려준다).
static func _migrate(snap: Dictionary) -> Dictionary:
	return snap


static func _fail(msg: String) -> Dictionary:
	push_error("[SaveFile] " + msg)
	return {}
