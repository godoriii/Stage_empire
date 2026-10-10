extends GutTest
## SE-038 AC4: StageLights — build.placed/demolished 로 light_grade(furniture.json effects, build.md C6) 누적,
## show.started → 스포트 N = min(max_spots, Σ light_grade) 켜짐, show.ended → grade 색 끝 연출 뒤 꺼짐, show.skipped → 변화 없음.
## show.* 페이로드는 events.md(SE-030 브랜치) 형식을 가정한다. 기대값은 데이터에서 테스트가 직접 읽는다.

const ARTIST_PATH: String = "res://data/artist/artist.json"
const EPS: float = 1e-4

var _bus: EventBus
var _lights: StageLights
var _t: float
var _next_entity: int = 1


func before_each() -> void:
	_bus = EventBus.new()
	_t = ViewTestUtil.expected_tile_size_m()
	_lights = StageLights.new()
	add_child_autofree(_lights)
	_lights.bind(_bus, BuildTestUtil.catalog(), _t)
	_next_entity = 1


func _grade_of(furniture_id: String) -> int:
	return int((BuildTestUtil.row(furniture_id)["effects"] as Dictionary)["light_grade"])


## light_grade > 0 인 행 id(테이블 순서).
func _graded_ids() -> Array[String]:
	var out: Array[String] = []
	for r: Dictionary in BuildTestUtil.furniture_json()["rows"]:
		if int((r["effects"] as Dictionary)["light_grade"]) > 0 and str(r["category"]) != "stage":
			out.append(str(r["id"]))
	return out


func _place(furniture_id: String, cell: Vector2i, rotation: int = 0) -> String:
	var id: String = "f%d" % _next_entity
	_next_entity += 1
	_bus.publish("build.placed", BuildTestUtil.placed(id, furniture_id, cell, rotation))
	return id


func _place_stage(rotation: int = 0) -> String:
	return _place("stage_small", Vector2i(10, 15), rotation)


func _started() -> void:
	_bus.publish("show.started", {"day": 1, "artist_id": "a01", "genre": "rock", "expected_admissions": 80})


func _ended(grade: String) -> void:
	_bus.publish("show.ended", {"day": 1, "artist_id": "a01", "satisfaction_bp": 6000, "grade": grade, "admissions": 80,
		"audience": 80, "revenue_hint": 1600, "incidents": []})


func test_spot_nodes_created_off_and_params_valid() -> void:
	var p: StageLightParams = _lights.params
	assert_eq(p.get_errors().size(), 0, "stage_light_params.tres 유효: %s" % ", ".join(p.get_errors()))
	assert_eq(p.max_spots, 4, "SpotLight3D ≤ 4 (SE-038 범위)")
	var spots: Array[SpotLight3D] = _lights.get_spot_nodes()
	assert_eq(spots.size(), p.max_spots, "스포트 노드 max_spots 개")
	for s: SpotLight3D in spots:
		assert_false(s.visible, "처음엔 꺼짐")
		assert_eq(s.shadow_enabled, p.spot_shadows)
		assert_almost_eq(s.spot_angle, p.spot_angle_deg, EPS)
	assert_eq(_lights.get_mode(), StageLights.MODE_OFF)


func test_show_started_turns_on_min_max_spots_light_grade_sum() -> void:
	_place_stage()
	var ids: Array[String] = _graded_ids()
	assert_gt(ids.size(), 1, "light_grade > 0 가구가 있다")
	var expected_sum: int = _grade_of("stage_small")
	assert_eq(_lights.get_light_grade_sum(), expected_sum, "무대 light_grade 포함")
	# 가구를 하나씩 더하며 매번 공연 시작 → N = min(max, Σ).
	var x: int = 1
	for fid: String in ids:
		_place(fid, Vector2i(x, 2))
		x += 3
		expected_sum += _grade_of(fid)
		assert_eq(_lights.get_light_grade_sum(), expected_sum, "Σ light_grade (%s 추가)" % fid)
		_started()
		var want: int = mini(_lights.params.max_spots, expected_sum)
		assert_eq(_lights.get_active_spot_count(), want, "Σ %d → 스포트 %d" % [expected_sum, want])
		assert_eq(_lights.get_mode(), StageLights.MODE_SHOW)
	assert_eq(_lights.get_active_spot_count(), _lights.params.max_spots, "상한 max_spots")
	# 공연 중 색 = show_colors.
	var spots: Array[SpotLight3D] = _lights.get_spot_nodes()
	for i: int in range(_lights.get_active_spot_count()):
		assert_eq(spots[i].light_color, _lights.params.show_colors[i % _lights.params.show_colors.size()], "공연 색 %d" % i)


