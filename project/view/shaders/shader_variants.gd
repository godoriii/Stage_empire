class_name ShaderVariants
extends RefCounted
## SE-004 툰 셰이더 시안 목록·해석·적용. 정적 함수만 있다(인스턴스 없음).
## 명령줄 --material=<id> 해석은 이 파일 한 곳에만 둔다(샌드박스·스파이크·측정기가 모두 이것을 쓴다).
##
## 시안 id: "plain"(SE-004 이전 룩 = 정점색 StandardMaterial3D, material_override 없음 — 비교용) / "a" / "b" / "c".
## 기본값은 DEFAULT_ID = "b"(SE-018, 2026-10-09 프로덕트 오너 결정). 세 진입점(샌드박스·스파이크·측정기)이
## 기본값을 전부 DEFAULT_ID 에서 받는다. 시안 id 리터럴은 이 파일에만 둔다(test_view_boundary.gd 가 검사).
## 시안 머티리얼은 params/toon_<id>.tres(ShaderMaterial, shader = toon.gdshader, next_pass = outline_<id>.tres).
## 상수는 전부 .tres 에 있다. 이 파일에는 셰이더 값이 없다.
## 표시 전용: 게임 상태를 읽거나 바꾸지 않는다.

const ARG_MATERIAL: String = "--material="
## 인자 없이 실행할 때의 시안(SE-018: 시안 B 확정).
const DEFAULT_ID: String = "b"
## 머티리얼 없이 메시의 원래 머티리얼(정점색 StandardMaterial3D)을 쓰는 비교용 id. 로드 대상이 아니다.
const PLAIN_ID: String = "plain"
## 유효한 시안 id 전부(순서 = 비교 표 순서).
const IDS: PackedStringArray = ["plain", "a", "b", "c"]
## 런타임 전환 키(shader_variant_1/2/3)가 고르는 시안. 인덱스 = 액션 번호 − 1.
const SELECTABLE_IDS: PackedStringArray = ["a", "b", "c"]
const MATERIAL_PATH_PATTERN: String = "res://view/shaders/params/toon_%s.tres"


## 시안 id 결정: @export 값 > 명령줄 --material= > default_id. 대소문자 무시(소문자로 돌려준다).
## 유효성은 검사하지 않는다(is_valid_id 로 호출자가 판단). SpikeCrowd.resolve_config_id 와 같은 우선순위.
static func resolve_material_id(exported: String, user_args: PackedStringArray, default_id: String) -> String:
	if not exported.strip_edges().is_empty():
		return exported.strip_edges().to_lower()
	for a: String in user_args:
		if a.begins_with(ARG_MATERIAL):
			return a.trim_prefix(ARG_MATERIAL).strip_edges().to_lower()
	return default_id


static func is_valid_id(id: String) -> bool:
	return IDS.has(id)


## 시안 머티리얼. "plain" 은 의도된 null(오류 아님), 없는 id 도 null(호출자가 is_valid_id 로 구분한다).
## 유효하고 plain 이 아닌 id 의 리소스 로드가 실패하면 push_error 후 null(조용히 null 을 돌려주지 않는다).
## path_pattern 은 테스트가 로드 실패를 만들기 위한 인자다(기본값이면 params/toon_<id>.tres).
static func load_material(id: String, path_pattern: String = MATERIAL_PATH_PATTERN) -> ShaderMaterial:
	if id == PLAIN_ID or not is_valid_id(id):
		return null
	var path: String = path_pattern % id
	var mat: ShaderMaterial = null
	if ResourceLoader.exists(path):
		mat = load(path) as ShaderMaterial
	if mat == null:
		push_error("ShaderVariants: 시안 '%s' 머티리얼 로드 실패: %s" % [id, path])
	return mat


## root(자신 포함) 아래 모든 MeshInstance3D·MultiMeshInstance3D 의 material_override 를 시안 머티리얼로 바꾼다.
## "plain" 이면 null 로 되돌린다(메시의 원래 머티리얼). exclude 의 노드와 그 자손은 건드리지 않는다.
## 외곽선은 머티리얼의 next_pass 라 노드를 추가하지 않는다. 적용한 노드 수.
## 없는 id 이거나 시안 머티리얼 로드가 실패하면 push_error 후 -1(아무것도 바꾸지 않음).
## Label3D·Sprite3D·파티클 등 다른 GeometryInstance3D 는 대상이 아니다(글자·빌보드가 툰 셰이더로 깨지지 않게).
static func apply(root: Node, id: String, exclude: Array[Node] = [], path_pattern: String = MATERIAL_PATH_PATTERN) -> int:
	if not is_valid_id(id):
		push_error("ShaderVariants: 시안 '%s' 없음 (가능: %s)" % [id, ", ".join(IDS)])
		return -1
	var mat: ShaderMaterial = load_material(id, path_pattern)
	if mat == null and id != PLAIN_ID:
		return -1
	var count: int = 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if exclude.has(n) or n.is_queued_for_deletion():
			continue
		if n is MeshInstance3D or n is MultiMeshInstance3D:
			(n as GeometryInstance3D).material_override = mat
			count += 1
		stack.append_array(n.get_children())
	return count
