extends GutTest
## SE-036 AC2·AC3·AC-35c: 티어 1 루프 헤드리스 통합 리플레이. 봇 명령 열(테스트 고정 데이터):
## 1일차 낮 기준 배치(baseline_show) 설치 → 매일 낮 로컬 상위 밴드(thumbnail_soda) 섭외 → 하루 끝(close) → next_day.
## A = 연속 진행(매 close 오토세이브). 비교:
## - 같은 시드 2회: 새 세션으로 SAME_SEED_DAYS 일 진행 == A 의 같은 날 상태 해시·이벤트 열.
## - 저장/로드: A 의 SAVE_DAY 오토세이브를 새 GameSession 이 로드 → 로드 직후 해시 == 저장 시점 해시 → DAYS 까지 진행한
##   상태 해시·이벤트 열 == A. 로드 다음 날 저녁 입장 뽑기(audience.admissions_decided) == A (SE-034-bug 회귀).
## 실행 시간(AC7, 증가 ≤ 20 초) 때문에 기본은 DAYS 6 / SAVE_DAY 3. 환경 변수 SE036_LONG=1 이면 30 일 / 15 일차 저장
## (티켓 원안, 약 70 초). 30일 첫 실행값은 docs/tickets/SE-036.md 결과 절.

const DIR_A: String = "user://test_se036_replay_a"
const DIR_B: String = "user://test_se036_replay_b"
const SEED: int = 36
const ARTIST: String = "thumbnail_soda"
const LAYOUT: String = "baseline_show"
const LONG_ENV: String = "SE036_LONG"
const DAYS_SHORT: int = 6
const SAVE_DAY_SHORT: int = 3
const SAME_SEED_DAYS_SHORT: int = 2
const DAYS_LONG: int = 30
const SAVE_DAY_LONG: int = 15
## 상태 해시 대신 이벤트로 비교하지 않는 것: tick.advanced(카운터), audience.agent_moved(에이전트 상태는 해시에 있다).
const COMPARE_EVENTS: Array[String] = [
	"time.phase_changed", "time.day_started", "time.speed_changed", "build.placed", "build.coverage_changed",
	"artist.booked", "artist.booking_rejected", "artist.lineup_set", "artist.grown", "audience.admissions_decided",
	"audience.agent_left", "audience.day_summary", "economy.sales_reported", "show.started", "show.skipped", "show.ended",
	"reputation.changed", "reputation.tier_unlocked", "economy.cash_changed", "economy.day_settled",
	"economy.bailout_offered", "economy.bankrupt",
]
## AC2 방향 단언(30일 모드) = reputation.md "통합 기준 시나리오" IB1~IB3 (SE-057). 임계·범위는 리터럴이 아니라 데이터에서 읽는다:
## 해금 티어 = ReputationConfig.START_TIER + 1, 임계 = tiers.json(ReputationConfig.tier_threshold),
## 해금일 범위 = reputation.json checks 의 이 키(IB1).
const UNLOCK_DAY_RANGE_KEY: String = "tier2_reputation_day_range"
const KEY_UNLOCK_CASH: String = "unlock_cash"
const KEY_UNLOCK_REP: String = "unlock_reputation"

var _days: int = DAYS_SHORT
var _save_day: int = SAVE_DAY_SHORT
var _same_days: int = SAME_SEED_DAYS_SHORT
var _cfgs: Dictionary
## 연속 진행 A 의 결과(첫 테스트가 lazy 로 만든다 — push_error·warning 이 그 테스트에 잡히게).
var _a: Dictionary = {}


func before_all() -> void:
	_rm_dir(DIR_A)
	_rm_dir(DIR_B)
	_cfgs = GameSession.load_configs()
	if OS.get_environment(LONG_ENV) == "1":
		_days = DAYS_LONG
		_save_day = SAVE_DAY_LONG
		_same_days = DAYS_LONG


func after_all() -> void:
	_rm_dir(DIR_A)
	_rm_dir(DIR_B)


func _rm_dir(path: String) -> void:
	var d: DirAccess = DirAccess.open(path)
	if d == null:
		return
	for f: String in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(path)


static func _hash(v: Variant) -> String:
	return JSON.stringify(v, "", true)


