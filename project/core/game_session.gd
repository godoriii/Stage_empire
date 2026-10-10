class_name GameSession
extends RefCounted
## 게임 세션 단일 조립점 (SE-036). TickLoop + 시스템 6개(build·artist·audience·show·economy·reputation)를
## sim.json system_order 순서로 생성·구독·register_system 하고, 세이브/로드(SaveFile)·오토세이브·session.* 명령을 맡는다.
## 규칙: docs/gdd/tick.md #스냅샷("허용 시점", "오토세이브 시점"), #명령-큐와-틱-순서("시스템은 이벤트 구독도
## system_order 순서로 생성·구독"), docs/tickets/SE-036.md, SE-049(session.loaded 4필드).
##
## 저장·로드·새 게임은 틱 경계에서만 한다. session.save_requested / load_requested / new_game_requested 는 명령 큐로
## 들어오고, 경계 처리에서 핸들러가 요청만 기록한다. GameSession 의 구동기(advance/step)가 TickLoop 호출 바깥(경계)에서
## 요청을 처리한다:
## - 구동 시작 시 큐에 session.* 명령이 있으면 먼저 큐 순서대로 경계 처리를 한다(session 명령까지 advance(0) →
##   그 요청 처리 → 다음 묶음, _pre_dispatch_session_commands).
##   (session 명령이 없으면 TickLoop 호출 순서는 TickLoop 을 직접 구동할 때와 같다.)
## - 오토세이브: time.phase_changed {to:"close"} 구독 핸들러는 플래그만 세우고, 구동기가 advance/step 반환 뒤
##   (close 는 홀드라 그 경계에서 반환) 파일을 쓴다.
## session.* 계약(SE-056, docs/gdd/events.md #session-명령-규칙 SN1~SN5):
## - SN1 슬롯 = ^[a-z0-9_]{1,24}$ 인 String. SN3 저장 실패는 push_error 만(이벤트 없음).
## - SN4 불러오기 실패 사유 invalid → missing → corrupt → version_mismatch → restore_failed(처음 맞는 것 하나).
## - SN2 같은 경계의 명령은 큐 순서대로: session 명령 앞의 명령을 먼저 전달하고 session 명령을 처리한다.
##   불러오기·새 게임이 성공하면 그 뒤 명령은 버리고 큐 = 복원 스냅샷의 pending_commands(새 게임은 빈 큐).
## - SN5 새 게임(session.new_game_requested)은 같은 TickLoop·EventBus·시스템에 new_game(seed) 의 1일차 스냅샷을
##   restore 한다 — 구독이 그대로 남고, 상태 해시는 new_game(seed) 와 같다.
## 로드·새 게임 성공 뒤 이벤트(재발행 규칙, SE-036 AC6): session.loaded {day, phase, speed, show_active} →
## build.placed(설치 인스턴스 순서대로 전부) → build.coverage_changed {cause:"sync"} → reputation.changed {delta:0}.
## economy 는 재발행하지 않는다(cash()·ticket_price()·hud_state() 접근자로 읽는다). show.started·time.phase_changed·
## artist.lineup_set 은 재발행하지 않는다(구독 시스템이 다시 반응해 상태·난수가 바뀐다, SE-049).
## 오토세이브 보관 수(SE-057, tick.md SV1~SV5): <data_root>/save/save.json 의 autosave_keep. 없으면 무제한.

const CMD_SAVE: String = "session.save_requested"
const CMD_LOAD: String = "session.load_requested"
const CMD_NEW_GAME: String = "session.new_game_requested"
const EV_SAVED: String = "session.saved"
const EV_LOADED: String = "session.loaded"
const EV_LOAD_FAILED: String = "session.load_failed"
const CMD_PREFIX: String = "session."
const EV_PHASE_CHANGED: String = "time.phase_changed"
const EV_BUILD_PLACED: String = "build.placed"
const EV_COVERAGE: String = "build.coverage_changed"
const EV_REPUTATION: String = "reputation.changed"
const COVERAGE_CAUSE_RELOAD: String = "sync"
const PHASE_CLOSE: String = "close"

## session.load_failed.reason (SN4, 판정 순서대로).
const REASON_INVALID: String = "invalid"
const REASON_MISSING: String = "missing"
const REASON_CORRUPT: String = "corrupt"
const REASON_VERSION_MISMATCH: String = "version_mismatch"
const REASON_RESTORE_FAILED: String = "restore_failed"
## SN1 슬롯 형식(계약의 형식 규칙이라 데이터가 아니다).
const SLOT_PATTERN: String = "^[a-z0-9_]{1,24}$"

