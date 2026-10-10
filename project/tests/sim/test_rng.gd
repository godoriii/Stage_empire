extends GutTest
## SE-001 AC9 — SeededRng. docs/gdd/tick.md#결정성과-rng.

var _cfg: SimConfig


func before_all() -> void:
	_cfg = SimConfig.load()


func _rng(seed_value: int) -> SeededRng:
	return SeededRng.new(seed_value, _cfg.rng_streams)


func test_same_seed_same_sequence() -> void:
	var a: RandomNumberGenerator = _rng(42).stream("audience")
	var b: RandomNumberGenerator = _rng(42).stream("audience")
	var diff: int = 0
	for i: int in 10000:
		if a.randi() != b.randi():
			diff += 1
	assert_eq(diff, 0, "시드 42 두 인스턴스 10,000회 일치")


func test_different_seed_differs() -> void:
	var a: RandomNumberGenerator = _rng(42).stream("audience")
	var b: RandomNumberGenerator = _rng(43).stream("audience")
	var diff: int = 0
	for i: int in 100:
		if a.randi() != b.randi():
			diff += 1
	assert_gt(diff, 0, "첫 100개 중 하나 이상 다름")


func test_streams_independent() -> void:
	var r1: SeededRng = _rng(42)
	var r2: SeededRng = _rng(42)
	for i: int in 1000:
		r1.stream("audience").randi()
	assert_eq(r1.stream("events").randi(), r2.stream("events").randi(), "audience 소비와 무관하게 events 다음 값 동일")
	# rng_streams 에 스트림을 하나 더해도 기존 스트림 열은 같다.
	var more: Array[String] = _cfg.rng_streams.duplicate()
	more.insert(0, "staff")
	var r3: SeededRng = SeededRng.new(42, more)
	var r4: SeededRng = _rng(42)
	var same: bool = true
	for n: String in _cfg.rng_streams:
		for i: int in 50:
			if r3.stream(n).randi() != r4.stream(n).randi():
				same = false
	assert_true(same, "스트림 추가 후에도 기존 스트림 열 동일")
	assert_not_null(r3.stream("staff"))


func test_state_roundtrip() -> void:
	var a: SeededRng = _rng(42)
	for n: String in _cfg.rng_streams:
		for i: int in 37:
			a.stream(n).randi()
	var st: Dictionary = a.get_state()
	assert_eq(st.keys().size(), _cfg.rng_streams.size(), "rng_streams 전부")
	for n: String in st:
		assert_typeof(st[n], TYPE_STRING, "상태 값은 10진 문자열")
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(st))
	var b: SeededRng = _rng(7)
	assert_true(b.set_state(parsed))
	var diff: int = 0
	for n: String in _cfg.rng_streams:
		for i: int in 100:
			if a.stream(n).randi() != b.stream(n).randi():
				diff += 1
	assert_eq(diff, 0, "JSON 왕복 후 이어지는 100개 일치")
	assert_false(b.set_state({"audience": 12}), "문자열 아닌 상태 거부")
	assert_push_error_count(1)


func test_derived_seed_vectors() -> void:
	var vectors: Array = [
		[42, "audience", 2851880905],
		[42, "artist", 3021210036],
		[42, "events", 564648782],
		[42, "economy", 2295552225],
		[42, "world", 2250541393],
		[0, "audience", 1688486501],
		[0, "events", 468373146],
		[2147483647, "audience", 1028055295],
	]
	for v: Array in vectors:
		assert_eq(SeededRng.derive_seed(v[0], v[1]), v[2], "%d:%s" % [v[0], v[1]])
	assert_eq(_rng(42).stream("audience").seed, 2851880905, "스트림 RNG 의 seed = 파생 시드")
	assert_null(_rng(42).stream("nope"), "모르는 스트림 → null")
	assert_push_error("모르는 스트림")


## SE-034-bug: assign 은 객체·스트림 객체를 유지하고 다른 SeededRng 의 시드·상태를 옮긴다.
func test_assign_keeps_objects_and_copies_state() -> void:
	var a: SeededRng = _rng(42)
	for n: String in _cfg.rng_streams:
		for i: int in 13:
			a.stream(n).randi()
	var b: SeededRng = _rng(7)
	var stream_obj: Object = b.stream("audience")
	assert_true(b.assign(a), "같은 스트림 목록 → true")
	assert_true(b.stream("audience") == stream_obj, "스트림 객체 유지")
	assert_eq(b.master_seed, 42, "마스터 시드 이전")
	assert_eq(b.get_state(), a.get_state(), "상태 이전")
	var diff: int = 0
	for n: String in _cfg.rng_streams:
		for i: int in 50:
			if a.stream(n).randi() != b.stream(n).randi():
				diff += 1
	assert_eq(diff, 0, "이어지는 열 일치")
	var other: Array[String] = ["audience"]
	var c: SeededRng = SeededRng.new(1, other)
	var before: Dictionary = b.get_state()
	assert_false(b.assign(c), "스트림 목록이 다르면 false")
	assert_push_error_count(1)
	assert_eq([b.get_state(), b.master_seed], [before, 42], "실패 시 상태 불변")
