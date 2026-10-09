class_name BuildViewParams
extends Resource
## SE-037 배치 UI 표시 상수(고스트·오버레이 데칼·반경 미리보기 색, 높이). 아트 디렉터가 build_view_params.tres 를 편집한다.
## 게임 수치가 아니다(색·오프셋만). 가구 크기·비용·반경은 furniture.json 에서 읽는다.

## 고스트(배치 미리보기) 색. 알파 = 반투명도.
@export var ghost_valid_color: Color = Color.GREEN
@export var ghost_invalid_color: Color = Color.RED
## 철거 모드에서 커서 아래 가구를 덮는 상자 색.
@export var demolish_color: Color = Color.ORANGE
## 고스트 상자를 가구 크기보다 키우는 여유(m). 메시와 z-fighting 방지.
@export var ghost_padding_m: float = 0.0
## 고스트 위 사유 라벨(Label3D) 높이 여유(m)·픽셀 크기·글자 크기.
@export var ghost_label_offset_m: float = 0.0
@export var ghost_label_pixel_size: float = 0.0
@export var ghost_label_font_size: int = 0

## 오버레이 데칼: 바닥 위 높이(m), 타일 한 변 대비 채움 비율.
@export var decal_y_offset_m: float = 0.0
@export var decal_fill_ratio: float = 1.0
## 모드별 "덮인 관람 타일" 색. 키 = CoverageOverlay.MODES 의 off 외 id(sound/sight/bar).
@export var overlay_covered_colors: Dictionary = {}
## 관람 타일 중 덮이지 않은 타일 색(모든 모드 공통).
@export var overlay_uncovered_color: Color = Color.RED

## 고스트 반경 미리보기(UI 계약: 선택 가구의 effects.*_radius 를 커버리지 거리식으로). 키 = effects 필드 이름.
@export var radius_preview_colors: Dictionary = {}

## 프록시 색: slots.base 가 hex 가 아닐 때(팔레트 id pal_* — 팔레트 확정 전) 쓰는 색.
@export var proxy_fallback_color: Color = Color.WHITE
