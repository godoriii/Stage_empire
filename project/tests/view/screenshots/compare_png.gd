extends SceneTree
## SE-020: 두 PNG 의 픽셀 차를 출력한다. PIL 없이 Godot 만 쓴다.
##
##   godot --headless --path project -s res://tests/view/screenshots/compare_png.gd -- <a.png> <b.png> [--strict] [--size-only]
##
## 출력(한 줄): diff_pixels=<n> max_channel_delta=<d>
## --size-only: PNG 2장이면 서로 같은 크기인지, 1장이면 1920x1080 인지만 검사 → size_ok=true|false size=<WxH>
## 종료 코드: 0 = 정상(비strict 는 차이가 있어도 0), 1 = --strict 이고 diff_pixels > 0,
##            2 = 크기 불일치("size mismatch"), 3 = 인자 오류 또는 PNG 로드 실패.
## 비교 로직은 PngCompare(res://tests/view/png_compare.gd) — GUT 단위 테스트 대상.
## 주의: 이 폴더는 .gdignore 라 class_name 캐시에 안 잡힌다(PngCompare 는 경로로 preload 한다).

const PngCompareScript: GDScript = preload("res://tests/view/png_compare.gd")

const EXIT_OK: int = 0
const EXIT_DIFF_STRICT: int = 1
const EXIT_SIZE_MISMATCH: int = 2
const EXIT_USAGE: int = 3
const EXPECTED_SIZE: Vector2i = Vector2i(1920, 1080)


func _init() -> void:
	quit(_run(OS.get_cmdline_user_args()))


func _run(args: PackedStringArray) -> int:
	var paths: PackedStringArray = PackedStringArray()
	var strict: bool = false
	var size_only: bool = false
	for a: String in args:
		if a == "--strict":
			strict = true
		elif a == "--size-only":
			size_only = true
		elif a.begins_with("--"):
			printerr("unknown option: %s" % a)
			return EXIT_USAGE
		else:
			paths.append(a)
	if size_only and paths.size() >= 1 and paths.size() <= 2:
		return _size_only(paths)
	if paths.size() != 2:
		printerr("usage: compare_png.gd -- <a.png> <b.png> [--strict] [--size-only]")
		return EXIT_USAGE
	var a_img: Image = _load(paths[0])
	var b_img: Image = _load(paths[1])
	if a_img == null or b_img == null:
		return EXIT_USAGE
	var r: Dictionary = PngCompareScript.diff(a_img, b_img)
	if r["error"] == PngCompareScript.ERR_SIZE_MISMATCH:
		print("size mismatch: %s=%s %s=%s" % [paths[0], r["size_a"], paths[1], r["size_b"]])
		return EXIT_SIZE_MISMATCH
	print("diff_pixels=%d max_channel_delta=%d" % [r["diff_pixels"], r["max_channel_delta"]])
	if strict and int(r["diff_pixels"]) > 0:
		return EXIT_DIFF_STRICT
	return EXIT_OK


func _size_only(paths: PackedStringArray) -> int:
	var sizes: Array[Vector2i] = []
	for p: String in paths:
		var img: Image = _load(p)
		if img == null:
			return EXIT_USAGE
		sizes.append(img.get_size())
	var ok: bool = sizes[0] == EXPECTED_SIZE
	if sizes.size() == 2:
		ok = sizes[0] == sizes[1]
	print("size_ok=%s size=%dx%d" % [str(ok).to_lower(), sizes[0].x, sizes[0].y])
	if not ok:
		print("size mismatch")
		return EXIT_SIZE_MISMATCH
	return EXIT_OK


func _load(path: String) -> Image:
	var img: Image = Image.new()
	var err: int = img.load(path)
	if err != OK:
		printerr("PNG load failed (%d): %s" % [err, path])
		return null
	return img
