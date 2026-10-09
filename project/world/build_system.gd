class_name BuildSystem
extends RefCounted
## build 시스템 v0 (SE-032). 규칙: docs/gdd/build.md (#상태, #배치-규칙 B1~B11, #철거-규칙 D1~D4, #경제-핸드셰이크 H1~H5,
## #커버리지 C0~C8, #결정성과-rng, #스냅샷 RS1~RS7). 이벤트: docs/gdd/events.md 의 build.* 행과 economy 입력 계약.
##
## - 가구 인스턴스 목록만 소유한다. 현금은 economy 가 바꾸고 build 는 charge/refund 제안과 upkeep 보고만 한다(cash 를 읽지 않는다).
## - 입력은 생성자에서 구독한 이벤트뿐(명령 2종, economy.charge_resolved, time.phase_changed). 생성자는 이벤트를 내지 않는다.
## - 난수를 쓰지 않는다. 순회는 instances(설치 순)와 맵 좌표(z, x)뿐이다.
## - TickLoop 에는 register_system("build", update, snapshot, restore) 로 등록한다(update 는 H5 정리만).
## - check_place() 는 UI 미리보기용 읽기 전용 쿼리(상태 불변, 이벤트 없음, build.md Q4).

# 명령(구독)
const CMD_PLACE: String = "build.place_requested"
const CMD_DEMOLISH: String = "build.demolish_requested"
# 상태 이벤트(발행)
const EV_PLACED: String = "build.placed"
const EV_REJECTED: String = "build.rejected"
const EV_DEMOLISHED: String = "build.demolished"
const EV_COVERAGE: String = "build.coverage_changed"
# economy 입력 계약(발행)·응답(구독)
const EV_CHARGE_PROPOSED: String = "economy.charge_proposed"
const EV_REFUND_PROPOSED: String = "economy.refund_proposed"
const EV_UPKEEP_REPORTED: String = "economy.upkeep_reported"
const EV_CHARGE_RESOLVED: String = "economy.charge_resolved"
const EV_PHASE_CHANGED: String = "time.phase_changed"

const ACTION_PLACE: String = "place"
const ACTION_DEMOLISH: String = "demolish"
# build.rejected reason 15종
const R_INVALID: String = "invalid"
const R_NOT_ALLOWED: String = "not_allowed"
const R_UNKNOWN_FURNITURE: String = "unknown_furniture"
const R_BAD_ROTATION: String = "bad_rotation"
const R_OUT_OF_BOUNDS: String = "out_of_bounds"
const R_BLOCKED_TILE: String = "blocked_tile"
const R_OVERLAP: String = "overlap"
const R_WALL_REQUIRED: String = "wall_required"
const R_LIMIT_REACHED: String = "limit_reached"
const R_PATH_BLOCKED: String = "path_blocked"
const R_INSUFFICIENT_CASH: String = "insufficient_cash"
const R_BANKRUPT: String = "bankrupt"
const R_CHARGE_INVALID: String = "charge_invalid"
const R_CHARGE_UNRESOLVED: String = "charge_unresolved"
const R_NOT_FOUND: String = "not_found"
## H3: economy decline_reason → build.rejected reason. 그 밖은 charge_invalid.
const DECLINE_TO_REASON: Dictionary = {"insufficient_cash": R_INSUFFICIENT_CASH, "bankrupt": R_BANKRUPT}

const CHARGE_REASON_BUILD: String = "build"
const REFUND_REASON_DEMOLISH: String = "demolish"
const REQUEST_PLACE_PREFIX: String = "build:place:"
const REQUEST_DEMOLISH_PREFIX: String = "build:demolish:"
const ENTITY_PREFIX: String = "f"
const FIRST_ENTITY: int = 1
## 새 게임 구간(build.md #상태 phase "day").
const NEW_GAME_PHASE: String = "day"
## 이 구간 진입 시 coverage_changed {cause:"sync"} (build.md #커버리지 "발행").
const PHASE_SYNC: String = "evening"
const CAUSE_PLACED: String = "placed"
const CAUSE_DEMOLISHED: String = "demolished"
const CAUSE_SYNC: String = "sync"

const SNAPSHOT_FIELDS: Array[String] = ["instances", "next_entity", "phase"]
const INSTANCE_FIELDS: Array[String] = ["entity_id", "furniture_id", "cell", "rotation", "paid"]

var config: BuildConfig
var bus: EventBus

