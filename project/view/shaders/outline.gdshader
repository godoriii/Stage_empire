// SE-004 외곽선 패스: 역면 헐(inverted hull). 툰 머티리얼의 next_pass 로 붙여 MultiMesh 군중에도
// 노드 추가 없이 적용된다(스크린스페이스 외곽선은 후속 포스트프로세스 티켓).
// 상수는 params/outline_{a,b,c}.tres 에서 정한다.
//
// 두께는 화면 픽셀(outline_px) 기준이라 직교 카메라 줌(size)과 무관하게 일정하다.
//   직교 투영: PROJECTION_MATRIX[1][1] = 2 / size(세로 가시 범위 m), 화면 세로 = VIEWPORT_SIZE.y px
//   → 1 px = size / VIEWPORT_SIZE.y m = 2 / (|PROJECTION_MATRIX[1][1]| · VIEWPORT_SIZE.y) m.
//   원근 투영(참고, 이 게임은 쓰지 않음)이면 같은 식에 뷰 공간 깊이(−z)를 곱한다.
// 뷰 공간 정점을 뷰 공간 법선 방향으로 outline_px × (m/px) 밀어낸 뒤 앞면을 컬링하고 뒷면만 단색으로 그린다.
// 실루엣에서 법선은 시선과 수직이라 화면상 두께 ≈ outline_px. 각진 박스는 법선이 면마다 나뉘어 모서리에 1~2px 틈이 생길 수 있다.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, skip_vertex_transform, shadows_disabled, fog_disabled;

uniform float outline_px : hint_range(0.0, 8.0) = 1.0;
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

void vertex() {
	vec3 view_pos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 view_n = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	// abs: Compatibility(OpenGL) 렌더러는 렌더 타깃 Y 뒤집기 때문에 [1][1] 이 음수일 수 있다(그대로 쓰면 헐이 안쪽으로 들어가 사라진다).
	float m_per_px = 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
	if (PROJECTION_MATRIX[3][3] < 0.5) {
		m_per_px *= -view_pos.z;
	}
	VERTEX = view_pos + view_n * outline_px * m_per_px;
	NORMAL = view_n;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
