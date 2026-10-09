class_name SimConfig
extends RefCounted
## sim.json 로더 (SE-001). 틱 수·구간·배속 허용표·RNG 스트림·시스템 순서의 단일 출처.
## 규칙: docs/gdd/tick.md#틱 (교차 검증 C1~C6). 모든 필드는 읽기 전용으로 취급한다.

const DEFAULT_PATH: String = "res://data/sim/sim.json"
## C1: 구간 id 순서. 스펙이 이름과 순서를 고정한다(tick.md#세션-구간).
const PHASE_IDS: Array[String] = ["day", "evening", "show", "close"]
const MODE_FORCE: String = "force"
const MODE_KEEP_IF_ALLOWED: String = "keep_if_allowed"
const ENTER_MODES: Array[String] = [MODE_FORCE, MODE_KEEP_IF_ALLOWED]

var ticks_per_second: int = 0
## 각 원소: {id: String, ticks: int, pausable: bool, speeds: Array(int), default_speed: int, enter_speed_mode: String}
var phases: Array[Dictionary] = []
var day_ticks: int = 0
var max_ticks_per_step: int = 0
var snapshot_schema_version: int = 0
var rng_streams: Array[String] = []
var system_order: Array[String] = []

var _index: Dictionary = {}       # id -> int
var _starts: Array[int] = []      # 구간별 phase_start (누적합)


