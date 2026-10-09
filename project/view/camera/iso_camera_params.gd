class_name IsoCameraParams
extends Resource
## IsoCamera 의 뷰 상수. 게임 밸런스가 아니라 화면 설정이므로 data/ 가 아닌 이 리소스(.tres)에 둔다.
## 아트 디렉터가 iso_camera_params.tres 를 편집해 바꾼다. 코드에는 숫자를 두지 않는다.

## PRD 고정: 줌 단계 수. 바꾸려면 PRD/ADR 변경이 필요하다.
const REQUIRED_ZOOM_LEVELS: int = 4

## 피치(도). 음수 = 내려다봄. PRD: 약 30°.
@export var pitch_deg: float = 0.0
## 초기 요(도). PRD: 45°. 회전은 여기서 90° 단위로만 움직인다.
@export var base_yaw_deg: float = 0.0
## 줌 단계별 Camera3D.size(직교 투영의 세로 가시 범위, m). 엄격히 증가, 정확히 4개.
## 인덱스 0 = 가장 가까움.
@export var zoom_sizes: PackedFloat32Array = PackedFloat32Array()
## 시작 줌 인덱스(0부터).
@export var default_zoom_index: int = 0
## 피벗이 그리드 밖으로 나갈 수 있는 여유(m).
@export var pan_margin_m: float = 0.0
## 피벗에서 카메라까지 거리(m). 직교라 화면 크기에는 영향 없고 near/far 클리핑에만 쓴다.
@export var camera_distance_m: float = 0.0
@export var near_m: float = 0.0
@export var far_m: float = 0.0
## 키보드/스틱 팬 속도: 초당 "현재 화면 세로 가시 범위(size)"의 몇 배를 움직이는지.
@export var pan_speed_screens_per_sec: float = 0.0


## 값이 PRD 제약을 지키는지 검사한다. 위반 시 push_error 후 false.
func validate() -> bool:
	var ok: bool = true
	if zoom_sizes.size() != REQUIRED_ZOOM_LEVELS:
		push_error("IsoCameraParams: zoom_sizes 는 정확히 %d 단계여야 한다 (현재 %d)" % [REQUIRED_ZOOM_LEVELS, zoom_sizes.size()])
		ok = false
	for i: int in range(1, zoom_sizes.size()):
		if zoom_sizes[i] <= zoom_sizes[i - 1]:
			push_error("IsoCameraParams: zoom_sizes 는 엄격히 증가해야 한다 (인덱스 %d)" % i)
			ok = false
	if zoom_sizes.size() > 0 and (default_zoom_index < 0 or default_zoom_index >= zoom_sizes.size()):
		push_error("IsoCameraParams: default_zoom_index 범위 밖 (%d)" % default_zoom_index)
		ok = false
	return ok
