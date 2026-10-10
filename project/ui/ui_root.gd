class_name UiRoot
extends Node
## SE-039: HUD·패널을 만들고 버스·데이터·문자열을 나눠 준다. 패널 전환·입력 포커스만 맡는다(게임 규칙 없음).
## 전환: HUD "섭외" 버튼 ↔ 섭외 패널, Esc(InputMap 기본 액션 ui_cancel) → 섭외 패널이 열려 있으면 닫고 아니면 메뉴 토글.
##   파산 화면이 떠 있으면 Esc 무시(입력 차단). 리포트(close)는 DayReport 가 스스로 보인다 — 열릴 때 섭외 패널을 닫는다.
## 읽기 전용 sim 객체(sources): "artist_config"(ArtistConfig 또는 UiArtistCatalog), "artist_system"(ArtistSystem, 없으면 null),
##   "reputation"(ReputationSystem — total·unlocked_tier 만 읽는다, SE-030·SE-035 인계). 메인 씬 연결은 SE-040.
## 구독: session.loaded(명성 초기값 다시 읽기), time.phase_changed(close 진입 시 섭외 패널 닫기). 발행 없음.

const HUD_SCENE: String = "res://ui/hud/top_hud.tscn"
const ARTIST_SCENE: String = "res://ui/panels/artist_panel.tscn"
const REPORT_SCENE: String = "res://ui/panels/day_report.tscn"
const BAILOUT_SCENE: String = "res://ui/panels/bailout_modal.tscn"
const GAME_OVER_SCENE: String = "res://ui/panels/game_over.tscn"
const NOTIFY_SCENE: String = "res://ui/panels/notifications.tscn"
const MENU_SCENE: String = "res://ui/panels/main_menu.tscn"
const MENU_ACTION: StringName = &"ui_cancel"
const SRC_ARTIST_CONFIG: String = "artist_config"
const SRC_ARTIST_SYSTEM: String = "artist_system"
const SRC_REPUTATION: String = "reputation"

var hud: TopHud
var artist_panel: ArtistPanel
var day_report: DayReport
var bailout: BailoutModal
var game_over: GameOver
var notifications: Notifications
var menu: MainMenu

var _bus: EventBus
var _sources: Dictionary = {}


func _init() -> void:
	name = "UiRoot"
	hud = (load(HUD_SCENE) as PackedScene).instantiate() as TopHud
	artist_panel = (load(ARTIST_SCENE) as PackedScene).instantiate() as ArtistPanel
	day_report = (load(REPORT_SCENE) as PackedScene).instantiate() as DayReport
	bailout = (load(BAILOUT_SCENE) as PackedScene).instantiate() as BailoutModal
	game_over = (load(GAME_OVER_SCENE) as PackedScene).instantiate() as GameOver
	notifications = (load(NOTIFY_SCENE) as PackedScene).instantiate() as Notifications
	menu = (load(MENU_SCENE) as PackedScene).instantiate() as MainMenu
	for p: UiPanel in panels():
		add_child(p)


func panels() -> Array[UiPanel]:
	return [hud, artist_panel, day_report, bailout, notifications, menu, game_over]


## 트리에 넣은 뒤 부른다. data/text/params 가 null 이면 기본(JSON·ui_ko.json 폴백·ui_params.tres).
func bind(bus: EventBus, data: UiData = null, text: UiText = null, params: UiParams = null, sources: Dictionary = {}) -> void:
	_unsubscribe()
	_bus = bus
	_sources = sources.duplicate()
	var d: UiData = data if data != null else UiData.load_default()
	var tx: UiText = text if text != null else UiText.load_default()
	var pr: UiParams = params if params != null else UiParams.load_default()
	for p: UiPanel in panels():
		p.setup(bus, d, tx, pr)
	artist_panel.set_sources(_sources.get(SRC_ARTIST_CONFIG), _sources.get(SRC_ARTIST_SYSTEM))
	day_report.set_artist_config(_sources.get(SRC_ARTIST_CONFIG))
	hud.set_reputation_reader(_sources.get(SRC_REPUTATION))
	_push_reputation()
	if not hud.artist_panel_requested.is_connected(toggle_artist_panel):
		hud.artist_panel_requested.connect(toggle_artist_panel)
		hud.menu_requested.connect(toggle_menu)
		artist_panel.close_requested.connect(close_artist_panel)
	if _bus != null:
		_bus.subscribe("session.loaded", _on_session_loaded)
		_bus.subscribe("time.phase_changed", _on_phase_changed)


## 버스 없이 가짜 sim 출력 하나를 모든 패널에 넣는다(샌드박스 프리셋). 처리한 패널 수.
func inject(event_name: String, payload: Dictionary) -> int:
	var n: int = 0
	for p: UiPanel in panels():
		if p.handle(event_name, payload):
			n += 1
	match event_name:
		"session.loaded":
			_on_session_loaded(payload)
		"time.phase_changed":
			_on_phase_changed(payload)
	return n


func toggle_artist_panel() -> void:
	artist_panel.visible = not artist_panel.visible and not game_over.is_blocking()


func close_artist_panel() -> void:
	artist_panel.visible = false


func toggle_menu() -> void:
	if not game_over.is_blocking():
		menu.toggle()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(MENU_ACTION):
		return
	if game_over.is_blocking():
		return
	if artist_panel.visible:
		close_artist_panel()
	else:
		menu.toggle()
	get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	_unsubscribe()


func _unsubscribe() -> void:
	if _bus != null:
		_bus.unsubscribe("session.loaded", _on_session_loaded)
		_bus.unsubscribe("time.phase_changed", _on_phase_changed)
	_bus = null


func _push_reputation() -> void:
	var total: int = TopHud.read_reputation_total(_sources.get(SRC_REPUTATION), 0)
	artist_panel.set_reputation(total)
	day_report.set_reputation(total)
	var reader: Object = _sources.get(SRC_REPUTATION)
	if reader != null and reader.get("unlocked_tier") != null:
		day_report.set_unlocked_tier(int(reader.get("unlocked_tier")))


func _on_session_loaded(_p: Dictionary) -> void:
	if _sources.get(SRC_REPUTATION) != null:
		_push_reputation()


func _on_phase_changed(p: Dictionary) -> void:
	if str(p.get("to", "")) == DayReport.REPORT_PHASE:
		close_artist_panel()
