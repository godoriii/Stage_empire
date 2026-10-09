class_name SpikeMeasure
extends Node
## SE-003 측정기. spike_crowd.tscn 을 `-- --measure` 로 실행하면 SpikeCrowd 가 이 노드를 자식으로 붙인다.
##
##   godot --path project res://view/perf/spike_crowd.tscn -- --measure --config=B [--out=<경로.json>] [--commit=<해시>]
##
## 절차: VSync 끄기 + max_fps 0 + 창 resolution(spike_configs.tres) → 예열(warmup_sec 이상 그리고 warmup_min_frames 이상)
## → measure_sec 동안 프레임마다 벽시계 프레임 시간(Time.get_ticks_usec 차이, delta 스무딩 영향 없음)과
## Performance/RenderingServer 수치 수집 → PerfStats → JSON 저장 + 콘솔 표 → 종료.
## 기본 출력: user://perf/SE-003_<config>.json (Linux: ~/.local/share/godot/app_userdata/Stage Empire/perf/).
## --warmup-sec= / --warmup-frames= / --measure-sec= 는 동작 확인용 단축 실행 전용이다. 관문 측정에는 쓰지 않는다(JSON 에 실제 값이 남는다).
## project.godot 은 바꾸지 않는다. 창·VSync 는 런타임에만 설정한다(AC9).

signal finished(report: Dictionary)

const TICKET: String = "SE-003"
const ARG_OUT: String = "--out="
const ARG_COMMIT: String = "--commit="
const ARG_WARMUP_SEC: String = "--warmup-sec="
const ARG_WARMUP_FRAMES: String = "--warmup-frames="
const ARG_MEASURE_SEC: String = "--measure-sec="
const DEFAULT_OUT_PATTERN: String = "user://perf/SE-003_%s.json"
## 티켓 측정 조건: forward_plus 렌더러.
const REQUIRED_RENDERER: String = "forward_plus"
const USEC_PER_MS: float = 1000.0
const MS_PER_SEC: float = 1000.0
const BYTES_PER_MB: float = 1048576.0
const BYTES_PER_GB: float = 1073741824.0

## 티켓 AC6 의 필수 키.
const REQUIRED_KEYS: PackedStringArray = [
	"config", "instances", "lights", "shadow_lights", "avg_fps", "p1_low_fps", "avg_frame_ms",
	"max_frame_ms", "draw_calls", "primitives", "resolution", "vsync", "renderer", "gpu", "cpu",
	"godot_version", "commit",
]

enum Phase { WARMUP, MEASURE, DONE }

## false 면 끝나도 종료하지 않는다(테스트용).
var auto_quit: bool = true
var out_path: String = ""
var warmup_sec: float = 0.0
var warmup_min_frames: int = 0
var measure_sec: float = 0.0

var _spike: Node
var _settings: SpikeConfigSet
var _config: SpikeConfig
var _phase: Phase = Phase.WARMUP
var _last_usec: int = 0
var _warm_frames: int = 0
var _warm_elapsed_sec: float = 0.0
var _measure_elapsed_sec: float = 0.0
var _frame_ms: PackedFloat64Array = PackedFloat64Array()
var _sums: Dictionary = {}
var _viewport_rid: RID


func setup(spike: Node, settings: SpikeConfigSet, config: SpikeConfig) -> void:
	_spike = spike
	_settings = settings
	_config = config
	warmup_sec = settings.warmup_sec
	warmup_min_frames = settings.warmup_min_frames
	measure_sec = settings.measure_sec
	out_path = DEFAULT_OUT_PATTERN % config.id
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with(ARG_OUT):
			out_path = a.trim_prefix(ARG_OUT)
		elif a.begins_with(ARG_WARMUP_SEC):
			warmup_sec = a.trim_prefix(ARG_WARMUP_SEC).to_float()
		elif a.begins_with(ARG_WARMUP_FRAMES):
			warmup_min_frames = a.trim_prefix(ARG_WARMUP_FRAMES).to_int()
		elif a.begins_with(ARG_MEASURE_SEC):
			measure_sec = a.trim_prefix(ARG_MEASURE_SEC).to_float()


