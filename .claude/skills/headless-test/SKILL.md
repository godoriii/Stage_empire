---
name: headless-test
description: GUT 헤드리스 테스트와 JSON 스키마 검증을 CI와 같은 방식으로 실행하고 결과를 요약한다. 사용 - /headless-test [project/tests/sim|project/tests/view|project/tests/e2e]
---

# 헤드리스 테스트

```bash
python3 tools/validate_data.py
tools/run_tests.sh ${ARGUMENTS:-}
```

- 두 명령 모두 돌린다. 실패 출력은 줄이지 말고 그대로 보여준다.
- `SKIP: Godot 바이너리 없음` 이면 로컬에 Godot 이 없는 것이다. `GODOT_BIN=/path/to/godot` 를 안내하고, CI 결과를 대신 확인하라고 말한다.
- `SKIP: project/addons/gut 없음` 이면 `docs/adr/0003-test-framework-gut.md` 설치 절을 안내한다.
- 테스트를 비활성화하거나 건너뛰어 녹색을 만들지 않는다.
