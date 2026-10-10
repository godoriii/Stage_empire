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
	# 코드에 있는 동적 키 접두는 전부 아래 전개 계열(_expansion_families)에 들어 있어야 한다.
	# 새 동적 키가 생기면 전개 규칙을 같이 추가하게 만드는 가드다(전개 없이 접두 하나만 있는 키는 못 잡던 SE-039 후속).
	var fams: Dictionary = _expansion_families(_events_md())
	for p: String in prefixes:
		assert_true(fams.has(p), "코드의 동적 키 접두 %s 가 전개 계열 %s 에 있다" % [p, ", ".join(PackedStringArray(fams.keys()))])


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


# ---------------------------------------------------------------------------------------------
# SE-053 AC5 — 동적 키 전개 전부를 원천에서 만들어 ui_ko.json 과 대조한다.
# 원천(테스트 안에 목록을 두지 않는다):
#   구간 ui.phase.<id>                 <- data/sim/sim.json phases[].id
#   아티스트 등급 ui.artist.grade.<id> <- data/artist/artist.json grades[].id
#   공연 없음 ui.report.skip.<reason>  <- docs/gdd/events.md `show.skipped` 행의 reason 열거
#   알림 ui.notify.<출처>, ui.reason.<출처>.<reason>
#                                      <- 출처 = Notifications.SOURCES(이벤트 -> 출처 id),
#                                         reason = docs/gdd/events.md 해당 이벤트 행의 reason 열거
# events.md 파싱: 행 = "| `이벤트` | 페이로드 | ...", 페이로드 칸에서 `reason: "a"|"b"` 열거를 읽고,
#   `reason: String` 인 행(build.rejected)은 "`reason` N종: `a`·`b`…" 를 읽어 N 과 개수가 같음을 단언한다.
# 문서 위치: res://../docs (리포지토리), 변이 사본처럼 docs 가 없으면 환경 변수 SE_DOCS_DIR (docs 디렉터리 경로).
# ---------------------------------------------------------------------------------------------

const PIPE: String = "\u00a6"   # 표 안의 이스케이프된 | (\|) 를 임시로 바꿀 문자


func _events_md() -> String:
	var dir: String = OS.get_environment("SE_DOCS_DIR")
	if dir.is_empty():
		dir = ProjectSettings.globalize_path("res://").path_join("../docs")
	var path: String = dir.path_join("gdd/events.md")
	assert_true(FileAccess.file_exists(path), "events.md 를 읽을 수 있다: %s" % path)
	return FileAccess.get_file_as_string(path)


## 이벤트 행의 페이로드 칸(두 번째 칸). 이스케이프된 | 는 PIPE 로 바꿔 둔다.
func _payload_cell(md: String, ev: String) -> String:
	for line: String in md.split("\n"):
		if line.begins_with("| `%s` |" % ev):
			var cells: PackedStringArray = line.replace("\\|", PIPE).split("|")
			return cells[2] if cells.size() > 2 else ""
	return ""


func _reason_enum(md: String, ev: String) -> PackedStringArray:
	var cell: String = _payload_cell(md, ev)
	var out: PackedStringArray = PackedStringArray()
	if cell.is_empty():
		return out
	var re_inline: RegEx = RegEx.create_from_string("(?<![a-z_])reason: (\"[a-z_]+\"(?:%s\"[a-z_]+\")*)" % PIPE)
	var m: RegExMatch = re_inline.search(cell)
	if m != null:
		for w: RegExMatch in RegEx.create_from_string("\"([a-z_]+)\"").search_all(m.get_string(1)):
			out.append(w.get_string(1))
		return out
	var re_list: RegEx = RegEx.create_from_string("`reason` (\\d+)종: ((?:`[a-z_]+`·?)+)")
	var l: RegExMatch = re_list.search(cell)
	if l != null:
		for w: RegExMatch in RegEx.create_from_string("`([a-z_]+)`").search_all(l.get_string(2)):
			out.append(w.get_string(1))
		assert_eq(out.size(), l.get_string(1).to_int(), "%s: 문서가 적은 reason 개수(%s종)와 나열 수가 같다" % [ev, l.get_string(1)])
	return out


