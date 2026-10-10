extends GutTest
## SE-042 AC4 · bot_metrics.md BM3·BM5(짧은 구간)·BM6: 봇 러너(BotPlay) 단위 테스트.
## - 정책 파일 4종이 읽히고 키가 전부 있다.
## - 정책 1·시드 1·3일: 2회 결과가 바이트 동일, 지표 키 전부 존재(결과 파일 형식).
## - 고정점: 시드 36 의 frugal / v0_replay 1~3일 close 가 SE-036 표(3,713 / 4,652 / 5,573, 명성 18 / 37 / 56)와 같고,
##   frugal 은 7일까지(11,053 / 158) 같다. 30일 전체(해금 22일, 명성 500 21일, 41,294 / 756)는 러너 실행의 calibration 으로 확인한다.
## - 부분 결과 합치기(--merge)는 한 번에 돌린 결과와 바이트 동일.
## - 분위수는 최근접 순위, 무작위 정책은 같은 시드에서 결정적.

const POLICY_IDS: Array[String] = ["frugal", "aggressive", "random", "v0_replay"]
const POLICY_KEYS: Array[String] = [
	"version", "id", "spec", "opening_layout", "artist_pick", "artist_id", "book_reserve", "price_mode", "price_fixed", "price_min",
	"price_max", "price_step", "price_low_fill_bp", "build_queue", "build_min_cash_after", "build_max_per_day", "random_build_bp",
	"random_accept_bp", "rng_salt", "bailout_accept",
]
const RUN_KEYS: Array[String] = [
	"seed", "bankrupt_day", "bailouts_taken", "final_cash", "final_rep", "metrics", "grade_days", "rejections", "shows",
	"distinct_artists", "price_changes", "pool",
]
const METRIC_KEYS: Array[String] = [
	"cash_swing_d3", "first_profit_day", "payback_day", "rep500_day", "tier2_day", "first_prompt_day", "prompts_d10",
]
const GRADE_DAY_KEYS: Array[String] = ["disaster", "poor", "ok", "good", "rave", "skipped"]
const TOP_KEYS: Array[String] = ["ticket", "spec", "spec_version", "days", "seeds", "policies", "by_policy", "cross_policy", "calibration"]
const BLOCK_KEYS: Array[String] = ["policy_file_sha1", "summary", "pooled", "runs"]
const POOLED_KEYS: Array[String] = [
	"grade_share_bp", "bankrupt_rate_bp", "tier2_rate_bp", "soldout", "fail_vs_skip", "zero_admission_shows", "rejections",
]
const SUMMARY_KEYS: Array[String] = ["n", "q1", "median", "q3", "reached_bp"]
## 시간·경로처럼 실행마다 달라지는 값이 결과에 들어가면 안 된다(BM6).
const FORBIDDEN_KEY_PARTS: Array[String] = ["elapsed", "time", "date", "path", "wall", "msec", "usec", "host"]
## SE-036 표 1~7일 (자금, 명성). docs/tickets/SE-036.md "30일 첫 실행값".
const SE036_ROWS: Array = [[3713, 18], [4652, 37], [5573, 56], [6673, 80], [8149, 106], [9669, 132], [11053, 158]]
const SEED_36: int = 36

var _cfgs: Dictionary
var _data: Dictionary
var _cache: Dictionary = {}


func before_all() -> void:
	_cfgs = GameSession.load_configs()
	_data = BotPlay.load_data()


func _run(policy_id: String, game_seed: int, days: int, trace: bool = false) -> Dictionary:
	var key: String = "%s/%d/%d/%s" % [policy_id, game_seed, days, trace]
	if not _cache.has(key):
		_cache[key] = BotPlay.play_game(BotPlay.load_policy(policy_id), game_seed, days, _cfgs, _data, trace)
	return _cache[key]


func _part(policy_id: String, first: int, count: int, days: int) -> Dictionary:
	var runs: Array = []
	for sd: int in range(first, first + count):
		runs.append(BotPlay.play_game(BotPlay.load_policy(policy_id), sd, days, _cfgs, _data))
	return {"policy": policy_id, "days": days, "first_seed": first, "count": count,
		"policy_file_sha1": BotPlay.policy_sha1(policy_id), "runs": runs}


func _keys_of(d: Dictionary) -> Array:
	return d.keys()


func _assert_has_keys(d: Dictionary, keys: Array, what: String) -> void:
	for k: String in keys:
		assert_true(d.has(k), "%s: 키 '%s' 있음" % [what, k])


func _walk_keys(v: Variant, out: Array) -> void:
	if v is Dictionary:
		for k: Variant in v:
			out.append(String(k))
			_walk_keys(v[k], out)
	elif v is Array:
		for e: Variant in v:
			_walk_keys(e, out)


