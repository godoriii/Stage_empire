extends GutTest
## SE-045 QA — AC2 보강. 개발자 테스트(test_tick.gd::test_rejects_float_beyond_int64)는 2^63 가드를 지워도 통과한다:
## 가드 없이 int(1e19) 는 x86 에서 INT64_MIN 이 되고, 그 뒤의 범위 검사(seed < 0, ticks_per_second <= 0)가 어차피 거절한다.
## 그래서 "어느 검사가 거절했는가"(push_error 문구)와 소스 구조로 가드 경유를 고정한다.
## 변이: core 에 가드 없는 private _as_int 를 되살리거나 JsonUtil.as_int 를 int() 로 바꾸면 이 파일이 실패해야 한다.

const CORE_DIR: String = "res://core"
const BEYOND_INT64: float = 1e19


func test_core_has_no_private_as_int() -> void:
	var dir: DirAccess = DirAccess.open(CORE_DIR)
	assert_not_null(dir, "core 디렉터리를 연다")
	var re: RegEx = RegEx.new()
	re.compile("func\\s+_as_int\\b")
	var scanned: int = 0
	for f: String in dir.get_files():
		if not f.ends_with(".gd"):
			continue
		scanned += 1
		var src: String = FileAccess.get_file_as_string(CORE_DIR + "/" + f)
		assert_null(re.search(src), "%s: private _as_int 없음(JsonUtil.as_int 사용)" % f)
	assert_gt(scanned, 3, "core/*.gd 를 실제로 훑었다")


func test_tickloop_restore_rejects_1e19_as_not_integer() -> void:
	var cfg: SimConfig = SimConfig.load()
	var good: Dictionary = TickLoop.new(cfg, 1).snapshot()
	var target: TickLoop = TickLoop.new(cfg, 9)
	target.advance(10)
	var before: String = JSON.stringify(target.snapshot(), "", true)
	for key: String in ["seed", "tick", "day", "tick_in_phase", "speed"]:
		for v: float in [BEYOND_INT64, -BEYOND_INT64]:
			var s: Dictionary = good.duplicate(true)
			s[key] = v
			assert_false(target.restore(s), "%s=%s → false" % [key, v])
			# 가드를 지우면 숫자 필드 검사를 통과해 seed 범위/I1/I3/I4 같은 다른 문구로 거절된다.
			assert_push_error("숫자 필드")
			assert_eq(JSON.stringify(target.snapshot(), "", true), before, "%s=%s 상태 불변" % [key, v])


func test_simconfig_rejects_1e19_default_speed_as_not_integer() -> void:
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SimConfig.DEFAULT_PATH))
	assert_not_null(SimConfig.from_dict(raw.duplicate(true)), "전제: 원본 사본은 통과")
	for v: float in [BEYOND_INT64, -BEYOND_INT64]:
		var d: Dictionary = raw.duplicate(true)
		(d["phases"] as Array)[0]["default_speed"] = v
		assert_null(SimConfig.from_dict(d), "default_speed %s → null" % v)
		# 가드를 지워도 null 은 그대로다: int(±1e19) 는 INT64_MIN 이 되고 C4(default_speed ∈ speeds, sim_config.gd 103행)가
		# 거절한다. 가드의 몫은 "누가 거절했는가"(정수 아님 vs C4)이므로 아래에서 push_error 문구를 단언한다(SE-052 AC-45b).
		assert_push_error("default_speed 는 정수여야 한다")
