# SE-039-bug 불러오기 직후 마감 리포트 R2 행에 키 문자열(`ui.artist.grade.`)이 샌다

| 항목 | 값 |
|---|---|
| 상태 | 해결 (render-engineer, 커밋 "SE-039-bug 불러오기 직후 리포트 R2 키 노출 수정 + close 프리셋 만족 요소" — sha 는 커밋 로그/보고 참조) |
| 담당 에이전트 | render-engineer (`project/ui/panels/day_report.gd` 1~2줄 + 테스트) |
| 마일스톤 | MVP |
| 의존 티켓 | SE-039 (같은 브랜치에서 고치면 병합 전 처리, 아니면 후속) |
| 발견 | qa, 2026-10-10, `docs/reports/SE-039.md` 발견 1 |
| 심각도 | 낮음~중간 (한국어 문장에 `ui.` 키가 섞여 보임 — SE-040 에서 "close 구간에서 저장 → 불러오기" 하면 실제로 보인다) |

## 재현 절차 (결정적, 시드 불필요 — UI 만)

실제 `ui_ko.json` 으로 샌드박스 UI 를 만들고 마감 구간 불러오기를 흉내 낸다(SE-049: 불러오기 직후 그날 `show.ended`·`economy.day_settled`·`artist.lineup_set` 은 재발행되지 않는다).

```gdscript
var s: GridSandbox = (load("res://view/scenes/grid_sandbox.tscn") as PackedScene).instantiate() as GridSandbox
add_child_autofree(s)
s.setup_ui("day")                       # 실제 UiText.load_default() = ui_ko.json
var r: UiRoot = s.get_ui_root()
r.inject("session.loaded", {"day": 3, "phase": "close", "speed": 0, "show_active": false})
r.inject("time.phase_changed", {"from": "show", "to": "close", "day": 3, "tick": 0})
# r.day_report 가 visible, R2 행 텍스트를 읽는다
```

## 기대 / 실제

| | 내용 |
|---|---|
| 기대 | 화면 문자열에 `ui.` 키 폴백이 없다. 공연 정보가 없으면(불러오기 직후) R2 는 숨기거나 "기록 없음" 류의 문장 |
| 실제 | R2 행 = `공연   ·  · ui.artist.grade.` (아티스트 이름·장르 빈 칸, 등급 키가 빈 id 로 조회돼 키 문자열 그대로 노출). 같은 화면의 R6~R8 은 `티켓 0 + 바 0 = 0`, `순이익 0 · 자금 0`, R12 `자금 0/30000 (0%)` 로 실제 값이 아닌 0 을 보인다(1차 열린 질문 1 — `session.loaded` 에 현금이 없음) |

원인: `day_report.gd` `row_text("R2")` — `not has_show() and not skipped.is_empty()` 가 거짓(skipped 도 비어 있음)이면 `r2` 템플릿을 빈 `lineup` 으로 채운다. `ui.artist.grade.%s` 에 빈 문자열이 들어간다.

## 수정 방향 (render 판단)

- R2·R3 처럼 정보가 없는 행은 `has_show()` 뿐 아니라 `lineup` 이 비었을 때도 숨기거나(`HIDDEN_WITHOUT_SHOW` 에 R2 조건 추가) `r2_none` 류 문구를 쓴다(문구가 필요하면 game-designer 에게 키 1줄).
- 회귀 테스트: 위 재현을 `test_day_report` 에 넣고 "보이는 모든 행에 정규식 `(^|\s)ui\.[a-z0-9_]+\.` 0건"을 단언한다. `project/tests/view/test_ui_text_table.gd`(qa 추가)의 `_screen_texts` 헬퍼를 참고.
- 0 으로 보이는 정산 값(현금·순이익)은 SE-039 열린 질문 1(불러오기 뒤 현금) 몫 — 이 티켓에서 고치지 않는다.

## 로그

재현 출력(보이는 행 12개, R2 만 문제):

```
PROBE 공연   ·  · ui.artist.grade.
```

## 결과 (render-engineer, 2026-10-10)

- 수정: `project/ui/panels/day_report.gd` — `HIDDEN_WITHOUT_LINEUP = ["R2"]`, `has_lineup_info()`(= `show.ended`·`artist.lineup_set`·`show.skipped` 중 하나라도 받음). 라인업 정보가 없으면 R2 를 숨긴다. R3·R5·R11 은 이미 `show.ended` 없으면 숨김이라 같은 경로에서 키가 새지 않는다. 새 문구는 쓰지 않았다 — game-designer 키 추가 불필요.
- 회귀 테스트(`project/tests/view/test_day_report.gd`):
  - `test_loaded_close_leaks_no_keys_se039_bug`: 위 재현 절차 그대로(샌드박스 `setup_ui("day")` + 실제 `ui_ko.json` → `session.loaded` close → `time.phase_changed` close). 리포트에 보이는 Label/Button 전부 `(^|\s)ui\.[a-z0-9_]+\.` 0건, R2 숨김을 단언하고, 대조군도 둔다.
  - `test_lineup_info_shows_r2_again`: `show.skipped` 가 오면 R2 가 다시 보인다.
- 고치지 않은 것: R6~R8·R12 의 0 값(불러오기 뒤 현금). SE-036 `GameSession.hud_state()`/`cash()` 를 SE-040 통합에서 읽는다.
- 같은 커밋(qa 낮음 권고): `UiPreset` close 의 `audience.day_summary.avg_components` 를 공연 만족 + 오프셋(합 0, 평균 = satisfaction_bp)으로 채웠다. `report_close.png` 만 다시 찍었다.
- 확인: `tools/run_tests.sh project/tests/view` 247/247. `recapture.sh` 로 9장을 2회 찍었다. 두 회차는 9장 모두 diff 0, 커밋본과도 8장 diff 0. `report_close.png` 는 만족 요소 행만 다르다(diff 3,732px, bbox 633,318–1059,333). 새 캡처를 육안으로 확인했고 키 문자열·□ 깨짐 없음.