func _ready() -> void:
	apply_display_settings()
	_viewport_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	_last_usec = Time.get_ticks_usec()
	print("SpikeMeasure: 구성 %s, 예열 %.1fs/%d프레임, 측정 %.1fs → %s" % [
		_config.id, warmup_sec, warmup_min_frames, measure_sec, ProjectSettings.globalize_path(out_path)])


## VSync off, 프레임 제한 없음, 창 크기 = settings.resolution. project.godot 은 건드리지 않는다.
func apply_display_settings() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	var win: Window = get_window()
	if win != null:
		# 테두리 없는 창: 1080p 모니터에서도 제목 표시줄 때문에 창이 줄어들지 않게. 실제 크기는 JSON resolution 에 남는다.
		win.mode = Window.MODE_WINDOWED
		win.borderless = true
		win.size = _settings.resolution
		win.position = DisplayServer.screen_get_position(win.current_screen)


func _process(_delta: float) -> void:
	var now: int = Time.get_ticks_usec()
	var dt_ms: float = float(now - _last_usec) / USEC_PER_MS
	_last_usec = now
	match _phase:
		Phase.WARMUP:
			_warm_frames += 1
			_warm_elapsed_sec += dt_ms / MS_PER_SEC
			if _warm_elapsed_sec >= warmup_sec and _warm_frames >= warmup_min_frames:
				_phase = Phase.MEASURE
		Phase.MEASURE:
			_frame_ms.append(dt_ms)
			_sample_monitors()
			_measure_elapsed_sec += dt_ms / MS_PER_SEC
			if _measure_elapsed_sec >= measure_sec:
				_finish()


func _sample_monitors() -> void:
	_add(&"draw_calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_add(&"primitives", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_add(&"objects", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_add(&"process_ms", Performance.get_monitor(Performance.TIME_PROCESS) * MS_PER_SEC)
	_add(&"crowd_update_ms", float(int(_spike.get("last_advance_usec"))) / USEC_PER_MS)
	_add(&"gpu_ms", RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid))
	_add(&"render_cpu_ms", RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid) + RenderingServer.get_frame_setup_time_cpu())
	_add(&"video_mem_mb", Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / BYTES_PER_MB)


func _add(key: StringName, v: float) -> void:
	_sums[key] = float(_sums.get(key, 0.0)) + v


func _avg(key: StringName) -> float:
	if _frame_ms.is_empty():
		return 0.0
	return float(_sums.get(key, 0.0)) / float(_frame_ms.size())


func _finish() -> void:
	_phase = Phase.DONE
	var stats: PerfStats = PerfStats.from_frame_times(_frame_ms)
	var monitors: Dictionary = {
		"draw_calls": roundi(_avg(&"draw_calls")),
		"primitives": roundi(_avg(&"primitives")),
		"objects": roundi(_avg(&"objects")),
		"avg_process_ms": _avg(&"process_ms"),
		"avg_crowd_update_ms": _avg(&"crowd_update_ms"),
		"avg_gpu_ms": _avg(&"gpu_ms"),
		"avg_render_cpu_ms": _avg(&"render_cpu_ms"),
		"video_mem_mb": _avg(&"video_mem_mb"),
		"warmup_sec": _warm_elapsed_sec,
		"warmup_frames": _warm_frames,
		"measure_sec": _measure_elapsed_sec,
		"instance_mesh_tris": int(_spike.call("get_instance_mesh_triangle_count")),
		"instance_count_actual": int(_spike.call("get_instance_count")),
		"shadow_lights_actual": int(_spike.call("get_shadow_light_count")),
	}
	var report: Dictionary = build_report(stats, _config, _settings,
		collect_environment(get_window(), _settings.resolution, resolve_commit(OS.get_cmdline_user_args())), monitors)
	var ok: bool = write_report(report, out_path)
	print(format_table_row(report))
	print("SpikeMeasure: 관문(%s 평균 ≥ %.0f fps): %s" % [_settings.gate_config_id, _settings.gate_min_avg_fps, report["gate"]["verdict"]])
	for issue: String in report["run_issues"]:
		print("SpikeMeasure: 측정 조건 위반: %s" % issue)
	finished.emit(report)
	if auto_quit:
		get_tree().quit(0 if ok else 1)


