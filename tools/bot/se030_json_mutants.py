#!/usr/bin/env python3
"""SE-030 QA JSON 변이 생성기.

project/data 의 show·reputation·genres JSON 을 한 군데씩 틀리게 하는 패치(`se030_mNN_*.diff`) 21개를 **리포지토리 밖**
디렉터리에 만들고(기본: 새 임시 디렉터리, 경로를 출력), 각 변이에서 `tools/validate_data.py --strict` 가 잡는지를
사본(리포 밖 임시 디렉터리)에서 확인한다. 패치는 저장소에 커밋하지 않는다(SE-048: 데이터가 바뀌면 낡는 산출물이라 생성기만 둔다).
GUT 쪽은 `tools/bot/mutate_and_test.sh <출력 디렉터리>/se030_mNN_*.diff` 로 돌린다(이 스크립트는 하지 않는다).

사용: python3 -I tools/bot/se030_json_mutants.py [--write-only] [--out DIR]
  --write-only  validate 확인 없이 패치만 쓴다.
  --out DIR     패치를 쓸 디렉터리. 리포지토리 안이면 거부한다(exit 2).
"""
import difflib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# (id, 파일(project/data 기준), 찾을 문자열, 바꿀 문자열, 설명, 연결된 규칙)
M = [
    ("m01_good_min_equal_ok", "show/show.json", '"id": "good",     "name": "호평", "min_bp": 6000', '"id": "good",     "name": "호평", "min_bp": 5000', "good.min_bp == ok.min_bp (임계 단조 위반)", "AC3 SL3"),
    ("m02_grades_order_swap", "show/show.json",
     '    { "id": "poor",     "name": "부진", "min_bp": 3000 },\n    { "id": "ok",       "name": "보통", "min_bp": 5000 },\n',
     '    { "id": "ok",       "name": "보통", "min_bp": 5000 },\n    { "id": "poor",     "name": "부진", "min_bp": 3000 },\n', "poor/ok 행 순서 교환 (min_bp 비단조 + show_grades 순서 불일치)", "AC3 SL2 SL3"),
    ("m03_first_min_nonzero", "show/show.json", '"id": "disaster", "name": "참사", "min_bp": 0', '"id": "disaster", "name": "참사", "min_bp": 100', "첫 행 min_bp 0 → 100 (SR3 이 항상 하나를 고르는 전제 깨짐)", "SL3"),
    ("m04_rave_over_scale", "show/show.json", '"min_bp": 7500', '"min_bp": 10001', "rave min_bp 10001 (rate_scale 초과)", "스키마 bp 최대"),
    ("m05_poor_positive", "reputation/reputation.json", '"poor": -10', '"poor": 10', "poor base −10 → +10 (실패가 명성을 올림)", "AC3 RT4"),
    ("m06_ok_zero", "reputation/reputation.json", '"ok": 12', '"ok": 0', "ok base 0 (RL4 0 금지)", "RL4"),
    ("m07_min_bp_low", "reputation/reputation.json", '"min_bp": 5000', '"min_bp": 100', "입장 계수 하한 100 bp (소수 입장 실패 Δ 가 0 이 됨)", "RP3 RL4"),
    ("m08_breadth_bonus_zero", "reputation/reputation.json", '"breadth_bonus_bp": 2000', '"breadth_bonus_bp": 0', "관객 폭 보너스 0 (FC4 제거의 데이터판)", "RP4 RT5"),
    ("m09_identity_share_8000", "reputation/reputation.json", '"identity_share_bp": 7000', '"identity_share_bp": 8000', "정체성 임계 8,000", "RP4 FC3"),
    ("m10_admissions_ref_120", "reputation/reputation.json", '"admissions_ref": 100', '"admissions_ref": 120', "입장 기준 120", "RG3"),
    ("m11_max_tier_3", "reputation/reputation.json", '"tier_unlock": {"max_tier": 2}', '"tier_unlock": {"max_tier": 3}', "max_tier 3 (두 번째 해금 허용, 해금 1회 가드의 데이터판)", "RP6 TU2"),
    ("m12_unlock_key_dup", "reputation/reputation.json", '"tier_unlock": {"max_tier": 2}', '"tier_unlock": {"max_tier": 2, "unlock_reputation": 500}', "reputation.json 에 해금 임계 복제", "AR14 RP13"),
    ("m13_affinity_asym", "genres/genres.json", '"affinity": { "rock": 0.5, "indie": 1.0, "electronic": 0.4 }', '"affinity": { "rock": 0.6, "indie": 1.0, "electronic": 0.4 }', "indie→rock 0.6 (비대칭)", "AC4 RL3"),
    ("m14_affinity_diag", "genres/genres.json", '"affinity": { "rock": 0.2, "indie": 0.4, "electronic": 1.0 }', '"affinity": { "rock": 0.2, "indie": 0.4, "electronic": 0.9 }', "electronic 대각 0.9", "AC4 RL3"),
    ("m15_affinity_out_of_range", "genres/genres.json", '"affinity": { "rock": 1.0, "indie": 0.5, "electronic": 0.2 }', '"affinity": { "rock": 1.0, "indie": 1.5, "electronic": 0.2 }', "rock→indie 1.5 (범위 밖)", "스키마 maximum 1"),
    ("m16_affinity_non_mvp", "genres/genres.json", '{ "id": "hiphop",     "name": "힙합",      "accent_color": "#f2a93b" }', '{ "id": "hiphop",     "name": "힙합",      "accent_color": "#f2a93b", "affinity": { "hiphop": 1.0 } }', "MVP 밖 장르에 affinity (스키마는 허용)", "RP11"),
    ("m17_expected_total_typo", "reputation/reputation.json", '"total": [18, 36, 54, 75, 96, 117, 138, 159, 180, 201, 222, 243, 264, 285, 306, 327, 348, 369, 390, 411, 432, 453, 474, 495, 516,', '"total": [18, 36, 54, 75, 96, 117, 138, 159, 180, 201, 222, 243, 264, 285, 306, 327, 348, 369, 390, 411, 432, 453, 474, 495, 515,', "기대 total 25일 516 → 515 (첫 시나리오만)", "RP12 RP15"),
    ("m18_good_base_23", "reputation/reputation.json", '"good": 22', '"good": 23', "good base 22 → 23 (데이터만 바꾸고 expected 미갱신)", "RP12"),
    ("m19_source_changed", "show/show.json", '"satisfaction_source": "audience.day_summary.avg_satisfaction_bp"', '"satisfaction_source": "show.computed"', "만족도 진실의 출처 변경", "SH11 SL4"),
    ("m20_no_stage_reason", "show/show.json", '"expected": { "event": "show.skipped", "reason": "no_stage" }', '"expected": { "event": "show.skipped", "reason": "no_lineup" }', "no_stage 시나리오 기대 reason 오기", "SH12"),
    ("m21_range_gate", "reputation/reputation.json", '"tier2_reputation_day_range": [20, 30]', '"tier2_reputation_day_range": [20, 24]', "AC2 허용 범위를 20~24 로 좁힘 (25일 이탈)", "AC2 RT1"),
]


