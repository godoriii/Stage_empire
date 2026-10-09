class_name MapConfig
extends RefCounted
## 맵 로더 (SE-032). project/data/maps/<id>.json (v0: tier1_club). 규칙: docs/gdd/build.md#맵, #설정-로드-검사 MK1~MK6.
## 스키마(maps.schema.json)로 못 하는 교차 검사를 한다. 실패하면 push_error 1회, null.
## JSON 숫자는 float 로 파싱되므로 정수값 float 는 int 로 정규화해서 보관한다. 모든 필드는 읽기 전용으로 취급한다.

const DEFAULT_PATH: String = "res://data/maps/tier1_club.json"
const TIERS_PATH: String = "res://data/tiers/tiers.json"
const SUPPORTED_VERSION: int = 1
## 타일 종류 id 는 5종 고정(build.md "타일 종류": 규칙이 id 로 참조). 속성은 데이터다.
const KIND_FLOOR: String = "floor"
const KIND_WALL: String = "wall"
const KIND_PILLAR: String = "pillar"
const KIND_ENTRANCE: String = "entrance"
const KIND_APRON: String = "apron"
const KIND_IDS: Array[String] = [KIND_FLOOR, KIND_WALL, KIND_PILLAR, KIND_ENTRANCE, KIND_APRON]
const KIND_BOOL_FIELDS: Array[String] = ["buildable", "walkable", "standing", "blocks_sight", "mountable"]
## 좌표 [x, z] 원소 수(G1).
const PAIR_SIZE: int = 2
## 4방향 이웃(C0 BFS). 대각 이동 없음.
const DIRS4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var version: int = 0
var id: String = ""
var tier: int = 0
var map_name: String = ""
var width: int = 0
var depth: int = 0
var persons_per_tile_bp: int = 0
## tiers.json 의 이 맵 티어 행 값(C4 상한, MK2).
var capacity_max: int = 0
var grid_size: int = 0
## Σ 맵 타일 kind.evac_capacity (C5 첫 항).
var evac_total: int = 0

var _kinds: Array = []             # [{id, char, buildable, walkable, standing, blocks_sight, mountable, evac_capacity}]
var _grid: PackedInt32Array = []   # z * width + x -> _kinds 인덱스
var _entrances: Array = []         # Vector2i, z → x 오름차순
var _layouts: Array = []           # [{id, description, placements: [{furniture_id, cell, rotation}], expected}]


## 파일을 읽어 검증한다. tiers.json 은 기본 경로에서 읽는다(읽기 전용).
static func load(path: String = DEFAULT_PATH, tiers_path: String = TIERS_PATH) -> MapConfig:
	var d: Variant = read_json(path)
	var t: Variant = read_json(tiers_path)
	if d == null or t == null:
		return null
	return from_dict(d, t)


