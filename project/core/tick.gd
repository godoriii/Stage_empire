class_name TickLoop
extends RefCounted
## 고정 틱 루프 (SE-001). 게임 시간의 단일 출처. 규칙: docs/gdd/tick.md (#틱, #세션-구간, #배속,
## #명령-큐와-틱-순서, #스냅샷, #이벤트-순서). 틱 수·구간 길이·배속 허용표는 전부 SimConfig 에서 읽는다.
##
## 한 틱(경계 T → T+1): 1 명령 처리(bus.dispatch_commands) → 2 시스템 update(ctx) (system_order 순)
## → 3 카운터 → 4 구간 전환(time.phase_changed → time.speed_changed) → 5 tick.advanced.
## advance()/step() 은 호출 시작(B-call)과 두 번째 이후 틱 직전(B-tick)에만 경계 처리를 한다.
## 시스템 스냅샷 훅(SE-011 스펙, SE-012 구현): register_system 의 snapshot_hook/restore_hook 으로 시스템 상태가
## snapshot()["systems"][id] 에 들어가고 restore() 7단계에서 복원된다(실패 시 역순 롤백).

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

## 스냅샷 최상위 키 10개(tick.md#스냅샷 표, SE-011). 시스템 상태는 systems.<id> 아래에만 들어간다.
const SNAPSHOT_KEYS: Array[String] = [
	"schema_version", "seed", "tick", "day", "phase", "tick_in_phase", "speed", "rng", "pending_commands",
	"systems",
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

## 실행 중 표시: advance/step 의 틱 처리 중, 그리고 snapshot()/restore() 가 시스템 훅을 부르는 중(SH5).
var _running: bool = false
var _acc: int = 0                  # step() 누적기 (µs × 틱/초). 상태 아님, 스냅샷 제외
var _systems: Dictionary = {}      # id -> update Callable
var _hooks: Dictionary = {}        # id -> [snapshot_hook, restore_hook] (훅 시스템만)


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


## 단계 2 에서 부를 시스템을 등록한다(tick.md#명령-큐와-틱-순서 "시스템 등록", SE-011).
## 호출 순서는 sim.json system_order (등록 순서 무관). 훅(snapshot_hook/restore_hook)은 둘 다 주거나 둘 다 비운다.
## 검사 G1~G6 은 위에서부터, 처음 걸린 곳에서 push_error 1회 + false, 아무것도 등록하지 않는다.
func register_system(id: String, update: Callable, snapshot_hook: Callable = Callable(), restore_hook: Callable = Callable()) -> bool:
	if _reject_if_busy("register_system"):                                    # G1
		return false
	if not config.system_order.has(id):                                       # G2
		push_error("[TickLoop] register_system: '%s' 는 system_order 에 없다" % id)
		return false
	if _systems.has(id):                                                      # G3
		push_error("[TickLoop] register_system: '%s' 는 이미 등록됐다" % id)
		return false
	if not update.is_valid():                                                 # G4
		push_error("[TickLoop] register_system: '%s' 의 update 가 유효하지 않다" % id)
		return false
	var has_hooks: bool = not snapshot_hook.is_null()
	if has_hooks != (not restore_hook.is_null()):                             # G5
		push_error("[TickLoop] register_system: '%s' 의 훅은 snapshot_hook·restore_hook 둘 다 주거나 둘 다 비워야 한다" % id)
		return false
	if has_hooks and not (snapshot_hook.is_valid() and restore_hook.is_valid()):  # G6
		push_error("[TickLoop] register_system: '%s' 의 snapshot_hook/restore_hook 이 유효하지 않다" % id)
		return false
	_systems[id] = update
	if has_hooks:
		_hooks[id] = [snapshot_hook, restore_hook]
	return true


## 경계 상태의 스냅샷(기본형만, 최상위 10개 키). 틱 처리 중·훅 실행 중·디스패치 중이면 push_error, {}.
## 훅 시스템의 snapshot_hook 결과는 system_order 순으로 systems.<id> 에 깊은 복사해 넣는다. 훅이 무효이거나
## 반환값이 Dictionary/E4 기본형이 아니면 push_error 1회 후 {} (tick.md#스냅샷 snapshot() 절차, D3).
func snapshot() -> Dictionary:
	if _reject_if_busy("snapshot"):                                           # 1
		return {}
	_running = true                                                           # 2 (SH5)
	var systems: Variant = _collect_system_snapshots("snapshot")
	_running = false                                                          # 3
	if systems == null:
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
		"systems": systems,
	}


