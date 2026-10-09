extends GutTest
## SE-021 qa 추가(AC2 보강): test_se021_outline_qa.gd 의 접점 검사는 바 카운터 아랫변 모서리 x 1721~1727(±4열)을
## 범위에서 뺐다. 그 7열 안의 끊김도 고정해 둔다(회귀·개선 둘 다 눈에 띄게 한다).
## 현재 캡처(Xvfb, gl_compatibility)에서 끊긴 열은 모서리 아래 x 1725 한 열이다(격자선 단차, 구현자 "한계" 절과 같은 원인).

const QaScript: GDScript = preload("res://tests/view/test_se021_outline_qa.gd")
const CORNER_COLS: Array[int] = [1721, 1722, 1723, 1724, 1725, 1726, 1727]
const CORNER_KNOWN_GAPS: Array[int] = [1725]


func _gap_cols(img: Image) -> Array[int]:
	var gaps: Array[int] = []
	for x: int in CORNER_COLS:
		# 모서리 부근 접점 y: 앞 면 기준선을 x 1724(y 702)까지, 이후 오른쪽 면(기울기 -1/2).
		var y: int = 702 + (0 if x <= 1724 else -floori((x - 1724) * 0.5))
		if x < 1724:
			y = 702 - ceili((1724 - x) * 0.5)
		if QaScript.max_dark_run_in_column(img, x, y - 3, y + 6) < 1:
			gaps.append(x)
	return gaps


func test_corner_contact_gaps_are_pinned() -> void:
	var img: Image = QaScript._load("res://tests/view/screenshots/SE-021", "ss_yaw45_zoom0.png")
	assert_not_null(img, "ss_yaw45_zoom0.png 로드")
	if img == null:
		return
	assert_eq(_gap_cols(img), CORNER_KNOWN_GAPS, "모서리 7열: 끊긴 열 고정")


func test_corner_control_b_has_no_contact_line() -> void:
	var b: Image = QaScript._load("res://tests/view/screenshots/SE-004", "b_yaw45_zoom0.png")
	assert_not_null(b, "b_yaw45_zoom0.png 로드")
	if b == null:
		return
	# 대조군: B 는 모서리 7열 중 접점 선이 있는 열이 (수직 모서리와 겹치는 1722~1723 제외) 없다.
	var lines: int = 0
	for x: int in [1721, 1724, 1725, 1726, 1727]:
		var y: int = 702 - (0 if x == 1724 else (ceili((1724 - x) * 0.5) if x < 1724 else floori((x - 1724) * 0.5)))
		if QaScript.max_dark_run_in_column(b, x, y - 3, y + 6) > 0:
			lines += 1
	assert_eq(lines, 0, "대조군 B: 모서리 부근 접점 선 없음")
