class_name TickLoop
extends RefCounted
## 고정 틱 루프 (SE-001). 게임 시간의 단일 출처. 규칙: docs/gdd/tick.md (#틱, #세션-구간, #배속,
## #명령-큐와-틱-순서, #스냅샷, #이벤트-순서). 틱 수·구간 길이·배속 허용표는 전부 SimConfig 에서 읽는다.
##
## 한 틱(경계 T → T+1): 1 명령 처리(bus.dispatch_commands) → 2 시스템 update(ctx) (system_order 순)
## → 3 카운터 → 4 구간 전환(time.phase_changed → time.speed_changed) → 5 tick.advanced.
## advance()/step() 은 호출 시작(B-call)과 두 번째 이후 틱 직전(B-tick)에만 경계 처리를 한다.

const EV_TICK_ADVANCED: String = "tick.advanced"
const EV_PHASE_CHANGED: String = "time.phase_changed"
const EV_DAY_STARTED: String = "time.day_started"
const EV_SPEED_CHANGED: String = "time.speed_changed"
const EV_SPEED_REJECTED: String = "time.speed_rejected"
const CMD_SPEED: String = "time.speed_requested"
const CMD_NEXT_DAY: String = "time.next_day_requested"

const CAUSE_REQUESTED: String = "requested"
const CAUSE_PHASE_ENTER: String = "phase_enter"
const REASON_INVALID: String = "invalid"
const REASON_NOT_ALLOWED: String = "not_allowed"

## step() 누적기 단위(마이크로초/초, tick.md#틱 상수표).
const US_PER_S: int = 1000000

## 스냅샷 키(tick.md#스냅샷 표).
const SNAPSHOT_KEYS: Array[String] = [
	"schema_version", "seed", "tick", "day", "phase", "tick_in_phase", "speed", "rng", "pending_commands",
]

# 아래 공개 멤버는 읽기 전용으로 취급한다(바꾸는 것은 TickLoop 자신뿐).
var config: SimConfig
var bus: EventBus
var rng: SeededRng
var master_seed: int = 0
var tick: int = 0
var day: int = 1
var phase: String = ""
var tick_in_phase: int = 0
var speed: int = 0
## 파생: phase_start(phase) + tick_in_phase. 스냅샷에 넣지 않는다.
var tick_in_day: int:
	get:
		return config.phase_start(phase) + tick_in_phase

var _running: bool = false
var _acc: int = 0                  # step() 누적기 (µs × 틱/초). 상태 아님, 스냅샷 제외
var _systems: Dictionary = {}      # id -> Callable


## 생성자는 이벤트를 내지 않는다. bus 가 null 이면 자체 생성.
func _init(p_config: SimConfig, p_seed: int, p_bus: EventBus = null) -> void:
	if p_config == null:
		push_error("[TickLoop] config 가 null 이다")
		return
	config = p_config
	bus = p_bus if p_bus != null else EventBus.new()
	rng = SeededRng.new(p_seed, config.rng_streams)
	master_seed = rng.master_seed
	var first: Dictionary = config.phases[0]
	phase = first["id"]
	speed = first["default_speed"]
	bus.subscribe(CMD_SPEED, _on_speed_requested)
	bus.subscribe(CMD_NEXT_DAY, _on_next_day_requested)


## 헤드리스 구동기. 최대 n 틱 처리(배속 1·2·3 구별 없음, 일시정지·홀드에서 멈춤). 반환 = 처리한 틱 수.
## advance(0) = 명령만 적용.
func advance(n: int) -> int:
	if _reject_if_busy("advance"):
		return 0
	var target: int = maxi(n, 0)
	_running = true
	bus.dispatch_commands()                       # A2 B-call
	var done: int = 0
	while done < target:
		if _halted():
			break
		if done != 0:
			bus.dispatch_commands()               # B-tick
			if _halted():
				break
		_process_tick()
		done += 1
	_running = false
	return done


