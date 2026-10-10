class_name GameSession
extends RefCounted
## 게임 세션 단일 조립점 (SE-036). TickLoop + 시스템 6개(build·artist·audience·show·economy·reputation)를
## sim.json system_order 순서로 생성·구독·register_system 하고, 세이브/로드(SaveFile)·오토세이브·session.* 명령을 맡는다.
## 규칙: docs/gdd/tick.md #스냅샷("허용 시점", "오토세이브 시점"), #명령-큐와-틱-순서("시스템은 이벤트 구독도
## system_order 순서로 생성·구독"), docs/tickets/SE-036.md, SE-049(session.loaded 4필드).
##
## 저장·로드는 틱 경계에서만 한다. session.save_requested / load_requested 는 명령 큐로 들어오고, 경계 처리에서
## 핸들러가 요청만 기록한다. GameSession 의 구동기(advance/step)가 TickLoop 호출 바깥(경계)에서 요청을 처리한다:
## - 구동 시작 시 큐에 session.* 명령이 있으면 먼저 advance(0) 으로 경계 처리를 하고, 그 경계에서 요청을 처리한다.
##   (session 명령이 없으면 TickLoop 호출 순서는 TickLoop 을 직접 구동할 때와 같다.)
## - 오토세이브: time.phase_changed {to:"close"} 구독 핸들러는 플래그만 세우고, 구동기가 advance/step 반환 뒤
##   (close 는 홀드라 그 경계에서 반환) 파일을 쓴다.
## 로드 성공 뒤 이벤트(재발행 규칙, SE-036 AC6): session.loaded {day, phase, speed, show_active} →
## build.placed(설치 인스턴스 순서대로 전부) → build.coverage_changed {cause:"sync"} → reputation.changed {delta:0}.
## economy 는 재발행하지 않는다(cash()·ticket_price()·hud_state() 접근자로 읽는다). show.started·time.phase_changed·
## artist.lineup_set 은 재발행하지 않는다(구독 시스템이 다시 반응해 상태·난수가 바뀐다, SE-049).

const CMD_SAVE: String = "session.save_requested"
const CMD_LOAD: String = "session.load_requested"
const EV_SAVED: String = "session.saved"
const EV_SAVE_FAILED: String = "session.save_failed"
const EV_LOADED: String = "session.loaded"
const EV_LOAD_FAILED: String = "session.load_failed"
const CMD_PREFIX: String = "session."
const EV_PHASE_CHANGED: String = "time.phase_changed"
const EV_BUILD_PLACED: String = "build.placed"
const EV_COVERAGE: String = "build.coverage_changed"
const EV_REPUTATION: String = "reputation.changed"
const COVERAGE_CAUSE_RELOAD: String = "sync"
const PHASE_CLOSE: String = "close"

const REASON_BAD_SLOT: String = "bad_slot"
const REASON_NOT_FOUND: String = "not_found"
const REASON_CORRUPT: String = "corrupt"
const REASON_RESTORE_FAILED: String = "restore_failed"
const REASON_WRITE_FAILED: String = "write_failed"

const DEFAULT_DATA_ROOT: String = "res://data"
const DEFAULT_SAVES_DIR: String = "user://saves"
const SAVE_EXT: String = ".sav"
const AUTOSAVE_PREFIX: String = "autosave_day"
## autosave_keep 의 "무제한" 값. 보관 수 데이터 필드(game-designer 요청, SE-036 결과 절)가 생길 때까지 기본값이다.
const KEEP_UNLIMITED: int = 0
const NO_DAY: int = 0

## load_configs() 가 돌려주는 키. 값이 null 이면 new_game 실패.
const CONFIG_KEYS: Array[String] = ["sim", "build", "artist", "audience", "show", "economy", "reputation"]
## GameSession 이 만드는 시스템(sim.json system_order 의 부분집합). staff·crisis 는 아직 없다.
const SYSTEM_IDS: Array[String] = ["build", "artist", "audience", "show", "economy", "reputation"]

