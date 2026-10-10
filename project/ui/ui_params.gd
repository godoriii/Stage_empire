class_name UiParams
extends Resource
## SE-039: UI 표시 상수(아트 디렉터·2차가 바꾸는 값). 값은 ui_params.tres 에 있다(코드 기본값은 빈 값).
## 게임 규칙 수치가 아니다 — 저장 슬롯 id·새 게임 시드·알림 수·리포트 행 순서(show.md 확정 순서)·섭외 행 간격.

const DEFAULT_PATH: String = "res://ui/ui_params.tres"
## SE-057 세이브 데이터 테이블(있으면 manual_slots 가 save_slots 를 대신한다, SE-040 AC-39d). 없으면 이 .tres 기본.
const SAVE_DATA_PATH: String = "res://data/save/save.json"
const SAVE_SLOTS_FIELD: String = "manual_slots"
## manual_slots 가 정수 n 이면 슬롯 id = "1".."n"(events.md SN1 수동 슬롯 이름).
const FIRST_SLOT_NUMBER: int = 1

## 메뉴 저장/불러오기 슬롯 id(session.save_requested {slot: String}). 슬롯 수 = 배열 길이.
@export var save_slots: PackedStringArray = PackedStringArray()
## session.new_game_requested {seed} 의 시드. 메인 씬(SE-040)은 for_session 사본에 실행 시드(--se-seed 또는 시작 시각)를 넣는다.
@export var new_game_seed: int = 0
## 알림 피드에 동시에 남는 최대 줄 수.
@export var notification_max: int = 0
## 알림 한 줄이 사라지기까지의 초(0 이하면 사라지지 않는다).
@export var notification_seconds: float = 0.0
## 마감 리포트 행 순서(show.md R1~R13 id, SE-039 2차 확정 순서).
@export var report_rows: PackedStringArray = PackedStringArray()
## 섭외 패널 한 행 안의 칸 간격(px, 표시 상수).
@export var artist_row_separation: int = 0


static func load_default() -> UiParams:
	return load(DEFAULT_PATH) as UiParams


## SE-040: 메인 씬용 사본. new_game_seed = seed_value, save_slots = save.json manual_slots(있으면) 또는 이 리소스 값.
## 원본(.tres 캐시)은 바꾸지 않는다.
func for_session(seed_value: int, save_data_path: String = SAVE_DATA_PATH) -> UiParams:
	var out: UiParams = duplicate() as UiParams
	out.new_game_seed = seed_value
	var slots: PackedStringArray = read_manual_slots(save_data_path)
	if not slots.is_empty():
		out.save_slots = slots
	return out


## save.json manual_slots → 슬롯 id 목록. 파일·필드가 없거나 형식이 틀리면 빈 배열(호출자가 기본값 유지).
## 정수 n(≥ 1) → ["1", …, "n"], 문자열 배열 → 그대로.
static func read_manual_slots(path: String = SAVE_DATA_PATH) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if not FileAccess.file_exists(path):
		return out
	var root: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (root is Dictionary) or not (root as Dictionary).has(SAVE_SLOTS_FIELD):
		return out
	var v: Variant = (root as Dictionary)[SAVE_SLOTS_FIELD]
	if v is float or v is int:
		for i: int in range(FIRST_SLOT_NUMBER, int(v) + FIRST_SLOT_NUMBER):
			out.append(str(i))
	elif v is Array:
		for e: Variant in v as Array:
			if e is String and not (e as String).is_empty():
				out.append(e as String)
	return out
