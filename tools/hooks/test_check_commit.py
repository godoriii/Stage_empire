#!/usr/bin/env python3
"""check_commit.py 자체 테스트. 리포지토리 루트에서 `python3 tools/hooks/test_check_commit.py`."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "tools" / "hooks" / "check_commit.py"


def run(command: str) -> tuple[int, str]:
    payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(ROOT)}
    p = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload), capture_output=True, text=True)
    return p.returncode, p.stderr.strip()


def git(*args: str) -> None:
    subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True)


def main() -> int:
    failed = 0
    push_cases = [
        ("git push " + "--force origin x", 2),
        ("git push " + "-f origin x", 2),
        ("git push origin " + "main", 2),
        ("git push -u origin feature/SE-001-tick", 0),
        ("git status", 0),
    ]
    for cmd, want in push_cases:
        rc, err = run(cmd)
        ok = rc == want
        failed += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} rc={rc} want={want}  {cmd}")

    # 짝 테스트 없는 시뮬레이션 스크립트를 스테이징하면 커밋이 막혀야 한다
    tmp = ROOT / "project" / "sim" / "zz_hooktest.gd"
    tmp.write_text("class_name ZzHookTest\n", encoding="utf-8")
    try:
        git("add", str(tmp.relative_to(ROOT)))
        rc, err = run("git commit -m test")
        ok = rc == 2 and "test_zz_hooktest.gd" in err
        failed += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} rc={rc} want=2  commit with untested sim script\n   {err.splitlines()[-1] if err else ''}")
    finally:
        git("rm", "-q", "--cached", str(tmp.relative_to(ROOT)))
        tmp.unlink(missing_ok=True)

    # 스테이징이 깨끗하면(데이터 검증 통과) 커밋이 허용되어야 한다
    rc, err = run("git commit -m test")
    ok = rc == 0
    failed += 0 if ok else 1
    print(f"{'PASS' if ok else 'FAIL'} rc={rc} want=0  clean commit\n   {err}")

    print("check_commit self-test", "OK" if failed == 0 else f"FAILED ({failed})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
