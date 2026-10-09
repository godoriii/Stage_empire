class_name PerfStats
extends RefCounted
## 프레임 시간 배열 → 평균 fps, 1% low fps, 평균/최대 프레임 ms. 순수 계산(Node 무관, 헤드리스 테스트 가능).
##
## 정의(SE-003 AC5):
## - avg_frame_ms = 프레임 시간(ms)의 산술 평균
## - avg_fps = 1000 / avg_frame_ms (= 총 프레임 수 / 총 시간)
## - 1% low: 프레임 시간이 긴 쪽부터 k = ceil(n × 1%) 개(최소 1개)를 골라, 그 평균 프레임 시간으로 낸 fps
##   (p1_low_fps = 1000 / mean(가장 느린 k 프레임 ms))
## - max_frame_ms = 가장 긴 프레임 시간
## 빈 배열이면 valid = false, 모든 값 0.

## "1% low" 의 1%. 지표의 정의 자체라 튜닝 값이 아니다.
const LOW_FRACTION: float = 0.01
const MS_PER_SEC: float = 1000.0

var valid: bool = false
var sample_count: int = 0
var avg_frame_ms: float = 0.0
var avg_fps: float = 0.0
var p1_low_frame_ms: float = 0.0
var p1_low_fps: float = 0.0
## 1% low 계산에 쓴 프레임 수(k).
var p1_low_count: int = 0
var max_frame_ms: float = 0.0
var min_frame_ms: float = 0.0
var total_ms: float = 0.0


## frame_times_ms: 프레임 시간(밀리초) 배열. Array 또는 PackedFloat32/64Array.
static func from_frame_times(frame_times_ms: Variant) -> PerfStats:
	var s: PerfStats = PerfStats.new()
	var sorted: PackedFloat64Array = PackedFloat64Array(Array(frame_times_ms))
	var n: int = sorted.size()
	if n == 0:
		return s
	sorted.sort()
	var total: float = 0.0
	for t: float in sorted:
		total += t
	s.valid = true
	s.sample_count = n
	s.total_ms = total
	s.avg_frame_ms = total / float(n)
	s.avg_fps = _fps(s.avg_frame_ms)
	s.min_frame_ms = sorted[0]
	s.max_frame_ms = sorted[n - 1]
	var k: int = maxi(1, ceili(float(n) * LOW_FRACTION))
	var slow_total: float = 0.0
	for i: int in range(n - k, n):
		slow_total += sorted[i]
	s.p1_low_count = k
	s.p1_low_frame_ms = slow_total / float(k)
	s.p1_low_fps = _fps(s.p1_low_frame_ms)
	return s


func to_dict() -> Dictionary:
	return {
		"valid": valid,
		"sample_count": sample_count,
		"avg_fps": avg_fps,
		"p1_low_fps": p1_low_fps,
		"p1_low_count": p1_low_count,
		"avg_frame_ms": avg_frame_ms,
		"p1_low_frame_ms": p1_low_frame_ms,
		"max_frame_ms": max_frame_ms,
		"min_frame_ms": min_frame_ms,
		"total_ms": total_ms,
	}


static func _fps(frame_ms: float) -> float:
	if frame_ms <= 0.0:
		return 0.0
	return MS_PER_SEC / frame_ms
