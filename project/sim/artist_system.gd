class_name ArtistSystem
extends RefCounted
## artist 시스템 v0 (SE-033). 규칙: docs/gdd/artist.md (#상태, #섭외-규칙 K1~K5, #경제-핸드셰이크 H1~H5, #라인업 LU1~LU2,
## #성장 G1~G6·GR1~GR6, #명성과의-상호작용, #결정성과-rng, #스냅샷 RA1~RA6). 이벤트: docs/gdd/events.md 의 artist.* 행과
## economy 입력 계약.
##
## - 명단의 동적 상태와 오늘 라인업만 소유한다. 현금은 economy 가 바꾸고 artist 는 charge 제안만 한다(cash 를 읽지 않는다).
## - 입력은 생성자에서 구독한 이벤트뿐(명령 1종, economy.charge_resolved, time.* 2종, show.ended, reputation.changed).
##   생성자는 이벤트를 내지 않는다. 다른 시스템을 직접 호출하지 않는다.
## - 난수를 쓰지 않는다(artist 스트림 사용 0). 순회는 roster(데이터 행 순서)뿐이다.
## - TickLoop 에는 register_system("artist", update, snapshot, restore) 로 등록한다(update 는 H5 정리만).
## - check_book() 은 섭외 패널용 읽기 전용 쿼리(상태 불변, 이벤트 없음).

# 명령(구독)
const CMD_BOOK: String = "artist.book_requested"
# 상태 이벤트(발행)
const EV_BOOKED: String = "artist.booked"
const EV_REJECTED: String = "artist.booking_rejected"
const EV_LINEUP_SET: String = "artist.lineup_set"
const EV_GROWN: String = "artist.grown"
# economy 입력 계약(발행)·응답(구독)
const EV_CHARGE_PROPOSED: String = "economy.charge_proposed"
const EV_CHARGE_RESOLVED: String = "economy.charge_resolved"
# 그 밖의 입력(구독)
const EV_PHASE_CHANGED: String = "time.phase_changed"
const EV_DAY_STARTED: String = "time.day_started"
const EV_SHOW_ENDED: String = "show.ended"
const EV_REPUTATION_CHANGED: String = "reputation.changed"

# artist.booking_rejected reason 5종
const R_NOT_ALLOWED: String = "not_allowed"
const R_ALREADY_BOOKED: String = "already_booked"
const R_GRADE_LOCKED: String = "grade_locked"
const R_INSUFFICIENT_CASH: String = "insufficient_cash"
const R_UNKNOWN_ARTIST: String = "unknown_artist"
## H3: economy decline_reason → reason. 그 밖("bankrupt", "invalid", …)은 not_allowed.
const DECLINE_TO_REASON: Dictionary = {"insufficient_cash": R_INSUFFICIENT_CASH}
## H3: 이 decline_reason 은 설정 오류라 push_error 를 더한다.
const DECLINE_INVALID: String = "invalid"

const CHARGE_REASON_GUARANTEE: String = "guarantee"
## H1: request_id = 접두어 + day + 구분자 + artist_id.
const REQUEST_PREFIX: String = "artist:book:"
const REQUEST_SEP: String = ":"
## 새 게임 값(artist.md #상태).
const NEW_GAME_DAY: int = 1
const NEW_GAME_PHASE: String = "day"
## lineup_today == null 일 때의 booked_day, 새 게임 last_grown_day.
const NO_DAY: int = 0
## 이 구간 진입 시 artist.lineup_set (LU1).
const LINEUP_PHASE: String = "evening"
## 라인업이 없을 때 lineup_set 의 popularity·skill.
const EMPTY_STAT: int = 0

const SNAPSHOT_FIELDS: Array[String] = [
	"roster", "lineup_today", "booked_day", "last_grown_day", "reputation_total", "day", "phase",
]
const ENTRY_FIELDS: Array[String] = [
	"id", "grade", "popularity", "skill", "shows_played", "discovered_here", "relationship",
]
const ENTRY_INT_FIELDS: Array[String] = ["popularity", "skill", "shows_played", "relationship"]