## 스냅샷을 적용한다(tick.md#스냅샷 restore 1~9). 1~6 은 검사(상태 불변), 7 시스템 적용(실패 시 역순 롤백),
## 8 TickLoop 필드 적용. 실패 시 push_error, false, TickLoop 필드 불변. 이벤트 없음.
## 숫자는 JSON 왕복으로 float 가 되어 와도 정수값이면 int 로 정규화한다. pending_commands 페이로드도
## 같은 규칙(명령 페이로드는 int 만 허용, EventBus E4 v0).
func restore(s: Dictionary) -> bool:
	if _reject_if_busy("restore"):                                            # 1
		return false
	var ver: Variant = _as_int(s.get("schema_version"))                       # 2
	if ver == null or ver != config.snapshot_schema_version:
		return _restore_fail("schema_version 불일치: %s (기대 %d)" % [s.get("schema_version"), config.snapshot_schema_version])
	var n_seed: Variant = _as_int(s.get("seed"))                              # 3
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
	var cmds: Variant = EventBus.normalize_commands(s.get("pending_commands"))  # 4 (a)
	if cmds == null:
		return _restore_fail("pending_commands 형식 오류(명령 페이로드 숫자는 int 만 허용)")
	var new_rng: SeededRng = SeededRng.new(n_seed, config.rng_streams)       # 4 (b) 현재 rng 는 그대로
	if not new_rng.set_state(rng_state):
		return _restore_fail("rng 상태 적용 실패")
	var systems: Variant = s.get("systems")                                   # 5 (D5)
	if not (systems is Dictionary):
		return _restore_fail("systems 가 객체가 아니다")
	var sys_ids: Array = (systems as Dictionary).keys()
	sys_ids.sort()
	for k: Variant in sys_ids:
		if not (systems[k] is Dictionary):
			return _restore_fail("systems.%s 가 객체가 아니다" % [k])
	for id: String in config.system_order:
		if not _hooks.has(id):
			continue
		if not (systems as Dictionary).has(id):
			return _restore_fail("훅 시스템 '%s' 의 항목이 systems 에 없다" % id)
		var hooks: Array = _hooks[id]
		if not ((hooks[0] as Callable).is_valid() and (hooks[1] as Callable).is_valid()):
			return _restore_fail("훅 시스템 '%s' 의 훅이 더 이상 유효하지 않다" % id)
	for k: Variant in sys_ids:
		if not _hooks.has(str(k)):
			push_warning("[TickLoop] restore: 훅 시스템이 아닌 systems.%s 항목을 무시한다" % [k])
	_running = true                                                           # 6 사전 스냅샷 (SH5)
	var prev: Variant = _collect_system_snapshots("restore")
	if prev == null:
		_running = false
		return false
	var applied: Array[String] = []                                          # 7 시스템 적용
	for id: String in config.system_order:
		if not _hooks.has(id):
			continue
		var rh: Callable = (_hooks[id] as Array)[1]
		var ok: Variant = rh.call((systems[id] as Dictionary).duplicate(true))
		if not (ok is bool and ok):
			push_error("[TickLoop] restore: 시스템 '%s' 의 restore_hook 이 실패했다. 앞서 복원한 시스템을 되돌린다" % id)
			_rollback_systems(applied, prev)
			_running = false
			return false
		applied.append(id)
	if not bus.set_pending_commands(cmds):                                    # 8 (a) 4단계가 검사를 끝냄(도달 불가)
		push_error("[TickLoop] restore: pending_commands 적용 실패. 시스템을 되돌린다")
		_rollback_systems(applied, prev)
		_running = false
		return false
	rng = new_rng                                                             # 8 (b)
	master_seed = n_seed
	tick = n_tick
	day = n_day
	phase = n_phase
	tick_in_phase = n_tip
	speed = n_speed
	_acc = 0
	_running = false                                                          # 9
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
		push_error("[TickLoop] %s: 틱 처리 중·시스템 훅 실행 중·이벤트 디스패치 중에는 호출할 수 없다(틱 경계에서만)" % what)
		return true
	return false


func _restore_fail(msg: String) -> bool:
	push_error("[TickLoop] restore: " + msg)
	return false


## 훅 시스템마다 system_order 순으로 snapshot_hook() 을 불러 검사하고 깊은 복사본을 모은다(snapshot() 2단계,
## restore() 6단계). 첫 위반에서 push_error(시스템 id 포함) 1회 후 null — 뒤 시스템 훅은 부르지 않는다.
## 호출자가 _running 을 세운 상태에서 부른다(SH5).
func _collect_system_snapshots(what: String) -> Variant:
	var out: Dictionary = {}
	for id: String in config.system_order:
		if not _hooks.has(id):
			continue
		var sh: Callable = (_hooks[id] as Array)[0]
		if not sh.is_valid():
			push_error("[TickLoop] %s: 시스템 '%s' 의 snapshot_hook 이 유효하지 않다" % [what, id])
			return null
		var v: Variant = sh.call()
		if not (v is Dictionary) or not EventBus.is_valid_value(v, true):
			push_error("[TickLoop] %s: 시스템 '%s' 의 snapshot_hook 반환값이 기본형 Dictionary 가 아니다(SH2)" % [what, id])
			return null
		out[id] = (v as Dictionary).duplicate(true)
	return out


## restore 7단계 롤백: 이미 복원한 시스템을 역순으로 사전 스냅샷(prev)으로 되돌린다. 롤백 실패는 시스템마다
## push_error 1회를 더하고 계속한다(복구 불능, tick.md#스냅샷).
func _rollback_systems(applied: Array[String], prev: Dictionary) -> void:
	for i: int in range(applied.size() - 1, -1, -1):
		var id: String = applied[i]
		var rh: Callable = (_hooks[id] as Array)[1]
		var ok: Variant = rh.call((prev[id] as Dictionary).duplicate(true))
		if not (ok is bool and ok):
			push_error("[TickLoop] restore: 시스템 '%s' 롤백 실패(복구 불능)" % id)


## int, 또는 정수값인 유한 float 만 int 로. 그 밖(bool·문자열·1.5·null)은 null.
static func _as_int(v: Variant) -> Variant:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v):
		return int(v)
	return null
