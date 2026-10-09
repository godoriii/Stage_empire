class_name GridViewParams
extends Resource
## 그리드·타일 커서 표시 상수(색, 선 높이 등). 아트 디렉터가 grid_view_params.tres 를 편집한다.
## SE-004 툰 셰이더 전까지는 기본 StandardMaterial3D 에 이 색을 쓴다.

@export var floor_color: Color = Color.BLACK
@export var line_color: Color = Color.WHITE
## 타일 선을 바닥 위로 띄우는 높이(m). z-fighting 방지.
@export var line_y_offset_m: float = 0.0
## 바닥 판 두께(m). 윗면이 y=0.
@export var floor_thickness_m: float = 0.0

@export var cursor_color: Color = Color.WHITE
## 커서 메시를 바닥 위로 띄우는 높이(m).
@export var cursor_y_offset_m: float = 0.0
## 커서 메시 한 변 / 타일 한 변 비율.
@export var cursor_fill_ratio: float = 1.0
## 커서 좌표 라벨(Label3D) 높이(m)와 픽셀 크기.
@export var cursor_label_height_m: float = 0.0
@export var cursor_label_pixel_size: float = 0.0
@export var cursor_label_font_size: int = 0
