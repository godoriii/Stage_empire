# tools/bot — qa 도구

## mutate_and_test.sh — 변이 확인 (SE-023)

"이 코드를 이렇게 망가뜨리면 테스트가 빨개지는가?"를 한 명령으로 확인한다.
`project/` 를 **리포지토리 밖 사본**으로 복사 → 패치 적용 → GUT 실행 → 사본 삭제(항상). 실제 `project/` 는 읽기만 하고,
리포지토리 안에는 임시 파일을 만들지 않는다.

```bash
tools/bot/mutate_and_test.sh <patch.diff> [tests_subdir=tests/sim] [--keep]
```

| 인자 | 설명 |
|---|---|
| `patch.diff` | 리포지토리 루트 기준 unified diff (`a/project/...` → `b/project/...`). 0 바이트 파일이면 "패치 없음" 기준선 실행(`#` 주석만 있는 파일은 빈 패치가 아니다 — 패치 규칙 참고) |
| `tests_subdir` | `project/` 기준 테스트 디렉터리. 기본 `tests/sim`, 뷰는 `tests/view` (`project/tests/sim` 처럼 `project/` 접두어를 붙여도 된다) |
| `--keep` | 사본을 지우지 않고 경로를 출력한다 (디버깅용. 직접 지워야 한다) |

환경 변수

- `SE_MUTATE_DIR`: 사본을 만들 상위 디렉터리. 없으면 `$TMPDIR` 또는 `/tmp` 아래 `mktemp -d`. 사본 이름은 `se_mutate.XXXXXX`.
  **리포지토리 밖이어야 한다**(`SE_MUTATE_DIR`·`TMPDIR` 모두). 리포지토리 안이면 디렉터리·사본을 만들기 전에 exit 2.
- `GODOT_BIN`: Godot 바이너리. 없으면 PATH 의 `godot`/`godot4` (`tools/run_tests.sh` 와 같은 규칙).

### 종료 코드

| 코드 | 뜻 |
|---|---|
| 0 | GUT 전부 통과. 패치가 있으면 **변이를 테스트가 못 잡았다**는 뜻, 빈 패치면 기준선이 녹색이라는 뜻 |
| GUT 의 코드 (보통 1) | 테스트 실패 = **변이가 잡혔다**. 마지막에 요약(`Tests/Passing/Failing`)과 실패한 테스트 이름을 다시 출력한다 |
| 2 | 사용법 오류: 인자 없음, 알 수 없는 옵션, 인자 초과(패치·`tests_subdir` 뒤의 위치 인자), `tests_subdir` 가 절대 경로이거나 `..` 포함, 패치/테스트 디렉터리 없음, 사본 상위 디렉터리(`SE_MUTATE_DIR`/`TMPDIR`)가 리포지토리 안이거나, 아직 없는 경로 중간에 `..` 가 있어 위치를 판정할 수 없음 |
| 3 | 패치 적용 불가 (`patch -p1 --dry-run` 실패, 출력 포함). GUT 는 실행하지 않는다 |
| 4 | Godot 바이너리 없음 |
| 5 | 내부 오류 (사본 생성 실패, GUT 애드온 없음) |

### 패치 규칙

