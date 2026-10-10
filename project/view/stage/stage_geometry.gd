class_name StageGeometry
extends RefCounted
## SE-038: 무대 가구의 표시용 기하(build.md 회전 방향표). CrowdView(관람 방향)·StageLights(스포트 위치)가 같이 쓴다.
## 판정이 아니라 렌더 위치 계산이다. 점유 사각형·회전은 BuildCatalog(G2~G6)과 같은 규칙을 쓴다.
## 무대 판별: furniture.json 행의 category 가 STAGE_CATEGORY(build.md "무대 stage", 맵당 1개).

const STAGE_CATEGORY: String = "stage"


## 무대 한 개의 위치 정보. 없으면 빈 사전.
## {entity_id: String, footprint: Vector2i, cell: Vector2i, rotation: int}
static func from_placed(catalog: BuildCatalog, payload: Dictionary) -> Dictionary:
	if catalog == null:
		return {}
	var fid: String = str(payload.get("furniture_id", ""))
	var row: Dictionary = catalog.furniture(fid)
	if str(row.get("category", "")) != STAGE_CATEGORY:
		return {}
	var cell: Vector2i = BuildCatalog.to_cell(payload.get("cell"))
	if cell == IsoGridMath.INVALID_TILE:
		return {}
	return {
		"entity_id": str(payload.get("entity_id", "")), "footprint": BuildCatalog.footprint_of(row),
		"cell": cell, "rotation": int(payload.get("rotation", 0)),
	}


## build.md C0 초점 셀 g: 정면 가장자리 셀을 방향표 정렬 기준으로 나열한 E 에서 E[⌊n/2⌋].
static func focus_cell(footprint: Vector2i, cell: Vector2i, rotation: int) -> Vector2i:
	var edge: Array[Vector2i] = front_edge_cells(footprint, cell, rotation)
	if edge.is_empty():
		return IsoGridMath.INVALID_TILE
	return edge[edge.size() / 2]


## 회전 방향표 "초점 셀 후보(정면 가장자리, 정렬 기준)".
static func front_edge_cells(footprint: Vector2i, cell: Vector2i, rotation: int) -> Array[Vector2i]:
	var size: Vector2i = BuildCatalog.rotated_size(footprint, rotation)
	var x0: int = cell.x
	var z0: int = cell.y
	var x1: int = cell.x + size.x - 1
	var z1: int = cell.y + size.y - 1
	var out: Array[Vector2i] = []
	match posmod(rotation, 360):
		0:
			for x: int in range(x0, x1 + 1):
				out.append(Vector2i(x, z0))
		90:
			for z: int in range(z0, z1 + 1):
				out.append(Vector2i(x0, z))
		180:
			for x: int in range(x0, x1 + 1):
				out.append(Vector2i(x, z1))
		270:
			for z: int in range(z0, z1 + 1):
				out.append(Vector2i(x1, z))
	return out


## 정면 방향(월드 단위 벡터). 회전 0 → −z, 90 → −x, 180 → +z, 270 → +x (build.md G4·방향표).
static func front_dir(rotation: int) -> Vector3:
	match posmod(rotation, 360):
		90:
			return Vector3.LEFT
		180:
			return Vector3.BACK
		270:
			return Vector3.RIGHT
	return Vector3.FORWARD


## 셀 중앙의 월드 위치(바닥).
static func cell_center_world(c: Vector2i, tile_m: float) -> Vector3:
	return Vector3((float(c.x) + 0.5) * tile_m, 0.0, (float(c.y) + 0.5) * tile_m)


## 모델 정면(−z, GLTF_SPEC §1)이 dir 을 보게 하는 y 축 회전(라디안). dir 이 0 이면 0.
static func yaw_facing(dir: Vector3) -> float:
	if is_zero_approx(dir.x) and is_zero_approx(dir.z):
		return 0.0
	return atan2(-dir.x, -dir.z)