# 상태 (읽기 전용으로 취급한다. 바꾸는 것은 BuildSystem 자신뿐)
## [{entity_id, furniture_id, cell: [x, z], rotation, paid}], entity 번호 오름차순(= 설치 순)
var instances: Array = []
var next_entity: int = FIRST_ENTITY
var phase: String = NEW_GAME_PHASE

var _occ: GridOccupancy = GridOccupancy.new()
var _path: TilePath
## null 또는 {request_id, furniture_id, cell, rotation, cells, cost} (H1~H5). 같은 경계 안에서 비워진다.
var _pending: Variant = null
var _coverage: Dictionary = {}


## 새 게임 상태로 만들고 구독한다. 이벤트를 내지 않는다. 커버리지는 내부에서 계산만 한다.
func _init(p_config: BuildConfig, p_bus: EventBus) -> void:
	if p_config == null or p_bus == null:
		push_error("[BuildSystem] config 와 bus 가 필요하다")
		return
	config = p_config
	bus = p_bus
	_path = TilePath.new(config.map)
	_recompute()
	bus.subscribe(CMD_PLACE, _on_place_requested)
	bus.subscribe(CMD_DEMOLISH, _on_demolish_requested)
	bus.subscribe(EV_CHARGE_RESOLVED, _on_charge_resolved)
	bus.subscribe(EV_PHASE_CHANGED, _on_phase_changed)


## TickLoop 단계 2. H5: 응답 없는 지출 제안 정리.
func update(_ctx: Dictionary) -> void:
	_flush_unresolved()


## 마지막 커버리지(= coverage_changed 페이로드에서 cause 뺀 것)의 깊은 복사본.
func coverage() -> Dictionary:
	return _coverage.duplicate(true)


## B1·B3~B10 판정만(구간 B2·자금 제외). 통과면 "". 상태 불변, 이벤트 없음(Q4, BC32).
func check_place(furniture_id: String, cell: Array, rotation: int) -> String:
	if not _is_int_pair(cell):
		return R_INVALID
	return _check_rules(furniture_id, cell, rotation)


## 경로 질의(SE-034 용, 읽기 전용). TilePath 참고.
func find_path(from: Array, to: Array) -> Array:
	return _path.find_path(from, to)


func path_from_entrance(to: Array) -> Array:
	return _path.path_from_entrance(to)


## {instances, next_entity, phase} 깊은 복사(기본형만). pending·파생값 제외. 상태 불변, 이벤트 없음(SH1·SH4).
func snapshot() -> Dictionary:
	return {"instances": instances.duplicate(true), "next_entity": next_entity, "phase": phase}


## RS1~RS7 을 전부 검사한 뒤 적용한다. 첫 위반에서 push_error 1회, false, 상태 불변, 이벤트 0(SH3·SH4).
## 성공하면 pending = null, 점유·경로·커버리지를 내부에서 다시 만든다(이벤트 없음).
func restore(d: Dictionary) -> bool:
	var parsed: Variant = _parse_snapshot(d)
	if parsed is String:
		push_error("[BuildSystem] restore: " + String(parsed))
		return false
	instances = parsed["instances"]
	next_entity = parsed["next_entity"]
	phase = parsed["phase"]
	_pending = null
	_rebuild_occupancy()
	_recompute()
	return true


# --- 명령·입력 핸들러 -------------------------------------------------------------

## B1~B11.
func _on_place_requested(p: Dictionary) -> void:
	_flush_unresolved()
	var fid: Variant = p.get("furniture_id")
	var cell: Variant = p.get("cell")
	var rot: Variant = p.get("rotation")
	var reason: String = ""
	if not (fid is String) or not _is_int_pair(cell) or not (rot is int):                     # B1
		reason = R_INVALID
	elif not config.furniture_table.allowed_phases.has(phase):                                 # B2
		reason = R_NOT_ALLOWED
	else:
		reason = _check_rules(fid, cell, rot)                                                   # B3~B10
	if reason != "":
		_reject_place(fid, cell, rot, reason)
		return
	var row: Dictionary = config.furniture_table.row_ref(fid)                                  # B11 → H1
	var rid: String = REQUEST_PLACE_PREFIX + ENTITY_PREFIX + str(next_entity)
	var cost: int = row["build_cost"]
	_pending = {
		"request_id": rid, "furniture_id": fid, "cell": [cell[0], cell[1]], "rotation": rot,
		"cells": GridOccupancy.cells_of(row["footprint"], cell, rot), "cost": cost,
	}
	bus.publish(EV_CHARGE_PROPOSED, {"request_id": rid, "reason": CHARGE_REASON_BUILD, "amount": cost})