# --- 순수 함수(테스트 대상) ------------------------------------------------

## 측정 결과 JSON 본문. REQUIRED_KEYS 전부 + 관문 판정 + 보조 수치.
static func build_report(stats: PerfStats, config: SpikeConfig, settings: SpikeConfigSet, env: Dictionary, monitors: Dictionary) -> Dictionary:
	var r: Dictionary = {
		"ticket": TICKET,
		"config": config.id,
		"note": config.note,
		"instances": config.instances,
		"lights": config.lights,
		"shadow_lights": config.shadow_lights,
		"shadow_atlas_size": config.shadow_atlas_size,
		"avg_fps": stats.avg_fps,
		"p1_low_fps": stats.p1_low_fps,
		"avg_frame_ms": stats.avg_frame_ms,
		"max_frame_ms": stats.max_frame_ms,
		"p1_low_frame_ms": stats.p1_low_frame_ms,
		"sample_count": stats.sample_count,
	}
	r.merge(monitors, false)
	r.merge(env, false)
	var issues: PackedStringArray = run_issues(stats, env)
	r["run_valid"] = issues.is_empty()
	r["run_issues"] = issues
	r["gate"] = gate_verdict(settings, config.id, stats, issues)
	r["bound_hint"] = bound_hint(float(monitors.get("avg_gpu_ms", 0.0)), float(monitors.get("avg_crowd_update_ms", 0.0)), float(monitors.get("avg_render_cpu_ms", 0.0)))
	return r


## 측정 조건 위반 목록(빈 배열 = 유효한 측정). 티켓 금지 사항: VSync 켠 채 측정, forward_plus 아님,
## 1920×1080 아님. 헤드리스는 렌더를 안 하므로 프레임 시간이 GPU 비용을 포함하지 않는다.
static func run_issues(stats: PerfStats, env: Dictionary) -> PackedStringArray:
	var issues: PackedStringArray = PackedStringArray()
	if not stats.valid:
		issues.append("프레임 샘플 없음")
	if bool(env.get("headless", false)):
		issues.append("헤드리스 실행(렌더 없음)")
	if str(env.get("vsync", "")) != "off":
		issues.append("VSync 가 꺼지지 않음 (%s)" % env.get("vsync", "?"))
	if str(env.get("renderer", "")) != REQUIRED_RENDERER:
		issues.append("렌더러가 %s 아님 (%s)" % [REQUIRED_RENDERER, env.get("renderer", "?")])
	if str(env.get("resolution", "")) != str(env.get("requested_resolution", "")):
		issues.append("해상도 불일치 (실제 %s, 요청 %s)" % [env.get("resolution", "?"), env.get("requested_resolution", "?")])
	return issues


## 관문 판정. 관문 구성이 아니면 applies = false, verdict = "해당 없음".
## 측정 조건 위반(issues)이 있으면 숫자와 관계없이 verdict = "무효", pass = false.
static func gate_verdict(settings: SpikeConfigSet, config_id: String, stats: PerfStats, issues: PackedStringArray = PackedStringArray()) -> Dictionary:
	var applies: bool = config_id == settings.gate_config_id
	var valid_run: bool = issues.is_empty()
	var passed: bool = applies and valid_run and stats.valid and stats.avg_fps >= settings.gate_min_avg_fps
	var verdict: String = "해당 없음"
	if applies:
		if not valid_run:
			verdict = "무효"
		else:
			verdict = "통과" if passed else "실패"
	return {
		"config": settings.gate_config_id,
		"min_avg_fps": settings.gate_min_avg_fps,
		"applies": applies,
		"pass": passed,
		"verdict": verdict,
	}


