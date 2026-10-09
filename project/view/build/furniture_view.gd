class_name FurnitureView
extends Node3D
## SE-037: 설치된 가구를 그린다. build.placed → 인스턴스 노드 생성, build.demolished → 삭제,
## session.loaded → 전부 지움(SE-036: 로드 뒤 build 가 build.placed 를 전부 다시 낸다).
## 구독만 한다. 이벤트를 발행하지 않고 게임 상태를 바꾸지 않는다(CLAUDE.md 원칙 1).
##
## 노드 구조: FurnitureView / <entity_id>(Node3D, 위치 = build.md G5, rotation_degrees.y = rotation) / Proxy | Model
##   Proxy = 회전 0 기준 footprint(w × d) × height_m BoxMesh, 단일 base 서피스, 정점색 = slots.base(materials.md).
##   Model = 행의 model(res://... .glb, build.md FC4)이 있고 리소스가 있으면 그 씬(SE-041). 없으면 Proxy.
## 시안 머티리얼은 ShaderVariants.apply_materials 로 씌운다(기본 ShaderVariants.DEFAULT_ID = 시안 B).

## 노드가 바뀔 때(생성·삭제·전체 지움). 고스트가 점유 추정을 다시 하는 데 쓴다.
signal instances_changed

const EV_PLACED: String = "build.placed"
const EV_DEMOLISHED: String = "build.demolished"
const EV_SESSION_LOADED: String = "session.loaded"
const PROXY_NAME: StringName = &"Proxy"
const MODEL_NAME: StringName = &"Model"
const DEFAULT_PARAMS_PATH: String = "res://view/build/build_view_params.tres"

@export var params: BuildViewParams

var _bus: EventBus
var _catalog: BuildCatalog
var _tile_m: float = 1.0
var _material_id: String = ShaderVariants.DEFAULT_ID
## entity_id -> {node: Node3D, furniture_id: String, cell: Vector2i, rotation: int, cells: Array[Vector2i]}
var _entries: Dictionary = {}
## Vector2i -> entity_id
var _occupancy: Dictionary = {}


## 버스 구독을 시작한다. tile_m = sim.json tile_size_m(GridView.get_tile_size_m()).
func bind(bus: EventBus, catalog: BuildCatalog, tile_m: float) -> void:
	if params == null:
		params = load(DEFAULT_PARAMS_PATH) as BuildViewParams
	_unsubscribe()
	_bus = bus
	_catalog = catalog
	_tile_m = tile_m
	if _bus != null:
		_bus.subscribe(EV_PLACED, on_placed)
		_bus.subscribe(EV_DEMOLISHED, on_demolished)
		_bus.subscribe(EV_SESSION_LOADED, on_session_loaded)


func _exit_tree() -> void:
	_unsubscribe()


func _unsubscribe() -> void:
	if _bus == null:
		return
	_bus.unsubscribe(EV_PLACED, on_placed)
	_bus.unsubscribe(EV_DEMOLISHED, on_demolished)
	_bus.unsubscribe(EV_SESSION_LOADED, on_session_loaded)
	_bus = null


## 시안을 바꾼다(샌드박스 키 1/2/3). 이미 있는 노드에도 다시 씌운다. 없는 id 면 false(아무것도 안 바꿈).
func set_material_id(id: String) -> bool:
	if not ShaderVariants.is_valid_id(id):
		push_error("FurnitureView: 시안 '%s' 없음" % id)
		return false
	_material_id = id
	for e: Dictionary in _entries.values():
		ShaderVariants.apply_materials(e["node"] as Node3D, _material_id)
	return true


func get_material_id() -> String:
	return _material_id


# --- 구독 핸들러 --------------------------------------------------------------