func _new_session(dir: String) -> GameSession:
	var s: GameSession = GameSession.new()
	assert_true(s.new_game_from_configs(SEED, _cfgs))
	s.saves_dir = dir
	# 저장/로드 비교가 SAVE_DAY 오토세이브를 쓰므로 save.json autosave_keep(SE-057)과 무관하게 전부 보관한다.
	s.autosave_keep = GameSession.KEEP_UNLIMITED
	return s


## 봇 명령 열 하루분: (1일차면 기준 배치) → 섭외 → close 까지. 끝나면 close 경계.
func _play_day(s: GameSession) -> void:
	if s.loop.day == 1 and s.build.instances.is_empty():
		var bcfg: BuildConfig = _cfgs["build"]
		for p: Dictionary in bcfg.layout(LAYOUT)["placements"]:
			s.bus.publish("build.place_requested", {"furniture_id": p["furniture_id"], "cell": p["cell"], "rotation": p["rotation"]})
	s.bus.publish("artist.book_requested", {"artist_id": ARTIST})
	var c: SimConfig = _cfgs["sim"]
	s.advance(c.day_ticks)
	assert_eq(s.loop.phase, "close", "%d일 close" % s.loop.day)


func _next_day(s: GameSession) -> void:
	s.bus.publish("time.next_day_requested", {})
	s.advance(0)


## days 일 진행. 반환 {rec, hashes: [day 별 close 해시], rows: [[day, cash, rep], …], events_at: [day 별 이벤트 수]}.
func _run(s: GameSession, from_day: int, to_day: int) -> Dictionary:
	var rec: EventRecorder = EventRecorder.new(s.bus, COMPARE_EVENTS)
	var hashes: Dictionary = {}
	var rows: Array = []
	var events_at: Dictionary = {}
	for d: int in range(from_day, to_day + 1):
		if d != from_day or s.loop.phase == "close":
			_next_day(s)
		_play_day(s)
		hashes[d] = _hash(s.snapshot())
		rows.append([d, s.cash(), s.reputation_total()])
		events_at[d] = rec.events.size()
	return {"rec": rec, "hashes": hashes, "rows": rows, "events_at": events_at}


func _run_a() -> Dictionary:
	if _a.is_empty():
		var s: GameSession = _new_session(DIR_A)
		var t0: int = Time.get_ticks_usec()
		_a = _run(s, 1, _days)
		_a["us"] = Time.get_ticks_usec() - t0
		_a["session"] = s
		var w: int = 0
		for e: Variant in get_errors():
			if e.is_push_warning():
				w += 1
		_a["warnings"] = w
		gut.p("SE-036 리플레이 A %d일 %d µs" % [_days, _a["us"]])
		for r: Array in _a["rows"]:
			gut.p("SE-036 | %d | %d | %d |" % r)
	return _a


## 이벤트 열에서 from_day 다음 날 시작 이후 부분(A 의 events_at 경계 기준).
func _events_after(a: Dictionary, day: int) -> Array:
	var ev: Array = (a["rec"] as EventRecorder).events
	return ev.slice(int(a["events_at"][day]))


# --- AC2 · AC-35c ------------------------------------------------------------------

func test_a_runs_clean_and_counts() -> void:
	var a: Dictionary = _run_a()
	var rec: EventRecorder = a["rec"]
	assert_eq(a["warnings"], 0, "A 진행 중 push_warning 0")
	assert_eq(rec.count("build.placed"), (_cfgs["build"] as BuildConfig).layout(LAYOUT)["placements"].size(), "기준 배치 전부 설치")
	assert_eq(rec.count("artist.booked"), _days, "매일 섭외 성공")
	assert_eq(rec.count("artist.booking_rejected"), 0)
	assert_eq(rec.count("show.started"), _days, "show.started 수 == 공연일 수")
	assert_eq(rec.count("show.ended"), _days, "show.ended 수 == show.started 수")
	assert_eq(rec.count("reputation.changed"), _days, "reputation.changed 수 == 공연일 수")
	assert_eq(rec.count("show.skipped"), 0)
	assert_eq(rec.count("economy.day_settled"), _days)
	assert_eq(rec.count("economy.bailout_offered") + rec.count("economy.bankrupt"), 0, "구제·파산 없음")
	assert_eq(DirAccess.get_files_at(DIR_A).size(), _days, "매 close 오토세이브(보관 무제한 주입)")