def patch_text(rel, old, new):
    p = ROOT / "project" / "data" / rel
    src = p.read_text(encoding="utf-8")
    if src.count(old) < 1:
        raise SystemExit(f"찾을 문자열 없음: {rel}: {old[:50]}")
    dst = src.replace(old, new, 1)
    diff = difflib.unified_diff(src.splitlines(True), dst.splitlines(True), f"a/project/data/{rel}", f"b/project/data/{rel}", n=3)
    return "".join(diff), dst


def resolve_out(argv):
    if "--out" in argv:
        i = argv.index("--out")
        if i + 1 >= len(argv):
            print("--out 에 디렉터리가 필요하다", file=sys.stderr)
            raise SystemExit(2)
        out = Path(argv[i + 1]).resolve()
    else:
        out = Path(tempfile.mkdtemp(prefix="se030_mut.")).resolve()
    if out == ROOT or ROOT in out.parents:
        print(f"출력 디렉터리는 리포지토리 밖이어야 한다: {out}", file=sys.stderr)
        raise SystemExit(2)
    out.mkdir(parents=True, exist_ok=True)
    return out


def main(write_only, out):
    print(f"패치 출력: {out}")
    print(f"{'id':28} {'validate --strict':18} 설명 (규칙)")
    for mid, rel, old, new, desc, rule in M:
        text, dst = patch_text(rel, old, new)
        header = f"# SE-030 QA 변이 {mid}: {desc} [{rule}]\n# 사용: tools/bot/mutate_and_test.sh {out}/se030_{mid}.diff\n"
        (out / f"se030_{mid}.diff").write_text(header + text, encoding="utf-8")
        if write_only:
            continue
        tmp = Path(tempfile.mkdtemp(prefix="se030_val."))
        try:
            shutil.copytree(ROOT / "project" / "data", tmp / "project" / "data")
            (tmp / "tools").mkdir()
            shutil.copy(ROOT / "tools" / "validate_data.py", tmp / "tools" / "validate_data.py")
            (tmp / "project" / "data" / rel).write_text(dst, encoding="utf-8")
            r = subprocess.run([sys.executable, str(tmp / "tools" / "validate_data.py"), "--strict"], capture_output=True, text=True)
            fails = [l for l in (r.stdout + r.stderr).splitlines() if l.startswith("FAIL")]
            status = f"잡음 (exit {r.returncode})" if r.returncode != 0 else "통과(못 잡음)"
            print(f"{mid:28} {status:18} {desc} ({rule})" + (f"  <- {fails[0][:110]}" if fails else ""))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main("--write-only" in sys.argv, resolve_out(sys.argv[1:]))
