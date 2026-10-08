# ADR-0002 시뮬레이션과 렌더링 분리, 고정 틱, 이벤트 버스

- 날짜: 2026-10-09
- 상태: 결정
- 출처: docs/PRD.md "아키텍처 원칙"

## 결정

1. 게임 상태는 `project/core`, `project/sim`, `project/world`의 순수 데이터 모델(`RefCounted`/`Resource`)이다. `Node`를 상속하지 않는다.
2. 시간은 `core/tick.gd`가 10 tick/초 고정 틱으로만 진행시킨다. 렌더는 보간한다. 세이브는 틱 경계에서만.
3. 시스템 간 통신은 `core/event_bus.gd`로만 한다. 렌더러·UI는 구독하고, 상태 변경은 명령 이벤트로 요청한다.
4. 난수는 `core/rng.gd`(시드 고정)에서만 나온다.

## 이유

- 헤드리스 유닛 테스트와 시드 고정 리플레이 테스트가 가능해야 에이전트가 낸 코드를 사람 없이 검증할 수 있다.
- 배속(1~3배)과 봇 플레이 1,000판이 렌더 없이 돌아야 한다.
- sim-engineer와 render-engineer가 서로 기다리지 않고 병렬로 일할 수 있다.

## 결과

- `tools/hooks/boundary.py`가 폴더 쓰기 범위를, reviewer가 `Node` 상속·`_process`·직접 난수를 검사한다.
- 이벤트 이름과 페이로드는 `docs/gdd/events.md`가 단일 출처다.
