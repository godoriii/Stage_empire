# ADR-0003 테스트 프레임워크는 GUT

- 날짜: 2026-10-09
- 상태: 결정 (에이전트 셋업 시점의 선택, 프리프로덕션 중 재검토 가능). 2026-10-09 GUT 9.6.1 + Godot 4.6 으로 설치 완료.

## 결정

GUT 9.6.1(Godot Unit Test, `project/addons/gut`, MIT, Godot 4.6 대응)을 리포지토리에 포함해 쓴다. 실행은 `tools/run_tests.sh`가 `godot --headless -s addons/gut/gut_cmdln.gd`로 한다. 테스트 파일은 `project/tests/sim|view|e2e/**/test_*.gd` (Godot 은 `res://` 밖의 스크립트를 로드하지 못하므로 프로젝트 안에 둔다).

## 이유

- GDScript 네이티브, 헤드리스 CLI 실행과 exit code 지원, 에이전트가 예제를 많이 알고 있어 테스트 작성 비용이 낮다.
- 대안 gdUnit4는 C# 쪽 지원이 좋지만 셋업이 더 무겁다. C# 비중이 커지면 재검토한다.

## 설치

```bash
# 이미 포함되어 있다: project/addons/gut (v9.6.1). 업그레이드는 Godot 버전과 짝을 맞춰 같은 PR에서 한다.
# Godot 4.6 바이너리를 GODOT_BIN 또는 PATH 의 godot 으로 두면 tools/run_tests.sh 가 실행된다.
tools/run_tests.sh
```

## 결과

- `tools/hooks/check_commit.py`가 `project/core|sim|world/**/*.gd`마다 `project/tests/sim/test_<이름>.gd`를 요구한다.
- CI(`.github/workflows/ci.yml`)는 `SE_REQUIRE_GODOT=1`로 돌아 Godot 없이는 실패한다.
