#!/usr/bin/env bash
# SE-020: SE-002(1장) + SE-004(4장) 스크린샷을 Xvfb(llvmpipe, gl_compatibility=opengl3)로 재캡처한다.
# 명령 5개는 SE-018 결과 절(AC9 / 테스트 방법)의 재캡처 명령과 인자 순서까지 같다.
# 셰이더 컴파일 검증 겸용: 헤드리스 GUT 는 더미 RenderingServer 라 .gdshader 를 컴파일하지 않으므로,
# 이 캡처가 toon/outline 셰이더가 gl_compatibility 에서 오류 없이 도는지 확인하는 유일한 자동 경로다.
#
#   project/tests/view/screenshots/recapture.sh [out_dir]
#
#   out_dir  PNG 5장 + 로그 5개(<name>.log)를 쓸 디렉터리. 생략하면 mktemp -d (경로를 마지막 줄에 출력).
#            리포지토리 안(특히 커밋된 기준 PNG 폴더)을 가리키면 거부한다 — 기준 PNG 는 SE-018 에서만 바꾼다.
# 환경 변수:
#   GODOT_BIN        Godot 바이너리(없으면 PATH 의 godot / godot4). tools/run_tests.sh 와 같은 규칙.
#   SE_PROJECT_DIR   캡처할 Godot 프로젝트 경로(기본 project). 셰이더 오류 주입 검증용 스크래치 사본에만 쓴다.
# 종료 코드: 0 = 5장 모두 생성·1920x1080·셰이더 오류 없음, 1 = 캡처 실패/오류 패턴/크기 이상, 2 = 환경(Godot·xvfb-run 없음, 인자 오류).
set -uo pipefail
cd "$(dirname "$0")/../../../.."   # 리포지토리 루트(project/tests/view/screenshots 의 4단계 위)
ROOT="$PWD"

GODOT="${GODOT_BIN:-$(command -v godot || command -v godot4 || true)}"
PROJECT="${SE_PROJECT_DIR:-project}"
if [ -z "$GODOT" ]; then echo "FAIL: Godot 바이너리를 찾을 수 없다 (GODOT_BIN 설정 필요)"; exit 2; fi
if ! command -v xvfb-run >/dev/null 2>&1; then echo "FAIL: xvfb-run 없음 (apt-get install -y xvfb)"; exit 2; fi
if [ $# -gt 1 ]; then echo "usage: $0 [out_dir]"; exit 2; fi

if [ $# -eq 1 ]; then
  mkdir -p "$1" || exit 2
  OUT="$(cd "$1" && pwd)"
else
  OUT="$(mktemp -d)"
fi
case "$OUT/" in
  "$ROOT"/*) echo "FAIL: out_dir 가 리포지토리 안이다 ($OUT). 스크래치/RUNNER_TEMP 를 쓴다."; exit 2 ;;
esac

# 셰이더 컴파일 오류 패턴(하나라도 로그에 있으면 실패).
ERR_PATTERNS=('SHADER ERROR' 'shader compilation' 'Failed to compile')
SHADER_ERR_REGEX='error\(.*\.gdshader|\.gdshader.*error\('

XVFB_ARGS=(-a -s "-screen 0 1920x1080x24")
GODOT_COMMON=(--path "$PROJECT" --rendering-driver opengl3 --resolution 1920x1080)
SCENE="res://view/scenes/grid_sandbox.tscn"

# 한 번 캡처하고 종료 코드·로그 패턴을 검사한다. 인자: <name.png> <"--" 뒤에 그대로 넘길 인자...>
# (SE-018 명령과 글자 단위로 같게 하려고 --se-screenshot 위치도 호출부에서 정한다.)
capture() {
  local name="$1"; shift
  local log="$OUT/${name%.png}.log"
  echo "== capture $name"
  xvfb-run "${XVFB_ARGS[@]}" "$GODOT" "${GODOT_COMMON[@]}" "$SCENE" -- "$@" >"$log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAIL: $name 캡처 종료 코드 $rc (로그: $log)"; tail -n 20 "$log"; exit 1
  fi
  local p
  for p in "${ERR_PATTERNS[@]}"; do
    if grep -n -i -F -- "$p" "$log" >/dev/null; then
      echo "FAIL: $name 로그에 셰이더 오류 패턴 '$p' (로그: $log)"; grep -n -i -F -- "$p" "$log" | head -n 5; exit 1
    fi
  done
  if grep -n -E -- "$SHADER_ERR_REGEX" "$log" >/dev/null; then
    echo "FAIL: $name 로그에 셰이더 오류 패턴 'error(' + '.gdshader' (로그: $log)"; grep -n -E -- "$SHADER_ERR_REGEX" "$log" | head -n 5; exit 1
  fi
  if [ ! -s "$OUT/$name" ]; then
    echo "FAIL: $name 이 생성되지 않았다 (로그: $log)"; tail -n 20 "$log"; exit 1
  fi
}

# SE-002 (플레이스홀더 + B 룩, 호버 타일 5,5)
capture grid_yaw45_zoom2.png --se-screenshot="$OUT/grid_yaw45_zoom2.png" --se-hover=5,5
# SE-004 3장 + 줌 0 1장
for m in a b c; do capture "${m}_yaw45_zoom2.png" --material=$m --se-screenshot="$OUT/${m}_yaw45_zoom2.png"; done
capture b_yaw45_zoom0.png --material=b --se-zoom=0 --se-screenshot="$OUT/b_yaw45_zoom0.png"

# 5장 전부 존재·1920x1080 (compare_png.gd --size-only)
for f in grid_yaw45_zoom2 a_yaw45_zoom2 b_yaw45_zoom2 c_yaw45_zoom2 b_yaw45_zoom0; do
  line="$("$GODOT" --headless --path project -s res://tests/view/screenshots/compare_png.gd -- "$OUT/$f.png" --size-only 2>&1 | tail -n 1)"
  echo "$f.png: $line"
  if [ "$line" != "size_ok=true size=1920x1080" ]; then echo "FAIL: $f.png 크기 이상"; exit 1; fi
done

echo "OK: 5장 캡처 완료, 셰이더 오류 패턴 없음"
echo "$OUT"
