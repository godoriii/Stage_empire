class_name BuildConfig
extends RefCounted
## build 설정 (SE-032). furniture.json + 맵 + (읽기 전용) tiers.json·economy.json. 규칙: docs/gdd/build.md#설정-로드-검사,
## #공개-api. MK1~MK6 은 MapConfig, FC1~FC5 는 FurnitureConfig 가 하고 여기서는 FC5 의 reference_layouts 쪽(맵 ↔ 가구)과
## economy 값 읽기를 한다. 실패하면 push_error, null. FC6·FC7 은 로드 검사가 아니라 테스트(BC20)다.

const ECONOMY_PATH: String = "res://data/economy/economy.json"

var map: MapConfig
var furniture_table: FurnitureConfig
## economy.json 값(읽기 전용).
var rate_scale: int = 0
var demolish_refund_rate_bp: int = 0
var starting_cash: int = 0
## tiers.json 의 맵 티어 capacity_max (C4).
var capacity_max: int = 0


static func load(furniture_path: String = FurnitureConfig.DEFAULT_PATH, map_path: String = MapConfig.DEFAULT_PATH) -> BuildConfig:
	var f: Variant = JsonUtil.read_json(furniture_path, MapConfig.LOG_TAG)
	var m: Variant = JsonUtil.read_json(map_path, MapConfig.LOG_TAG)
	var t: Variant = JsonUtil.read_json(MapConfig.TIERS_PATH, MapConfig.LOG_TAG)
	var e: Variant = JsonUtil.read_json(ECONOMY_PATH, MapConfig.LOG_TAG)
	if f == null or m == null or t == null or e == null:
		return null
	return from_dicts(f, m, t, e)


static func from_dicts(furniture: Dictionary, map_d: Dictionary, tiers: Dictionary, economy: Dictionary) -> BuildConfig:
	var cfg: BuildConfig = BuildConfig.new()
	for key: String in ["rate_scale", "demolish_refund_rate_bp", "starting_cash"]:
		var v: Variant = JsonUtil.as_int(economy.get(key))
		if v == null or v < 0:
			return _fail("economy.json %s 는 0 이상 정수여야 한다" % key)
	cfg.rate_scale = JsonUtil.as_int(economy["rate_scale"])
	cfg.demolish_refund_rate_bp = JsonUtil.as_int(economy["demolish_refund_rate_bp"])
	cfg.starting_cash = JsonUtil.as_int(economy["starting_cash"])
	if cfg.rate_scale < 1:
		return _fail("economy.json rate_scale 은 1 이상이어야 한다")
	cfg.furniture_table = FurnitureConfig.from_dict(furniture, cfg.rate_scale, cfg.demolish_refund_rate_bp)
	if cfg.furniture_table == null:
		return null
	cfg.map = MapConfig.from_dict(map_d, tiers)
	if cfg.map == null:
		return null
	cfg.capacity_max = cfg.map.capacity_max
	for lid: Variant in cfg.map.layout_ids():                                                   # FC5 (layouts)
		for p: Dictionary in cfg.map.layout(lid)["placements"]:
			if not cfg.furniture_table.has_furniture(p["furniture_id"]):
				return _fail("FC5 reference_layouts '%s' 의 furniture_id '%s' 가 행에 없다" % [lid, p["furniture_id"]])
	return cfg


# --- 읽기 전용 조회(깊은 복사) ----------------------------------------------------

func furniture(fid: String) -> Dictionary:
	return furniture_table.furniture(fid)


func has_furniture(fid: String) -> bool:
	return furniture_table.has_furniture(fid)


## 맵 밖이면 {}.
func tile_kind(cell: Array) -> Dictionary:
	return map.tile_kind(cell)


func layout(layout_id: String) -> Dictionary:
	return map.layout(layout_id)


func reference_set(set_id: String) -> Dictionary:
	return furniture_table.reference_set(set_id)


# --- 순수 함수(G2·G3·시야 레이) ---------------------------------------------------

static func rotated_size(footprint: Array, rotation: int) -> Array:
	return GridOccupancy.rotated_size(footprint, rotation)


static func cells_of(footprint: Array, cell: Array, rotation: int) -> Array:
	return GridOccupancy.cells_of(footprint, cell, rotation)


static func line(a: Array, b: Array) -> Array:
	return Coverage.line(a, b)


static func _fail(msg: String) -> Variant:
	push_error("[BuildConfig] " + msg)
	return null
