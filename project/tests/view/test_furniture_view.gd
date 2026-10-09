extends GutTest
## SE-037 AC1: FurnitureView — 가짜 버스에 build.placed 20종 주입 → 노드 20개, 위치(G5)·회전·프록시 크기·색,
## build.demolished → 삭제, session.loaded → 전부 지움. 기대값은 데이터에서 읽는다.

const ROTATIONS: Array[int] = [0, 90, 180, 270]
const EPS: float = 0.0001

var _bus: EventBus
var _view: FurnitureView
var _t: float


func before_each() -> void:
	_bus = EventBus.new()
	_t = ViewTestUtil.expected_tile_size_m()
	_view = FurnitureView.new()
	add_child_autofree(_view)
	_view.bind(_bus, BuildTestUtil.catalog(), _t)


## 행 i 를 겹치지 않는 자리에 놓는다(view 는 겹침을 판정하지 않지만 점유 조회 단언을 위해).
func _cell_for(i: int) -> Vector2i:
	return Vector2i((i % 4) * 6 + 1, (i / 4) * 5 + 1)


func _rotation_for(r: Dictionary, i: int) -> int:
	return ROTATIONS[i % ROTATIONS.size()] if bool(r["rotatable"]) else 0


func _place_all_rows() -> Array:
	var rows: Array = BuildTestUtil.furniture_json()["rows"]
	for i: int in rows.size():
		var r: Dictionary = rows[i]
		_bus.publish("build.placed", BuildTestUtil.placed("f%d" % (i + 1), r["id"], _cell_for(i), _rotation_for(r, i)))
	return rows


func test_placed_all_rows_creates_one_node_each() -> void:
	var rows: Array = _place_all_rows()
	assert_gt(rows.size(), 0, "furniture.json 행이 있다")
	assert_eq(_view.get_instance_count(), rows.size(), "노드 수 = furniture.json 행 수")
	var seen_rot: Dictionary = {}
	for i: int in rows.size():
		var r: Dictionary = rows[i]
		var rot: int = _rotation_for(r, i)
		seen_rot[rot] = true
		var node: Node3D = _view.get_instance_node("f%d" % (i + 1))
		assert_not_null(node, "%s 노드" % r["id"])
		if node == null:
			continue
		assert_eq(node.get_parent(), _view, "FurnitureView 직속")
		var wd: Vector2i = BuildTestUtil.rotated_wd(r["footprint"], rot)
		var c: Vector2i = _cell_for(i)
		var want: Vector3 = Vector3((c.x + wd.x * 0.5) * _t, 0.0, (c.y + wd.y * 0.5) * _t)
		assert_true(node.position.is_equal_approx(want), "%s 위치 G5 %s == %s" % [r["id"], node.position, want])
		assert_almost_eq(node.rotation_degrees.y, float(rot), EPS, "%s 회전 = rotation" % r["id"])
	assert_eq(seen_rot.size(), ROTATIONS.size(), "회전 4종이 섞였다")


func test_proxy_size_and_base_color_match_data() -> void:
	var rows: Array = _place_all_rows()
	for i: int in rows.size():
		var r: Dictionary = rows[i]
		var node: Node3D = _view.get_instance_node("f%d" % (i + 1))
		var proxy: MeshInstance3D = node.get_node_or_null(^"Proxy") as MeshInstance3D
		assert_not_null(proxy, "%s Proxy (model 키 없음)" % r["id"])
		if proxy == null:
			continue
		var fp: Array = r["footprint"]
		var h: float = float(r["height_m"])
		var size: Vector3 = proxy.mesh.get_aabb().size
		assert_true(size.is_equal_approx(Vector3(float(fp[0]) * _t, h, float(fp[1]) * _t)),
			"%s 프록시 = footprint × height_m (%s)" % [r["id"], size])
		assert_almost_eq(proxy.position.y, h * 0.5, EPS, "%s 바닥 y = 0" % r["id"])
		# 회전 후 월드 점유 = [W', D'] (G2).
		var world: AABB = node.transform * proxy.transform * proxy.mesh.get_aabb()
		var wd: Vector2i = BuildTestUtil.rotated_wd(fp, _rotation_for(r, i))
		assert_almost_eq(world.size.x, wd.x * _t, 0.001, "%s 월드 x 폭 = W'" % r["id"])
		assert_almost_eq(world.size.z, wd.y * _t, 0.001, "%s 월드 z 폭 = D'" % r["id"])
		var colors: PackedColorArray = proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		var want: Color = Color.html(str(r["slots"]["base"]))
		assert_true(colors[0].is_equal_approx(Color(want.r, want.g, want.b, 1.0)), "%s 정점색 = slots.base" % r["id"])
		assert_eq(proxy.mesh.get_surface_count(), 1, "%s 단일 base 서피스" % r["id"])


