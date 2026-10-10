class_name StageLightParams
extends Resource
## SE-038 무대 스포트 룩 상수(아트 디렉션 대상). 아트 디렉터가 stage_light_params.tres 를 편집한다.
## 게임 수치가 아니다. 켜질 스포트 수는 가구 effects.light_grade 합(furniture.json, build.md C6)으로 정하고
## 여기 max_spots 가 상한이다(SE-038 범위 "SpotLight3D ≤ 4").

## 스포트 노드 수 = 켤 수 있는 최대 수.
@export var max_spots: int = 0
## 스포트 높이(m, 바닥 기준)와 무대 정면 가장자리에서 관객 쪽으로 떨어진 거리(m).
@export var spot_height_m: float = 0.0
@export var spot_forward_m: float = 0.0
## 스포트 가로 간격 = 무대 정면 폭 × 이 비율을 켜진 수로 나눈 칸 중심.
@export var spot_spread_ratio: float = 1.0
## 겨누는 점: 무대 점유 영역 중심 위 이 높이(m, 공연자 가슴 높이).
@export var aim_height_m: float = 0.0
@export var spot_range_m: float = 0.0
@export var spot_angle_deg: float = 0.0
@export var spot_energy: float = 0.0
## SpotLight3D.spot_attenuation(거리 감쇠 지수). 툰 셰이더는 감쇠(ATTENUATION)를 셀 단계로 접으므로 1 이면
## 몇 m 만 떨어져도 어두운 단계로 떨어진다 — 무대 스포트는 0 근처로 둬서 콘 안이 밝은 단계에 들게 한다.
@export var spot_attenuation: float = 1.0
## 스포트 그림자(셰도우 패스 비용, 성능 관문 대상). 기본 off.
@export var spot_shadows: bool = false
## 공연 중 색(스포트 i 는 show_colors[i % 크기]).
@export var show_colors: PackedColorArray = PackedColorArray()
## show.ended 끝 연출: grade id(artist.json show_grades) → 색. 없는 id 는 grade_fallback_color.
@export var grade_colors: Dictionary = {}
@export var grade_fallback_color: Color = Color.WHITE
## 끝 연출 길이(초). 0 이면 show.ended 즉시 끈다.
@export var finale_sec: float = 0.0


## 문제 목록(빈 배열 = 유효).
func get_errors() -> PackedStringArray:
	var errs: PackedStringArray = PackedStringArray()
	if max_spots <= 0:
		errs.append("max_spots > 0")
	if spot_height_m <= aim_height_m:
		errs.append("spot_height_m 는 aim_height_m 보다 높아야 한다")
	if spot_range_m <= 0.0 or spot_angle_deg <= 0.0 or spot_angle_deg >= 90.0 or spot_energy <= 0.0:
		errs.append("스포트 범위·각도·세기")
	if spot_spread_ratio <= 0.0 or spot_spread_ratio > 1.0:
		errs.append("0 < spot_spread_ratio ≤ 1")
	if show_colors.is_empty():
		errs.append("show_colors 비어 있음")
	if finale_sec < 0.0:
		errs.append("finale_sec ≥ 0")
	return errs