## build.placed 페이로드 {entity_id, furniture_id, cell, rotation, cells, cost}. 같은 entity_id 가 이미 있으면 교체.
func on_placed(payload: Dictionary) -> void:
	var entity_id: String = str(payload.get("entity_id", ""))
	var furniture_id: String = str(payload.get("furniture_id", ""))
	var cell: Vector2i = BuildCatalog.to_cell(payload.get("cell"))
	var rotation_deg: int = int(payload.get("rotation", 0))
	if entity_id.is_empty() or cell == IsoGridMath.INVALID_TILE or _catalog == null or not _catalog.has_furniture(furniture_id):
		push_warning("FurnitureView: build.placed 를 그릴 수 없다 (entity %s, furniture %s)" % [entity_id, furniture_id])
		return
	if _entries.has(entity_id):
		_remove_entry(entity_id)
	var row: Dictionary = _catalog.furniture(furniture_id)
	var fp: Vector2i = BuildCatalog.footprint_of(row)
	var node: Node3D = Node3D.new()
	node.name = entity_id
	node.position = BuildCatalog.center_world(fp, cell, rotation_deg, _tile_m)
	node.rotation_degrees = Vector3(0.0, float(rotation_deg), 0.0)
	node.add_child(_make_body(row))
	add_child(node)
	ShaderVariants.apply_materials(node, _material_id)
	var cells: Array[Vector2i] = BuildCatalog.cells_of(fp, cell, rotation_deg)
	_entries[entity_id] = {"node": node, "furniture_id": furniture_id, "cell": cell, "rotation": rotation_deg, "cells": cells}
	for c: Vector2i in cells:
		_occupancy[c] = entity_id
	instances_changed.emit()


## build.demolished 페이로드 {entity_id, …}. 모르는 id 는 무시.
func on_demolished(payload: Dictionary) -> void:
	var entity_id: String = str(payload.get("entity_id", ""))
	if not _entries.has(entity_id):
		return
	_remove_entry(entity_id)
	instances_changed.emit()


## session.loaded: 전부 지운다. 이어서 오는 build.placed 재발행(SE-036)으로 다시 그린다.
func on_session_loaded(_payload: Dictionary) -> void:
	clear_all()


func clear_all() -> void:
	for id: String in _entries.keys():
		_remove_entry(id)
	instances_changed.emit()


# --- 조회 (읽기 전용) ---------------------------------------------------------

func get_instance_count() -> int:
	return _entries.size()


func get_entity_ids() -> PackedStringArray:
	return PackedStringArray(_entries.keys())


func get_instance_node(entity_id: String) -> Node3D:
	if not _entries.has(entity_id):
		return null
	return (_entries[entity_id] as Dictionary)["node"] as Node3D


## 인스턴스 정보 사본 {furniture_id, cell, rotation, cells}(없으면 {}).
func get_instance(entity_id: String) -> Dictionary:
	if not _entries.has(entity_id):
		return {}
	var e: Dictionary = _entries[entity_id]
	return {"furniture_id": e["furniture_id"], "cell": e["cell"], "rotation": e["rotation"], "cells": (e["cells"] as Array).duplicate()}


## 셀을 점유한 entity_id(없으면 "").
func entity_at(cell: Vector2i) -> String:
	return str(_occupancy.get(cell, ""))


func is_occupied(cell: Vector2i) -> bool:
	return _occupancy.has(cell)


## 프록시 BoxMesh 의 정점색(slots.base). hex 가 아니면 params.proxy_fallback_color.
func base_color_of(row: Dictionary) -> Color:
	var slots: Dictionary = row.get("slots", {}) as Dictionary
	var s: String = str(slots.get("base", ""))
	if Color.html_is_valid(s):
		return Color.html(s)
	return params.proxy_fallback_color


# --- 내부 -------------------------------------------------------------------

func _make_body(row: Dictionary) -> Node3D:
	var model_path: String = str(row.get("model", ""))
	if not model_path.is_empty() and ResourceLoader.exists(model_path):
		var scene: PackedScene = load(model_path) as PackedScene
		if scene != null:
			var model: Node3D = scene.instantiate() as Node3D
			if model != null:
				model.name = MODEL_NAME
				return model
		push_warning("FurnitureView: %s 모델 로드 실패, 프록시로 그린다 (%s)" % [row.get("id", ""), model_path])
	var fp: Vector2i = BuildCatalog.footprint_of(row)
	var h: float = float(row.get("height_m", 1.0))
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(float(fp.x) * _tile_m, h, float(fp.y) * _tile_m)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = PROXY_NAME
	mi.mesh = ShaderPlaceholders.colorize(box, base_color_of(row), Color.WHITE, false)
	mi.position = Vector3(0.0, h * 0.5, 0.0)
	return mi


func _remove_entry(entity_id: String) -> void:
	var e: Dictionary = _entries[entity_id]
	for c: Vector2i in e["cells"]:
		if str(_occupancy.get(c, "")) == entity_id:
			_occupancy.erase(c)
	var node: Node3D = e["node"] as Node3D
	remove_child(node)
	node.queue_free()
	_entries.erase(entity_id)
