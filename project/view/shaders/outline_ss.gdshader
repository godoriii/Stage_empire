// SE-021 스크린스페이스 외곽선(시안 ss). 역면 헐(outline.gdshader)의 비교 시안이다. 기본값(B)은 바꾸지 않는다.
// 씬에 1개 붙는 전체 화면 쿼드(outline_ss_pass.tscn)가 불투명 패스 뒤의 깊이 텍스처만 읽어 외곽선 픽셀을 덮어 그린다.
// 상수는 전부 params/outline_ss.tres 에서 정한다(아래 uniform 기본값은 쓰지 않는다).
//
// gl_compatibility(Xvfb·CI)와 forward_plus 둘 다에서 돈다:
//   - 법선 버퍼(normal_roughness 힌트 텍스처)는 forward_plus 전용이라 쓰지 않는다. 법선은 깊이에서 재구성한다.
//   - 깊이 텍스처(depth 힌트 샘플러)는 투명 패스에서 읽는다(ALPHA 를 쓰므로 이 머티리얼은 투명 패스, render_priority 최대).
//   - NDC 변환만 렌더러별로 다르다(CURRENT_RENDERER 분기: OpenGL 은 깊이 [-1, 1], RD 는 [0, 1]).
//
// 단위: 화면 px. 직교 카메라라 화면 1 px = size / VIEWPORT_SIZE.y m(outline.gdshader 와 같은 환산).
//   깊이도 같은 단위(px)로 바꿔서 임계값이 줌과 무관하게 같다. 원근 카메라는 가정하지 않는다(이 게임은 직교만).
//
// 판정: 픽셀 p 가 반지름 outline_px(원판) 안의 이웃 q 중 하나에 대해
//   (1) 깊이 불연속(실루엣): q 가 p 보다 depth_threshold_px 넘게 앞 → p 는 실루엣 바깥(먼 쪽) → 외곽선.
//       역면 헐(B)처럼 선이 물체 바깥에 붙어 캡슐 폭이 B 와 같다(outline_px).
//   (2) 법선 불연속(주름): |깊이 차| ≤ depth_threshold_px 이고, q 가 p 의 접평면에서 plane_epsilon_px 넘게 벗어나며,
//       두 법선의 내적 < normal_threshold. 그중 카메라를 덜 향한 쪽(facing 작은 쪽)만 칠한다.
//       facing 차가 facing_bias 이하(대칭 주름)면 q 가 오른쪽(같은 열이면 +y)인 p 를 칠한다(한쪽만 → 폭 outline_px).
//       바닥 접점(깊이 연속, 바닥 facing 0.5 < 옆면 facing 약 0.61)은 바닥 쪽에 선이 생긴다. 박스 아래쪽 실루엣처럼
//       깊이 차가 임계 밑으로 줄어드는 곳도 (2)가 이어받는다.
//       p·q 둘 다 법선이 "믿을 만할" 때만 본다(아래). 바닥 격자선(0.005 m 위 1 px 선, 줌 0 에서 깊이 1.5~3.4 px 단차)
//       같은 얇은 단차는 법선을 흔들어 점 잡음을 만들기 때문이다.
// 법선 재구성: 축마다 양쪽 3 px 를 읽고 중심 외삽 오차가 가장 작은 한쪽 직선의 기울기를 쓴다(axis_slope, 주름 건너편과
//   1 px 단차를 피함). 두 축 모두 그 오차가 normal_fit_px 이하일 때만 법선을 믿는다(얇은 단차 위 픽셀·곡면 실루엣
//   가장자리는 제외).
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform float outline_px : hint_range(0.0, 8.0) = 1.0;
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float depth_threshold_px : hint_range(0.0, 512.0) = 1.0;
uniform float normal_threshold : hint_range(-1.0, 1.0) = 1.0;
uniform float facing_bias : hint_range(0.0, 1.0) = 0.0;
uniform float plane_epsilon_px : hint_range(0.0, 8.0) = 0.0;
uniform float normal_fit_px : hint_range(0.0, 8.0) = 0.0;

void vertex() {
	// 전체 화면 쿼드(QuadMesh 2×2 → 클립 공간 [-1, 1]). 깊이 테스트를 하지 않으므로 z 는 클립 범위 안이면 된다.
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
}

// uv 의 뷰 공간 깊이(카메라에서 멀수록 큼), 화면 px 단위.
float depth_px(vec2 uv, mat4 inv_proj, float px_per_m) {
	float d = texture(depth_tex, uv).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec4 ndc = vec4(vec3(uv, d) * 2.0 - 1.0, 1.0);
#else
	vec4 ndc = vec4(uv * 2.0 - 1.0, d, 1.0);
#endif
	vec4 v = inv_proj * ndc;
	return -(v.z / v.w) * px_per_m;
}

