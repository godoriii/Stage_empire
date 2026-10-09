// SE-004 툰 셰이더(셀 셰이딩 + 선택적 림라이트). 시안 A/B/C 공통 셰이더.
// 상수는 전부 params/toon_{a,b,c}.tres 의 shader_parameter 로 정한다(아트 디렉터 조정용). 아래 기본값은 쓰지 않는다.
// 외곽선은 이 머티리얼의 next_pass(outline.gdshader)로 그린다.
//
// 머티리얼 슬롯(style-guide: base/accent/emissive. glass 는 후속 티켓):
//   albedo = 정점색(COLOR) × base_color, 정점 알파가 0 인 곳(accent 영역)은 추가로 × accent_color.
//   스파이크 군중은 MultiMesh 인스턴스 색이 COLOR 로 들어오므로 시안을 씌워도 색 분포가 default 와 같다.
//   emission = emissive_color.rgb × emissive_energy.
// 셀 단계: 라이트마다 N·L × 감쇠(그림자 포함)를 cell_steps 단계로 양자화한다.
//   어두운 단계는 검정 대신 shadow_tint(알파 = 세기)만큼 그 라이트 색을 받는다(감쇠 비례).
// 림: rim_enabled 면 실루엣(1 − N·V ≥ 1 − rim_width) 중 라이트를 향한 쪽에 라이트 색 × rim_color × rim_strength
//   × 역광 가중 (1 − L·V) / 2.
//   SPECULAR_LIGHT 로 더해 albedo 와 무관하게 무대 조명 색이 실루엣에 묻어난다.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

group_uniforms cell;
uniform int cell_steps : hint_range(2, 8) = 2;
uniform vec4 shadow_tint : source_color = vec4(0.3, 0.3, 0.4, 1.0);

group_uniforms rim;
uniform bool rim_enabled = false;
uniform float rim_strength : hint_range(0.0, 4.0) = 1.0;
uniform float rim_width : hint_range(0.0, 1.0) = 0.3;
uniform vec4 rim_color : source_color = vec4(1.0);

group_uniforms slots;
uniform vec4 base_color : source_color = vec4(1.0);
uniform vec4 accent_color : source_color = vec4(1.0);
uniform vec4 emissive_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emissive_energy : hint_range(0.0, 16.0) = 0.0;
group_uniforms;

float toon_band(float x) {
	float n = float(max(cell_steps, 2));
	return clamp(floor(x * n) / (n - 1.0), 0.0, 1.0);
}

void fragment() {
	float accent_w = 1.0 - COLOR.a;
	vec3 slot = mix(vec3(1.0), accent_color.rgb, accent_w);
	ALBEDO = base_color.rgb * COLOR.rgb * slot;
	EMISSION = emissive_color.rgb * emissive_energy;
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float reach = clamp(ATTENUATION, 0.0, 1.0);
	float lit = toon_band(ndl * reach);
	vec3 dark = shadow_tint.rgb * shadow_tint.a * reach;
	DIFFUSE_LIGHT += LIGHT_COLOR / PI * mix(dark, vec3(1.0), lit);
	if (rim_enabled) {
		float fres = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
		// 역광 가중: 라이트가 물체 뒤(카메라 반대편)에 있을수록 1, 정면이면 0 → 무대 조명 색이 실루엣에 묻는다.
		float back = (1.0 - dot(LIGHT, VIEW)) * 0.5;
		float rim = step(1.0 - rim_width, fres) * step(0.0001, ndl) * reach * back;
		SPECULAR_LIGHT += LIGHT_COLOR / PI * rim_color.rgb * rim_strength * rim;
	}
}
