class_name PlacementGhost
extends Node3D
## SE-037: 배치 고스트(미리보기)와 배치·철거 명령 발행.
## 팔레트에서 가구를 고르면(select) 호버 타일(hover)에 고스트 상자를 띄운다. 색은 view 쪽 **추정**:
##   맵 밖(out_of_bounds) / 배치 불가 타일(blocked_tile) / 점유 겹침(overlap) / 벽 비인접(wall_required) → 무효(빨강),
##   그 밖 → 유효(녹색). 자금·구간·한도·경로는 sim 이 판정한다(build.md B2·B9·B10·H3). 최종 결과는 build.placed/rejected.
##   SE-032 병합 뒤 build.md Q4 의 check_place() 읽기 전용 쿼리로 바꿀 자리(estimate_reason 한 곳).
## 클릭(build_confirm) → build.place_requested {furniture_id, cell:[x,z], rotation}(무효 추정이면 보내지 않는다).
## 철거 모드(build_demolish) → 클릭한 셀의 가구가 있으면 build.demolish_requested {entity_id}, 빈 타일이면 아무것도 없음.
## 회전(build_rotate) → rotation 순환(rotatable == false 면 고정). 취소(build_cancel) → 선택 해제, 이벤트 없음.
## 게임 상태를 바꾸지 않는다. 버스에는 *_requested 명령만 발행한다(CLAUDE.md 원칙 1).

## 모드·선택·회전·호버·유효성이 바뀔 때. 팔레트 상태 문구 갱신용.
signal state_changed

enum Mode { NONE, PLACE, DEMOLISH }

const DEFAULT_PARAMS_PATH: String = "res://view/build/build_view_params.tres"
const BOX_NAME: StringName = &"GhostBox"
const LABEL_NAME: StringName = &"ReasonLabel"
const RADIUS_NAME: StringName = &"RadiusPreview"
## 반경 미리보기에 쓰는 effects 필드(UI 계약: *_radius). 색은 params.radius_preview_colors[필드].
const RADIUS_FIELDS: PackedStringArray = ["sound_radius", "bar_service_radius"]
## estimate_reason 이 돌려줄 수 있는 값(build.md B5~B8 의 reason 과 같은 이름).
const REASON_OUT_OF_BOUNDS: String = "out_of_bounds"
const REASON_BLOCKED_TILE: String = "blocked_tile"
const REASON_OVERLAP: String = "overlap"
const REASON_WALL_REQUIRED: String = "wall_required"

@export var params: BuildViewParams

var _bus: EventBus
var _catalog: BuildCatalog
var _furniture: FurnitureView
var _tile_m: float = 1.0
var _mode: Mode = Mode.NONE
var _furniture_id: String = ""
var _rotation: int = 0
var _hover: Vector2i = IsoGridMath.INVALID_TILE
var _reason: String = ""

var _box: MeshInstance3D
var _box_mat: StandardMaterial3D
var _label: Label3D
var _radius: MultiMeshInstance3D


func bind(bus: EventBus, catalog: BuildCatalog, furniture: FurnitureView, tile_m: float) -> void:
	if params == null:
		params = load(DEFAULT_PARAMS_PATH) as BuildViewParams
	_bus = bus
	_catalog = catalog
	_furniture = furniture
	_tile_m = tile_m
	_build_visuals()
	if _furniture != null and not _furniture.instances_changed.is_connected(_refresh):
		_furniture.instances_changed.connect(_refresh)
	_refresh()


# --- 조작 -------------------------------------------------------------------

## 팔레트 선택. 모르는 id 면 false(상태 불변). 회전은 allowed_rotations 의 처음 값으로.
func select(furniture_id: String) -> bool:
	if _catalog == null or not _catalog.has_furniture(furniture_id):
		push_warning("PlacementGhost: 가구 '%s' 없음" % furniture_id)
		return false
	_mode = Mode.PLACE
	_furniture_id = furniture_id
	_rotation = _catalog.allowed_rotations()[0]
	_refresh()
	return true


## 철거 모드 켜기/끄기. 켜면 가구 선택은 해제된다.
func set_demolish_mode(on: bool) -> void:
	_mode = Mode.DEMOLISH if on else Mode.NONE
	_furniture_id = ""
	_refresh()


## 취소(Esc): 선택·철거 모드 해제, 고스트 숨김. 이벤트 없음.
func cancel() -> void:
	_mode = Mode.NONE
	_furniture_id = ""
	_refresh()


## 회전(R): 다음 회전. 선택이 없거나 rotatable == false 면 그대로. 바뀌었으면 true.
func rotate_selection() -> bool:
	if _mode != Mode.PLACE:
		return false
	var next: int = _catalog.next_rotation(_furniture_id, _rotation)
	if next == _rotation:
		return false
	_rotation = next
	_refresh()
	return true


