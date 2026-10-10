#!/usr/bin/env bash
# SE-020: SE-002(1장) + SE-004(4장) + SE-037(1장) + SE-038(1장) + SE-039(2장) + SE-040(2장) 스크린샷을 Xvfb(llvmpipe, gl_compatibility=opengl3)로 재캡처한다.
# 명령 5개는 SE-018 결과 절(AC9 / 테스트 방법)의 재캡처 명령과 인자 순서까지 같고, 6번째(SE-037)는 SE-037 결과 절의 명령과, 7번째(SE-038)는 SE-038 결과 절의 명령과, 8·9번째(SE-039)는 SE-039 결과 절의 명령과, 10·11번째(SE-040)는 SE-040 결과 절의 명령(씬 main.tscn)과 같다.
# 셰이더 컴파일 검증 겸용: 헤드리스 GUT 는 더미 RenderingServer 라 .gdshader 를 컴파일하지 않으므로,
# 이 캡처가 toon/outline 셰이더가 gl_compatibility 에서 오류 없이 도는지 확인하는 유일한 자동 경로다.
#
#   project/tests/view/screenshots/recapture.sh [out_dir]
#
#   out_dir  PNG 11장 + 로그 11개(<name>.log)를 쓸 디렉터리. 생략하면 mktemp -d (경로를 마지막 줄에 출력).
#            상대 경로는 **호출자의 cwd** 기준이다(리포지토리 루트 기준 아님). 없으면 만든다.
#            리포지토리 안(특히 커밋된 기준 PNG 폴더)을 가리키면 디렉터리를 만들기 **전에** 거부한다 — 기준 PNG 는 SE-018 에서만 바꾼다.
# 종료 코드: 0 = 11장 모두 생성·1920x1080·셰이더 오류 없음, 1 = 캡처 실패/오류 패턴/크기 이상, 2 = 환경(Godot·xvfb-run 없음, 인자 오류).
set -uo pipefail
CALLER_PWD="$PWD"   # out_dir 상대 경로의 기준(아래 cd 로 cwd 가 바뀌기 전에 잡는다)
cd "$(dirname "$0")/../../../.." || { echo "FAIL: 리포지토리 루트로 이동할 수 없다 ($0 기준 4단계 위)"; exit 2; }   # project/tests/view/screenshots 의 4단계 위
ROOT="$(pwd -P)"

