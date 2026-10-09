---
name: build
description: Godot 프로젝트를 헤드리스로 내보내 플레이 가능한 빌드를 만든다(Linux/Windows). producer 가 "플레이해볼 것" 보고 전에 사용. 사용 - /build [linux|windows]
---

# 빌드

```bash
GODOT="${GODOT_BIN:-godot}"
PRESET="${ARGUMENTS:-linux}"        # export_presets.cfg 의 프리셋 이름: linux | windows
mkdir -p build/$PRESET
"$GODOT" --headless --path project --export-release "$PRESET" "../build/$PRESET/stage_empire"
```

- `project/export_presets.cfg` 가 없으면 먼저 에디터에서 프리셋(Linux/X11, Windows Desktop)을 만들어야 한다. 사람에게 안내한다.
- 내보내기 템플릿이 없으면 Godot 버전에 맞는 템플릿 설치를 안내한다.
- 빌드 산출물은 커밋하지 않는다(`build/` 는 .gitignore).
- 성공하면 실행 경로와 빌드 시각, 커밋 해시를 `docs/status/` 의 "플레이해볼 것"에 적는다.