- 경로는 `a/project/...` → `b/project/...` 뿐이다(`git diff` 출력 그대로, `patch -p1` 을 사본 루트에서 실행). 다른 경로 규칙은 지원하지 않는다.
- 패치 파일 맨 앞에 `#` 주석 줄을 두어도 된다(`patch` 가 diff 시작 전의 잡글을 무시한다). `mutations/` 의 예시는 머리에 기대 결과를 적어 두었다.
- **빈 패치 = 0 바이트 파일뿐이다.** `#` 주석(또는 hunk 없는 잡글)만 있는 파일은 빈 패치로 보지 않는다: `patch` 가 "Only garbage was found" 로 실패해 exit 3 이 된다(잘못된 파일이 조용히 기준선 exit 0 으로 둔갑하지 않게 하려는 것). 기준선은 `: > empty.diff` 로 만든다.
- 실제 트리를 고치지 않고 패치를 만드는 법: 사본에서 고친 뒤 `git diff --no-index` 로 만든다. 디렉터리 이름을 `a/`(원본)·`b/`(변이본)로 두고 접두어를 끄면 경로가 `a/project/...` → `b/project/...` 로 맞는다: `cd <작업폴더> && git diff --no-index --no-prefix a/project/sim/x.gd b/project/sim/x.gd > x.diff` (`--src-prefix=a/ --dst-prefix=b/` 는 기본값과 같아 `a/a/project/...` 가 되므로 쓰지 않는다. `--src-prefix= --dst-prefix=` 도 `--no-prefix` 와 같은 결과다). 또는 손으로 unified diff 를 쓴다
  (qa 는 `project/sim` 을 못 쓰므로 스크래치 디렉터리에서 `difflib.unified_diff` 로 만들어도 된다. `mutations/` 의 두 파일이 그렇게 만들어졌다).
  사람/엔지니어는 자기 브랜치에서 `git diff > x.diff` 후 `git checkout -- .` 로 되돌려도 된다.
- 소스가 바뀌어 hunk 가 안 맞으면 exit 3 이다. 예시 패치는 해당 시점의 `main` 기준이므로 대상 함수가 바뀌면 다시 만들어야 한다.

### 예시 (`mutations/`)

| 패치 | 변이 | 기대 (tests/sim) |
|---|---|---|
| `mutations/se016_bankrupt_order.diff` | SE-016 순서 되돌리기: `_on_phase_changed`·`_on_day_started` 의 `if bankrupt: return` 을 맨 앞으로 | 실패 정확히 2건 `test_bankrupt_after_bailouts_exhausted`, `test_bankrupt_restore_keeps_pending_bailout`(후자는 SE-022 테스트라 SE-023 때도 걸렸어야 하나 기록이 1건이었다 — SE-044 QA 에서 origin/main 에서도 2건임을 확인) |
| `mutations/se015_range_check_6_off.diff` | SE-015 ⑥ 검사(`loans[].paid` 범위)를 `if false:` 로 | 실패 정확히 1건 `test_restore_rejects_out_of_range` |

```bash
tools/bot/mutate_and_test.sh tools/bot/mutations/se016_bankrupt_order.diff          # exit 1, 실패 2건이 잡힘
tools/bot/mutate_and_test.sh tools/bot/mutations/se015_range_check_6_off.diff
: > /tmp/empty.diff && tools/bot/mutate_and_test.sh /tmp/empty.diff                 # exit 0 (기준선)
tools/bot/mutate_and_test.sh /tmp/empty.diff tests/view                             # view 85+ 사본 실행
```

### 주의

boundary hook 이 qa/reviewer 의 `project/sim|core|world` 쓰기를 막는 것은 정상이다. 이 스크립트는 그 우회가 아니라 **사본** 검증이며, 실제 `project/` 에는 쓰지 않는다.
`rm -rf` 는 `mktemp` 가 만든 `se_mutate.*` 사본에만, 실경로가 `<사본 상위 디렉터리의 실경로>/se_mutate.*` 일 때만 실행한다(상위 디렉터리는 리포지토리 밖임을 사본 생성 전에 확인한다). `--keep` 으로 남긴 사본은 직접 지운다.

### 스크립트 자체 테스트 방법

SE-023 AC1~AC5 를 그대로 돌린다. 합격 기준:

1. 빈 패치 → exit 0, 요약이 `tools/run_tests.sh project/tests/sim` 과 같다.
2. 예시 패치 2개 → exit ≠ 0, 실패 테스트가 각각 위 표의 1건뿐.
3. 실행 전후 `git status --short` 동일, `ls /tmp | grep se_mutate`(또는 `$SE_MUTATE_DIR`/`$TMPDIR`) 비어 있음, 경고 출력 없음. `--keep` 이면 경로가 출력되고 남는다.
4. 적용 불가 패치 → exit 3 + `patch` 출력, 사본 삭제. `GODOT_BIN=/nonexistent` → exit 4.
5. `tests/view` 인자 → 사본에서 view 테스트가 돌고 exit 0.