func test_demolish_and_duplicate_placed_update_sum() -> void:
	_place_stage()
	var fid: String = _graded_ids()[0]
	var e: String = _place(fid, Vector2i(2, 2))
	var base: int = _grade_of("stage_small")
	assert_eq(_lights.get_light_grade_sum(), base + _grade_of(fid))
	_bus.publish("build.placed", BuildTestUtil.placed(e, fid, Vector2i(2, 3), 0))
	assert_eq(_lights.get_light_grade_sum(), base + _grade_of(fid), "같은 entity 재발행은 교체(중복 누적 없음)")
	_bus.publish("build.demolished", BuildTestUtil.demolished(e, fid, Vector2i(2, 3), 0))
	assert_eq(_lights.get_light_grade_sum(), base, "철거 → 뺀다")
	_started()
	assert_eq(_lights.get_active_spot_count(), mini(_lights.params.max_spots, base), "Σ 만큼만")


func test_show_ended_grade_color_finale_then_off() -> void:
	_place_stage()
	for fid: String in _graded_ids():
		_place(fid, Vector2i(1 + _next_entity * 2, 2))
	_started()
	var on: int = _lights.get_active_spot_count()
	assert_gt(on, 0)
	var grades: Array = (ViewTestUtil.read_json(ARTIST_PATH) as Dictionary)["show_grades"]
	var grade: String = str(grades[grades.size() - 1])
	_ended(grade)
	var want: Color = _lights.params.grade_colors[grade] as Color
	assert_eq(_lights.get_mode(), StageLights.MODE_FINALE, "끝 연출")
	assert_eq(_lights.get_finale_color(), want, "grade 색")
	var spots: Array[SpotLight3D] = _lights.get_spot_nodes()
	for i: int in range(on):
		assert_true(spots[i].visible)
		assert_eq(spots[i].light_color, want, "스포트 %d = %s 색" % [i, grade])
	_lights._process(_lights.params.finale_sec * 0.5)
	assert_eq(_lights.get_active_spot_count(), on, "끝 연출 중")
	_lights._process(_lights.params.finale_sec * 0.6)
	assert_eq(_lights.get_active_spot_count(), 0, "finale_sec 뒤 끔")
	assert_eq(_lights.get_mode(), StageLights.MODE_OFF)
	# 모르는 grade → 폴백 색.
	_started()
	_ended("zzz")
	assert_eq(_lights.get_finale_color(), _lights.params.grade_fallback_color, "모르는 grade 폴백")


func test_grade_colors_cover_artist_show_grades() -> void:
	var grades: Array = (ViewTestUtil.read_json(ARTIST_PATH) as Dictionary)["show_grades"]
	assert_gt(grades.size(), 0, "artist.json show_grades")
	var seen: Dictionary = {}
	for g: Variant in grades:
		assert_true(_lights.params.grade_colors.has(str(g)), "grade '%s' 색 있음" % g)
		seen[_lights.params.grade_colors.get(str(g), Color.BLACK)] = true
	assert_eq(seen.size(), grades.size(), "등급별 색이 서로 다르다")


