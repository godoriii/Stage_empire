extends GutTest
## SE-032 AC4 — Coverage (C0~C8, 시야 레이). docs/gdd/build.md#커버리지. 기준 배치 2개는 tier1_club.json
## reference_layouts[].expected 와 전 키 대조(BC22·BC23 의 순수 함수 쪽). 규칙 판정(B*) 없이 인스턴스 목록만 넣는다.

var _cfg: BuildConfig


func before_all() -> void:
	_cfg = BuildConfig.load()


func _instances(placements: Array) -> Array:
	var out: Array = []
	for i: int in placements.size():
		var p: Dictionary = placements[i]
		out.append({
			"entity_id": "f%d" % (i + 1), "furniture_id": p["furniture_id"], "cell": p["cell"],
			"rotation": p["rotation"], "paid": _cfg.furniture(p["furniture_id"])["build_cost"],
		})
	return out


func _compute(instances: Array) -> Dictionary:
	return Coverage.compute(_cfg.map, _cfg.furniture_table, _cfg.rate_scale, instances)


func _layout_instances(layout_id: String) -> Array:
	return _instances(_cfg.layout(layout_id)["placements"])


func _assert_layout(layout_id: String) -> void:
	var layout: Dictionary = _cfg.layout(layout_id)
	var inst: Array = _instances(layout["placements"])
	var cov: Dictionary = _compute(inst)
	var cost: int = 0
	for i: Dictionary in inst:
		cost += int(i["paid"])
	var blocked: Array = []
	for t: Array in cov["viewing_tiles"]:
		if not (cov["sight_tiles"] as Array).has(t):
			blocked.append(t)
	var derived: Dictionary = {
		"sound_count": (cov["sound_tiles"] as Array).size(), "sight_count": (cov["sight_tiles"] as Array).size(),
		"bar_count": (cov["bar_tiles"] as Array).size(), "build_cost": cost,
		"cash_after": _cfg.starting_cash - cost, "sight_blocked_cells": blocked,
	}
	var expected: Dictionary = layout["expected"]
	for k: String in expected:
		if cov.has(k):
			assert_eq(cov[k], expected[k], "%s: %s" % [layout_id, k])
		elif derived.has(k):
			assert_eq(derived[k], expected[k], "%s: %s" % [layout_id, k])
		else:
			fail_test("%s: expected 키 '%s' 를 대조할 수 없다" % [layout_id, k])
	assert_eq(cov.keys(), Array(Coverage.KEYS), "페이로드 키·순서")


func test_ac4_empty_room_matches_expected() -> void:
	_assert_layout("empty_room")


func test_ac4_baseline_show_matches_expected() -> void:
	_assert_layout("baseline_show")
	var cov: Dictionary = _compute(_layout_instances("baseline_show"))
	assert_eq((cov["viewing_tiles"] as Array).size(), cov["viewing_count"])
	# G6: 타일 배열은 z → x 오름차순.
	for key: String in ["viewing_tiles", "sound_tiles", "sight_tiles", "bar_tiles"]:
		var a: Array = cov[key]
		var sorted: Array = a.duplicate()
		sorted.sort_custom(func(p: Array, q: Array) -> bool: return p[1] < q[1] or (p[1] == q[1] and p[0] < q[0]))
		assert_eq(a, sorted, "%s 정렬" % key)


func test_bc21_two_more_speakers_pure() -> void:
	var inst: Array = _layout_instances("baseline_show")
	inst.append({"entity_id": "f7", "furniture_id": "speaker_floor", "cell": [5, 10], "rotation": 0, "paid": 0})
	inst.append({"entity_id": "f8", "furniture_id": "speaker_floor", "cell": [18, 10], "rotation": 0, "paid": 0})
	var cov: Dictionary = _compute(inst)
	assert_eq(cov["viewing_count"], 403)
	assert_eq((cov["sound_tiles"] as Array).size(), 313)
	assert_eq(cov["sound_bp"], 7766)


func test_compute_is_pure() -> void:
	var inst: Array = _layout_instances("baseline_show")
	var copy: Array = inst.duplicate(true)
	var a: Dictionary = _compute(inst)
	var b: Dictionary = _compute(inst)
	assert_eq(JSON.stringify(a), JSON.stringify(b), "같은 입력 → 같은 출력")
	assert_eq(inst, copy, "입력 불변")
	# 설정도 그대로(다른 레이아웃 결과가 바뀌지 않는다).
	assert_eq(_compute([])["floor_free"], _cfg.layout("empty_room")["expected"]["floor_free"])


