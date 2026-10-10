class_name SeededRng
extends RefCounted
## 시드 고정 RNG (SE-001). 규칙: docs/gdd/tick.md#결정성과-rng.
## 마스터 시드 + 이름 있는 스트림. 스트림 시드는 FNV-1a 32(str(master_seed) + ":" + name) 로 파생하므로
## 스트림을 추가해도 기존 스트림의 열은 바뀌지 않는다. 스트림은 생성 시 전부 만든다(eager).
## core/sim/world 에서 RandomNumberGenerator 를 만드는 곳은 이 파일뿐이다.

## FNV-1a 32 정의 상수(알고리즘 정의, tick.md#틱 상수표).
const FNV_OFFSET: int = 2166136261
const FNV_PRIME: int = 16777619
const FNV_MASK: int = 0xFFFFFFFF
## 마스터 시드 상한 2^31 - 1 (JSON 왕복에서 정수 손실 없음).
const MASTER_SEED_MAX: int = 2147483647

var master_seed: int = 0
var stream_names: Array[String] = []
var _streams: Dictionary = {}   # name -> RandomNumberGenerator


func _init(p_master_seed: int, p_stream_names: Array[String]) -> void:
	var s: int = p_master_seed
	if s < 0 or s > MASTER_SEED_MAX:
		push_error("[SeededRng] 마스터 시드 %d 가 범위(0~%d) 밖이다. posmod 로 접는다" % [s, MASTER_SEED_MAX])
		s = posmod(s, MASTER_SEED_MAX + 1)
	master_seed = s
	for n: String in p_stream_names:
		if _streams.has(n):
			push_warning("[SeededRng] 중복 스트림 이름 무시: %s" % n)
			continue
		var r: RandomNumberGenerator = RandomNumberGenerator.new()
		r.seed = derive_seed(master_seed, n)
		_streams[n] = r
		stream_names.append(n)


## FNV-1a 32비트, 키 = str(master_seed) + ":" + name 의 UTF-8 바이트.
static func derive_seed(p_master_seed: int, stream_name: String) -> int:
	var h: int = FNV_OFFSET
	for b: int in (str(p_master_seed) + ":" + stream_name).to_utf8_buffer():
		h = ((h ^ b) * FNV_PRIME) & FNV_MASK
	return h


## 이름 있는 스트림. sim.json rng_streams 에 없는 이름이면 push_error, null.
func stream(stream_name: String) -> RandomNumberGenerator:
	if not _streams.has(stream_name):
		push_error("[SeededRng] 모르는 스트림: %s (sim.json rng_streams 에 없음)" % stream_name)
		return null
	return _streams[stream_name]


## {스트림 이름: state 10진 문자열}. int64 를 문자열로 두어 JSON 왕복 손실이 없다.
func get_state() -> Dictionary:
	var out: Dictionary = {}
	for n: String in stream_names:
		out[n] = str((_streams[n] as RandomNumberGenerator).state)
	return out


## other 의 마스터 시드·스트림 시드·상태를 이 객체에 옮긴다(이 객체와 스트림 객체는 그대로 둔다). 같은 스트림 이름
## 목록이어야 한다(아니면 push_error, false, 상태 불변). TickLoop.restore 8(b) 가 검증을 끝낸 새 SeededRng 를 기존 객체에
## 적용할 때 쓴다 — 시스템이 생성자에서 받은 rng 참조가 복원 뒤에도 유효하다(SE-034-bug).
func assign(other: SeededRng) -> bool:
	if other == null or other.stream_names != stream_names:
		push_error("[SeededRng] assign: 스트림 목록이 다르다")
		return false
	master_seed = other.master_seed
	for n: String in stream_names:
		var dst: RandomNumberGenerator = _streams[n]
		var src: RandomNumberGenerator = other._streams[n]
		dst.seed = src.seed
		dst.state = src.state
	return true


## get_state() 결과를 적용한다. 값이 10진 정수 문자열이 아니면 push_error, false, 상태 불변.
## 모르는 스트림은 push_warning 후 무시, 빠진 스트림은 현재 상태 유지.
func set_state(d: Dictionary) -> bool:
	var apply: Dictionary = {}
	for k: Variant in d:
		if not (k is String or k is StringName):
			push_error("[SeededRng] set_state: 스트림 이름이 문자열이 아니다: %s" % [k])
			return false
		var v: Variant = d[k]
		if not (v is String) or not (v as String).is_valid_int():
			push_error("[SeededRng] set_state: '%s' 의 상태가 10진 정수 문자열이 아니다" % k)
			return false
		var n: String = String(k)
		if not _streams.has(n):
			push_warning("[SeededRng] set_state: 모르는 스트림 무시: %s" % n)
			continue
		apply[n] = (v as String).to_int()
	for n: String in apply:
		(_streams[n] as RandomNumberGenerator).state = apply[n]
	return true