func test_show_skipped_changes_nothing() -> void:
	_place_stage()
	_place(_graded_ids()[0], Vector2i(2, 2))
	_bus.publish("show.skipped", {"day": 1, "reason": "no_lineup"})
	assert_eq(_lights.get_mode(), StageLights.MODE_OFF, "꺼진 채")
	assert_eq(_lights.get_active_spot_count(), 0)
	_started()
	var on: int = _lights.get_active_spot_count()
	var colors: Array[Color] = []
	for s: SpotLight3D in _lights.get_spot_nodes():
		colors.append(s.light_color)
	_bus.publish("show.skipped", {"day": 2, "reason": "no_stage"})
	assert_eq(_lights.get_mode(), StageLights.MODE_SHOW, "켜진 채")
	assert_eq(_lights.get_active_spot_count(), on)
	for i: int in range(colors.size()):
		assert_eq(_lights.get_spot_nodes()[i].light_color, colors[i], "색 불변")


func test_no_stage_or_zero_grade_keeps_spots_off() -> void:
	_place(_graded_ids()[0], Vector2i(2, 2))
	_started()
	assert_eq(_lights.get_active_spot_count(), 0, "무대 모름 → 켜지 않는다")
	_bus.publish("session.loaded", {"day": 1})
	assert_eq(_lights.get_light_grade_sum(), 0, "로드 → 누적 비움")
	assert_false(_lights.has_stage())
	_place_stage()
	_started()
	assert_eq(_lights.get_active_spot_count(), mini(_lights.params.max_spots, _grade_of("stage_small")), "Σ = 무대 등급만")


func test_session_loaded_turns_off_and_replay_restores() -> void:
	_place_stage()
	for fid: String in _graded_ids():
		_place(fid, Vector2i(1 + _next_entity * 2, 2))
	_started()
	assert_gt(_lights.get_active_spot_count(), 0)
	var sum_before: int = _lights.get_light_grade_sum()
	_bus.publish("session.loaded", {"day": 4})
	assert_eq(_lights.get_active_spot_count(), 0, "로드 → 끔")
	assert_eq(_lights.get_mode(), StageLights.MODE_OFF)
	# SE-036: 로드 뒤 build.placed 재발행.
	_next_entity = 1
	_place_stage()
	for fid: String in _graded_ids():
		_place(fid, Vector2i(1 + _next_entity * 2, 2))
	assert_eq(_lights.get_light_grade_sum(), sum_before, "재발행으로 같은 Σ")


func test_spots_hang_in_front_of_stage_and_aim_at_it() -> void:
	for rot: int in [0, 90, 180, 270]:
		_bus.publish("session.loaded", {})
		_next_entity = 1
		_place("stage_small", Vector2i(10, 10), rot)
		for fid: String in _graded_ids():
			_place(fid, Vector2i(1, 1))
		_started()
		var p: StageLightParams = _lights.params
		var fp: Array = BuildTestUtil.row("stage_small")["footprint"]
		var wd: Vector2i = BuildTestUtil.rotated_wd(fp, rot)
		var center: Vector3 = Vector3((10 + wd.x * 0.5) * _t, 0.0, (10 + wd.y * 0.5) * _t)
		# 정면(build.md 방향표): 0 → −z, 90 → −x, 180 → +z, 270 → +x.
		var front: Vector3 = {0: Vector3.FORWARD, 90: Vector3.LEFT, 180: Vector3.BACK, 270: Vector3.RIGHT}[rot]
		for i: int in range(_lights.get_active_spot_count()):
			var s: SpotLight3D = _lights.get_spot_nodes()[i]
			assert_almost_eq(s.position.y, p.spot_height_m, EPS, "rot %d 높이" % rot)
			var rel: Vector3 = s.position - center
			assert_gt(rel.dot(front), 0.0, "rot %d: 스포트 %d 가 무대 정면(관객 쪽)에 있다" % [rot, i])
			var aim: Vector3 = center + Vector3.UP * p.aim_height_m
			var dir: Vector3 = -s.transform.basis.z
			assert_gt(dir.dot((aim - s.position).normalized()), 0.999, "rot %d: 스포트 %d 가 무대 중심을 겨눈다" % [rot, i])
	assert_eq(_bus.get_pending_commands().size(), 0, "명령 발행 0")