## 저장 위치(테스트는 임시 경로를 주입한다). 슬롯 s 의 파일 = saves_dir/s.sav.
var saves_dir: String = DEFAULT_SAVES_DIR
var autosave_enabled: bool = true
## 오토세이브 보관 수. KEEP_UNLIMITED(0) = 무제한. 데이터 필드가 없어 기본은 무제한이고 테스트는 주입한다.
var autosave_keep: int = KEEP_UNLIMITED
## 마지막으로 쓴 오토세이브 경로("" = 없음).
var last_autosave_path: String = ""

# 읽기 전용 접근자(바꾸는 것은 GameSession 자신뿐).
var loop: TickLoop:
	get:
		return _loop
var bus: EventBus:
	get:
		return _loop.bus if _loop != null else null
var build: BuildSystem:
	get:
		return _build
var artist: ArtistSystem:
	get:
		return _artist
var audience: AudienceSystem:
	get:
		return _audience
var show: ShowSystem:
	get:
		return _show
var economy: Economy:
	get:
		return _economy
var reputation: ReputationSystem:
	get:
		return _reputation

var _loop: TickLoop = null
var _build: BuildSystem = null
var _artist: ArtistSystem = null
var _audience: AudienceSystem = null
var _show: ShowSystem = null
var _economy: Economy = null
var _reputation: ReputationSystem = null
var _driving: bool = false          # advance/step 이 TickLoop 을 부르는 중(경계 밖)
var _autosave_day: int = NO_DAY     # close 진입 플래그(그날 번호)
var _requests: Array = []           # [[명령 이름, slot], …] 경계에서 처리할 session 명령


## data_root 아래 설정 테이블을 읽는다. 경로는 각 Config 의 기본 경로에서 DEFAULT_DATA_ROOT 를 data_root 로 바꾼 것.
## (Config 가 내부에서 읽는 교차 테이블 — tiers·economy·genres 등 — 은 각 Config 의 고정 경로 그대로다.)
## 값이 null 인 항목은 그 Config 의 로드 실패(Config 가 push_error 를 이미 냈다).
static func load_configs(data_root: String = DEFAULT_DATA_ROOT) -> Dictionary:
	var sim: SimConfig = SimConfig.load(_rebase(SimConfig.DEFAULT_PATH, data_root))
	var bcfg: BuildConfig = BuildConfig.load(_rebase(FurnitureConfig.DEFAULT_PATH, data_root), _rebase(MapConfig.DEFAULT_PATH, data_root))
	return {
		"sim": sim,
		"build": bcfg,
		"artist": ArtistConfig.load(_rebase(ArtistConfig.DEFAULT_ARTISTS_PATH, data_root), _rebase(ArtistConfig.DEFAULT_RULES_PATH, data_root)),
		"audience": AudienceConfig.load(_rebase(AudienceConfig.DEFAULT_PATH, data_root)),
		"show": ShowConfig.load(_rebase(ShowConfig.DEFAULT_PATH, data_root)),
		"economy": EconomyConfig.load(_rebase(EconomyConfig.DEFAULT_PATH, data_root)),
		"reputation": ReputationConfig.load(_rebase(ReputationConfig.DEFAULT_PATH, data_root)),
	}


## 새 게임. 설정 로드·시스템 생성·등록이 하나라도 실패하면 push_error 1회(GameSession), false.
func new_game(seed_value: int, data_root: String = DEFAULT_DATA_ROOT) -> bool:
	return new_game_from_configs(seed_value, load_configs(data_root))


