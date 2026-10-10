extends GutTest
## SE-034 AC7 / audience.md AU11 — 150 명(수용 150·인기 100·명성 2,000, AU3 의 상한 조건) 저녁 600 + 공연 900 틱 헤드리스
## 벽시계 측정. 단언은 한 틱 평균 ≤ 5 ms(목표 ≤ 2 ms 는 qa 리포트 기록용, 티켓 Q11). 측정 대상은 AudienceSystem.update(ctx)
## 한 번(agent_moved 발행·버스 페이로드 검사·복사 포함, 구독자 없음). 실측값은 gut.p 로 남긴다(docs/reports/SE-034.md 용).

## AC7 단언 임계(ms/틱, 티켓 수용 기준 값).
const ASSERT_MS_PER_TICK: float = 5.0
## 목표(ms/틱, 리포트 기록용 — 단언하지 않는다).
const TARGET_MS_PER_TICK: float = 2.0
const US_PER_MS: float = 1000.0


func test_au11_perf_150_agents() -> void:
	var h: AudienceHarness = AudienceHarness.new()
	var cfg: AudienceConfig = h.acfg
	var u: Dictionary = h.unit(0)
	var aud: AudienceSystem = u["aud"]
	var lu: Dictionary = cfg.scenario("rookie_baseline")["lineup"].duplicate()
	lu["popularity"] = cfg.stat_max
	var cov: Dictionary = h.coverage_payload("baseline_show")
	cov["capacity"] = cfg.max_agents
	h.decide(u, {"reputation_total": cfg.reputation_cap, "ticket_price": cfg.price_ref, "lineup": lu}, cov)
	assert_eq(aud.today["admissions"], cfg.max_agents, "전제: 150 명")
	# 기록기 없는 버스의 새 시스템에 같은 상태를 복원해 구독자 비용을 뺀다(버스 검사·복사는 남는다).
	var bus: EventBus = EventBus.new()
	var timed: AudienceSystem = AudienceSystem.new(cfg, bus, SeededRng.new(0, h.scfg.rng_streams), h.map)
	assert_true(timed.restore(aud.snapshot()), "같은 상태를 구독자 없는 버스의 시스템으로")
	var total_us: int = 0
	var max_us: int = 0
	var show_us: int = 0
	var peak: int = 0
	var evening: int = h.scfg.phase_ticks("evening")
	var show: int = h.scfg.phase_ticks("show")
	for tip: int in evening:
		var t0: int = Time.get_ticks_usec()
		timed.update(h.ctx(1, "evening", tip))
		var dt: int = Time.get_ticks_usec() - t0
		total_us += dt
		max_us = maxi(max_us, dt)
		peak = maxi(peak, timed.agents().size())
	AudienceHarness.phase(bus, "evening", "show")
	peak = maxi(peak, timed.agents().size())
	for tip: int in show:
		var t0: int = Time.get_ticks_usec()
		timed.update(h.ctx(1, "show", tip))
		var dt: int = Time.get_ticks_usec() - t0
		total_us += dt
		show_us += dt
		max_us = maxi(max_us, dt)
	var ticks: int = evening + show
	var avg_ms: float = total_us / US_PER_MS / ticks
	var show_ms: float = show_us / US_PER_MS / show
	gut.p("AU11 실측: 150 명, %d 틱, 평균 %.3f ms/틱 (저녁+공연), 공연 평균 %.3f ms/틱, 최대 %.3f ms, 목표 %.1f / 단언 %.1f ms"
		% [ticks, avg_ms, show_ms, max_us / US_PER_MS, TARGET_MS_PER_TICK, ASSERT_MS_PER_TICK])
	assert_eq(peak, cfg.max_agents, "측정 중 동시 에이전트 150")
	assert_lte(avg_ms, ASSERT_MS_PER_TICK, "한 틱 평균 ≤ 5 ms")
	assert_lte(show_ms, ASSERT_MS_PER_TICK, "공연 구간 한 틱 평균 ≤ 5 ms")
