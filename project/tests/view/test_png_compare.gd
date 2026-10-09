extends GutTest
## SE-020: PngCompare.diff 단위 테스트(합성 이미지 대조군 + 커밋된 기준 PNG 5장 로드 경로).
## compare_png.gd 의 종료 코드 표(0/1/2)는 docs/reports/SE-020.md 의 수동 실행 기록. Xvfb 불필요.

const SHOT_ROOT: String = "res://tests/view/screenshots"
const BASELINES: Array[String] = [
	"SE-002/grid_yaw45_zoom2.png",
	"SE-004/a_yaw45_zoom2.png",
	"SE-004/b_yaw45_zoom2.png",
	"SE-004/c_yaw45_zoom2.png",
	"SE-004/b_yaw45_zoom0.png",
]


func _filled(w: int, h: int, c: Color) -> Image:
	var img: Image = Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return img


func test_identical_images_have_zero_diff() -> void:
	var a: Image = _filled(16, 9, Color8(40, 50, 60, 255))
	var b: Image = _filled(16, 9, Color8(40, 50, 60, 255))
	var r: Dictionary = PngCompare.diff(a, b)
	assert_eq(r["error"], PngCompare.ERR_NONE, "오류 없음")
	assert_eq(r["diff_pixels"], 0, "다른 픽셀 0")
	assert_eq(r["max_channel_delta"], 0, "채널 차 0")


func test_one_pixel_change_is_counted_with_channel_delta() -> void:
	var a: Image = _filled(16, 9, Color8(40, 50, 60, 255))
	var b: Image = a.duplicate() as Image
	b.set_pixel(3, 4, Color8(40, 50, 75, 255))   # B 채널만 +15
	var r: Dictionary = PngCompare.diff(a, b)
	assert_eq(r["diff_pixels"], 1, "다른 픽셀 정확히 1")
	assert_eq(r["max_channel_delta"], 15, "최대 채널 차 15")
	# 대칭.
	var r2: Dictionary = PngCompare.diff(b, a)
	assert_eq(r2["diff_pixels"], 1, "순서를 바꿔도 1")
	assert_eq(r2["max_channel_delta"], 15, "순서를 바꿔도 15")


func test_multiple_changes_use_max_delta_and_count_each_pixel_once() -> void:
	var a: Image = _filled(8, 8, Color8(100, 100, 100, 255))
	var b: Image = a.duplicate() as Image
	b.set_pixel(0, 0, Color8(101, 99, 100, 255))     # 한 픽셀에서 두 채널 변경 → 픽셀 1개로 센다
	b.set_pixel(7, 7, Color8(100, 100, 100, 200))    # 알파 차 55 도 RGBA 비교에 잡힌다
	var r: Dictionary = PngCompare.diff(a, b)
	assert_eq(r["diff_pixels"], 2, "픽셀 2개")
	assert_eq(r["max_channel_delta"], 55, "알파 포함 최대 차 55")


func test_different_size_returns_size_mismatch() -> void:
	var a: Image = _filled(16, 9, Color.BLACK)
	var b: Image = _filled(16, 10, Color.BLACK)
	var r: Dictionary = PngCompare.diff(a, b)
	assert_eq(r["error"], PngCompare.ERR_SIZE_MISMATCH, "크기 불일치 오류")
	assert_eq(r["diff_pixels"], -1, "diff_pixels 는 -1(비교 안 함)")
	assert_eq(r["size_a"], Vector2i(16, 9), "size_a")
	assert_eq(r["size_b"], Vector2i(16, 10), "size_b")


func test_non_rgba8_format_is_converted_before_compare() -> void:
	var a: Image = _filled(4, 4, Color8(10, 20, 30, 255))
	var b: Image = a.duplicate() as Image
	b.convert(Image.FORMAT_RGB8)
	var r: Dictionary = PngCompare.diff(a, b)
	assert_eq(r["diff_pixels"], 0, "RGB8 로 바꿔도 알파 255 와 같다")
	b.set_pixel(1, 1, Color8(10, 20, 31, 255))
	assert_eq(PngCompare.diff(a, b)["diff_pixels"], 1, "RGB8 사본의 1픽셀 변경도 잡힌다")


func test_committed_baselines_load_and_self_compare_is_zero() -> void:
	for rel: String in BASELINES:
		var abs_path: String = ProjectSettings.globalize_path(SHOT_ROOT.path_join(rel))
		assert_true(FileAccess.file_exists(abs_path), "기준 PNG 존재(LFS 체크아웃): %s" % rel)
		if not FileAccess.file_exists(abs_path):
			continue
		var a: Image = Image.new()
		var b: Image = Image.new()
		assert_eq(a.load(abs_path), OK, "%s 로드" % rel)
		assert_eq(b.load(abs_path), OK, "%s 두 번째 로드" % rel)
		assert_eq(a.get_size(), Vector2i(1920, 1080), "%s 1920×1080 (LFS 포인터면 로드가 실패한다)" % rel)
		var r: Dictionary = PngCompare.diff(a, b)
		assert_eq(r["diff_pixels"], 0, "%s 자기 자신과 0" % rel)
		assert_eq(r["max_channel_delta"], 0, "%s 채널 차 0" % rel)


## 대조군: 서로 다른 기준 PNG 둘은 실제로 다르다고 나와야 한다(비교기가 항상 0 을 내지 않는다는 증거).
func test_different_baselines_differ() -> void:
	var a: Image = Image.new()
	var b: Image = Image.new()
	assert_eq(a.load(ProjectSettings.globalize_path(SHOT_ROOT.path_join("SE-004/a_yaw45_zoom2.png"))), OK, "a 로드")
	assert_eq(b.load(ProjectSettings.globalize_path(SHOT_ROOT.path_join("SE-004/b_yaw45_zoom2.png"))), OK, "b 로드")
	var r: Dictionary = PngCompare.diff(a, b)
	assert_gt(int(r["diff_pixels"]), 1000, "시안 A 와 B 는 외곽선 폭 때문에 크게 다르다")
	assert_gt(int(r["max_channel_delta"]), 0, "채널 차 > 0")
