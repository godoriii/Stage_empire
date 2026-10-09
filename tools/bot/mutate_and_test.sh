#!/usr/bin/env bash
# SE-023 변이 확인 스크립트: 사본 생성 -> 패치 적용 -> GUT 실행 -> 사본 삭제(항상).
#
#   tools/bot/mutate_and_test.sh <patch.diff> [tests_subdir] [--keep]
#
# 실제 project/ 는 읽기만 한다. 리포지토리 안에는 어떤 파일도 만들지 않는다.
# 사본은 리포지토리 밖($SE_MUTATE_DIR 아래 또는 mktemp -d)에 <사본>/project/... 구조로 만든다.
# 이 스크립트는 boundary hook 의 우회가 아니라 "사본" 검증이다. 자세한 규칙은 tools/bot/README.md.
#
# 종료 코드: 0 = GUT 통과(변이를 못 잡음 / 패치 없음 확인),  GUT 가 돌려준 코드(!=0) = 변이가 잡힘,
#            2 = 사용법 오류,  3 = 패치 적용 불가,  4 = Godot 없음,  5 = 그 밖의 내부 오류
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
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
mkdir -p "$BASE" || exit 5
BASE="$(cd "$BASE" && pwd -P)"
WORK="$(mktemp -d -p "$BASE" se_mutate.XXXXXX)" || exit 5

# rm -rf 는 mktemp 가 만든 사본 디렉터리에만 쓴다: 비어 있지 않음 + 절대 경로 + 이름 접두어 + /tmp 또는
# SE_MUTATE_DIR 아래 + 리포지토리 바깥 일 때만.
safe_remove_work() {
  local w="${WORK:-}"
  [ -n "$w" ] || return 0
  [ -d "$w" ] || return 0
  w="$(cd "$w" && pwd -P)" || return 0
  case "$w" in
    "$ROOT"|"$ROOT"/*) echo "경고: 사본이 리포지토리 안이라 삭제하지 않는다: $w" >&2; return 0 ;;
  esac
  case "$(basename "$w")" in se_mutate.?*) ;; *) echo "경고: 예상 밖 이름이라 삭제하지 않는다: $w" >&2; return 0 ;; esac
  local ok=0
  case "$w" in /tmp/?*) ok=1 ;; esac
  if [ -n "${SE_MUTATE_DIR:-}" ]; then
    local sb; sb="$(cd "$SE_MUTATE_DIR" 2>/dev/null && pwd -P)" || sb=""
    if [ -n "$sb" ]; then case "$w" in "$sb"/?*) ok=1 ;; esac; fi
  fi
  if [ $ok -ne 1 ]; then echo "경고: /tmp 또는 SE_MUTATE_DIR 밖이라 삭제하지 않는다: $w" >&2; return 0; fi
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
# 실패한 테스트 이름: Run Summary 의 "res://<스크립트>" 줄 아래 "- <테스트명>" 줄
FAILED="$(echo "$CLEAN" | awk '/= Run Summary/{s=1} s && /^res:\/\//{f=$0} s && /^- /{sub(/^- /,""); print f " :: " $0}')"
if [ -n "$FAILED" ]; then
  echo "[mutate] 실패한 테스트($(echo "$FAILED" | wc -l | tr -d ' ')건):"
  echo "$FAILED" | sed 's/^/  - /'
fi
if [ "$RC" -eq 0 ]; then
  echo "[mutate] 결과: 전부 통과 (변이가 없거나 테스트가 변이를 못 잡았다)"
else
  echo "[mutate] 결과: 실패 있음 (변이가 잡혔다)"
fi
exit "$RC"
