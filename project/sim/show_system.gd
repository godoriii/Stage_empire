class_name ShowSystem
extends RefCounted
## show 시스템 v0 (SE-035). 규칙: docs/gdd/show.md (#입력-계약 LN1~LN3, #상태, #공연-시작 ST0~ST3, #공연-끝 DS1~DS5·SE1~SE4·CL1,
## #이벤트, #결정성과-rng, #스냅샷 SS1~SS4). 이벤트: docs/gdd/events.md 의 show.* 3행.
##
## - 오늘 공연의 진행 상태와 등급 판정만 소유한다. 만족은 audience, 라인업은 artist, 무대 유무는 build 가 정하고 show 는
##   이벤트를 구독만 한다. 다른 시스템을 직접 호출하지 않는다. 생성자는 이벤트를 내지 않는다.
## - 난수를 쓰지 않는다(어떤 스트림도 뽑지 않음). 공식은 비교와 정수 곱뿐.
## - TickLoop 에는 register_system("show", update, snapshot, restore) 로 등록한다(update 는 아무것도 안 함).

# 발행
const EV_STARTED: String = "show.started"
const EV_SKIPPED: String = "show.skipped"
const EV_ENDED: String = "show.ended"
# 구독(#입력-계약 7개)
const EV_PHASE_CHANGED: String = "time.phase_changed"
const EV_DAY_STARTED: String = "time.day_started"
const EV_LINEUP_SET: String = "artist.lineup_set"
const EV_ADMISSIONS: String = "audience.admissions_decided"
const EV_COVERAGE: String = "build.coverage_changed"
const EV_PRICE: String = "economy.ticket_price_changed"
const EV_SUMMARY: String = "audience.day_summary"

const PHASE_DAY: String = "day"
const PHASE_EVENING: String = "evening"
const PHASE_SHOW: String = "show"
const PHASE_CLOSE: String = "close"

const STATUS_IDLE: String = "idle"
const STATUS_RUNNING: String = "running"
const STATUS_SKIPPED: String = "skipped"
const STATUS_ENDED: String = "ended"
const STATUSES: Array[String] = [STATUS_IDLE, STATUS_RUNNING, STATUS_SKIPPED, STATUS_ENDED]

const REASON_NO_LINEUP: String = "no_lineup"
const REASON_NO_STAGE: String = "no_stage"

## 새 게임 값(#상태).
const NEW_GAME_DAY: int = 1
const NO_DAY: int = 0
const MIN_TICKET_PRICE: int = 1

const SNAPSHOT_FIELDS: Array[String] = [
	"day", "phase", "ticket_price", "has_stage", "lineup", "lineup_day", "expected_admissions", "status",
]
const SNAPSHOT_INT_FIELDS: Array[String] = ["day", "ticket_price", "lineup_day", "expected_admissions"]
const LINEUP_FIELDS: Array[String] = ["artist_id", "genre"]
## DS1: 정수여야 하는 요약 키.
const SUMMARY_INT_FIELDS: Array[String] = ["day", "admissions", "audience", "avg_satisfaction_bp"]

var config: ShowConfig
var bus: EventBus

# 상태(읽기 전용으로 취급한다. 바꾸는 것은 ShowSystem 자신뿐). lineup 은 프로퍼티로 깊은 복사를 돌려준다.
var day: int = NEW_GAME_DAY
var phase: String = PHASE_DAY
var ticket_price: int = 0
var has_stage: bool = false
var lineup_day: int = NO_DAY
var expected_admissions: int = 0
var status: String = STATUS_IDLE
## 오늘 라인업 {artist_id, genre} 또는 null(깊은 복사본).
var lineup: Variant:
	get:
		return (_lineup as Dictionary).duplicate(true) if _lineup != null else null

var _lineup: Variant = null