## 실시간 구동기. 정수 누적기로 delta_s 를 틱으로 환산한다(tick.md#배속 S1~S7).
func step(delta_s: float) -> int:
	if _reject_if_busy("step"):                   # S1
		return 0
	_running = true
	bus.dispatch_commands()                       # S2
	var s0: int = speed
	if s0 == 0 or _halted():                      # S3
		_acc = 0
		_running = false
		return 0
	var d: float = delta_s if is_finite(delta_s) else 0.0
	var k: int = s0 * config.ticks_per_second
	# S4 포화(SE-007-bug): sat_s 초분이면 이미 max_ticks_per_step 틱 이상이라 그보다 긴 정수 초는 S5 에서
	# 어차피 버려진다. 정수 초만 sat_s 로 자르고 소수부는 보존해 S5 의 잔여 acc 가 자르지 않은 계산과
	# 같게 한다. 이로써 roundi(d × 10^6) 과 us × k 가 int64 를 넘지 않는다. d ≤ sat_s 는 기존 경로 그대로.
	var sat_s: int = (config.max_ticks_per_step + k - 1) / k
	if d > sat_s:
		d = sat_s + fposmod(d, 1.0)
	var us: int = maxi(0, roundi(d * US_PER_S))   # S4
	_acc += us * k
	var q: int = _acc / US_PER_S                  # S5
	_acc -= q * US_PER_S
	var budget: int = mini(q, config.max_ticks_per_step)
	var done: int = 0
	while done < budget:                          # S6
		if done != 0:
			if _halted() or speed != s0:
				_acc = 0
				break
			bus.dispatch_commands()
			if _halted() or speed != s0:
				_acc = 0
				break
		_process_tick()
		done += 1
	_running = false
	return done                                   # S7


## 단계 2 에서 부를 시스템을 등록한다. 호출 순서는 sim.json system_order (등록 순서 무관).
func register_system(id: String, update: Callable) -> bool:
	if _reject_if_busy("register_system"):
		return false
	if not config.system_order.has(id):
		push_error("[TickLoop] register_system: '%s' 는 system_order 에 없다" % id)
		return false
	if _systems.has(id):
		push_error("[TickLoop] register_system: '%s' 는 이미 등록됐다" % id)
		return false
	if not update.is_valid():
		push_error("[TickLoop] register_system: '%s' 의 update 가 유효하지 않다" % id)
		return false
	_systems[id] = update
	return true


## 경계 상태의 스냅샷(기본형만). 틱 처리 중·디스패치 중이면 push_error, {}.
func snapshot() -> Dictionary:
	if _reject_if_busy("snapshot"):
		return {}
	return {
		"schema_version": config.snapshot_schema_version,
		"seed": master_seed,
		"tick": tick,
		"day": day,
		"phase": phase,
		"tick_in_phase": tick_in_phase,
		"speed": speed,
		"rng": rng.get_state(),
		"pending_commands": bus.get_pending_commands(),
	}


## 스냅샷을 적용한다(tick.md#스냅샷 restore 1~6). 실패 시 push_error, false, 상태 불변. 이벤트 없음.
## 숫자는 JSON 왕복으로 float 가 되어 와도 정수값이면 int 로 정규화한다. pending_commands 페이로드도
## 같은 규칙(명령 페이로드는 int 만 허용, EventBus E4 v0).
func restore(s: Dictionary) -> bool:
	if _reject_if_busy("restore"):
		return false
	var ver: Variant = _as_int(s.get("schema_version"))
	if ver == null or ver != config.snapshot_schema_version:
		return _restore_fail("schema_version 불일치: %s (기대 %d)" % [s.get("schema_version"), config.snapshot_schema_version])
	var n_seed: Variant = _as_int(s.get("seed"))
	var n_tick: Variant = _as_int(s.get("tick"))
	var n_day: Variant = _as_int(s.get("day"))
	var n_tip: Variant = _as_int(s.get("tick_in_phase"))
	var n_speed: Variant = _as_int(s.get("speed"))
	if n_seed == null or n_tick == null or n_day == null or n_tip == null or n_speed == null:
		return _restore_fail("숫자 필드(seed/tick/day/tick_in_phase/speed)가 정수가 아니다")
	if n_seed < 0 or n_seed > SeededRng.MASTER_SEED_MAX:
		return _restore_fail("seed 범위 밖: %d" % n_seed)
	var ph: Variant = s.get("phase")
	if not (ph is String or ph is StringName) or config.phase_index(String(ph)) < 0:
		return _restore_fail("모르는 phase: %s" % [ph])
	var n_phase: String = String(ph)
	if n_day < 1:
		return _restore_fail("day < 1")
	var len_phase: int = config.phase_ticks(n_phase)
	var i3: bool = (n_tip >= 0 and n_tip < len_phase) if len_phase > 0 else n_tip == 0
	if not i3:
		return _restore_fail("I3 위반: tick_in_phase %d (phase %s)" % [n_tip, n_phase])
	if n_tick != (n_day - 1) * config.day_ticks + config.phase_start(n_phase) + n_tip:
		return _restore_fail("I1 위반: tick %d, day %d, phase %s, tick_in_phase %d" % [n_tick, n_day, n_phase, n_tip])
	if not config.is_speed_allowed(n_phase, n_speed):
		return _restore_fail("I4 위반: speed %d 는 %s 에서 허용되지 않는다" % [n_speed, n_phase])
	var rng_state: Variant = s.get("rng")
	if not (rng_state is Dictionary):
		return _restore_fail("rng 가 객체가 아니다")
	var cmds: Variant = EventBus.normalize_commands(s.get("pending_commands"))
	if cmds == null:
		return _restore_fail("pending_commands 형식 오류(명령 페이로드 숫자는 int 만 허용)")
	var new_rng: SeededRng = SeededRng.new(n_seed, config.rng_streams)
	if not new_rng.set_state(rng_state):
		return _restore_fail("rng 상태 적용 실패")
	if not bus.set_pending_commands(cmds):
		return _restore_fail("pending_commands 적용 실패")
	# 여기부터는 실패하지 않는다.
	rng = new_rng
	master_seed = n_seed
	tick = n_tick
	day = n_day
	phase = n_phase
	tick_in_phase = n_tip
	speed = n_speed
	_acc = 0
	return true


