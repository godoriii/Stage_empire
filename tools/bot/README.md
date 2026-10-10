# tools/bot — qa 도구

## play_bot.sh — 봇 플레이 통계 (SE-042)

"정책 3종 × 시드 N × 30일" 을 `GameSession` 헤드리스로 돌려 대리 지표(`docs/gdd/bot_metrics.md` M1~M12)를 낸다.
구성: `project/tests/e2e/bot_runner.gd`(SceneTree 러너) + `bot_play.gd`(한 판·통계, `class_name BotPlay`) · `tools/bot/policies/*.json`(정책, `targets.json` = 목표 범위·보정 기대값) · `bot_table.py`(결과 JSON → 표 + 안/밖).

```bash
tools/bot/play_bot.sh --policy frugal --seeds 100 --days 30        # 시드 1..100 을 코어 수만큼 프로세스로 나눠 돌리고 합쳐 results/SE-042.json 갱신
tools/bot/play_bot.sh --policy v0_replay --seed-start 36 --seeds 1 --days 30   # 보정(통계 표 밖). calibration.match 가 true 여야 한다
tools/bot/play_bot.sh --merge                                      # 부분 결과(results/parts, gitignore)만 다시 합침
python3 -I tools/bot/bot_table.py                                  # results/SE-042.json 표 출력
```

- 프로세스마다 `XDG_DATA_HOME` 을 따로 줘 `user://` 가 다른 GUT·봇 실행과 겹치지 않는다(`BOT_TMP` 아래 임시 디렉터리, 종료 시 삭제).
- 결과 파일은 결정적이다(실행 시간 없음). 같은 입력이면 프로세스 분할이 달라도 바이트 동일(`--merge` 가 시드 순서로 합친다).
- 실행 시간은 하루 약 1.2~2.3 초(관객 120명대, 다른 실행과 코어 경쟁 여부에 따라). 300판은 벽시계 1시간을 넘을 수 있어 SE-042 는 시드 30 으로 줄여 돌렸다(리포트 `docs/reports/SE-042.md`).
- 단위 테스트: `tools/run_tests.sh project/tests/e2e`.

## mutate_and_test.sh — 변이 확인 (SE-023)

"이 코드를 이렇게 망가뜨리면 테스트가 빨개지는가?"를 한 명령으로 확인한다.
`project/` 를 **리포지토리 밖 사본**으로 복사(문서를 읽는 테스트용으로 `docs/` 도 사본 옆에 읽기 전용으로 복사) → 패치 적용 → GUT 실행 → 사본 삭제(항상).
실제 `project/`·`docs/` 는 읽기만 하고, 리포지토리 안에는 임시 파일을 만들지 않는다. 사본 구조는 `<사본>/project/...` + `<사본>/docs/...` 이다
(테스트가 `res://../docs/gdd/*.md` 를 읽기 때문에 `docs/` 가 없으면 그 테스트가 Pending 이 되어 기준선이 `tools/run_tests.sh` 와 달라진다).

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
  **리포지토리 밖이어야 하고 `/` 가 아니어야 한다**(`SE_MUTATE_DIR`·`TMPDIR` 모두). 판정은 물리 경로(`cd -P`)로 한다:
  1. 경로 어디에든 `..` 성분이 있으면 exit 2 (심링크 뒤 `..` 는 글자 해석과 커널 해석이 달라 판정이 어긋난다).
  2. 디렉터리를 **만들기 전에**, 존재하는 가장 가까운 상위를 실경로로 풀고 아직 없는 꼬리를 붙여 리포지토리 안(또는 `/`)이면 exit 2. 이때 아무것도 만들지 않는다.
  3. 만든 뒤에 실경로 `$BASE` 를 한 번 더 검사하는 방어선이 있다. 리포지토리 안이면 **이번 실행이 새로 만든** 빈 디렉터리를 `rmdir` 로 정리하고 exit 2 (기존 디렉터리는 건드리지 않는다).
  4. 어느 단계든 `cd` 가 실패하면(권한 없음 등) exit 2.
- `GODOT_BIN`: Godot 바이너리. 없으면 PATH 의 `godot`/`godot4` (`tools/run_tests.sh` 와 같은 규칙).

### 종료 코드