## 호버 타일(= 명령 cell, 회전 후 점유 사각형의 최소 모서리 G3). INVALID_TILE 이면 고스트를 숨긴다.
func hover(tile: Vector2i) -> void:
	if tile == _hover:
		return
	_hover = tile
	_refresh()


## TileCursor.hovered_tile_changed 연결용.
func on_cursor_hover(tile: Vector2i, _inside: bool) -> void:
	hover(tile)


## 클릭(build_confirm). 명령을 발행했으면 true.
## PLACE: 유효 추정일 때만 build.place_requested 1건. DEMOLISH: 호버 셀에 가구가 있을 때만 build.demolish_requested 1건.
func click() -> bool:
	if _bus == null or _hover == IsoGridMath.INVALID_TILE:
		return false
	match _mode:
		Mode.PLACE:
			if not _reason.is_empty():
				return false
			return _bus.publish("build.place_requested", {
				"furniture_id": _furniture_id,
				"cell": BuildCatalog.to_pair(_hover),
				"rotation": int(_rotation),
			})
		Mode.DEMOLISH:
			var entity_id: String = _furniture.entity_at(_hover) if _furniture != null else ""
			if entity_id.is_empty():
				return false
			return _bus.publish("build.demolish_requested", {"entity_id": entity_id})
	return false


func _unhandled_input(event: InputEvent) -> void:
	if _catalog == null:
		return
	var handled: bool = true
	if event.is_action_pressed(InputActions.BUILD_ROTATE):
		rotate_selection()
	elif event.is_action_pressed(InputActions.BUILD_CANCEL):
		if _mode == Mode.NONE:
			handled = false
		cancel()
	elif event.is_action_pressed(InputActions.BUILD_DEMOLISH):
		set_demolish_mode(_mode != Mode.DEMOLISH)
	elif event.is_action_pressed(InputActions.BUILD_CONFIRM):
		if _mode == Mode.NONE:
			handled = false
		click()
	else:
		handled = false
	if handled and is_inside_tree():
		get_viewport().set_input_as_handled()


# --- 조회 -------------------------------------------------------------------

func get_mode() -> Mode:
	return _mode


func get_selected_id() -> String:
	return _furniture_id


func get_rotation_deg() -> int:
	return _rotation


func get_hovered_tile() -> Vector2i:
	return _hover


## 현재 추정 무효 사유("" = 유효 추정). PLACE 모드가 아니면 "".
func get_reason() -> String:
	return _reason


func is_valid() -> bool:
	return _mode == Mode.PLACE and _reason.is_empty()


## 고스트 상자가 보이는가.
func is_ghost_visible() -> bool:
	return _box != null and _box.visible


## 고스트 상자 색(params 의 유효/무효/철거 색 중 하나). 숨김이면 투명.
func get_ghost_color() -> Color:
	if not is_ghost_visible():
		return Color(0, 0, 0, 0)
	return _box_mat.albedo_color


func get_radius_preview_count() -> int:
	if _radius == null or not _radius.visible or _radius.multimesh == null:
		return 0
	return _radius.multimesh.instance_count


## view 쪽 유효성 추정(build.md B5~B8 중 view 가 아는 것). "" = 유효 추정.
## 점유는 FurnitureView 가 받은 build.placed 기준. 자금(H3)·구간(B2)·한도(B9)·경로(B10)는 판정하지 않는다.
func estimate_reason(furniture_id: String, cell: Vector2i, rotation_deg: int) -> String:
	var row: Dictionary = _catalog.furniture(furniture_id)
	var fp: Vector2i = BuildCatalog.footprint_of(row)
	var cells: Array[Vector2i] = BuildCatalog.cells_of(fp, cell, rotation_deg)
	for c: Vector2i in cells:
		if not _catalog.is_inside(c):
			return REASON_OUT_OF_BOUNDS
	for c: Vector2i in cells:
		if not bool(_catalog.tile_kind(c).get("buildable", false)):
			return REASON_BLOCKED_TILE
	if _furniture != null:
		for c: Vector2i in cells:
			if _furniture.is_occupied(c):
				return REASON_OVERLAP
	if bool(row.get("wall_required", false)):
		for n: Vector2i in BuildCatalog.back_neighbors(fp, cell, rotation_deg):
			if not bool(_catalog.tile_kind(n).get("mountable", false)):
				return REASON_WALL_REQUIRED
	return ""


# --- 표시 -------------------------------------------------------------------