# --- 정책·목표 파일 ------------------------------------------------------------------------

func test_policy_files_load_with_all_keys() -> void:
	for id: String in POLICY_IDS:
		var p: Dictionary = BotPlay.load_policy(id)
		assert_false(p.is_empty(), "%s 정책 파일 읽힘" % id)
		assert_eq(p.get("id"), id, "id == 파일 이름")
		assert_eq(p.get("version"), 1)
		_assert_has_keys(p, POLICY_KEYS, id)
		assert_eq(p.keys().size(), POLICY_KEYS.size(), "%s: 문서에 없는 키 없음" % id)
		assert_eq(BotPlay.policy_sha1(id).length(), 40, "sha1 40자")
	var q: Array = BotPlay.load_policy("aggressive")["build_queue"]
	assert_eq(q.size(), 9, "공격형 건설 큐 9개")
	assert_eq(BotPlay.load_policy("v0_replay")["artist_id"], "thumbnail_soda")
	assert_eq(BotPlay.load_policy("random")["rng_salt"], 7)


func test_targets_file_shape() -> void:
	var t: Dictionary = BotPlay.read_json(BotPlay.TARGETS_FILE)
	assert_eq(t["version"], 1)
	assert_gt((t["targets"] as Array).size(), 25)
	for e: Dictionary in t["targets"]:
		_assert_has_keys(e, ["metric", "stat", "policy", "min", "max"], "targets 항목")
	assert_eq(t["calibration"]["final_cash"], 41294)
	assert_eq(t["calibration"]["final_rep"], 756)


# --- 결정성 · 키 (AC4, BM3, BM6) ---------------------------------------------------------------

func test_frugal_seed1_3days_deterministic_and_keys() -> void:
	var a: Dictionary = _run("frugal", 1, 3)
	var b: Dictionary = BotPlay.play_game(BotPlay.load_policy("frugal"), 1, 3, _cfgs, _data)
	assert_eq(BotPlay.to_json(a), BotPlay.to_json(b), "같은 정책·시드·일수 2회 결과 바이트 동일")
	_assert_has_keys(a, RUN_KEYS, "run")
	_assert_has_keys(a["metrics"], METRIC_KEYS, "metrics")
	_assert_has_keys(a["grade_days"], GRADE_DAY_KEYS, "grade_days")
	_assert_has_keys(a["rejections"], ["booking", "build"], "rejections")
	assert_eq(a["seed"], 1)
	assert_eq(a["shows"], 3, "3일 모두 공연")
	assert_null(a["bankrupt_day"])
	var total: int = 0
	for g: String in GRADE_DAY_KEYS:
		total += int(a["grade_days"][g])
	assert_eq(total, 3, "등급별 일수 합 == 진행일")
	assert_eq((a["rejections"]["booking"] as Dictionary).size(), 0, "절약형 섭외 거절 0")
	assert_eq((a["rejections"]["build"] as Dictionary).size(), 0, "절약형 건설 거절 0")


func test_random_policy_deterministic_and_isolated() -> void:
	var a: Dictionary = _run("random", 3, 2)
	var b: Dictionary = BotPlay.play_game(BotPlay.load_policy("random"), 3, 2, _cfgs, _data)
	assert_eq(BotPlay.to_json(a), BotPlay.to_json(b), "무작위 정책도 같은 시드 2회 바이트 동일(봇 RNG 시드 고정)")
	var c: Dictionary = BotPlay.play_game(BotPlay.load_policy("random"), 4, 2, _cfgs, _data)
	assert_ne(BotPlay.to_json(a), BotPlay.to_json(c), "다른 시드는 다른 결과")


# --- 고정점 (BM5 짧은 구간) -----------------------------------------------------------------------

func test_fixed_point_frugal_seed36_matches_se036_table() -> void:
	var r: Dictionary = _run("frugal", SEED_36, 7, true)
	var tr: Array = r["trace"]
	assert_eq(tr.size(), 7)
	for i: int in 7:
		assert_eq(tr[i][1], SE036_ROWS[i][0], "%d일 close 자금" % (i + 1))
		assert_eq(tr[i][2], SE036_ROWS[i][1], "%d일 close 명성" % (i + 1))
	assert_eq(r["metrics"]["cash_swing_d3"], 3113, "M1 손계산(bot_metrics.md 목표 범위 근거) 3,113")
	assert_eq(r["metrics"]["first_profit_day"], 1)
	assert_eq(r["metrics"]["payback_day"], 3)


