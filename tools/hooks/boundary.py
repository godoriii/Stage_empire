#!/usr/bin/env python3
"""에이전트 쓰기 경계 hook (PreToolUse).

각 서브에이전트의 frontmatter `hooks`에서 호출한다. stdin으로 Claude Code hook JSON을 받아
Write/Edit/MultiEdit/NotebookEdit의 대상 경로, 그리고 Bash 명령의 리다이렉션·sed -i·tee·mv·cp·rm
대상 경로가 허용 루트 밖이면 exit 2로 도구 호출을 막는다.

사용:
  .claude/settings.json 의 PreToolUse(Write|Edit|NotebookEdit|Bash) 에서 인자 없이 호출한다.
  hook 입력의 `agent_type`(서브에이전트 이름)으로 tools/hooks/boundary_policy.json 의 정책을 고른다.
  agent_type 이 없으면(사람이 직접 모는 메인 세션) 아무것도 막지 않는다.

  수동 검증:
  echo '{"tool_name":"Write","tool_input":{"file_path":"project/view/a.gd"},"agent_type":"sim-engineer"}' | python3 tools/hooks/boundary.py
  python3 tools/hooks/boundary.py --self-test

규칙 요약은 CLAUDE.md "책임 경계 규칙" 참고. 막혔다면 우회하지 말고 티켓을 producer에게 돌려보낸다.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from pathlib import Path

WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
PATH_KEYS = ("file_path", "notebook_path", "path")

# Bash 명령에서 "쓰기 대상"으로 간주하는 패턴
MUTATING_CMDS = {"rm", "mv", "cp", "tee", "touch", "mkdir", "rmdir", "truncate", "install", "ln"}
READONLY_BASH_ALLOW = re.compile(
    r"^\s*(git\s+(diff|log|show|status|blame|branch|rev-parse|ls-files|grep)\b"
    r"|cat\b|ls\b|head\b|tail\b|wc\b|grep\b|rg\b|find\b|tree\b|stat\b|file\b|diff\b"
    r"|python3?\s+(-I\s+)?tools/validate_data\.py\b"
    r"|tools/run_tests\.sh\b|echo\b|pwd\b|cd\b|which\b|env\b|true\b)"
)
# 어떤 에이전트도 쓰면 안 되는 경로 (사람 전용)
ALWAYS_PROTECTED = (
    ".claude/settings.json",
    ".claude/settings.local.json",
    ".claude/agents",
    "tools/hooks",
    "CLAUDE.md",
)


def repo_root(cwd: str) -> Path:
    p = Path(cwd).resolve()
    for cand in (p, *p.parents):
        if (cand / "CLAUDE.md").exists() and (cand / ".claude").is_dir():
            return cand
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    return Path(env).resolve() if env else p


def rel(path: str, root: Path, cwd: Path) -> str | None:
    """경로를 리포지토리 상대 경로로. 리포지토리 밖이면 None.

    git worktree 를 지원한다: 세션 cwd 의 리포지토리 밖이어도, 대상 경로에서 위로 올라가
    CLAUDE.md + .claude/ 가 있는 다른 체크아웃(같은 리포지토리의 worktree) 안이면 그 루트 기준으로 본다.
    """
    p = Path(path)
    if not p.is_absolute():
        p = cwd / p
    p = p.resolve()
    try:
        return p.relative_to(root).as_posix()
    except ValueError:
        pass
    other = repo_root(str(p.parent))
    if other != p.parent and (other / "CLAUDE.md").exists() and (other / ".claude").is_dir():
        try:
            return p.relative_to(other).as_posix()
        except ValueError:
            return None
    return None


def under(path: str, roots: list[str]) -> bool:
    for r in roots:
        r = r.strip("/")
        if path == r or path.startswith(r + "/"):
            return True
    return False


REDIRECT_TOKENS = {">", ">>", "&>", ">|", "&>>"}
SEG_SEPARATORS = {"|", "||", "&&", ";", "&", ";;"}


def _split_segments(head: str) -> list[list[str]]:
    """셸 문법을 인식해 명령 세그먼트(토큰 목록)로 나눈다.

    따옴표 안의 `|`·`;`·`>` 는 구분자나 리다이렉션이 아니다(예: `sed -i 's/a|b/c/' f`).
    파싱이 불가능한(따옴표 불균형) 명령은 보수적으로 공백 분리로 되돌아간다.
    """
    try:
        lex = shlex.shlex(head, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        toks = head.split()
    segs: list[list[str]] = [[]]
    for t in toks:
        if t in SEG_SEPARATORS:
            segs.append([])
        else:
            segs[-1].append(t)
    return [s for s in segs if s]


def _strip_heredoc(command: str) -> str:
    """히어독 본문을 떼고 명령 헤더만 남긴다.

    `cat <<EOF > path\\n...\\nEOF` → `cat  > path` (헤더 줄의 `<<EOF` 만 지우고 같은 줄 나머지는 유지).
    """
    m = re.search(r"<<-?\s*['\"]?\w+['\"]?", command)
    if not m:
        return command
    nl = command.find("\n", m.end())
    rest = command[m.end():] if nl < 0 else command[m.end():nl]
    return command[: m.start()] + " " + rest


def bash_targets(command: str) -> list[str]:
    """Bash 명령에서 쓰기 대상으로 보이는 경로를 뽑는다(보수적 휴리스틱).

    히어독(<<) 본문은 검사하지 않는다: 스크립트 안의 `>`·`>=` 를 리다이렉션으로 오인하지 않기 위해.
    히어독으로 파일을 쓰는 경우(`cat <<EOF > path`)는 헤더 줄의 `> path` 를 남기므로 여전히 잡힌다.
    """
    targets: list[str] = []
    head = _strip_heredoc(command)
    for raw in _split_segments(head):
        toks: list[str] = []
        # 리다이렉션: > file, >> file, 2> file, &> file (punctuation_chars 로 `>`·`>>`·`&>` 가 토큰이 된다)
        i = 0
        while i < len(raw):
            t = raw[i]
            if t in REDIRECT_TOKENS or (t.isdigit() and i + 1 < len(raw) and raw[i + 1] in REDIRECT_TOKENS):
                if t.isdigit():
                    i += 1
                if i + 1 < len(raw):
                    targets.append(raw[i + 1])
                i += 2
                continue
            if t in ("<", "<<<"):
                i += 2
                continue
            toks.append(t)
            i += 1
        if not toks:
            continue
        # sudo/env 접두어 제거
        cmd = toks[0]
        args = toks[1:]
        if cmd in ("sudo", "env", "nice", "nohup") and args:
            cmd, args = args[0], args[1:]
        base = os.path.basename(cmd)
        if base == "sed" and any(a == "-i" or a.startswith("-i") for a in args):
            targets += [a for a in args if not a.startswith("-") and not a.startswith(("s/", "s|", "s#"))]
        elif base in MUTATING_CMDS:
            targets += [a for a in args if not a.startswith("-")]
        elif base == "git":
            # git checkout -- file, git restore file, git rm, git mv 는 작업 트리를 바꾼다
            if args and args[0] in ("rm", "mv", "restore", "checkout", "clean", "reset"):
                targets += [a for a in args[1:] if not a.startswith("-")]
        elif base in ("python", "python3") and any(a.endswith(".py") for a in args):
            # 스크립트 자체는 판단 불가 → 통과. 결과는 Write 도구 사용을 권장.
            pass
    return targets


def deny(msg: str) -> None:
    sys.stderr.write(msg.rstrip() + "\n")
    sys.exit(2)


def check(payload: dict, allow: list[str], readonly: bool, agent: str) -> None:
    tool = payload.get("tool_name", "")
    tin = payload.get("tool_input", {}) or {}
    cwd = Path(payload.get("cwd") or os.getcwd()).resolve()
    root = repo_root(str(cwd))

    def judge(path: str, via: str) -> None:
        r = rel(path, root, cwd)
        if r is None:
            deny(f"[boundary:{agent}] 리포지토리 밖 경로에 쓸 수 없다: {path} ({via})")
        if under(r, list(ALWAYS_PROTECTED)):
            deny(f"[boundary:{agent}] 사람 전용 경로다: {r} ({via}). 변경이 필요하면 producer 티켓으로 요청.")
        if readonly and not under(r, allow):
            deny(
                f"[boundary:{agent}] 이 에이전트는 읽기 전용이다. 쓰기 시도: {r} ({via}).\n"
                f"허용: {', '.join(allow) or '(없음)'} (리뷰 코멘트 파일만)."
            )
        if not under(r, allow):
            deny(
                f"[boundary:{agent}] 쓰기 범위 밖: {r} ({via}).\n"
                f"허용 루트: {', '.join(allow) or '(없음)'}\n"
                "경계를 넘어야 하면 티켓을 분리해 producer에게 돌려보낸다 (CLAUDE.md 책임 경계 규칙)."
            )

    if tool in WRITE_TOOLS:
        for k in PATH_KEYS:
            if tin.get(k):
                judge(str(tin[k]), tool)
                return
        return

    if tool == "Bash":
        command = str(tin.get("command", ""))
        if readonly:
            segs = [s for s in re.split(r"\s*(?:&&|\|\||;)\s*", command) if s.strip()]
            for s in segs:
                first = s.split("|")[0]
                if not READONLY_BASH_ALLOW.match(first):
                    deny(
                        f"[boundary:{agent}] 읽기 전용 에이전트는 이 명령을 실행할 수 없다: {first.strip()}\n"
                        "허용: git diff/log/show/status/blame, cat, ls, grep, rg, find, head, tail, wc, "
                        "tools/validate_data.py, tools/run_tests.sh"
                    )
        for t in bash_targets(command):
            if t in ("/dev/null", "/dev/stderr", "/dev/stdout"):
                continue
            judge(t, "Bash")
        return


def self_test() -> None:
    cases = [
        ({"tool_name": "Write", "tool_input": {"file_path": "project/sim/economy.gd"}}, ["project/sim"], False, True),
        ({"tool_name": "Edit", "tool_input": {"file_path": "project/view/camera.gd"}}, ["project/sim"], False, False),
        ({"tool_name": "Write", "tool_input": {"file_path": "project/data/tiers/tiers.json"}}, ["project/sim"], False, False),
        ({"tool_name": "Write", "tool_input": {"file_path": ".claude/settings.json"}}, [".claude"], False, False),
        ({"tool_name": "Bash", "tool_input": {"command": "echo hi > project/ui/x.gd"}}, ["project/sim"], False, False),
        ({"tool_name": "Bash", "tool_input": {"command": "sed -i 's/a/b/' project/sim/a.gd"}}, ["project/sim"], False, True),
        ({"tool_name": "Bash", "tool_input": {"command": "git diff main"}}, [], True, True),
        ({"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}}, [], True, False),
        ({"tool_name": "Write", "tool_input": {"file_path": "project/sim/a.gd"}}, ["docs/reviews"], True, False),
        ({"tool_name": "Write", "tool_input": {"file_path": "docs/reviews/SE-1.md"}}, ["docs/reviews"], True, True),
        ({"tool_name": "Read", "tool_input": {"file_path": "project/view/camera.gd"}}, ["project/sim"], False, True),
        ({"tool_name": "Bash", "tool_input": {"command": "sed -i 's/^| SE-012 |.*/x/' docs/status/a.md"}}, ["docs/status"], False, True),
        ({"tool_name": "Bash", "tool_input": {"command": "grep -q 'a > b' x.md && echo ok"}}, ["docs/status"], False, True),
        ({"tool_name": "Bash", "tool_input": {"command": "grep x f | tee project/ui/x.gd"}}, ["project/sim"], False, False),
        ({"tool_name": "Bash", "tool_input": {"command": "echo hi 2> project/ui/err.log"}}, ["project/sim"], False, False),
        ({"tool_name": "Bash", "tool_input": {"command": "cat <<EOF > project/ui/x.gd\nx > y\nEOF"}}, ["project/sim"], False, False),
    ]
    root = str(Path(__file__).resolve().parents[2])
    failed = 0
    for payload, allow, ro, expect_ok in cases:
        payload = {**payload, "cwd": root}
        import subprocess

        args = [sys.executable, __file__, "--agent", "test"]
        args += ["--allow", *(allow or ["__none__"])]
        if ro:
            args.append("--readonly")
        p = subprocess.run(args, input=json.dumps(payload), capture_output=True, text=True)
        ok = p.returncode == 0
        mark = "PASS" if ok == expect_ok else "FAIL"
        if mark == "FAIL":
            failed += 1
        print(f"{mark} {payload['tool_name']:<6} {payload['tool_input']} allow={allow} ro={ro} -> rc={p.returncode}")
    print("self-test", "OK" if failed == 0 else f"FAILED ({failed})")
    sys.exit(1 if failed else 0)


def load_policy() -> dict:
    path = Path(__file__).with_name("boundary_policy.json")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # 정책 파일이 깨지면 전부 막는 쪽이 안전하다
        deny(f"[boundary] 정책 파일을 읽을 수 없다: {path}: {e}")
        return {}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", default=None, help="agent_type 대신 쓸 에이전트 이름(테스트용)")
    ap.add_argument("--allow", nargs="*", default=None, help="정책 파일 대신 쓸 허용 루트(테스트용)")
    ap.add_argument("--readonly", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # 파싱 불가 → 막지 않는다(hook 오류로 작업을 멈추지 않기 위해)

    agent = a.agent or payload.get("agent_type")
    if not agent:
        sys.exit(0)  # 메인 세션(사람) → 제한 없음
    if a.allow is not None or a.readonly:
        allow, readonly = [x for x in (a.allow or []) if x != "__none__"], a.readonly
    else:
        policy = load_policy().get("agents", {})
        rule = policy.get(agent)
        if rule is None:
            deny(f"[boundary] 정책에 없는 에이전트다: {agent}. tools/hooks/boundary_policy.json 에 등록해야 한다.")
            return
        allow, readonly = list(rule.get("allow", [])), bool(rule.get("readonly", False))
    check(payload, allow, readonly, agent)


if __name__ == "__main__":
    main()
