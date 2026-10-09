class_name BuildPreset
extends RefCounted
## SE-037: 샌드박스 --se-build-preset=<id> 용 가짜 sim 출력(sim 이 없는 샌드박스에서 배치 UI 를 보이기 위한 고정 데이터).
## 이벤트 버스에 발행하지 않는다. 샌드박스가 FurnitureView.on_placed / CoverageOverlay.on_coverage_changed 에 직접 넣는다.
## SE-040(통합) 뒤에는 실제 build 시스템의 build.placed / build.coverage_changed 가 같은 자리에 들어온다.
##
## 프리셋:
##   empty    배치 UI 만(가구 0, 커버리지 없음).
##   baseline tier1_club.json reference_layouts[baseline_show](build.md 부록 A2)의 배치 6개 + 그 커버리지, 오버레이 음향.
## 커버리지 근사(이 파일 한 곳): 관람 타일 = standing 타일 중 비점유 + 무대 앞 반평면(도달 집합 BFS 생략 — 기준 배치는
##   갇힌 타일이 없어 같다), 음향·바 = 커버리지 거리식(UI 계약 "설비 반경 미리보기"와 같은 식),
##   시야 = 관람 타일 − 레이아웃 expected.sight_blocked_cells(시야 레이는 sim 규칙이라 복제하지 않고 데이터 기대값을 쓴다).
##   스칼라 필드(…_bp, capacity 등)는 레이아웃 expected 값을 그대로 옮긴다. 테스트가 타일 수를 expected 와 대조한다.

const ARG: String = "--se-build-preset="
const NONE: String = ""
const EMPTY: String = "empty"
const BASELINE: String = "baseline"
const IDS: PackedStringArray = ["empty", "baseline"]
## baseline 프리셋이 쓰는 맵 reference_layouts id.
const BASELINE_LAYOUT_ID: String = "baseline_show"
## baseline 프리셋의 시작 오버레이 모드(CoverageOverlay.MODES).
const BASELINE_OVERLAY_MODE: String = "sound"
## expected 에서 페이로드로 그대로 옮기는 스칼라 키(build.coverage_changed 필드 이름과 같은 것만).
const SCALAR_KEYS: PackedStringArray = [
	"has_stage", "floor_free", "viewing_count", "sound_bp", "sight_bp", "bar_bp", "capacity",
	"evac_capacity", "evac_shortfall", "light_grade", "satisfaction_bonus_bp", "upkeep_per_day",
]


## 명령줄에서 프리셋 id. 인자가 없으면 NONE(""). 유효성은 is_valid_id 로.
static func resolve(user_args: PackedStringArray) -> String:
	for a: String in user_args:
		if a.begins_with(ARG):
			return a.trim_prefix(ARG).strip_edges().to_lower()
	return NONE


static func is_valid_id(id: String) -> bool:
	return IDS.has(id)


## 레이아웃 배치를 build.placed 페이로드 열로(entity f1.. 순서, cells G6, cost = build_cost).
static func placed_payloads(catalog: BuildCatalog, layout_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var layout: Dictionary = catalog.reference_layout(layout_id)
	var n: int = 1
	for p: Variant in layout.get("placements", []):
		var pd: Dictionary = p as Dictionary
		var fid: String = str(pd.get("furniture_id", ""))
		var row: Dictionary = catalog.furniture(fid)
		var cell: Vector2i = BuildCatalog.to_cell(pd.get("cell"))
		var rot: int = int(pd.get("rotation", 0))
		var cells: Array = []
		for c: Vector2i in BuildCatalog.cells_of(BuildCatalog.footprint_of(row), cell, rot):
			cells.append(BuildCatalog.to_pair(c))
		out.append({
			"entity_id": "f%d" % n, "furniture_id": fid, "cell": BuildCatalog.to_pair(cell), "rotation": rot,
			"cells": cells, "cost": int(row.get("build_cost", 0)),
		})
		n += 1
	return out


## 배치 열의 build.coverage_changed 근사 페이로드(위 설명). layout_id 가 있으면 시야 차단 셀·스칼라를 그 expected 에서.
static func coverage_payload(catalog: BuildCatalog, placed: Array[Dictionary], layout_id: String = "") -> Dictionary:
	var occupied: Dictionary = {}
	var stage: Dictionary = {}
	var sources: Array[Dictionary] = []   # {min, max, effects}
	for p: Dictionary in placed:
		var row: Dictionary = catalog.furniture(str(p["furniture_id"]))
		var cells: Array[Vector2i] = []
		for pair: Variant in p["cells"]:
			cells.append(BuildCatalog.to_cell(pair))
			occupied[BuildCatalog.to_cell(pair)] = true
		sources.append({"min": cells[0], "max": cells[cells.size() - 1], "effects": row.get("effects", {})})
		if str(row.get("category", "")) == "stage":
			stage = {"fp": BuildCatalog.footprint_of(row), "cell": BuildCatalog.to_cell(p["cell"]), "rotation": int(p["rotation"])}
	var expected: Dictionary = catalog.reference_layout(layout_id).get("expected", {}) as Dictionary
	var blocked: Dictionary = {}
	for pair: Variant in expected.get("sight_blocked_cells", []):
		blocked[BuildCatalog.to_cell(pair)] = true
	var viewing: Array = []
	var sound: Array = []
	var sight: Array = []
	var bar: Array = []
	var size: Vector2i = catalog.get_map_size()
	if not stage.is_empty():
		for z: int in range(size.y):
			for x: int in range(size.x):
				var t: Vector2i = Vector2i(x, z)
				if occupied.has(t) or not bool(catalog.tile_kind(t).get("standing", false)):
					continue
				if not BuildCatalog.in_front_half_plane(stage["fp"], stage["cell"], stage["rotation"], t):
					continue
				viewing.append(BuildCatalog.to_pair(t))
				if _covered(sources, t, "sound_radius"):
					sound.append(BuildCatalog.to_pair(t))
				if _covered(sources, t, "bar_service_radius"):
					bar.append(BuildCatalog.to_pair(t))
				if not blocked.has(t):
					sight.append(BuildCatalog.to_pair(t))
	var out: Dictionary = {
		"cause": "placed", "has_stage": not stage.is_empty(), "viewing_count": viewing.size(),
		"viewing_tiles": viewing, "sound_tiles": sound, "sight_tiles": sight, "bar_tiles": bar,
	}
	for k: String in SCALAR_KEYS:
		if expected.has(k) and not out.has(k):
			out[k] = expected[k]
	return out


static func _covered(sources: Array[Dictionary], t: Vector2i, field: String) -> bool:
	for s: Dictionary in sources:
		if BuildCatalog.radius_covers(s["min"], s["max"], t, int((s["effects"] as Dictionary).get(field, 0))):
			return true
	return false
