#!/usr/bin/env bash
# SE-023 변이 확인 스크립트: 사본 생성 -> 패치 적용 -> GUT 실행 -> 사본 삭제(항상).
#
#   tools/bot/mutate_and_test.sh <patch.diff> [tests_subdir] [--keep]
#
# 실제 project/ 와 docs/ 는 읽기만 한다. 리포지토리 안에는 어떤 파일도 만들지 않는다.
# 사본은 리포지토리 밖($SE_MUTATE_DIR, 없으면 $TMPDIR, 없으면 /tmp 아래 mktemp -d)에
# <사본>/project/... 와 <사본>/docs/... (읽기 전용, 문서를 읽는 테스트용) 구조로 만든다.
# 사본 상위 디렉터리 판정은 물리 경로(cd -P) 기준이다:
#   - 경로 어디에든 '..' 성분이 있으면 exit 2 (심링크 뒤 '..' 로 판정을 속이지 못하게).
#   - 만들기 전에: 존재하는 가장 가까운 상위를 물리 경로로 풀어 붙인 결과가 리포지토리 안이거나 '/' 이면 exit 2.
#   - 만든 뒤에: 실경로 $BASE 를 다시 검사해 리포지토리 안이면 이번에 만든 빈 디렉터리를 정리하고 exit 2 (방어선).
#   - 어느 단계든 cd 가 실패하면 exit 2.
# 이 스크립트는 boundary hook 의 우회가 아니라 "사본" 검증이다. 자세한 규칙은 tools/bot/README.md.
#
# 종료 코드: 0 = GUT 통과(변이를 못 잡음 / 패치 없음 확인),  GUT 가 돌려준 코드(!=0) = 변이가 잡힘,
#            2 = 사용법 오류,  3 = 패치 적용 불가,  4 = Godot 없음,  5 = 그 밖의 내부 오류
set -uo pipefail

ROOT="$(cd -P "$(dirname "$0")/../.." && pwd -P)" || { echo "FAIL: 리포지토리 루트를 찾을 수 없다" >&2; exit 5; }
SRC="$ROOT/project"

usage() {
  echo "사용법: tools/bot/mutate_and_test.sh <patch.diff> [tests_subdir=tests/sim] [--keep]" >&2
  exit 2
}

PATCH=""
SUBDIR=""
KEEP=0
for a in "$@"; do
  case "$a" in
    --keep) KEEP=1 ;;
    -h|--help) usage ;;
    -*) echo "알 수 없는 옵션: $a" >&2; usage ;;
    *)
      if [ -z "$PATCH" ]; then PATCH="$a"
      elif [ -z "$SUBDIR" ]; then SUBDIR="${a#project/}"
      else usage; fi ;;
  esac