var config: ArtistConfig
var bus: EventBus

# 상태 (읽기 전용으로 취급한다. 바꾸는 것은 ArtistSystem 자신뿐). roster 는 roster()/entry() 로 읽는다.
## 오늘 섭외가 확정된 아티스트 id 또는 null.
var lineup_today: Variant = null
var booked_day: int = NO_DAY
var last_grown_day: int = NO_DAY
var reputation_total: int = 0
var day: int = NEW_GAME_DAY
var phase: String = NEW_GAME_PHASE

var _roster: Array = []        # [{id, grade, popularity, skill, shows_played, discovered_here, relationship}], 데이터 행 순서
var _index: Dictionary = {}    # id -> roster 번호 (config 행 순서와 같다)
## null 또는 {request_id, artist_id, grade, amount} (H1~H5). 같은 경계 안에서 비워진다. 스냅샷 제외.
var _pending: Variant = null


## 새 게임 상태로 만들고 구독한다. 이벤트를 내지 않는다.
func _init(p_config: ArtistConfig, p_bus: EventBus) -> void:
	if p_config == null or p_bus == null:
		push_error("[ArtistSystem] config 와 bus 가 필요하다")
		return
	config = p_config
	bus = p_bus
	for id: String in config.artist_ids():
		var row: Dictionary = config.artist(id)
		_index[id] = _roster.size()
		_roster.append({
			"id": id, "grade": row["grade"], "popularity": row["popularity"], "skill": row["skill"],
			"shows_played": ArtistConfig.NEW_GAME_SHOWS_PLAYED, "discovered_here": false,
			"relationship": ArtistConfig.NEW_GAME_RELATIONSHIP,
		})
	bus.subscribe(CMD_BOOK, _on_book_requested)
	bus.subscribe(EV_CHARGE_RESOLVED, _on_charge_resolved)
	bus.subscribe(EV_PHASE_CHANGED, _on_phase_changed)
	bus.subscribe(EV_DAY_STARTED, _on_day_started)
	bus.subscribe(EV_SHOW_ENDED, _on_show_ended)
	bus.subscribe(EV_REPUTATION_CHANGED, _on_reputation_changed)


## TickLoop 단계 2. H5: 응답 없는 개런티 제안 정리.
func update(_ctx: Dictionary) -> void:
	_flush_unresolved()


# --- 읽기 전용 조회 ---------------------------------------------------------------

## roster 의 깊은 복사본(데이터 행 순서).
func roster() -> Array:
	return _roster.duplicate(true)


## roster 원소의 깊은 복사본. 없으면 {}.
func entry(id: String) -> Dictionary:
	if not _index.has(id):
		return {}
	return (_roster[_index[id]] as Dictionary).duplicate(true)


## 개런티 승인 대기 중인 섭외가 있는가(경계 상태에서는 항상 false).
func has_pending() -> bool:
	return _pending != null


## K1~K4 판정만(자금 제외). 통과면 "", 아니면 reason. 상태 불변, 이벤트 없음(섭외 패널용).
func check_book(artist_id: Variant) -> String:
	if not (artist_id is String) or not _index.has(artist_id):                                 # K1
		return R_UNKNOWN_ARTIST
	if not config.booking_phases.has(phase):                                                   # K2
		return R_NOT_ALLOWED
	if lineup_today != null:                                                                   # K3
		return R_ALREADY_BOOKED
	var e: Dictionary = _roster[_index[artist_id]]                                             # K4
	if reputation_total < config.unlock_reputation(e["grade"]) and not e["discovered_here"]:
		return R_GRADE_LOCKED
	return ""


# --- 스냅샷 ------------------------------------------------------------------------

## {roster, lineup_today, booked_day, last_grown_day, reputation_total, day, phase} 깊은 복사(기본형만). pending 제외.
## 상태 불변, 이벤트 없음(SH1·SH4).
func snapshot() -> Dictionary:
	return {
		"roster": _roster.duplicate(true),
		"lineup_today": lineup_today,
		"booked_day": booked_day,
		"last_grown_day": last_grown_day,
		"reputation_total": reputation_total,
		"day": day,
		"phase": phase,
	}


