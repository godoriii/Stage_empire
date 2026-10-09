class_name PngCompare
extends RefCounted
## SE-020: 두 Image 의 픽셀 차 계산(PIL·numpy 없이). 스크립트 compare_png.gd 와 GUT 가 같이 쓴다.
## 비교는 RGBA8 로 변환한 바이트 단위 — SE-004 리포트의 "RGBA 전 채널" 방법과 같다.

const ERR_NONE: String = ""
const ERR_SIZE_MISMATCH: String = "size_mismatch"
const BYTES_PER_PIXEL: int = 4


## 반환: { "error": String, "diff_pixels": int, "max_channel_delta": int, "diff_bbox": Array[int],
##         "size_a": Vector2i, "size_b": Vector2i }
## diff_bbox = [x0, y0, x1, y1] — 다른 픽셀 전체를 감싸는 최소 상자(양 끝 포함 픽셀 좌표). 다른 픽셀이 없으면 [].
## 크기가 다르면 error = ERR_SIZE_MISMATCH 이고 diff_pixels = max_channel_delta = -1, diff_bbox = [].
static func diff(a: Image, b: Image) -> Dictionary:
	var size_a: Vector2i = a.get_size()
	var size_b: Vector2i = b.get_size()
	var out: Dictionary = {
		"error": ERR_NONE, "diff_pixels": 0, "max_channel_delta": 0, "diff_bbox": [], "size_a": size_a, "size_b": size_b,
	}
	if size_a != size_b:
		out["error"] = ERR_SIZE_MISMATCH
		out["diff_pixels"] = -1
		out["max_channel_delta"] = -1
		return out
	var da: PackedByteArray = _as_rgba8(a).get_data()
	var db: PackedByteArray = _as_rgba8(b).get_data()
	if da == db:
		return out
	var width: int = size_a.x
	var n_pixels: int = width * size_a.y
	var diff_pixels: int = 0
	var max_delta: int = 0
	var x0: int = width
	var y0: int = size_a.y
	var x1: int = -1
	var y1: int = -1
	for p: int in range(n_pixels):
		var base: int = p * BYTES_PER_PIXEL
		var pixel_differs: bool = false
		for c: int in range(BYTES_PER_PIXEL):
			var d: int = absi(da[base + c] - db[base + c])
			if d > 0:
				pixel_differs = true
				if d > max_delta:
					max_delta = d
		if pixel_differs:
			diff_pixels += 1
			# 바이트 루프에 얹은 bbox 갱신 — 다른 픽셀에서만 실행되므로 동일 영역의 비용은 늘지 않는다.
			var px: int = p % width
			@warning_ignore("integer_division")
			var py: int = p / width
			if px < x0:
				x0 = px
			if px > x1:
				x1 = px
			if py < y0:
				y0 = py
			y1 = py   # p 가 증가하므로 행은 단조 증가: 마지막으로 다른 픽셀의 행이 최대
	out["diff_pixels"] = diff_pixels
	out["max_channel_delta"] = max_delta
	if diff_pixels > 0:
		out["diff_bbox"] = [x0, y0, x1, y1]
	return out


## --max-diff-pixels=<n> 판정: diff_pixels 가 n 을 넘으면 true(실패). n = 0 은 --strict 와 같다.
## 크기 불일치(diff_pixels = -1)는 호출 쪽이 먼저 처리하므로 여기서는 실패로 보지 않는다.
static func exceeds_max_diff_pixels(result: Dictionary, max_diff_pixels: int) -> bool:
	return int(result["diff_pixels"]) > max_diff_pixels


## compare_png.gd 출력용 "x0,y0,x1,y1" (다른 픽셀이 없으면 "none").
static func format_bbox(bbox: Array) -> String:
	if bbox.is_empty():
		return "none"
	return "%d,%d,%d,%d" % [bbox[0], bbox[1], bbox[2], bbox[3]]


static func _as_rgba8(img: Image) -> Image:
	if img.get_format() == Image.FORMAT_RGBA8:
		return img
	var copy: Image = img.duplicate() as Image
	copy.convert(Image.FORMAT_RGBA8)
	return copy
