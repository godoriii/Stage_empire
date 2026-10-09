class_name GridDataLoader
extends RefCounted
## 그리드 크기·타일 크기를 데이터 테이블에서 읽는다(읽기 전용).
## TODO(SE-001 병합 후 교체): sim 의 데이터 로더/그리드 상태를 구독하는 방식으로 바꾼다.
## 지금은 sim 로더가 없어서 view 에서 FileAccess(READ)로 직접 읽는다. 쓰기는 하지 않는다.

const TIERS_PATH: String = "res://data/tiers/tiers.json"
const SIM_PATH: String = "res://data/sim/sim.json"


## tiers.json 의 rows 중 id == tier_id 인 행의 grid_size. 못 찾으면 push_error 후 0.
static func load_grid_size(tier_id: String) -> int:
	var root: Variant = _read_json(TIERS_PATH)
	if not (root is Dictionary) or not (root as Dictionary).has("rows"):
		push_error("GridDataLoader: %s 형식 오류" % TIERS_PATH)
		return 0
	for row: Variant in (root as Dictionary)["rows"]:
		if row is Dictionary and str((row as Dictionary).get("id", "")) == tier_id:
			return int((row as Dictionary)["grid_size"])
	push_error("GridDataLoader: %s 에 %s 없음" % [TIERS_PATH, tier_id])
	return 0


## sim.json 의 tile_size_m. 못 찾으면 push_error 후 0.
static func load_tile_size_m() -> float:
	var root: Variant = _read_json(SIM_PATH)
	if not (root is Dictionary) or not (root as Dictionary).has("tile_size_m"):
		push_error("GridDataLoader: %s 에 tile_size_m 없음" % SIM_PATH)
		return 0.0
	return float((root as Dictionary)["tile_size_m"])


## 티어 id 로 IsoGridMath 를 만든다. 정사각 그리드(grid_size × grid_size).
static func load_grid_math(tier_id: String) -> IsoGridMath:
	var n: int = load_grid_size(tier_id)
	return IsoGridMath.new(Vector2i(n, n), load_tile_size_m())


static func _read_json(path: String) -> Variant:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("GridDataLoader: %s 를 열 수 없다 (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	return JSON.parse_string(f.get_as_text())
