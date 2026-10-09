extends GutTest
## SE-032 AC7·AC8 — project/world/**/*.gd 경계 검사. test_core_boundary.gd 와 같은 방식(소스를 FileAccess 로 읽어 패턴 검사).
## - Node·SceneTree·_process·get_node·Time.·직접 난수 0건, class_name 1개 + extends RefCounted/Resource, 내부 class 없음.
## - view/ui 참조 0, 다른 sim 시스템 직접 참조 0(원칙 4: 이벤트 버스로만).
## - 엔진 클래스 생성은 허용 목록(AStarGrid2D)과 core·sim·world 의 class_name 만.
## - 매직 넘버 0: const 선언 밖 수 리터럴은 0·1 만(수치는 project/data).

const WORLD_ROOT: String = "res://world"
const CLASS_ROOTS: Array[String] = ["res://core", "res://sim", "res://world"]
const EXPECTED: Array[String] = [
	"res://world/build_config.gd", "res://world/build_system.gd", "res://world/coverage.gd",
	"res://world/furniture_config.gd", "res://world/grid_occupancy.gd", "res://world/map_config.gd",
	"res://world/tile_path.gd",
]
## world 에서 .new() 로 만들어도 되는 엔진 클래스(RefCounted 계열, Node 아님).
const ALLOWED_ENGINE_CLASSES: Array[String] = ["AStarGrid2D"]
## 원칙 4: world 가 이름으로 부르면 안 되는 sim 시스템 클래스.
const FORBIDDEN_SYSTEM_RE: String = "(?<![\\w])(Economy|EconomyConfig)(?![\\w])"
const PRESENTATION_RE: String = "res://(view|ui)/"
const NUMBER_RE: String = "(?<![\\w.])\\d+(\\.\\d+)?(?![\\w.])"
const ALLOWED_BARE_NUMBERS: Array[String] = ["0", "1"]
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


## 주석(#…)과 문자열 리터럴("…", '…')을 지운다(한 줄 단위).
func _strip(src: String) -> String:
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
	var files: PackedStringArray = _list_gd(WORLD_ROOT)
	for f: String in EXPECTED:
		assert_true(files.has(f), "%s 존재" % f)


func test_world_has_no_node_time_or_random() -> void:
	var files: PackedStringArray = _list_gd(WORLD_ROOT)
	assert_gt(files.size(), 0)
	var forbidden: RegEx = RegEx.create_from_string("extends\\s+Node|_process\\(|_physics_process\\(|get_node\\(|get_tree\\(|SceneTree|(?<![\\w])Time\\.")
	var random_re: RegEx = RegEx.create_from_string("randi\\(|randf\\(|randomize\\(|RandomNumberGenerator|SeededRng|\\.stream\\(")
	var presentation: RegEx = RegEx.create_from_string(PRESENTATION_RE)
	var systems: RegEx = RegEx.create_from_string(FORBIDDEN_SYSTEM_RE)
	var class_re: RegEx = RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*$")
	var extends_re: RegEx = RegEx.create_from_string("(?m)^extends\\s+(\\w+)\\s*$")
	var inner_re: RegEx = RegEx.create_from_string("(?m)^\\s*class\\s+\\w+")
	# 검사기 자체 확인
	assert_gt(_hits(forbidden, "extends Node2D\nvar t = Time.get_ticks_msec()", "self").size(), 1)
	assert_gt(_hits(random_re, "var r = randi()", "self").size(), 0)
	assert_eq(_hits(systems, _strip("var e: Economy # Economy"), "self").size(), 1)
	var bad: PackedStringArray = []
	for f: String in files:
		var src: String = FileAccess.get_file_as_string(f)
		var code: String = _strip(src)
		bad.append_array(_hits(forbidden, code, f))
		bad.append_array(_hits(random_re, code, f))
		bad.append_array(_hits(presentation, src, f))
		bad.append_array(_hits(systems, code, f))
		if class_re.search_all(src).size() != 1:
			bad.append("%s: class_name 이 정확히 1개가 아님" % f)
		var ext: Array[RegExMatch] = extends_re.search_all(src)
		if ext.size() != 1 or not ["RefCounted", "Resource"].has(ext[0].get_string(1)):
			bad.append("%s: extends RefCounted/Resource 아님" % f)
		if inner_re.search(src) != null:
			bad.append("%s: 내부 class 선언(파일당 클래스 하나)" % f)
	assert_eq(bad.size(), 0, "금지 패턴 없음: %s" % ", ".join(bad))


func test_engine_classes_allow_list() -> void:
	var known: Dictionary = {}
	var cn: RegEx = RegEx.create_from_string("(?m)^class_name\\s+(\\w+)")
	for root: String in CLASS_ROOTS:
		for f: String in _list_gd(root):
			var m: RegExMatch = cn.search(FileAccess.get_file_as_string(f))
			if m != null:
				known[m.get_string(1)] = true
	for c: String in ALLOWED_ENGINE_CLASSES:
		known[c] = true
	assert_true(ClassDB.is_parent_class("AStarGrid2D", "RefCounted"), "AStarGrid2D 는 RefCounted(Node 아님)")
	var new_re: RegEx = RegEx.create_from_string("(?<![\\w])([A-Z]\\w*)\\.new\\(")
	var bad: PackedStringArray = []
	var used_astar: bool = false
	for f: String in _list_gd(WORLD_ROOT):
		for m: RegExMatch in new_re.search_all(_strip(FileAccess.get_file_as_string(f))):
			var name: String = m.get_string(1)
			if name == "AStarGrid2D":
				used_astar = true
			if not known.has(name):
				bad.append("%s: %s.new()" % [f, name])
	assert_eq(bad.size(), 0, "허용 목록 밖 엔진 클래스 생성 없음: %s" % ", ".join(bad))
	assert_true(used_astar, "TilePath 가 AStarGrid2D 를 쓴다(허용 목록이 실제로 쓰인다)")


func test_world_has_no_magic_numbers() -> void:
	var re: RegEx = RegEx.create_from_string(NUMBER_RE)
	var tick_re: RegEx = RegEx.create_from_string(TICK_LITERAL_RE)
	var const_re: RegEx = RegEx.create_from_string("^\\s*const\\s")
	var bad: PackedStringArray = []
	for f: String in _list_gd(WORLD_ROOT):
		var code: String = _strip(FileAccess.get_file_as_string(f))
		bad.append_array(_hits(tick_re, code, f))
		for line: String in code.split("\n"):
			if const_re.search(line) != null:
				continue
			for m: RegExMatch in re.search_all(line):
				if not ALLOWED_BARE_NUMBERS.has(m.get_string()):
					bad.append("%s: %s (%s)" % [f, m.get_string(), line.strip_edges()])
	assert_eq(bad.size(), 0, "world 에 const 밖 매직 넘버 없음: %s" % ", ".join(bad))