GODOT="${GODOT_BIN:-$(command -v godot || command -v godot4 || true)}"
PROJECT="${SE_PROJECT_DIR:-project}"
if [ -z "$GODOT" ]; then echo "FAIL: Godot 바이너리를 찾을 수 없다 (GODOT_BIN 설정 필요)"; exit 2; fi
if ! command -v xvfb-run >/dev/null 2>&1; then echo "FAIL: xvfb-run 없음 (apt-get install -y xvfb)"; exit 2; fi
if [ $# -gt 1 ]; then echo "usage: $0 [out_dir]"; exit 2; fi

# 존재하지 않는 경로도 디렉터리를 만들지 않고 물리 경로(심볼릭 링크 해석)로 절대화한다:
# 존재하는 가장 가까운 조상까지 올라가 pwd -P 로 해석하고, 나머지 이름을 뒤에 붙인다.
abs_path() {
  local p="$1" tail="" name
  case "$p" in /*) ;; *) p="$CALLER_PWD/$p" ;; esac
  while [ ! -d "$p" ]; do
    name="$(basename "$p")"
    if [ "$name" = ".." ]; then echo "FAIL: out_dir 가 존재하지 않는 디렉터리 뒤에 '..' 를 포함한다 ($1)" >&2; return 1; fi
    if [ "$name" != "." ]; then tail="/$name$tail"; fi
    p="$(dirname "$p")"
  done
  local base
  base="$(cd "$p" && pwd -P)" || return 1
  echo "$base$tail"
}

inside_repo() { case "$1/" in "$ROOT"/*) return 0 ;; esac; return 1; }

if [ $# -eq 1 ]; then
  if [ -z "$1" ]; then echo "usage: $0 [out_dir]  (out_dir 가 빈 문자열이다)"; exit 2; fi
  OUT="$(abs_path "$1")" || exit 2
  # 리포지토리 안 거부는 mkdir 보다 먼저 — 거부된 호출이 리포지토리에 빈 디렉터리를 남기지 않는다.
  if inside_repo "$OUT"; then echo "FAIL: out_dir 가 리포지토리 안이다 ($OUT). 스크래치/RUNNER_TEMP 를 쓴다."; exit 2; fi
  mkdir -p "$OUT" || { echo "FAIL: out_dir 를 만들 수 없다 ($OUT)"; exit 2; }
else
  OUT="$(mktemp -d)" || exit 2
  OUT="$(cd "$OUT" && pwd -P)" || exit 2
  # TMPDIR 이 리포지토리 안이면 방금 만든 빈 디렉터리를 치우고 거부한다.
  if inside_repo "$OUT"; then rmdir "$OUT" 2>/dev/null; echo "FAIL: mktemp 결과가 리포지토리 안이다 ($OUT). TMPDIR 를 리포지토리 밖으로 지정한다."; exit 2; fi
fi

# 셰이더 컴파일 오류 패턴(하나라도 로그에 있으면 실패).
ERR_PATTERNS=('SHADER ERROR' 'shader compilation' 'Failed to compile')
SHADER_ERR_REGEX='error\(.*\.gdshader|\.gdshader.*error\('

XVFB_ARGS=(-a -s "-screen 0 1920x1080x24")
GODOT_COMMON=(--path "$PROJECT" --rendering-driver opengl3 --resolution 1920x1080)
SCENE="res://view/scenes/grid_sandbox.tscn"
MAIN_SCENE="res://view/scenes/main.tscn"   # SE-040 캡처(10·11번째)용 — 샌드박스가 아니라 메인 씬

# 한 번 캡처하고 종료 코드·로그 패턴을 검사한다. 인자: <name.png> <"--" 뒤에 그대로 넘길 인자...>
# (SE-018 명령과 글자 단위로 같게 하려고 --se-screenshot 위치도 호출부에서 정한다.)
capture() {
  local name="$1"; shift
  local scene="${CAPTURE_SCENE:-$SCENE}"
  local log="$OUT/${name%.png}.log"
  echo "== capture $name"
  xvfb-run "${XVFB_ARGS[@]}" "$GODOT" "${GODOT_COMMON[@]}" "$scene" -- "$@" >"$log" 2>&1
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
# SE-037 (배치 UI: 기준 배치 6 + 음향 오버레이 + 팔레트)
capture build_baseline_yaw45_zoom2.png --se-build-preset=baseline --se-screenshot="$OUT/build_baseline_yaw45_zoom2.png"
# SE-038 (관객 150 watching + 무대 스포트 4 on, 기준 배치 + 조명 가구)
capture crowd150_show_yaw45_zoom2.png --se-crowd-preset=150 --se-screenshot="$OUT/crowd150_show_yaw45_zoom2.png"

# SE-039 (HUD·패널 v0: 낮 구간 HUD + 섭외 버튼, 마감 리포트. ui_ko.json 한국어 문장)
capture hud_day_yaw45_zoom2.png --se-ui-preset=day --se-screenshot="$OUT/hud_day_yaw45_zoom2.png"
capture report_close.png --se-ui-preset=close --se-screenshot="$OUT/report_close.png"

# SE-040 (메인 씬: 실제 GameSession 위, 시드 0, 기준 배치 + 섭외 + 배속 3. evening = 개장 30초 입장 중, show = 공연 중반 + 스포트)
CAPTURE_SCENE="$MAIN_SCENE" capture main_day1_evening.png --se-seed=0 --se-capture=evening --se-screenshot="$OUT/main_day1_evening.png"
CAPTURE_SCENE="$MAIN_SCENE" capture main_show.png --se-seed=0 --se-capture=show --se-screenshot="$OUT/main_show.png"

# 11장 전부 존재·1920x1080 (compare_png.gd --size-only)
for f in grid_yaw45_zoom2 a_yaw45_zoom2 b_yaw45_zoom2 c_yaw45_zoom2 b_yaw45_zoom0 build_baseline_yaw45_zoom2 crowd150_show_yaw45_zoom2 hud_day_yaw45_zoom2 report_close main_day1_evening main_show; do
  line="$("$GODOT" --headless --path project -s res://tests/view/screenshots/compare_png.gd -- "$OUT/$f.png" --size-only 2>&1 | tail -n 1)"
  echo "$f.png: $line"
  if [ "$line" != "size_ok=true size=1920x1080" ]; then echo "FAIL: $f.png 크기 이상"; exit 1; fi
done

echo "OK: 11장 캡처 완료, 셰이더 오류 패턴 없음"
echo "$OUT"
