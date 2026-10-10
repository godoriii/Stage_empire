class_name UiTestUtil
extends RefCounted
## SE-039 HUD·패널 테스트 공용 헬퍼(테스트 파일 아님). 가짜 sim = 테스트가 버스에 상태 이벤트를 직접 발행한다.
## 명령(*_requested)은 EventBus 명령 큐에 남으므로 get_pending_commands 로 단언한다(디스패치하지 않는다).
## 기대값은 데이터(JSON)에서 읽는다 — 행 수·임계·배속 리터럴을 두지 않는다.

const SIM_PATH: String = "res://data/sim/sim.json"
const ARTISTS_PATH: String = "res://data/artists/artists.json"
const ARTIST_PATH: String = "res://data/artist/artist.json"
const ECONOMY_PATH: String = "res://data/economy/economy.json"
const SHOW_PATH: String = "res://data/show/show.json"
const TIERS_PATH: String = "res://data/tiers/tiers.json"


static func json(path: String) -> Dictionary:
	return ViewTestUtil.read_json(path) as Dictionary


## 픽스처 문자열(결정 a): 값 자리표시만 있는 템플릿 몇 개. 나머지 키는 폴백(결정 b).
static func fixture_text() -> UiText:
	return UiText.from_strings({
		"ui.hud.cash": "C{cash}", "ui.hud.reputation": "R{reputation}", "ui.hud.day": "D{day}",
		"ui.phase.day": "PH_day", "ui.phase.close": "PH_close",
		"ui.notify.artist": "N_artist:{reason}", "ui.reason.artist.insufficient_cash": "cash!",
	})


## 씬을 만들어 트리에 넣고 setup 한다.
static func make_panel(test: GutTest, scene_path: String, bus: EventBus, text: UiText = null) -> UiPanel:
	var p: UiPanel = (load(scene_path) as PackedScene).instantiate() as UiPanel
	test.add_child_autofree(p)
	p.setup(bus, UiData.load_default(), text, UiParams.load_default())
	return p


static func make_root(test: GutTest, bus: EventBus, sources: Dictionary = {}) -> UiRoot:
	var r: UiRoot = UiRoot.new()
	test.add_child_autofree(r)
	r.bind(bus, UiData.load_default(), UiText.from_strings({}), UiParams.load_default(), sources)
	return r


## 명령 큐에서 이름이 같은 것의 페이로드들.
static func commands(bus: EventBus, name: String) -> Array:
	var out: Array = []
	for c: Dictionary in bus.get_pending_commands():
		if c["name"] == name:
			out.append(c["payload"])
	return out


## 구간 진입(time.phase_changed) 가짜 발행.
static func enter_phase(bus: EventBus, to: String, day: int = 1) -> void:
	bus.publish("time.phase_changed", {"from": "", "to": to, "day": day, "tick": 0})


## sim.json 구간 id 목록(순서).
static func phase_ids() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ph: Dictionary in json(SIM_PATH)["phases"]:
		out.append(str(ph["id"]))
	return out


static func phase_speeds(phase: String) -> Array[int]:
	var out: Array[int] = []
	for ph: Dictionary in json(SIM_PATH)["phases"]:
		if ph["id"] == phase:
			for s: Variant in ph["speeds"]:
				out.append(int(s))
	return out


static func booking_phase() -> String:
	return str(json(ARTIST_PATH)["booking_phases"][0])


static func close_phase() -> String:
	var ids: PackedStringArray = phase_ids()
	return ids[ids.size() - 1]


static func unlock_of(grade: String) -> int:
	for g: Dictionary in json(ARTIST_PATH)["grades"]:
		if g["id"] == grade:
			return int(g["unlock_reputation"])
	return -1


## 가장 높은 섭외 임계 등급(잠김 테스트용)과 그 임계.
static func locked_grade() -> String:
	var best: String = ""
	var v: int = -1
	for g: Dictionary in json(ARTIST_PATH)["grades"]:
		if int(g["unlock_reputation"]) > v:
			v = int(g["unlock_reputation"])
			best = str(g["id"])
	return best


static func first_artist_of_grade(grade: String) -> String:
	for r: Dictionary in json(ARTISTS_PATH)["rows"]:
		if r["grade"] == grade:
			return str(r["id"])
	return ""


static func economy_row() -> Dictionary:
	var tiers: Array = json(TIERS_PATH)["rows"]
	var t: int = int(tiers[0]["tier"])
	for r: Dictionary in tiers:
		t = mini(t, int(r["tier"]))
	for r: Dictionary in json(ECONOMY_PATH)["rows"]:
		if int(r["tier"]) == t:
			return r
	return {}
