extends GutTest
## SE-003 AC5: PerfStats 가 프레임 시간 배열에서 평균 fps·1% low·평균/최대 ms 를 손계산과 ±0.01 로 맞춘다.
## + 측정 리포트(SpikeMeasure.build_report)의 필수 키·관문 판정(AC6 의 헤드리스로 확인 가능한 부분).

const TOL: float = 0.01
const SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"


func _repeat(value: float, count: int) -> Array:
	var out: Array = []
	for i: int in range(count):
		out.append(value)
	return out


## 느린 프레임을 배열 가운데 섞어 넣는다(정렬을 실제로 하는지 확인).
func _with_spikes(base: Array, spikes: Array) -> Array:
	var out: Array = base.duplicate()
	for j: int in range(spikes.size()):
		out.insert((j * 37 + 11) % (out.size() + 1), spikes[j])
	return out


func test_stats_from_known_frame_times() -> void:
	# 1) 100 프레임: 99 × 10 ms + 50 ms. 합 1040 → 평균 10.4 ms → 96.1538 fps.
	#    1% low: k = ceil(100 × 0.01) = 1 → 50 ms → 20 fps. 최대 50 ms.
	var s1: PerfStats = PerfStats.from_frame_times(_with_spikes(_repeat(10.0, 99), [50.0]))
	assert_true(s1.valid)
	assert_eq(s1.sample_count, 100)
	assert_almost_eq(s1.avg_frame_ms, 10.4, TOL)
	assert_almost_eq(s1.avg_fps, 96.1538, TOL)
	assert_eq(s1.p1_low_count, 1)
	assert_almost_eq(s1.p1_low_fps, 20.0, TOL)
	assert_almost_eq(s1.max_frame_ms, 50.0, TOL)

	# 2) 200 프레임: 196 × 16 ms + {40, 30, 25, 20}. 합 3136 + 115 = 3251 → 평균 16.255 ms → 61.5195 fps.
	#    k = ceil(2.0) = 2 → (40 + 30) / 2 = 35 ms → 28.5714 fps. 최대 40 ms.
	var s2: PerfStats = PerfStats.from_frame_times(_with_spikes(_repeat(16.0, 196), [25.0, 40.0, 20.0, 30.0]))
	assert_eq(s2.sample_count, 200)
	assert_almost_eq(s2.avg_frame_ms, 16.255, TOL)
	assert_almost_eq(s2.avg_fps, 61.5195, TOL)
	assert_eq(s2.p1_low_count, 2)
	assert_almost_eq(s2.p1_low_frame_ms, 35.0, TOL)
	assert_almost_eq(s2.p1_low_fps, 28.5714, TOL)
	assert_almost_eq(s2.max_frame_ms, 40.0, TOL)

	# 3) 250 프레임(올림 확인): 247 × 20 ms + {100, 60, 50}. 합 4940 + 210 = 5150 → 20.6 ms → 48.5437 fps.
	#    k = ceil(2.5) = 3 → (100 + 60 + 50) / 3 = 70 ms → 14.2857 fps. 최대 100 ms.
	var s3: PerfStats = PerfStats.from_frame_times(_with_spikes(_repeat(20.0, 247), [60.0, 100.0, 50.0]))
	assert_eq(s3.sample_count, 250)
	assert_almost_eq(s3.avg_frame_ms, 20.6, TOL)
	assert_almost_eq(s3.avg_fps, 48.5437, TOL)
	assert_eq(s3.p1_low_count, 3)
	assert_almost_eq(s3.p1_low_fps, 14.2857, TOL)
	assert_almost_eq(s3.max_frame_ms, 100.0, TOL)

	# 4) 3 프레임(최소 1개): [30, 10, 20] → 평균 20 ms → 50 fps, k = 1 → 30 ms → 33.3333 fps.
	var s4: PerfStats = PerfStats.from_frame_times([30.0, 10.0, 20.0])
	assert_almost_eq(s4.avg_fps, 50.0, TOL)
	assert_eq(s4.p1_low_count, 1)
	assert_almost_eq(s4.p1_low_fps, 33.3333, TOL)
	assert_almost_eq(s4.max_frame_ms, 30.0, TOL)
	assert_almost_eq(s4.min_frame_ms, 10.0, TOL)


func test_empty_input_is_invalid() -> void:
	var s: PerfStats = PerfStats.from_frame_times([])
	assert_false(s.valid)
	assert_eq(s.sample_count, 0)
	assert_eq(s.avg_fps, 0.0)
	assert_eq(s.p1_low_fps, 0.0)


func test_accepts_packed_arrays_and_does_not_mutate_input() -> void:
	var src: PackedFloat64Array = PackedFloat64Array([20.0, 10.0, 30.0])
	var s: PerfStats = PerfStats.from_frame_times(src)
	assert_almost_eq(s.avg_fps, 50.0, TOL)
	assert_eq(src, PackedFloat64Array([20.0, 10.0, 30.0]), "입력 배열 순서를 바꾸지 않는다")
	var s32: PerfStats = PerfStats.from_frame_times(PackedFloat32Array([20.0, 10.0, 30.0]))
	assert_almost_eq(s32.p1_low_fps, 33.3333, TOL)


