#!/usr/bin/env bash
# GUT 헤드리스 테스트 러너. CI, 커밋 hook, 에이전트가 같은 스크립트를 쓴다.
#
#   tools/run_tests.sh                       # project/tests/{sim,view,e2e} 전체
#   tools/run_tests.sh project/tests/sim     # 디렉터리 지정 (res:// 기준 상대 경로는 project/ 접두어 없이도 됨)
#   tools/run_tests.sh --quick               # 커밋 hook용: project/tests/sim 만, 실패 시 즉시 종료
#
# Godot 바이너리: $GODOT_BIN 또는 PATH 의 godot / godot4. 없으면 SKIP(exit 0)하고 CI에 맡긴다.
# SE_REQUIRE_GODOT=1 이면 Godot 이 없을 때 실패한다(CI에서 사용).
set -uo pipefail
cd "$(dirname "$0")/.."

GODOT="${GODOT_BIN:-$(command -v godot || command -v godot4 || true)}"
DIRS=()
QUICK=0
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    *) DIRS+=("${a#project/}") ;;      # project/tests/sim → tests/sim
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

if [ ! -f project/addons/gut/gut_cmdln.gd ]; then
  echo "FAIL: project/addons/gut 없음 (docs/adr/0003-test-framework-gut.md)"; exit 1
fi

# 임포트 + class_name 캐시 갱신 (.godot/ 은 gitignore). 새 class_name 이 등록되지 않으면 테스트가 실패하므로 매번 돈다.
"$GODOT" --headless --path project --import >/dev/null 2>&1 || true

STATUS=0
for d in "${DIRS[@]}"; do
  if [ ! -d "project/$d" ]; then continue; fi
  if ! find "project/$d" -name 'test_*.gd' | grep -q .; then
    echo "SKIP: 테스트 파일 없음 (project/$d)"; continue
  fi
  echo "== GUT: project/$d"
  "$GODOT" --headless --path project -s addons/gut/gut_cmdln.gd \
    -gdir="res://$d" -ginclude_subdirs -gexit -glog=1
  RC=$?
  if [ $RC -ne 0 ]; then STATUS=$RC; fi
  if [ $QUICK -eq 1 ] && [ $STATUS -ne 0 ]; then exit $STATUS; fi
done
exit $STATUS
