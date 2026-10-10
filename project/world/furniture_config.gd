class_name FurnitureConfig
extends RefCounted
## 가구 테이블 로더 (SE-032). project/data/furniture/furniture.json. 규칙: docs/gdd/build.md#가구-카테고리와-필드,
## #설정-로드-검사 FC1~FC5(FC5 의 reference_layouts 쪽은 맵이 필요해 BuildConfig 가 한다).
## 실패하면 push_error 1회, null. 정수값 float 는 int 로 정규화해서 보관한다. 모든 필드는 읽기 전용으로 취급한다.

const DEFAULT_PATH: String = "res://data/furniture/furniture.json"
const SUPPORTED_VERSION: int = 1
## 규칙이 id 로 참조하는 카테고리(C0 무대 S, B10 (b)).
const CATEGORY_STAGE: String = "stage"
const EFFECT_INT_FIELDS: Array[String] = [
	"sound_radius", "bar_service_radius", "capacity_add", "evac_capacity", "satisfaction_bonus_bp", "light_grade",
]
const EFFECT_SIGHT_BLOCK: String = "sight_block"
## FC4 model 경로 규약.
const MODEL_PREFIX: String = "res://assets/models/"
const MODEL_SUFFIX: String = ".glb"

var version: int = 0
var allowed_phases: Array[String] = []
var allowed_rotations: Array[int] = []
## category -> int
var category_max_count: Dictionary = {}
var satisfaction_bonus_cap_bp: int = 0

var _rows: Array = []        # 행(정규화), 파일 순서
var _by_id: Dictionary = {}  # id -> _rows 인덱스
var _sets: Array = []        # reference_sets (정수 정규화)


## rate_scale·refund_bp 는 economy.json 값(FC2).
static func from_dict(d: Dictionary, rate_scale: int, refund_bp: int) -> FurnitureConfig:
	var f: FurnitureConfig = FurnitureConfig.new()
	var ver: Variant = JsonUtil.as_int(d.get("version"))
	if ver == null or ver != SUPPORTED_VERSION:
		return _fail("version 은 %d 이어야 한다: %s" % [SUPPORTED_VERSION, d.get("version")])
	f.version = ver

	var rules: Variant = d.get("build_rules")
	if not (rules is Dictionary):
		return _fail("build_rules 는 객체여야 한다")
	var phases: Variant = rules.get("allowed_phases")
	if not (phases is Array):
		return _fail("build_rules.allowed_phases 는 배열이어야 한다")
	for p: Variant in phases:
		if not (p is String) or not SimConfig.PHASE_IDS.has(p):
			return _fail("build_rules.allowed_phases 의 '%s' 는 구간 id 가 아니다(%s)" % [p, SimConfig.PHASE_IDS])
		f.allowed_phases.append(p)
	var rots: Variant = rules.get("allowed_rotations")
	if not (rots is Array):
		return _fail("build_rules.allowed_rotations 는 배열이어야 한다")
	for r: Variant in rots:
		var ri: Variant = JsonUtil.as_int(r)
		if ri == null or not GridOccupancy.KNOWN_ROTATIONS.has(ri):
			return _fail("FC3 allowed_rotations 의 %s 는 방향표 회전(%s)이 아니다" % [r, GridOccupancy.KNOWN_ROTATIONS])
		f.allowed_rotations.append(ri)
	if not f.allowed_rotations.has(GridOccupancy.ROT_0):
		return _fail("FC3 allowed_rotations 가 0 을 포함하지 않는다")
	var cmc: Variant = rules.get("category_max_count", {})
	if not (cmc is Dictionary):
		return _fail("build_rules.category_max_count 는 객체여야 한다")
	for c: Variant in cmc:
		var n: Variant = JsonUtil.as_int(cmc[c])
		if not (c is String) or n == null or n < 0:
			return _fail("category_max_count.%s 는 0 이상 정수여야 한다" % [c])
		f.category_max_count[c] = n
	var cap: Variant = JsonUtil.as_int(rules.get("satisfaction_bonus_cap_bp"))
	if cap == null or cap < 0:
		return _fail("build_rules.satisfaction_bonus_cap_bp 는 0 이상 정수여야 한다")
	f.satisfaction_bonus_cap_bp = cap

	var rows: Variant = d.get("rows")
	if not (rows is Array) or (rows as Array).is_empty():
		return _fail("rows 는 비어 있지 않은 배열이어야 한다")
	for raw: Variant in rows:
		var row: Variant = _parse_row(raw)
		if row == null:
			return null
		var rid: String = row["id"]
		if f._by_id.has(rid):                                                               # FC1
			return _fail("FC1 행 id 중복: %s" % rid)
		var kept: int = int(row["build_cost"]) * (rate_scale - refund_bp) / rate_scale      # FC2
		if not (kept > int(row["upkeep_per_day"])):
			return _fail("FC2 %s: ⌊build_cost × (rate_scale − refund) ÷ rate_scale⌋ = %d 가 upkeep_per_day %d 보다 크지 않다" % [rid, kept, row["upkeep_per_day"]])
		f._by_id[rid] = f._rows.size()
		f._rows.append(row)

	var sets: Variant = d.get("reference_sets", [])
	if not (sets is Array):
		return _fail("reference_sets 는 배열이어야 한다")
	for s: Variant in sets:
		if not (s is Dictionary) or not (s.get("id") is String) or not (s.get("items") is Array):
			return _fail("reference_sets[] 는 id·items 가 있는 객체여야 한다")
		for it: Variant in s["items"]:
			if not (it is Dictionary) or not f._by_id.has(it.get("furniture_id")):                    # FC5
				return _fail("FC5 reference_sets '%s' 의 furniture_id '%s' 가 행에 없다" % [s["id"], (it as Dictionary).get("furniture_id") if it is Dictionary else it])
		f._sets.append(JsonUtil.int_deep(s))
	return f


