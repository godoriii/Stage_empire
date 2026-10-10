class_name ReputationSystem
extends RefCounted
## reputation 시스템 v0 (SE-035). 규칙: docs/gdd/reputation.md (#입력-계약, #상태, #명성-갱신 RG0~RG7,
## #장르-집중과-확산 FC1~FC4, #티어-해금 TU1~TU4, #결정성과-rng, #스냅샷 RR1~RR5). 이벤트: events.md 의 reputation.* 2행.
##
## - 명성 값(종합·장르별)과 해금 진행만 소유한다. 현금은 economy.day_settled.cash 를 읽기만 한다.
## - 입력은 생성자에서 구독한 4개 이벤트뿐. 생성자는 이벤트를 내지 않는다. 다른 시스템을 직접 호출하지 않는다.
## - 난수를 쓰지 않는다. 공식은 정수 곱·내림 나눗셈·clamp·max 뿐, 순회는 mvp_genres 순서 하나.
## - TickLoop 에는 register_system("reputation", update, snapshot, restore) 로 등록한다(update 는 아무것도 안 함).

# 발행
const EV_CHANGED: String = "reputation.changed"
const EV_TIER_UNLOCKED: String = "reputation.tier_unlocked"
# 구독
const EV_SHOW_STARTED: String = "show.started"
const EV_SHOW_ENDED: String = "show.ended"
const EV_DAY_SETTLED: String = "economy.day_settled"
const EV_DAY_STARTED: String = "time.day_started"

const FOCUS_NONE: String = "none"
const FOCUS_IDENTITY: String = "identity"
const FOCUS_BREADTH: String = "breadth"
## compute_delta 의 eff_bp: FC1 미충족(또는 실패 등급이라 판정하지 않음).
const EFF_NOT_JUDGED: int = -1

const NO_DAY: int = 0
const SNAPSHOT_FIELDS: Array[String] = [
	"total", "by_genre", "show_day", "show_genre", "last_applied_day", "unlocked_tier",
]

var config: ReputationConfig
var bus: EventBus

# 상태(읽기 전용으로 취급한다. 바꾸는 것은 ReputationSystem 자신뿐). by_genre 는 by_genre() 로 읽는다.
var total: int = 0
var show_day: int = NO_DAY
## 마지막 show.started.genre 또는 null.
var show_genre: Variant = null
var last_applied_day: int = NO_DAY
var unlocked_tier: int = ReputationConfig.START_TIER

var _by_genre: Dictionary = {}   # mvp_genres 순서로 만든다


## 새 게임 상태로 만들고 4개 이벤트를 구독한다. 이벤트를 내지 않는다.
func _init(p_config: ReputationConfig, p_bus: EventBus) -> void:
	if p_config == null or p_bus == null:
		push_error("[ReputationSystem] config 와 bus 가 필요하다")
		return
	config = p_config
	bus = p_bus
	for g: String in config.genre_ids():
		_by_genre[g] = 0
	bus.subscribe(EV_SHOW_STARTED, _on_show_started)
	bus.subscribe(EV_SHOW_ENDED, _on_show_ended)
	bus.subscribe(EV_DAY_SETTLED, _on_day_settled)
	bus.subscribe(EV_DAY_STARTED, _on_day_started)


## TickLoop 단계 2. 아무것도 하지 않는다(등록은 스냅샷 훅 때문에 필요하다).
func update(_ctx: Dictionary) -> void:
	pass


## 장르별 명성(복사본, mvp_genres 순서).
func by_genre() -> Dictionary:
	return _by_genre.duplicate()


# --- 순수 함수 ----------------------------------------------------------------------

