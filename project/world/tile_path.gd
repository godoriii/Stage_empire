class_name TilePath
extends RefCounted
## 타일 경로 탐색 (SE-032, 관객 SE-034 용). AStarGrid2D(RefCounted, Node 아님) 래퍼.
## 지나갈 수 있는 타일 = 맵 walkable 이고 가구가 점유하지 않은 타일(C0 BFS 와 같은 기준). 대각 이동 금지(v0),
## 맨해튼 휴리스틱. 같은 맵·같은 점유·같은 질의 → 같은 경로(결정적). 도달 불가·맵 밖·막힌 끝점 → 빈 배열.
## 경로는 [x, z] int 배열 목록, 출발·도착 포함.

var _map: MapConfig
var _astar: AStarGrid2D


func _init(p_map: MapConfig) -> void:
	_map = p_map
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(0, 0, _map.width, _map.depth)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.jumping_enabled = false
	_astar.update()
	_reset_to_map()


## 점유를 처음부터 다시 맞춘다(맵 기본 상태 + occupancy 의 점유 셀은 막힘).
func sync(occupancy: GridOccupancy) -> void:
	_reset_to_map()
	set_occupied(occupancy.cells(), true)


## 셀 목록의 점유를 갱신한다. 맵에서 walkable 이 아닌 타일은 항상 막힌 채로 둔다. 맵 밖 셀은 무시.
func set_occupied(cells: Array, occupied: bool) -> void:
	for c: Array in cells:
		var x: int = int(c[0])
		var z: int = int(c[1])
		if _map.is_walkable(x, z):
			_astar.set_point_solid(Vector2i(x, z), occupied)


func is_passable(x: int, z: int) -> bool:
	return _map.in_bounds(x, z) and not _astar.is_point_solid(Vector2i(x, z))


## from → to 경로. 도달 불가·맵 밖·끝점이 막힘이면 [].
func find_path(from: Array, to: Array) -> Array:
	var a: Vector2i = Vector2i(int(from[0]), int(from[1]))
	var b: Vector2i = Vector2i(int(to[0]), int(to[1]))
	if not is_passable(a.x, a.y) or not is_passable(b.x, b.y):
		return []
	var out: Array = []
	for v: Vector2i in _astar.get_id_path(a, b):
		out.append([v.x, v.y])
	return out


## 입구 → to. 입구마다 경로를 구해 가장 짧은 것(같으면 입구 순서 z → x 가 앞선 것). 없으면 [].
func path_from_entrance(to: Array) -> Array:
	var best: Array = []
	for e: Array in _map.entrances():
		var p: Array = find_path(e, to)
		if not p.is_empty() and (best.is_empty() or p.size() < best.size()):
			best = p
	return best


func _reset_to_map() -> void:
	for z: int in _map.depth:
		for x: int in _map.width:
			_astar.set_point_solid(Vector2i(x, z), not _map.is_walkable(x, z))
