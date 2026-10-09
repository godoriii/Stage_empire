#!/usr/bin/env python3
"""git 명령 가드 hook (PreToolUse, matcher: Bash).

- `git commit`  → 커밋 전에 (1) JSON 테이블 스키마 검증, (2) 시뮬레이션 스크립트의 짝 테스트 존재 확인,
                  (3) Godot이 있으면 헤드리스 테스트. 하나라도 실패하면 exit 2로 커밋을 막는다.
- `git push`    → main/master 직접 push, --force/-f, --force-with-lease 를 막는다.
- 그 외 명령    → 통과.

사람이 직접 모는 메인 세션에서도 동일하게 적용된다(CI와 같은 기준). 급할 때 건너뛰려면
SE_SKIP_COMMIT_CHECKS=1 을 환경에 두되, CI는 그래도 돈다.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

SIM_DIRS = ("project/core/", "project/sim/", "project/world/")


def deny(msg: str) -> None:
    sys.stderr.write(msg.rstrip() + "\n")
    sys.exit(2)


def root_of(cwd: str) -> Path:
    p = Path(cwd).resolve()
    for cand in (p, *p.parents):
        if (cand / "CLAUDE.md").exists():
            return cand
    return p


def staged_files(root: Path) -> list[str]:
    r = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
        cwd=root, capture_output=True, text=True,
    )
    return [l.strip() for l in r.stdout.splitlines() if l.strip()]


def missing_tests(root: Path, files: list[str]) -> list[tuple[str, str]]:
    """시뮬레이션 .gd 파일마다 project/tests/sim/**/test_<basename>.gd 가 있어야 한다."""
    out = []
    tests_dir = root / "project" / "tests" / "sim"
    existing = {p.name for p in tests_dir.rglob("test_*.gd")} if tests_dir.exists() else set()
    for f in files:
        if not f.endswith(".gd") or not f.startswith(SIM_DIRS):
            continue
        base = Path(f).stem
        if base.startswith("_") or base.endswith(("_types", "_consts")):
            continue  # 순수 타입/상수 선언 파일은 예외
        want = f"test_{base}.gd"
        if want not in existing:
            out.append((f, f"project/tests/sim/{want}"))
    return out


def run(cmd: list[str], root: Path) -> tuple[int, str]:
    r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


def on_commit(root: Path) -> None:
    if os.environ.get("SE_SKIP_COMMIT_CHECKS") == "1":
        sys.stderr.write("[check_commit] SE_SKIP_COMMIT_CHECKS=1 → 검사 생략(CI는 그대로 돈다)\n")
        return
    problems: list[str] = []

    rc, out = run([sys.executable, "tools/validate_data.py"], root)
    if rc != 0:
        problems.append("JSON 테이블 스키마 검증 실패:\n" + out)

    files = staged_files(root)
    missing = missing_tests(root, files)
    if missing:
        lines = "\n".join(f"  {src}  →  {test} 필요" for src, test in missing)
        problems.append("헤드리스 테스트가 없는 시뮬레이션 스크립트가 있다(CLAUDE.md 경계 규칙):\n" + lines)

    if any(f.endswith(".gd") or f.startswith("project/data/") for f in files):
        rc, out = run(["tools/run_tests.sh", "--quick"], root)
        if rc != 0:
            problems.append("헤드리스 테스트 실패:\n" + out[-4000:])

    if problems:
        deny("[check_commit] 커밋을 막았다.\n\n" + "\n\n".join(problems))


def on_push(command: str) -> None:
    if re.search(r"\s(--force|-f|--force-with-lease)\b", command):
        deny("[check_commit] force push 금지 (CLAUDE.md). 머지 커밋으로 해결한다.")
    m = re.search(r"git\s+push\b(.*)$", command)
    tail = m.group(1) if m else ""
    if re.search(r"\b(main|master)\b", tail) and not re.search(r":\S*(main|master)", tail):
        # `git push origin main` 같이 main 을 직접 지정하는 경우
        deny("[check_commit] main 직접 push 금지. 브랜치에 push 하고 PR을 연다.")


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if payload.get("tool_name") != "Bash":
        return
    command = str((payload.get("tool_input") or {}).get("command", ""))
    root = root_of(payload.get("cwd") or os.getcwd())
    if re.search(r"\bgit\s+(-c\s+\S+\s+)*commit\b", command):
        on_commit(root)
    if re.search(r"\bgit\s+push\b", command):
        on_push(command)


if __name__ == "__main__":
    main()