## RA1~RA6 을 전부 검사한 뒤 적용한다. 첫 위반에서 push_error 1회, false, 상태 불변, 이벤트 0(SH3·SH4).
## roster 는 데이터 행 순서로 다시 담는다. 성공하면 pending = null.
func restore(d: Dictionary) -> bool:
	var parsed: Variant = _parse_snapshot(d)
	if parsed is String:
		push_error("[ArtistSystem] restore: " + String(parsed))
		return false
	_roster = parsed["roster"]
	lineup_today = parsed["lineup_today"]
	booked_day = parsed["booked_day"]
	last_grown_day = parsed["last_grown_day"]
	reputation_total = parsed["reputation_total"]
	day = parsed["day"]
	phase = parsed["phase"]
	_pending = null
	return true


# --- 명령·입력 핸들러 -------------------------------------------------------------

## K1~K5 → H1.
func _on_book_requested(p: Dictionary) -> void:
	_flush_unresolved()
	var raw: Variant = p.get("artist_id")
	var reason: String = check_book(raw)
	if reason != "":
		_reject(raw, reason)
		return
	var id: String = raw                                                                        # K5 → H1
	var grade: String = _roster[_index[id]]["grade"]
	var amount: int = config.guarantee(grade)
	var rid: String = REQUEST_PREFIX + str(day) + REQUEST_SEP + id
	_pending = {"request_id": rid, "artist_id": id, "grade": grade, "amount": amount}
	bus.publish(EV_CHARGE_PROPOSED, {"request_id": rid, "reason": CHARGE_REASON_GUARANTEE, "amount": amount})


## H2~H4.
func _on_charge_resolved(p: Dictionary) -> void:
	if _pending == null:                                                                       # H4
		return
	var pend: Dictionary = _pending
	if p.get("reason") != CHARGE_REASON_GUARANTEE or p.get("request_id") != pend["request_id"]:
		return
	_pending = null
	if p.get("approved") != true:                                                              # H3
		var decline: Variant = p.get("decline_reason")
		if decline == DECLINE_INVALID:
			push_error("[ArtistSystem] H3: economy 가 개런티 %s 를 invalid 로 거절했다(설정 오류)" % pend["request_id"])
		_reject(pend["artist_id"], DECLINE_TO_REASON.get(decline, R_NOT_ALLOWED))
		return
	var amount: Variant = ArtistConfig.as_int(p.get("amount"))                                 # H2 (상태 먼저)
	var paid: int = amount if amount != null else int(pend["amount"])
	var id: String = pend["artist_id"]
	lineup_today = id
	booked_day = day
	_roster[_index[id]]["discovered_here"] = true
	bus.publish(EV_BOOKED, {"day": day, "artist_id": id, "grade": pend["grade"], "guarantee": paid})


## 구간·날짜 추적. evening 진입이면 lineup_set 1회(LU1).
func _on_phase_changed(p: Dictionary) -> void:
	var to: Variant = p.get("to")
	var d: Variant = p.get("day")
	if not (to is String) or not SimConfig.PHASE_IDS.has(to) or not (d is int) or d < NEW_GAME_DAY:
		push_warning("[ArtistSystem] time.phase_changed 페이로드 무시: %s" % [p])
		return
	phase = to
	day = d
	if phase == LINEUP_PHASE:
		_publish_lineup()


