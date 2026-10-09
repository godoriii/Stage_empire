extends GutTest
## SE-004 AC1(셰이더 uniform 선언·COLOR 사용·로드), AC2(시안 .tres 파라미터 = 티켓 표, next_pass 외곽선 구조),
## AC3(셰이더 상수·플레이스홀더 치수가 코드에 리터럴로 없다).
## 헤드리스(더미 RenderingServer)에서는 Shader.get_shader_uniform_list() 가 비므로 uniform 은 소스 텍스트로 검사한다.

const TOON_SHADER: String = "res://view/shaders/toon.gdshader"
const OUTLINE_SHADER: String = "res://view/shaders/outline.gdshader"
const TOON_UNIFORMS: Array[String] = [
	"cell_steps", "shadow_tint", "rim_enabled", "rim_strength", "rim_color",
	"base_color", "accent_color", "emissive_color",
]
const OUTLINE_UNIFORMS: Array[String] = ["outline_px", "outline_color"]
## 티켓 "시안 정의" 표: id → [셀 단계, 림라이트, 외곽선 px].
const TABLE: Dictionary = {
	"a": [2, false, 1.0],
	"b": [3, true, 2.0],
	"c": [2, true, 2.0],
}
const TOON_TRES_PATTERN: String = "res://view/shaders/params/toon_%s.tres"
const OUTLINE_TRES_PATTERN: String = "res://view/shaders/params/outline_%s.tres"

## AC3: 숫자 리터럴이 전혀 없어야 하는 파일(허용: 0, 0.5, 1 과 배열 인덱스).
const STRICT_FILES: Array[String] = [
	"res://view/shaders/shader_variants.gd",
	"res://view/scenes/shader_placeholders.gd",
	"res://view/scenes/shader_placeholder_set.gd",
]
## AC3: 셰이더 파라미터·플레이스홀더 메시를 다루는 줄에 리터럴이 없어야 하는 파일(기존 스파이크·샌드박스 수치는 대상 아님).
const TARGETED_FILES: Array[String] = [
	"res://view/scenes/grid_sandbox.gd",
	"res://view/perf/spike_crowd.gd",
]
const ALLOWED_LITERALS: Array[String] = ["0", "0.0", "0.5", "1", "1.0"]
## 셰이더 파라미터 이름·파라미터 설정·플레이스홀더 프리미티브가 나오는 줄.
const SHADER_LINE_PATTERN: String = "(cell_steps|shadow_tint|rim_enabled|rim_strength|rim_width|rim_color|base_color|accent_color|emissive_color|emissive_energy|outline_px|outline_color|set_shader_parameter|CapsuleMesh|BoxMesh)"
const NUMBER_PATTERN: String = "(?<![\\w.])(\\d+\\.\\d*|\\.\\d+|\\d+)(?![\\w.])"