| 코드 | 뜻 |
|---|---|
| 0 | GUT 전부 통과. 패치가 있으면 **변이를 테스트가 못 잡았다**는 뜻, 빈 패치면 기준선이 녹색이라는 뜻 |
| GUT 의 코드 (보통 1) | 테스트 실패 = **변이가 잡혔다**. 마지막에 요약(`Tests/Passing/Failing`)과 실패한 테스트 이름을 다시 출력한다 |
| 2 | 사용법 오류: 인자 없음, 알 수 없는 옵션, 인자 초과(패치·`tests_subdir` 뒤의 위치 인자), `tests_subdir` 가 절대 경로이거나 `..` 포함, 패치/테스트 디렉터리 없음, 사본 상위 디렉터리(`SE_MUTATE_DIR`/`TMPDIR`)가 리포지토리 안이거나 `/` 이거나, 경로에 `..` 성분이 있거나, `cd` 로 이동할 수 없음 |
| 3 | 패치 적용 불가 (`patch -p1 --dry-run` 실패, 출력 포함). GUT 는 실행하지 않는다 |
| 4 | Godot 바이너리 없음 |
| 5 | 내부 오류 (리포지토리 루트 계산 실패, 사본·`docs/` 복사 실패, GUT 애드온 없음, `mkdir`/`mktemp` 실패) |

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

### SE-030 데이터 변이 (`se030_*.py`)

show·reputation·genres JSON 을 한 군데씩 틀리게 한 변이 21건(m01~m21)으로 "데이터 검증과 테스트가 잡는가"를 본다.
패치(`se030_mNN_*.diff`)는 생성기가 실행마다 다시 쓰는 산출물이고 데이터가 바뀌면 낡으므로 **저장소에 두지 않는다**(SE-048). 재생성:

```bash
python3 -I tools/bot/se030_json_mutants.py [--write-only] [--out DIR]   # 패치를 리포 밖 DIR(기본: 새 임시 디렉터리, 경로 출력)에 쓰고 validate --strict 검출 표를 낸다. DIR 이 리포 안이면 exit 2
```

그다음 `tools/bot/mutate_and_test.sh <DIR>/se030_m18_good_base_23.diff tests/sim` 처럼 GUT 열을 돌린다. 나머지 둘: `se030_formula_mutants.py`(공식 변이 14건, 읽기 전용 표 출력), `se030_hand_calc.py`(독립 손계산 `HAND OK`).

### 주의

boundary hook 이 qa/reviewer 의 `project/sim|core|world` 쓰기를 막는 것은 정상이다. 이 스크립트는 그 우회가 아니라 **사본** 검증이며, 실제 `project/` 에는 쓰지 않는다.
`rm -rf` 는 `mktemp` 가 만든 `se_mutate.*` 사본에만, 실경로가 `<사본 상위 디렉터리의 실경로>/se_mutate.*` 일 때만 실행한다(상위 디렉터리는 사본 생성 전에 물리 경로로 리포지토리 밖임을 확인하고, 만든 뒤 실경로로 다시 확인한다).
사본의 `docs/` 는 읽기 전용(`a-w`)이다. 삭제 직전에 스크립트가 `chmod -R u+w` 로 풀어 지운다. `--keep` 으로 남긴 사본은 직접 지운다(비 root 면 `chmod -R u+w <사본> && rm -rf <사본>`).

요약의 "실패한 테스트" 는 GUT Run Summary 항목 중 `[Failed]` 가 있는 것만 센다. Pending/Risky 만 있는 항목은 "Pending/Risky 테스트(실패 아님)" 로 따로 표시한다(기준선에서는 0건이어야 한다).

### 스크립트 자체 테스트 방법

SE-023 AC1~AC5 를 그대로 돌린다. 합격 기준:

1. 빈 패치 → exit 0, 요약(Scripts/Tests/Passing/Asserts)이 `tools/run_tests.sh project/tests/sim` 과 같고 Pending 0, "실패한 테스트" 0건.
2. 예시 패치 2개 → exit ≠ 0, 실패 테스트가 위 표의 건수와 같다(se016 2건, se015 1건).
3. 실행 전후 `git status --short` 동일, `ls /tmp | grep se_mutate`(또는 `$SE_MUTATE_DIR`/`$TMPDIR`) 비어 있음, 경고 출력 없음. `--keep` 이면 경로가 출력되고 남는다.
4. 사본 상위 경로: 심링크 뒤 `..`(`/tmp/L/../x`, 심링크 안에서 상대 `../x`), `SE_MUTATE_DIR=/`, 권한 없는 디렉터리 → 전부 exit 2, 리포지토리 안에 새 디렉터리 0.
5. 적용 불가 패치 → exit 3 + `patch` 출력, 사본 삭제. `GODOT_BIN=/nonexistent` → exit 4.
6. `tests/view` 인자 → 사본에서 view 테스트가 돌고 exit 0.
