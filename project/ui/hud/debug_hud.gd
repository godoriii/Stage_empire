class_name DebugHud
extends CanvasLayer
## 샌드박스용 최소 디버그 HUD: 좌측 상단에 호버 타일 좌표, 카메라 요·줌 단계, 조작 안내.
## 뷰 상태(카메라·커서)만 표시한다. 게임 수치(sim 발행 값)는 아직 없다.
## 조작 안내의 키 이름은 InputMap 에서 읽는다(리맵하면 같이 바뀐다).

@export var label_path: NodePath = ^"Panel/Label"

var _label: Label
var _camera: IsoCamera
var _cursor: TileCursor
## SE-004 현재 셰이더 시안 id. 비어 있으면 줄을 표시하지 않는다(--material= 없이 실행하면 SE-002 와 같은 화면).
var _shader_variant: String = ""


func _ready() -> void:
	_label = get_node(label_path) as Label


func bind(camera: IsoCamera, cursor: TileCursor) -> void:
	_camera = camera
	_cursor = cursor
	_camera.view_changed.connect(_refresh)
	_cursor.hovered_tile_changed.connect(_on_hover_changed)
	_refresh()


func get_text() -> String:
	return _label.text


## SE-004: 현재 시안을 한 줄로 표시한다("시안: a"). 빈 문자열이면 줄을 숨긴다.
func set_shader_variant(id: String) -> void:
	_shader_variant = id
	_refresh()


func _on_hover_changed(_tile: Vector2i, _inside: bool) -> void:
	_refresh()


func _refresh() -> void:
	if _label == null or _camera == null or _cursor == null:
		return
	var tile_text: String = "-"
	if _cursor.is_hovering():
		var t: Vector2i = _cursor.get_hovered_tile()
		tile_text = "%d, %d" % [t.x, t.y]
	var lines: PackedStringArray = PackedStringArray()
	lines.append("타일 (x, z): %s" % tile_text)
	lines.append("요 %d°  피치 %d°  줌 %d/%d" % [
		roundi(_camera.get_yaw_deg()), roundi(_camera.get_pitch_deg()),
		_camera.get_zoom_index() + 1, _camera.get_zoom_level_count()])
	lines.append("회전 %s / %s   줌 %s / %s" % [
		_key_name(InputActions.CAMERA_ROTATE_CCW), _key_name(InputActions.CAMERA_ROTATE_CW),
		_key_name(InputActions.CAMERA_ZOOM_IN), _key_name(InputActions.CAMERA_ZOOM_OUT)])
	lines.append("팬 %s %s %s %s 또는 %s 드래그" % [
		_key_name(InputActions.CAMERA_PAN_UP), _key_name(InputActions.CAMERA_PAN_LEFT),
		_key_name(InputActions.CAMERA_PAN_DOWN), _key_name(InputActions.CAMERA_PAN_RIGHT),
		_key_name(InputActions.CAMERA_PAN_DRAG)])
	if not _shader_variant.is_empty():
		var keys: PackedStringArray = PackedStringArray()
		for action: StringName in InputActions.SHADER_VARIANT_ACTIONS:
			keys.append(_key_name(action))
		lines.append("시안: %s   전환 %s" % [_shader_variant, " / ".join(keys)])
	_label.text = "\n".join(lines)


## 액션의 첫 바인딩 이름. 키보드는 키 글자, 그 외는 엔진 표기.
static func _key_name(action: StringName) -> String:
	if not InputMap.has_action(action):
		return "?"
	var events: Array[InputEvent] = InputMap.action_get_events(action)
	if events.is_empty():
		return "?"
	var ev: InputEvent = events[0]
	if ev is InputEventKey:
		var k: InputEventKey = ev as InputEventKey
		# 물리 키 이름(US 배열 기준). DisplayServer 레이아웃 변환은 헤드리스에서 미지원이라 쓰지 않는다.
		return OS.get_keycode_string(k.physical_keycode if k.physical_keycode != 0 else k.keycode)
	return ev.as_text()