## 새 게임 상태로 만들고 7개 이벤트를 구독한다. 이벤트를 내지 않는다.
func _init(p_config: ShowConfig, p_bus: EventBus) -> void:
	if p_config == null or p_bus == null:
		push_error("[ShowSystem] config 와 bus 가 필요하다")
		return
	config = p_config
	bus = p_bus
	ticket_price = config.ticket_price_default
	bus.subscribe(EV_PHASE_CHANGED, _on_phase_changed)
	bus.subscribe(EV_DAY_STARTED, _on_day_started)
	bus.subscribe(EV_LINEUP_SET, _on_lineup_set)
	bus.subscribe(EV_ADMISSIONS, _on_admissions_decided)
	bus.subscribe(EV_COVERAGE, _on_coverage_changed)
	bus.subscribe(EV_PRICE, _on_ticket_price_changed)
	bus.subscribe(EV_SUMMARY, _on_day_summary)


## TickLoop 단계 2. v0 는 공연 중 하는 일이 없다(#공연-중). 등록은 스냅샷 훅 때문에 필요하다.
func update(_ctx: Dictionary) -> void:
	pass


# --- 순수 함수 ----------------------------------------------------------------------

## SE1~SE4. summary = audience.day_summary 페이로드 모양. 형식 오류(DS1) 또는 ticket_price < 1 이면 {}.
## 입력을 바꾸지 않는다. 상태·이벤트·난수 없음. 테스트·봇이 쓴다.
static func compute_result(cfg: ShowConfig, summary: Dictionary, p_ticket_price: int) -> Dictionary:
	if cfg == null or summary_error(cfg, summary) != "" or p_ticket_price < MIN_TICKET_PRICE:
		return {}
	var sat: int = summary["avg_satisfaction_bp"]
	var adm: int = summary["admissions"]
	return {
		"satisfaction_bp": sat,                       # SE1 (SR1 그대로)
		"grade": cfg.grade_for(sat),                  # SE2 (SR3)
		"admissions": adm,
		"audience": summary["audience"],
		"revenue_hint": adm * p_ticket_price,         # SE3 (economy S1 과 같은 곱)
		"incidents": [],                              # SE4 (v0)
	}


## DS1 검사. 통과면 "", 아니면 위반 설명.
static func summary_error(cfg: ShowConfig, s: Dictionary) -> String:
	for key: String in SUMMARY_INT_FIELDS:
		if not (s.get(key) is int):
			return "DS1 %s 가 int 가 아니다: %s" % [key, s.get(key)]
	var sat: int = s["avg_satisfaction_bp"]
	if sat < 0 or sat > cfg.rate_scale:
		return "DS1 avg_satisfaction_bp %d 가 0~%d 밖이다" % [sat, cfg.rate_scale]
	var adm: int = s["admissions"]
	var aud: int = s["audience"]
	if aud < 0 or aud > adm:
		return "DS1 0 ≤ audience(%d) ≤ admissions(%d) 가 아니다" % [aud, adm]
	return ""


# --- 스냅샷 ------------------------------------------------------------------------

## #상태 표의 8개(깊은 복사, 기본형만). 상태 불변, 이벤트 없음.
func snapshot() -> Dictionary:
	return {
		"day": day,
		"phase": phase,
		"ticket_price": ticket_price,
		"has_stage": has_stage,
		"lineup": lineup,
		"lineup_day": lineup_day,
		"expected_admissions": expected_admissions,
		"status": status,
	}


## SS1~SS4 를 전부 검사한 뒤 적용한다. 첫 위반에서 push_error 1회, false, 상태 불변, 이벤트 0.
func restore(d: Dictionary) -> bool:
	var parsed: Variant = _parse_snapshot(d)
	if parsed is String:
		push_error("[ShowSystem] restore: " + String(parsed))
		return false
	day = parsed["day"]
	phase = parsed["phase"]
	ticket_price = parsed["ticket_price"]
	has_stage = parsed["has_stage"]
	_lineup = parsed["lineup"]
	lineup_day = parsed["lineup_day"]
	expected_admissions = parsed["expected_admissions"]
	status = parsed["status"]
	return true


# --- 입력 핸들러 -------------------------------------------------------------------

