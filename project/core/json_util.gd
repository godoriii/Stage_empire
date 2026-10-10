class_name JsonUtil
extends RefCounted
## JSON 값 정규화 공용 헬퍼 (SE-044, docs/reviews/SE-032.md 발견 3·5). world(MapConfig 등)와 sim(EconomyConfig, Economy)이
## 같이 쓰므로 core 에 둔다. 전부 정적 순수 함수다(상태·이벤트·난수 없음).
## JSON 숫자는 float 로 파싱되므로 정수값 float 를 int 로 접는다. 64비트 int 로 정확히 표현되지 않는 크기는 거절한다.

## int 로 바꿀 수 있는 float 의 절댓값 상한(미포함) = 2^63. 언어의 int 최댓값(INT64_MAX = 2^63 − 1)을 float 로 바꾸면
## 가장 가까운 double 인 2^63 이 된다. |v| ≥ 이 값이면 int(v) 캐스트 결과가 플랫폼 정의라 거절한다(발견 5).
const FLOAT_INT_LIMIT: float = float(9223372036854775807)
## as_int_pair 의 원소 수(좌표 [x, z], build.md G1).
const PAIR_SIZE: int = 2
## read_json 의 push_error 접두어 기본값.
const DEFAULT_TAG: String = "JsonUtil"


## int, 또는 정수값이고 |v| < 2^63 인 유한 float 만 int 로. 그 밖(bool·문자열·1.5·inf·nan·±1e19·null)은 null.
static func as_int(v: Variant) -> Variant:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v) and absf(v) < FLOAT_INT_LIMIT:
		return int(v)
	return null


## 원소 2개 배열의 각 원소가 as_int 를 통과하면 [x, z](int), 아니면 null.
static func as_int_pair(v: Variant) -> Variant:
	if not (v is Array) or (v as Array).size() != PAIR_SIZE:
		return null
	var x: Variant = as_int(v[0])
	var z: Variant = as_int(v[1])
	if x == null or z == null:
		return null
	return [x, z]


## 정수값 float → int (재귀, Array·Dictionary 안까지). 그 밖의 값(as_int 가 거절하는 float 포함)은 그대로.
static func int_deep(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var n: Variant = as_int(v)
			return n if n != null else v
		TYPE_ARRAY:
			var arr: Array = []
			for e: Variant in v:
				arr.append(int_deep(e))
			return arr
		TYPE_DICTIONARY:
			var out: Dictionary = {}
			for k: Variant in v:
				out[k] = int_deep(v[k])
			return out
	return v


## JSON 파일 → Dictionary. 파일이 없거나 최상위가 객체가 아니면 push_error 1회("[<tag>] …"), null.
static func read_json(path: String, tag: String = DEFAULT_TAG) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("[%s] 파일 없음: %s" % [tag, path])
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("[%s] JSON 객체가 아님: %s" % [tag, path])
		return null
	return parsed
