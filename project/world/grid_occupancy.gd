class_name GridOccupancy
extends RefCounted
## 그리드 점유와 회전 풋프린트 기하 (SE-032). 규칙: docs/gdd/build.md#좌표·회전·점유 G1~G6 과 회전별 방향표.
##
## - 정적 함수는 순수하다(입력만 보고 같은 출력, 상태 없음). 좌표 사각형은 Rect2i(position = 최소 모서리 [x0, z0],
##   size = 회전 후 [W', D']), 셀은 내부에서 Vector2i(x, z), 밖으로 내보낼 때는 [x, z] int 배열(G6 순서: z, x 오름차순).
## - 인스턴스는 셀 → entity_id 점유표 하나만 갖는다. 규칙 판정(B5~B10)은 BuildSystem 이 한다.

## 회전 방향표(build.md "회전별 방향표")가 아는 회전. 데이터 allowed_rotations 는 이 집합의 부분집합이어야 한다(FC3).
const ROT_0: int = 0
const ROT_90: int = 90
const ROT_180: int = 180
const ROT_270: int = 270
const KNOWN_ROTATIONS: Array[int] = [ROT_0, ROT_90, ROT_180, ROT_270]
## 초점 셀 g = E[⌊n / FOCAL_DIVISOR⌋] (build.md C0 "초점 셀").
const FOCAL_DIVISOR: int = 2

var _owner: Dictionary = {}   # Vector2i -> entity_id(String)


# --- 순수 기하 -------------------------------------------------------------------

## G2: 회전 0·180 은 [w, d], 90·270 은 [d, w].
static func rotated_size(footprint: Array, rotation: int) -> Array:
	var w: int = int(footprint[0])
	var d: int = int(footprint[1])
	if rotation == ROT_90 or rotation == ROT_270:
		return [d, w]
	return [w, d]


## B5·RS4: 회전 후 점유 사각형이 맵 [0, width) × [0, depth) 안에 있는가. cell 성분을 GDScript 64비트 int 그대로
## 비교한다(Rect2i/Vector2i 는 int32 라 큰 좌표가 잘린다, SE-032-bug). 덧셈 없이 비교해 int64 오버플로도 없다.
## rect_of/cells_of 에 외부 좌표를 넣기 전에 반드시 이 검사를 먼저 한다.
static func rect_in_bounds(footprint: Array, cell: Array, rotation: int, width: int, depth: int) -> bool:
	var size: Array = rotated_size(footprint, rotation)
	var x: int = cell[0]
	var z: int = cell[1]
	return x >= 0 and z >= 0 and x <= width - int(size[0]) and z <= depth - int(size[1])


## G3: cell = 회전 후 점유 사각형의 최소 모서리. 성분이 int32 로 잘리므로 rect_in_bounds 를 통과한 cell 만 넣는다.
static func rect_of(footprint: Array, cell: Array, rotation: int) -> Rect2i:
	var size: Array = rotated_size(footprint, rotation)
	return Rect2i(int(cell[0]), int(cell[1]), int(size[0]), int(size[1]))


## G3·G6: 점유 셀 [x, z] 목록, z 오름차순 → x 오름차순.
static func cells_of(footprint: Array, cell: Array, rotation: int) -> Array:
	return rect_cells(rect_of(footprint, cell, rotation))


static func rect_cells(r: Rect2i) -> Array:
	var out: Array = []
	for z: int in range(r.position.y, r.end.y):
		for x: int in range(r.position.x, r.end.x):
			out.append([x, z])
	return out


## 방향표 "등면 이웃"(B8 검사 셀). 정면의 반대쪽 가장자리 바깥 한 줄.
static func back_neighbors(r: Rect2i, rotation: int) -> Array:
	match rotation:
		ROT_0:
			return _row_z(r, r.end.y)
		ROT_90:
			return _col_x(r, r.end.x)
		ROT_180:
			return _row_z(r, r.position.y - 1)
		ROT_270:
			return _col_x(r, r.position.x - 1)
	return []


## 방향표 "앞 행"(B10 (b)). 정면 가장자리 바깥 한 줄.
static func front_row(r: Rect2i, rotation: int) -> Array:
	match rotation:
		ROT_0:
			return _row_z(r, r.position.y - 1)
		ROT_90:
			return _col_x(r, r.position.x - 1)
		ROT_180:
			return _row_z(r, r.end.y)
		ROT_270:
			return _col_x(r, r.end.x)
	return []


