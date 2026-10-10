class_name Coverage
extends RefCounted
## 커버리지 계산 (SE-032). 규칙: docs/gdd/build.md#커버리지 C0~C8, 시야 레이 line().
## 전부 정적 순수 함수다: 같은 입력 → 같은 출력, 입력을 바꾸지 않고 이벤트·난수 없음. 전체 재계산(증분 없음).
## 출력 타일 배열은 G6 순서(z 오름차순 → x 오름차순), 좌표는 [x, z] int. `blocked_cells`(SE-044)는 C0 의 점유 셀 전체다.

## 브레젠험 오차 배수(build.md 의사코드 `e2 = 2 * err`).
const BRESENHAM_ERR_SCALE: int = 2

## coverage_changed 페이로드 키 순서(cause 제외). build.md #이벤트-페이로드.
const KEYS: Array[String] = [
	"has_stage", "floor_free", "viewing_count", "viewing_tiles", "sound_tiles", "sight_tiles", "bar_tiles",
	"sound_bp", "sight_bp", "bar_bp", "capacity", "evac_capacity", "evac_shortfall", "light_grade",
	"satisfaction_bonus_bp", "upkeep_per_day", "blocked_cells",
]


## instances: [{furniture_id, cell: [x, z], rotation, …}, …] (설치 순). 반환 = coverage_changed 페이로드에서 cause 를 뺀 것.
static func compute(map: MapConfig, furniture: FurnitureConfig, rate_scale: int, instances: Array) -> Dictionary:
	# 점유·사각형
	var rects: Array[Rect2i] = []
	var rows: Array = []
	var blocked: Dictionary = {}
	var stage_index: int = -1
	for i: int in instances.size():
		var inst: Dictionary = instances[i]
		var row: Dictionary = furniture.row_ref(inst["furniture_id"])
		var r: Rect2i = GridOccupancy.rect_of(row["footprint"], inst["cell"], int(inst["rotation"]))
		rects.append(r)
		rows.append(row)
		for c: Array in GridOccupancy.rect_cells(r):
			blocked[Vector2i(c[0], c[1])] = true
		if stage_index < 0 and row["category"] == FurnitureConfig.CATEGORY_STAGE:
			stage_index = i

	# C0
	var reach: Dictionary = map.reachable(blocked)
	var floor_free: int = 0
	var viewing: Array = []
	var has_stage: bool = stage_index >= 0
	var stage_rect: Rect2i = rects[stage_index] if has_stage else Rect2i()
	var stage_rot: int = int(instances[stage_index]["rotation"]) if has_stage else 0
	for z: int in map.depth:
		for x: int in map.width:
			if not reach.has(Vector2i(x, z)) or not map.is_standing(x, z):
				continue
			floor_free += 1
			if has_stage and GridOccupancy.in_front(stage_rect, stage_rot, x, z):
				viewing.append([x, z])

	# 차단 셀(C2): blocks_sight 타일 + sight_block 가구 셀(무대 S 제외)
	var sight_blockers: Dictionary = {}
	for i: int in instances.size():
		if i == stage_index or not rows[i]["effects"][FurnitureConfig.EFFECT_SIGHT_BLOCK]:
			continue
		for c: Array in GridOccupancy.rect_cells(rects[i]):
			sight_blockers[Vector2i(c[0], c[1])] = true
	var focal: Array = GridOccupancy.focal_cell(stage_rect, stage_rot) if has_stage else []

	# C1·C2·C3
	var sound: Array = []
	var sight: Array = []
	var bar: Array = []
	for t: Array in viewing:
		var x: int = t[0]
		var z: int = t[1]
		if _covered(rects, rows, "sound_radius", x, z):
			sound.append(t)
		if _covered(rects, rows, "bar_service_radius", x, z):
			bar.append(t)
		if _clear_sight(map, sight_blockers, t, focal):
			sight.append(t)

	# C4~C8
	var cap_add: int = 0
	var evac_add: int = 0
	var light: int = 0
	var sat: int = 0
	var upkeep: int = 0
	for row: Dictionary in rows:
		var e: Dictionary = row["effects"]
		cap_add += int(e["capacity_add"])
		evac_add += int(e["evac_capacity"])
		light += int(e["light_grade"])
		sat += int(e["satisfaction_bonus_bp"])
		upkeep += int(row["upkeep_per_day"])
	var capacity: int = mini(map.capacity_max, floor_free * map.persons_per_tile_bp / rate_scale + cap_add)
	var evac: int = map.evac_total + evac_add
	var vc: int = viewing.size()
	return {
		"has_stage": has_stage,
		"floor_free": floor_free,
		"viewing_count": vc,
		"viewing_tiles": viewing,
		"sound_tiles": sound,
		"sight_tiles": sight,
		"bar_tiles": bar,
		"sound_bp": ratio_bp(sound.size(), vc, rate_scale),
		"sight_bp": ratio_bp(sight.size(), vc, rate_scale),
		"bar_bp": ratio_bp(bar.size(), vc, rate_scale),
		"capacity": capacity,
		"evac_capacity": evac,
		"evac_shortfall": maxi(0, capacity - evac),
		"light_grade": light,
		"satisfaction_bonus_bp": mini(furniture.satisfaction_bonus_cap_bp, sat),
		"upkeep_per_day": upkeep,
		"blocked_cells": blocked_cells(blocked),
	}