const DEFAULT_DATA_ROOT: String = "res://data"
const DEFAULT_SAVES_DIR: String = "user://saves"
const SAVE_EXT: String = ".sav"
const AUTOSAVE_PREFIX: String = "autosave_day"
## autosave_keep 의 "무제한" 값(tick.md SV3·SV4). save.json 이 없거나 키가 없거나 값이 잘못됐을 때도 이 값이다.
const KEEP_UNLIMITED: int = 0
## 세이브 설정 테이블(tick.md #세이브-설정-savejson SV1, SE-057). load_configs 가 data_root 기준으로 옮겨 읽는다.
const SAVE_CONFIG_PATH: String = "res://data/save/save.json"
## save.json 의 오토세이브 보관 수 필드이자 load_configs() 결과의 같은 이름 키(선택 키, 없으면 무제한).
## manual_slots 는 sim 이 읽지 않는다(SV2 — 메뉴 SE-040 몫).
const KEY_AUTOSAVE_KEEP: String = "autosave_keep"
const NO_DAY: int = 0

## load_configs() 가 돌려주는 키. 값이 null 이면 new_game 실패.
const CONFIG_KEYS: Array[String] = ["sim", "build", "artist", "audience", "show", "economy", "reputation"]
## GameSession 이 만드는 시스템(sim.json system_order 의 부분집합). staff·crisis 는 아직 없다.
const SYSTEM_IDS: Array[String] = ["build", "artist", "audience", "show", "economy", "reputation"]

## 저장 위치(테스트는 임시 경로를 주입한다). 슬롯 s 의 파일 = saves_dir/s.sav.
var saves_dir: String = DEFAULT_SAVES_DIR
var autosave_enabled: bool = true
## 오토세이브 보관 수. KEEP_UNLIMITED(0) = 무제한. new_game 이 configs[KEY_AUTOSAVE_KEEP](save.json, SV1)로 정하고,
## 그 뒤 테스트가 덮어쓸 수 있다.
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
var _requests: Array = []           # [[명령 이름, slot 또는 seed], …] 경계에서 처리할 session 명령
var _configs: Dictionary = {}       # new_game 에 쓴 설정(새 게임 명령이 같은 설정으로 세계를 만든다)
static var _slot_re: RegEx = null


## data_root 아래 설정 테이블을 읽는다. 경로는 각 Config 의 기본 경로에서 DEFAULT_DATA_ROOT 를 data_root 로 바꾼 것.
## (Config 가 내부에서 읽는 교차 테이블 — tiers·economy·genres 등 — 은 각 Config 의 고정 경로 그대로다.)
## 값이 null 인 항목은 그 Config 의 로드 실패(Config 가 push_error 를 이미 냈다).
## KEY_AUTOSAVE_KEEP(int) 는 <data_root>/save/save.json 의 보관 수(read_autosave_keep, SV4·SV5 적용 뒤 값)다.
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
		KEY_AUTOSAVE_KEEP: read_autosave_keep(_rebase(SAVE_CONFIG_PATH, data_root)),
	}


## save.json 의 autosave_keep(tick.md SV4·SV5). 파일 없음·키 없음 → KEEP_UNLIMITED(오류 없음).
## 파일이 JSON 객체가 아니거나 값이 int 가 아니거나 0 미만 → push_error 1회, KEEP_UNLIMITED(잘못된 데이터로 세이브를 지우지 않는다).
static func read_autosave_keep(path: String) -> int:
	if not FileAccess.file_exists(path):
		return KEEP_UNLIMITED
	var d: Variant = JsonUtil.read_json(path, "GameSession")
	if d == null:
		return KEEP_UNLIMITED
	if not (d as Dictionary).has(KEY_AUTOSAVE_KEEP):
		return KEEP_UNLIMITED
	return _valid_keep((d as Dictionary)[KEY_AUTOSAVE_KEEP], path)


## int(정수값 float 포함)이고 0 이상이면 그 값, 아니면 push_error 1회 후 KEEP_UNLIMITED(SV5).
static func _valid_keep(v: Variant, where: String) -> int:
	var n: Variant = JsonUtil.as_int(v)
	if n == null or int(n) < KEEP_UNLIMITED:
		push_error("[GameSession] %s: %s 가 0 이상의 int 가 아니다(%s) — 무제한으로 둔다" % [where, KEY_AUTOSAVE_KEEP, v])
		return KEEP_UNLIMITED
	return n