## 방향표 "앞 반평면"(관람 타일 후보).
static func in_front(r: Rect2i, rotation: int, x: int, z: int) -> bool:
	match rotation:
		ROT_0:
			return z < r.position.y
		ROT_90:
			return x < r.position.x
		ROT_180:
			return z > r.end.y - 1
		ROT_270:
			return x > r.end.x - 1
	return false


## 방향표 "초점 셀 후보": 정면 가장자리 셀(점유 셀 안쪽 한 줄), 정렬 기준 순.
static func front_edge(r: Rect2i, rotation: int) -> Array:
	match rotation:
		ROT_0:
			return _row_z(r, r.position.y)
		ROT_90:
			return _col_x(r, r.position.x)
		ROT_180:
			return _row_z(r, r.end.y - 1)
		ROT_270:
			return _col_x(r, r.end.x - 1)
	return []


## C0 초점 셀 g = E[⌊n/2⌋].
static func focal_cell(r: Rect2i, rotation: int) -> Array:
	var e: Array = front_edge(r, rotation)
	if e.is_empty():
		return []
	return e[e.size() / FOCAL_DIVISOR]


## 거리식 d²(t, i) (build.md #커버리지 "거리"). 사각형 밖 축별 거리의 제곱합. 정수 연산뿐.
static func dist2(r: Rect2i, x: int, z: int) -> int:
	var dx: int = maxi(maxi(r.position.x - x, 0), x - (r.end.x - 1))
	var dz: int = maxi(maxi(r.position.y - z, 0), z - (r.end.y - 1))
	return dx * dx + dz * dz


static func _row_z(r: Rect2i, z: int) -> Array:
	var out: Array = []
	for x: int in range(r.position.x, r.end.x):
		out.append([x, z])
	return out


static func _col_x(r: Rect2i, x: int) -> Array:
	var out: Array = []
	for z: int in range(r.position.y, r.end.y):
		out.append([x, z])
	return out


# --- 점유표 ----------------------------------------------------------------------

func clear() -> void:
	_owner.clear()


## cells([x, z] 목록)를 entity_id 로 점유한다. 이미 점유된 셀이 하나라도 있으면 false, 점유표 불변.
func add(entity_id: String, cells: Array) -> bool:
	for c: Array in cells:
		if _owner.has(Vector2i(int(c[0]), int(c[1]))):
			return false
	for c: Array in cells:
		_owner[Vector2i(int(c[0]), int(c[1]))] = entity_id
	return true


## entity_id 가 점유한 셀을 비운다.
func remove(entity_id: String, cells: Array) -> void:
	for c: Array in cells:
		var k: Vector2i = Vector2i(int(c[0]), int(c[1]))
		if _owner.get(k, "") == entity_id:
			_owner.erase(k)


## Vector2i(int32)로 잘리지 않고 표현되는 좌표인가(SE-032-bug). 잘리는 좌표는 어떤 셀도 아니다.
static func fits_cell(x: int, z: int) -> bool:
	var v: Vector2i = Vector2i(x, z)
	return v.x == x and v.y == z


func is_occupied(x: int, z: int) -> bool:
	return fits_cell(x, z) and _owner.has(Vector2i(x, z))


## 셀을 점유한 entity_id. 비었거나 표현 불가 좌표면 "".
func owner_of(x: int, z: int) -> String:
	if not fits_cell(x, z):
		return ""
	return _owner.get(Vector2i(x, z), "")


func size() -> int:
	return _owner.size()


## 점유 셀 집합 사본 {Vector2i: true}. 도달 집합 계산(MapConfig.reachable)의 차단 입력.
func blocked_set() -> Dictionary:
	var out: Dictionary = {}
	for k: Vector2i in _owner:
		out[k] = true
	return out


## 점유 셀 [x, z] 목록, G6 순서.
func cells() -> Array:
	var keys: Array = _owner.keys()
	keys.sort_custom(_zx_less)
	var out: Array = []
	for k: Vector2i in keys:
		out.append([k.x, k.y])
	return out


static func _zx_less(a: Vector2i, b: Vector2i) -> bool:
	return a.y < b.y or (a.y == b.y and a.x < b.x)
