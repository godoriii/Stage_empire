class_name EconomyConfig
extends RefCounted
## economy.json 로더 (SE-012). 규칙: docs/gdd/economy.md#설정-로드와-공개-api (교차 검사 K1~K5).
## 스키마(economy.schema.json)로 못 하는 검사만 여기서 한다. 모든 필드는 읽기 전용으로 취급한다.
## JSON 숫자는 float 로 파싱되므로 정수값 float 는 int 로 정규화해서 보관한다(R1: 금액은 int).

const DEFAULT_PATH: String = "res://data/economy/economy.json"
## K3: 이 로더가 읽는 테이블 version 과 비율 분모(단위 정의, 스키마 enum 과 같은 값).
const SUPPORTED_VERSION: int = 1
const REQUIRED_RATE_SCALE: int = 10000
## K1: 새 게임 티어(economy.md#시작-자금 "tier = 1"). 이 티어의 행이 반드시 있어야 한다.
const START_TIER: int = 1
const ROW_ID_PREFIX: String = "tier_"
## guarantee(grade) 가 모르는 등급에 돌려주는 값. 지출로 보내면 C2(amount < 0)로 거절된다.
const GUARANTEE_UNKNOWN: int = -1
const CLASS_CAPITAL: String = "capital"
const CLASS_OPERATING: String = "operating"
## 장부(ledger) 키. 고정 3개(economy.md #상태 `ledger`, "회계 분류와 장부 키"). Economy 가 같은 이름을 쓴다.
const LEDGER_ADMISSIONS: String = "admissions"
const LEDGER_AUDIENCE: String = "audience"
const LEDGER_GUARANTEE: String = "guarantee"
## K5: charge_reasons 에서 "operating" 인 사유는 이 목록(ledger 키 이름)에 있어야 한다.
const LEDGER_KEYS: Array[String] = [LEDGER_ADMISSIONS, LEDGER_AUDIENCE, LEDGER_GUARANTEE]
const ROW_INT_FIELDS: Array[String] = [
	"tier", "rent_per_day", "tax_rate_bp", "ticket_price_default", "ticket_price_min", "ticket_price_max",
	"bar_purchase_rate_bp", "bar_avg_spend", "bar_cost_rate_bp", "bailout_loan_amount", "bailout_interest_bp",
	"bailout_repay_days",
]

var version: int = 0
var rate_scale: int = 0
var starting_cash: int = 0
var bailout_count: int = 0
var demolish_refund_rate_bp: int = 0
## 사유 → "capital" | "operating"
var charge_reasons: Dictionary = {}
## 기준 시나리오(정수값 float 는 int 로 정규화한 깊은 복사본). 테스트·qa 용.
var reference_scenarios: Array = []

var _rows: Dictionary = {}                 # tier(int) -> row Dictionary (정수 필드는 int)
var _guarantee_by_grade: Dictionary = {}   # grade -> int


