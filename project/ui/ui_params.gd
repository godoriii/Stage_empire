class_name UiParams
extends Resource
## SE-039: UI 표시 상수(아트 디렉터·2차가 바꾸는 값). 값은 ui_params.tres 에 있다(코드 기본값은 빈 값).
## 게임 규칙 수치가 아니다 — 저장 슬롯 id·새 게임 시드·알림 수·리포트 행 순서(show.md 확정 순서)·섭외 행 간격.

const DEFAULT_PATH: String = "res://ui/ui_params.tres"

## 메뉴 저장/불러오기 슬롯 id(session.save_requested {slot: String}). 슬롯 수 = 배열 길이.
@export var save_slots: PackedStringArray = PackedStringArray()
## session.new_game_requested {seed} 의 시드(SE-040 이 정할 때까지 고정).
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
