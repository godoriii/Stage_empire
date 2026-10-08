---
name: sheet-export
description: 밸런스 시트(Google Sheets 또는 CSV)를 project/data/ JSON 테이블로 내보내고 스키마 검증한다. game-designer 가 수치를 시트에서 조정한 뒤 사용. 사용 - /sheet-export <table> <sheet-url 또는 csv 경로>
---

# 시트 → JSON 내보내기

`tools/sheet_export.py` 가 아직 없다면 이 절차대로 만든 뒤 실행한다(쓰기 범위: game-designer 는 `project/data/` 만이므로 스크립트 생성은 메인 세션에서).

1. 입력: Google Sheets 는 연결된 Sheets 도구로 `get_values`, CSV 는 파일 읽기. 첫 행이 헤더(= JSON 키), `id` 열 필수.
2. 변환: 숫자는 number, `true/false` 는 boolean, 쉼표 구분 셀은 배열, 빈 셀은 키 생략.
3. 출력: `project/data/<table>/<table>.json` 을 `{"version": N, "rows": [...]}` 형식으로. `version` 은 기존 값 유지(스키마가 바뀔 때만 올린다).
4. `python3 tools/validate_data.py` 실행. 실패하면 파일을 되돌리고 오류를 보여준다.
5. 바뀐 행 수와 바뀐 수치의 전후를 표로 보고한다.