func test_economy_reputation_direction() -> void:
	var a: Dictionary = _run_a()
	var rows: Array = a["rows"]
	for i: int in range(1, rows.size()):
		assert_gt(int(rows[i][1]), int(rows[i - 1][1]), "%d일 자금 증가(tier1_baseline 방향)" % rows[i][0])
		assert_gt(int(rows[i][2]), int(rows[i - 1][2]), "%d일 명성 증가" % rows[i][0])
	var unlocked: Array = (a["rec"] as EventRecorder).of("reputation.tier_unlocked")
	assert_lte(unlocked.size(), 1, "티어 해금 최대 1회")
	var rcfg: ReputationConfig = _cfgs["reputation"]
	var tier: int = ReputationConfig.START_TIER + 1
	var th: Dictionary = rcfg.tier_threshold(tier)
	var rng: Array = rcfg.checks.get(UNLOCK_DAY_RANGE_KEY, [])
	assert_eq(rng.size(), 2, "reputation.json checks.%s = [min, max]" % UNLOCK_DAY_RANGE_KEY)
	assert_true(th.has(KEY_UNLOCK_CASH) and th.has(KEY_UNLOCK_REP), "tiers.json tier %d 임계" % tier)
	if rng.size() != 2 or th.is_empty():
		return
	var min_day: int = int(rng[0])
	var max_day: int = int(rng[1])
	if _days >= max_day:
		assert_eq(unlocked.size(), 1, "IB1: %d일 안에 티어 %d 해금 1회" % [max_day, tier])
		if unlocked.size() != 1:
			return
		assert_eq(int(unlocked[0]["tier"]), tier, "IB1: 해금 티어")
		var ud: int = int(unlocked[0]["day"])
		assert_between(ud, min_day, max_day, "IB1: 해금일 %d~%d" % [min_day, max_day])
		assert_gte(int(rows[ud - 1][1]), int(th[KEY_UNLOCK_CASH]), "IB2: 해금일 자금 ≥ tiers.json unlock_cash")
		assert_gte(int(rows[ud - 1][2]), int(th[KEY_UNLOCK_REP]), "IB2: 해금일 명성 ≥ tiers.json unlock_reputation")


# --- 결정성 · 저장/로드 --------------------------------------------------------------

func test_same_seed_twice_identical() -> void:
	var a: Dictionary = _run_a()
	var s: GameSession = _new_session(DIR_B)
	var b: Dictionary = _run(s, 1, _same_days)
	for d: int in range(1, _same_days + 1):
		assert_eq(b["hashes"][d], a["hashes"][d], "%d일 close 해시 동일" % d)
	var a_ev: Array = (a["rec"] as EventRecorder).events.slice(0, int(a["events_at"][_same_days]))
	assert_eq(_hash((b["rec"] as EventRecorder).events), _hash(a_ev), "이벤트 열 동일")


func test_load_autosave_then_continue_matches_continuous() -> void:
	var a: Dictionary = _run_a()
	var path: String = DIR_A.path_join("autosave_day%d.sav" % _save_day)
	var s: GameSession = GameSession.new()
	assert_true(s.new_game_from_configs(SEED + 99, _cfgs), "다른 시드로 만든 새 세션")
	s.saves_dir = DIR_B
	assert_true(s.load_from(path), "%d일차 오토세이브 로드" % _save_day)
	assert_eq(_hash(s.snapshot()), a["hashes"][_save_day], "로드 직후 해시 == 저장 시점 해시")
	var b: Dictionary = _run(s, _save_day + 1, _days)
	for d: int in range(_save_day + 1, _days + 1):
		assert_eq(b["hashes"][d], a["hashes"][d], "%d일 close 해시 == 연속 진행" % d)
	var a_ev: Array = _events_after(a, _save_day)
	var b_ev: Array = (b["rec"] as EventRecorder).events
	assert_eq(_hash(b_ev), _hash(a_ev), "로드 뒤 이벤트 열 == 연속 진행")
	# SE-034-bug 회귀: 로드 다음 날 저녁 입장 뽑기가 연속 진행과 같다.
	var adm_a: Array = []
	for e: Array in a_ev:
		if e[0] == "audience.admissions_decided":
			adm_a.append(e[1])
	var adm_b: Array = (b["rec"] as EventRecorder).of("audience.admissions_decided")
	assert_gt(adm_b.size(), 0)
	assert_eq(_hash(adm_b[0]), _hash(adm_a[0]), "%d일 저녁 입장 결정(난수) == 연속 진행" % (_save_day + 1))
