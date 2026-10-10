extends GutTest
## SE-039 qa: 실제 ui_ko.json 으로 그린 화면에 키 폴백("ui.…")이 남지 않고, 코드가 읽는 정적 키가 전부 테이블에 있다.
## (기존 테스트는 UiText.from_strings 픽스처만 써서, 테이블 누락·오타가 캡처에서만 보였다.)

const SANDBOX_SCENE: String = "res://view/scenes/grid_sandbox.tscn"
const KEY_LITERAL: String = "\"(ui\\.[a-z0-9_.]+)([^\"]*)\""
const KEY_ON_SCREEN: String = "(^|\\s)ui\\.[a-z0-9_]+\\.[a-z0-9_.]+"


func _table() -> Dictionary:
	var d: Dictionary = UiTestUtil.json(UiText.UI_PATH)
	return d.get("strings", {}) as Dictionary


func test_every_static_key_literal_in_ui_code_exists_in_table() -> void:
	var table: Dictionary = _table()
	assert_gt(table.size(), 0, "ui_ko.json strings 읽음")
	var re: RegEx = RegEx.create_from_string(KEY_LITERAL)
	var static_keys: int = 0
	var missing: PackedStringArray = PackedStringArray()
	var prefixes: PackedStringArray = PackedStringArray()
	for f: String in ViewTestUtil.list_sources(["res://ui"], "gd"):
		for line: String in FileAccess.get_file_as_string(f).split("\n"):
			if line.strip_edges().begins_with("#"):
				continue
			for m: RegExMatch in re.search_all(line):
				var key: String = m.get_string(1)
				if not m.get_string(2).is_empty():
					prefixes.append(key)   # "ui.phase.%s" 같은 동적 키의 접두
					continue
				static_keys += 1
				if not table.has(key):
					missing.append("%s (%s)" % [key, f])
	assert_gt(static_keys, 40, "정적 키를 충분히 찾았다(검사가 비어 있지 않다)")
	assert_eq(missing.size(), 0, "테이블에 없는 정적 키: %s" % ", ".join(missing))
	assert_gt(prefixes.size(), 0, "동적 키 접두도 찾았다")
	for p: String in prefixes:
		var hit: bool = false
		for k: Variant in table:
			if str(k).begins_with(p):
				hit = true
				break
		assert_true(hit, "동적 키 접두 %s 로 시작하는 항목이 테이블에 있다" % p)


func _screen_texts(n: Node, out: PackedStringArray) -> void:
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is CanvasLayer and not (n as CanvasLayer).visible:
		return   # 숨긴 패널(UiPanel = CanvasLayer)은 CanvasItem 이 아니다
	if n is Label:
		out.append((n as Label).text)
	elif n is Button:
		out.append((n as Button).text)
	elif n is RichTextLabel:
		out.append((n as RichTextLabel).text)
	for c: Node in n.get_children():
		_screen_texts(c, out)


func _sandbox_texts(preset: String) -> PackedStringArray:
	var s: GridSandbox = (load(SANDBOX_SCENE) as PackedScene).instantiate() as GridSandbox
	add_child_autofree(s)
	assert_true(s.setup_ui(preset), "프리셋 %s" % preset)
	var out: PackedStringArray = PackedStringArray()
	_screen_texts(s.get_ui_root(), out)
	return out


func test_presets_show_no_key_fallback_text() -> void:
	var re: RegEx = RegEx.create_from_string(KEY_ON_SCREEN)
	for preset: String in [UiPreset.DAY, UiPreset.CLOSE]:
		var texts: PackedStringArray = _sandbox_texts(preset)
		assert_gt(texts.size(), 10, "%s: 보이는 텍스트 수집" % preset)
		var bad: PackedStringArray = PackedStringArray()
		for t: String in texts:
			if re.search(t) != null:
				bad.append(t)
		assert_eq(bad.size(), 0, "%s: 키 문자열이 화면에 남음: %s" % [preset, " | ".join(bad)])