## 이미 읽은 설정으로 새 게임(테스트가 설정을 한 번만 읽고 재사용한다). configs 키 = CONFIG_KEYS.
## 생성·구독·register_system 순서 = sim.json system_order(build → artist → audience → show → economy → reputation).
func new_game_from_configs(seed_value: int, configs: Dictionary) -> bool:
	if _loop != null:
		push_error("[GameSession] new_game: 이미 시작한 세션이다(새 GameSession 을 만든다)")
		return false
	for k: String in CONFIG_KEYS:
		if configs.get(k) == null:
			push_error("[GameSession] new_game: 설정 '%s' 로드 실패" % k)
			return false
	var scfg: SimConfig = configs["sim"]
	for id: String in SYSTEM_IDS:
		if not scfg.system_order.has(id):
			push_error("[GameSession] new_game: 시스템 '%s' 가 sim.json system_order 에 없다" % id)
			return false
	var bcfg: BuildConfig = configs["build"]
	var loop_new: TickLoop = TickLoop.new(scfg, seed_value)
	var made: Dictionary = {}
	for id: String in scfg.system_order:               # 생성 = 구독 순서(system_order)
		match id:
			"build":
				made[id] = BuildSystem.new(bcfg, loop_new.bus)
			"artist":
				made[id] = ArtistSystem.new(configs["artist"], loop_new.bus)
			"audience":
				made[id] = AudienceSystem.new(configs["audience"], loop_new.bus, loop_new.rng, bcfg.map)
			"show":
				made[id] = ShowSystem.new(configs["show"], loop_new.bus)
			"economy":
				made[id] = Economy.new(configs["economy"], loop_new.bus)
			"reputation":
				made[id] = ReputationSystem.new(configs["reputation"], loop_new.bus)
	for id: String in scfg.system_order:               # 등록(4인자, 훅 포함)
		if not made.has(id):
			continue
		var sys: Object = made[id]
		var ok: bool = loop_new.register_system(id, Callable(sys, "update"), Callable(sys, "snapshot"), Callable(sys, "restore"))
		if not ok:
			push_error("[GameSession] new_game: 시스템 '%s' 등록 실패" % id)
			return false
	_loop = loop_new
	_build = made["build"]
	_artist = made["artist"]
	_audience = made["audience"]
	_show = made["show"]
	_economy = made["economy"]
	_reputation = made["reputation"]
	_loop.bus.subscribe(CMD_SAVE, _on_save_requested)
	_loop.bus.subscribe(CMD_LOAD, _on_load_requested)
	_loop.bus.subscribe(EV_PHASE_CHANGED, _on_phase_changed)
	return true


# --- 구동 ------------------------------------------------------------------------

## TickLoop.advance 위임 + 경계에서 session 명령·오토세이브 처리. 반환 = 처리한 틱 수.
func advance(n: int) -> int:
	if _reject_if_busy("advance"):
		return 0
	_driving = true
	_pre_dispatch_session_commands()
	var done: int = _loop.advance(n)
	_driving = false
	_after_drive()
	return done


## TickLoop.step 위임 + 경계에서 session 명령·오토세이브 처리. 반환 = 처리한 틱 수.
func step(delta_s: float) -> int:
	if _reject_if_busy("step"):
		return 0
	_driving = true
	_pre_dispatch_session_commands()
	var done: int = _loop.step(delta_s)
	_driving = false
	_after_drive()
	return done


## 경계 상태의 스냅샷(TickLoop.snapshot 위임). 경계 밖이면 push_error, {}.
func snapshot() -> Dictionary:
	if _reject_if_busy("snapshot"):
		return {}
	return _loop.snapshot()


## 스냅샷 적용(TickLoop.restore 위임, 이벤트 없음). 재발행이 필요하면 load_from 을 쓴다.
func restore(s: Dictionary) -> bool:
	if _reject_if_busy("restore"):
		return false
	return _loop.restore(s)


## 경계에서 스냅샷을 path 에 쓴다(JSON → gzip). 경계 밖(틱 처리 중·디스패치 중)이면 push_error 1회, false.
func save_to(path: String) -> bool:
	if _reject_if_busy("save_to"):
		return false
	return _save_now(path)


## 경계에서 path 를 읽어 복원하고 session.loaded + 재발행 이벤트를 낸다. 실패하면 false, 상태 불변.
func load_from(path: String) -> bool:
	if _reject_if_busy("load_from"):
		return false
	return _load_now(path) == ""