## 계열 접두 -> 전개된 키 배열.
func _expansion_families(md: String) -> Dictionary:
	var fams: Dictionary = {}
	var phases: PackedStringArray = PackedStringArray()
	for ph: Variant in UiTestUtil.json(UiTestUtil.SIM_PATH).get("phases", []) as Array:
		phases.append("ui.phase.%s" % str((ph as Dictionary).get("id", "")))
	fams["ui.phase."] = phases
	var grades: PackedStringArray = PackedStringArray()
	for g: Variant in UiTestUtil.json(UiTestUtil.ARTIST_PATH).get("grades", []) as Array:
		grades.append("ui.artist.grade.%s" % str((g as Dictionary).get("id", "")))
	fams["ui.artist.grade."] = grades
	var skips: PackedStringArray = PackedStringArray()
	for r: String in _reason_enum(md, "show.skipped"):
		skips.append("ui.report.skip.%s" % r)
	fams["ui.report.skip."] = skips
	var notify: PackedStringArray = PackedStringArray()
	var reasons: PackedStringArray = PackedStringArray()
	for ev: Variant in Notifications.SOURCES:
		var src: String = str(Notifications.SOURCES[ev])
		notify.append("ui.notify.%s" % src)
		for r: String in _reason_enum(md, str(ev)):
			reasons.append("ui.reason.%s.%s" % [src, r])
	fams["ui.notify."] = notify
	fams["ui.reason."] = reasons
	return fams


func test_se053_ac5_every_expanded_dynamic_key_exists_in_table() -> void:
	var table: Dictionary = _table()
	var md: String = _events_md()
	var fams: Dictionary = _expansion_families(md)
	var total: int = 0
	var missing: PackedStringArray = PackedStringArray()
	for fam: Variant in fams:
		var keys: PackedStringArray = fams[fam] as PackedStringArray
		assert_gt(keys.size(), 0, "계열 %s: 원천에서 키가 전개된다(원천 파싱이 비지 않았다)" % fam)
		for k: String in keys:
			total += 1
			if not table.has(k):
				missing.append(k)
	gut.p("전개한 동적 키 %d개 (계열 %d)" % [total, fams.size()])
	assert_gt(total, 30, "전개 키 수 하한")
	assert_eq(missing.size(), 0, "ui_ko.json 에 없는 전개 키: %s" % ", ".join(missing))


## 원천 열거를 실제로 읽었는지(파서가 빈 결과로 조용히 통과하지 않게).
func test_se053_ac5_source_enumerations_are_complete() -> void:
	var md: String = _events_md()
	# build.rejected 는 "N종: …" 표기를 읽는다. N 과 나열 수의 일치는 _reason_enum 안에서 단언한다.
	assert_gt(_reason_enum(md, "build.rejected").size(), 0, "build.rejected: '`reason` N종' 나열을 읽었다")
	for ev: Variant in Notifications.SOURCES:
		assert_gt(_reason_enum(md, str(ev)).size(), 0, "%s: events.md 에서 reason 열거를 읽었다" % ev)
	assert_gt(_reason_enum(md, "show.skipped").size(), 0, "show.skipped: reason 열거를 읽었다")


## 반대 방향: 전개 계열 접두 아래의 테이블 키는 전부 원천에서 나온다(원천에서 사라진 사유·등급이 남지 않는다).
func test_se053_ac5_no_orphan_keys_under_expanded_prefixes() -> void:
	var table: Dictionary = _table()
	var fams: Dictionary = _expansion_families(_events_md())
	var expected: Dictionary = {}
	for fam: Variant in fams:
		for k: String in fams[fam] as PackedStringArray:
			expected[k] = true
	var orphans: PackedStringArray = PackedStringArray()
	for k: Variant in table:
		var key: String = str(k)
		for fam: Variant in ["ui.phase.", "ui.artist.grade.", "ui.report.skip.", "ui.reason."]:
			if key.begins_with(str(fam)) and not expected.has(key):
				orphans.append(key)
	assert_eq(orphans.size(), 0, "원천에 없는 전개 계열 키: %s" % ", ".join(orphans))