## RG2~RG5. by_genre 에 없는 장르는 0 으로 본다. 입력 불변, 상태·이벤트·난수 없음.
## 결과 {delta, base, factor_bp, focus, eff_bp, bonus_bp}. 모르는 등급·장르, 음수 입장이면 {}.
static func compute_delta(cfg: ReputationConfig, p_by_genre: Dictionary, genre: String, grade: String,
		admissions: int) -> Dictionary:
	if cfg == null or not cfg.show_grades.has(grade) or not cfg.genre_ids().has(genre) or admissions < 0:
		return {}
	var b: int = cfg.base(grade)                                                              # RG2
	var f: int = cfg.admission_factor_bp(admissions)                                          # RG3
	var focus: String = FOCUS_NONE
	var eff: int = EFF_NOT_JUDGED
	var bonus: int = 0
	if b > 0:                                                                                 # RG4
		var genres: Array[String] = cfg.genre_ids()
		var s: int = 0
		for h: String in genres:
			s += int(p_by_genre.get(h, 0))
		if s >= cfg.min_genre_sum:                                                            # FC1
			var w: int = 0
			for h: String in genres:
				w += int(p_by_genre.get(h, 0)) * cfg.affinity_bp(genre, h)
			eff = w / s                                                                       # FC2
			if eff >= cfg.identity_share_bp:                                                  # FC3
				focus = FOCUS_IDENTITY
				bonus = cfg.identity_bonus_bp
			else:                                                                             # FC4
				var broad: bool = true
				for h: String in genres:
					if int(p_by_genre.get(h, 0)) * cfg.rate_scale < cfg.breadth_min_share_bp * s:
						broad = false
				if broad:
					focus = FOCUS_BREADTH
					bonus = cfg.breadth_bonus_bp
	var delta: int                                                                            # RG5
	if b > 0:
		delta = (b * f / cfg.rate_scale) * (cfg.rate_scale + bonus) / cfg.rate_scale
	else:
		delta = -((-b) * f / cfg.rate_scale)
	return {"delta": delta, "base": b, "factor_bp": f, "focus": focus, "eff_bp": eff, "bonus_bp": bonus}


# --- 스냅샷 ------------------------------------------------------------------------

## {total, by_genre, show_day, show_genre, last_applied_day, unlocked_tier}(깊은 복사, 기본형만, by_genre 는 mvp_genres 순서).
func snapshot() -> Dictionary:
	return {
		"total": total,
		"by_genre": _ordered(_by_genre),
		"show_day": show_day,
		"show_genre": show_genre,
		"last_applied_day": last_applied_day,
		"unlocked_tier": unlocked_tier,
	}


## RR1~RR5 를 전부 검사한 뒤 적용한다. 첫 위반에서 push_error 1회, false, 상태 불변, 이벤트 0.
func restore(d: Dictionary) -> bool:
	var parsed: Variant = _parse_snapshot(d)
	if parsed is String:
		push_error("[ReputationSystem] restore: " + String(parsed))
		return false
	total = parsed["total"]
	_by_genre = parsed["by_genre"]
	show_day = parsed["show_day"]
	show_genre = parsed["show_genre"]
	last_applied_day = parsed["last_applied_day"]
	unlocked_tier = parsed["unlocked_tier"]
	return true


# --- 입력 핸들러 -------------------------------------------------------------------