## 점유 셀 집합 {Vector2i: true} → G6 순서(z → x 오름차순) [[x, z], …] (build.md C0 `blocked_cells`, SE-044). 빈 집합이면 [].
static func blocked_cells(blocked: Dictionary) -> Array:
	var cells: Array[Vector2i] = []
	for c: Vector2i in blocked:
		cells.append(c)
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	var out: Array = []
	for c: Vector2i in cells:
		out.append([c.x, c.y])
	return out


## ⌊count × rate_scale ÷ total⌋, total == 0 이면 0.
static func ratio_bp(count: int, total: int, rate_scale: int) -> int:
	if total == 0:
		return 0
	return count * rate_scale / total


## 시야 레이 line(a, b): a 와 b 를 포함한 셀 목록. build.md 의사코드와 비트 단위로 같다(a → b 방향).
static func line(a: Array, b: Array) -> Array:
	var x0: int = int(a[0])
	var z0: int = int(a[1])
	var x1: int = int(b[0])
	var z1: int = int(b[1])
	var dx: int = absi(x1 - x0)
	var sx: int = 1 if x0 < x1 else -1
	var dz: int = -absi(z1 - z0)
	var sz: int = 1 if z0 < z1 else -1
	var err: int = dx + dz
	var x: int = x0
	var z: int = z0
	var out: Array = []
	while true:
		out.append([x, z])
		if x == x1 and z == z1:
			break
		var e2: int = BRESENHAM_ERR_SCALE * err
		if e2 >= dz:
			err += dz
			x += sx
		if e2 <= dx:
			err += dx
			z += sz
	return out


## 반경 효과(C1·C3): r > 0 이고 d² ≤ r² 인 인스턴스가 하나라도 있으면 덮인다.
static func _covered(rects: Array[Rect2i], rows: Array, field: String, x: int, z: int) -> bool:
	for i: int in rects.size():
		var r: int = int(rows[i]["effects"][field])
		if r > 0 and GridOccupancy.dist2(rects[i], x, z) <= r * r:
			return true
	return false


## C2: line(t, g) 의 처음·끝을 뺀 셀 중 차단 셀이 없으면 true.
static func _clear_sight(map: MapConfig, blockers: Dictionary, t: Array, g: Array) -> bool:
	var cells: Array = line(t, g)
	for i: int in range(1, cells.size() - 1):
		var c: Array = cells[i]
		if map.blocks_sight(c[0], c[1]) or blockers.has(Vector2i(c[0], c[1])):
			return false
	return true