## 대략적인 병목 표시: GPU 렌더 시간이 CPU 쪽(군중 갱신 스크립트 + 렌더 CPU)보다 길면 GPU, 아니면 CPU.
## GPU 시간을 못 재는 드라이버(0)면 "unknown". 판정 문장은 사람이 Performance 수치를 보고 쓴다(AC8).
## 참고: avg_process_ms(Performance.TIME_PROCESS)는 프레임 전체 시간에 가까워 이 비교에 쓰지 않는다.
static func bound_hint(gpu_ms: float, script_ms: float, render_cpu_ms: float) -> String:
	if gpu_ms <= 0.0:
		return "unknown"
	return "gpu" if gpu_ms > script_ms + render_cpu_ms else "cpu"


## 결과 표(project/tests/view/perf/results/SE-003.md) 한 행.
static func format_table_row(r: Dictionary) -> String:
	return "| %s | %d | %d | %d | %.1f | %.1f | %.2f | %.2f | %d | %d |" % [
		r["config"], r["instances"], r["lights"], r["shadow_lights"], r["avg_fps"], r["p1_low_fps"],
		r["avg_frame_ms"], r["max_frame_ms"], r["draw_calls"], r["primitives"]]


## 실행 환경(측정 PC 사양) 수집. win = 측정한 창(stretch canvas_items 라 3D 렌더 해상도 = 창 크기).
static func collect_environment(win: Window, requested: Vector2i, commit: String) -> Dictionary:
	var size: Vector2i = win.size if win != null else Vector2i.ZERO
	var mem: Dictionary = OS.get_memory_info()
	var adapter: PackedStringArray = OS.get_video_adapter_driver_info()
	return {
		"resolution": "%dx%d" % [size.x, size.y],
		"requested_resolution": "%dx%d" % [requested.x, requested.y],
		"vsync": vsync_name(DisplayServer.window_get_vsync_mode()),
		"renderer": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"gpu_api": RenderingServer.get_video_adapter_api_version(),
		"gpu_driver": " ".join(adapter),
		"cpu": OS.get_processor_name(),
		"cpu_cores": OS.get_processor_count(),
		"ram_gb": float(mem.get("physical", 0)) / BYTES_PER_GB,
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"godot_version": Engine.get_version_info()["string"],
		"commit": commit,
		"timestamp": Time.get_datetime_string_from_system(true),
		"headless": DisplayServer.get_name() == "headless",
	}


static func vsync_name(mode: DisplayServer.VSyncMode) -> String:
	match mode:
		DisplayServer.VSYNC_DISABLED:
			return "off"
		DisplayServer.VSYNC_ENABLED:
			return "on"
		DisplayServer.VSYNC_ADAPTIVE:
			return "adaptive"
		DisplayServer.VSYNC_MAILBOX:
			return "mailbox"
	return "unknown"


## --commit=<해시> 가 있으면 그 값, 없으면 git rev-parse(작업 트리에 변경이 있으면 -dirty), 실패하면 "unknown".
static func resolve_commit(user_args: PackedStringArray) -> String:
	for a: String in user_args:
		if a.begins_with(ARG_COMMIT):
			return a.trim_prefix(ARG_COMMIT)
	var repo: String = ProjectSettings.globalize_path("res://")
	var out: Array = []
	if OS.execute("git", ["-C", repo, "rev-parse", "--short=12", "HEAD"], out) != 0 or out.is_empty():
		return "unknown"
	var commit: String = str(out[0]).strip_edges()
	var status: Array = []
	if OS.execute("git", ["-C", repo, "status", "--porcelain"], status) == 0 and not status.is_empty() \
			and not str(status[0]).strip_edges().is_empty():
		commit += "-dirty"
	return commit


## JSON 저장. 성공 시 true.
static func write_report(report: Dictionary, path: String) -> bool:
	var abs_dir: String = ProjectSettings.globalize_path(path.get_base_dir())
	var err: Error = DirAccess.make_dir_recursive_absolute(abs_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("SpikeMeasure: 디렉터리 생성 실패 %s (%s)" % [abs_dir, error_string(err)])
		return false
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SpikeMeasure: %s 를 쓸 수 없다 (%s)" % [path, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(JSON.stringify(report, "  ", false) + "\n")
	f.close()
	print("SpikeMeasure: 결과 → %s" % ProjectSettings.globalize_path(path))
	return true
