# SE-031-bug `glitter_twins`(반짝 쌍둥이) 이름이 실존 2인 프로듀서 팀 이름 "The Glimmer Twins"의 직역·패러디로 읽힘

| 항목 | 값 |
|---|---|
| 상태 | 해결 (content-writer e46ecd3, 이름 교체. qa 재검증 2026-10-09) |
| 담당 에이전트 | content-writer (이름·id·바이오 교체; `project/data/artists/artists.json`, `project/data/text/artists_ko.json`) |
| 마일스톤 | MVP |
| 의존 티켓 | SE-031 (같은 브랜치 `feature/SE-031-artist-spec-and-roster`에서 병합 전에 고치거나, 병합 뒤 후속 티켓) |
| 스펙 | docs/gdd/artist.md #이름과-바이오-규칙 N3(한두 글자 패러디·직역 금지), N8(자기 검토 표), docs/PRD.md "비목표"(실존 아티스트 연상 금지) |
| 심각도 | 중간 (PRD 비목표 위반 가능성, 데이터 한 행 교체로 해결. 시뮬레이션·수치 영향 없음) |

## 재현 절차

- 입력: `project/data/artists/artists.json` 행 s11 `id: "glitter_twins"`, `name: "반짝 쌍둥이"`; 자기 검토 표(SE-031 결과 절 2차)는 "유사 실존 이름 없음".
- 기억 기준 대조(웹 검색 없음): "The Glimmer Twins"는 롤링 스톤스의 Mick Jagger·Keith Richards가 음반 제작 크레딧에 쓰는 공동 필명으로 알려진 이름이다.
  - `glitter` ↔ `glimmer`: 영문 id가 2글자 차이(t,t → m,m). N3 의 "한두 글자만 바꾼 패러디"에 해당.
  - "반짝"은 glimmer/sparkle 양쪽으로 번역되고 "쌍둥이"는 twins 라서 한국어 이름을 영어로 직역하면 "Glimmer Twins"가 된다. content-writer 의 검토 방법("직역 가능성 확인")이 이 건을 잡지 못했다.
- 기대: 12행 모두 실존 이름과 직역·1~2글자 차이가 없다(AC3).
- 실제: 1건(s11) 의심. 나머지 11개는 아래 표 참고(qa 리포트 docs/reports/SE-031.md "실존 연상 검토").
- 재현성: 기억에 의한 판단이라 확정이 아니다. 실존 여부는 reviewer/사람이 한 번 더 확인한다. 확인 전까지 닫지 않는다.

## 제안

- 이름·id 교체(콘셉트 "화려한 무대 의상의 하우스 DJ 듀오" 유지): 예 `반짝 쌍둥이` → 쌍둥이/반짝 모티프를 버린 이름. 바이오 키는 `artist.bio.<새 id>`로 같이 바꾼다(L6). `id`는 세이브 키이지만 MVP 전이라 지금 바꿔도 마이그레이션이 없다.
- 슬롯 수치·태그는 그대로(수치 변경 없음). 교체 뒤 `python3 tools/validate_data.py --strict`와 `project/tests/sim/test_artist_data.gd`(id 12개 유일·`bio_key` 규칙)가 녹색이어야 한다.

## 결과

- 교체(content-writer, e46ecd3): s11 `glitter_twins`/반짝 쌍둥이 → `gold_foil_mask`/금박 가면, 같은 커밋에서 s06 `two_cups`/커피 두 잔 → `window_seat`/창가 자리(낮은 주의 건 선제 교체). 수치·태그·장르·등급 불변, `bio_key`는 `artist.bio.<새 id>`, s11 바이오는 새로 씀(70자).
- qa 재검증(2026-10-09): `tools/run_tests.sh project/tests/sim` 87/87 통과(`test_artist_data.gd` 317행의 옛 id 리터럴 `two_cups`가 남아 1개 실패했던 것을 `window_seat`로 고침), `validate_data.py --strict` exit 0(실패 0), artist.md AR11 스크립트 `AR11 OK`.
- 새 이름 재판정(기억 기준): `gold_foil_mask`/금박 가면 문제 없음. `window_seat`/창가 자리는 곡명 "Window Seat"(Erykah Badu)과 id 일치하는 낮은 주의 1건이 있으나 아티스트 이름·패러디가 아니라 차단하지 않고 reviewer 확인을 요청(`docs/reports/SE-031.md`).
