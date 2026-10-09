extends GutTest
## SE-002 AC8: 런타임 InputMap 액션 등록. SE-004 AC10: shader_variant_1/2/3.

const EXPECTED: Array[StringName] = [
	&"camera_rotate_cw", &"camera_rotate_ccw",
	&"camera_zoom_in", &"camera_zoom_out",
	&"camera_pan_left", &"camera_pan_right", &"camera_pan_up", &"camera_pan_down",
	&"camera_pan_drag",
]


func _erase_all() -> void:
	for a: StringName in EXPECTED:
		if InputMap.has_action(a):
			InputMap.erase_action(a)


func after_all() -> void:
	# 다른 테스트에 기본 상태를 남긴다.
	_erase_all()
	InputActions.register()


func test_actions_registered() -> void:
	_erase_all()
	assert_eq(InputActions.register(), EXPECTED.size(), "새로 등록한 액션 수")
	for a: StringName in EXPECTED:
		assert_true(InputMap.has_action(a), "%s 등록됨" % a)
		assert_gt(InputMap.action_get_events(a).size(), 0, "%s 기본 바인딩 있음" % a)
	assert_eq(InputActions.ALL.size(), EXPECTED.size(), "InputActions.ALL 과 티켓 목록 일치")
	# 두 번 불러도 중복 등록하지 않는다.
	var counts: Array[int] = []
	for a: StringName in EXPECTED:
		counts.append(InputMap.action_get_events(a).size())
	assert_eq(InputActions.register(), 0, "재등록은 0")
	for i: int in EXPECTED.size():
		assert_eq(InputMap.action_get_events(EXPECTED[i]).size(), counts[i], "%s 이벤트 중복 없음" % EXPECTED[i])


func test_default_bindings_match_ticket() -> void:
	_erase_all()
	InputActions.register()
	assert_true(_has_key(&"camera_rotate_cw", KEY_E), "E = 시계 회전")
	assert_true(_has_key(&"camera_rotate_ccw", KEY_Q), "Q = 반시계 회전")
	assert_true(_has_mouse(&"camera_zoom_in", MOUSE_BUTTON_WHEEL_UP), "휠 위 = 줌 인")
	assert_true(_has_mouse(&"camera_zoom_out", MOUSE_BUTTON_WHEEL_DOWN), "휠 아래 = 줌 아웃")
	assert_true(_has_key(&"camera_pan_up", KEY_W))
	assert_true(_has_key(&"camera_pan_left", KEY_A))
	assert_true(_has_key(&"camera_pan_down", KEY_S))
	assert_true(_has_key(&"camera_pan_right", KEY_D))
	assert_true(_has_mouse(&"camera_pan_drag", MOUSE_BUTTON_MIDDLE), "휠 클릭 드래그 = 팬")


func test_existing_action_is_not_overwritten() -> void:
	_erase_all()
	InputMap.add_action(&"camera_rotate_cw")
	var custom: InputEventKey = InputEventKey.new()
	custom.physical_keycode = KEY_R
	InputMap.action_add_event(&"camera_rotate_cw", custom)
	InputActions.register()
	var events: Array[InputEvent] = InputMap.action_get_events(&"camera_rotate_cw")
	assert_eq(events.size(), 1, "사람이 정의/리맵한 액션은 유지")
	assert_true(_has_key(&"camera_rotate_cw", KEY_R))


func _has_key(action: StringName, key: Key) -> bool:
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventKey and ((ev as InputEventKey).physical_keycode == key or (ev as InputEventKey).keycode == key):
			return true
	return false


func _has_mouse(action: StringName, button: MouseButton) -> bool:
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == button:
			return true
	return false


const SHADER_VARIANT_EXPECTED: Array[StringName] = [&"shader_variant_1", &"shader_variant_2", &"shader_variant_3"]


func test_shader_variant_actions_registered() -> void:
	for a: StringName in SHADER_VARIANT_EXPECTED:
		if InputMap.has_action(a):
			InputMap.erase_action(a)
	assert_eq(InputActions.register_shader_variants(), SHADER_VARIANT_EXPECTED.size(), "새로 등록한 시안 액션 수")
	assert_eq(InputActions.SHADER_VARIANT_ACTIONS, SHADER_VARIANT_EXPECTED, "InputActions.SHADER_VARIANT_ACTIONS 와 티켓 목록 일치")
	for a: StringName in SHADER_VARIANT_EXPECTED:
		assert_true(InputMap.has_action(a), "%s 등록됨" % a)
		assert_false(InputActions.ALL.has(a), "%s 는 카메라 액션 목록(ALL)에 섞이지 않는다" % a)
	assert_true(_has_key(&"shader_variant_1", KEY_1), "1 = 시안 a")
	assert_true(_has_key(&"shader_variant_2", KEY_2), "2 = 시안 b")
	assert_true(_has_key(&"shader_variant_3", KEY_3), "3 = 시안 c")
	assert_eq(InputActions.register_shader_variants(), 0, "재등록은 0")
	for a: StringName in SHADER_VARIANT_EXPECTED:
		assert_eq(InputMap.action_get_events(a).size(), 1, "%s 이벤트 중복 없음" % a)
	assert_eq(ShaderVariants.SELECTABLE_IDS, PackedStringArray(["a", "b", "c"]), "액션 순서 = 시안 a/b/c")


# --- SE-037 -----------------------------------------------------------------

const BUILD_EXPECTED: Array[StringName] = [&"build_confirm", &"build_rotate", &"build_cancel", &"build_demolish", &"overlay_cycle"]


func test_build_actions_registered() -> void:
	_erase_all()   # 앞 테스트가 camera_rotate_cw 를 R 로 리맵해 두었을 수 있다 → 기본 바인딩으로.
	InputActions.register()
	for a: StringName in BUILD_EXPECTED:
		if InputMap.has_action(a):
			InputMap.erase_action(a)
	assert_eq(InputActions.register_build(), BUILD_EXPECTED.size(), "새로 등록한 배치 액션 수")
	assert_eq(InputActions.BUILD_ACTIONS, BUILD_EXPECTED, "InputActions.BUILD_ACTIONS 와 티켓 목록 일치")
	for a: StringName in BUILD_EXPECTED:
		assert_true(InputMap.has_action(a), "%s 등록됨" % a)
		assert_false(InputActions.ALL.has(a), "%s 는 카메라 액션 목록(ALL)에 섞이지 않는다" % a)
	assert_true(_has_key(&"build_rotate", KEY_R), "R = 회전")
	assert_true(_has_key(&"build_cancel", KEY_ESCAPE), "Esc = 취소")
	assert_true(_has_key(&"overlay_cycle", KEY_O), "O = 오버레이 순환")
	assert_true(_has_key(&"build_demolish", KEY_X), "X = 철거 모드")
	assert_true(_has_mouse(&"build_confirm", MOUSE_BUTTON_LEFT), "왼쪽 클릭 = 배치/철거 실행")
	assert_eq(InputActions.register_build(), 0, "재등록은 0")
	# 기존 키와 겹치지 않는다(카메라·시안 액션의 키보드 바인딩).
	var others: Array[StringName] = []
	others.append_array(InputActions.ALL)
	others.append_array(InputActions.SHADER_VARIANT_ACTIONS)
	for a: StringName in BUILD_EXPECTED:
		for ev: InputEvent in InputMap.action_get_events(a):
			if not (ev is InputEventKey):
				continue
			for o: StringName in others:
				assert_false(_has_key(o, (ev as InputEventKey).physical_keycode), "%s 키가 %s 와 겹치지 않는다" % [a, o])