## LU2: 라인업 초기화. 이벤트 없음.
func _on_day_started(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	if not (d is int) or d < NEW_GAME_DAY:
		push_warning("[ArtistSystem] time.day_started 페이로드 무시: %s" % [p])
		return
	day = d
	lineup_today = null
	booked_day = NO_DAY


## K4 입력: 종합 명성 캐시.
func _on_reputation_changed(p: Dictionary) -> void:
	var total: Variant = p.get("total")
	if not (total is int) or total < 0:
		push_warning("[ArtistSystem] reputation.changed 페이로드 무시: %s" % [p])
		return
	reputation_total = total


## G1~G6.
func _on_show_ended(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	var sg: Variant = p.get("grade")
	var aid: Variant = p.get("artist_id")
	if not (d is int) or not (sg is String) or not (aid == null or aid is String):             # G1
		push_warning("[ArtistSystem] show.ended 페이로드 무시: %s" % [p])
		return
	if aid == null:                                                                            # G2
		return
	if aid != lineup_today or d != booked_day:                                                 # G3
		push_warning("[ArtistSystem] show.ended 가 라인업(%s, %d일)과 다르다(계약 위반): %s" % [lineup_today, booked_day, p])
		return
	if d == last_grown_day:                                                                    # G4
		return
	if not config.show_grades.has(sg):                                                         # G5
		push_error("[ArtistSystem] show.ended grade '%s' 가 show_grades %s 에 없다" % [sg, config.show_grades])
		return
	var i: int = _index[aid]                                                                   # G6
	var g: Dictionary = config.grow(_roster[i], sg)
	var e: Dictionary = {}
	for key: String in ENTRY_FIELDS:
		e[key] = g[key]
	_roster[i] = e
	last_grown_day = d
	bus.publish(EV_GROWN, {
		"day": d, "artist_id": aid, "grade": e["grade"], "popularity": e["popularity"], "skill": e["skill"],
		"popularity_delta": g["popularity_delta"], "skill_delta": g["skill_delta"],
		"shows_played": e["shows_played"], "promoted": g["promoted"],
	})


# --- 발행 ----------------------------------------------------------------------

## H5. 명령 처리 시작 시에도 부른다(응답 없는 제안을 덮어쓰지 않게).
func _flush_unresolved() -> void:
	if _pending == null:
		return
	var pend: Dictionary = _pending
	_pending = null
	push_warning("[ArtistSystem] H5: economy 가 %s 에 응답하지 않았다(계약 위반). 섭외를 거절한다" % pend["request_id"])
	_reject(pend["artist_id"], R_NOT_ALLOWED)


func _reject(artist_id: Variant, reason: String) -> void:
	bus.publish(EV_REJECTED, {"day": day, "artist_id": artist_id, "reason": reason})


func _publish_lineup() -> void:
	var payload: Dictionary = {
		"day": day, "artist_id": null, "genre": null, "grade": null, "popularity": EMPTY_STAT, "skill": EMPTY_STAT,
	}
	if lineup_today != null:
		var e: Dictionary = _roster[_index[lineup_today]]
		payload["artist_id"] = lineup_today
		payload["genre"] = config.genre_of(lineup_today)
		payload["grade"] = e["grade"]
		payload["popularity"] = e["popularity"]
		payload["skill"] = e["skill"]
	bus.publish(EV_LINEUP_SET, payload)


# --- 스냅샷 검사 ------------------------------------------------------------------

## RA1~RA6. 성공이면 적용할 Dictionary(정규화한 깊은 복사), 실패면 오류 문자열.
func _parse_snapshot(d: Dictionary) -> Variant:
	for key: String in SNAPSHOT_FIELDS:                                                         # RA1
		if not d.has(key):
			return "RA1 필드 누락: %s" % key
	var raw_roster: Variant = d["roster"]
	if not (raw_roster is Array):
		return "RA1 roster 가 배열이 아니다"
	var lu: Variant = d["lineup_today"]
	if lu is StringName:
		lu = String(lu)
	if not (lu == null or lu is String):
		return "RA1 lineup_today 가 문자열 또는 null 이 아니다: %s" % [lu]
	var ints: Dictionary = {}
	for key: String in ["booked_day", "last_grown_day", "reputation_total", "day"]:
		var v: Variant = ArtistConfig.as_int(d[key])
		if v == null:
			return "RA1 %s 가 정수가 아니다: %s" % [key, d[key]]
		ints[key] = v
	var ph: Variant = d["phase"]
	if not (ph is String or ph is StringName):
		return "RA1 phase 가 문자열이 아니다: %s" % [ph]
	if ints["day"] < NEW_GAME_DAY:                                                             # RA2
		return "RA2 day < %d: %d" % [NEW_GAME_DAY, ints["day"]]
	if not SimConfig.PHASE_IDS.has(String(ph)):
		return "RA2 phase 가 구간 id 가 아니다: %s" % [ph]
	if ints["reputation_total"] < 0:
		return "RA2 reputation_total < 0: %d" % ints["reputation_total"]
	var by_id: Dictionary = {}
	for e: Variant in raw_roster:                                                              # RA3·RA4
		var parsed: Variant = _parse_entry(e)
		if parsed is String:
			return parsed
		var id: String = parsed["id"]
		if by_id.has(id):
			return "RA3 roster id '%s' 가 두 번 있다" % id
		by_id[id] = parsed
	if by_id.size() != _index.size():
		return "RA3 roster 원소 수 %d 가 명단 %d 와 다르다" % [by_id.size(), _index.size()]
	var bd: int = ints["booked_day"]                                                          # RA5
	if lu == null:
		if bd != NO_DAY:
			return "RA5 lineup_today 가 null 인데 booked_day 가 %d 이다" % bd
	else:
		if not by_id.has(lu):
			return "RA5 lineup_today '%s' 가 roster 에 없다" % lu
		if bd != ints["day"]:
			return "RA5 booked_day %d 가 day %d 와 다르다" % [bd, ints["day"]]
	var lg: int = ints["last_grown_day"]                                                      # RA6
	if lg < NO_DAY or lg > ints["day"]:
		return "RA6 last_grown_day %d 가 0~day(%d) 밖이다" % [lg, ints["day"]]
	var ordered: Array = []
	for id: String in config.artist_ids():
		ordered.append(by_id[id])
	return {
		"roster": ordered, "lineup_today": lu, "booked_day": bd, "last_grown_day": lg,
		"reputation_total": ints["reputation_total"], "day": ints["day"], "phase": String(ph),
	}


## roster 원소 하나(RA3·RA4). 성공이면 정규화한 Dictionary, 실패면 오류 문자열.
func _parse_entry(e: Variant) -> Variant:
	if not (e is Dictionary):
		return "RA3 roster 원소가 객체가 아니다"
	for key: String in ENTRY_FIELDS:
		if not (e as Dictionary).has(key):
			return "RA3 roster 원소 필드 누락: %s" % key
	var id: Variant = e["id"]
	var grade: Variant = e["grade"]
	if not (id is String) or not (grade is String) or not (e["discovered_here"] is bool):
		return "RA3 roster 원소 타입 오류(id·grade 문자열, discovered_here bool): %s" % [e]
	var out: Dictionary = {"id": id, "grade": grade, "discovered_here": e["discovered_here"]}
	for key: String in ENTRY_INT_FIELDS:
		var v: Variant = ArtistConfig.as_int(e[key])
		if v == null:
			return "RA3 '%s' 의 %s 가 정수가 아니다: %s" % [id, key, e[key]]
		out[key] = v
	if not _index.has(id):
		return "RA3 모르는 아티스트 id '%s'" % id
	if not config.grade_ids().has(grade):                                                     # RA4
		return "RA4 '%s' 의 grade '%s' 가 grades 에 없다" % [id, grade]
	if out["popularity"] < 0 or out["popularity"] > config.stat_max:
		return "RA4 '%s' 의 popularity %d 가 0~%d 밖이다" % [id, out["popularity"], config.stat_max]
	if out["skill"] < 0 or out["skill"] > config.stat_max:
		return "RA4 '%s' 의 skill %d 가 0~%d 밖이다" % [id, out["skill"], config.stat_max]
	if out["shows_played"] < 0:
		return "RA4 '%s' 의 shows_played 가 음수다: %d" % [id, out["shows_played"]]
	if out["relationship"] < config.relationship_min or out["relationship"] > config.relationship_max:
		return "RA4 '%s' 의 relationship %d 가 %d~%d 밖이다" % [id, out["relationship"], config.relationship_min, config.relationship_max]
	return out