## 새 게임. 설정 로드·시스템 생성·등록이 하나라도 실패하면 push_error 1회(GameSession), false.
func new_game(seed_value: int, data_root: String = DEFAULT_DATA_ROOT) -> bool:
	return new_game_from_configs(seed_value, load_configs(data_root))


## 이미 읽은 설정으로 새 게임(테스트가 설정을 한 번만 읽고 재사용한다). configs 키 = CONFIG_KEYS(필수) + KEY_AUTOSAVE_KEEP(선택).
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
	_configs = configs
	autosave_keep = KEEP_UNLIMITED
	if configs.has(KEY_AUTOSAVE_KEEP):                 # 선택 키(직접 만든 configs 에는 없을 수 있다 → 무제한, SV4)
		autosave_keep = _valid_keep(configs[KEY_AUTOSAVE_KEEP], "configs")
	_loop.bus.subscribe(CMD_SAVE, _on_save_requested)
	_loop.bus.subscribe(CMD_LOAD, _on_load_requested)
	_loop.bus.subscribe(CMD_NEW_GAME, _on_new_game_requested)
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
## (직접 호출 API 라 SN4 ②~④ 실패도 push_error 1회를 낸다. ⑤ 는 TickLoop.restore 의 push_error.)
func load_from(path: String) -> bool:
	if _reject_if_busy("load_from"):
		return false
	var reason: String = _load_now(path)
	if reason != "" and reason != REASON_RESTORE_FAILED:
		push_error("[GameSession] load_from 실패(%s): %s" % [reason, path])
	return reason == ""


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


## 큐에 session.* 명령이 있으면 TickLoop 구동 전 경계에서 큐 순서대로 처리한다(SN2):
## session 명령까지의 묶음을 advance(0) 으로 전달하고(핸들러가 요청을 기록) 그 요청을 처리한다. 처리 중 버스의 큐는
## "아직 전달하지 않은 명령 + 전달 중 새로 들어온 명령"이라 저장 스냅샷의 pending_commands 가 된다.
## 불러오기·새 게임이 성공하면 남은 명령을 버린다(큐는 restore 가 정한 값). 끝에 남은 묶음도 이 경계에서 전달한다.
## session 명령이 없으면 아무것도 하지 않는다(TickLoop 호출 순서는 TickLoop 을 직접 구동할 때와 같다).
func _pre_dispatch_session_commands() -> void:
	var rest: Array = _loop.bus.get_pending_commands()
	if _first_session_index(rest) < 0:
		return
	var deferred: Array = []                     # 전달 중 새로 들어온 명령(다음 경계 몫)
	while true:
		var i: int = _first_session_index(rest)
		var seg: Array = rest if i < 0 else rest.slice(0, i + 1)
		rest = [] if i < 0 else rest.slice(i + 1)
		if seg.is_empty():
			break
		_loop.bus.set_pending_commands(seg)
		_loop.advance(0)
		deferred.append_array(_loop.bus.get_pending_commands())
		var visible: Array = rest.duplicate()
		visible.append_array(deferred)
		_loop.bus.set_pending_commands(visible)
		if _process_requests():
			return                               # 세계가 바뀌었다: 남은 명령 폐기(SN2)
	_loop.bus.set_pending_commands(deferred)


static func _first_session_index(cmds: Array) -> int:
	for i: int in cmds.size():
		if String(cmds[i]["name"]).begins_with(CMD_PREFIX):
			return i
	return -1


## advance/step 반환 뒤(경계): 오토세이브 → 남은 session 요청.
func _after_drive() -> void:
	if _autosave_day != NO_DAY:
		var d: int = _autosave_day
		_autosave_day = NO_DAY
		if autosave_enabled:
			_autosave(d)
	_process_requests()


## 기록된 session 요청을 순서대로 처리한다. 불러오기·새 게임이 성공하면 남은 요청을 버리고 true(SN2).
func _process_requests() -> bool:
	while not _requests.is_empty():
		var r: Array = _requests.pop_front()
		var arg: Variant = r[1]
		match r[0]:
			CMD_SAVE:
				if not is_valid_slot(arg):
					push_error("[GameSession] 저장 거부: 슬롯 '%s' 가 SN1 형식(%s)이 아니다" % [arg, SLOT_PATTERN])
				elif _save_now(slot_path(arg)):
					_loop.bus.publish(EV_SAVED, {"slot": arg, "day": _loop.day})
			CMD_LOAD:
				var reason: String = _load_now(slot_path(arg)) if is_valid_slot(arg) else REASON_INVALID
				if reason != "":
					_loop.bus.publish(EV_LOAD_FAILED, {"slot": arg, "reason": reason})
				else:
					_requests.clear()
					return true
			CMD_NEW_GAME:
				if not (arg is int):
					push_error("[GameSession] 새 게임 무시: seed 가 int 가 아니다(%s)" % [arg])
				elif _new_world(arg):
					_requests.clear()
					return true
	return false


