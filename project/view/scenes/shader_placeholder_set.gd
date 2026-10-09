class_name ShaderPlaceholderSet
extends Resource
## SE-004 셰이더 시안 비교용 플레이스홀더 세트의 치수·색·라이트. 값은 shader_placeholders.tres 에 있다.
## 게임 밸런스가 아니라 렌더 확인용 설정이므로 data/ 가 아닌 view 리소스에 둔다(spike_configs.tres 와 같은 자리).
## 위치(offset)는 전부 그리드 중심(ShaderPlaceholders 노드 위치) 기준 m. 메시 피벗은 바닥 중심(style-guide).
## 크기 표기는 style-guide 의 w×d(x, z), 높이 m.

## 바 카운터: 크기(x = w, y = 높이, z = d), 바닥 중심 위치(x, z), 정점색. accent_top 이면 윗면이 accent 슬롯.
@export var bar_size_m: Vector3 = Vector3.ZERO
@export var bar_offset_m: Vector2 = Vector2.ZERO
@export var bar_color: Color = Color.WHITE
@export var bar_accent_top: bool = false

## 무대.
@export var stage_size_m: Vector3 = Vector3.ZERO
@export var stage_offset_m: Vector2 = Vector2.ZERO
@export var stage_color: Color = Color.WHITE
@export var stage_accent_top: bool = false

## 벽 세그먼트.
@export var wall_size_m: Vector3 = Vector3.ZERO
@export var wall_offset_m: Vector2 = Vector2.ZERO
@export var wall_color: Color = Color.WHITE

## 캐릭터 캡슐(반지름, 전체 높이). 위치 하나당 캡슐 하나, 색은 같은 인덱스(모자라면 순환).
@export var character_radius_m: float = 0.0
@export var character_height_m: float = 0.0
@export var character_offsets_m: PackedVector2Array = PackedVector2Array()
@export var character_colors: PackedColorArray = PackedColorArray()

## accent 슬롯 영역의 정점색. 툰 셰이더에서는 여기에 accent_color(시안 .tres)가 곱해진다.
@export var accent_color: Color = Color.WHITE

## 스테이지 조명 흉내 컬러 스포트(림라이트 확인용). 위치·조준점은 (x, 높이, z) 오프셋. 세 배열 길이가 같아야 한다.
@export var spot_offsets_m: PackedVector3Array = PackedVector3Array()
@export var spot_targets_m: PackedVector3Array = PackedVector3Array()
@export var spot_colors: PackedColorArray = PackedColorArray()
@export var spot_energy: float = 0.0
@export var spot_range_m: float = 0.0
@export var spot_angle_deg: float = 0.0


## 박스 플레이스홀더(바·무대·벽) 수 + 캐릭터 수 = 생성되는 MeshInstance3D 수.
func get_mesh_count() -> int:
	return ShaderPlaceholders.BOX_NAMES.size() + character_offsets_m.size()


## 값이 스스로 모순되지 않는지. 문제 목록(빈 배열 = 유효).
func get_errors() -> PackedStringArray:
	var errs: PackedStringArray = PackedStringArray()
	for pair: Array in [["bar_size_m", bar_size_m], ["stage_size_m", stage_size_m], ["wall_size_m", wall_size_m]]:
		var v: Vector3 = pair[1]
		if v.x <= 0.0 or v.y <= 0.0 or v.z <= 0.0:
			errs.append("%s 의 모든 성분 > 0 이어야 한다 (%s)" % [pair[0], v])
	if character_radius_m <= 0.0 or character_height_m <= 0.0:
		errs.append("캐릭터 캡슐: 반지름·높이 > 0 (%.2f, %.2f)" % [character_radius_m, character_height_m])
	if character_offsets_m.is_empty():
		errs.append("character_offsets_m 가 비어 있다")
	if character_colors.is_empty():
		errs.append("character_colors 가 비어 있다")
	if spot_offsets_m.size() != spot_targets_m.size() or spot_offsets_m.size() != spot_colors.size():
		errs.append("spot_offsets_m / spot_targets_m / spot_colors 길이 불일치 (%d / %d / %d)" % [
			spot_offsets_m.size(), spot_targets_m.size(), spot_colors.size()])
	return errs
