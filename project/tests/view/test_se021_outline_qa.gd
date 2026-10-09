extends GutTest
## SE-021 AC1~AC3 (+AC7 의 픽셀 부분): 커밋된 Xvfb(gl_compatibility) 캡처에서 스크린스페이스 외곽선(시안 ss)의 폭(px)을 잰다.
## 측정 방법은 test_se004_outline_qa.gd 와 같다: 한 행(또는 열)에서 "어두운 픽셀(max(r,g,b) < 30)" 연속 구간의 길이.
## 이 테스트는 스크린샷을 새로 찍지 않는다(재캡처 명령은 docs/tickets/SE-021.md "테스트 방법").

const SS_DIR: String = "res://tests/view/screenshots/SE-021"
const B_DIR: String = "res://tests/view/screenshots/SE-004"
const DARK_MAX: int = 30
## outline_ss.tres 의 outline_px(= B 의 2 px).
const WANT_PX: int = 2

## AC1: 바 카운터 수직 실루엣(SE-004 qa 좌표). [행 시작, 행 끝(포함), x 구간].
const BAR_RIGHT_EDGE: Array = [510, 639, [1820, 1845]]
const BAR_LEFT_EDGE: Array = [400, 529, [1388, 1402]]
## 왼쪽 모서리에서 보라 캡슐(바 뒤) 아래쪽 외곽선이 바 외곽선과 이어지는 행. 장면 기하 때문이며 B 캡처도 같은 행에서
## 폭 1 이 아니다(test_bar_left_merge_rows_are_scene_geometry 가 대조). SE-004 qa 의 "126행"과 같은 사정.
const BAR_LEFT_MERGE_ROWS: Array[int] = [490, 491]

## AC2: 바 카운터 아랫변(바닥 접점). 줌 0 캡처에서 아랫변은 2:1 직선이다.
## [x 시작, x 끝(포함), 기준 x, 기준 y, 기울기 부호] → 접점 y = 기준 y + 부호 · (x − 기준 x) / 2. 열마다 [y − 3, y + 6) 를 본다.
##   앞(왼쪽 아래) 면: (1396, 538) → (1724, 702). 오른쪽 면: (1724, 702) → (1832, 648). 모서리 ±4 열은 뺀다.
const CONTACT_SEGMENTS: Array = [[1400, 1720, 1396, 538, 1], [1728, 1828, 1724, 702, -1]]
const CONTACT_WINDOW_ABOVE: int = 3
const CONTACT_WINDOW_BELOW: int = 6
## 바닥 격자선(0.005 m 위 1 px 선)이 접점 바로 아래를 덮는 열. 그 픽셀의 깊이 단차 때문에 법선을 믿지 못해 선이 끊긴다
## (결과 절 "한계"). 회귀를 잡도록 목록을 고정한다(늘거나 줄면 실패).
const CONTACT_KNOWN_GAPS: Array[int] = [1503]

## AC3: test_se004_outline_qa.gd CASES 와 같은 행·열.
const CAPSULE_CASES: Array = [
	["ss_yaw45_zoom2.png", 465, 499, [[780, 830], [858, 908]]],
	["ss_yaw45_zoom0.png", 300, 439, [[470, 580], [690, 800]]],
]


static func _load(dir: String, f: String) -> Image:
	var img: Image = Image.new()
	if img.load(ProjectSettings.globalize_path(dir.path_join(f))) != OK:
		return null
	return img


static func _is_dark(img: Image, x: int, y: int) -> bool:
	var c: Color = img.get_pixel(x, y)
	return maxi(maxi(roundi(c.r * 255.0), roundi(c.g * 255.0)), roundi(c.b * 255.0)) < DARK_MAX


