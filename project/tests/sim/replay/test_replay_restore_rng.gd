extends GutTest
## SE-034-bug 회귀 — TickLoop.restore 뒤 RNG 객체 유지(tick.md SH6 "복원 후 진행 = 연속 진행", audience.md R5).
## qa 재현(docs/tickets/SE-034-bug.md) 그대로: rookie_baseline·시드 0, 1일차 close 저장 S →
##   A 연속 진행 / B 새 루프(다른 시드)에 로드 / C 같은 루프를 2일차까지 돌린 뒤 S 로 되돌려 로드 → 2일차.
## 2일차 입장 뽑기(noise_bp·admissions·by_type), 요약, 뽑기 뒤 loop.rng 상태, 2일차 close 재저장의 rng 가 A 와 같아야 한다.
## 수정 전(rng = new_rng 교체)에는 B·C 의 noise_bp 가 A 와 달라 실패한다(qa 측정 413 / 228 / 642).

var _h: AudienceHarness
var _sc: Dictionary


func before_all() -> void:
	_h = AudienceHarness.new()
	_sc = _h.acfg.scenario("rookie_baseline")


func _next_day(loop: TickLoop) -> void:
	loop.bus.publish("time.next_day_requested", {})
	loop.advance(_h.scfg.day_ticks)


## rec 에서 day 의 이벤트 페이로드(없으면 {}).
func _of_day(rec: EventRecorder, name: String, day: int) -> Dictionary:
	for p: Dictionary in rec.of(name):
		if int(p["day"]) == day:
			return p
	return {}


## 2일차 결과 묶음.
func _day2(l: Dictionary) -> Dictionary:
	var loop: TickLoop = l["loop"]
	return {
		"adm": _of_day(l["rec"], "audience.admissions_decided", 2),
		"sum": _of_day(l["rec"], "audience.day_summary", 2),
		"rng": loop.rng.get_state(),
		"resave_rng": AudienceHarness.rt(loop.snapshot())["rng"],
	}


func _assert_same(got: Dictionary, want: Dictionary, label: String) -> void:
	assert_false((got["adm"] as Dictionary).is_empty(), "%s: 2일차 admissions_decided" % label)
	for k: String in ["noise_bp", "admissions", "by_type", "expected", "capped_by"]:
		assert_eq(got["adm"].get(k), want["adm"][k], "%s: 2일차 %s" % [label, k])
	assert_eq(AudienceHarness.hash_of(got["sum"]), AudienceHarness.hash_of(want["sum"]), "%s: 2일차 day_summary" % label)
	assert_eq(got["rng"], want["rng"], "%s: 2일차 뽑기 뒤 loop.rng 상태" % label)
	assert_eq(got["resave_rng"], want["resave_rng"], "%s: 로드 뒤 다시 저장한 rng = 연속 진행 저장본" % label)


func test_load_then_next_evening_matches_continuous() -> void:
	# A 연속 진행
	var a: Dictionary = _h.scenario_loop(_sc)
	var la: TickLoop = a["loop"]
	la.advance(_h.scfg.day_ticks)
	assert_eq(la.phase, "close", "전제: 1일차 close")
	var s: Dictionary = AudienceHarness.rt(la.snapshot())
	_next_day(la)
	var want: Dictionary = _day2(a)
	assert_eq(int(want["adm"]["day"]), 2, "전제: A 2일차 결정")

	# B 새 루프(다른 시드)에 로드
	var b: Dictionary = _h.looped(int(_sc["seed"]) + 777, _sc["lineup"], "")
	var lb: TickLoop = b["loop"]
	var held: SeededRng = lb.rng
	assert_true(lb.restore(s), "B restore")
	assert_true(lb.rng == held, "B: restore 뒤 loop.rng 객체 유지")
	assert_true((b["aud"] as AudienceSystem).rng == lb.rng, "B: AudienceSystem.rng == loop.rng")
	assert_eq(lb.rng.get_state(), s["rng"], "B: 복원 직후 rng 상태 = 저장본")
	assert_eq(lb.master_seed, int(s["seed"]), "B: master_seed = 저장본 seed")
	assert_eq(lb.rng.master_seed, int(s["seed"]), "B: SeededRng.master_seed = 저장본 seed")
	_next_day(lb)
	_assert_same(_day2(b), want, "B 새 루프 로드")

	# C 같은 루프를 2일차까지 돌린 뒤 S 로 되돌려 로드
	var c: Dictionary = _h.scenario_loop(_sc)
	var lc: TickLoop = c["loop"]
	lc.advance(_h.scfg.day_ticks)
	_next_day(lc)
	var held_c: SeededRng = lc.rng
	assert_true(lc.restore(s), "C restore")
	assert_true(lc.rng == held_c and (c["aud"] as AudienceSystem).rng == lc.rng, "C: 객체 유지")
	(c["rec"] as EventRecorder).clear()
	_next_day(lc)
	_assert_same(_day2(c), want, "C 되돌림 로드")


## AC4(SH3): 거부되는 restore 는 rng 객체·상태·시드를 바꾸지 않는다.
func test_rejected_restore_keeps_rng() -> void:
	var a: Dictionary = _h.scenario_loop(_sc)
	var la: TickLoop = a["loop"]
	la.advance(_h.scfg.day_ticks)
	var good: Dictionary = AudienceHarness.rt(la.snapshot())
	var b: Dictionary = _h.looped(int(_sc["seed"]) + 777, _sc["lineup"], "")
	var lb: TickLoop = b["loop"]
	var held: SeededRng = lb.rng
	var before: Dictionary = lb.rng.get_state()
	var seed_before: int = lb.master_seed
	var bad_state: Dictionary = good.duplicate(true)
	bad_state["rng"]["audience"] = "x"
	assert_false(lb.restore(bad_state), "rng 상태 형식 오류 → false")
	assert_push_error_count(2, "SeededRng.set_state 1 + TickLoop 1")
	var bad_seed: Dictionary = good.duplicate(true)
	bad_seed["seed"] = -1
	assert_false(lb.restore(bad_seed), "seed 범위 밖 → false")
	assert_push_error_count(3)
	var bad_sys: Dictionary = good.duplicate(true)
	bad_sys["systems"]["audience"]["phase"] = "noon"
	assert_false(lb.restore(bad_sys), "시스템 훅 실패(7단계) → false")
	assert_push_error_count(5, "audience RU1 + TickLoop")
	assert_true(lb.rng == held, "객체 유지")
	assert_eq(lb.rng.get_state(), before, "rng 상태 불변")
	assert_eq([lb.master_seed, lb.rng.master_seed], [seed_before, seed_before], "시드 불변")
