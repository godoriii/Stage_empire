---
name: new-ticket
description: 새 티켓 SE-### 파일을 docs/tickets/ 에 템플릿으로 만든다. 번호는 자동으로 다음 번호. 사용 - /new-ticket <제목> [담당 에이전트]
---

# 새 티켓 만들기

1. `ls docs/tickets/ | grep -E '^SE-[0-9]+' | sort -V | tail -1` 로 마지막 번호를 찾고 +1 한다. 없으면 SE-001.
2. `docs/tickets/TEMPLATE.md` 를 복사해 `docs/tickets/SE-###.md` 를 만들고 제목·담당·마일스톤을 채운다.
3. 수용 기준과 테스트 방법이 비어 있으면 **배정하지 않는다**. 사용자에게 두 항목을 물어보거나 PRD/GDD 에서 끌어와 채운다.
4. 구현 티켓인데 `docs/gdd/` 스펙이 없으면 먼저 game-designer 스펙 티켓을 만들고 의존 관계를 적는다.
5. 티켓 경로를 한 줄로 알려준다.
