extends GutTest
## SE-003 AC5: PerfStats 가 프레임 시간 배열에서 평균 fps·1% low·평균/최대 ms 를 손계산과 ±0.01 로 맞춘다.
## + 측정 리포트(SpikeMeasure.build_report)의 필수 키·관문 판정(AC6 의 헤드리스로 확인 가능한 부분).
## SE-013 AC7(단축 실행 무효), AC8(GPU 타이밍 가용 여부), AC9(-dirty 는 project/·tools/ 만).

const TOL: float = 0.01
const SETTINGS_PATH: String = "res://view/perf/spike_configs.tres"
const MEASURE_SCRIPT: String = "res://tests/view/perf/measure_spike.gd"


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


## 측정 조건을 지킨 실행으로 가정한 환경(헤드리스 아님, VSync off, forward_plus, 1920x1080).
func _valid_env(real_env: Dictionary) -> Dictionary:
	var env: Dictionary = real_env.duplicate()
	env.merge({"headless": false, "vsync": "off", "renderer": "forward_plus",
		"resolution": "1920x1080", "requested_resolution": "1920x1080"}, true)
	return env


## 티켓 정상값: 예열 10 s / 120 프레임 / 측정 30 s.
func _valid_monitors() -> Dictionary:
	return {"draw_calls": 40, "primitives": 3500000, "avg_gpu_ms": 9.0, "avg_crowd_update_ms": 4.0, "avg_render_cpu_ms": 2.0,
		"warmup_sec": 10.0, "warmup_frames": 120, "measure_sec": 30.0}


func test_report_has_required_keys_and_gate() -> void:
	var settings: SpikeConfigSet = load(SETTINGS_PATH) as SpikeConfigSet
	var real_env: Dictionary = SpikeMeasure.collect_environment(get_tree().root, settings.resolution, SpikeMeasure.resolve_commit(PackedStringArray()))
	var env: Dictionary = _valid_env(real_env)
	var monitors: Dictionary = _valid_monitors()
	# 관문 구성 E: 16.6 ms(60.24 fps) → 통과, 59.5 fps → 실패.
	var gate_cfg: SpikeConfig = settings.get_config(settings.gate_config_id)
	var pass_stats: PerfStats = PerfStats.from_frame_times(_repeat(16.6, 100))
	var r: Dictionary = SpikeMeasure.build_report(pass_stats, gate_cfg, settings, env, monitors)
	for k: String in SpikeMeasure.REQUIRED_KEYS:
		assert_true(r.has(k), "리포트 필수 키 %s" % k)
	for k: String in ["gpu_timing_available", "gpu_timing_note", "crowd_cast_shadow"]:
		assert_true(r.has(k), "SE-013 키 %s" % k)
	assert_false(r["crowd_cast_shadow"], "monitors 에 실제 값이 없으면 구성 값(E = false)")
	assert_eq(r["config"], "E")
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
	assert_eq(SpikeMeasure.run_issues(pass_stats, vs, monitors, settings).size(), 1, "VSync on")
	var gl: Dictionary = env.duplicate()
	gl["renderer"] = "gl_compatibility"
	assert_eq(SpikeMeasure.run_issues(pass_stats, gl, monitors, settings).size(), 1, "gl_compatibility")
	var small: Dictionary = env.duplicate()
	small["resolution"] = "1366x768"
	assert_eq(SpikeMeasure.run_issues(pass_stats, small, monitors, settings).size(), 1, "해상도 불일치")

	var row: String = SpikeMeasure.format_table_row(r)
	assert_true(row.begins_with("| E | 5000 | 32 | 8 | 60.2 | 60.2 | 16.60 | 16.60 | 40 | 3500000 |"), "결과 표 행 형식: %s" % row)


# --- SE-013 AC7 -----------------------------------------------------------

func test_run_issues_flags_shortened_runs() -> void:
	var settings: SpikeConfigSet = load(SETTINGS_PATH) as SpikeConfigSet
	# 이 테스트의 기준값이 티켓 값과 같은지 먼저(구현 리소스와 독립인 리터럴).
	assert_eq(settings.warmup_sec, 10.0)
	assert_eq(settings.warmup_min_frames, 120)
	assert_eq(settings.measure_sec, 30.0)
	var stats: PerfStats = PerfStats.from_frame_times(_repeat(16.6, 100))
	var env: Dictionary = _valid_env(SpikeMeasure.collect_environment(get_tree().root, settings.resolution, "test"))
	var ok: Dictionary = _valid_monitors()
	var none: PackedStringArray = SpikeMeasure.run_issues(stats, env, ok, settings)
	assert_eq(none.size(), 0, "정상값이면 0건: %s" % ", ".join(none))

	# 단축 한 항목씩: 각각 정확히 1건, 메시지에 실제값과 기준값.
	var cases: Array = [
		["warmup_sec", 9.9, "9.9", "10"],
		["warmup_frames", 119, "119", "120"],
		["measure_sec", 29.9, "29.9", "30"],
	]
	for c: Array in cases:
		var m: Dictionary = ok.duplicate()
		m[c[0]] = c[1]
		var issues: PackedStringArray = SpikeMeasure.run_issues(stats, env, m, settings)
		assert_eq(issues.size(), 1, "%s = %s → 1건: %s" % [c[0], c[1], ", ".join(issues)])
		if issues.size() == 1:
			assert_string_contains(issues[0], c[2], "%s 실제값" % c[0])
			assert_string_contains(issues[0], c[3], "%s 기준값" % c[0])
		var r: Dictionary = SpikeMeasure.build_report(stats, settings.get_config(settings.gate_config_id), settings, env, m)
		assert_false(r["run_valid"], "%s 단축 → run_valid false" % c[0])
		assert_eq(r["gate"]["verdict"], "무효", "%s 단축 → 관문 무효" % c[0])
	# 기준과 같으면 위반 아님(경계값).
	var exact: Dictionary = ok.duplicate()
	exact.merge({"warmup_sec": settings.warmup_sec, "warmup_frames": settings.warmup_min_frames, "measure_sec": settings.measure_sec}, true)
	assert_eq(SpikeMeasure.run_issues(stats, env, exact, settings).size(), 0, "기준값과 같으면 0건")
	# 측정 길이 키가 없으면 단축으로 본다(3건).
	assert_eq(SpikeMeasure.run_issues(stats, env, {}, settings).size(), 3, "길이 키 없음 → 3건")

	# 기존 4 케이스는 그대로 1건씩(VSync on, gl_compatibility, 해상도 불일치, 헤드리스).
	var variants: Array = [["vsync", "on"], ["renderer", "gl_compatibility"], ["resolution", "1366x768"], ["headless", true]]
	for v: Array in variants:
		var e: Dictionary = env.duplicate()
		e[v[0]] = v[1]
		assert_eq(SpikeMeasure.run_issues(stats, e, ok, settings).size(), 1, "%s = %s → 1건" % [v[0], v[1]])
	# 샘플 없음도 1건.
	assert_eq(SpikeMeasure.run_issues(PerfStats.from_frame_times([]), env, ok, settings).size(), 1, "샘플 없음 → 1건")