## H2~H4.
func _on_charge_resolved(p: Dictionary) -> void:
	if _pending == null:
		return
	var pend: Dictionary = _pending
	if p.get("reason") != CHARGE_REASON_BUILD or p.get("request_id") != pend["request_id"]:   # H4
		return
	_pending = null
	if p.get("approved") != true:                                                              # H3
		var decline: Variant = p.get("decline_reason")
		var reason: String = DECLINE_TO_REASON.get(decline, R_CHARGE_INVALID)
		_reject_place(pend["furniture_id"], pend["cell"], pend["rotation"], reason)
		return
	var amount: Variant = MapConfig.as_int(p.get("amount"))                                    # H2
	var paid: int = amount if amount != null else int(pend["cost"])
	var eid: String = ENTITY_PREFIX + str(next_entity)
	instances.append({
		"entity_id": eid, "furniture_id": pend["furniture_id"], "cell": pend["cell"],
		"rotation": pend["rotation"], "paid": paid,
	})
	next_entity += 1
	_occ.add(eid, pend["cells"])
	_path.set_occupied(pend["cells"], true)
	_recompute()
	bus.publish(EV_PLACED, {
		"entity_id": eid, "furniture_id": pend["furniture_id"], "cell": pend["cell"],
		"rotation": pend["rotation"], "cells": pend["cells"], "cost": paid,
	})
	bus.publish(EV_UPKEEP_REPORTED, {"total": _coverage["upkeep_per_day"]})
	_publish_coverage(CAUSE_PLACED)


## D1~D4.
func _on_demolish_requested(p: Dictionary) -> void:
	_flush_unresolved()
	var eid: Variant = p.get("entity_id")
	if not (eid is String):                                                                    # D1
		_reject_demolish(eid, {}, R_INVALID)
		return
	var idx: int = _find_instance(eid)
	var inst: Dictionary = instances[idx] if idx >= 0 else {}
	if not config.furniture_table.allowed_phases.has(phase):                                   # D2
		_reject_demolish(eid, inst, R_NOT_ALLOWED)
		return
	if idx < 0:                                                                                # D3
		_reject_demolish(eid, inst, R_NOT_FOUND)
		return
	var row: Dictionary = config.furniture_table.row_ref(inst["furniture_id"])                 # D4 (상태 먼저)
	var cells: Array = GridOccupancy.cells_of(row["footprint"], inst["cell"], int(inst["rotation"]))
	instances.remove_at(idx)
	_occ.remove(eid, cells)
	_path.set_occupied(cells, false)
	_recompute()
	var paid: int = inst["paid"]
	bus.publish(EV_DEMOLISHED, {
		"entity_id": eid, "furniture_id": inst["furniture_id"], "cell": inst["cell"],
		"rotation": inst["rotation"], "cells": cells, "base_amount": paid,
	})
	bus.publish(EV_REFUND_PROPOSED, {
		"request_id": REQUEST_DEMOLISH_PREFIX + String(eid), "reason": REFUND_REASON_DEMOLISH, "base_amount": paid,
	})
	bus.publish(EV_UPKEEP_REPORTED, {"total": _coverage["upkeep_per_day"]})
	_publish_coverage(CAUSE_DEMOLISHED)


## 구간 추적. evening 진입이면 sync 1회.
func _on_phase_changed(p: Dictionary) -> void:
	var to: Variant = p.get("to")
	if not (to is String):
		push_warning("[BuildSystem] time.phase_changed 페이로드 무시: %s" % [p])
		return
	phase = to
	if phase == PHASE_SYNC:
		_publish_coverage(CAUSE_SYNC)


# --- 판정 ----------------------------------------------------------------------

## B3~B10 (처음 맞는 행). 상태를 바꾸지 않는다. cell 은 int 쌍이어야 한다.
func _check_rules(fid: String, cell: Array, rot: int) -> String:
	var ft: FurnitureConfig = config.furniture_table
	var m: MapConfig = config.map
	if not ft.has_furniture(fid):                                                              # B3
		return R_UNKNOWN_FURNITURE
	var row: Dictionary = ft.row_ref(fid)
	if not ft.allowed_rotations.has(rot) or (not row["rotatable"] and rot != GridOccupancy.ROT_0):  # B4
		return R_BAD_ROTATION
	var r: Rect2i = GridOccupancy.rect_of(row["footprint"], cell, rot)
	var cells: Array = GridOccupancy.rect_cells(r)
	for c: Array in cells:                                                                     # B5
		if not m.in_bounds(c[0], c[1]):
			return R_OUT_OF_BOUNDS
	for c: Array in cells:                                                                     # B6
		if not m.is_buildable(c[0], c[1]):
			return R_BLOCKED_TILE
	for c: Array in cells:                                                                     # B7
		if _occ.is_occupied(c[0], c[1]):
			return R_OVERLAP
	if row["wall_required"]:                                                                   # B8
		for c: Array in GridOccupancy.back_neighbors(r, rot):
			if not m.is_mountable(c[0], c[1]):
				return R_WALL_REQUIRED
	var cat: String = row["category"]                                                          # B9
	if ft.category_max_count.has(cat) and _count_category(cat) >= int(ft.category_max_count[cat]):
		return R_LIMIT_REACHED
	if _blocks_path(row, r, rot, cells):                                                       # B10
		return R_PATH_BLOCKED
	return ""