## 슬롯 이름 → 파일 경로(saves_dir/slot.sav).
func slot_path(slot: String) -> String:
	return saves_dir.path_join(slot + SAVE_EXT)


## 오토세이브 파일 경로(saves_dir/autosave_day<N>.sav).
func autosave_path(d: int) -> String:
	return slot_path(autosave_slot(d))


static func autosave_slot(d: int) -> String:
	return AUTOSAVE_PREFIX + str(d)


# --- 읽기 전용 상태(HUD 용, 상태·이벤트 불변) -------------------------------------------

func cash() -> int:
	return _economy.cash


func ticket_price() -> int:
	return _economy.ticket_price


func reputation_total() -> int:
	return _reputation.total


## 그날 show.started 뒤 아직 show.ended 전(ShowSystem.status == running).
func show_active() -> bool:
	return _show.status == ShowSystem.STATUS_RUNNING


## HUD 가 로드 직후(session.loaded) 한 번에 읽는 값.
func hud_state() -> Dictionary:
	return {
		"day": _loop.day, "phase": _loop.phase, "speed": _loop.speed, "cash": cash(), "ticket_price": ticket_price(),
		"reputation_total": reputation_total(), "show_active": show_active(), "bankrupt": _economy.bankrupt,
	}


# --- 내부 ------------------------------------------------------------------------

func _reject_if_busy(what: String) -> bool:
	if _loop == null:
		push_error("[GameSession] %s: new_game 전이다" % what)
		return true
	if _driving or _loop.bus.is_dispatching():
		push_error("[GameSession] %s: 틱 처리 중·이벤트 디스패치 중에는 할 수 없다(틱 경계에서만)" % what)
		return true
	return false


## 큐에 session.* 명령이 있으면 먼저 경계 처리(advance(0))를 하고 그 경계에서 요청을 처리한다.
func _pre_dispatch_session_commands() -> void:
	var found: bool = false
	for c: Dictionary in _loop.bus.get_pending_commands():
		if String(c["name"]).begins_with(CMD_PREFIX):
			found = true
			break
	if not found:
		return
	_loop.advance(0)
	_process_requests()


## advance/step 반환 뒤(경계): 오토세이브 → 남은 session 요청.
func _after_drive() -> void:
	if _autosave_day != NO_DAY:
		var d: int = _autosave_day
		_autosave_day = NO_DAY
		if autosave_enabled:
			_autosave(d)
	_process_requests()


func _process_requests() -> void:
	while not _requests.is_empty():
		var r: Array = _requests.pop_front()
		var slot: Variant = r[1]
		if r[0] == CMD_SAVE:
			if not _is_valid_slot(slot):
				_loop.bus.publish(EV_SAVE_FAILED, {"slot": str(slot), "reason": REASON_BAD_SLOT})
			elif _save_now(slot_path(slot)):
				_loop.bus.publish(EV_SAVED, {"slot": slot, "day": _loop.day})
			else:
				_loop.bus.publish(EV_SAVE_FAILED, {"slot": slot, "reason": REASON_WRITE_FAILED})
		else:
			if not _is_valid_slot(slot):
				_loop.bus.publish(EV_LOAD_FAILED, {"slot": str(slot), "reason": REASON_BAD_SLOT})
				continue
			var reason: String = _load_now(slot_path(slot))
			if reason != "":
				_loop.bus.publish(EV_LOAD_FAILED, {"slot": slot, "reason": reason})


func _autosave(d: int) -> void:
	var slot: String = autosave_slot(d)
	var path: String = slot_path(slot)
	if not _save_now(path):
		_loop.bus.publish(EV_SAVE_FAILED, {"slot": slot, "reason": REASON_WRITE_FAILED})
		return
	last_autosave_path = path
	_prune_autosaves()
	_loop.bus.publish(EV_SAVED, {"slot": slot, "day": d})


func _save_now(path: String) -> bool:
	var s: Dictionary = _loop.snapshot()
	if s.is_empty():
		push_error("[GameSession] 저장 실패: 스냅샷을 찍지 못했다(%s)" % path)
		return false
	return SaveFile.write(path, s)