func has_furniture(fid: String) -> bool:
	return _by_id.has(fid)


## 행 사본. 없으면 {}.
func furniture(fid: String) -> Dictionary:
	if not _by_id.has(fid):
		return {}
	return (_rows[_by_id[fid]] as Dictionary).duplicate(true)


## 내부 조회용 참조(복사 없음). 호출자는 바꾸지 않는다. 없으면 {}.
func row_ref(fid: String) -> Dictionary:
	if not _by_id.has(fid):
		return {}
	return _rows[_by_id[fid]]


## 행 id 목록(파일 순서).
func ids() -> Array:
	var out: Array = []
	for r: Dictionary in _rows:
		out.append(r["id"])
	return out


func reference_set(set_id: String) -> Dictionary:
	for s: Dictionary in _sets:
		if s["id"] == set_id:
			return s.duplicate(true)
	return {}


func reference_set_ids() -> Array:
	var out: Array = []
	for s: Dictionary in _sets:
		out.append(s["id"])
	return out


static func _parse_row(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return _fail("rows[] 원소는 객체여야 한다")
	var rid: Variant = raw.get("id")
	if not (rid is String) or (rid as String).is_empty():
		return _fail("rows[].id 는 비어 있지 않은 문자열이어야 한다")
	var cat: Variant = raw.get("category")
	if not (cat is String) or (cat as String).is_empty():
		return _fail("%s.category 는 문자열이어야 한다" % rid)
	var fp: Variant = JsonUtil.as_int_pair(raw.get("footprint"))
	if fp == null or fp[0] < 1 or fp[1] < 1:
		return _fail("%s.footprint 는 1 이상 정수 [w, d] 여야 한다" % rid)
	var cost: Variant = JsonUtil.as_int(raw.get("build_cost"))
	if cost == null or cost < 1:
		return _fail("%s.build_cost 는 1 이상 정수여야 한다" % rid)
	var upkeep: Variant = JsonUtil.as_int(raw.get("upkeep_per_day"))
	if upkeep == null or upkeep < 0:
		return _fail("%s.upkeep_per_day 는 0 이상 정수여야 한다" % rid)
	for b: String in ["rotatable", "wall_required"]:
		if not (raw.get(b) is bool):
			return _fail("%s.%s 는 bool 이어야 한다" % [rid, b])
	var eff: Variant = raw.get("effects")
	if not (eff is Dictionary):
		return _fail("%s.effects 는 객체여야 한다" % rid)
	var effects: Dictionary = {}
	for k: String in EFFECT_INT_FIELDS:
		var v: Variant = JsonUtil.as_int(eff.get(k))
		if v == null or v < 0:
			return _fail("%s.effects.%s 는 0 이상 정수여야 한다" % [rid, k])
		effects[k] = v
	if not (eff.get(EFFECT_SIGHT_BLOCK) is bool):
		return _fail("%s.effects.%s 는 bool 이어야 한다" % [rid, EFFECT_SIGHT_BLOCK])
	effects[EFFECT_SIGHT_BLOCK] = eff[EFFECT_SIGHT_BLOCK]
	var model: Variant = raw.get("model", "")
	if not (model is String):
		return _fail("%s.model 은 문자열이어야 한다" % rid)
	if not (model as String).is_empty() and model != MODEL_PREFIX + rid + MODEL_SUFFIX:          # FC4
		return _fail("FC4 %s.model '%s' 가 '%s' 가 아니다" % [rid, model, MODEL_PREFIX + rid + MODEL_SUFFIX])
	var out: Dictionary = JsonUtil.int_deep(raw)
	out["footprint"] = fp
	out["build_cost"] = cost
	out["upkeep_per_day"] = upkeep
	out["effects"] = effects
	return out


static func _fail(msg: String) -> Variant:
	push_error("[FurnitureConfig] " + msg)
	return null
