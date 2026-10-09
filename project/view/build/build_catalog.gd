class_name BuildCatalog
extends RefCounted
## SE-037: 가구 테이블(furniture.json)·맵(maps/<id>.json) 읽기 전용 로더 + 점유 기하(build.md G1~G6).
## view 가 배치 미리보기·렌더 위치를 정하는 데 쓴다. 판정의 최종 권위는 sim(build.placed/rejected)이다.
## 데이터 수치는 전부 JSON 에서 읽는다(가구 수·카테고리·회전 목록 포함). 쓰기는 하지 않는다.
## GridDataLoader 와 같은 방식(FileAccess READ). res://sim·core·world 를 로드하지 않는다(AC6).
##
## 좌표: 셀은 Vector2i(x, z). 이벤트 페이로드의 [x, z] 와는 to_cell()/to_pair() 로 바꾼다.

const FURNITURE_PATH: String = "res://data/furniture/furniture.json"
const MAP_PATH: String = "res://data/maps/tier1_club.json"

var _rows: Array[Dictionary] = []
var _by_id: Dictionary = {}
var _categories: PackedStringArray = PackedStringArray()
var _allowed_rotations: Array[int] = []
var _map: Dictionary = {}
var _kinds_by_char: Dictionary = {}
var _tiles: PackedStringArray = PackedStringArray()
var _map_size: Vector2i = Vector2i.ZERO


## 기본 경로의 두 파일을 읽는다. 형식 오류면 push_error 후 null.
static func load_default(furniture_path: String = FURNITURE_PATH, map_path: String = MAP_PATH) -> BuildCatalog:
	var f: Variant = _read_json(furniture_path)
	var m: Variant = _read_json(map_path)
	if not (f is Dictionary) or not (m is Dictionary):
		return null
	return from_dicts(f as Dictionary, m as Dictionary)


## 이미 파싱한 사전으로 만든다(테스트가 사본을 고쳐 넣는다). 형식 오류면 push_error 후 null.
static func from_dicts(furniture: Dictionary, map: Dictionary) -> BuildCatalog:
	var c: BuildCatalog = BuildCatalog.new()
	if not c._load_furniture(furniture) or not c._load_map(map):
		return null
	return c


# --- 가구 -------------------------------------------------------------------

func row_count() -> int:
	return _rows.size()


## 행 사본 목록(테이블 순서).
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r: Dictionary in _rows:
		out.append(r.duplicate(true))
	return out


func has_furniture(id: String) -> bool:
	return _by_id.has(id)


## 행 사본. 없으면 {}.
func furniture(id: String) -> Dictionary:
	if not _by_id.has(id):
		return {}
	return (_by_id[id] as Dictionary).duplicate(true)


## 카테고리 id 목록(테이블에 처음 나오는 순서).
func categories() -> PackedStringArray:
	return _categories.duplicate()


