#!/usr/bin/env bash
# GUT 헤드리스 테스트 러너. CI, 커밋 hook, 에이전트가 같은 스크립트를 쓴다.
#
#   tools/run_tests.sh                 # tests/ 전체
#   tools/run_tests.sh tests/sim       # 디렉터리 지정
#   tools/run_tests.sh --quick         # 커밋 hook용: tests/sim 만, 실패 시 즉시 종료
#
# Godot 바이너리: $GODOT_BIN 또는 PATH 의 godot / godot4. 없으면 SKIP(exit 0)하고 CI에 맡긴다.
# SE_REQUIRE_GODOT=1 이면 Godot 이 없을 때 실패한다(CI에서 사용).
set -euo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT_BIN:-$(command -v godot || command -v godot4 || true)}"
DIRS=()
QUICK=0
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    *) DIRS+=("$a") ;;
  esac
done
if [ ${#DIRS[@]} -eq 0 ]; then
  if [ $QUICK -eq 1 ]; then DIRS=(tests/sim); else DIRS=(tests/sim tests/view tests/e2e); fi
fi

if [ -z "$GODOT" ]; then
  if [ "${SE_REQUIRE_GODOT:-0}" = "1" ]; then
    echo "FAIL: Godot 바이너리를 찾을 수 없다 (GODOT_BIN 설정 필요)"; exit 1
  fi
  echo "SKIP: Godot 바이너리 없음 → 헤드리스 테스트는 CI에서 실행된다"; exit 0
fi

if [ ! -d project/addons/gut ]; then
  echo "SKIP: project/addons/gut 없음 → GUT 설치 전 (docs/adr/0003-test-framework-gut.md 참고)"; exit 0
fi

# 테스트 파일이 하나도 없으면 통과
if ! find "${DIRS[@]}" -name 'test_*.gd' 2>/dev/null | grep -q .; then
  echo "SKIP: 테스트 파일 없음 (${DIRS[*]})"; exit 0
fi

# 첫 실행 시 임포트 캐시 생성
"$GODOT" --headless --path project --import >/dev/null 2>&1 || true

STATUS=0
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  echo "== GUT: $d"
  # tests/ 는 project/ 밖에 있으므로 res:// 기준 상대 경로로 넘긴다
  "$GODOT" --headless --path project -s addons/gut/gut_cmdln.gd \
    -gdir="res://../$d" -ginclude_subdirs -gexit -glog=1 || STATUS=$?
  if [ $QUICK -eq 1 ] && [ $STATUS -ne 0 ]; then exit $STATUS; fi
done
exit $STATUS
