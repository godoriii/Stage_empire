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


# --- SE-025: diff_bbox / --max-diff-pixels ---------------------------------------------------------

const COMPARE_CLI: String = "res://tests/view/screenshots/compare_png.gd"
const TMP_PREFIX: String = "user://se025_cmp_"   # 리포지토리 밖(user://)에만 쓴다


## AC4: 합성 이미지에서 (10,20)·(30,5) 두 픽셀을 바꾸면 bbox 는 둘을 포함하는 최소 상자 [10,5,30,20].
## 대조군: 동일 이미지 → [], 픽셀 1개 → 그 좌표 하나([x,y,x,y]), 순서를 바꿔도 같다.
func test_diff_bbox_contains_all_changed_pixels() -> void:
	var a: Image = _filled(64, 32, Color8(40, 50, 60, 255))
	var b: Image = a.duplicate() as Image
	assert_eq(PngCompare.diff(a, b)["diff_bbox"], [], "동일 이미지는 bbox 없음([])")
	b.set_pixel(10, 20, Color8(41, 50, 60, 255))
	var one: Dictionary = PngCompare.diff(a, b)
	assert_eq(one["diff_bbox"], [10, 20, 10, 20], "1픽셀 → 그 좌표 하나")
	b.set_pixel(30, 5, Color8(40, 50, 99, 255))
	var r: Dictionary = PngCompare.diff(a, b)
	assert_eq(r["diff_pixels"], 2, "다른 픽셀 2개")
	assert_eq(r["diff_bbox"], [10, 5, 30, 20], "두 영역을 포함하는 최소 상자(양 끝 포함)")
	assert_eq(PngCompare.diff(b, a)["diff_bbox"], [10, 5, 30, 20], "순서를 바꿔도 같다")
	# 모서리 픽셀(0,0)·(63,31)까지 가면 상자가 이미지 전체.
	b.set_pixel(0, 0, Color8(0, 0, 0, 255))
	b.set_pixel(63, 31, Color8(0, 0, 0, 255))
	assert_eq(PngCompare.diff(a, b)["diff_bbox"], [0, 0, 63, 31], "모서리 포함 시 전체")
	assert_eq(PngCompare.format_bbox(PngCompare.diff(a, b)["diff_bbox"]), "0,0,63,31", "출력 형식")
	assert_eq(PngCompare.format_bbox([]), "none", "bbox 없음 출력")


func test_size_mismatch_has_empty_bbox() -> void:
	var r: Dictionary = PngCompare.diff(_filled(4, 4, Color.BLACK), _filled(4, 5, Color.BLACK))
	assert_eq(r["diff_bbox"], [], "크기 불일치는 bbox 없음")


## AC4: --max-diff-pixels=1 에서 1픽셀 차 → 통과(exit 0), 2픽셀 차 → 실패(exit 1). 경계 판정 함수.
func test_max_diff_pixels_boundary_decision() -> void:
	var a: Image = _filled(16, 9, Color8(1, 2, 3, 255))
	var b1: Image = a.duplicate() as Image
	b1.set_pixel(1, 1, Color8(9, 2, 3, 255))
	var b2: Image = b1.duplicate() as Image
	b2.set_pixel(2, 2, Color8(9, 2, 3, 255))
	var r0: Dictionary = PngCompare.diff(a, a.duplicate() as Image)
	var r1: Dictionary = PngCompare.diff(a, b1)
	var r2: Dictionary = PngCompare.diff(a, b2)
	assert_false(PngCompare.exceeds_max_diff_pixels(r1, 1), "1픽셀 ≤ 1 → 통과")
	assert_true(PngCompare.exceeds_max_diff_pixels(r2, 1), "2픽셀 > 1 → 실패")
	assert_false(PngCompare.exceeds_max_diff_pixels(r0, 0), "n=0(--strict): 차이 0 → 통과")
	assert_true(PngCompare.exceeds_max_diff_pixels(r1, 0), "n=0(--strict): 1픽셀 → 실패")


## 실제 CLI(별도 Godot 프로세스)로 exit 코드·출력 줄을 확인한다: 판정 함수가 아니라 compare_png.gd 의 배선 검증.
func test_compare_cli_max_diff_pixels_exit_codes_and_bbox_line() -> void:
	var a: Image = _filled(64, 32, Color8(40, 50, 60, 255))
	var b1: Image = a.duplicate() as Image
	b1.set_pixel(10, 20, Color8(41, 50, 60, 255))
	var b2: Image = b1.duplicate() as Image
	b2.set_pixel(30, 5, Color8(40, 50, 99, 255))
	var pa: String = ProjectSettings.globalize_path(TMP_PREFIX + "a.png")
	var p1: String = ProjectSettings.globalize_path(TMP_PREFIX + "b1.png")
	var p2: String = ProjectSettings.globalize_path(TMP_PREFIX + "b2.png")
	assert_eq(a.save_png(pa), OK, "a 저장")
	assert_eq(b1.save_png(p1), OK, "b1 저장")
	assert_eq(b2.save_png(p2), OK, "b2 저장")

	var r_pass: Dictionary = _run_cli([pa, p1, "--max-diff-pixels=1"])
	assert_eq(r_pass["code"], 0, "1픽셀 차 + 1 → exit 0: %s" % r_pass["out"])
	assert_string_contains(r_pass["out"], "diff_pixels=1 max_channel_delta=1 diff_bbox=10,20,10,20", "1픽셀 출력")
	var r_fail: Dictionary = _run_cli([pa, p2, "--max-diff-pixels=1"])
	assert_eq(r_fail["code"], 1, "2픽셀 차 + 1 → exit 1: %s" % r_fail["out"])
	assert_string_contains(r_fail["out"], "diff_pixels=2 max_channel_delta=39 diff_bbox=10,5,30,20", "2픽셀 출력 + bbox")
	var r_plain: Dictionary = _run_cli([pa, p2])
	assert_eq(r_plain["code"], 0, "옵션 없으면 보고만(exit 0)")
	var r_strict: Dictionary = _run_cli([pa, p1, "--strict"])
	assert_eq(r_strict["code"], 1, "--strict 는 n=0: 1픽셀도 exit 1")
	var r_both: Dictionary = _run_cli([pa, p1, "--strict", "--max-diff-pixels=5"])
	assert_eq(r_both["code"], 3, "--strict + --max-diff-pixels 는 인자 오류(3)")
	var r_bad: Dictionary = _run_cli([pa, p1, "--max-diff-pixels=-1"])
	assert_eq(r_bad["code"], 3, "음수 n 은 인자 오류(3)")
	var r_same: Dictionary = _run_cli([pa, pa, "--strict"])
	assert_eq(r_same["code"], 0, "동일 이미지 --strict → 0")
	assert_string_contains(r_same["out"], "diff_pixels=0 max_channel_delta=0 diff_bbox=none", "차이 없음 출력")

	for path: String in [pa, p1, p2]:
		DirAccess.remove_absolute(path)


func _run_cli(extra: Array) -> Dictionary:
	var args: PackedStringArray = PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", COMPARE_CLI, "--"])
	for e: Variant in extra:
		args.append(str(e))
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	return {"code": code, "out": "".join(output)}