func _on_show_started(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	var g: Variant = p.get("genre")
	if not (d is int) or not (g is String) or not config.genre_ids().has(g):
		push_error("[ReputationSystem] show.started 형식 오류(day int, genre ∈ mvp_genres): %s" % [p])
		return
	show_day = d
	show_genre = g


func _on_day_started(p: Dictionary) -> void:
	if not (p.get("day") is int):
		push_warning("[ReputationSystem] time.day_started 페이로드 무시: %s" % [p])
		return
	show_day = NO_DAY
	show_genre = null


## RG1~RG7.
func _on_show_ended(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	var adm: Variant = p.get("admissions")
	var grade: Variant = p.get("grade")
	if not (d is int) or not (adm is int) or adm < 0 or not (grade is String):                 # RG1
		push_error("[ReputationSystem] RG1 show.ended 형식 오류: %s" % [p])
		return
	if not config.show_grades.has(grade):                                                     # RG1a
		push_error("[ReputationSystem] RG1a show.ended grade '%s' 가 show_grades %s 에 없다" % [grade, config.show_grades])
		return
	if d != show_day or show_genre == null:                                                   # RG1b
		push_warning("[ReputationSystem] RG1b %d일 show.ended 가 show.started(%d일) 없이 왔다(무시)" % [d, show_day])
		return
	if d == last_applied_day:                                                                 # RG1c
		return
	var g: String = show_genre
	var r: Dictionary = compute_delta(config, _by_genre, g, grade, adm)                       # RG2~RG5
	var before: int = total
	total = maxi(0, total + int(r["delta"]))                                                  # RG6
	_by_genre[g] = maxi(0, int(_by_genre[g]) + int(r["delta"]))
	last_applied_day = d                                                                      # RG7
	bus.publish(EV_CHANGED, {"day": d, "delta": total - before, "total": total, "by_genre": _ordered(_by_genre)})


## TU1~TU4.
func _on_day_settled(p: Dictionary) -> void:
	var d: Variant = p.get("day")
	var cash: Variant = p.get("cash")
	if not (d is int) or not (cash is int):                                                   # TU1
		push_error("[ReputationSystem] TU1 economy.day_settled 의 day·cash 가 int 가 아니다: %s, %s" % [d, cash])
		return
	var next: int = unlocked_tier + 1
	var th: Dictionary = config.tier_threshold(next)
	if next > config.max_tier or th.is_empty():                                               # TU2
		return
	if cash >= int(th["unlock_cash"]) and total >= int(th["unlock_reputation"]):              # TU3
		unlocked_tier = next
		bus.publish(EV_TIER_UNLOCKED, {"tier": next, "day": d})


# --- 내부 ------------------------------------------------------------------------

## mvp_genres 순서로 다시 담은 복사본(Dictionary 순회 순서에 기대지 않는다).
func _ordered(src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for g: String in config.genre_ids():
		out[g] = int(src.get(g, 0))
	return out


## RR1~RR5. 성공이면 적용할 Dictionary, 실패면 오류 문자열.
func _parse_snapshot(d: Dictionary) -> Variant:
	for key: String in SNAPSHOT_FIELDS:                                                       # RR1
		if not d.has(key):
			return "RR1 필드 누락: %s" % key
	var ints: Dictionary = {}
	for key: String in ["total", "show_day", "last_applied_day", "unlocked_tier"]:
		var v: Variant = JsonUtil.as_int(d[key])
		if v == null:
			return "RR1 %s 가 정수가 아니다: %s" % [key, d[key]]
		ints[key] = v
	var bg: Variant = d["by_genre"]
	if not (bg is Dictionary):
		return "RR1 by_genre 가 객체가 아니다: %s" % [bg]
	var sg: Variant = d["show_genre"]
	if not (sg == null or sg is String):
		return "RR1 show_genre 가 문자열 또는 null 이 아니다: %s" % [sg]
	for key: String in ["total", "show_day", "last_applied_day"]:                              # RR2
		if ints[key] < 0:
			return "RR2 %s < 0: %d" % [key, ints[key]]
	var genres: Array[String] = config.genre_ids()                                            # RR3
	if (bg as Dictionary).size() != genres.size():
		return "RR3 by_genre 키 집합 %s 가 mvp_genres %s 와 다르다" % [(bg as Dictionary).keys(), genres]
	var out_bg: Dictionary = {}
	for g: String in genres:
		if not (bg as Dictionary).has(g):
			return "RR3 by_genre 에 '%s' 가 없다" % g
		var x: Variant = JsonUtil.as_int(bg[g])
		if x == null or x < 0:
			return "RR3 by_genre.%s 가 0 이상 정수가 아니다: %s" % [g, bg[g]]
		out_bg[g] = x
	if sg != null and not genres.has(sg):                                                     # RR4
		return "RR4 show_genre '%s' 가 mvp_genres 에 없다" % sg
	if ints["show_day"] == NO_DAY and sg != null:
		return "RR4 show_day 가 0 인데 show_genre 가 '%s' 이다" % sg
	if ints["unlocked_tier"] < ReputationConfig.START_TIER or ints["unlocked_tier"] > config.max_tier:   # RR5
		return "RR5 unlocked_tier %d 가 %d~%d 밖이다" % [ints["unlocked_tier"], ReputationConfig.START_TIER, config.max_tier]
	return {
		"total": ints["total"], "by_genre": out_bg, "show_day": ints["show_day"], "show_genre": sg,
		"last_applied_day": ints["last_applied_day"], "unlocked_tier": ints["unlocked_tier"],
	}