func test_default_shader_variant_applied() -> void:
	_place_all_rows()
	var want: ShaderMaterial = ShaderVariants.load_material(ShaderVariants.DEFAULT_ID)
	for id: String in _view.get_entity_ids():
		var proxy: MeshInstance3D = _view.get_instance_node(id).get_node(^"Proxy") as MeshInstance3D
		assert_not_null(proxy.material_override, "%s 시안 머티리얼" % id)
		assert_eq(proxy.material_override.resource_path, want.resource_path, "%s 기본 시안(DEFAULT_ID)" % id)
	assert_true(_view.set_material_id(ShaderVariants.PLAIN_ID), "plain 으로 전환")
	var p: MeshInstance3D = _view.get_instance_node("f1").get_node(^"Proxy") as MeshInstance3D
	assert_null(p.material_override, "plain = 원래 머티리얼")


func test_demolished_removes_node_and_occupancy() -> void:
	_bus.publish("build.placed", BuildTestUtil.placed("f1", "bar_counter", Vector2i(20, 4), 90))
	_bus.publish("build.placed", BuildTestUtil.placed("f2", "speaker_floor", Vector2i(5, 5), 0))
	assert_eq(_view.get_instance_count(), 2)
	for z: int in [4, 5, 6]:
		assert_eq(_view.entity_at(Vector2i(20, z)), "f1", "bar_counter r90 점유 [20,%d]" % z)
	assert_eq(_view.entity_at(Vector2i(21, 4)), "", "점유 밖")
	var node: Node3D = _view.get_instance_node("f1")
	_bus.publish("build.demolished", BuildTestUtil.demolished("f1", "bar_counter", Vector2i(20, 4), 90))
	assert_eq(_view.get_instance_count(), 1, "철거 → 1개")
	assert_null(_view.get_instance_node("f1"), "f1 조회 없음")
	assert_false(node.is_inside_tree(), "f1 노드가 트리에서 빠졌다")
	assert_eq(_view.entity_at(Vector2i(20, 5)), "", "점유 해제")
	assert_eq(_view.entity_at(Vector2i(5, 5)), "f2", "다른 가구 유지")
	_bus.publish("build.demolished", {"entity_id": "f99"})
	assert_eq(_view.get_instance_count(), 1, "모르는 id 는 무시")


func test_duplicate_placed_replaces_and_session_loaded_clears() -> void:
	_bus.publish("build.placed", BuildTestUtil.placed("f1", "speaker_floor", Vector2i(5, 5), 0))
	_bus.publish("build.placed", BuildTestUtil.placed("f1", "speaker_floor", Vector2i(8, 8), 90))
	assert_eq(_view.get_instance_count(), 1, "같은 entity_id 는 교체(SE-036 재발행 대비)")
	assert_eq(_view.entity_at(Vector2i(5, 5)), "", "옛 점유 해제")
	assert_eq(_view.entity_at(Vector2i(8, 8)), "f1")
	_bus.publish("build.placed", BuildTestUtil.placed("f2", "bench", Vector2i(1, 10), 270))
	_bus.publish("session.loaded", {"day": 3})
	assert_eq(_view.get_instance_count(), 0, "session.loaded → 전부 지움")
	assert_false(_view.is_occupied(Vector2i(1, 10)), "점유도 지움")
	_bus.publish("build.placed", BuildTestUtil.placed("f2", "bench", Vector2i(1, 10), 270))
	assert_eq(_view.get_instance_count(), 1, "재발행된 build.placed 로 다시 그린다")


func test_unknown_furniture_is_ignored() -> void:
	_bus.publish("build.placed", {"entity_id": "f1", "furniture_id": "stage_huge", "cell": [5, 5], "rotation": 0, "cells": [[5, 5]], "cost": 1})
	assert_eq(_view.get_instance_count(), 0, "모르는 가구는 그리지 않는다(push_warning)")


func test_model_branch_loads_scene_when_model_exists() -> void:
	var f: Dictionary = BuildTestUtil.furniture_json()
	var m: Dictionary = BuildTestUtil.map_json()
	# 리포지토리에 .glb 가 아직 없으므로(SE-041) 존재하는 view 씬으로 분기만 확인한다.
	for r: Dictionary in f["rows"]:
		if r["id"] == "speaker_floor":
			r["model"] = "res://view/scenes/shader_placeholders.tscn"
		elif r["id"] == "bench":
			r["model"] = "res://view/build/__missing__.glb"
	var view: FurnitureView = FurnitureView.new()
	add_child_autofree(view)
	view.bind(_bus, BuildCatalog.from_dicts(f, m), _t)
	_bus.publish("build.placed", BuildTestUtil.placed("f1", "speaker_floor", Vector2i(5, 5), 0))
	_bus.publish("build.placed", BuildTestUtil.placed("f2", "bench", Vector2i(1, 10), 270))
	assert_not_null(view.get_instance_node("f1").get_node_or_null(^"Model"), "model 리소스가 있으면 Model")
	assert_null(view.get_instance_node("f1").get_node_or_null(^"Proxy"), "Model 이면 Proxy 없음")
	assert_not_null(view.get_instance_node("f2").get_node_or_null(^"Proxy"), "model 경로에 리소스가 없으면 Proxy")