## B10 (a) 새 고립, (b) 입구 → 무대 앞 행 경로 없음.
func _blocks_path(row: Dictionary, r: Rect2i, rot: int, cells: Array) -> bool:
	var m: MapConfig = config.map
	var blocked: Dictionary = _occ.blocked_set()
	var r0: Dictionary = m.reachable(blocked)
	var added: Dictionary = {}
	for c: Array in cells:
		added[Vector2i(c[0], c[1])] = true
		blocked[Vector2i(c[0], c[1])] = true
	var r1: Dictionary = m.reachable(blocked)
	for t: Vector2i in r0:                                                                     # (a)
		if not added.has(t) and not r1.has(t):
			return true
	var front: Array = []                                                                      # (b)
	if row["category"] == FurnitureConfig.CATEGORY_STAGE:
		front = GridOccupancy.front_row(r, rot)
	else:
		var si: int = _stage_index()
		if si < 0:
			return false
		var s: Dictionary = instances[si]
		var srow: Dictionary = config.furniture_table.row_ref(s["furniture_id"])
		front = GridOccupancy.front_row(GridOccupancy.rect_of(srow["footprint"], s["cell"], int(s["rotation"])), int(s["rotation"]))
	for c: Array in front:
		if r1.has(Vector2i(c[0], c[1])):
			return false
	return true


func _count_category(cat: String) -> int:
	var n: int = 0
	for inst: Dictionary in instances:
		if config.furniture_table.row_ref(inst["furniture_id"])["category"] == cat:
			n += 1
	return n


func _stage_index() -> int:
	for i: int in instances.size():
		if config.furniture_table.row_ref(instances[i]["furniture_id"])["category"] == FurnitureConfig.CATEGORY_STAGE:
			return i
	return -1


func _find_instance(eid: String) -> int:
	for i: int in instances.size():
		if instances[i]["entity_id"] == eid:
			return i
	return -1


static func _is_int_pair(v: Variant) -> bool:
	return v is Array and (v as Array).size() == MapConfig.PAIR_SIZE and v[0] is int and v[1] is int


# --- 발행 ----------------------------------------------------------------------

## H5. 명령 처리 시작 시에도 부른다(응답 없는 제안을 덮어쓰지 않게).
func _flush_unresolved() -> void:
	if _pending == null:
		return
	var pend: Dictionary = _pending
	_pending = null
	push_warning("[BuildSystem] H5: economy 가 %s 에 응답하지 않았다(계약 위반). 배치를 거절한다" % pend["request_id"])
	_reject_place(pend["furniture_id"], pend["cell"], pend["rotation"], R_CHARGE_UNRESOLVED)


func _reject_place(fid: Variant, cell: Variant, rot: Variant, reason: String) -> void:
	bus.publish(EV_REJECTED, {
		"action": ACTION_PLACE, "reason": reason, "furniture_id": fid, "cell": cell, "rotation": rot, "entity_id": null,
	})


func _reject_demolish(eid: Variant, inst: Dictionary, reason: String) -> void:
	bus.publish(EV_REJECTED, {
		"action": ACTION_DEMOLISH, "reason": reason, "furniture_id": inst.get("furniture_id"),
		"cell": inst.get("cell"), "rotation": inst.get("rotation"), "entity_id": eid,
	})


func _publish_coverage(cause: String) -> void:
	var payload: Dictionary = {"cause": cause}
	for k: String in Coverage.KEYS:
		payload[k] = _coverage[k]
	bus.publish(EV_COVERAGE, payload)


# --- 파생 상태 --------------------------------------------------------------------

func _recompute() -> void:
	_coverage = Coverage.compute(config.map, config.furniture_table, config.rate_scale, instances)


