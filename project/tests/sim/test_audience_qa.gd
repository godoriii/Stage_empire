extends GutTest
## SE-034 qa 추가 테스트(변이 M6 "blocked_cells 무시" 가 기존 30건을 전부 통과해 드러난 공백을 메운다).
## 기준: 티켓 "SE-034 인계 확정" 3·4 — 점유 입력은 build.coverage_changed.blocked_cells 와 스냅샷 coverage.blocked_cells 뿐이고,
## 그 셀은 관객이 지나가지 않는다. 기존 test_au10a_paths_after_restore_avoid_blocked_cells 는 관람 자리를 손으로 좁힌 케이스라
## 열린 바닥에서는 최단 경로가 가구를 지나지 않아 변이를 잡지 못한다. 여기서는 기준 배치 하루 전체에서 표시 좌표를 본다.

var _h: AudienceHarness


func before_all() -> void:
	_h = AudienceHarness.new()


func _blocked(cov: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for c: Array in cov["blocked_cells"]:
		out[Vector2i(int(c[0]), int(c[1]))] = true
	return out


## agent_moved 표시 좌표가 가리키는 타일(`px ÷ pos_scale`)이 막힌 타일인 원소 수와 전체 원소 수.
func _on_blocked(moved: Array, blocked: Dictionary) -> Array:
	var bad: int = 0
	var total: int = 0
	var ps: int = _h.acfg.pos_scale
	for m: Dictionary in moved:
		for e: Array in m["agents"]:
			total += 1
			if e[3] == "queued":
				continue
			if blocked.has(Vector2i(int(e[1]) / ps, int(e[2]) / ps)):
				bad += 1
	return [bad, total]


## 연속 진행 하루: 이벤트로 받은 blocked_cells 가 경로에 반영된다(생성자·이벤트 경로).
func test_qa_full_day_never_walks_through_furniture() -> void:
	var blocked: Dictionary = _blocked(_h.coverage_payload("baseline_show"))
	assert_gt(blocked.size(), 0, "전제: 기준 배치에 막힌 셀이 있다")
	for sid: String in ["local_top_baseline", "rookie_baseline"]:
		var l: Dictionary = _h.scenario_loop(_h.acfg.scenario(sid))
		(l["loop"] as TickLoop).advance(_h.scfg.day_ticks)
		var r: Array = _on_blocked((l["rec"] as EventRecorder).of("audience.agent_moved"), blocked)
		assert_gt(int(r[1]), 10000, "%s: 표본이 충분하다(%d)" % [sid, r[1]])
		assert_eq(r[0], 0, "%s: 막힌 타일 위 표본 0 (blocked_cells 반영)" % sid)


## 복원 경로: 저녁 중간 스냅샷을 커버리지 이벤트 없이 복원한 시스템도 coverage.blocked_cells 로 경로를 만든다.
func test_qa_restored_system_never_walks_through_furniture() -> void:
	var sc: Dictionary = _h.acfg.scenario("rookie_baseline")
	var cov: Dictionary = _h.coverage_payload("baseline_show")
	var blocked: Dictionary = _blocked(cov)
	var ua: Dictionary = _h.unit(int(sc["seed"]))
	_h.decide(ua, sc, cov)
	_h.run(ua["aud"], "evening", 0, 100)
	var snap: Dictionary = AudienceHarness.rt((ua["aud"] as AudienceSystem).snapshot())
	var ub: Dictionary = _h.unit(int(sc["seed"]) + 1)
	assert_true((ub["aud"] as AudienceSystem).restore(snap), "restore")
	var evening: int = _h.scfg.phase_ticks("evening")
	_h.run(ub["aud"], "evening", 100, evening)
	AudienceHarness.phase(ub["bus"], "evening", "show")
	_h.run(ub["aud"], "show", 0, _h.scfg.phase_ticks("show"))
	AudienceHarness.phase(ub["bus"], "show", "close")
	var r: Array = _on_blocked((ub["rec"] as EventRecorder).of("audience.agent_moved"), blocked)
	assert_gt(int(r[1]), 5000, "표본이 충분하다(%d)" % r[1])
	assert_eq(r[0], 0, "복원 뒤 막힌 타일 위 표본 0")
