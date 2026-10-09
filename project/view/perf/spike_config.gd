class_name SpikeConfig
extends Resource
## SE-003 성능 스파이크 구성 한 행(티켓 표 A~D). 값은 spike_configs.tres 에 있다.
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
	if shadow_atlas_size <= 0 or (shadow_atlas_size & (shadow_atlas_size - 1)) != 0:
		errs.append("%s: shadow_atlas_size 는 양의 2의 거듭제곱 (%d)" % [id, shadow_atlas_size])
	return errs