func test_fixed_point_v0_replay_seed36_matches_se036_table() -> void:
	var r: Dictionary = _run("v0_replay", SEED_36, 3, true)
	var tr: Array = r["trace"]
	for i: int in 3:
		assert_eq(tr[i][1], SE036_ROWS[i][0], "v0_replay %d일 close 자금" % (i + 1))
		assert_eq(tr[i][2], SE036_ROWS[i][1], "v0_replay %d일 close 명성" % (i + 1))
	assert_eq((r["rejections"]["booking"] as Dictionary).size() + (r["rejections"]["build"] as Dictionary).size(), 0)


func test_aggressive_queue_places_without_rule_rejections() -> void:
	var r: Dictionary = _run("aggressive", 1, 2)
	for reason: String in r["rejections"]["build"]:
		assert_eq(reason, "insufficient_cash", "BM4: 건설 큐 거절은 자금 부족뿐(좌표·규칙 거절 없음)")
	assert_eq((r["rejections"]["booking"] as Dictionary).size(), 0, "봇 예측 bookable 과 K4 일치")


# --- 합치기 · 통계 (BM6) ----------------------------------------------------------------------

func test_merge_of_split_parts_equals_single_run() -> void:
	var targets: Dictionary = BotPlay.read_json(BotPlay.TARGETS_FILE)
	var whole: Dictionary = BotPlay.merge_parts([_part("frugal", 1, 2, 2)], targets)
	# 나눠서(역순으로 들어와도) 합치면 같다.
	var split: Dictionary = BotPlay.merge_parts([_part("frugal", 2, 1, 2), _part("frugal", 1, 1, 2)], targets)
	assert_false(whole.is_empty())
	assert_eq(BotPlay.to_json(split), BotPlay.to_json(whole), "합친 결과 == 한 번에 돌린 결과(바이트 동일)")
	_assert_has_keys(whole, TOP_KEYS, "결과 최상위")
	assert_eq(whole["policies"], ["frugal"])
	assert_eq(whole["seeds"], {"first": 1, "count": 2})
	var block: Dictionary = whole["by_policy"]["frugal"]
	_assert_has_keys(block, BLOCK_KEYS, "정책 블록")
	_assert_has_keys(block["pooled"], POOLED_KEYS, "pooled")
	for k: String in METRIC_KEYS:
		_assert_has_keys(block["summary"][k], SUMMARY_KEYS, "summary.%s" % k)
	assert_eq(block["summary"]["cash_swing_d3"]["n"], 2)
	assert_null(whole["calibration"], "v0_replay 부분 결과가 없으면 calibration null")
	var keys: Array = []
	_walk_keys(whole, keys)
	for k: String in keys:
		for bad: String in FORBIDDEN_KEY_PARTS:
			assert_false(k.to_lower().contains(bad), "결과에 비결정 값 키 없음: %s" % k)
	assert_true(JSON.parse_string(BotPlay.to_json(whole)) is Dictionary, "결과가 JSON 으로 다시 읽힌다")


func test_merge_rejects_gaps_and_mixed_days() -> void:
	var targets: Dictionary = BotPlay.read_json(BotPlay.TARGETS_FILE)
	var fake: Dictionary = _part("frugal", 1, 1, 1)
	var gap: Dictionary = fake.duplicate(true)
	for r: Dictionary in gap["runs"]:
		r["seed"] = 3
	var parts_gap: Array = [fake, gap]
	assert_true(BotPlay.merge_parts(parts_gap, targets).is_empty(), "시드 1, 3 은 이어지지 않는다")
	var other_days: Dictionary = fake.duplicate(true)
	other_days["days"] = 2
	assert_true(BotPlay.merge_parts([fake, other_days], targets).is_empty(), "일수가 다르면 합치지 않는다")
	assert_push_error_count(2, "거절마다 push_error 1회")


func test_percentile_nearest_rank() -> void:
	var v: Array = []
	for i: int in range(100, 0, -1):
		v.append(i)
	assert_eq(BotPlay.percentile(v, 25), 25)
	assert_eq(BotPlay.percentile(v, 50), 50)
	assert_eq(BotPlay.percentile(v, 75), 75)
	assert_eq(BotPlay.percentile([5, 1, 3], 50), 3, "n=3 중앙값 = v[⌈1.5⌉−1] = v[1]")
	assert_eq(BotPlay.percentile([1, 2, 3, null], 75), 3, "n=4 Q3 = v[2]")
	assert_null(BotPlay.percentile([1, 2, null, null], 75), "null 은 맨 뒤(+∞): Q3 = v[2] = null")
	assert_eq(BotPlay.percentile([null, 2, 1, null], 25), 1, "Q1 = v[0]")
	var s: Dictionary = BotPlay.summary_of([1, null, 3, 5])
	assert_eq(s["reached_bp"], 7500)
	assert_eq(s["n"], 4)
	assert_eq(BotPlay.fdiv(-7, 2), -4, "내림 나눗셈")
	assert_null(BotPlay.fdiv(5, 0))