func test_report_has_required_keys_and_gate() -> void:
	var settings: SpikeConfigSet = load(SETTINGS_PATH) as SpikeConfigSet
	var real_env: Dictionary = SpikeMeasure.collect_environment(get_tree().root, settings.resolution, SpikeMeasure.resolve_commit(PackedStringArray()))
	# 측정 조건을 지킨 실행으로 가정한 환경(헤드리스 아님, VSync off, forward_plus, 1920x1080).
	var env: Dictionary = real_env.duplicate()
	env.merge({"headless": false, "vsync": "off", "renderer": "forward_plus",
		"resolution": "1920x1080", "requested_resolution": "1920x1080"}, true)
	var monitors: Dictionary = {"draw_calls": 40, "primitives": 3500000, "avg_gpu_ms": 9.0, "avg_crowd_update_ms": 4.0, "avg_render_cpu_ms": 2.0}
	# 관문 구성 B: 16.6 ms(60.24 fps) → 통과, 59.5 fps → 실패.
	var gate_cfg: SpikeConfig = settings.get_config(settings.gate_config_id)
	var pass_stats: PerfStats = PerfStats.from_frame_times(_repeat(16.6, 100))
	var r: Dictionary = SpikeMeasure.build_report(pass_stats, gate_cfg, settings, env, monitors)
	for k: String in SpikeMeasure.REQUIRED_KEYS:
		assert_true(r.has(k), "리포트 필수 키 %s" % k)
	assert_eq(r["config"], "B")
	assert_eq(r["instances"], gate_cfg.instances)
	assert_eq(r["shadow_lights"], gate_cfg.shadow_lights)
	assert_true(r["gate"]["applies"])
	assert_true(r["gate"]["pass"], "평균 60.24 ≥ 60 → 통과")
	assert_eq(r["gate"]["verdict"], "통과")
	assert_eq(r["bound_hint"], "gpu", "GPU 9 ms > CPU 4 + 2 ms")
	assert_false(String(r["commit"]).is_empty())
	assert_false(String(r["godot_version"]).is_empty())

	var fail_stats: PerfStats = PerfStats.from_frame_times(_repeat(1000.0 / (settings.gate_min_avg_fps - 0.5), 100))
	var rf: Dictionary = SpikeMeasure.build_report(fail_stats, gate_cfg, settings, env, monitors)
	assert_false(rf["gate"]["pass"])
	assert_eq(rf["gate"]["verdict"], "실패")

	var other: SpikeConfig = settings.get_config("A")
	var ra: Dictionary = SpikeMeasure.build_report(pass_stats, other, settings, env, monitors)
	assert_false(ra["gate"]["applies"], "관문 구성이 아니면 판정 대상 아님")
	assert_eq(ra["gate"]["verdict"], "해당 없음")

	assert_true(r["run_valid"])
	# 헤드리스 실제 환경 → 측정 조건 위반 → 숫자가 좋아도 "무효".
	var rh: Dictionary = SpikeMeasure.build_report(pass_stats, gate_cfg, settings, real_env, monitors)
	assert_true(real_env["headless"], "테스트는 헤드리스에서 돈다")
	assert_false(rh["run_valid"])
	assert_false(rh["gate"]["pass"])
	assert_eq(rh["gate"]["verdict"], "무효", "헤드리스 측정은 관문 판정에 못 쓴다")
	# VSync 켜짐 / 렌더러 / 해상도 위반을 각각 잡는다.
	var vs: Dictionary = env.duplicate()
	vs["vsync"] = "on"
	assert_eq(SpikeMeasure.run_issues(pass_stats, vs).size(), 1, "VSync on")
	var gl: Dictionary = env.duplicate()
	gl["renderer"] = "gl_compatibility"
	assert_eq(SpikeMeasure.run_issues(pass_stats, gl).size(), 1, "gl_compatibility")
	var small: Dictionary = env.duplicate()
	small["resolution"] = "1366x768"
	assert_eq(SpikeMeasure.run_issues(pass_stats, small).size(), 1, "해상도 불일치")

	var row: String = SpikeMeasure.format_table_row(r)
	assert_true(row.begins_with("| B | 5000 | 32 | 8 | 60.2 | 60.2 | 16.60 | 16.60 | 40 | 3500000 |"), "결과 표 행 형식: %s" % row)


func test_bound_hint() -> void:
	assert_eq(SpikeMeasure.bound_hint(0.0, 5.0, 1.0), "unknown", "GPU 시간 못 재면 unknown")
	assert_eq(SpikeMeasure.bound_hint(10.0, 5.0, 1.0), "gpu")
	assert_eq(SpikeMeasure.bound_hint(5.0, 5.0, 1.0), "cpu")