func _refresh() -> void:
	if _catalog == null or _box == null:
		return
	_reason = ""
	var on: bool = _hover != IsoGridMath.INVALID_TILE
	match _mode:
		Mode.PLACE:
			_reason = estimate_reason(_furniture_id, _hover, _rotation) if on else ""
			if on:
				_show_place()
		Mode.DEMOLISH:
			on = on and _furniture != null and not _furniture.entity_at(_hover).is_empty()
			if on:
				_show_demolish()
		_:
			on = false
	_box.visible = on
	_label.visible = on and not _label.text.is_empty()
	if not on or _mode != Mode.PLACE:
		_radius.visible = false
	state_changed.emit()


func _show_place() -> void:
	var row: Dictionary = _catalog.furniture(_furniture_id)
	var fp: Vector2i = BuildCatalog.footprint_of(row)
	var h: float = float(row.get("height_m", 1.0))
	_place_box(fp, _hover, _rotation, h, params.ghost_invalid_color if not _reason.is_empty() else params.ghost_valid_color)
	_label.text = _reason
	_update_radius_preview(row, fp)


func _show_demolish() -> void:
	var info: Dictionary = _furniture.get_instance(_furniture.entity_at(_hover))
	var row: Dictionary = _catalog.furniture(str(info["furniture_id"]))
	_place_box(BuildCatalog.footprint_of(row), info["cell"], int(info["rotation"]), float(row.get("height_m", 1.0)),
		params.demolish_color)
	_label.text = ""


func _place_box(fp: Vector2i, cell: Vector2i, rotation_deg: int, height_m: float, color: Color) -> void:
	var pad: float = params.ghost_padding_m
	(_box.mesh as BoxMesh).size = Vector3(float(fp.x) * _tile_m + pad, height_m + pad, float(fp.y) * _tile_m + pad)
	_box.position = BuildCatalog.center_world(fp, cell, rotation_deg, _tile_m) + Vector3(0.0, height_m * 0.5, 0.0)
	_box.rotation_degrees = Vector3(0.0, float(rotation_deg), 0.0)
	_box_mat.albedo_color = color
	_label.position = _box.position + Vector3(0.0, height_m * 0.5 + params.ghost_label_offset_m, 0.0)


## 선택 가구의 effects.*_radius 가 덮는 맵 안 셀(커버리지 거리식)을 반투명 타일로.
func _update_radius_preview(row: Dictionary, fp: Vector2i) -> void:
	var effects: Dictionary = row.get("effects", {}) as Dictionary
	var cells: Array[Vector2i] = BuildCatalog.cells_of(fp, _hover, _rotation)
	var rect_min: Vector2i = cells[0]
	var rect_max: Vector2i = cells[cells.size() - 1]
	var tiles: Array[Vector2i] = []
	var colors: Array[Color] = []
	for field: String in RADIUS_FIELDS:
		var r: int = int(effects.get(field, 0))
		if r <= 0:
			continue
		var col: Color = params.radius_preview_colors.get(field, params.ghost_valid_color)
		for t: Vector2i in _catalog.radius_cells(rect_min, rect_max, r):
			tiles.append(t)
			colors.append(col)
	var mm: MultiMesh = _radius.multimesh
	mm.instance_count = 0
	mm.instance_count = tiles.size()
	for i: int in tiles.size():
		var p: Vector3 = Vector3((float(tiles[i].x) + 0.5) * _tile_m, params.decal_y_offset_m, (float(tiles[i].y) + 0.5) * _tile_m)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))
		mm.set_instance_color(i, colors[i])
	_radius.visible = not tiles.is_empty()


func _build_visuals() -> void:
	if _box != null:
		return
	_box = MeshInstance3D.new()
	_box.name = BOX_NAME
	_box.mesh = BoxMesh.new()
	_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_box_mat = StandardMaterial3D.new()
	_box_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_box_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_box_mat.albedo_color = params.ghost_valid_color
	_box.material_override = _box_mat
	_box.visible = false
	add_child(_box)

	_label = Label3D.new()
	_label.name = LABEL_NAME
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.pixel_size = params.ghost_label_pixel_size
	_label.font_size = params.ghost_label_font_size
	var c: Color = params.ghost_invalid_color
	_label.modulate = Color(c.r, c.g, c.b, 1.0).lightened(0.5)
	_label.visible = false
	add_child(_label)

	_radius = MultiMeshInstance3D.new()
	_radius.name = RADIUS_NAME
	_radius.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_radius.multimesh = CoverageOverlay.make_tile_multimesh(_tile_m * params.decal_fill_ratio)
	_radius.material_override = CoverageOverlay.make_decal_material()
	_radius.visible = false
	add_child(_radius)
