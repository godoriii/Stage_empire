extends GutTest
## SE-001 AC1(리터럴), AC12(Node·시간·직접 난수 금지, class_name + RefCounted/Resource).
## project/core/**/*.gd 소스를 FileAccess 로 읽어 패턴 검사한다. docs/gdd/tick.md#틱, #결정성과-rng.

const CORE_ROOT: String = "res://core"
const RNG_FILE: String = "res://core/rng.gd"
const EXPECTED: Array[String] = [
	"res://core/event_bus.gd", "res://core/rng.gd", "res://core/sim_config.gd", "res://core/tick.gd",
]
const TICK_LITERAL_RE: String = "(?<![\\w.])(10|1800|600|900|3300|330)(?![\\w.])"


func _list_gd(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out
	for f: String in dir.get_files():
		if f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	for sub: String in dir.get_directories():
		out.append_array(_list_gd(dir_path.path_join(sub)))
	out.sort()
	return out


## 주석(#…)과 문자열 리터럴("…", '…')을 지운다. 한 줄 단위(코어에 여러 줄 문자열은 없다).
func _strip_comments_and_strings(src: String) -> String:
	var out: PackedStringArray = []
	for line: String in src.split("\n"):
		var buf: String = ""
		var quote: String = ""
		var i: int = 0
		while i < line.length():
			var c: String = line[i]
			if quote != "":
				if c == "\\":
					i += 2
					continue
				if c == quote:
					quote = ""
					buf += c
			elif c == "\"" or c == "'":
				quote = c
				buf += c
			elif c == "#":
				break
			else:
				buf += c
			i += 1
		out.append(buf)
	return "\n".join(out)


func _hits(re: RegEx, text: String, file: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var lines: PackedStringArray = text.split("\n")
	for i: int in lines.size():
		var m: RegExMatch = re.search(lines[i])
		if m != null:
			out.append("%s:%d `%s`" % [file, i + 1, m.get_string()])
	return out


func test_sources_found() -> void:
	var files: PackedStringArray = _list_gd(CORE_ROOT)
	for f: String in EXPECTED:
		assert_true(files.has(f), "%s 존재" % f)


func test_no_tick_literals_in_core() -> void:
	var re: RegEx = RegEx.create_from_string(TICK_LITERAL_RE)
	# 검사기 자체 확인: 리터럴은 걸리고, 상수표의 상수·다른 수는 걸리지 않는다.
	assert_gt(_hits(re, "var a := 10\nvar b = x * 1800", "self").size(), 1, "정규식이 리터럴을 잡는다")
	assert_eq(_hits(re, "const U := 1000000\nconst P := 16777619\nvar f := 0.10\nvar g := 2147483647", "self").size(), 0, "상수표 상수는 안 걸린다")
	assert_eq(_strip_comments_and_strings("var s := \"10\" # 10 tick"), "var s := \"\" ", "주석·문자열 제거")
	var hits: PackedStringArray = []
	for f: String in _list_gd(CORE_ROOT):
		hits.append_array(_hits(re, _strip_comments_and_strings(FileAccess.get_file_as_string(f)), f))
	assert_eq(hits.size(), 0, "core 에 틱·구간 리터럴 없음: %s" % ", ".join(hits))


func test_core_has_no_node_or_direct_random() -> void:
	var files: PackedStringArray = _list_gd(CORE_ROOT)
	assert_gt(files.size(), 0, "core 스크립트를 찾는다")
	var forbidden: RegEx = RegEx.create_from_string("extends\\s+Node|_process\\(|_physics_process\\(|get_node\\(|(?<![\\w])Time\\.")
	var random_re: RegEx = RegEx.create_from_string("randi\\(|randf\\(|randomize\\(|RandomNumberGenerator")
	var class_re: RegEx = RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*$")
	var extends_re: RegEx = RegEx.create_from_string("(?m)^extends\\s+(\\w+)\\s*$")
	var inner_re: RegEx = RegEx.create_from_string("(?m)^\\s*class\\s+\\w+")
	var bad: PackedStringArray = []
	for f: String in files:
		var src: String = FileAccess.get_file_as_string(f)
		bad.append_array(_hits(forbidden, src, f))
		if f != RNG_FILE:
			bad.append_array(_hits(random_re, src, f))
		if class_re.search_all(src).size() != 1:
			bad.append("%s: class_name 이 정확히 1개가 아님" % f)
		var ext: Array[RegExMatch] = extends_re.search_all(src)
		if ext.size() != 1 or not ["RefCounted", "Resource"].has(ext[0].get_string(1)):
			bad.append("%s: extends RefCounted/Resource 아님" % f)
		if inner_re.search(src) != null:
			bad.append("%s: 내부 class 선언(파일당 클래스 하나)" % f)
	assert_eq(bad.size(), 0, "금지 패턴 없음: %s" % ", ".join(bad))
	# rng.gd 는 RandomNumberGenerator 를 실제로 쓴다(검사기 자체 확인).
	assert_gt(_hits(random_re, FileAccess.get_file_as_string(RNG_FILE), RNG_FILE).size(), 0, "rng.gd 에서는 걸린다")