## 한 행의 [xa, xb) 구간에서 어두운 픽셀 연속 구간의 길이 목록.
static func dark_runs(img: Image, y: int, xa: int, xb: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var run: int = 0
	for x: int in range(xa, xb):
		if _is_dark(img, x, y):
			run += 1
		elif run > 0:
			out.append(run)
			run = 0
	if run > 0:
		out.append(run)
	return out


## 한 열의 [ya, yb) 구간에서 가장 긴 어두운 연속 구간.
static func max_dark_run_in_column(img: Image, x: int, ya: int, yb: int) -> int:
	var best: int = 0
	var run: int = 0
	for y: int in range(ya, yb):
		run = run + 1 if _is_dark(img, x, y) else 0
		best = maxi(best, run)
	return best


## 접점 구간 전 열의 (x, 최대 어두운 연속 길이).
static func contact_widths(img: Image) -> Dictionary:
	var out: Dictionary = {}
	for seg: Array in CONTACT_SEGMENTS:
		for x: int in range(seg[0], seg[1] + 1):
			var y: int = seg[3] + seg[4] * floori((x - seg[2]) * 0.5)
			out[x] = max_dark_run_in_column(img, x, y - CONTACT_WINDOW_ABOVE, y + CONTACT_WINDOW_BELOW)
	return out


func test_box_vertical_edges_are_full_width() -> void:
	var img: Image = _load(SS_DIR, "ss_yaw45_zoom0.png")
	assert_not_null(img, "ss_yaw45_zoom0.png 로드")
	if img == null:
		return
	var bad: PackedStringArray = PackedStringArray()
	var rows: int = 0
	for y: int in range(BAR_RIGHT_EDGE[0], BAR_RIGHT_EDGE[1] + 1):
		var runs: PackedInt32Array = dark_runs(img, y, BAR_RIGHT_EDGE[2][0], BAR_RIGHT_EDGE[2][1])
		rows += 1
		if runs != PackedInt32Array([WANT_PX]):
			bad.append("R y=%d %s" % [y, str(runs)])
	assert_eq(rows, 130, "오른쪽 모서리 130행")
	var left_rows: int = 0
	for y: int in range(BAR_LEFT_EDGE[0], BAR_LEFT_EDGE[1] + 1):
		if BAR_LEFT_MERGE_ROWS.has(y):
			continue
		var runs: PackedInt32Array = dark_runs(img, y, BAR_LEFT_EDGE[2][0], BAR_LEFT_EDGE[2][1])
		left_rows += 1
		if runs != PackedInt32Array([WANT_PX]):
			bad.append("L y=%d %s" % [y, str(runs)])
	assert_eq(left_rows, 128, "왼쪽 모서리 130행 − 캡슐 합류 2행")
	assert_eq(bad.size(), 0, "바 수직 모서리 폭 %d px (어긋난 행: %s)" % [WANT_PX, ", ".join(bad.slice(0, 5))])


func test_bar_left_merge_rows_are_scene_geometry() -> void:
	# 대조: 제외한 2행은 B 캡처에서도 "폭 1 하나"가 아니다(캡슐 외곽선 합류 = 장면 기하, ss 탓이 아님).
	var b: Image = _load(B_DIR, "b_yaw45_zoom0.png")
	assert_not_null(b, "b_yaw45_zoom0.png 로드")
	if b == null:
		return
	for y: int in BAR_LEFT_MERGE_ROWS:
		assert_ne(dark_runs(b, y, BAR_LEFT_EDGE[2][0], BAR_LEFT_EDGE[2][1]), PackedInt32Array([1]), "B y=%d 도 합류" % y)
	# 같은 창에서 B 의 나머지 행은 폭 1(SE-004 qa 관찰과 같다) → ss 가 B 보다 두껍다(1 → 2).
	assert_eq(dark_runs(b, 450, BAR_LEFT_EDGE[2][0], BAR_LEFT_EDGE[2][1]), PackedInt32Array([1]), "B 왼쪽 모서리 폭 1")
	assert_eq(dark_runs(b, 600, BAR_RIGHT_EDGE[2][0], BAR_RIGHT_EDGE[2][1]), PackedInt32Array([1]), "B 오른쪽 모서리 폭 1")


func test_floor_contact_edge_visible() -> void:
	var ss: Image = _load(SS_DIR, "ss_yaw45_zoom0.png")
	var b: Image = _load(B_DIR, "b_yaw45_zoom0.png")
	assert_not_null(ss, "ss_yaw45_zoom0.png 로드")
	assert_not_null(b, "b_yaw45_zoom0.png 로드")
	if ss == null or b == null:
		return
	var ss_w: Dictionary = contact_widths(ss)
	var b_w: Dictionary = contact_widths(b)
	assert_eq(ss_w.size(), 422, "검사 열 422개")
	var gaps: Array[int] = []
	var b_nonzero: Array[int] = []
	for x: int in ss_w.keys():
		if int(ss_w[x]) < 1:
			gaps.append(x)
		if int(b_w[x]) > 0:
			b_nonzero.append(x)
	gaps.sort()
	assert_eq(gaps, CONTACT_KNOWN_GAPS, "ss 접점 외곽선: 알려진 격자선 열 외에는 전 열 ≥ 1 px")
	assert_eq(b_nonzero.size(), 0, "대조군 B: 같은 좌표 전 열 0 px (%s)" % str(b_nonzero.slice(0, 5)))


func test_capsule_outline_matches_b() -> void:
	var edges: int = 0
	for row: Array in CAPSULE_CASES:
		var img: Image = _load(SS_DIR, row[0])
		assert_not_null(img, "%s 로드" % row[0])
		if img == null:
			continue
		var bad: PackedStringArray = PackedStringArray()
		for y: int in range(row[1], row[2] + 1):
			for span: Array in row[3]:
				var runs: PackedInt32Array = dark_runs(img, y, span[0], span[1])
				edges += 2
				if runs != PackedInt32Array([WANT_PX, WANT_PX]):
					bad.append("y=%d x[%d,%d) %s" % [y, span[0], span[1], str(runs)])
		assert_eq(bad.size(), 0, "%s 캡슐 좌우 외곽선 %d px (어긋남: %s)" % [row[0], WANT_PX, ", ".join(bad.slice(0, 5))])
	assert_eq(edges, 140 + 560, "줌 2: 140 가장자리 + 줌 0: 560 가장자리")
	# B 와 같은 폭: SE-004 b 캡처의 같은 행.
	var b: Image = _load(B_DIR, "b_yaw45_zoom2.png")
	var ss: Image = _load(SS_DIR, "ss_yaw45_zoom2.png")
	if b != null and ss != null:
		assert_eq(dark_runs(ss, 480, 780, 830), dark_runs(b, 480, 780, 830), "줌 2 y=480 캡슐 폭 ss == b")


func test_screenshots_exist_1080p() -> void:
	for f: String in ["ss_yaw45_zoom2.png", "ss_yaw45_zoom0.png"]:
		var img: Image = _load(SS_DIR, f)
		assert_not_null(img, "%s 존재·로드" % f)
		if img != null:
			assert_eq(Vector2i(img.get_width(), img.get_height()), Vector2i(1920, 1080), "%s 1920×1080" % f)


func test_measure_helpers_control() -> void:
	var img: Image = Image.create(10, 12, false, Image.FORMAT_RGBA8)
	img.fill(Color8(50, 40, 50))
	for y: int in [3, 4, 7]:
		img.set_pixel(2, y, Color8(7, 4, 14))
	assert_eq(max_dark_run_in_column(img, 2, 0, 12), 2, "열 최대 연속 2")
	assert_eq(max_dark_run_in_column(img, 3, 0, 12), 0, "빈 열 0")
	assert_eq(dark_runs(img, 3, 0, 10), PackedInt32Array([1]), "행 구간 1")
