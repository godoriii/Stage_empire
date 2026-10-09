extends GutTest
## SE-004 AC12 (qa): 커밋된 Xvfb 스크린샷에서 캡슐 좌우 외곽선의 가로 폭(px)을 직접 잰다.
## A 1px, B 2px, C 2px, B 는 줌 0(size 7 m)과 줌 2(size 20 m)에서 같다(화면 px 기준 두께 일정).
## 측정: 캡슐 몸통(직선 구간) 각 행에서 "어두운 픽셀(max(r,g,b) < DARK_MAX)" 연속 구간의 길이.
## 배경 타일 바닥은 약 (53,38,49), 캡슐 몸통은 밝아서 외곽선(약 (7,4,14))만 걸린다.
## 이 테스트는 스크린샷을 새로 찍지 않는다(재캡처 비교는 docs/reports/SE-004.md 의 수동 절차).

const SHOT_DIR: String = "res://tests/view/screenshots/SE-004"
const DARK_MAX: int = 30
## [파일, 행 시작, 행 끝(포함), 기대 폭 px, 검사할 x 구간들(캡슐 1·2 의 좌우 가장자리 포함)]
const CASES: Array = [
	["a_yaw45_zoom2.png", 465, 499, 1, [[780, 830], [858, 908]]],
	["b_yaw45_zoom2.png", 465, 499, 2, [[780, 830], [858, 908]]],
	["c_yaw45_zoom2.png", 465, 499, 2, [[780, 830], [858, 908]]],
	["b_yaw45_zoom0.png", 300, 439, 2, [[470, 580], [690, 800]]],
]


## 한 행의 [xa, xb) 구간에서 어두운 픽셀 연속 구간의 길이 목록.
static func dark_runs(img: Image, y: int, xa: int, xb: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var run: int = 0
	for x: int in range(xa, xb):
		var c: Color = img.get_pixel(x, y)
		var dark: bool = maxi(maxi(roundi(c.r * 255.0), roundi(c.g * 255.0)), roundi(c.b * 255.0)) < DARK_MAX
		if dark:
			run += 1
		elif run > 0:
			out.append(run)
			run = 0
	if run > 0:
		out.append(run)
	return out


func test_outline_width_px_matches_variant() -> void:
	for row: Array in CASES:
		var f: String = row[0]
		var abs_path: String = ProjectSettings.globalize_path(SHOT_DIR.path_join(f))
		var img: Image = Image.new()
		assert_eq(img.load(abs_path), OK, "%s PNG 로드" % f)
		if img.is_empty():
			continue
		var want: int = row[3]
		var rows_checked: int = 0
		var bad: PackedStringArray = PackedStringArray()
		for y: int in range(row[1], row[2] + 1):
			for span: Array in row[4]:
				var runs: PackedInt32Array = dark_runs(img, y, span[0], span[1])
				# 캡슐 하나 = 좌우 가장자리 2개 → 구간마다 폭 want 짜리 어두운 구간이 정확히 2개(좌·우 외곽선).
				if runs.size() != 2 or runs[0] != want or runs[1] != want:
					bad.append("y=%d x[%d,%d) runs=%s" % [y, span[0], span[1], str(runs)])
			rows_checked += 1
		assert_gt(rows_checked, 0, "%s 검사한 행 있음" % f)
		assert_eq(bad.size(), 0, "%s 외곽선 폭 %d px (어긋난 행: %s)" % [f, want, ", ".join(bad.slice(0, 5))])


func test_outline_width_is_zoom_independent_but_capsule_scale_changes() -> void:
	# 줌 0 의 캡슐은 줌 2 보다 size 비(20/7 ≈ 2.86)만큼 크게 그려지는데 외곽선 폭은 같다.
	var near: Image = Image.new()
	var far: Image = Image.new()
	assert_eq(near.load(ProjectSettings.globalize_path(SHOT_DIR.path_join("b_yaw45_zoom0.png"))), OK)
	assert_eq(far.load(ProjectSettings.globalize_path(SHOT_DIR.path_join("b_yaw45_zoom2.png"))), OK)
	if near.is_empty() or far.is_empty():
		return
	var near_runs: PackedInt32Array = dark_runs(near, 372, 470, 580)
	var far_runs: PackedInt32Array = dark_runs(far, 480, 780, 830)
	assert_eq(near_runs.size(), 2, "줌 0 캡슐 가장자리 2개")
	assert_eq(far_runs.size(), 2, "줌 2 캡슐 가장자리 2개")
	assert_eq(near_runs, far_runs, "줌 0 과 줌 2 의 외곽선 폭이 같다")
	# 캡슐 바깥 폭(왼쪽 외곽선 시작 ~ 오른쪽 외곽선 끝)은 줌에 따라 달라야 한다(줌 값이 실제로 적용됐다는 증거).
	assert_gt(_outer_width(near, 372, 470, 580), _outer_width(far, 480, 780, 830) * 2, "줌 0 캡슐이 줌 2 보다 2배 넘게 크다")


static func _outer_width(img: Image, y: int, xa: int, xb: int) -> int:
	var first: int = -1
	var last: int = -1
	for x: int in range(xa, xb):
		var c: Color = img.get_pixel(x, y)
		if maxi(maxi(roundi(c.r * 255.0), roundi(c.g * 255.0)), roundi(c.b * 255.0)) < DARK_MAX:
			if first < 0:
				first = x
			last = x
	return last - first + 1


func test_dark_run_measure_control() -> void:
	# 대조군: 측정 함수가 폭을 정확히 센다(1·2·3 px 합성 이미지).
	var img: Image = Image.create(40, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color8(50, 40, 50))
	img.set_pixel(5, 0, Color8(7, 4, 14))
	img.set_pixel(10, 0, Color8(7, 4, 14))
	img.set_pixel(11, 0, Color8(7, 4, 14))
	for x: int in [20, 21, 22]:
		img.set_pixel(x, 0, Color8(7, 4, 14))
	assert_eq(dark_runs(img, 0, 0, 40), PackedInt32Array([1, 2, 3]), "합성 이미지 폭 1·2·3")
