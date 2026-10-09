class_name BuildTestUtil
extends RefCounted
## SE-037 배치 UI 테스트 공용 헬퍼(테스트 파일 아님). 가짜 sim 역할: 버스에 build.* 상태 이벤트를 직접 발행한다.
## 기대값은 데이터(furniture.json·tier1_club.json)에서 읽는다 — 코드에 가구 수·비용 리터럴을 두지 않는다.

const FURNITURE_PATH: String = "res://data/furniture/furniture.json"
const MAP_PATH: String = "res://data/maps/tier1_club.json"


static func furniture_json() -> Dictionary:
	return ViewTestUtil.read_json(FURNITURE_PATH) as Dictionary


static func map_json() -> Dictionary:
	return ViewTestUtil.read_json(MAP_PATH) as Dictionary


static func catalog() -> BuildCatalog:
	return BuildCatalog.load_default()


static func row(id: String) -> Dictionary:
	for r: Dictionary in furniture_json()["rows"]:
		if r["id"] == id:
			return r
	return {}


## 테스트 쪽 독립 계산: 회전 후 [W', D'] (build.md G2).
static func rotated_wd(footprint: Array, rotation: int) -> Vector2i:
	var w: int = int(footprint[0])
	var d: int = int(footprint[1])
	return Vector2i(d, w) if rotation == 90 or rotation == 270 else Vector2i(w, d)


## 테스트 쪽 독립 계산: 점유 셀 [[x, z], …] (G3·G6).
static func cells_pairs(footprint: Array, cell: Vector2i, rotation: int) -> Array:
	var s: Vector2i = rotated_wd(footprint, rotation)
	var out: Array = []
	for z: int in range(cell.y, cell.y + s.y):
		for x: int in range(cell.x, cell.x + s.x):
			out.append([x, z])
	return out


## build.placed 페이로드(events.md 형식).
static func placed(entity_id: String, furniture_id: String, cell: Vector2i, rotation: int) -> Dictionary:
	var r: Dictionary = row(furniture_id)
	return {
		"entity_id": entity_id, "furniture_id": furniture_id, "cell": [cell.x, cell.y], "rotation": rotation,
		"cells": cells_pairs(r["footprint"], cell, rotation), "cost": int(r["build_cost"]),
	}


static func demolished(entity_id: String, furniture_id: String, cell: Vector2i, rotation: int) -> Dictionary:
	var p: Dictionary = placed(entity_id, furniture_id, cell, rotation)
	p.erase("cost")
	p["base_amount"] = int(row(furniture_id)["build_cost"])
	return p


static func press(node: Node, action: StringName) -> void:
	var ev: InputEventAction = InputEventAction.new()
	ev.action = action
	ev.pressed = true
	node._unhandled_input(ev)
