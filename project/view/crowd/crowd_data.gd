class_name CrowdData
extends RefCounted
## SE-038: 군중 표시에 필요한 데이터 값(읽기 전용). 수치는 전부 JSON 에서 읽는다(코드 리터럴 금지).
##   audience.json: pos_scale(표시 좌표 1/P m), max_agents(MultiMesh 인스턴스 수), types[].id·color(유형 색).
##   sim.json:      ticks_per_second(보간 틱 길이 = 1 / tps), tile_size_m(월드 m),
##                  phases[0].default_speed(새 게임 배속 — 보간 초기 speed, audience.md view 계약 "위치", SE-040 AC-38a).
## GridDataLoader·BuildCatalog 과 같은 방식(FileAccess READ). res://sim·core·world 를 로드하지 않는다.

const AUDIENCE_PATH: String = "res://data/audience/audience.json"
const SIM_PATH: String = "res://data/sim/sim.json"
## tick.md #배속 단위 정의: speed 1 = 실시간(수치가 아니라 배속의 단위).
const SPEED_REALTIME: int = 1

## 표시 좌표 단위(px ÷ pos_scale = 타일 단위).
var pos_scale: int = 0
## 동시 에이전트 상한 = MultiMesh instance_count.
var max_agents: int = 0
## 고정 틱 길이(초) = 1 / ticks_per_second.
var tick_len_sec: float = 0.0
## 타일 한 변(m).
var tile_m: float = 0.0
## 새 게임 배속(sim.json phases[0].default_speed). phases 가 없는 사본(테스트 고정 데이터)이면 SPEED_REALTIME.
var default_speed: int = SPEED_REALTIME
## 유형 id(audience.json types 순서).
var type_ids: PackedStringArray = PackedStringArray()
## 유형 id → 인스턴스 색(알파 1.0 고정, materials.md M3).
var type_colors: Dictionary = {}


## 기본 경로의 두 파일을 읽는다. 형식 오류면 push_error 후 null.
static func load_default(audience_path: String = AUDIENCE_PATH, sim_path: String = SIM_PATH) -> CrowdData:
	var a: Variant = _read_json(audience_path)
	var s: Variant = _read_json(sim_path)
	if not (a is Dictionary) or not (s is Dictionary):
		return null
	return from_dicts(a as Dictionary, s as Dictionary)


## 이미 파싱한 사전으로 만든다(테스트가 사본을 고쳐 넣는다). 형식 오류면 push_error 후 null.
static func from_dicts(audience: Dictionary, sim: Dictionary) -> CrowdData:
	var d: CrowdData = CrowdData.new()
	d.pos_scale = int(audience.get("pos_scale", 0))
	d.max_agents = int(audience.get("max_agents", 0))
	var tps: float = float(sim.get("ticks_per_second", 0))
	d.tile_m = float(sim.get("tile_size_m", 0.0))
	if d.pos_scale <= 0 or d.max_agents <= 0 or tps <= 0.0 or d.tile_m <= 0.0:
		push_error("CrowdData: pos_scale·max_agents(audience.json), ticks_per_second·tile_size_m(sim.json) 은 양수여야 한다")
		return null
	d.tick_len_sec = 1.0 / tps
	var phases: Variant = sim.get("phases", [])
	if phases is Array and not (phases as Array).is_empty() and (phases as Array)[0] is Dictionary:
		d.default_speed = int(((phases as Array)[0] as Dictionary).get("default_speed", SPEED_REALTIME))
	for t: Variant in audience.get("types", []):
		if not (t is Dictionary):
			continue
		var id: String = str((t as Dictionary).get("id", ""))
		var hex: String = str((t as Dictionary).get("color", ""))
		if id.is_empty() or not Color.html_is_valid(hex):
			push_error("CrowdData: 유형 '%s' 의 color '%s' 가 hex 가 아니다" % [id, hex])
			return null
		var c: Color = Color.html(hex)
		c.a = 1.0
		d.type_ids.append(id)
		d.type_colors[id] = c
	if d.type_ids.is_empty():
		push_error("CrowdData: audience.json types 가 비어 있다")
		return null
	return d


## 표시 좌표 [px, pz](1/pos_scale 타일) → 월드 위치(바닥 y = 0).
func to_world(px: int, pz: int) -> Vector3:
	return Vector3(float(px) / float(pos_scale) * tile_m, 0.0, float(pz) / float(pos_scale) * tile_m)


## 타일 중앙의 표시 좌표(audience.md "표시 좌표" c(t) = t × P + P/2). 샌드박스 프리셋이 가짜 페이로드를 만들 때 쓴다.
func tile_center_pos(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x * pos_scale + pos_scale / 2, cell.y * pos_scale + pos_scale / 2)


static func _read_json(path: String) -> Variant:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("CrowdData: %s 를 열 수 없다 (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	var v: Variant = JSON.parse_string(f.get_as_text())
	if not (v is Dictionary):
		push_error("CrowdData: %s JSON 형식 오류" % path)
	return v
