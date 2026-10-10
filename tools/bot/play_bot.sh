#!/usr/bin/env bash
# SE-042 봇 플레이 래퍼 (qa). 러너 본체는 project/tests/e2e/bot_runner.gd (SceneTree), 로직은 bot_play.gd.
#
#   tools/bot/play_bot.sh --policy frugal --seeds 100 --days 30            # 시드 1..100 을 프로세스로 나눠 돌리고 합쳐 SE-042.json 갱신
#   tools/bot/play_bot.sh --policy v0_replay --seed-start 36 --seeds 1 --days 30   # 보정 정책(통계 표 밖, calibration 으로 합쳐진다)
#   tools/bot/play_bot.sh --merge                                          # 부분 결과(parts)만 합쳐 결과 파일을 다시 쓴다
#
# 옵션: --policy <id> --seeds <n> --days <d> [--seed-start <s>=1] [--procs <p>=코어 수] [--parts <dir>] [--out <file>] [--no-merge] [--merge]
# 환경: GODOT_BIN, BOT_PARTS_DIR(기본 tools/bot/results/parts, gitignore), BOT_TMP(프로세스별 XDG_DATA_HOME 상위, 기본 $TMPDIR 또는 /tmp)
# 프로세스마다 XDG_DATA_HOME 을 따로 줘 user:// 가 다른 GUT·봇 실행과 겹치지 않게 한다. 결과 파일에는 실행 시간 같은 비결정 값이 없다.
# 종료 코드: 0 성공, 2 인자 오류, 3 Godot 없음, 그 밖 = 실패한 하위 실행의 코드.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

POLICY=""; SEEDS=""; DAYS=""; START=1; PROCS=""; MERGE_ONLY=0; NO_MERGE=0
PARTS="${BOT_PARTS_DIR:-$ROOT/tools/bot/results/parts}"
OUT="$ROOT/tools/bot/results/SE-042.json"
usage() { sed -n 2,13p "$0"; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --policy) POLICY="${2:-}"; shift 2 ;;
    --seeds) SEEDS="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --seed-start) START="${2:-}"; shift 2 ;;
    --procs) PROCS="${2:-}"; shift 2 ;;
    --parts) PARTS="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --merge) MERGE_ONLY=1; shift ;;
    --no-merge) NO_MERGE=1; shift ;;
    -h|--help) usage ;;
    *) echo "알 수 없는 옵션: $1" >&2; usage ;;
  esac
done

GODOT="${GODOT_BIN:-$(command -v godot || command -v godot4 || true)}"
if [ -z "$GODOT" ]; then echo "FAIL: Godot 바이너리 없음 (GODOT_BIN)" >&2; exit 3; fi
RUNNER="res://tests/e2e/bot_runner.gd"
TMP_BASE="${BOT_TMP:-${TMPDIR:-/tmp}}"
WORK="$(mktemp -d "$TMP_BASE/se_bot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PARTS"
PARTS="$(cd "$PARTS" && pwd)"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac

# class_name 캐시(BotPlay)가 필요하다. 한 번만 임포트한다.
XDG_DATA_HOME="$WORK/xdg_import" "$GODOT" --headless --path project --import >/dev/null 2>&1 || true

if [ $MERGE_ONLY -eq 0 ]; then
  if [ -z "$POLICY" ] || [ -z "$SEEDS" ] || [ -z "$DAYS" ]; then echo "--policy, --seeds, --days 필요" >&2; usage; fi
  [ -f "tools/bot/policies/$POLICY.json" ] || { echo "정책 파일 없음: $POLICY" >&2; exit 2; }
  case "$SEEDS$DAYS$START" in *[!0-9]*|"") echo "--seeds/--days/--seed-start 는 정수" >&2; exit 2 ;; esac
  if [ "$SEEDS" -lt 1 ] || [ "$DAYS" -lt 1 ]; then echo "--seeds, --days 는 1 이상" >&2; exit 2; fi
  if [ -z "$PROCS" ]; then PROCS="$(nproc 2>/dev/null || echo 1)"; fi
  if [ "$PROCS" -gt "$SEEDS" ]; then PROCS="$SEEDS"; fi
  # 시드 구간을 PROCS 개로 균등 분할 (앞 구간이 하나씩 더 가진다)
  BASE=$((SEEDS / PROCS)); EXTRA=$((SEEDS % PROCS))
  PIDS=(); first=$START
  for ((i = 0; i < PROCS; i++)); do
    n=$BASE; if [ $i -lt $EXTRA ]; then n=$((n + 1)); fi
    part="$PARTS/${POLICY}_d${DAYS}_s${first}_n${n}.json"
    mkdir -p "$WORK/xdg_$i"
    ( XDG_DATA_HOME="$WORK/xdg_$i" "$GODOT" --headless --path project -s "$RUNNER" -- run \
        --policy "$POLICY" --seed-start "$first" --seeds "$n" --days "$DAYS" --out "$part" ) >"$WORK/log_$i.txt" 2>&1 &
    PIDS+=($!)
    first=$((first + n))
  done
  RC=0
  for idx in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$idx]}"; then
      RC=3; echo "FAIL: 프로세스 $idx" >&2; tail -20 "$WORK/log_$idx.txt" >&2
    fi
  done
  for ((i = 0; i < PROCS; i++)); do tail -1 "$WORK/log_$i.txt"; done
  if [ $RC -ne 0 ]; then exit $RC; fi
  if [ $NO_MERGE -eq 1 ]; then exit 0; fi
fi

XDG_DATA_HOME="$WORK/xdg_merge" "$GODOT" --headless --path project -s "$RUNNER" -- merge --parts "$PARTS" --out "$OUT"
RC=$?
if [ $RC -ne 0 ]; then echo "FAIL: merge exit $RC" >&2; exit $RC; fi
echo "결과: $OUT"
python3 -I "$ROOT/tools/bot/bot_table.py" "$OUT" || true
exit 0