func _src(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _declares_uniform(src: String, name: String) -> bool:
	var re: RegEx = RegEx.create_from_string("(?m)^\\s*uniform\\s+\\w+\\s+%s\\b" % name)
	return re.search(src) != null


# --- AC1 ------------------------------------------------------------------

func test_shader_files_declare_required_uniforms() -> void:
	var toon_src: String = _src(TOON_SHADER)
	var outline_src: String = _src(OUTLINE_SHADER)
	assert_false(toon_src.is_empty(), "toon.gdshader 읽기")
	assert_false(outline_src.is_empty(), "outline.gdshader 읽기")
	for u: String in TOON_UNIFORMS:
		assert_true(_declares_uniform(toon_src, u), "toon.gdshader uniform %s" % u)
	for u: String in OUTLINE_UNIFORMS:
		assert_true(_declares_uniform(outline_src, u), "outline.gdshader uniform %s" % u)
	assert_true(RegEx.create_from_string("\\bCOLOR\\b").search(toon_src) != null, "toon.gdshader 가 정점색 COLOR 를 쓴다")
	assert_true(toon_src.contains("shader_type spatial"), "spatial 셰이더")
	# 외곽선: 역면 헐(앞면 컬링) + 화면 px 환산(VIEWPORT_SIZE, PROJECTION_MATRIX).
	assert_true(outline_src.contains("cull_front"), "역면 헐: cull_front")
	assert_true(outline_src.contains("VIEWPORT_SIZE"), "px 환산에 VIEWPORT_SIZE")
	assert_true(outline_src.contains("PROJECTION_MATRIX"), "px 환산에 PROJECTION_MATRIX")
	for path: String in [TOON_SHADER, OUTLINE_SHADER]:
		var sh: Shader = load(path) as Shader
		assert_not_null(sh, "%s 가 Shader 로 로드" % path)
		if sh != null:
			assert_false(sh.get_code().is_empty(), "%s get_code() 비어 있지 않음" % path)
	# 역검증: 같은 정규식이 선언 없는 소스에서는 false.
	assert_false(_declares_uniform("// uniform int cell_steps\nfloat cell_steps = 2.0;", "cell_steps"), "대조군: 주석·지역 변수는 선언 아님")
	assert_true(_declares_uniform("uniform int cell_steps : hint_range(2, 8) = 2;", "cell_steps"), "대조군: 힌트 있는 선언")


# --- SE-024 AC1 (materials.md R-A·C1) ---------------------------------------

## 정점 알파(COLOR.a) 읽기. 슬롯 = 서피스(docs/gdd/materials.md 채택안 (b)) → toon.gdshader 는 정점 알파를 읽지 않는다.
const VERTEX_ALPHA_PATTERN: String = "\\bCOLOR\\s*\\.\\s*a\\b"


static func _vertex_alpha_reads(src: String) -> int:
	return RegEx.create_from_string(VERTEX_ALPHA_PATTERN).search_all(src).size()


func test_toon_shader_does_not_read_vertex_alpha() -> void:
	var src: String = _src(TOON_SHADER)
	assert_false(src.is_empty(), "toon.gdshader 읽기")
	assert_eq(_vertex_alpha_reads(src), 0, "toon.gdshader 에 COLOR.a 읽기 0건(R-A)")
	# 정점색 rgb 는 base 서피스 albedo 에 그대로 곱한다(accent 마스크 없음).
	assert_true(src.contains("ALBEDO = base_color.rgb * COLOR.rgb;"), "ALBEDO = base_color.rgb * COLOR.rgb")
	# accent_color uniform 은 R-B(SE-041 2차)까지 미사용으로 남긴다(.tres 3개 변경 회피).
	assert_true(_declares_uniform(src, "accent_color"), "accent_color uniform 선언 유지")
	# 대조군: 같은 정규식이 알파 읽기는 잡고 rgb·다른 식별자는 거른다.
	assert_eq(_vertex_alpha_reads("x = COLOR.a;"), 1, "대조군: COLOR.a 1건")
	assert_eq(_vertex_alpha_reads("float w = 1.0 - COLOR . a;"), 1, "대조군: 공백 있는 COLOR . a 1건")
	assert_eq(_vertex_alpha_reads("ALBEDO = COLOR.rgb; float y = MY_COLOR.a + COLOR.ab;"), 0, "대조군: COLOR.rgb·MY_COLOR.a·COLOR.ab 는 0건")


# --- AC2 ------------------------------------------------------------------

func test_variant_params_match_table() -> void:
	var toon: Shader = load(TOON_SHADER) as Shader
	var outline: Shader = load(OUTLINE_SHADER) as Shader
	for id: String in TABLE.keys():
		var row: Array = TABLE[id]
		var mat: ShaderMaterial = load(TOON_TRES_PATTERN % id) as ShaderMaterial
		assert_not_null(mat, "toon_%s.tres 는 ShaderMaterial" % id)
		if mat == null:
			continue
		assert_eq(mat.shader, toon, "%s: shader == toon.gdshader (같은 리소스)" % id)
		assert_eq(int(mat.get_shader_parameter("cell_steps")), int(row[0]), "%s: cell_steps" % id)
		assert_eq(bool(mat.get_shader_parameter("rim_enabled")), bool(row[1]), "%s: rim_enabled" % id)
		var ol: ShaderMaterial = load(OUTLINE_TRES_PATTERN % id) as ShaderMaterial
		assert_not_null(ol, "outline_%s.tres 는 ShaderMaterial" % id)
		assert_eq(mat.next_pass, ol, "%s: next_pass == outline_%s.tres" % [id, id])
		if ol == null:
			continue
		assert_eq(ol.shader, outline, "%s: 외곽선 shader == outline.gdshader" % id)
		assert_almost_eq(float(ol.get_shader_parameter("outline_px")), float(row[2]), 0.0001, "%s: outline_px" % id)
		assert_null(ol.next_pass, "%s: 외곽선 뒤에 추가 패스 없음" % id)
		# 셰이더 기본값에 기대지 않는다: 모든 uniform 이 .tres 에 명시돼 있다(아트 디렉터가 .tres 만 보고 조정).
		var toon_text: String = _src(TOON_TRES_PATTERN % id)
		for u: String in TOON_UNIFORMS:
			assert_true(toon_text.contains("shader_parameter/%s = " % u), "toon_%s.tres 에 %s 명시" % [id, u])
		var outline_text: String = _src(OUTLINE_TRES_PATTERN % id)
		for u: String in OUTLINE_UNIFORMS:
			assert_true(outline_text.contains("shader_parameter/%s = " % u), "outline_%s.tres 에 %s 명시" % [id, u])
	# 시안 간 차이는 표의 세 축뿐: 나머지 파라미터는 A/B/C 가 같다(비교 조건 통일).
	var a: ShaderMaterial = load(TOON_TRES_PATTERN % "a") as ShaderMaterial
	for id: String in ["b", "c"]:
		var m: ShaderMaterial = load(TOON_TRES_PATTERN % id) as ShaderMaterial
		for u: String in ["shadow_tint", "rim_strength", "rim_width", "rim_color", "base_color", "accent_color", "emissive_color", "emissive_energy"]:
			assert_eq(m.get_shader_parameter(u), a.get_shader_parameter(u), "%s.%s == a.%s" % [id, u, u])
		var ol_a: ShaderMaterial = a.next_pass as ShaderMaterial
		var ol_m: ShaderMaterial = m.next_pass as ShaderMaterial
		assert_eq(ol_m.get_shader_parameter("outline_color"), ol_a.get_shader_parameter("outline_color"), "%s 외곽선 색 == a" % id)


# --- AC3 ------------------------------------------------------------------

## 주석과 문자열 리터럴, 배열 인덱스([n])를 지운 줄.
static func _code_only(line: String) -> String:
	var no_str: String = RegEx.create_from_string("\"([^\"\\\\]|\\\\.)*\"").sub(line, "\"\"", true)
	var hash_at: int = no_str.find("#")
	if hash_at >= 0:
		no_str = no_str.substr(0, hash_at)
	return RegEx.create_from_string("\\[\\s*\\d+\\s*\\]").sub(no_str, "[]", true)


## 줄 배열에서 허용 밖 숫자 리터럴이 있는 줄. line_filter 가 비어 있지 않으면 그 정규식에 걸리는 줄만 본다.
static func _literal_hits(lines: PackedStringArray, label: String, line_filter: String = "") -> PackedStringArray:
	var num_re: RegEx = RegEx.create_from_string(NUMBER_PATTERN)
	var filter_re: RegEx = RegEx.create_from_string(line_filter) if not line_filter.is_empty() else null
	var hits: PackedStringArray = PackedStringArray()
	for i: int in lines.size():
		var code: String = _code_only(lines[i])
		if filter_re != null and filter_re.search(code) == null:
			continue
		for m: RegExMatch in num_re.search_all(code):
			if not ALLOWED_LITERALS.has(m.get_string()):
				hits.append("%s:%d: %s" % [label, i + 1, lines[i].strip_edges()])
				break
	return hits


func test_no_shader_constants_in_code() -> void:
	var strict: PackedStringArray = PackedStringArray(STRICT_FILES)
	strict.append_array(ViewTestUtil.list_sources(["res://view/shaders"], "gd"))
	var hits: PackedStringArray = PackedStringArray()
	for path: String in strict:
		assert_true(FileAccess.file_exists(path), "검사 대상 존재: %s" % path)
		hits.append_array(_literal_hits(_src(path).split("\n"), path))
	assert_eq(hits.size(), 0, "셰이더·플레이스홀더 스크립트에 숫자 리터럴 없음(0, 0.5, 1, 인덱스 제외): %s" % ", ".join(hits))
	var targeted: PackedStringArray = PackedStringArray()
	for path: String in TARGETED_FILES:
		targeted.append_array(_literal_hits(_src(path).split("\n"), path, SHADER_LINE_PATTERN))
	assert_eq(targeted.size(), 0, "샌드박스·스파이크의 셰이더 파라미터/프리미티브 줄에 리터럴 없음: %s" % ", ".join(targeted))
	# 셰이더 머티리얼을 코드에서 만들지 않는다(값은 .tres 에서만).
	var all_gd: PackedStringArray = ViewTestUtil.list_sources(ViewTestUtil.SOURCE_ROOTS, "gd")
	var made: PackedStringArray = ViewTestUtil.grep(all_gd, "(ShaderMaterial|Shader)\\.new\\(|set_shader_parameter\\(")
	assert_eq(made.size(), 0, "view/ui 코드에 ShaderMaterial.new()·set_shader_parameter() 없음: %s" % ", ".join(made))
	# 역검증: 같은 검사가 리터럴을 잡고, 허용 값·인덱스·주석·문자열은 통과시킨다.
	var fake: PackedStringArray = PackedStringArray([
		"mat.set_shader_parameter(\"cell_steps\", 3)",
		"box.size = Vector3(3, 1.1, 1)",
		"var x: float = s.y * 0.5 + names[2].length() - 1",
		"# 주석의 2px 는 무시",
		"var t: String = \"outline 2px\"",
	])
	assert_eq(_literal_hits(fake, "fake").size(), 2, "대조군(strict): 3 과 1.1 이 있는 두 줄")
	assert_eq(_literal_hits(fake, "fake", SHADER_LINE_PATTERN).size(), 1, "대조군(targeted): set_shader_parameter 줄 1건")


# --- SE-021 AC5 -------------------------------------------------------------

const SS_SHADER: String = "res://view/shaders/outline_ss.gdshader"
const SS_PASS_SCENE: String = "res://view/shaders/outline_ss_pass.tscn"


## 셰이더 소스의 uniform 이름 전부(설정할 수 없는 화면/깊이 텍스처 힌트 샘플러는 뺀다).
static func _settable_uniforms(src: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var re: RegEx = RegEx.create_from_string("(?m)^\\s*uniform\\s+\\w+\\s+(\\w+)([^;]*);")
	for m: RegExMatch in re.search_all(src):
		if m.get_string(2).contains("hint_depth_texture") or m.get_string(2).contains("hint_screen_texture"):
			continue
		out.append(m.get_string(1))
	return out


func test_ss_uniforms_all_in_tres() -> void:
	var src: String = _src(SS_SHADER)
	assert_false(src.is_empty(), "outline_ss.gdshader 읽기")
	var uniforms: PackedStringArray = _settable_uniforms(src)
	for u: String in ["outline_px", "outline_color", "depth_threshold_px", "normal_threshold", "facing_bias",
			"plane_epsilon_px", "normal_fit_px"]:
		assert_true(uniforms.has(u), "outline_ss uniform %s" % u)
	var ss_text: String = _src(OUTLINE_TRES_PATTERN % "ss")
	for u: String in uniforms:
		assert_true(ss_text.contains("shader_parameter/%s = " % u), "outline_ss.tres 에 %s 명시" % u)
	var ol_ss: ShaderMaterial = load(OUTLINE_TRES_PATTERN % "ss") as ShaderMaterial
	var ol_b: ShaderMaterial = load(OUTLINE_TRES_PATTERN % "b") as ShaderMaterial
	assert_eq(ol_ss.shader, load(SS_SHADER), "outline_ss.tres shader == outline_ss.gdshader")
	assert_almost_eq(float(ol_ss.get_shader_parameter("outline_px")), 2.0, 0.0001, "outline_px == 2")
	assert_eq(ol_ss.get_shader_parameter("outline_color"), ol_b.get_shader_parameter("outline_color"), "외곽선 색 == B")
	assert_eq(ol_ss.render_priority, Material.RENDER_PRIORITY_MAX, "투명 패스 맨 뒤")
	# toon_ss = toon_b 와 같은 파라미터, next_pass 없음.
	var toon_ss: ShaderMaterial = load(TOON_TRES_PATTERN % "ss") as ShaderMaterial
	var toon_b: ShaderMaterial = load(TOON_TRES_PATTERN % "b") as ShaderMaterial
	assert_eq(toon_ss.shader, toon_b.shader, "toon_ss shader == toon.gdshader")
	assert_null(toon_ss.next_pass, "toon_ss next_pass 없음")
	var toon_text: String = _src(TOON_TRES_PATTERN % "ss")
	for u: String in _settable_uniforms(_src(TOON_SHADER)):
		assert_true(toon_text.contains("shader_parameter/%s = " % u), "toon_ss.tres 에 %s 명시" % u)
		assert_eq(toon_ss.get_shader_parameter(u), toon_b.get_shader_parameter(u), "toon_ss.%s == toon_b" % u)
	# 포스트 패스 씬은 outline_ss.tres 를 쓰고 그림자를 드리우지 않는다.
	var scene_text: String = _src(SS_PASS_SCENE)
	assert_true(scene_text.contains("res://view/shaders/params/outline_ss.tres"), "포스트 패스 씬 → outline_ss.tres")
	assert_true(scene_text.contains("cast_shadow = 0"), "포스트 패스 그림자 off")
	# 대조군: 정규식이 힌트 샘플러를 빼고 일반 uniform 은 잡는다.
	var fake: String = "uniform sampler2D t : hint_depth_texture;\nuniform float a : hint_range(0.0, 1.0) = 0.5;\n// uniform float b;"
	assert_eq(_settable_uniforms(fake), PackedStringArray(["a"]), "대조군: 설정 가능한 uniform 1개")
