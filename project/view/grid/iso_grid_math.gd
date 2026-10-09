class_name IsoGridMath
extends RefCounted
## 그리드 좌표 수학. Node/Scene 에 의존하지 않는 순수 클래스라 헤드리스 테스트가 가능하다.
## 규약: 그리드 원점은 월드 (0, 0, 0), 타일 (x, z) 는 월드 [x*t, (x+1)*t) × [z*t, (z+1)*t) 를 차지한다(t = 타일 크기 m).
## 타일 "위치"는 바닥 중심(style-guide: 피벗은 바닥 중심, y=0).

## 레이가 지면과 만나지 않을 때 돌려주는 값.
const INVALID_TILE: Vector2i = Vector2i(-2147483648, -2147483648)

var grid_size: Vector2i
var tile_size_m: float


func _init(size_tiles: Vector2i, tile_m: float) -> void:
	grid_size = size_tiles
	tile_size_m = tile_m


## 그리드 전체 크기(m). x, z.
func get_extent_m() -> Vector2:
	return Vector2(grid_size) * tile_size_m


## 월드 좌표 → 타일 좌표(그리드 밖일 수 있음. is_inside 로 확인).
func world_to_tile(world: Vector3) -> Vector2i:
	return Vector2i(floori(world.x / tile_size_m), floori(world.z / tile_size_m))


## 타일 좌표 → 타일 바닥 중심 월드 좌표(y = 0).
func tile_to_world(tile: Vector2i) -> Vector3:
	return Vector3((float(tile.x) + 0.5) * tile_size_m, 0.0, (float(tile.y) + 0.5) * tile_size_m)


func is_inside(tile: Vector2i) -> bool:
	return tile.x >= 0 and tile.y >= 0 and tile.x < grid_size.x and tile.y < grid_size.y


func is_world_inside(world: Vector3) -> bool:
	return is_inside(world_to_tile(world))


## 레이와 지면(y = 0) 의 교점. 레이가 평면과 평행하거나 평면이 뒤에 있으면 null.
static func ray_to_ground(origin: Vector3, direction: Vector3) -> Variant:
	if is_zero_approx(direction.y):
		return null
	var t: float = -origin.y / direction.y
	if t < 0.0:
		return null
	return origin + direction * t


## 레이 → 타일. 지면과 만나지 않으면 INVALID_TILE.
func ray_to_tile(origin: Vector3, direction: Vector3) -> Vector2i:
	var hit: Variant = ray_to_ground(origin, direction)
	if hit == null:
		return INVALID_TILE
	return world_to_tile(hit as Vector3)