# --- SE-013 AC8 -----------------------------------------------------------

func test_gpu_timing_availability_flag() -> void:
	var settings: SpikeConfigSet = load(SETTINGS_PATH) as SpikeConfigSet
	var stats: PerfStats = PerfStats.from_frame_times(_repeat(16.6, 100))
	var env: Dictionary = _valid_env(SpikeMeasure.collect_environment(get_tree().root, settings.resolution, "test"))
	var cfg: SpikeConfig = settings.get_config("E")

	var with_gpu: Dictionary = _valid_monitors()
	with_gpu["avg_gpu_ms"] = 9.0
	var r1: Dictionary = SpikeMeasure.build_report(stats, cfg, settings, env, with_gpu)
	assert_typeof(r1["gpu_timing_available"], TYPE_BOOL)
	assert_true(r1["gpu_timing_available"], "avg_gpu_ms > 0 → 가용")
	assert_eq(r1["gpu_timing_note"], "", "가용이면 빈 문자열")
	assert_ne(r1["bound_hint"], "unknown")

	var metal_env: Dictionary = env.duplicate()
	metal_env["rendering_driver"] = "metal"
	var no_gpu: Dictionary = _valid_monitors()
	no_gpu["avg_gpu_ms"] = 0.0
	var r0: Dictionary = SpikeMeasure.build_report(stats, cfg, settings, metal_env, no_gpu)
	assert_false(r0["gpu_timing_available"], "avg_gpu_ms == 0 → 불가")
	assert_false(String(r0["gpu_timing_note"]).is_empty(), "이유가 남는다")
	assert_string_contains(r0["gpu_timing_note"], "metal", "드라이버 이름 포함")
	assert_eq(r0["bound_hint"], "unknown")
	assert_true(r0["run_valid"], "GPU 타이밍 없음은 측정 조건 위반이 아니다")

	# 실제 환경 드라이버 이름도 그대로 들어간다.
	var r_real: Dictionary = SpikeMeasure.build_report(stats, cfg, settings, env, no_gpu)
	assert_string_contains(r_real["gpu_timing_note"], str(env["rendering_driver"]))


# --- SE-013 AC9 -----------------------------------------------------------

func test_dirty_only_from_project_and_tools() -> void:
	assert_false(SpikeMeasure.is_dirty_status(PackedStringArray()), "빈 배열 → 깨끗")
	assert_false(SpikeMeasure.is_dirty_status(PackedStringArray(["", "  ", "\t"])), "공백뿐 → 깨끗")
	assert_true(SpikeMeasure.is_dirty_status(PackedStringArray([" M project/view/perf/spike_crowd.gd"])), "project 수정 → 더티")
	assert_true(SpikeMeasure.is_dirty_status(PackedStringArray(["", "?? tools/new_tool.py", ""])), "빈 줄 사이 변경 → 더티")
	# resolve_commit 은 git status 를 pathspec project·tools 로 제한한다(측정 JSON 은 docs/ 라 제외).
	var src: String = FileAccess.get_file_as_string(MEASURE_SCRIPT)
	assert_true(src.contains("\"status\", \"--porcelain\", \"--\", \"project\", \"tools\""),
		"resolve_commit: git status --porcelain -- project tools")
	assert_true(src.contains("is_dirty_status(str(status[0])"), "resolve_commit 이 is_dirty_status 로 판정")
	# --commit= 인자가 있으면 그대로 쓴다(git 안 봄).
	assert_eq(SpikeMeasure.resolve_commit(PackedStringArray(["--commit=abc123"])), "abc123")


func test_bound_hint() -> void:
	assert_eq(SpikeMeasure.bound_hint(0.0, 5.0, 1.0), "unknown", "GPU 시간 못 재면 unknown")
	assert_eq(SpikeMeasure.bound_hint(10.0, 5.0, 1.0), "gpu")
	assert_eq(SpikeMeasure.bound_hint(5.0, 5.0, 1.0), "cpu")
