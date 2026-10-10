class_name UiData
extends RefCounted
## SE-039: UI 가 표시·활성 판단에 쓰는 데이터 값(JSON 읽기 전용). 수치 리터럴을 UI 코드에 두지 않기 위한 한 곳.
## sim.json(구간별 speeds), artist.json(booking_phases·mvp_genres), economy.json(티켓 가격 범위·시작 현금),
## show.json(grades[].name), tiers.json(해금 조건), genres.json(name). res://sim·core·world 를 로드하지 않는다.

const SIM_PATH: String = "res://data/sim/sim.json"
const ARTIST_PATH: String = "res://data/artist/artist.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const SHOW_PATH: String = "res://data/show/show.json"
const TIERS_PATH: String = "res://data/tiers/tiers.json"
const GENRES_PATH: String = "res://data/genres/genres.json"

## 구간 id(sim.json 순서)와 구간 id → speeds(Array[int]).
var phase_ids: PackedStringArray = PackedStringArray()
var phase_speeds: Dictionary = {}
## 구간 id → default_speed(sim.json).
var phase_default_speed: Dictionary = {}
## 모든 구간 speeds 의 합집합(오름차순) = HUD 배속 버튼.
var all_speeds: Array[int] = []
var booking_phases: PackedStringArray = PackedStringArray()
var mvp_genres: PackedStringArray = PackedStringArray()
## 현재 티어(MVP 는 티어 전환 없음 → tiers.json 최소 tier)와 그 economy 행 값.
var current_tier: int = 0
var ticket_price_min: int = 0
var ticket_price_max: int = 0
var ticket_price_default: int = 0
var starting_cash: int = 0
## 공연 등급 id → 표시 이름(show.json grades[].name).
var grade_names: Dictionary = {}
## tier 오름차순 행(tiers.json).
var tiers: Array[Dictionary] = []
## 장르 id → 이름(genres.json).
var genre_names: Dictionary = {}


static func read_json(path: String, optional: bool = false) -> Variant:
	if not FileAccess.file_exists(path):
		if not optional:
			push_error("UiData: missing %s" % path)
		return null
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("UiData: cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return null
	return JSON.parse_string(f.get_as_text())


static func load_default() -> UiData:
	return from_dicts(read_json(SIM_PATH), read_json(ARTIST_PATH), read_json(ECONOMY_PATH),
		read_json(SHOW_PATH), read_json(TIERS_PATH), read_json(GENRES_PATH))


static func from_dicts(sim: Variant, artist: Variant, economy: Variant, show: Variant, tiers_d: Variant, genres: Variant) -> UiData:
	var d: UiData = UiData.new()
	var union: Dictionary = {}
	for ph: Dictionary in _rows(sim, "phases"):
		var id: String = str(ph.get("id", ""))
		var speeds: Array[int] = []
		for s: Variant in ph.get("speeds", []):
			speeds.append(int(s))
			union[int(s)] = true
		d.phase_ids.append(id)
		d.phase_speeds[id] = speeds
		d.phase_default_speed[id] = int(ph.get("default_speed", 0))
	for s: Variant in union:
		d.all_speeds.append(int(s))
	d.all_speeds.sort()
	if artist is Dictionary:
		for p: Variant in (artist as Dictionary).get("booking_phases", []):
			d.booking_phases.append(str(p))
		for g: Variant in (artist as Dictionary).get("mvp_genres", []):
			d.mvp_genres.append(str(g))
	for row: Dictionary in _rows(tiers_d, "rows"):
		d.tiers.append(row)
	d.tiers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("tier", 0)) < int(b.get("tier", 0)))
	if not d.tiers.is_empty():
		d.current_tier = int(d.tiers[0].get("tier", 0))
	if economy is Dictionary:
		d.starting_cash = int((economy as Dictionary).get("starting_cash", 0))
	for row: Dictionary in _rows(economy, "rows"):
		if int(row.get("tier", -1)) == d.current_tier:
			d.ticket_price_min = int(row.get("ticket_price_min", 0))
			d.ticket_price_max = int(row.get("ticket_price_max", 0))
			d.ticket_price_default = int(row.get("ticket_price_default", 0))
	for g: Dictionary in _rows(show, "grades"):
		d.grade_names[str(g.get("id", ""))] = str(g.get("name", ""))
	for g: Dictionary in _rows(genres, "rows"):
		d.genre_names[str(g.get("id", ""))] = str(g.get("name", ""))
	return d


## 구간에서 허용된 배속인가(sim.json speeds).
func speed_allowed(phase: String, speed: int) -> bool:
	return (phase_speeds.get(phase, []) as Array).has(speed)


func genre_name(id: String) -> String:
	return str(genre_names.get(id, id))


func grade_name(id: String) -> String:
	return str(grade_names.get(id, id))


## tier 다음 행(해금 진행도 R12). 없으면 {}.
func next_tier_row(tier: int) -> Dictionary:
	for row: Dictionary in tiers:
		if int(row.get("tier", 0)) > tier:
			return row
	return {}


static func _rows(d: Variant, key: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if d is Dictionary and (d as Dictionary).get(key) is Array:
		for r: Variant in (d as Dictionary)[key]:
			if r is Dictionary:
				out.append(r as Dictionary)
	return out
