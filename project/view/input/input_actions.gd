class_name InputActions
extends RefCounted
## 뷰 입력 액션 이름과 기본 바인딩. 키·버튼 상수(KEY_*, MOUSE_BUTTON_*, JOY_*)는 이 파일에만 둔다.
## 다른 코드는 액션 이름(StringName)으로만 입력을 확인한다(키 리맵 가능, PRD 조작 요구).
##
## project.godot 의 [input] 은 render-engineer 쓰기 범위 밖이라 런타임에 InputMap 에 등록한다.
## 이미 같은 이름의 액션이 있으면(사람이 project.godot 에 정의했거나 리맵한 경우) 건드리지 않는다.

const CAMERA_ROTATE_CW: StringName = &"camera_rotate_cw"
const CAMERA_ROTATE_CCW: StringName = &"camera_rotate_ccw"
const CAMERA_ZOOM_IN: StringName = &"camera_zoom_in"
const CAMERA_ZOOM_OUT: StringName = &"camera_zoom_out"
const CAMERA_PAN_LEFT: StringName = &"camera_pan_left"
const CAMERA_PAN_RIGHT: StringName = &"camera_pan_right"
const CAMERA_PAN_UP: StringName = &"camera_pan_up"
const CAMERA_PAN_DOWN: StringName = &"camera_pan_down"
const CAMERA_PAN_DRAG: StringName = &"camera_pan_drag"

const ALL: Array[StringName] = [
	CAMERA_ROTATE_CW, CAMERA_ROTATE_CCW,
	CAMERA_ZOOM_IN, CAMERA_ZOOM_OUT,
	CAMERA_PAN_LEFT, CAMERA_PAN_RIGHT, CAMERA_PAN_UP, CAMERA_PAN_DOWN,
	CAMERA_PAN_DRAG,
]


## 모든 액션을 등록한다. 여러 번 불러도 안전하다. 새로 등록한 액션 수를 돌려준다.
static func register() -> int:
	var added: int = 0
	for action: StringName in ALL:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for ev: InputEvent in default_events(action):
			InputMap.action_add_event(action, ev)
		added += 1
	return added


## 액션의 기본 바인딩. 마우스+키보드 1순위, 게임패드는 숄더/D패드/왼쪽 스틱.
static func default_events(action: StringName) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	match action:
		CAMERA_ROTATE_CW:
			out.append(_key(KEY_E))
			out.append(_joy_button(JOY_BUTTON_RIGHT_SHOULDER))
		CAMERA_ROTATE_CCW:
			out.append(_key(KEY_Q))
			out.append(_joy_button(JOY_BUTTON_LEFT_SHOULDER))
		CAMERA_ZOOM_IN:
			out.append(_mouse_button(MOUSE_BUTTON_WHEEL_UP))
			out.append(_key(KEY_EQUAL))
			out.append(_key(KEY_KP_ADD))
			out.append(_joy_button(JOY_BUTTON_DPAD_UP))
		CAMERA_ZOOM_OUT:
			out.append(_mouse_button(MOUSE_BUTTON_WHEEL_DOWN))
			out.append(_key(KEY_MINUS))
			out.append(_key(KEY_KP_SUBTRACT))
			out.append(_joy_button(JOY_BUTTON_DPAD_DOWN))
		CAMERA_PAN_LEFT:
			out.append(_key(KEY_A))
			out.append(_key(KEY_LEFT))
			out.append(_joy_axis(JOY_AXIS_LEFT_X, -1.0))
		CAMERA_PAN_RIGHT:
			out.append(_key(KEY_D))
			out.append(_key(KEY_RIGHT))
			out.append(_joy_axis(JOY_AXIS_LEFT_X, 1.0))
		CAMERA_PAN_UP:
			out.append(_key(KEY_W))
			out.append(_key(KEY_UP))
			out.append(_joy_axis(JOY_AXIS_LEFT_Y, -1.0))
		CAMERA_PAN_DOWN:
			out.append(_key(KEY_S))
			out.append(_key(KEY_DOWN))
			out.append(_joy_axis(JOY_AXIS_LEFT_Y, 1.0))
		CAMERA_PAN_DRAG:
			out.append(_mouse_button(MOUSE_BUTTON_MIDDLE))
	return out


static func _key(physical: Key) -> InputEventKey:
	var ev: InputEventKey = InputEventKey.new()
	ev.physical_keycode = physical
	return ev


static func _mouse_button(button: MouseButton) -> InputEventMouseButton:
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = button
	return ev


static func _joy_button(button: JoyButton) -> InputEventJoypadButton:
	var ev: InputEventJoypadButton = InputEventJoypadButton.new()
	ev.button_index = button
	return ev


static func _joy_axis(axis: JoyAxis, direction: float) -> InputEventJoypadMotion:
	var ev: InputEventJoypadMotion = InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = direction
	return ev
