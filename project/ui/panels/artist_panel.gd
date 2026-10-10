class_name ArtistPanel
extends UiPanel
## SE-039 AC2: 섭외 패널(PRD 전체화면 패널: 아티스트 섭외). artist.md "UI 계약 (SE-039)".
## 읽는 sim 멤버(SE-033 인계로 한정 — 덕 타이핑, 클래스 이름을 쓰지 않는다):
##   설정 객체(ArtistConfig): artist_ids()·artist(id)·guarantee(grade)·unlock_reputation(grade)
##   시스템 객체(ArtistSystem): check_book(id)·roster()·entry(id). 상태를 바꾸지 않는 읽기뿐.
## 행 수 = artist_ids() 길이(리터럴 금지). 행: 이름·장르(genres.json)·등급·인기·실력·개런티·바이오·태그·상태·섭외 버튼.
## 버튼 활성 = 섭외 구간(artist.json booking_phases) ∧ 사유 "" — 사유는 시스템이 있으면 check_book(id), 없으면
##   이벤트로 받은 값으로 같은 K2~K4 를 거울 판정(명성 total < unlock_reputation(grade) ∧ 발굴 아님 → grade_locked).
## 구독: artist.booked(행 "오늘 공연")·artist.grown·artist.lineup_set·reputation.changed·time.phase_changed·
##   time.day_started·session.loaded. 거절(artist.booking_rejected)의 알림은 Notifications 몫.
## 발행: artist.book_requested {artist_id}.

signal close_requested

const ROWS_PATH: NodePath = ^"Panel/VBox/Scroll/Rows"
const TITLE_PATH: NodePath = ^"Panel/VBox/Title"
const CLOSE_PATH: NodePath = ^"Panel/VBox/Close"
const ROW_NAME_PATTERN: String = "Row_%s"
## 행 안 칸 간격(px, 표시 상수).
const ROW_SEPARATION: int = 14
const META_ARTIST_ID: StringName = &"artist_id"
## 사유 id(events.md artist.booking_rejected reason, check_book 반환값과 같은 5종 중 패널이 쓰는 것).
const R_NONE: String = ""
const R_NOT_ALLOWED: String = "not_allowed"
const R_ALREADY_BOOKED: String = "already_booked"
const R_GRADE_LOCKED: String = "grade_locked"
## roster 원소 필드(artist_system ENTRY_FIELDS 중 표시에 쓰는 것).
const F_GRADE: String = "grade"
const F_POP: String = "popularity"
const F_SKILL: String = "skill"
const F_DISCOVERED: String = "discovered_here"

var _config: Object
var _artists: Object
var _reputation: int = 0
var _phase: String = ""
var _booked_id: String = ""
## id → roster 원소(복사본).
var _entries: Dictionary = {}


## 읽기 전용 객체를 넣는다. artists 가 null 이면 이벤트 거울 판정만 쓴다.
func set_sources(config: Object, artists: Object) -> void:
	_config = config
	_artists = artists
	_reload_roster()
	if is_inside_tree() and _data != null:
		_build_rows()


func _event_handlers() -> Dictionary:
	return {
		"artist.booked": on_booked,
		"artist.grown": on_grown,
		"artist.lineup_set": on_lineup_set,
		"reputation.changed": on_reputation_changed,
		"time.phase_changed": on_phase_changed,
		"time.day_started": on_day_started,
		"session.loaded": on_session_loaded,
	}


func _on_setup() -> void:
	(get_node(TITLE_PATH) as Label).text = t("ui.artist.title")
	var close: Button = get_node(CLOSE_PATH) as Button
	close.text = t("ui.common.close")
	if not close.pressed.is_connected(_emit_close):
		close.pressed.connect(_emit_close)
	_build_rows()


# --- 조회 -------------------------------------------------------------------

func get_rows() -> Array[Control]:
	var out: Array[Control] = []
	for c: Node in get_node(ROWS_PATH).get_children():
		if c is Control and not c.is_queued_for_deletion():
			out.append(c as Control)
	return out


func get_row(artist_id: String) -> Control:
	return get_node(ROWS_PATH).get_node_or_null(ROW_NAME_PATTERN % artist_id) as Control


func get_book_button(artist_id: String) -> Button:
	var r: Control = get_row(artist_id)
	return r.get_node("Line/Book") as Button if r != null else null


func get_status_text(artist_id: String) -> String:
	var r: Control = get_row(artist_id)
	return (r.get_node("Line/Status") as Label).text if r != null else ""


func get_row_text(artist_id: String) -> String:
	var r: Control = get_row(artist_id)
	if r == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for path: String in ["Line/Name", "Line/Genre", "Line/Grade", "Line/Stats", "Line/Guarantee", "Bio", "Tags"]:
		parts.append((r.get_node(path) as Label).text)
	return "\n".join(parts)


## 섭외 사유(""면 가능). 시스템이 있으면 check_book, 없으면 거울 판정.
func book_reason(artist_id: String) -> String:
	if not _data.booking_phases.has(_phase):
		return R_NOT_ALLOWED
	if _artists != null:
		return str(_artists.call("check_book", artist_id))
	if not _booked_id.is_empty():
		return R_ALREADY_BOOKED
	var e: Dictionary = _entry(artist_id)
	var grade: String = str(e.get(F_GRADE, ""))
	if _config != null and _reputation < int(_config.call("unlock_reputation", grade)) and not bool(e.get(F_DISCOVERED, false)):
		return R_GRADE_LOCKED
	return R_NONE


