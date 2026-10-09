# Stage Empire — 작업 규칙 (CLAUDE.md)

지하 라이브클럽에서 글로벌 메가 페스티벌까지 키우는 2.5D 아이소메트릭 건설·경영 시뮬레이션.
기준 문서는 `docs/PRD.md`(원본: Claude Docs "Stage Empire PRD & 제작 계획"). 이 파일은 PRD의 결정 사항을
에이전트가 매 작업에서 지켜야 할 규칙으로 압축한 것이다. PRD와 충돌하면 PRD가 이긴다.

## 결정된 사항 (바꾸려면 ADR 필요)

- 엔진: **Godot 4.7.2** (4.x 계열), GDScript 기본 + 일부 C#. 성능 스파이크(인스턴싱 캐릭터 5,000 + 동적 라이트 32개, 60fps) 실패 시에만 Unity 재검토.
- 룩: 3D 로우폴리 모델 + 직교 카메라(피치 ~30°, 요 45°) + 툰 셰이더·외곽선. 카메라 회전은 90° 단위 4방향만.
- 그리드: 1타일 = 1m. 티어 1은 24×24, 티어 6은 400×400. 32×32 청크 단위 로드.
- 시뮬레이션: 고정 틱 10 tick/초, 렌더는 보간. 세이브는 틱 경계에서만. RNG는 시드 고정.
- 팀: 사람 1명 + 에이전트. 사람이 하는 일은 방향 결정, 재미 판단, 아트 디렉션, 최종 검수.
- 테스트 프레임워크: GUT 9.7.1 (`project/addons/gut`, Godot 4.7.x), 헤드리스 실행. 근거는 `docs/adr/0003-test-framework-gut.md`.

## 아키텍처 원칙

1. **시뮬레이션과 렌더링 분리.** 게임 상태는 순수 데이터 모델. 렌더러(`view/`, `ui/`)는 이벤트 버스를 구독만 하고 상태를 직접 바꾸지 않는다. 시뮬레이션 코드는 Node/Scene API를 import하지 않는다(헤드리스 테스트의 전제).
2. **고정 틱.** `core/`의 틱 루프만 시간을 진행시킨다. `_process`에서 게임 상태를 바꾸지 않는다.
3. **데이터 주도.** 가구·아티스트·장르·이벤트·티어 조건·밸런스 수치는 전부 `project/data/**/*.json`. 코드에 매직 넘버를 넣지 않는다. 모든 테이블은 `project/data/schemas/`의 스키마를 가지며 `python3 tools/validate_data.py`를 통과해야 한다.
4. **이벤트 버스.** 시스템끼리 직접 호출하지 않는다. `core/event_bus.gd`로 발행/구독.
5. **관객 AI 전환.** 티어 3까지 개별 에이전트(최대 3,000), 티어 4부터 흐름장(flow field) + 밀도 모델.

레이어와 폴더:

| 레이어 | 폴더 | 책임 |
|---|---|---|
| Core | `project/core/` | 게임 루프, 틱, 세이브/로드, 이벤트 버스, RNG |
| Simulation | `project/sim/` | 경제, 관객, 아티스트, 공연, 명성, 이벤트 |
| World | `project/world/` | 그리드, 배치 규칙, 경로 탐색, 커버리지 계산 |
| Presentation | `project/view/` | 직교 카메라, 모델·머티리얼, 툰 셰이더, 조명·파티클, 군중 인스턴싱, 오디오 재생 |
| UI | `project/ui/` | 패널, HUD, 튜토리얼, 로컬라이즈 |
| Data | `project/data/` | JSON 테이블, 스키마, 문자열 |
| Assets | `project/assets/` | 모델, 머티리얼, 오디오. `review-queue/`는 사람 검수 대기 |
| Tools | `tools/` | 시트→JSON, glTF 임포터, 에셋 린터, 봇 플레이어, hooks |
| Tests | `project/tests/sim|view|e2e/` | 헤드리스 유닛·리플레이·스크린샷 테스트 |

## 책임 경계 규칙 (hooks로 강제)

- 엔지니어 에이전트(sim-engineer, render-engineer)는 `project/data/`의 수치를 바꾸지 않는다. 밸런스는 **game-designer만** 손댄다. 새 필드가 필요하면 스키마 변경 티켓을 producer에게 돌려보낸다.
- render-engineer는 `sim/`을 읽기만 하고, sim-engineer는 `view/`·`ui/`를 건드리지 않는다. 경계를 넘어야 하면 티켓을 분리한다.
- 생성 에셋은 사람 검수 없이 `project/assets/{models,materials,audio}`에 들어가지 않는다. art-pipeline과 audio는 `project/assets/review-queue/`까지만 쓴다. 검수 통과 후 사람이 옮긴다.
- 모든 작업은 티켓 번호(`SE-###`)를 가진다. 티켓에는 **수용 기준**과 **테스트 방법**이 반드시 있다(`docs/tickets/TEMPLATE.md`).
- 에이전트 간 전달은 대화가 아니라 **파일**로 한다: 티켓(`docs/tickets/`) → 스펙(`docs/gdd/`) → PR 설명 → 리뷰 코멘트(`docs/reviews/`).
- 게임 상태를 만드는 스크립트(`project/core|sim|world/**/*.gd`)는 짝이 되는 `project/tests/sim/test_<이름>.gd`가 없으면 커밋 불가. `tools/hooks/check_commit.py`가 막는다.
- reviewer는 읽기 전용이다. 승인/반려만 하고 코드를 고치지 않는다. 반려는 새 티켓이 된다.
- `main`에 직접 push 금지, force push 금지. 모든 변경은 브랜치 → PR → CI 녹색 + reviewer 승인 → producer 병합.