func _rebuild_occupancy() -> void:
	_occ.clear()
	for inst: Dictionary in instances:
		var row: Dictionary = config.furniture_table.row_ref(inst["furniture_id"])
		_occ.add(inst["entity_id"], GridOccupancy.cells_of(row["footprint"], inst["cell"], int(inst["rotation"])))
	_path.sync(_occ)


## RS1~RS7. 성공이면 적용할 Dictionary(정규화된 깊은 복사), 실패면 오류 문자열.
func _parse_snapshot(d: Dictionary) -> Variant:
	var ft: FurnitureConfig = config.furniture_table
	var m: MapConfig = config.map
	for key: String in SNAPSHOT_FIELDS:                                                         # RS1
		if not d.has(key):
			return "RS1 필드 누락: %s" % key
	var raw: Variant = d["instances"]
	if not (raw is Array):
		return "RS1 instances 가 배열이 아니다"
	var ne: Variant = MapConfig.as_int(d["next_entity"])
	if ne == null or ne < FIRST_ENTITY:
		return "RS1 next_entity 가 %d 이상 정수가 아니다: %s" % [FIRST_ENTITY, d["next_entity"]]
	var ph: Variant = d["phase"]
	if not (ph is String or ph is StringName) or not SimConfig.PHASE_IDS.has(String(ph)):
		return "RS1 phase 가 구간 id 가 아니다: %s" % [ph]
	var out: Array = []
	var occ: GridOccupancy = GridOccupancy.new()
	var counts: Dictionary = {}
	var last_n: int = 0
	for e: Variant in raw:
		if not (e is Dictionary):
			return "RS1 instances[] 원소가 객체가 아니다"
		for key: String in INSTANCE_FIELDS:
			if not (e as Dictionary).has(key):
				return "RS1 instances[] 필드 누락: %s" % key
		var eid: Variant = e["entity_id"]
		var fid: Variant = e["furniture_id"]
		var cell: Variant = MapConfig.as_int_pair(e["cell"])
		var rot: Variant = MapConfig.as_int(e["rotation"])
		var paid: Variant = MapConfig.as_int(e["paid"])
		if not (eid is String) or not (fid is String) or cell == null or rot == null or paid == null:
			return "RS1 instances[] 타입 오류: %s" % [e]
		var n: int = _entity_number(eid)                                                        # RS2
		if n < FIRST_ENTITY:
			return "RS2 entity_id 형식 오류: '%s'" % eid
		if n >= ne:
			return "RS2 entity_id '%s' 번호가 next_entity %d 이상이다" % [eid, ne]
		if n <= last_n:
			return "RS2 entity_id '%s' 번호가 엄격히 증가하지 않는다" % eid
		last_n = n
		if not ft.has_furniture(fid):                                                          # RS3
			return "RS3 모르는 furniture_id: %s" % fid
		var row: Dictionary = ft.row_ref(fid)
		if not ft.allowed_rotations.has(rot) or (not row["rotatable"] and rot != GridOccupancy.ROT_0):
			return "RS3 %s 의 rotation %d 가 허용되지 않는다" % [eid, rot]
		var cells: Array = GridOccupancy.cells_of(row["footprint"], cell, rot)
		for c: Array in cells:                                                                 # RS4
			if not m.is_buildable(c[0], c[1]):
				return "RS4 %s 의 셀 [%d,%d] 가 맵 밖이거나 buildable 이 아니다" % [eid, c[0], c[1]]
		if not occ.add(eid, cells):                                                            # RS5
			return "RS5 %s 가 다른 인스턴스와 겹친다" % eid
		var cat: String = row["category"]                                                      # RS6
		counts[cat] = int(counts.get(cat, 0)) + 1
		if ft.category_max_count.has(cat) and counts[cat] > int(ft.category_max_count[cat]):
			return "RS6 카테고리 %s 설치 수가 한도 %d 를 넘는다" % [cat, ft.category_max_count[cat]]
		if paid < 0:                                                                           # RS7
			return "RS7 %s 의 paid 가 음수다: %d" % [eid, paid]
		out.append({"entity_id": eid, "furniture_id": fid, "cell": cell, "rotation": rot, "paid": paid})
	return {"instances": out, "next_entity": ne, "phase": String(ph)}


## "f<n>"(n ≥ 1, 앞자리 0 없음) → n. 형식이 틀리면 0.
static func _entity_number(eid: String) -> int:
	if not eid.begins_with(ENTITY_PREFIX):
		return 0
	var num: String = eid.substr(ENTITY_PREFIX.length())
	if not num.is_valid_int() or str(num.to_int()) != num:
		return 0
	return maxi(num.to_int(), 0)