# --- 내부 ---------------------------------------------------------------------

func _halted() -> bool:
	return speed == 0 or config.is_hold(phase)


func _process_tick() -> void:
	# 단계 2: ctx 는 틱 시작 시점(경계 T) 값.
	var ctx: Dictionary = {
		"tick": tick + 1,
		"day": day,
		"phase": phase,
		"tick_in_day": tick_in_day,
		"tick_in_phase": tick_in_phase,
	}
	for id: String in config.system_order:
		if _systems.has(id):
			(_systems[id] as Callable).call(ctx.duplicate())
	# 단계 3
	tick += 1
	tick_in_phase += 1
	# 단계 4
	if tick_in_phase == config.phase_ticks(phase):
		var from: String = phase
		var old_speed: int = speed
		_enter_phase(config.next_phase_id(phase))
		_publish_phase_enter(from, old_speed)
	# 단계 5
	bus.publish(EV_TICK_ADVANCED, {"tick": tick, "phase": phase})


## 상태만 바꾼다(E8: 상태 먼저, 이벤트는 호출자가 나중에).
func _enter_phase(id: String) -> void:
	phase = id
	tick_in_phase = 0
	var p: Dictionary = config.phase(id)
	var keep: bool = p["enter_speed_mode"] == SimConfig.MODE_KEEP_IF_ALLOWED and (p["speeds"] as Array).has(speed)
	if not keep:
		speed = p["default_speed"]


func _publish_phase_enter(from: String, old_speed: int) -> void:
	bus.publish(EV_PHASE_CHANGED, {"from": from, "to": phase, "day": day, "tick": tick})
	if speed != old_speed:
		bus.publish(EV_SPEED_CHANGED, {"speed": speed, "from": old_speed, "cause": CAUSE_PHASE_ENTER})


func _on_speed_requested(payload: Dictionary) -> void:
	if not payload.has("speed"):
		_reject_speed(null, REASON_INVALID)
		return
	var raw: Variant = payload["speed"]
	var s: Variant = _as_int(raw)
	if s == null:
		_reject_speed(raw, REASON_INVALID)
		return
	if not config.is_speed_allowed(phase, s):
		_reject_speed(s, REASON_NOT_ALLOWED)
		return
	if s == speed:
		return
	var old: int = speed
	speed = s
	bus.publish(EV_SPEED_CHANGED, {"speed": speed, "from": old, "cause": CAUSE_REQUESTED})


func _reject_speed(value: Variant, reason: String) -> void:
	bus.publish(EV_SPEED_REJECTED, {"speed": value, "reason": reason, "phase": phase})


## 홀드 구간에서만 유효. 다른 구간에서는 무시(상태 불변, 이벤트 없음). 틱을 소비하지 않는다.
func _on_next_day_requested(_payload: Dictionary) -> void:
	if not config.is_hold(phase):
		return
	var from: String = phase
	var old_speed: int = speed
	day += 1
	_enter_phase(config.first_phase_id())
	bus.publish(EV_DAY_STARTED, {"day": day})
	_publish_phase_enter(from, old_speed)


func _reject_if_busy(what: String) -> bool:
	if config == null:
		push_error("[TickLoop] %s: config 없이 생성됐다" % what)
		return true
	if _running or bus.is_dispatching():
		push_error("[TickLoop] %s: 틱 처리 중이거나 이벤트 디스패치 중에는 호출할 수 없다(틱 경계에서만)" % what)
		return true
	return false


func _restore_fail(msg: String) -> bool:
	push_error("[TickLoop] restore: " + msg)
	return false


## int, 또는 정수값인 유한 float 만 int 로. 그 밖(bool·문자열·1.5·null)은 null.
static func _as_int(v: Variant) -> Variant:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v):
		return int(v)
	return null