경계 위반이 hooks에 막히면 우회하지 말고, 왜 필요한지 티켓에 적어 producer에게 돌려보낸다.

## 에이전트 구성

`.claude/agents/`에 9종. 사람은 **producer**만 상대한다.

| 에이전트 | 쓰기 범위 | 모델 |
|---|---|---|
| producer | `docs/tickets/`, `docs/status/`, 병합 | Fable 5.1 |
| game-designer | `docs/gdd/`, `project/data/` | Opus 5.5 |
| content-writer | `project/data/text/`, `project/data/artists/` | Sonnet 5.5 |
| sim-engineer | `project/core/`, `project/sim/`, `project/world/`, `project/tests/sim/` | Opus 5.5 |
| render-engineer | `project/view/`, `project/ui/`, `project/tests/view/` | Opus 5.5 |
| art-pipeline | `project/assets/review-queue/`, `project/data/furniture/`, `tools/assets/` | Sonnet 5.5 |
| audio | `project/assets/review-queue/audio/`, `project/data/audio/` | Sonnet 5.5 |
| qa | `project/tests/`, `docs/reports/` | Sonnet 5.5 |
| reviewer | 없음(읽기 전용), `docs/reviews/`만 | Fable 5.1 |

모든 에이전트는 추가로 `docs/tickets/`에 쓸 수 있다(담당 티켓의 "결과" 절 기록용). 그 밖의 경로는 위 표가 전부다.

동시 실행 상한은 producer 외 3개. 엔지니어(sim/render)는 폴더가 겹치지 않으므로 병렬 허용(2026-10-09, 첫날 10 티켓에서 hook·관문이 문제없이 작동해 "처음 2주 엔지니어 1명" 제한을 해제).

## 사람 검수 최소화 원칙 (2026-10-09 프로덕트 오너 결정)

사람에게 올리는 항목은 **사람만 할 수 있는 것**으로 제한한다. 그 밖은 에이전트가 기본값으로 진행하고 `docs/status/`의 "결정 로그"에 남긴다. 사람은 로그를 보고 나중에 뒤집을 수 있다.

| 사람에게 올린다 | 에이전트가 처리한다 |
|---|---|
| GPU 가 필요한 성능 측정(관문 시점에만, 여러 티켓을 한 번에 모아서) | PR 병합 — CI 녹색 + reviewer 승인이면 producer 가 **묻지 않고** merge commit 으로 병합 |
| 아트 디렉션 선택(셰이더 시안, 팔레트, 룩 변경의 스크린샷 승인) | 열린 질문 — 추천안을 채택하고 결정 로그에 기록. ADR 이 필요한 변경만 사람에게 |
| 되돌릴 수 없거나 외부로 나가는 행동(삭제, 공개, 지출, 리포지토리 설정) | 육안 확인 — 헤드리스 캡처(xvfb)·구조 테스트로 대체. 사람 캡처는 룩 변경 때만 |
| 범위 축소·방향 전환(관문 실패 후 Unity 재검토 같은 것) | 티켓 분해·배정·후속 티켓 발행·브랜치 정리 |

사람에게 올릴 때는 질문 하나에 선택지와 추천을 붙이고, 답이 없으면 추천안으로 진행한다.

## 한 티켓의 흐름

1. 사람이 마일스톤 목표를 producer에게 준다. 예: "티어 1 공연 루프가 돌아가게".
2. producer가 PRD·GDD를 참조해 티켓 10~20개로 쪼개고 의존성을 표시한다.
3. game-designer가 각 티켓의 스펙(규칙, 수치, 수용 기준)과 JSON 초안을 쓴다.
4. sim-engineer와 render-engineer가 각자 worktree에서 병렬 구현하고 테스트를 함께 낸다.
5. art-pipeline과 audio가 같은 티켓의 에셋을 만들어 검수 큐에 올린다.
6. qa가 헤드리스 테스트, 봇 플레이, 성능 측정을 돌리고 리포트를 낸다.
7. reviewer가 경계 위반과 코드 품질을 보고 승인/반려한다.
8. producer가 병합하고 사람에게 "이번에 플레이해볼 것"을 보고한다.

## 명령어

```bash
python3 tools/validate_data.py          # JSON 테이블 스키마 검증 (CI와 커밋 hook이 동일하게 실행)
tools/run_tests.sh                      # GUT 헤드리스 테스트 전체 (Godot 없으면 SKIP)
tools/run_tests.sh project/tests/sim    # 특정 디렉터리만
python3 tools/hooks/boundary.py --self-test   # 경계 hook 자체 테스트
python3 tools/hooks/test_check_commit.py      # 커밋/푸시 가드 hook 자체 테스트
```

Godot 바이너리는 `GODOT_BIN` 환경 변수 또는 PATH의 `godot`을 쓴다.

## 코드 규칙

- GDScript: 타입 힌트 필수(`var x: int`), 스네이크 케이스, 클래스 하나당 파일 하나, `class_name` 사용.
- 시뮬레이션 코드는 `RefCounted`/`Resource` 기반, `Node` 상속 금지.
- 수치는 JSON에서 읽는다. 상수가 필요하면 `project/data/`에 넣고 game-designer 티켓으로 요청.
- 커밋 메시지: `SE-### <한 줄 요약>`. 본문에 테스트 방법.
- PR 설명: 티켓 번호, 변경 요약, 테스트 결과, 경계 준수 확인 체크박스(템플릿 `.github/pull_request_template.md`).

## 언어

문서·티켓·코멘트는 한국어. 코드 식별자와 커밋 제목의 요약 부분은 영어 식별자 허용.