func test_line_bc24_and_pseudocode() -> void:
	var l: Array = Coverage.line([4, 1], [12, 20])
	assert_eq(l.slice(0, 8), [[4, 1], [4, 2], [5, 3], [5, 4], [6, 5], [6, 6], [7, 7], [7, 8]], "부록 A 검증 예")
	assert_true(l.has([7, 8]), "기둥 [7,8] 을 지난다")
	assert_eq(l.back(), [12, 20])
	var straight: Array = Coverage.line([12, 1], [12, 20])
	assert_eq(straight.size(), 20)
	for i: int in straight.size():
		assert_eq(straight[i], [12, 1 + i])
	assert_eq(Coverage.line([3, 3], [3, 3]), [[3, 3]], "한 점")
	# 4방향 모두 끝점 포함, 한 걸음은 8-이웃.
	for b: Array in [[0, 0], [9, 2], [-4, 7], [5, -6]]:
		var ray: Array = Coverage.line([1, 1], b)
		assert_eq(ray[0], [1, 1])
		assert_eq(ray.back(), b)
		for i: int in range(1, ray.size()):
			assert_lte(absi(ray[i][0] - ray[i - 1][0]), 1)
			assert_lte(absi(ray[i][1] - ray[i - 1][1]), 1)


func test_ratio_bp_floor_and_zero() -> void:
	assert_eq(Coverage.ratio_bp(96, 405, 10000), 2370)
	assert_eq(Coverage.ratio_bp(5, 0, 10000), 0, "분모 0 → 0")


func test_sight_block_furniture_blocks_but_stage_does_not() -> void:
	var stage: Dictionary = {"entity_id": "f1", "furniture_id": "stage_small", "cell": [10, 20], "rotation": 0, "paid": 0}
	assert_true(_cfg.furniture("speaker_stack")["effects"]["sight_block"], "전제")
	var base: Dictionary = _compute([stage])
	assert_true((base["sight_tiles"] as Array).has([12, 10]), "무대 자신은 차단하지 않는다")
	var cov: Dictionary = _compute([stage, {"entity_id": "f2", "furniture_id": "speaker_stack", "cell": [12, 15], "rotation": 0, "paid": 0}])
	assert_false((cov["sight_tiles"] as Array).has([12, 10]), "sight_block 가구 뒤는 안 보인다")
	assert_true((cov["viewing_tiles"] as Array).has([12, 10]))


func test_unreachable_hole_excluded() -> void:
	var inst: Array = []
	var n: int = 0
	for c: Array in [[4, 5], [6, 5], [5, 4], [5, 6]]:
		n += 1
		inst.append({"entity_id": "f%d" % n, "furniture_id": "speaker_floor", "cell": c, "rotation": 0, "paid": 0})
	var empty: int = _compute([])["floor_free"]
	assert_eq(_compute(inst)["floor_free"], empty - 4 - 1, "갇힌 빈 타일 [5,5] 는 R 밖 → 수용에서 빠진다")


func test_capacity_clamped_and_bonus_capped() -> void:
	var cap_max: int = _cfg.capacity_max
	var bench: Dictionary = _cfg.furniture("bench")
	var inst: Array = []
	var z: int = 3
	while true:
		var cov: Dictionary = _compute(inst)
		if cov["capacity"] >= cap_max:
			break
		inst.append({"entity_id": "f%d" % (inst.size() + 1), "furniture_id": "bench", "cell": [3, z], "rotation": 0, "paid": 0})
		z += 2
	inst.append({"entity_id": "f%d" % (inst.size() + 1), "furniture_id": "bench", "cell": [3, z], "rotation": 0, "paid": 0})
	assert_eq(_compute(inst)["capacity"], cap_max, "C4 상한 capacity_max")
	assert_gt(int(bench["effects"]["capacity_add"]), 0)
	var cap_bp: int = _cfg.furniture_table.satisfaction_bonus_cap_bp
	var bonus: int = _cfg.furniture("toilet_booth")["effects"]["satisfaction_bonus_bp"]
	var toilets: Array = []
	for i: int in cap_bp / bonus + 1:
		toilets.append({"entity_id": "f%d" % (i + 1), "furniture_id": "toilet_booth", "cell": [1 + i, 21], "rotation": 0, "paid": 0})
	assert_eq(_compute(toilets)["satisfaction_bonus_bp"], cap_bp, "C7 상한")


func test_evac_light_upkeep_sums() -> void:
	var inst: Array = [
		{"entity_id": "f1", "furniture_id": "exit_door", "cell": [3, 22], "rotation": 0, "paid": 0},
		{"entity_id": "f2", "furniture_id": "light_moving_head", "cell": [5, 5], "rotation": 0, "paid": 0},
		{"entity_id": "f3", "furniture_id": "fog_machine", "cell": [6, 5], "rotation": 0, "paid": 0},
	]
	var cov: Dictionary = _compute(inst)
	var door: Dictionary = _cfg.furniture("exit_door")
	var head: Dictionary = _cfg.furniture("light_moving_head")
	var fog: Dictionary = _cfg.furniture("fog_machine")
	assert_eq(cov["evac_capacity"], _cfg.map.evac_total + int(door["effects"]["evac_capacity"]))
	assert_eq(cov["light_grade"], int(head["effects"]["light_grade"]) + int(fog["effects"]["light_grade"]))
	assert_eq(cov["upkeep_per_day"], int(door["upkeep_per_day"]) + int(head["upkeep_per_day"]) + int(fog["upkeep_per_day"]))
	assert_eq(cov["evac_shortfall"], maxi(0, cov["capacity"] - cov["evac_capacity"]))