func _on_phase_changed(p: Dictionary) -> void:
	var to: Variant = p.get("to")
	var d: Variant = p.get("day")
	if not (to is String) or not SimConfig.PHASE_IDS.has(to) or not (d is int) or d < NEW_GAME_DAY:
		push_warning("[ShowSystem] time.phase_changed 페이로드 무시: %s" % [p])
		return
	phase = to
	day = d
	if phase == PHASE_SHOW:
		_start_show()
	elif phase == PHASE_CLOSE and status == STATUS_RUNNING:                                  # CL1
		status = STATUS_ENDED
		push_warning("[ShowSystem] CL1: %d일 공연이 audience.day_summary 없이 끝났다(show.ended 없음)" % day)


func _on_day_started(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	if not (d is int) or d < NEW_GAME_DAY:
		push_warning("[ShowSystem] time.day_started 페이로드 무시: %s" % [p])
		return
	day = d
	_lineup = null
	lineup_day = NO_DAY
	expected_admissions = 0
	status = STATUS_IDLE


## LN1~LN3.
func _on_lineup_set(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	if phase != PHASE_EVENING or not (d is int) or d != day:                                  # LN1
		push_warning("[ShowSystem] LN1: 저녁이 아니거나 다른 날의 라인업 무시: %s" % [p])
		return
	var aid: Variant = p.get("artist_id")
	var genre: Variant = p.get("genre")
	if aid == null:                                                                           # LN3 (섭외 없음)
		_lineup = null
		lineup_day = day
		return
	if not (aid is String) or not (genre is String):                                         # LN2
		push_error("[ShowSystem] LN2: artist.lineup_set 형식 오류(artist_id·genre): %s" % [p])
		return
	if not config.mvp_genres.has(genre):                                                      # LN2 확장(SS3 와 같은 집합)
		push_error("[ShowSystem] LN2: 라인업 장르 '%s' 가 mvp_genres %s 에 없다" % [genre, config.mvp_genres])
		return
	_lineup = {"artist_id": aid, "genre": genre}                                              # LN3
	lineup_day = day


func _on_admissions_decided(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	var adm: Variant = p.get("admissions")
	if not (d is int) or d != day or not (adm is int) or adm < 0:
		push_warning("[ShowSystem] audience.admissions_decided 페이로드 무시: %s" % [p])
		return
	expected_admissions = adm


func _on_coverage_changed(p: Dictionary) -> void:
	var hs: Variant = p.get("has_stage")
	if not (hs is bool):
		push_warning("[ShowSystem] build.coverage_changed.has_stage 가 bool 이 아니다(무시): %s" % [hs])
		return
	has_stage = hs


func _on_ticket_price_changed(p: Dictionary) -> void:
	var price: Variant = p.get("price")
	if not (price is int) or price < MIN_TICKET_PRICE:
		push_warning("[ShowSystem] economy.ticket_price_changed.price 무시: %s" % [price])
		return
	ticket_price = price


## ST0~ST3.
func _start_show() -> void:
	if status != STATUS_IDLE:                                                                 # ST0
		push_warning("[ShowSystem] ST0: %d일 공연 구간 진입이 두 번째다(status %s, 무시)" % [day, status])
		return
	if lineup_day != day or _lineup == null:                                                  # ST1
		status = STATUS_SKIPPED
		bus.publish(EV_SKIPPED, {"day": day, "reason": REASON_NO_LINEUP})
		return
	if not has_stage:                                                                         # ST2
		status = STATUS_SKIPPED
		bus.publish(EV_SKIPPED, {"day": day, "reason": REASON_NO_STAGE})
		return
	status = STATUS_RUNNING                                                                   # ST3
	bus.publish(EV_STARTED, {
		"day": day, "artist_id": _lineup["artist_id"], "genre": _lineup["genre"],
		"expected_admissions": expected_admissions,
	})


## DS1~DS5.
func _on_day_summary(p: Dictionary) -> void:
	var err: String = summary_error(config, p)
	if err != "":                                                                             # DS1
		push_error("[ShowSystem] audience.day_summary " + err)
		return
	if p["day"] != day:                                                                       # DS2
		push_warning("[ShowSystem] DS2: 다른 날(%d, 현재 %d)의 요약 무시" % [p["day"], day])
		return
	if status == STATUS_SKIPPED:                                                              # DS3
		return
	if status != STATUS_RUNNING:                                                              # DS4
		push_warning("[ShowSystem] DS4: status %s 에서 온 요약 무시(공연 시작 누락 또는 두 번째 요약)" % status)
		return
	if p.get("has_lineup") == false:
		push_warning("[ShowSystem] 요약 has_lineup false 인데 공연 중이다(라인업 계약 위반) — show 의 라인업으로 진행")
	var r: Dictionary = compute_result(config, p, ticket_price)                               # DS5
	status = STATUS_ENDED
	bus.publish(EV_ENDED, {
		"day": day, "artist_id": _lineup["artist_id"], "satisfaction_bp": r["satisfaction_bp"], "grade": r["grade"],
		"admissions": r["admissions"], "audience": r["audience"], "revenue_hint": r["revenue_hint"],
		"incidents": r["incidents"],
	})


# --- 스냅샷 검사 ------------------------------------------------------------------

## SS1~SS4. 성공이면 적용할 Dictionary(정규화한 깊은 복사), 실패면 오류 문자열.
func _parse_snapshot(d: Dictionary) -> Variant:
	for key: String in SNAPSHOT_FIELDS:                                                       # SS1
		if not d.has(key):
			return "SS1 필드 누락: %s" % key
	var ints: Dictionary = {}
	for key: String in SNAPSHOT_INT_FIELDS:
		var v: Variant = JsonUtil.as_int(d[key])
		if v == null:
			return "SS1 %s 가 정수가 아니다: %s" % [key, d[key]]
		ints[key] = v
	var ph: Variant = d["phase"]
	var st: Variant = d["status"]
	var lu: Variant = d["lineup"]
	if not (ph is String) or not (st is String):
		return "SS1 phase·status 가 문자열이 아니다: %s, %s" % [ph, st]
	if not (d["has_stage"] is bool):
		return "SS1 has_stage 가 bool 이 아니다: %s" % [d["has_stage"]]
	if not (lu == null or lu is Dictionary):
		return "SS1 lineup 이 객체 또는 null 이 아니다: %s" % [lu]
	if ints["day"] < NEW_GAME_DAY:                                                            # SS2
		return "SS2 day < %d: %d" % [NEW_GAME_DAY, ints["day"]]
	if not SimConfig.PHASE_IDS.has(ph):
		return "SS2 phase 가 구간 id 가 아니다: %s" % ph
	if ints["ticket_price"] < MIN_TICKET_PRICE:
		return "SS2 ticket_price < %d: %d" % [MIN_TICKET_PRICE, ints["ticket_price"]]
	if ints["expected_admissions"] < 0:
		return "SS2 expected_admissions < 0: %d" % ints["expected_admissions"]
	if ints["lineup_day"] < NO_DAY or ints["lineup_day"] > ints["day"]:
		return "SS2 lineup_day %d 가 0~day(%d) 밖이다" % [ints["lineup_day"], ints["day"]]
	var out_lineup: Variant = null
	if lu != null:                                                                            # SS3
		var ld: Dictionary = lu
		if ld.size() != LINEUP_FIELDS.size() or not (ld.get("artist_id") is String) or not (ld.get("genre") is String):
			return "SS3 lineup 은 정확히 {artist_id: String, genre: String} 이어야 한다: %s" % [ld]
		if not config.mvp_genres.has(ld["genre"]):
			return "SS3 lineup.genre '%s' 가 mvp_genres 에 없다" % ld["genre"]
		out_lineup = {"artist_id": ld["artist_id"], "genre": ld["genre"]}
	if not STATUSES.has(st):                                                                  # SS4
		return "SS4 status '%s' 가 %s 밖이다" % [st, STATUSES]
	if st == STATUS_RUNNING and (ph != PHASE_SHOW or out_lineup == null):
		return "SS4 running 인데 phase '%s' 가 show 가 아니거나 lineup 이 없다" % ph
	return {
		"day": ints["day"], "phase": ph, "ticket_price": ints["ticket_price"], "has_stage": d["has_stage"],
		"lineup": out_lineup, "lineup_day": ints["lineup_day"], "expected_admissions": ints["expected_admissions"],
		"status": st,
	}