# --- 이벤트 -----------------------------------------------------------------

func on_booked(p: Dictionary) -> void:
	_booked_id = str(p.get("artist_id", ""))
	_refresh()


func on_grown(p: Dictionary) -> void:
	var id: String = str(p.get("artist_id", ""))
	var e: Dictionary = _entry(id)
	for k: String in [F_GRADE, F_POP, F_SKILL]:
		if p.has(k):
			e[k] = p[k]
	_entries[id] = e
	_refresh()


func on_lineup_set(p: Dictionary) -> void:
	var id: Variant = p.get("artist_id")
	_booked_id = str(id) if id != null else ""
	_refresh()


func on_reputation_changed(p: Dictionary) -> void:
	_reputation = int(p.get("total", _reputation))
	_refresh()


func on_phase_changed(p: Dictionary) -> void:
	_phase = str(p.get("to", _phase))
	_refresh()


func on_day_started(_p: Dictionary) -> void:
	_booked_id = ""
	_refresh()


func on_session_loaded(p: Dictionary) -> void:
	_phase = str(p.get("phase", _phase))
	_reload_roster()
	_refresh()


## HUD 와 같은 명성 초기값(ReputationSystem.total 읽기).
func set_reputation(total: int) -> void:
	_reputation = total
	_refresh()


# --- 내부 -------------------------------------------------------------------

func _entry(id: String) -> Dictionary:
	if _entries.has(id):
		return (_entries[id] as Dictionary).duplicate()
	var row: Dictionary = _config.call("artist", id) if _config != null else {}
	return {F_GRADE: row.get(F_GRADE, ""), F_POP: row.get(F_POP, 0), F_SKILL: row.get(F_SKILL, 0)}


func _reload_roster() -> void:
	_entries.clear()
	if _artists == null:
		return
	for e: Variant in _artists.call("roster"):
		if e is Dictionary:
			_entries[str((e as Dictionary).get("id", ""))] = (e as Dictionary).duplicate(true)
	if not _booked_id.is_empty() and (_artists.call("entry", _booked_id) as Dictionary).is_empty():
		_booked_id = ""


func _ids() -> Array:
	return _config.call("artist_ids") if _config != null else []


func _build_rows() -> void:
	var rows: Node = get_node(ROWS_PATH)
	for c: Node in rows.get_children():
		rows.remove_child(c)
		c.free()
	for id: Variant in _ids():
		rows.add_child(_make_row(str(id)))
	_refresh()


func _make_row(id: String) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.name = ROW_NAME_PATTERN % id
	box.set_meta(META_ARTIST_ID, id)
	var line: HBoxContainer = HBoxContainer.new()
	line.name = "Line"
	line.add_theme_constant_override("separation", ROW_SEPARATION)
	box.add_child(line)
	for n: String in ["Name", "Genre", "Grade", "Stats", "Guarantee", "Status"]:
		var l: Label = Label.new()
		l.name = n
		line.add_child(l)
	(line.get_node("Name") as Label).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var b: Button = Button.new()
	b.name = "Book"
	b.focus_mode = Control.FOCUS_NONE
	b.text = t("ui.artist.book")
	b.pressed.connect(_on_book_pressed.bind(id))
	line.add_child(b)
	for n: String in ["Bio", "Tags"]:
		var l: Label = Label.new()
		l.name = n
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(l)
	return box


func _refresh() -> void:
	if not is_inside_tree() or _data == null:
		return
	for r: Control in get_rows():
		var id: String = str(r.get_meta(META_ARTIST_ID))
		var row: Dictionary = _config.call("artist", id) if _config != null else {}
		var e: Dictionary = _entry(id)
		var grade: String = str(e.get(F_GRADE, ""))
		(r.get_node("Line/Name") as Label).text = str(row.get("name", id))
		(r.get_node("Line/Genre") as Label).text = _data.genre_name(str(row.get("genre", "")))
		(r.get_node("Line/Grade") as Label).text = t("ui.artist.grade.%s" % grade)
		(r.get_node("Line/Stats") as Label).text = t("ui.artist.stats", {"popularity": int(e.get(F_POP, 0)), "skill": int(e.get(F_SKILL, 0))})
		var guarantee: int = int(_config.call("guarantee", grade)) if _config != null else 0
		(r.get_node("Line/Guarantee") as Label).text = t("ui.artist.guarantee", {"guarantee": guarantee})
		(r.get_node("Bio") as Label).text = t(str(row.get("bio_key", "")))
		var tags: PackedStringArray = PackedStringArray()
		for tag: Variant in row.get("personality", []):
			tags.append(t("artist.tag.%s" % str(tag)))
		(r.get_node("Tags") as Label).text = " · ".join(tags)
		var reason: String = book_reason(id)
		(r.get_node("Line/Book") as Button).disabled = reason != R_NONE
		(r.get_node("Line/Status") as Label).text = _status_text(id, reason, grade)


func _status_text(id: String, reason: String, grade: String) -> String:
	if id == _booked_id:
		return t("ui.artist.status.today")
	match reason:
		R_GRADE_LOCKED:
			return t("ui.artist.status.locked", {"reputation": int(_config.call("unlock_reputation", grade)) if _config != null else 0})
		R_ALREADY_BOOKED:
			return t("ui.artist.status.booked_other")
	return ""


func _on_book_pressed(artist_id: String) -> void:
	if _bus != null and book_reason(artist_id) == R_NONE:
		_bus.publish("artist.book_requested", {"artist_id": artist_id})


func _emit_close() -> void:
	close_requested.emit()