## 성공이면 "", 실패면 load_failed reason. 실패 시 상태 불변(TickLoop.restore 원자성).
func _load_now(path: String) -> String:
	if not FileAccess.file_exists(path):
		push_error("[GameSession] 로드 실패: 파일 없음 %s" % path)
		return REASON_NOT_FOUND
	var s: Dictionary = SaveFile.read(path)
	if s.is_empty():
		return REASON_CORRUPT
	if not _loop.restore(s):
		return REASON_RESTORE_FAILED
	_autosave_day = NO_DAY
	_publish_loaded()
	return ""


## 로드 뒤 view 가 전체 상태를 다시 그리도록 한다(재발행 규칙, 파일 머리 주석).
func _publish_loaded() -> void:
	var b: EventBus = _loop.bus
	b.publish(EV_LOADED, {"day": _loop.day, "phase": _loop.phase, "speed": _loop.speed, "show_active": show_active()})
	var cfg: BuildConfig = _build.config
	for inst: Dictionary in _build.instances:
		var fid: String = inst["furniture_id"]
		var cell: Array = inst["cell"]
		var rot: int = inst["rotation"]
		b.publish(EV_BUILD_PLACED, {
			"entity_id": inst["entity_id"], "furniture_id": fid, "cell": cell.duplicate(), "rotation": rot,
			"cells": BuildConfig.cells_of(cfg.furniture(fid)["footprint"], cell, rot), "cost": inst["paid"],
		})
	var cov: Dictionary = _build.coverage()
	var payload: Dictionary = {"cause": COVERAGE_CAUSE_RELOAD}
	for k: String in Coverage.KEYS:
		payload[k] = cov[k]
	b.publish(EV_COVERAGE, payload)
	b.publish(EV_REPUTATION, {"day": _loop.day, "delta": 0, "total": _reputation.total, "by_genre": _reputation.by_genre()})


## 보관 수를 넘는 오래된 오토세이브(일차가 작은 것부터)를 지운다. KEEP_UNLIMITED 면 아무것도 지우지 않는다.
func _prune_autosaves() -> void:
	if autosave_keep <= KEEP_UNLIMITED:
		return
	var days: Array[int] = list_autosave_days()
	var extra: int = days.size() - autosave_keep
	for i: int in range(extra):
		DirAccess.remove_absolute(autosave_path(days[i]))


## saves_dir 의 오토세이브 일차 목록(오름차순).
func list_autosave_days() -> Array[int]:
	var out: Array[int] = []
	var dir: DirAccess = DirAccess.open(saves_dir)
	if dir == null:
		return out
	for f: String in dir.get_files():
		if not (f.begins_with(AUTOSAVE_PREFIX) and f.ends_with(SAVE_EXT)):
			continue
		var mid: String = f.trim_prefix(AUTOSAVE_PREFIX).trim_suffix(SAVE_EXT)
		if mid.is_valid_int():
			out.append(mid.to_int())
	out.sort()
	return out


static func _is_valid_slot(slot: Variant) -> bool:
	return (slot is String or slot is StringName) and String(slot) != "" and String(slot).is_valid_filename()


static func _rebase(default_path: String, data_root: String) -> String:
	return data_root.path_join(default_path.trim_prefix(DEFAULT_DATA_ROOT).trim_prefix("/"))


# --- 명령·입력 핸들러(요청 기록만, 상태 이벤트 없음) ----------------------------------

func _on_save_requested(p: Dictionary) -> void:
	_requests.append([CMD_SAVE, p.get("slot")])


func _on_load_requested(p: Dictionary) -> void:
	_requests.append([CMD_LOAD, p.get("slot")])


func _on_phase_changed(p: Dictionary) -> void:
	if p.get("to") == PHASE_CLOSE:
		var d: Variant = JsonUtil.as_int(p.get("day"))
		if d != null:
			_autosave_day = d
