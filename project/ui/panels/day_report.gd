class_name DayReport
extends UiPanel
## SE-039 AC4: 마감 리포트(PRD "세션 구조" 마감 = 리포트 화면). 필드는 show.md "마감 리포트 필드" R1~R13 이 전부.
## 리포트는 close 진입 틱까지 받은 이벤트만 합성한다(sim 상태를 읽지 않는다). 행 순서 = UiParams.report_rows(show.md "마감 리포트 필드" 표시 순서, SE-039 2차 확정).
## 구독: economy.day_settled(R1·R6~R8), artist.lineup_set·show.skipped(R2), show.ended(R3·R4), audience.day_summary(R4·R5),
##   reputation.changed(R9·R10), artist.grown(R11), reputation.tier_unlocked + tiers.json(R12), economy.bailout_offered·
##   economy.bankrupt(R13), time.phase_changed(close 에서만 보임), time.day_started(그날 값 초기화), session.loaded.
## 공연 없는 날(show.ended 없음): R3·R5·R11 숨김, R9 "변화 없음"(SE-030 인계).
## 발행: time.next_day_requested {}("다음 날" 버튼, tick.md: close 는 이 명령으로만 이탈).

signal next_day_pressed

## tick.md #세션-구간: 리포트는 close 구간에서만(구간 id 는 events.md 프로토콜 값).
const REPORT_PHASE: String = "close"
const ROWS_PATH: NodePath = ^"Panel/VBox/Rows"
const TITLE_PATH: NodePath = ^"Panel/VBox/Title"
const NEXT_PATH: NodePath = ^"Panel/VBox/NextDay"
const ROW_NAME_PATTERN: String = "Row_%s"
const META_ROW: StringName = &"report_row"
## 공연이 없는 날 숨기는 행(show.md R 표 "공연 없는 날" 열).
const HIDDEN_WITHOUT_SHOW: PackedStringArray = ["R3", "R5", "R11"]
## 라인업을 채울 수 없으면 숨기는 행(has_lineup_info). 불러오기 뒤에는 그날 lineup_set 이 재발행되지 않는다(SE-049) —
## 빈 값으로 채우면 등급 키가 샌다(SE-039-bug, SE-053 AC3).
const HIDDEN_WITHOUT_LINEUP: PackedStringArray = ["R2"]
const LIST_SEP: String = " · "
## show.md R3·R5: bp ÷ 100 = %.
const BP_PER_PERCENT: int = 100
const S_SETTLED: String = "settled"
const S_LINEUP: String = "lineup"
const S_SKIPPED: String = "skipped"
const S_ENDED: String = "ended"
const S_SUMMARY: String = "summary"
const S_REP: String = "rep_change"
const S_GROWN: String = "grown"
const S_BAILOUT: String = "bailout"
const S_BANKRUPT: String = "bankrupt"

var _phase: String = ""
## 그날 받은 이벤트 페이로드(복사본). 키 = 아래 S_* (time.day_started 에서 비운다, 파산은 유지).
var _state: Dictionary = {}
var _artist_config: Object
var _rep_total: int = 0
## 장르 id → 마지막으로 받은 장르 명성(R10 "이전 값 유지").
var _by_genre: Dictionary = {}
var _tier: int = 0
var _unlocked_tier: int = 0
## session.loaded 의 day(불러오기 직후 close 면 정산 이벤트가 재발행되지 않는다 — SE-049, R1·제목 폴백).
var _loaded_day: int = 0


func _event_handlers() -> Dictionary:
	return {
		"economy.day_settled": _store.bind(S_SETTLED),
		"artist.lineup_set": _store.bind(S_LINEUP),
		"show.skipped": _store.bind(S_SKIPPED),
		"show.ended": _store.bind(S_ENDED),
		"audience.day_summary": _store.bind(S_SUMMARY),
		"reputation.changed": on_reputation_changed,
		"artist.grown": _store.bind(S_GROWN),
		"reputation.tier_unlocked": on_tier_unlocked,
		"economy.bailout_offered": _store.bind(S_BAILOUT),
		"economy.bankrupt": _store.bind(S_BANKRUPT),
		"time.phase_changed": on_phase_changed,
		"time.day_started": on_day_started,
		"session.loaded": on_session_loaded,
	}


