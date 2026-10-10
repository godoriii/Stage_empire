#!/usr/bin/env python3
"""SE-042 결과 JSON(tools/bot/results/SE-042.json) -> 마크다운 표 + 목표 범위 안/밖 판정.

  python3 -I tools/bot/bot_table.py [결과.json] [--targets tools/bot/policies/targets.json] [--check-only]

표 형식은 docs/gdd/bot_metrics.md "결과 파일 형식"의 md 항목(분위 지표 표, 모은 값 표, 범위 밖 목록)을 따른다.
출력은 결과 JSON 과 targets.json 만의 함수다(결정적). 판정 규칙은 targets.json 의 min/max(포함), unreached=True 는 값이 null(미도달)이어야 안.
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_RESULT = os.path.join(ROOT, "tools", "bot", "results", "SE-042.json")
DEFAULT_TARGETS = os.path.join(ROOT, "tools", "bot", "policies", "targets.json")

QUANTILE_ROWS = [
    ("M1 cash_swing_d3", "cash_swing_d3"),
    ("M2 first_profit_day", "first_profit_day"),
    ("M3 payback_day", "payback_day"),
    ("M5 rep500_day", "rep500_day"),
    ("M6 tier2_day", "tier2_day"),
    ("M7 bankrupt_day", "bankrupt_day"),
    ("M8 first_prompt_day", "first_prompt_day"),
    ("M8 prompts_d10", "prompts_d10"),
    ("보조 final_cash", "final_cash"),
    ("보조 final_rep", "final_rep"),
    ("보조 bailouts_taken", "bailouts_taken"),
]
GRADE_KEYS = ["disaster", "poor", "ok", "good", "rave", "skipped"]


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def pct(bp):
    return "-" if bp is None else "%.1f%%" % (bp / 100.0)


def cell(s):
    if s is None:
        return "-"
    if s["median"] is None and s["reached_bp"] == 0:
        return ">30 (도달 0%)"
    f = lambda v: ">30" if v is None else format(v, ",")
    txt = "%s [%s, %s]" % (f(s["median"]), f(s["q1"]), f(s["q3"]))
    return txt + " (도달 %s)" % pct(s["reached_bp"])


def value_of(res, t):
    """targets.json 항목 하나의 관측 값. 없으면 None."""
    m, pol = t["metric"], t["policy"]
    if t["stat"] == "cross":
        return res["cross_policy"].get(m)
    block = res["by_policy"].get(pol)
    if block is None:
        return None
    if t["stat"] in ("median", "q1", "q3"):
        return block["summary"][m][t["stat"]]
    pooled = block["pooled"]
    g = pooled["grade_share_bp"]
    if m == "grade_good_rave_bp":
        return g["good"] + g["rave"]
    if m == "grade_rave_bp":
        return g["rave"]
    if m == "grade_disaster_poor_bp":
        return g["disaster"] + g["poor"]
    if m == "grade_disaster_poor_skipped_bp":
        return g["disaster"] + g["poor"] + g["skipped"]
    if m in ("tier2_rate_bp", "bankrupt_rate_bp"):
        return pooled[m]
    if m in ("soldout_below_good_bp", "soldout_sat_mean_bp"):
        return pooled["soldout"][m.replace("soldout_", "")]
    if m == "net_fail_minus_skip":
        f = pooled["fail_vs_skip"]
        if f["net_fail_mean"] is None or f["net_skip_mean"] is None:
            return None
        return f["net_fail_mean"] - f["net_skip_mean"]
    raise KeyError(m)


def judge(res, t):
    """('안' | '밖' | '판정 불가', 관측 값)"""
    if t["policy"] is not None and t["policy"] not in res["by_policy"]:
        return "판정 불가", None
    v = value_of(res, t)
    if t.get("unreached"):
        return ("안" if v is None else "밖"), v
    if v is None:
        return "밖" if t["stat"] in ("median", "q1", "q3") else "판정 불가", v
    if t["min"] is not None and v < t["min"]:
        return "밖", v
    if t["max"] is not None and v > t["max"]:
        return "밖", v
    return "안", v


def rng(t):
    if t.get("unreached"):
        return ">30 (미도달)"
    lo, hi = t["min"], t["max"]
    if lo is not None and hi is not None:
        return "%s~%s" % (format(lo, ","), format(hi, ","))
    if lo is not None:
        return "≥ %s" % format(lo, ",")
    return "≤ %s" % format(hi, ",")


def fmt_v(v):
    return "-" if v is None else format(v, ",")


def tables(res, targets):
    out = []
    pols = res["policies"]
    out.append("### 실행 정보\n")
    out.append("- 일수 %d, 시드 %d..%d (%d판/정책), 정책 %s, spec_version %d" % (
        res["days"], res["seeds"]["first"], res["seeds"]["first"] + res["seeds"]["count"] - 1, res["seeds"]["count"],
        ", ".join(pols), res["spec_version"]))
    for p in pols:
        out.append("- %s.json sha1 `%s`" % (p, res["by_policy"][p]["policy_file_sha1"]))
    cal = res.get("calibration")
    if cal:
        for k, v in cal.items():
            out.append("- 보정 %s: 시드 %d 해금 %s / 명성 500 %s / 끝 %s / %s -> match=%s" % (
                k, v["seed"], v["tier2_day"], v["rep500_day"], fmt_v(v["final_cash"]), fmt_v(v["final_rep"]), v["match"]))
    out.append("")
    # 분위 지표
    by_t = {}
    for t in targets["targets"]:
        by_t.setdefault((t["metric"], t["policy"]), []).append(t)
    out.append("### 정책 x 지표 (분위 지표: 중앙값 [Q1, Q3], 도달률)\n")
    out.append("| 지표 | " + " | ".join(pols) + " |")
    out.append("|---|" + "---|" * len(pols))
    for label, key in QUANTILE_ROWS:
        out.append("| %s | " % label + " | ".join(cell(res["by_policy"][p]["summary"][key]) for p in pols) + " |")
    out.append("")
    out.append("### 모은 값 (pooled)\n")
    out.append("| 지표 | " + " | ".join(pols) + " |")
    out.append("|---|" + "---|" * len(pols))
    out.append("| M4 등급 % (" + "/".join(GRADE_KEYS) + ") | " + " | ".join(
        "/".join("%.1f" % (res["by_policy"][p]["pooled"]["grade_share_bp"][g] / 100.0) for g in GRADE_KEYS) for p in pols) + " |")
    out.append("| M6 tier2_rate | " + " | ".join(pct(res["by_policy"][p]["pooled"]["tier2_rate_bp"]) for p in pols) + " |")
    out.append("| M7 bankrupt_rate | " + " | ".join(pct(res["by_policy"][p]["pooled"]["bankrupt_rate_bp"]) for p in pols) + " |")
    out.append("| M10 soldout days / sat_mean_bp / below_good | " + " | ".join(
        "%s / %s / %s" % (fmt_v(s["days"]), fmt_v(s["sat_mean_bp"]), pct(s["below_good_bp"]))
        for s in (res["by_policy"][p]["pooled"]["soldout"] for p in pols)) + " |")
    out.append("| M11 fail_days / skip_days / net_fail / net_skip / rep_fail | " + " | ".join(
        "%s / %s / %s / %s / %s" % tuple(fmt_v(f[k]) for k in ("fail_days", "skip_days", "net_fail_mean", "net_skip_mean", "rep_fail_mean"))
        for f in (res["by_policy"][p]["pooled"]["fail_vs_skip"] for p in pols)) + " |")
    out.append("| M12 zero_admission_shows (건 / 공연일) | " + " | ".join(
        "%s / %s" % (fmt_v(z["count"]), fmt_v(z["of_shows"])) for z in (res["by_policy"][p]["pooled"]["zero_admission_shows"] for p in pols)) + " |")
    out.append("| 섭외 거절 사유 | " + " | ".join(json.dumps(res["by_policy"][p]["pooled"]["rejections"]["booking"], ensure_ascii=False) for p in pols) + " |")
    out.append("| 건설 거절 사유 | " + " | ".join(json.dumps(res["by_policy"][p]["pooled"]["rejections"]["build"], ensure_ascii=False) for p in pols) + " |")
    out.append("")
    cp = res["cross_policy"]
    out.append("### 정책 간 (M9) · 합산 파산율\n")
    out.append("- spread_rep500_days = %s, spread_final_cash = %s, bankrupt_rate_bp_pooled = %s (%s)" % (
        fmt_v(cp["spread_rep500_days"]), fmt_v(cp["spread_final_cash"]), fmt_v(cp["bankrupt_rate_bp_pooled"]), pct(cp["bankrupt_rate_bp_pooled"])))
    out.append("")
    out.append("### 목표 범위 판정\n")
    out.append("| 지표 | 통계 | 정책 | 관측 | 목표 | 판정 |")
    out.append("|---|---|---|---|---|---|")
    outs = []
    for t in targets["targets"]:
        verdict, v = judge(res, t)
        ref = " (참고)" if t.get("reference") else ""
        out.append("| %s | %s | %s | %s | %s | %s%s |" % (t["metric"], t["stat"], t["policy"] or "정책 간", fmt_v(v), rng(t), verdict, ref))
        if verdict == "밖":
            outs.append((t, v))
    out.append("")
    out.append("### 범위 밖 (%d건)\n" % len(outs))
    for t, v in outs:
        out.append("- %s %s 관측 %s 목표 %s" % (t["metric"], t["policy"] or "정책 간", fmt_v(v), rng(t)))
    return "\n".join(out)


def main(argv):
    path = DEFAULT_RESULT
    tpath = DEFAULT_TARGETS
    i = 0
    while i < len(argv):
        if argv[i] == "--targets":
            tpath = argv[i + 1]
            i += 2
        elif argv[i].startswith("-"):
            print("알 수 없는 옵션", argv[i], file=sys.stderr)
            return 2
        else:
            path = argv[i]
            i += 1
    print(tables(load(path), load(tpath)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