## JSON 파일 → Dictionary. 실패하면 push_error, null.
static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("[MapConfig] 파일 없음: %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("[MapConfig] JSON 객체가 아님: %s" % path)
		return null
	return parsed


## 메모리 상 Dictionary(JSON 파싱 결과와 같은 모양)에서 만든다. 테스트의 변형 사본 검증용.
static func from_dict(d: Dictionary, tiers: Dictionary) -> MapConfig:
	var m: MapConfig = MapConfig.new()
	var ver: Variant = as_int(d.get("version"))
	if ver == null or ver != SUPPORTED_VERSION:
		return _fail("version 은 %d 이어야 한다: %s" % [SUPPORTED_VERSION, d.get("version")])
	m.version = ver
	if not (d.get("id") is String):
		return _fail("id 는 문자열이어야 한다")
	m.id = d["id"]
	m.map_name = str(d.get("name", ""))
	for key: String in ["tier", "width", "depth", "persons_per_tile_bp"]:
		var v: Variant = as_int(d.get(key))
		if v == null or v < 0:
			return _fail("%s 는 0 이상 정수여야 한다: %s" % [key, d.get(key)])
	m.tier = as_int(d["tier"])
	m.width = as_int(d["width"])
	m.depth = as_int(d["depth"])
	m.persons_per_tile_bp = as_int(d["persons_per_tile_bp"])
	if m.width < 1 or m.depth < 1:
		return _fail("width·depth 는 1 이상이어야 한다")

	# tile_kinds (MK3 의 id·char 유일, 5종 고정)
	var raw_kinds: Variant = d.get("tile_kinds")
	if not (raw_kinds is Array):
		return _fail("tile_kinds 는 배열이어야 한다")
	var by_char: Dictionary = {}
	var seen_ids: Dictionary = {}
	for rk: Variant in raw_kinds:
		var k: Variant = _parse_kind(rk)
		if k == null:
			return null
		if seen_ids.has(k["id"]):
			return _fail("MK3 tile_kinds id 중복: %s" % k["id"])
		if by_char.has(k["char"]):
			return _fail("MK3 tile_kinds char 중복: '%s'" % k["char"])
		seen_ids[k["id"]] = true
		by_char[k["char"]] = m._kinds.size()
		m._kinds.append(k)
	for kid: String in KIND_IDS:
		if not seen_ids.has(kid):
			return _fail("tile_kinds 에 '%s' 가 없다(5종 고정: %s)" % [kid, KIND_IDS])
	if seen_ids.size() != KIND_IDS.size():
		return _fail("tile_kinds 는 5종 고정이다: %s" % [seen_ids.keys()])

	# MK1 격자 치수
	var rows: Variant = d.get("tiles")
	if not (rows is Array) or (rows as Array).size() != m.depth:
		return _fail("MK1 tiles 행 수가 depth(%d)와 다르다" % m.depth)
	for z: int in m.depth:
		var line: Variant = rows[z]
		if not (line is String) or (line as String).length() != m.width:
			return _fail("MK1 tiles[%d] 길이가 width(%d)와 다르다" % [z, m.width])

	# MK2 티어 grid_size
	var trow: Variant = _tier_row(tiers, m.tier)
	if trow == null:
		return _fail("MK2 tiers.json 에 tier %d 행이 없다" % m.tier)
	var gs: Variant = as_int(trow.get("grid_size"))
	var cmax: Variant = as_int(trow.get("capacity_max"))
	if gs == null or cmax == null or cmax < 0:
		return _fail("tiers.json tier %d 행의 grid_size·capacity_max 가 정수가 아니다" % m.tier)
	m.grid_size = gs
	m.capacity_max = cmax
	if m.width != gs or m.depth != gs:
		return _fail("MK2 width %d·depth %d 가 tiers grid_size %d 와 다르다" % [m.width, m.depth, gs])

	# MK3 모든 글자가 어떤 char
	m._grid.resize(m.width * m.depth)
	for z: int in m.depth:
		var line: String = rows[z]
		for x: int in m.width:
			var c: String = line[x]
			if not by_char.has(c):
				return _fail("MK3 tiles[%d][%d] 의 글자 '%s' 가 tile_kinds 에 없다" % [z, x, c])
			var ki: int = by_char[c]
			m._grid[z * m.width + x] = ki
			var kind: Dictionary = m._kinds[ki]
			m.evac_total += int(kind["evac_capacity"])
			if kind["id"] == KIND_ENTRANCE:
				m._entrances.append(Vector2i(x, z))

	# MK4
	if m._entrances.is_empty():
		return _fail("MK4 entrance 타일이 없다")
	# MK5 닫힌 방
	for z: int in m.depth:
		for x: int in m.width:
			if x != 0 and z != 0 and x != m.width - 1 and z != m.depth - 1:
				continue
			var kind: Dictionary = m._kind_ref(x, z)
			if kind["walkable"] and kind["id"] != KIND_ENTRANCE:
				return _fail("MK5 가장자리 [%d,%d] 가 걷기 가능한 비입구 타일이다(닫힌 방 아님)" % [x, z])
	# MK6 빈 맵 연결
	var r: Dictionary = m.reachable({})
	for z: int in m.depth:
		for x: int in m.width:
			if m.is_walkable(x, z) and not r.has(Vector2i(x, z)):
				return _fail("MK6 걷기 가능 타일 [%d,%d] 가 입구와 연결되지 않는다" % [x, z])

	# reference_layouts (테스트 픽스처)
	var raw_layouts: Variant = d.get("reference_layouts", [])
	if not (raw_layouts is Array):
		return _fail("reference_layouts 는 배열이어야 한다")
	for rl: Variant in raw_layouts:
		var l: Variant = _parse_layout(rl)
		if l == null:
			return null
		m._layouts.append(l)
	return m


# --- 조회 ----------------------------------------------------------------------

func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and z >= 0 and x < width and z < depth


## 타일 종류 사본. 맵 밖이면 {}.
func tile_kind(cell: Array) -> Dictionary:
	var x: int = int(cell[0])
	var z: int = int(cell[1])
	if not in_bounds(x, z):
		return {}
	return _kind_ref(x, z).duplicate(true)


func is_walkable(x: int, z: int) -> bool:
	return in_bounds(x, z) and _kind_ref(x, z)["walkable"]


func is_standing(x: int, z: int) -> bool:
	return in_bounds(x, z) and _kind_ref(x, z)["standing"]


func is_buildable(x: int, z: int) -> bool:
	return in_bounds(x, z) and _kind_ref(x, z)["buildable"]


## 맵 밖은 mountable 이 아니다(B8).
func is_mountable(x: int, z: int) -> bool:
	return in_bounds(x, z) and _kind_ref(x, z)["mountable"]


func blocks_sight(x: int, z: int) -> bool:
	return in_bounds(x, z) and _kind_ref(x, z)["blocks_sight"]


## 입구 타일 [x, z] 목록(z → x 오름차순).
func entrances() -> Array:
	var out: Array = []
	for e: Vector2i in _entrances:
		out.append([e.x, e.y])
	return out


## C0 도달 집합 R: 모든 entrance 에서 시작하는 4방향 BFS. 지나갈 수 있는 타일 = walkable 이고 blocked 에 없는 타일.
## blocked = {Vector2i: true}. 결과 {Vector2i: true} (집합, 순회 순서 무관).
func reachable(blocked: Dictionary) -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array[Vector2i] = []
	for e: Vector2i in _entrances:
		if not blocked.has(e) and not seen.has(e):
			seen[e] = true
			queue.append(e)
	var head: int = 0
	while head < queue.size():
		var p: Vector2i = queue[head]
		head += 1
		for dv: Vector2i in DIRS4:
			var q: Vector2i = p + dv
			if seen.has(q) or blocked.has(q) or not is_walkable(q.x, q.y):
				continue
			seen[q] = true
			queue.append(q)
	return seen


func layout_ids() -> Array:
	var out: Array = []
	for l: Dictionary in _layouts:
		out.append(l["id"])
	return out


## 기준 배치 사본. 없으면 {}.
func layout(layout_id: String) -> Dictionary:
	for l: Dictionary in _layouts:
		if l["id"] == layout_id:
			return l.duplicate(true)
	return {}


# --- 내부 ----------------------------------------------------------------------

func _kind_ref(x: int, z: int) -> Dictionary:
	return _kinds[_grid[z * width + x]]


static func _parse_kind(rk: Variant) -> Variant:
	if not (rk is Dictionary):
		return _fail("tile_kinds[] 원소는 객체여야 한다")
	var kid: Variant = rk.get("id")
	var ch: Variant = rk.get("char")
	if not (kid is String) or not (ch is String) or (ch as String).length() != 1:
		return _fail("tile_kinds[].id 는 문자열, char 는 한 글자여야 한다")
	var out: Dictionary = {"id": kid, "char": ch}
	for f: String in KIND_BOOL_FIELDS:
		if not (rk.get(f) is bool):
			return _fail("tile_kinds '%s' 의 %s 는 bool 이어야 한다" % [kid, f])
		out[f] = rk[f]
	var ev: Variant = as_int(rk.get("evac_capacity"))
	if ev == null or ev < 0:
		return _fail("tile_kinds '%s' 의 evac_capacity 는 0 이상 정수여야 한다" % kid)
	out["evac_capacity"] = ev
	return out


static func _parse_layout(rl: Variant) -> Variant:
	if not (rl is Dictionary) or not (rl.get("id") is String):
		return _fail("reference_layouts[] 는 id 가 있는 객체여야 한다")
	var placements: Variant = rl.get("placements")
	if not (placements is Array):
		return _fail("reference_layouts '%s' 의 placements 는 배열이어야 한다" % rl["id"])
	var ps: Array = []
	for p: Variant in placements:
		if not (p is Dictionary) or not (p.get("furniture_id") is String):
			return _fail("reference_layouts '%s' 의 placements[] 형식 오류" % rl["id"])
		var cell: Variant = as_int_pair(p.get("cell"))
		var rot: Variant = as_int(p.get("rotation"))
		if cell == null or rot == null:
			return _fail("reference_layouts '%s' 의 cell·rotation 은 정수여야 한다" % rl["id"])
		ps.append({"furniture_id": p["furniture_id"], "cell": cell, "rotation": rot})
	return {
		"id": rl["id"],
		"description": str(rl.get("description", "")),
		"placements": ps,
		"expected": int_deep(rl.get("expected", {})),
	}


static func _tier_row(tiers: Dictionary, t: int) -> Variant:
	var rows: Variant = tiers.get("rows")
	if not (rows is Array):
		return null
	for r: Variant in rows:
		if r is Dictionary and as_int(r.get("tier")) == t:
			return r
	return null


## int, 또는 정수값인 유한 float 만 int 로. 그 밖(bool·문자열·1.5·null)은 null.
static func as_int(v: Variant) -> Variant:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v):
		return int(v)
	return null


## [x, z] 정수 쌍. 아니면 null.
static func as_int_pair(v: Variant) -> Variant:
	if not (v is Array) or (v as Array).size() != PAIR_SIZE:
		return null
	var x: Variant = as_int(v[0])
	var z: Variant = as_int(v[1])
	if x == null or z == null:
		return null
	return [x, z]


## 정수값 float → int (재귀). 그 밖의 값은 그대로.
static func int_deep(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var n: Variant = as_int(v)
			return n if n != null else v
		TYPE_ARRAY:
			var arr: Array = []
			for e: Variant in v:
				arr.append(int_deep(e))
			return arr
		TYPE_DICTIONARY:
			var out: Dictionary = {}
			for k: Variant in v:
				out[k] = int_deep(v[k])
			return out
	return v


static func _fail(msg: String) -> Variant:
	push_error("[MapConfig] " + msg)
	return null
