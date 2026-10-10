extends GutTest
## SE-044 AC4 — JsonUtil (project/core/json_util.gd). docs/reviews/SE-032.md 발견 3(헬퍼 통합)·발견 5(|v| ≥ 2^63 가드).
## MapConfig·EconomyConfig·Economy·BuildSystem 이 이 함수를 쓰므로, 기존 동작(정수 접기·거절 목록)과 새 가드를 함께 고정한다.

const MAP_PATH: String = "res://data/maps/tier1_club.json"
const MISSING_PATH: String = "res://data/__no_such_file__.json"


func test_as_int_accepts_int_and_integral_float() -> void:
	assert_eq(JsonUtil.as_int(25), 25)
	assert_eq(typeof(JsonUtil.as_int(25.0)), TYPE_INT, "정수값 float → int")
	assert_eq(JsonUtil.as_int(25.0), 25)
	assert_eq(JsonUtil.as_int(-3.0), -3)
	assert_eq(JsonUtil.as_int(0.0), 0)
	assert_eq(JsonUtil.as_int(-0.0), 0)


func test_as_int_rejects_non_integers() -> void:
	for v: Variant in [1.5, -0.25, true, false, "3", null, [1], {}, INF, -INF, NAN]:
		assert_null(JsonUtil.as_int(v), "거절: %s" % [v])


## 발견 5: |float| ≥ 2^63 은 int 캐스트가 플랫폼 정의라 거절한다(손상 세이브의 paid 가 INT64_MAX 로 통과하지 않게).
func test_as_int_rejects_beyond_int64() -> void:
	assert_null(JsonUtil.as_int(1e19), "1e19 거절")
	assert_null(JsonUtil.as_int(-1e19), "-1e19 거절")
	assert_null(JsonUtil.as_int(JsonUtil.FLOAT_INT_LIMIT), "정확히 2^63 거절")
	assert_null(JsonUtil.as_int(-JsonUtil.FLOAT_INT_LIMIT), "정확히 -2^63 (float) 거절")
	assert_null(JsonUtil.as_int(1e300), "아주 큰 유한 값 거절")
	# 경계: 2^63 은 2 의 거듭제곱이라 float 로 정확하다. 그 바로 아래 double(2^63 − 1024)은 int 로 정확히 왕복한다.
	assert_eq(JsonUtil.FLOAT_INT_LIMIT, pow(2.0, 63.0), "상한 = 2^63")
	var below: float = JsonUtil.FLOAT_INT_LIMIT - 1024.0
	var n: Variant = JsonUtil.as_int(below)
	assert_eq(typeof(n), TYPE_INT, "2^63 아래 최대 double 은 받는다")
	assert_eq(float(n), below, "정확히 왕복")
	assert_eq(JsonUtil.as_int(-below), -n)
	# int 입력은 범위와 무관하게 그대로(이미 64비트 정수).
	assert_eq(JsonUtil.as_int(9223372036854775807), 9223372036854775807)


## 정상 왕복: JSON 문자열화 → 파싱(float) → as_int 가 원래 int 를 돌려준다(2^53 이하 정수).
func test_as_int_json_roundtrip() -> void:
	for v: int in [0, 1, -1, 7766, 2540, -100000, 9007199254740992]:
		var parsed: Variant = JSON.parse_string(JSON.stringify({"v": v}))["v"]
		assert_eq(JsonUtil.as_int(parsed), v, "왕복 %d" % v)
		assert_eq(typeof(JsonUtil.as_int(parsed)), TYPE_INT)


func test_as_int_pair() -> void:
	assert_eq(JsonUtil.as_int_pair([3.0, 4]), [3, 4])
	assert_eq(typeof(JsonUtil.as_int_pair([3.0, 4.0])[0]), TYPE_INT)
	for v: Variant in [[1], [1, 2, 3], [1.5, 2], [1, "2"], [1e19, 0], [0, -1e19], "1,2", null, {}]:
		assert_null(JsonUtil.as_int_pair(v), "거절: %s" % [v])


func test_int_deep_folds_nested_and_keeps_rest() -> void:
	var src: Variant = {"a": 1.0, "b": [2.0, [3.0, 1.5]], "c": {"d": -4.0, "e": "x", "f": true, "g": null}, "h": 1e19}
	var got: Variant = JsonUtil.int_deep(src)
	assert_eq(typeof(got["a"]), TYPE_INT)
	assert_eq(typeof(got["b"][1][0]), TYPE_INT)
	assert_eq(got["b"][1][1], 1.5, "정수 아닌 float 는 그대로")
	assert_eq(typeof(got["b"][1][1]), TYPE_FLOAT)
	assert_eq(got["c"]["d"], -4)
	assert_eq([got["c"]["e"], got["c"]["f"], got["c"]["g"]], ["x", true, null], "그 밖의 값 그대로")
	assert_eq(typeof(got["h"]), TYPE_FLOAT, "2^63 이상 float 는 접지 않는다")
	assert_eq(src["a"], 1.0, "입력 불변")
	assert_eq(typeof(src["a"]), TYPE_FLOAT)


func test_read_json_ok_and_failures() -> void:
	var d: Variant = JsonUtil.read_json(MAP_PATH)
	assert_true(d is Dictionary, "객체 JSON 을 읽는다")
	assert_true((d as Dictionary).has("reference_layouts"))
	assert_null(JsonUtil.read_json(MISSING_PATH, "T"), "파일 없음 → null")
	assert_push_error("[T] 파일 없음", "태그 접두어")
	assert_push_error_count(1)


## 통합 뒤 MapConfig·EconomyConfig 가 큰 값을 정수로 받지 않는다(RS·economy 양쪽 경로).
func test_callers_reject_beyond_int64() -> void:
	var cfg: BuildConfig = BuildConfig.load()
	var build: BuildSystem = BuildSystem.new(cfg, EventBus.new())
	var stage_cost: int = cfg.furniture("stage_small")["build_cost"]
	var good: Dictionary = {"instances": [{"entity_id": "f1", "furniture_id": "stage_small", "cell": [10, 20], "rotation": 0, "paid": stage_cost}], "next_entity": 2, "phase": "day"}
	assert_true(build.restore(JSON.parse_string(JSON.stringify(good))), "전제: 정상 스냅샷")
	var bad: Dictionary = good.duplicate(true)
	bad["instances"][0]["paid"] = 1e19
	assert_false(build.restore(bad), "RS1: paid 1e19 거절")
	assert_push_error("RS1", "타입 오류로 거절")
	var econ: Economy = Economy.new(EconomyConfig.load(), EventBus.new())
	var esnap: Dictionary = econ.snapshot()
	esnap["cash"] = -1e19
	assert_false(econ.restore(esnap), "economy: cash -1e19 거절")
	assert_push_error_count(2)
