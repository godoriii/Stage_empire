class_name SaveFile
extends RefCounted
## 세이브 파일 포맷 (SE-036). TickLoop.snapshot() 을 JSON → gzip 으로 쓰고 읽는다(PRD "기술 요구사항" 세이브).
## 파일 = gzip( JSON.stringify({header: {save_version, snapshot_schema_version, written_day}, snapshot: {…}}) ).
## 읽기 실패(파일 없음·gzip 아님·잘림·JSON 아님·헤더 형식/버전 불일치)는 push_error 1회(SaveFile) + {}.
## 잘린 gzip 은 Godot 의 압축 해제가 엔진 오류("Decompression failed")를 따로 1회 낸다(막을 수 없다).
## 마이그레이션: save_version 1 뿐이라 틀만 있다(migrate). snapshot_schema_version 불일치는 TickLoop.restore 2단계가 거부한다.

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
## inspect() 반환 키.
const R_ERROR: String = "error"
const R_SAVE_VERSION: String = "save_version"
const R_SNAPSHOT: String = "snapshot"


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
	var r: Dictionary = inspect(bytes)
	if r[R_ERROR] != "":
		return _fail("%s: %s" % [r[R_ERROR], label])
	var sv: Variant = r[R_SAVE_VERSION]
	if sv == null or sv != SAVE_VERSION:
		return _fail("save_version %s 를 읽을 수 없다(지원 %d): %s" % [sv, SAVE_VERSION, label])
	return migrate(r[R_SNAPSHOT])


## 파일 바이트의 형식 검사(push_error 없음 — session.load_requested 판정 SN4 ③ 은 push_error 0, SE-056).
## 반환 {error, save_version, snapshot}. error = "" 이면 형식이 맞고 snapshot 은 정수 정규화된 스냅샷,
## save_version 은 헤더 값(int 또는 null — 지원 여부는 호출자가 본다). error != "" 이면 손상(사유 문장).
## 손상 = gzip 아님·압축 해제 실패·JSON 아님·최상위가 객체 아님·header·snapshot 객체 없음·헤더와 스냅샷의 스키마 버전 불일치.
static func inspect(bytes: PackedByteArray) -> Dictionary:
	var out: Dictionary = {R_ERROR: "", R_SAVE_VERSION: null, R_SNAPSHOT: {}}
	if bytes.size() < 2 or bytes[0] != GZIP_ID1 or bytes[1] != GZIP_ID2:
		out[R_ERROR] = "gzip 파일이 아니다"
		return out
	var raw: PackedByteArray = bytes.decompress_dynamic(NO_SIZE_LIMIT, COMPRESSION)
	if raw.is_empty():
		out[R_ERROR] = "압축 해제 실패(잘렸거나 손상)"
		return out
	var json: JSON = JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK:
		out[R_ERROR] = "JSON 이 아니다(%d행: %s)" % [json.get_error_line(), json.get_error_message()]
		return out
	var doc: Variant = json.data
	if not (doc is Dictionary):
		out[R_ERROR] = "최상위가 객체가 아니다"
		return out
	var header: Variant = (doc as Dictionary).get(HEADER_KEY)
	var snap: Variant = (doc as Dictionary).get(SNAPSHOT_KEY)
	if not (header is Dictionary) or not (snap is Dictionary):
		out[R_ERROR] = "header·snapshot 객체가 없다"
		return out
	var hv: Variant = JsonUtil.as_int((header as Dictionary).get(H_SCHEMA_VERSION))
	if hv == null or hv != JsonUtil.as_int((snap as Dictionary).get("schema_version")):
		out[R_ERROR] = "헤더 snapshot_schema_version 과 스냅샷 schema_version 이 다르다"
		return out
	out[R_SAVE_VERSION] = JsonUtil.as_int((header as Dictionary).get(H_SAVE_VERSION))
	out[R_SNAPSHOT] = JsonUtil.int_deep(snap)
	return out


## save_version 별 변환 자리(v1 뿐이라 그대로 돌려준다). 입력 = inspect 의 snapshot.
static func migrate(snap: Dictionary) -> Dictionary:
	return snap


static func _fail(msg: String) -> Dictionary:
	push_error("[SaveFile] " + msg)
	return {}