func _on_setup() -> void:
	_tier = _data.current_tier
	var next: Button = get_node(NEXT_PATH) as Button
	next.text = t("ui.report.next_day")
	if not next.pressed.is_connected(_on_next_pressed):
		next.pressed.connect(_on_next_pressed)
	var rows: Node = get_node(ROWS_PATH)
	for c: Node in rows.get_children():
		rows.remove_child(c)
		c.free()
	for id: String in _params.report_rows:
		var l: Label = Label.new()
		l.name = ROW_NAME_PATTERN % id
		l.set_meta(META_ROW, id)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rows.add_child(l)
	_refresh()


## 명성 초기값(새 게임·불러오기 직후 ReputationSystem.total — UiRoot 가 넣는다).
func set_reputation(total: int) -> void:
	_rep_total = total
	_refresh()


## R2 아티스트 이름 출처(ArtistConfig.artist(id).name — SE-033 인계 멤버). null 이면 id 표시.
func set_artist_config(config: Object) -> void:
	_artist_config = config
	_refresh()


# --- 조회 -------------------------------------------------------------------

func get_row_ids() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for c: Node in get_node(ROWS_PATH).get_children():
		if not c.is_queued_for_deletion():
			out.append(str(c.get_meta(META_ROW)))
	return out


func get_row_label(id: String) -> Label:
	return get_node(ROWS_PATH).get_node_or_null(ROW_NAME_PATTERN % id) as Label


func is_row_visible(id: String) -> bool:
	var l: Label = get_row_label(id)
	return l != null and l.visible


func get_row_text(id: String) -> String:
	var l: Label = get_row_label(id)
	return l.text if l != null else ""


func get_next_button() -> Button:
	return get_node(NEXT_PATH) as Button


func has_show() -> bool:
	return _st(S_ENDED).size() > 0


## R2 를 보일 수 있는가: 공연 건너뜀 사유가 있거나, 아티스트·장르·등급을 채울 수 있다.
func has_lineup_info() -> bool:
	return (not _st(S_SKIPPED).is_empty() and not has_show()) or not _r2_fields().is_empty()


## R2 의 {artist_id, genre, grade}. 출처 순서: artist.lineup_set → (불러오기 뒤 lineup_set 이 재발행되지 않으면)
## show.ended.artist_id + 읽기 멤버 artist(id)(등급은 artist.grown.grade 가 있으면 그것). 채울 수 없으면 {}.
func _r2_fields() -> Dictionary:
	var lineup: Dictionary = _st(S_LINEUP)
	if lineup.get("artist_id") != null and not str(lineup.get("grade", "")).is_empty():
		return {"artist_id": str(lineup["artist_id"]), "genre": str(lineup.get("genre", "")), "grade": str(lineup["grade"])}
	var aid: String = str(_st(S_ENDED).get("artist_id", ""))
	if aid.is_empty() or _artist_config == null:
		return {}
	var row: Dictionary = _artist_config.call("artist", aid) as Dictionary
	if row.is_empty():
		return {}
	var grown: Dictionary = _st(S_GROWN)
	var grade: String = str(grown.get("grade", row.get("grade", ""))) if str(grown.get("artist_id", "")) == aid else str(row.get("grade", ""))
	if grade.is_empty():
		return {}
	return {"artist_id": aid, "genre": str(row.get("genre", "")), "grade": grade}


func _st(key: String) -> Dictionary:
	return _state.get(key, {}) as Dictionary


# --- 이벤트 -----------------------------------------------------------------

func _store(p: Dictionary, key: String) -> void:
	_state[key] = p.duplicate(true)
	_refresh()


func on_tier_unlocked(p: Dictionary) -> void:
	_unlocked_tier = int(p.get("tier", 0))
	_tier = maxi(_tier, _unlocked_tier)
	_refresh()


## 해금된 티어(ReputationSystem.unlocked_tier — SE-035 인계 멤버). R12 진행도는 그다음 티어 기준.
func set_unlocked_tier(tier: int) -> void:
	_tier = maxi(_data.current_tier if _data != null else tier, tier)
	_refresh()