## res://data/economy/economy.json 을 읽어 검증한다. 실패 시 push_error 후 null.
static func load(path: String = DEFAULT_PATH) -> EconomyConfig:
	if not FileAccess.file_exists(path):
		push_error("[EconomyConfig] 파일 없음: %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("[EconomyConfig] JSON 객체가 아님: %s" % path)
		return null
	return from_dict(parsed)


## 메모리 상 Dictionary(JSON 파싱 결과와 같은 모양)에서 만든다. 테스트의 변형 사본 검증용.
static func from_dict(d: Dictionary) -> EconomyConfig:
	var cfg: EconomyConfig = EconomyConfig.new()

	var ver: Variant = as_int(d.get("version"))
	if ver == null or ver != SUPPORTED_VERSION:
		return _fail("K3 version 은 %d 이어야 한다: %s" % [SUPPORTED_VERSION, d.get("version")])
	cfg.version = ver
	var scale: Variant = as_int(d.get("rate_scale"))
	if scale == null or scale != REQUIRED_RATE_SCALE:
		return _fail("K3 rate_scale 은 %d 이어야 한다: %s" % [REQUIRED_RATE_SCALE, d.get("rate_scale")])
	cfg.rate_scale = scale

	for key: String in ["starting_cash", "bailout_count", "demolish_refund_rate_bp"]:
		var v: Variant = as_int(d.get(key))
		if v == null or v < 0:
			return _fail("%s 는 0 이상 정수여야 한다" % key)
		cfg.set(key, v)

	var grades: Variant = d.get("guarantee_by_grade")
	if not (grades is Dictionary):
		return _fail("guarantee_by_grade 는 객체여야 한다")
	for g: Variant in grades:
		var amount: Variant = as_int(grades[g])
		if not (g is String) or amount == null or amount < 0:
			return _fail("guarantee_by_grade.%s 는 0 이상 정수여야 한다" % [g])
		cfg._guarantee_by_grade[g] = amount

	var reasons: Variant = d.get("charge_reasons")
	if not (reasons is Dictionary):
		return _fail("charge_reasons 는 객체여야 한다")
	for r: Variant in reasons:
		var cls: Variant = reasons[r]
		if not (r is String) or not (cls == CLASS_CAPITAL or cls == CLASS_OPERATING):
			return _fail("charge_reasons.%s 는 '%s' 또는 '%s' 여야 한다" % [r, CLASS_CAPITAL, CLASS_OPERATING])
		if cls == CLASS_OPERATING and not LEDGER_KEYS.has(r):
			return _fail("K5 charge_reasons.%s 가 '%s' 인데 ledger 키가 아니다(ledger: %s)" % [r, CLASS_OPERATING, LEDGER_KEYS])
		cfg.charge_reasons[r] = cls

	var rows: Variant = d.get("rows")
	if not (rows is Array) or (rows as Array).is_empty():
		return _fail("rows 는 비어 있지 않은 배열이어야 한다")
	for raw: Variant in rows:
		var row: Variant = _parse_row(raw)
		if row == null:
			return null
		var t: int = row["tier"]
		if row["id"] != ROW_ID_PREFIX + str(t):
			return _fail("K1 rows[].id '%s' 가 '%s%d' 가 아니다" % [row["id"], ROW_ID_PREFIX, t])
		if cfg._rows.has(t):
			return _fail("K1 tier %d 행이 중복이다" % t)
		if not (row["ticket_price_min"] <= row["ticket_price_default"] and row["ticket_price_default"] <= row["ticket_price_max"]):
			return _fail("K2 %s: ticket_price_min ≤ ticket_price_default ≤ ticket_price_max 가 아니다" % row["id"])
		cfg._rows[t] = row
	if not cfg._rows.has(START_TIER):
		return _fail("K1 tier %d 행이 없다" % START_TIER)

	var scenarios: Variant = d.get("reference_scenarios")
	if not (scenarios is Array):
		return _fail("reference_scenarios 는 배열이어야 한다")
	for sc: Variant in scenarios:
		if not (sc is Dictionary):
			return _fail("reference_scenarios[] 원소는 객체여야 한다")
		var grade: Variant = sc.get("guarantee_grade")
		if not (grade is String) or not cfg._guarantee_by_grade.has(grade):
			return _fail("K4 reference_scenarios '%s' 의 guarantee_grade '%s' 가 guarantee_by_grade 에 없다" % [sc.get("id"), grade])
		cfg.reference_scenarios.append(_int_deep(sc))
	return cfg


## tier 의 경제 행(복사본). 없는 티어면 push_error, {}.
func row(tier: int) -> Dictionary:
	if not _rows.has(tier):
		push_error("[EconomyConfig] row: tier %d 행이 없다" % tier)
		return {}
	return (_rows[tier] as Dictionary).duplicate(true)


## row() 를 부르기 전 존재 확인(오류 없음).
func has_row(tier: int) -> bool:
	return _rows.has(tier)


## v0 개런티 고정표. 없는 등급이면 push_error 후 GUARANTEE_UNKNOWN(-1).
func guarantee(grade: String) -> int:
	if not _guarantee_by_grade.has(grade):
		push_error("[EconomyConfig] guarantee: guarantee_by_grade 에 없는 등급 '%s'" % grade)
		return GUARANTEE_UNKNOWN
	return _guarantee_by_grade[grade]


## id 로 기준 시나리오(복사본). 없으면 {}.
func scenario(id: String) -> Dictionary:
	for sc: Dictionary in reference_scenarios:
		if sc.get("id") == id:
			return sc.duplicate(true)
	return {}


## int, 또는 정수값인 유한 float 만 int 로. 그 밖(bool·문자열·1.5·null)은 null.
static func as_int(v: Variant) -> Variant:
	if v is int:
		return v
	if v is float and is_finite(v) and v == floorf(v):
		return int(v)
	return null


static func _parse_row(raw: Variant) -> Variant:
	if not (raw is Dictionary):
		return _fail("rows[] 원소는 객체여야 한다")
	var id: Variant = raw.get("id")
	if not (id is String):
		return _fail("rows[].id 는 문자열이어야 한다")
	var out: Dictionary = {"id": id}
	for key: String in ROW_INT_FIELDS:
		var v: Variant = as_int(raw.get(key))
		if v == null or v < 0:
			return _fail("%s.%s 는 0 이상 정수여야 한다" % [id, key])
		out[key] = v
	return out


## 정수값 float → int (재귀). 그 밖의 값은 그대로.
static func _int_deep(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var n: Variant = as_int(v)
			return n if n != null else v
		TYPE_ARRAY:
			var arr: Array = []
			for e: Variant in v:
				arr.append(_int_deep(e))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k: Variant in v:
				d[k] = _int_deep(v[k])
			return d
	return v


static func _fail(msg: String) -> Variant:
	push_error("[EconomyConfig] " + msg)
	return null