func rows_in_category(category: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r: Dictionary in _rows:
		if str(r.get("category", "")) == category:
			out.append(r.duplicate(true))
	return out


## build_rules.allowed_rotations (도, int).
func allowed_rotations() -> Array[int]:
	return _allowed_rotations.duplicate()


## 회전 R(build.md UI 계약): allowed_rotations 에서 다음 값(마지막 다음은 처음). rotatable == false 면 처음 값 고정.
func next_rotation(furniture_id: String, rotation: int) -> int:
	if _allowed_rotations.is_empty():
		return rotation
	var first: int = _allowed_rotations[0]
	if not bool(furniture(furniture_id).get("rotatable", false)):
		return first
	var i: int = _allowed_rotations.find(rotation)
	if i < 0:
		return first
	return _allowed_rotations[(i + 1) % _allowed_rotations.size()]


## 행의 footprint [w, d] → Vector2i(w, d). 없으면 (1, 1).
static func footprint_of(row: Dictionary) -> Vector2i:
	var fp: Variant = row.get("footprint", [1, 1])
	if fp is Array and (fp as Array).size() == 2:
		return Vector2i(int(fp[0]), int(fp[1]))
	return Vector2i.ONE


# --- 맵 ---------------------------------------------------------------------

func get_map_id() -> String:
	return str(_map.get("id", ""))


func get_map_size() -> Vector2i:
	return _map_size


func is_inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < _map_size.x and cell.y < _map_size.y


## 셀의 타일 종류 행 사본(맵 밖이면 {}).
func tile_kind(cell: Vector2i) -> Dictionary:
	if not is_inside(cell):
		return {}
	var ch: String = _tiles[cell.y][cell.x]
	return (_kinds_by_char.get(ch, {}) as Dictionary).duplicate()


## reference_layouts 의 한 행 사본(없으면 {}).
func reference_layout(id: String) -> Dictionary:
	for l: Variant in _map.get("reference_layouts", []):
		if l is Dictionary and str((l as Dictionary).get("id", "")) == id:
			return (l as Dictionary).duplicate(true)
	return {}


# --- 점유 기하 (build.md G2~G6, 회전 방향표) -------------------------------

## G2: 회전 후 [W', D']. 90·270 이면 w·d 교환.
static func rotated_size(footprint: Vector2i, rotation: int) -> Vector2i:
	if posmod(rotation, 180) == 90:
		return Vector2i(footprint.y, footprint.x)
	return footprint


## G3·G6: 점유 셀(z 오름차순, 같은 z 에서 x 오름차순). cell = 회전 후 점유 사각형의 최소 모서리.
static func cells_of(footprint: Vector2i, cell: Vector2i, rotation: int) -> Array[Vector2i]:
	var size: Vector2i = rotated_size(footprint, rotation)
	var out: Array[Vector2i] = []
	for z: int in range(cell.y, cell.y + size.y):
		for x: int in range(cell.x, cell.x + size.x):
			out.append(Vector2i(x, z))
	return out


## 회전 방향표 "등면 이웃"(B8 검사 셀). 정면의 반대쪽 한 줄.
static func back_neighbors(footprint: Vector2i, cell: Vector2i, rotation: int) -> Array[Vector2i]:
	var size: Vector2i = rotated_size(footprint, rotation)
	var x0: int = cell.x
	var z0: int = cell.y
	var x1: int = cell.x + size.x - 1
	var z1: int = cell.y + size.y - 1
	var out: Array[Vector2i] = []
	match posmod(rotation, 360):
		0:
			for x: int in range(x0, x1 + 1):
				out.append(Vector2i(x, z1 + 1))
		90:
			for z: int in range(z0, z1 + 1):
				out.append(Vector2i(x1 + 1, z))
		180:
			for x: int in range(x0, x1 + 1):
				out.append(Vector2i(x, z0 - 1))
		270:
			for z: int in range(z0, z1 + 1):
				out.append(Vector2i(x0 - 1, z))
	return out


## 회전 방향표 "앞 반평면"에 셀이 있는가(관람 타일 후보).
static func in_front_half_plane(footprint: Vector2i, cell: Vector2i, rotation: int, t: Vector2i) -> bool:
	var size: Vector2i = rotated_size(footprint, rotation)
	match posmod(rotation, 360):
		0:
			return t.y < cell.y
		90:
			return t.x < cell.x
		180:
			return t.y > cell.y + size.y - 1
		270:
			return t.x > cell.x + size.x - 1
	return false


## G5: 렌더 위치 = ((cell.x + W'/2) × t, 0, (cell.z + D'/2) × t). 피벗 = 점유 영역 바닥 중앙.
static func center_world(footprint: Vector2i, cell: Vector2i, rotation: int, tile_m: float) -> Vector3:
	var size: Vector2i = rotated_size(footprint, rotation)
	return Vector3((float(cell.x) + float(size.x) * 0.5) * tile_m, 0.0, (float(cell.y) + float(size.y) * 0.5) * tile_m)


## 커버리지 거리식(build.md "거리"): 사각형 [rect_min, rect_max](점유 셀 최소·최대)와 셀 t 의 d² ≤ r², r > 0.
## UI 계약 "설비 반경 미리보기"가 이 식을 쓴다. 정수 연산뿐.
static func radius_covers(rect_min: Vector2i, rect_max: Vector2i, t: Vector2i, radius: int) -> bool:
	if radius <= 0:
		return false
	var dx: int = maxi(maxi(rect_min.x - t.x, 0), t.x - rect_max.x)
	var dz: int = maxi(maxi(rect_min.y - t.y, 0), t.y - rect_max.y)
	return dx * dx + dz * dz <= radius * radius


## 반경 r 이 덮는 맵 안 셀 전부(G6 순서).
func radius_cells(rect_min: Vector2i, rect_max: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if radius <= 0:
		return out
	for z: int in range(maxi(rect_min.y - radius, 0), mini(rect_max.y + radius, _map_size.y - 1) + 1):
		for x: int in range(maxi(rect_min.x - radius, 0), mini(rect_max.x + radius, _map_size.x - 1) + 1):
			var t: Vector2i = Vector2i(x, z)
			if radius_covers(rect_min, rect_max, t, radius):
				out.append(t)
	return out


## 페이로드 [x, z] → Vector2i. 형식이 틀리면 IsoGridMath.INVALID_TILE.
static func to_cell(pair: Variant) -> Vector2i:
	if pair is Array and (pair as Array).size() == 2:
		return Vector2i(int(pair[0]), int(pair[1]))
	return IsoGridMath.INVALID_TILE


## Vector2i → 페이로드 [x, z] (int 2개, 명령 페이로드 E4).
static func to_pair(cell: Vector2i) -> Array:
	return [int(cell.x), int(cell.y)]


# --- 로드 -------------------------------------------------------------------

func _load_furniture(root: Dictionary) -> bool:
	var rows_v: Variant = root.get("rows")
	if not (rows_v is Array) or (rows_v as Array).is_empty():
		push_error("BuildCatalog: furniture rows 없음")
		return false
	for r: Variant in rows_v:
		if not (r is Dictionary) or not (r as Dictionary).has("id"):
			push_error("BuildCatalog: furniture 행 형식 오류")
			return false
		var row: Dictionary = (r as Dictionary).duplicate(true)
		var id: String = str(row["id"])
		_rows.append(row)
		_by_id[id] = row
		var cat: String = str(row.get("category", ""))
		if not _categories.has(cat):
			_categories.append(cat)
	var rules: Dictionary = root.get("build_rules", {}) as Dictionary
	for v: Variant in rules.get("allowed_rotations", []):
		_allowed_rotations.append(int(v))
	if _allowed_rotations.is_empty():
		push_error("BuildCatalog: build_rules.allowed_rotations 없음")
		return false
	return true


func _load_map(root: Dictionary) -> bool:
	_map = root.duplicate(true)
	_map_size = Vector2i(int(root.get("width", 0)), int(root.get("depth", 0)))
	for k: Variant in root.get("tile_kinds", []):
		if k is Dictionary:
			_kinds_by_char[str((k as Dictionary).get("char", ""))] = (k as Dictionary).duplicate()
	for row: Variant in root.get("tiles", []):
		_tiles.append(str(row))
	if _map_size.x <= 0 or _tiles.size() != _map_size.y:
		push_error("BuildCatalog: 맵 tiles 행 수가 depth 와 다르다")
		return false
	for row: String in _tiles:
		if row.length() != _map_size.x:
			push_error("BuildCatalog: 맵 tiles 행 길이가 width 와 다르다")
			return false
	return true


static func _read_json(path: String) -> Variant:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("BuildCatalog: %s 를 열 수 없다 (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	var v: Variant = JSON.parse_string(f.get_as_text())
	if not (v is Dictionary):
		push_error("BuildCatalog: %s JSON 형식 오류" % path)
	return v