func on_reputation_changed(p: Dictionary) -> void:
	_state[S_REP] = p.duplicate(true)
	_rep_total = int(p.get("total", _rep_total))
	var bg: Variant = p.get("by_genre")
	if bg is Dictionary:
		_by_genre = (bg as Dictionary).duplicate()
	_refresh()


func on_phase_changed(p: Dictionary) -> void:
	_phase = str(p.get("to", _phase))
	_refresh()


## 같은 세계 안의 새 날: 그날 값만 비운다. 파산 기록은 유지(같은 세계에서는 파산 뒤 진행 없음).
func on_day_started(_p: Dictionary) -> void:
	var bankrupt: Dictionary = _st(S_BANKRUPT)
	_state.clear()
	if not bankrupt.is_empty():
		_state[S_BANKRUPT] = bankrupt
	_unlocked_tier = 0
	_refresh()


## 새 게임·불러오기 = 다른 세계(events.md SN6): 그날 상태를 전부 비운다(파산 기록·해금 티어·장르 명성 포함).
## 해금 티어는 데이터 시작 티어로 돌리고, reputation 읽기 멤버가 있으면 UiRoot 가 뒤이어 set_unlocked_tier 로 채운다.
func on_session_loaded(p: Dictionary) -> void:
	_state.clear()
	_unlocked_tier = 0
	_tier = _data.current_tier if _data != null else 0
	_by_genre.clear()
	_loaded_day = int(p.get("day", 0))
	_phase = str(p.get("phase", _phase))
	_refresh()


# --- 내부 -------------------------------------------------------------------

func _refresh() -> void:
	if not is_inside_tree() or _data == null:
		return
	visible = _phase == REPORT_PHASE
	(get_node(TITLE_PATH) as Label).text = t("ui.report.title", {"day": int(_st(S_SETTLED).get("day", _loaded_day))})
	get_next_button().disabled = not _st(S_BANKRUPT).is_empty()
	for id: String in get_row_ids():
		var l: Label = get_row_label(id)
		l.visible = (has_show() or not HIDDEN_WITHOUT_SHOW.has(id)) and (has_lineup_info() or not HIDDEN_WITHOUT_LINEUP.has(id))
		l.text = row_text(id)


