class_name PngCompare
extends RefCounted
## SE-020: 두 Image 의 픽셀 차 계산(PIL·numpy 없이). 스크립트 compare_png.gd 와 GUT 가 같이 쓴다.
## 비교는 RGBA8 로 변환한 바이트 단위 — SE-004 리포트의 "RGBA 전 채널" 방법과 같다.

const ERR_NONE: String = ""
const ERR_SIZE_MISMATCH: String = "size_mismatch"
const BYTES_PER_PIXEL: int = 4


## 반환: { "error": String, "diff_pixels": int, "max_channel_delta": int, "size_a": Vector2i, "size_b": Vector2i }
## 크기가 다르면 error = ERR_SIZE_MISMATCH 이고 diff_pixels = max_channel_delta = -1.
static func diff(a: Image, b: Image) -> Dictionary:
	var size_a: Vector2i = a.get_size()
	var size_b: Vector2i = b.get_size()
	var out: Dictionary = {
		"error": ERR_NONE, "diff_pixels": 0, "max_channel_delta": 0, "size_a": size_a, "size_b": size_b,
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
	var n_pixels: int = size_a.x * size_a.y
	var diff_pixels: int = 0
	var max_delta: int = 0
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
	out["diff_pixels"] = diff_pixels
	out["max_channel_delta"] = max_delta
	return out


static func _as_rgba8(img: Image) -> Image:
	if img.get_format() == Image.FORMAT_RGBA8:
		return img
	var copy: Image = img.duplicate() as Image
	copy.convert(Image.FORMAT_RGBA8)
	return copy
