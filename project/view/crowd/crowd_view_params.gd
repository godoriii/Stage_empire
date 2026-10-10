class_name CrowdViewParams
extends Resource
## SE-038 군중 표시 상수(프록시 치수, 색 폴백, 샌드박스 프리셋). 아트 디렉터가 crowd_view_params.tres 를 편집한다.
## 게임 수치가 아니다. 인스턴스 수·좌표 단위·유형 색·틱 길이는 audience.json·sim.json(CrowdData)에서 읽는다.

# --- 프록시 메시(CrowdProxyMesh.build 인자) --------------------------------
# 성능 스파이크(spike_configs.tres)와 같은 값이어야 측정이 실제 군중을 대표한다(test_crowd_view 가 대조).

@export var body_radius_m: float = 0.0
@export var body_height_m: float = 0.0
@export var body_radial_segments: int = 0
@export var body_rings: int = 0
@export var head_size_m: float = 0.0
@export var arm_size_m: Vector3 = Vector3.ZERO

# --- 색 ------------------------------------------------------------------

## audience.json 에 없는 유형 id 가 왔을 때의 인스턴스 색(알파는 1.0 으로 덮어쓴다).
@export var unknown_type_color: Color = Color.MAGENTA

# --- 샌드박스 프리셋(--se-crowd-preset=<n>) --------------------------------

## 프리셋 관객 유형 고르기 RNG 시드(표시 전용 RNG, sim 스트림 아님. 캡처 재현성).
@export var preset_seed: int = 0
## 프리셋 조명 가구를 무대 옆 몇 칸 밖에 놓을지(무대 정면 가장자리 끝 셀에서 가로로).
@export var preset_light_offset_cells: int = 0


## 프록시 메시(공유 빌더).
func build_proxy_mesh() -> ArrayMesh:
	return CrowdProxyMesh.build(body_radius_m, body_height_m, body_radial_segments, body_rings, head_size_m, arm_size_m)


## 캐릭터 키(발 → 머리 꼭대기, m).
func character_height_m() -> float:
	return body_height_m + head_size_m