done
[ -n "$PATCH" ] || usage
SUBDIR="${SUBDIR:-tests/sim}"
SUBDIR="${SUBDIR%/}"
case "$SUBDIR" in
  /*|*..*) echo "tests_subdir 는 project/ 기준 상대 경로여야 한다: $SUBDIR" >&2; exit 2 ;;
esac
if [ ! -f "$PATCH" ]; then echo "패치 파일 없음: $PATCH" >&2; exit 2; fi
PATCH_ABS="$(cd "$(dirname "$PATCH")" && pwd -P)/$(basename "$PATCH")"

GODOT="${GODOT_BIN:-$(command -v godot || command -v godot4 || true)}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "FAIL: Godot 바이너리를 찾을 수 없다 (GODOT_BIN 설정 필요: '${GODOT}')" >&2
  exit 4
fi
if [ ! -f "$SRC/addons/gut/gut_cmdln.gd" ]; then
  echo "FAIL: project/addons/gut 없음 (docs/adr/0003-test-framework-gut.md)" >&2
  exit 5
fi
if [ ! -d "$SRC/$SUBDIR" ]; then
  echo "FAIL: 테스트 디렉터리 없음: project/$SUBDIR" >&2
  exit 2
fi

# --- 사본 디렉터리 (리포지토리 밖) -------------------------------------------------
BASE="${SE_MUTATE_DIR:-${TMPDIR:-/tmp}}"
# 리포지토리 안(또는 그 자체)이면 디렉터리를 만들기 전에 거부한다: 삭제 가드가 리포지토리 안 사본을 지우지 않으므로
# untracked 잔여가 남는다. 판정은 전부 물리 경로(cd -P / pwd -P)로 한다.
# 1) '..' 성분 거부: 'L/../x' 는 L 이 심링크면 논리(글자) 해석과 커널(물리) 해석이 달라 판정과 mkdir 이 어긋난다.
case "/$BASE/" in
  */../*) echo "사본 상위 디렉터리에 '..' 를 쓸 수 없다 (SE_MUTATE_DIR/TMPDIR): $BASE" >&2; exit 2 ;;
esac
# 2) 아직 없는 꼬리 경로까지 판정: 존재하는 가장 가까운 상위(EXIST_PRE, 물리 경로)와 없는 꼬리(REST_PRE)를 나눈다.
resolve_no_create() {
  local p="$1" rest="" r
  case "$p" in /*) ;; *) p="$(pwd -P)/$p" || return 1 ;; esac
  while [ ! -d "$p" ]; do
    rest="/$(basename "$p")$rest"
    p="$(dirname "$p")"
  done
  r="$(cd -P "$p" && pwd -P)" || return 1
  [ -n "$r" ] || return 1
  EXIST_PRE="$r"
  REST_PRE="$rest"
  BASE_PRE="${r%/}$rest"
  [ -n "$BASE_PRE" ] || BASE_PRE="/"
}
EXIST_PRE=""; REST_PRE=""; BASE_PRE=""
resolve_no_create "$BASE" || { echo "사본 상위 디렉터리로 이동할 수 없다 (cd 실패, SE_MUTATE_DIR/TMPDIR): $BASE" >&2; exit 2; }
if [ "$BASE_PRE" = "/" ]; then
  echo "사본 상위 디렉터리가 '/' 일 수 없다 (SE_MUTATE_DIR/TMPDIR): $BASE" >&2
  exit 2
fi
case "$BASE_PRE" in
  "$ROOT"|"$ROOT"/*)
    echo "사본 상위 디렉터리는 리포지토리 밖이어야 한다 (SE_MUTATE_DIR/TMPDIR): $BASE_PRE" >&2
    exit 2 ;;
esac
mkdir -p -- "$BASE_PRE" || exit 5
# 3) 사후 검사(방어선): 만든 뒤의 실경로가 리포지토리 안이거나 '/' 이면 이번에 만든 빈 디렉터리를 정리하고 거부한다.
undo_created_dirs() {
  local d="$EXIST_PRE" c rest="$REST_PRE" list=() parts=() i
  rest="${rest#/}"
  [ -n "$rest" ] || return 0
  # '/' 로 나눌 때 pathname expansion(glob)이 일어나면 꼬리 성분의 *?[ 가 현재 디렉터리의 다른 이름으로 풀려
  # 이미 있던 빈 디렉터리를 rmdir 할 수 있다 (SE-047 리뷰 [낮음] 1). read -r -a 는 glob 을 하지 않는다.
  IFS=/ read -r -a parts <<< "$rest"
  for c in "${parts[@]}"; do d="${d%/}/$c"; list+=("$d"); done
  for ((i=${#list[@]}-1; i>=0; i--)); do rmdir -- "${list[$i]}" 2>/dev/null || true; done
}
BASE="$(cd -P "$BASE_PRE" && pwd -P)" || { undo_created_dirs; echo "사본 상위 디렉터리로 이동할 수 없다 (cd 실패): $BASE_PRE" >&2; exit 2; }
if [ -z "$BASE" ] || [ "$BASE" = "/" ]; then
  undo_created_dirs
  echo "사본 상위 디렉터리의 실경로가 비었거나 '/' 이다: '$BASE'" >&2
  exit 2
fi
case "$BASE" in
  "$ROOT"|"$ROOT"/*)
    undo_created_dirs
    echo "사본 상위 디렉터리의 실경로가 리포지토리 안이다 (SE_MUTATE_DIR/TMPDIR): $BASE" >&2
    exit 2 ;;
esac
WORK="$(mktemp -d -p "$BASE" se_mutate.XXXXXX)" || exit 5

# rm -rf 는 mktemp 가 만든 사본 디렉터리에만 쓴다: 비어 있지 않음 + 디렉터리 + 실경로가 "$BASE"/se_mutate.?* 일 때만
# ($BASE 는 위에서 실경로로 만들었고 리포지토리 밖임을 확인했다. 이름 조건도 이 패턴에 포함된다).
safe_remove_work() {
  local w="${WORK:-}"
  [ -n "$w" ] || return 0
  [ -d "$w" ] || return 0
  w="$(cd "$w" && pwd -P)" || return 0
  local ok=0
  case "$w" in "$BASE"/se_mutate.?*) ok=1 ;; esac
  if [ $ok -ne 1 ]; then echo "경고: 예상 밖 경로라 삭제하지 않는다: $w (기대: $BASE/se_mutate.*)" >&2; return 0; fi
  chmod -R u+w -- "$w" 2>/dev/null || true   # 사본 docs/ 는 읽기 전용이라 먼저 쓰기 권한을 돌려준다
  rm -rf -- "$w"
}

cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "[mutate] --keep: 사본을 남긴다: $WORK"
  else
    safe_remove_work
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- 사본 생성: project/ 에서 .godot/ 만 제외 ---------------------------------------
mkdir -p "$WORK/project" || exit 5
if ! tar -C "$SRC" --exclude=./.godot -cf - . | tar -C "$WORK/project" -xf -; then
  echo "FAIL: project/ 사본 생성 실패" >&2; exit 5
fi

# 문서를 읽는 테스트(res://../docs/...)용으로 docs/ 를 사본 옆(<사본>/docs)에 읽기 전용으로 복사한다.
# 패치는 project/ 만 대상이다(docs/ 는 변이 대상이 아니므로 복사 직후 잠근다).
if [ -d "$ROOT/docs" ]; then
  mkdir -p "$WORK/docs" || exit 5
  if ! tar -C "$ROOT/docs" -cf - . | tar -C "$WORK/docs" -xf -; then
    echo "FAIL: docs/ 사본 생성 실패" >&2; exit 5
  fi
  chmod -R a-w "$WORK/docs" || exit 5
fi

# --- 패치 ---------------------------------------------------------------------------
if [ -s "$PATCH_ABS" ]; then
  if ! OUT="$(cd "$WORK" && patch -p1 --dry-run --no-backup-if-mismatch < "$PATCH_ABS" 2>&1)"; then
    echo "$OUT"
    echo "[mutate] FAIL: 패치를 적용할 수 없다 (exit 3). GUT 는 실행하지 않는다." >&2
    exit 3
  fi
  if ! OUT="$(cd "$WORK" && patch -p1 --no-backup-if-mismatch < "$PATCH_ABS" 2>&1)"; then
    echo "$OUT"
    echo "[mutate] FAIL: 패치 적용 중 실패 (exit 3)." >&2
    exit 3
  fi
  echo "$OUT"
else
  echo "[mutate] 빈 패치: 변이 없이 사본을 그대로 실행한다."
fi

# --- GUT ----------------------------------------------------------------------------
echo "[mutate] 사본: $WORK  tests: project/$SUBDIR  godot: $GODOT"
"$GODOT" --headless --path "$WORK/project" --import >/dev/null 2>&1 || true

LOG="$WORK/gut.log"
"$GODOT" --headless --path "$WORK/project" -s addons/gut/gut_cmdln.gd \
  -gdir="res://$SUBDIR" -ginclude_subdirs -gexit -glog=1 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"

# --- 요약 다시 출력 -------------------------------------------------------------------
ESC="$(printf '\033')"
CLEAN="$(sed "s/${ESC}\[[0-9;]*m//g" "$LOG")"
echo
echo "[mutate] ===== 요약 (patch: $(basename "$PATCH_ABS"), tests: project/$SUBDIR, exit: $RC) ====="
echo "$CLEAN" | grep -E '^(Scripts|Tests|Passing Tests|Failing Tests|Risky/Pending|Asserts) ' || true
# Run Summary 의 "res://<스크립트>" 줄 아래 "- <테스트명>" 항목은 통과하지 못한 테스트 전부다(실패 + Pending + Risky).
# 항목 아래에 "[Failed]" 줄이 하나라도 있으면 "실패한 테스트", 없으면(Pending/Risky 뿐) "Pending/Risky"로 따로 센다.
CLASSIFIED="$(echo "$CLEAN" | awk '
  function flush() { if (cur) print kind "\t" file " :: " name; cur = 0 }
  /= Run Summary/ { s = 1; next }
  !s { next }
  /^res:\/\// { flush(); f = $0; next }
  /^Totals/ { flush(); next }
  /^- / { flush(); cur = 1; kind = "P"; file = f; name = $0; sub(/^- /, "", name); next }
  cur && /^[ \t]+\[Failed\]/ { kind = "F" }
  END { flush() }')"
FAILED="$(echo "$CLASSIFIED" | awk -F'\t' '$1=="F"{print $2}')"
PENDING="$(echo "$CLASSIFIED" | awk -F'\t' '$1=="P"{print $2}')"
if [ -n "$FAILED" ]; then
  echo "[mutate] 실패한 테스트($(echo "$FAILED" | wc -l | tr -d ' ')건):"
  echo "$FAILED" | sed 's/^/  - /'
fi
if [ -n "$PENDING" ]; then
  echo "[mutate] Pending/Risky 테스트($(echo "$PENDING" | wc -l | tr -d ' ')건, 실패 아님):"
  echo "$PENDING" | sed 's/^/  - /'
fi
if [ "$RC" -eq 0 ]; then
  echo "[mutate] 결과: 전부 통과 (변이가 없거나 테스트가 변이를 못 잡았다)"
else
  echo "[mutate] 결과: 실패 있음 (변이가 잡혔다)"
fi
exit "$RC"
