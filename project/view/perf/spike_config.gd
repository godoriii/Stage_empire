class_name SpikeConfig
extends Resource
## 성능 스파이크 구성 한 행(SE-003 표 A~D + SE-013 구성 E + SE-038 구성 F). 값은 spike_configs.tres 에 있다.
## 게임 밸런스가 아니라 렌더 측정 설정이므로 data/ 가 아닌 view 리소스에 둔다.

## 구성 이름. 명령줄 --config=<id> 로 고른다.
@export var id: String = ""
## MultiMesh 인스턴스(캐릭터 프록시) 수.
@export var instances: int = 0
## 동적 라이트(Omni/Spot 혼합) 총 수.
@export var lights: int = 0
## 그중 shadow_enabled 인 라이트 수. lights 이하.
@export var shadow_lights: int = 0
## 뷰포트 positional_shadow_atlas_size(px). 2의 거듭제곱.
@export var shadow_atlas_size: int = 0
## 군중(MultiMesh)이 그림자를 드리우는지. false 면 cast_shadow = OFF(style-guide 2026-10-09 결정, SE-013 구성 E).
## 셰도우 라이트·아틀라스는 그대로라 무대 프록시 등 다른 캐스터의 셰도우 패스는 계속 돈다.
@export var crowd_shadows: bool = true
## SE-038: 셰도우 캐스터 박스(가구 프록시) 수. 0 이면 SpikeConfigSet.stage_prop_count(A~E 와 같은 값).
## 구성 F(대표 장면)는 가구 20 을 흉내 내려고 20 을 쓴다.
@export var prop_count: int = 0
## SE-038: true 면 라이트를 전부 SpotLight3D 로 만든다(무대 스포트). false 면 SE-003 의 Omni/Spot 교대(A~E).
@export var spots_only: bool = false
## 사람이 읽는 비고(결과 표 "비고" 열).
@export var note: String = ""


## 구성이 스스로 모순되지 않는지. 문제 목록(빈 배열 = 유효).
func get_errors() -> PackedStringArray:
	var errs: PackedStringArray = PackedStringArray()
	if id.is_empty():
		errs.append("id 가 비어 있다")
	if instances <= 0:
		errs.append("%s: instances > 0 이어야 한다 (%d)" % [id, instances])
	if lights < 0:
		errs.append("%s: lights ≥ 0 이어야 한다 (%d)" % [id, lights])
	if shadow_lights < 0 or shadow_lights > lights:
		errs.append("%s: 0 ≤ shadow_lights ≤ lights 여야 한다 (%d / %d)" % [id, shadow_lights, lights])
	if prop_count < 0:
		errs.append("%s: prop_count ≥ 0 이어야 한다 (%d)" % [id, prop_count])
	if shadow_atlas_size <= 0 or (shadow_atlas_size & (shadow_atlas_size - 1)) != 0:
		errs.append("%s: shadow_atlas_size 는 양의 2의 거듭제곱 (%d)" % [id, shadow_atlas_size])
	return errs