## 실패하면 이벤트 없음(SN3, push_error 는 SaveFile 이 낸다).
func _autosave(d: int) -> void:
	var slot: String = autosave_slot(d)
	var path: String = slot_path(slot)
	if not _save_now(path):
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


## 성공이면 "", 실패면 SN4 ②~⑤ 사유. ②~④ 는 push_error 0, ⑤ 는 TickLoop.restore 의 push_error. 실패 시 상태 불변.
func _load_now(path: String) -> String:
	if not FileAccess.file_exists(path):                                       # ②
		return REASON_MISSING
	var r: Dictionary = SaveFile.inspect(FileAccess.get_file_as_bytes(path))
	if r[SaveFile.R_ERROR] != "":                                              # ③ 파일 형식
		return REASON_CORRUPT
	var snap: Dictionary = r[SaveFile.R_SNAPSHOT]
	for k: String in TickLoop.SNAPSHOT_KEYS:                                   # ③ 스냅샷 최상위 키
		if not snap.has(k):
			return REASON_CORRUPT
	var sv: Variant = r[SaveFile.R_SAVE_VERSION]
	if sv == null or sv != SaveFile.SAVE_VERSION:                              # ④ 파일 버전
		return REASON_VERSION_MISMATCH
	if JsonUtil.as_int(snap["schema_version"]) != _loop.config.snapshot_schema_version:   # ④ 스냅샷 스키마
		return REASON_VERSION_MISMATCH
	if not _loop.restore(SaveFile.migrate(snap)):                              # ⑤
		return REASON_RESTORE_FAILED
	_autosave_day = NO_DAY
	_publish_loaded()
	return ""


## SN5: new_game(seed) 와 같은 1일차 세계를 만들어 그 스냅샷을 지금 TickLoop 에 restore 한다(버스·시스템·구독 유지).
## 재발행(session.loaded → build.placed → build.coverage_changed{sync} → reputation.changed) 뒤 같은 스냅샷을 한 번 더
## restore 한다: 새 세계의 AudienceSystem.coverage 는 첫 coverage_changed 전이라 비어 있는데(capacity 0) 재발행 sync 가
## 그것을 채워 상태 해시가 new_game(seed) 와 달라지기 때문이다(SN5 "같은 seed → 같은 1일차 상태 해시").
## 실패하면 push_error, false, 상태 불변.
func _new_world(seed_value: int) -> bool:
	var fresh: GameSession = GameSession.new()
	if not fresh.new_game_from_configs(seed_value, _configs):
		push_error("[GameSession] 새 게임 실패: 세계를 만들지 못했다(seed %d)" % seed_value)
		return false
	var snap: Dictionary = fresh.snapshot()
	if not _loop.restore(snap):
		return false
	_autosave_day = NO_DAY
	_publish_loaded()
	if not _loop.restore(snap):
		push_error("[GameSession] 새 게임: 재발행 뒤 재적용 실패(seed %d)" % seed_value)
	return true


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


## SN1: String 이고 ^[a-z0-9_]{1,24}$ 에 맞는다.
static func is_valid_slot(slot: Variant) -> bool:
	if not (slot is String):
		return false
	if _slot_re == null:
		_slot_re = RegEx.create_from_string(SLOT_PATTERN)
	return _slot_re.search(slot) != null


static func _rebase(default_path: String, data_root: String) -> String:
	return data_root.path_join(default_path.trim_prefix(DEFAULT_DATA_ROOT).trim_prefix("/"))


# --- 명령·입력 핸들러(요청 기록만, 상태 이벤트 없음) ----------------------------------

func _on_save_requested(p: Dictionary) -> void:
	_requests.append([CMD_SAVE, p.get("slot")])


func _on_load_requested(p: Dictionary) -> void:
	_requests.append([CMD_LOAD, p.get("slot")])


func _on_new_game_requested(p: Dictionary) -> void:
	_requests.append([CMD_NEW_GAME, p.get("seed")])


func _on_phase_changed(p: Dictionary) -> void:
	if p.get("to") == PHASE_CLOSE:
		var d: Variant = JsonUtil.as_int(p.get("day"))
		if d != null:
			_autosave_day = d
