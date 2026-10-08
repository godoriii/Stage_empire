# SE-### <제목>

| 항목 | 값 |
|---|---|
| 상태 | 대기 / 스펙 / 구현 / QA / 리뷰 / 병합 / 반려 |
| 담당 에이전트 | producer / game-designer / content-writer / sim-engineer / render-engineer / art-pipeline / audio / qa |
| 마일스톤 | 프리프로덕션 / MVP / 버티컬 슬라이스 / 프로덕션 / 폴리시 |
| 의존 티켓 | SE-### (없으면 "없음") |
| 스펙 | docs/gdd/<system>.md#<절> (구현 티켓은 필수) |
| 브랜치 | feature/SE-###-<slug> |

## 목표

한 문단. 플레이어 관점 또는 시스템 관점에서 "무엇이 되면 끝인가".

## 범위

- 포함:
- 제외(다른 티켓):

## 수용 기준

측정 가능한 문장만. 각 항목은 테스트 하나와 짝이 된다.

- [ ] AC1.
- [ ] AC2.

## 테스트 방법

- 헤드리스: `tools/run_tests.sh tests/sim` 에서 `test_<name>.gd` 의 어떤 케이스
- 수동(있다면): 실행 절차와 기대 화면

## 경계 확인

- 쓰는 폴더:
- 읽기만 하는 폴더:
- 필요한 이벤트(발행/구독):
- 필요한 데이터 테이블/필드(game-designer 요청 여부):

## 결과

(담당 에이전트가 완료 시 작성) 바뀐 파일, 테스트 결과, 남은 질문. PR 설명과 동일.

## QA / 리뷰

- QA 리포트: docs/reports/SE-###.md
- 리뷰: docs/reviews/SE-###.md