## 행 하나의 표시 문자열(show.md R 표의 출처 필드).
func row_text(id: String) -> String:
	var s: Dictionary = _st(S_SETTLED)
	var lineup: Dictionary = _st(S_LINEUP)
	var skipped: Dictionary = _st(S_SKIPPED)
	var ended: Dictionary = _st(S_ENDED)
	var summary: Dictionary = _st(S_SUMMARY)
	var rep_change: Dictionary = _st(S_REP)
	var grown: Dictionary = _st(S_GROWN)
	var bailout: Dictionary = _st(S_BAILOUT)
	var bankrupt: Dictionary = _st(S_BANKRUPT)
	match id:
		"R1":
			return t("ui.report.r1", {"day": int(s.get("day", _loaded_day))})
		"R2":
			if not has_show() and not skipped.is_empty():
				return t("ui.report.r2_none", {"reason": t("ui.report.skip.%s" % str(skipped.get("reason", "")))})
			var f: Dictionary = _r2_fields()
			if f.is_empty():
				return ""
			return t("ui.report.r2", {
				"artist": _artist_name(str(f["artist_id"])), "genre": _data.genre_name(str(f["genre"])),
				"grade": t("ui.artist.grade.%s" % str(f["grade"])),
			})
		"R3":
			return t("ui.report.r3", {"grade": _data.grade_name(str(ended.get("grade", ""))),
				"satisfaction": int(ended.get("satisfaction_bp", 0)) / BP_PER_PERCENT})
		"R4":
			if has_show():
				return t("ui.report.r4", {"admissions": int(ended.get("admissions", 0)), "audience": int(ended.get("audience", 0)),
					"left_early": int(summary.get("left_early", 0))})
			return t("ui.report.r4_none", {"admissions": int(summary.get("admissions", 0))})
		"R5":
			var c: Dictionary = summary.get("avg_components", {}) as Dictionary
			return t("ui.report.r5", {"lineup": int(c.get("lineup_bp", 0)) / BP_PER_PERCENT, "sound": int(c.get("sound_bp", 0)) / BP_PER_PERCENT,
				"sight": int(c.get("sight_bp", 0)) / BP_PER_PERCENT, "value": int(c.get("value_bp", 0)) / BP_PER_PERCENT, "wait": int(c.get("wait_bp", 0)) / BP_PER_PERCENT,
				"crowd": int(summary.get("crowd_bp", 0)) / BP_PER_PERCENT})
		"R6":
			return t("ui.report.r6", {"ticket_revenue": int(s.get("ticket_revenue", 0)), "bar_revenue": int(s.get("bar_revenue", 0)),
				"revenue": int(s.get("revenue", 0))})
		"R7":
			return t("ui.report.r7", {"rent": int(s.get("rent", 0)), "upkeep": int(s.get("upkeep", 0)), "guarantee": int(s.get("guarantee", 0)),
				"bar_cost": int(s.get("bar_cost", 0)), "tax": int(s.get("tax", 0)), "loan_repayment": int(s.get("loan_repayment", 0))})
		"R8":
			return t("ui.report.r8", {"net": int(s.get("net", 0)), "cash": int(s.get("cash", 0))})
		"R9":
			if rep_change.is_empty() or int(rep_change.get("delta", 0)) == 0:
				return t("ui.report.r9_none", {"total": _rep_total})
			return t("ui.report.r9", {"delta": "%+d" % int(rep_change.get("delta", 0)), "total": _rep_total})
		"R10":
			var parts: PackedStringArray = PackedStringArray()
			for g: String in _data.mvp_genres:
				parts.append(t("ui.report.r10_item", {"genre": _data.genre_name(g), "value": int(_by_genre.get(g, 0))}))
			return t("ui.report.r10", {"list": LIST_SEP.join(parts)})
		"R11":
			var key: String = "ui.report.r11_promoted" if bool(grown.get("promoted", false)) else "ui.report.r11"
			return t(key, {"popularity_delta": "%+d" % int(grown.get("popularity_delta", 0)),
				"skill_delta": "%+d" % int(grown.get("skill_delta", 0))})
		"R12":
			return _unlock_text()
		"R13":
			if not bankrupt.is_empty():
				return t("ui.report.r13_bankrupt", {"cash": int(bankrupt.get("cash", 0))})
			if not bailout.is_empty():
				return t("ui.report.r13_bailout", {"amount": int(bailout.get("amount", 0)), "total_due": int(bailout.get("total_due", 0))})
			return t("ui.report.r13_none")
	return id


## R12: tier_unlocked 이 왔으면 해금 문구, 아니면 다음 티어 진행도(total ÷ unlock_reputation, cash ÷ unlock_cash, %).
func _unlock_text() -> String:
	if _unlocked_tier > 0 and _unlocked_tier == _tier and not _st(S_SETTLED).is_empty():
		return t("ui.report.r12_unlocked", {"tier": _unlocked_tier})
	var next: Dictionary = _data.next_tier_row(_tier)
	if next.is_empty():
		return t("ui.report.r12_max")
	var rep_need: int = int(next.get("unlock_reputation", 0))
	var cash_need: int = int(next.get("unlock_cash", 0))
	return t("ui.report.r12", {
		"tier": int(next.get("tier", 0)),
		"reputation": _rep_total, "reputation_need": rep_need, "reputation_pct": _pct(_rep_total, rep_need),
		"cash": int(_st(S_SETTLED).get("cash", 0)), "cash_need": cash_need, "cash_pct": _pct(int(_st(S_SETTLED).get("cash", 0)), cash_need),
	})


func _artist_name(id: String) -> String:
	if _artist_config == null or id.is_empty():
		return id
	return str((_artist_config.call("artist", id) as Dictionary).get("name", id))


## 진행도 % (0~100 으로 자름). need 가 0 이하면 100.
static func _pct(have: int, need: int) -> int:
	if need <= 0:
		return 100
	return clampi(have * 100 / need, 0, 100)


func _on_next_pressed() -> void:
	if _bus != null and _phase == REPORT_PHASE and _st(S_BANKRUPT).is_empty():
		_bus.publish("time.next_day_requested", {})
	next_day_pressed.emit()
