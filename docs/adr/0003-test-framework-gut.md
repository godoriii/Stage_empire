# ADR-0003 테스트 프레임워크는 GUT

- 날짜: 2026-10-09
- 상태: 결정 (에이전트 셋업 시점의 선택, 프리프로덕션 중 재검토 가능)

## 결정

GUT(Godot Unit Test, `project/addons/gut`)를 쓴다. 실행은 `tools/run_tests.sh`가 `godot --headless -s addons/gut/gut_cmdln.gd`로 한다. 테스트 파일은 `tests/sim|view|e2e/**/test_*.gd`.

## 이유

- GDScript 네이티브, 헤드리스 CLI 실행과 exit code 지원, 에이전트가 예제를 많이 알고 있어 테스트 작성 비용이 낮다.
- 대안 gdUnit4는 C# 쪽 지원이 좋지만 셋업이 더 무겁다. C# 비중이 커지면 재검토한다.

## 설치

```bash
# Godot Asset Library 또는 GitHub 릴리스에서 GUT 9.x 를 받아 project/addons/gut 에 둔다.
# 이후 Godot 에디터 Project > Project Settings > Plugins 에서 GUT 활성화 (project.godot 에 기록됨).
tools/run_tests.sh   # 설치 전에는 SKIP 으로 통과한다
```

## 결과

- `tools/hooks/check_commit.py`가 `project/core|sim|world/**/*.gd`마다 `tests/sim/test_<이름>.gd`를 요구한다.
- CI(`.github/workflows/ci.yml`)는 `SE_REQUIRE_GODOT=1`로 돌아 Godot 없이는 실패한다.