## res://data/sim/sim.json 을 읽어 검증한다. 실패 시 push_error 후 null.
static func load(path: String = DEFAULT_PATH) -> SimConfig:
	if not FileAccess.file_exists(path):
		push_error("[SimConfig] 파일 없음: %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("[SimConfig] JSON 객체가 아님: %s" % path)
		return null
	return from_dict(parsed)


## 메모리 상 Dictionary(JSON 파싱 결과와 같은 모양)에서 만든다. 테스트의 변형 사본 검증용.
static func from_dict(d: Dictionary) -> SimConfig:
	var cfg: SimConfig = SimConfig.new()

	var tps: Variant = _as_int(d.get("ticks_per_second"))
	if tps == null or tps <= 0:
		return _fail("ticks_per_second 는 양의 정수여야 한다")
	cfg.ticks_per_second = tps

	var mtps: Variant = _as_int(d.get("max_ticks_per_step"))
	if mtps == null or mtps < 1:
		return _fail("max_ticks_per_step 는 1 이상 정수여야 한다")
	cfg.max_ticks_per_step = mtps

	var ssv: Variant = _as_int(d.get("snapshot_schema_version"))
	if ssv == null or ssv < 1:
		return _fail("snapshot_schema_version 은 1 이상 정수여야 한다")
	cfg.snapshot_schema_version = ssv

	var streams: Variant = _string_list(d.get("rng_streams"))
	if streams == null:
		return _fail("rng_streams 는 비어 있지 않은 문자열 배열이어야 한다")
	if _has_duplicates(streams):
		return _fail("C6 rng_streams 에 중복이 있다")
	cfg.rng_streams.assign(streams)

	var order: Variant = _string_list(d.get("system_order"))
	if order == null:
		return _fail("system_order 는 비어 있지 않은 문자열 배열이어야 한다")
	if _has_duplicates(order):
		return _fail("C6 system_order 에 중복이 있다")
	cfg.system_order.assign(order)

	var raw_phases: Variant = d.get("phases")
	if not (raw_phases is Array):
		return _fail("phases 는 배열이어야 한다")
	for raw: Variant in raw_phases:
		var ph: Variant = _parse_phase(raw)
		if ph == null:
			return null
		cfg.phases.append(ph)

	# C1 순서
	var ids: Array[String] = []
	for ph: Dictionary in cfg.phases:
		ids.append(ph["id"])
	if ids != PHASE_IDS:
		return _fail("C1 phases[].id 순서가 %s 가 아니다: %s" % [PHASE_IDS, ids])

	var last: int = cfg.phases.size() - 1
	var start: int = 0
	for i: int in cfg.phases.size():
		var ph: Dictionary = cfg.phases[i]
		var t: int = ph["ticks"]
		# C2 마지막 구간만 홀드(ticks 0)
		if i == last and t != 0:
			return _fail("C2 마지막 구간 '%s' 의 ticks 는 0 이어야 한다" % ph["id"])
		if i != last and t <= 0:
			return _fail("C2 구간 '%s' 의 ticks 는 양수여야 한다" % ph["id"])
		var speeds: Array = ph["speeds"]
		# C3 오름차순·중복 없음
		for j: int in range(1, speeds.size()):
			if speeds[j] <= speeds[j - 1]:
				return _fail("C3 구간 '%s' 의 speeds 가 오름차순·중복 없음이 아니다: %s" % [ph["id"], speeds])
		# C4
		if not speeds.has(ph["default_speed"]):
			return _fail("C4 구간 '%s' 의 default_speed 가 speeds 에 없다" % ph["id"])
		# C5 pausable == (0 ∈ speeds)
		if ph["pausable"] != speeds.has(0):
			return _fail("C5 구간 '%s' 의 pausable 이 speeds 와 맞지 않는다" % ph["id"])
		cfg._index[ph["id"]] = i
		cfg._starts.append(start)
		start += t
	cfg.day_ticks = start
	return cfg


## 구간 id 의 순번. 모르는 id 는 -1.
func phase_index(id: String) -> int:
	return _index.get(id, -1)


## 구간 시작점 = 앞 구간 ticks 누적합. 모르는 id 는 -1.
func phase_start(id: String) -> int:
	var i: int = phase_index(id)
	return _starts[i] if i >= 0 else -1


func phase(id: String) -> Dictionary:
	var i: int = phase_index(id)
	return phases[i] if i >= 0 else {}


func phase_ticks(id: String) -> int:
	return phase(id).get("ticks", 0)


## 홀드 구간(ticks == 0): 시간으로 나가지 않는다.
func is_hold(id: String) -> bool:
	return phase_index(id) >= 0 and phase_ticks(id) == 0


func first_phase_id() -> String:
	return phases[0]["id"]


## 다음 구간 id. 마지막 구간이면 빈 문자열(홀드에서 다음 날은 명령으로만 간다).
func next_phase_id(id: String) -> String:
	var i: int = phase_index(id)
	if i < 0 or i + 1 >= phases.size():
		return ""
	return phases[i + 1]["id"]


func is_speed_allowed(id: String, s: int) -> bool:
	return (phase(id).get("speeds", []) as Array).has(s)


static func _parse_phase(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return _fail("phases[] 원소는 객체여야 한다")
	var id: Variant = raw.get("id")
	if not (id is String) or (id as String).is_empty():
		return _fail("phases[].id 는 문자열이어야 한다")
	var t: Variant = _as_int(raw.get("ticks"))
	if t == null or t < 0:
		return _fail("구간 '%s' 의 ticks 는 0 이상 정수여야 한다" % id)
	var pausable: Variant = raw.get("pausable")
	if not (pausable is bool):
		return _fail("구간 '%s' 의 pausable 은 bool 이어야 한다" % id)
	var raw_speeds: Variant = raw.get("speeds")
	if not (raw_speeds is Array) or (raw_speeds as Array).is_empty():
		return _fail("구간 '%s' 의 speeds 는 비어 있지 않은 배열이어야 한다" % id)
	var speeds: Array = []
	for v: Variant in raw_speeds:
		var s: Variant = _as_int(v)
		if s == null or s < 0:
			return _fail("구간 '%s' 의 speeds 원소는 0 이상 정수여야 한다" % id)
		speeds.append(s)
	var ds: Variant = _as_int(raw.get("default_speed"))
	if ds == null:
		return _fail("구간 '%s' 의 default_speed 는 정수여야 한다" % id)
	var mode: Variant = raw.get("enter_speed_mode")
	if not (mode is String) or not ENTER_MODES.has(mode):
		return _fail("구간 '%s' 의 enter_speed_mode 는 %s 중 하나여야 한다" % [id, ENTER_MODES])
	return {
		"id": id,
		"ticks": t,
		"pausable": pausable,
		"speeds": speeds,
		"default_speed": ds,
		"enter_speed_mode": mode,
	}


## int, 또는 정수값인 유한 float 만 int 로. 그 밖은 null.
static func _as_int(v: Variant) -> Variant:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v):
		return int(v)
	return null


static func _string_list(v: Variant) -> Variant:
	if not (v is Array) or (v as Array).is_empty():
		return null
	var out: Array[String] = []
	for e: Variant in v:
		if not (e is String) or (e as String).is_empty():
			return null
		out.append(e)
	return out


static func _has_duplicates(a: Array) -> bool:
	var seen: Dictionary = {}
	for e: Variant in a:
		if seen.has(e):
			return true
		seen[e] = true
	return false


static func _fail(msg: String) -> Variant:
	push_error("[SimConfig] " + msg)
	return null
