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
## SE-004 셰이더 시안 전환(샌드박스 --material= 실행 중에만 동작). 인덱스 = ShaderVariants.SELECTABLE_IDS.
const SHADER_VARIANT_1: StringName = &"shader_variant_1"
const SHADER_VARIANT_2: StringName = &"shader_variant_2"
const SHADER_VARIANT_3: StringName = &"shader_variant_3"
## SE-037 배치 UI. 클릭(build_confirm) = 배치/철거 실행, R = 회전, Esc = 취소, X = 철거 모드, O = 오버레이 순환.
const BUILD_CONFIRM: StringName = &"build_confirm"
const BUILD_ROTATE: StringName = &"build_rotate"
const BUILD_CANCEL: StringName = &"build_cancel"
const BUILD_DEMOLISH: StringName = &"build_demolish"
const OVERLAY_CYCLE: StringName = &"overlay_cycle"

const ALL: Array[StringName] = [
	CAMERA_ROTATE_CW, CAMERA_ROTATE_CCW,
	CAMERA_ZOOM_IN, CAMERA_ZOOM_OUT,
	CAMERA_PAN_LEFT, CAMERA_PAN_RIGHT, CAMERA_PAN_UP, CAMERA_PAN_DOWN,
	CAMERA_PAN_DRAG,
]

## SE-004 시안 전환 액션. 카메라 액션(ALL)과 따로 둔다: SE-002 의 ALL·register() 의 의미(카메라 9개)를 바꾸지 않는다.
const SHADER_VARIANT_ACTIONS: Array[StringName] = [SHADER_VARIANT_1, SHADER_VARIANT_2, SHADER_VARIANT_3]

## SE-037 배치 UI 액션. ALL(카메라 9개)과 따로 둔다. 샌드박스는 --se-build-preset= 일 때만 등록한다.
const BUILD_ACTIONS: Array[StringName] = [BUILD_CONFIRM, BUILD_ROTATE, BUILD_CANCEL, BUILD_DEMOLISH, OVERLAY_CYCLE]


## 모든 액션을 등록한다. 여러 번 불러도 안전하다. 새로 등록한 액션 수를 돌려준다.
static func register() -> int:
	return _register_list(ALL)


## SE-004 시안 전환 액션(shader_variant_1/2/3)을 등록한다. 규칙은 register() 와 같다. 새로 등록한 수.
static func register_shader_variants() -> int:
	return _register_list(SHADER_VARIANT_ACTIONS)


## SE-037 배치 UI 액션(BUILD_ACTIONS)을 등록한다. 규칙은 register() 와 같다. 새로 등록한 수.
static func register_build() -> int:
	return _register_list(BUILD_ACTIONS)


static func _register_list(actions: Array[StringName]) -> int:
	var added: int = 0
	for action: StringName in actions:
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
		SHADER_VARIANT_1:
			out.append(_key(KEY_1))
		SHADER_VARIANT_2:
			out.append(_key(KEY_2))
		SHADER_VARIANT_3:
			out.append(_key(KEY_3))
		BUILD_CONFIRM:
			out.append(_mouse_button(MOUSE_BUTTON_LEFT))
			out.append(_joy_button(JOY_BUTTON_A))
		BUILD_ROTATE:
			out.append(_key(KEY_R))
			out.append(_joy_button(JOY_BUTTON_Y))
		BUILD_CANCEL:
			out.append(_key(KEY_ESCAPE))
			out.append(_joy_button(JOY_BUTTON_B))
		BUILD_DEMOLISH:
			out.append(_key(KEY_X))
			out.append(_joy_button(JOY_BUTTON_X))
		OVERLAY_CYCLE:
			out.append(_key(KEY_O))
			out.append(_joy_button(JOY_BUTTON_BACK))
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