// 한 축의 기울기(px 당 깊이 px). step = 그 축의 1 px uv. 양쪽 3 px 씩 읽고, 한쪽 안의 쌍 (1,2)·(1,3)·(2,3) 6개 후보 중
// 중심으로의 외삽 오차가 가장 작은 직선의 기울기를 쓴다. 주름 건너편 면은 오차가 커서 빠지고,
// 한쪽 3 px 안의 1 px 단차(격자선)는 그 픽셀을 건너뛴 쌍이 골라진다. fit_err = 고른 후보의 오차.
float axis_slope(vec2 uv, vec2 step, float z0, mat4 inv_proj, float px_per_m, out float fit_err) {
	float best_slope = 0.0;
	fit_err = -1.0;
	for (int side = -1; side <= 1; side += 2) {
		float s1 = depth_px(uv + float(side) * step, inv_proj, px_per_m);
		float s2 = depth_px(uv + float(2 * side) * step, inv_proj, px_per_m);
		float s3 = depth_px(uv + float(3 * side) * step, inv_proj, px_per_m);
		// (i, j): 바깥쪽 기울기 (s_j − s_i) / (j − i), 중심 외삽 = s_i − i · 기울기.
		vec3 outward = vec3(s2 - s1, (s3 - s1) * 0.5, s3 - s2);
		vec3 pred = vec3(s1, s1, s2) - vec3(1.0, 1.0, 2.0) * outward;
		vec3 err = abs(pred - vec3(z0));
		for (int c = 0; c < 3; c++) {
			if (fit_err < 0.0 || err[c] < fit_err) {
				fit_err = err[c];
				best_slope = outward[c] * float(side);
			}
		}
	}
	return best_slope;
}

// 깊이 기울기 g = (∂z/∂x, ∂z/∂y). 법선 = normalize(vec3(g, -1)), facing(카메라를 향한 정도) = 1 / |vec3(g, 1)|.
// reliable = 두 축 모두 외삽 오차 ≤ normal_fit_px.
vec2 depth_gradient(vec2 uv, vec2 texel, float z0, mat4 inv_proj, float px_per_m, out bool reliable) {
	float ex;
	float ey;
	vec2 g = vec2(
		axis_slope(uv, vec2(texel.x, 0.0), z0, inv_proj, px_per_m, ex),
		axis_slope(uv, vec2(0.0, texel.y), z0, inv_proj, px_per_m, ey));
	reliable = max(ex, ey) <= normal_fit_px;
	return g;
}

void fragment() {
	vec2 texel = 1.0 / VIEWPORT_SIZE;
	// 직교: PROJECTION_MATRIX[1][1] = 2 / size → px/m = [1][1] · VIEWPORT_SIZE.y / 2 (OpenGL 은 부호가 뒤집힐 수 있어 abs).
	float px_per_m = abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y * 0.5;
	float z0 = depth_px(SCREEN_UV, INV_PROJECTION_MATRIX, px_per_m);
	bool rel0;
	vec2 g0 = depth_gradient(SCREEN_UV, texel, z0, INV_PROJECTION_MATRIX, px_per_m, rel0);
	vec3 n0 = normalize(vec3(g0, -1.0));
	int r = int(ceil(outline_px));
	float r2 = outline_px * outline_px;
	bool edge = false;
	for (int dy = -r; dy <= r; dy++) {
		for (int dx = -r; dx <= r; dx++) {
			vec2 o = vec2(float(dx), float(dy));
			float o2 = dot(o, o);
			if (edge || o2 == 0.0 || o2 > r2) {
				continue;
			}
			vec2 uv = SCREEN_UV + o * texel;
			float zq = depth_px(uv, INV_PROJECTION_MATRIX, px_per_m);
			float dz = z0 - zq;
			if (dz > depth_threshold_px) {
				edge = true;
				continue;
			}
			if (!rel0 || dz < -depth_threshold_px || abs(zq - (z0 + dot(g0, o))) <= plane_epsilon_px) {
				continue;
			}
			bool relq;
			vec3 nq = normalize(vec3(depth_gradient(uv, texel, zq, INV_PROJECTION_MATRIX, px_per_m, relq), -1.0));
			if (!relq || dot(n0, nq) >= normal_threshold) {
				continue;
			}
			float f0 = -n0.z;
			float fq = -nq.z;
			bool tie = abs(f0 - fq) <= facing_bias;
			if ((!tie && f0 < fq) || (tie && (dx > 0 || (dx == 0 && dy > 0)))) {
				edge = true;
			}
		}
	}
	ALBEDO = outline_color.rgb;
	ALPHA = edge ? outline_color.a : 0.0;
}
