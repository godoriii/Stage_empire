#!/usr/bin/env python3
"""SE-030 QA 공식 변이: 구현(SE-035) 전에, 스펙 공식을 한 군데씩 틀리게 한 엔진이
`reputation.json` / `show.json` 의 기준 시나리오 리터럴(및 문서 표)로 잡히는지 본다.

잡히지 않는 변이 = SE-035 의 테스트가 기준 시나리오만으로는 못 잡는다는 뜻이다(경계값 케이스가 따로 필요).
사용: python3 tools/bot/se030_formula_mutants.py   (읽기 전용, 항상 exit 0, 결과 표만 출력)
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
D = ROOT / "project" / "data"
L = lambda p: json.load(open(D / p, encoding="utf-8"))
REP, SHOW, ART, GEN, TIERS = L("reputation/reputation.json"), L("show/show.json"), L("artist/artist.json"), L("genres/genres.json"), L("tiers/tiers.json")
G = ART["mvp_genres"]
rows = {r["id"]: r for r in GEN["rows"]}
AFF = {g: {h: round(rows[g]["affinity"][h] * 10000) for h in G} for g in G}
B, A, F = REP["base_by_grade"], REP["admission_factor"], REP["focus"]
T2 = TIERS["rows"][1]


def grade(sat, m):
    ok = (lambda s, lo: s > lo) if m == "SR3_strict" else (lambda s, lo: s >= lo)
    out = None
    for g in SHOW["grades"]:
        if ok(sat, g["min_bp"]) or g["min_bp"] == 0:
            out = g["id"]
    return out


def delta(bg, g, gr, adm, m):
    b = B[gr]
    f = adm * 10000 // A["admissions_ref"]
    if m != "RG3_no_min":
        f = max(A["min_bp"], f)
    if m != "RG3_no_max":
        f = min(A["max_bp"], f)
    if b < 0:
        if m == "RG5_fail_bonus":
            pass
        return -((-b) * f // 10000), f, "none"
    s = sum(bg.values())
    fo = "none"
    c1 = (s > F["min_genre_sum"]) if m == "FC1_strict" else (s >= F["min_genre_sum"])
    if c1:
        eff = sum(bg[h] * AFF[g][h] for h in G) // s
        c3 = (eff > F["identity_share_bp"]) if m == "FC3_strict" else (eff >= F["identity_share_bp"])
        if c3:
            fo = "identity"
        elif m != "FC4_removed":
            if m == "FC4_strict":
                ok = all(bg[h] * 10000 > F["breadth_min_share_bp"] * s for h in G)
            elif m == "FC4_any":
                ok = any(bg[h] * 10000 >= F["breadth_min_share_bp"] * s for h in G)
            else:
                ok = all(bg[h] * 10000 >= F["breadth_min_share_bp"] * s for h in G)
            if ok:
                fo = "breadth"
    bonus = {"identity": F["identity_bonus_bp"], "breadth": F["breadth_bonus_bp"], "none": 0}[fo]
    if m == "RG5_single_floor":
        return b * f * (10000 + bonus) // 10**8, f, fo
    return (b * f // 10000) * (10000 + bonus) // 10000, f, fo


def run(sc, m):
    t, bg, ut, unl = 0, {g: 0 for g in G}, 1, []
    tot, dl, cds, fs = [], [], [], []
    for d in range(1, sc["days"] + 1):
        sh = sc["show_cycle"][(d - 1) % len(sc["show_cycle"])]
        if sh is not None:
            gr = grade(sh["satisfaction_bp"], m)
            cd, f, fo = delta(bg, sh["genre"], gr, sh["admissions"], m)
            if m == "RG6_no_floor":
                nt = t + cd
                bg[sh["genre"]] += cd
            else:
                nt = max(0, t + cd)
                bg[sh["genre"]] = max(0, bg[sh["genre"]] + cd)
            dl.append(nt - t)
            cds.append(cd)
            fs.append(f)
            t = nt
        else:
            dl.append(None)
            cds.append(None)
            fs.append(None)
        tot.append(t)
        c = sc["cash"]["start"] + sc["cash"]["per_day"] * d
        cond = (c > T2["unlock_cash"] if m == "TU3_cash_strict" else c >= T2["unlock_cash"]) and \
               (t > T2["unlock_reputation"] if m == "TU3_rep_strict" else t >= T2["unlock_reputation"])
        if m == "TU3_or":
            cond = c >= T2["unlock_cash"] or t >= T2["unlock_reputation"]
        if (m == "TU3_no_once_guard" or ut + 1 <= REP["tier_unlock"]["max_tier"]) and cond:
            ut += 1
            unl.append(d)
    return tot, dl, unl, cds, fs


# 문서 표(reputation.md "보정 판정 예" 7행 · "하루 Δ 표" 25칸)가 변이를 잡는지: RP4 / RP2 가 이 표를 단언한다고 가정.
FOCUS_TABLE = [
    ((0, 100, 0), ["none", "identity", "none"]), ((50, 50, 0), ["identity", "identity", "none"]),
    ((0, 50, 50), ["none", "identity", "identity"]), ((50, 0, 50), ["none", "none", "none"]),
    ((33, 33, 33), ["breadth"] * 3), ((20, 60, 20), ["breadth", "identity", "breadth"]), ((10, 90, 0), ["none", "identity", "none"]),
]
DELTA_TABLE = {"ok": [6, 9, 12, 10, 14], "good": [11, 18, 22, 21, 26], "rave": [16, 26, 32, 31, 38],
               "disaster": [-15, -24, -30, -24, -30], "poor": [-5, -8, -10, -8, -10]}


def table_caught(m):
    hit = []
    for ratio, exp in FOCUS_TABLE:
        bg = dict(zip(G, ratio))
        for g, e in zip(G, exp):
            if delta(bg, g, "good", 83, m)[2] != e:
                hit.append("보정 판정 예 " + str(ratio))
                break
    for gr, exp in DELTA_TABLE.items():
        got = [delta({g: 0 for g in G}, "indie", gr, a, m)[0] for a in (50, 83, 100)] + \
              [delta({"rock": 0, "indie": 500, "electronic": 0}, "indie", gr, a, m)[0] for a in (83, 100)]
        if got != exp:
            hit.append("하루 Δ 표 " + gr)
    return sorted(set(hit))


def boundary_caught(m):
    """데이터 테스트(test_show_reputation_data.gd)에 추가한 경계 케이스."""
    hit = []
    if delta({"rock": 0, "indie": 49, "electronic": 0}, "indie", "good", 83, m)[2] != "none":
        hit.append("FC1 49")
    if delta({"rock": 0, "indie": 50, "electronic": 0}, "indie", "good", 83, m)[2] != "identity":
        hit.append("FC1 50")
    if delta({"rock": 15, "indie": 15, "electronic": 70}, "rock", "good", 83, m)[2] != "breadth":
        hit.append("FC4 정확히 15%")
    return hit


MUTANTS = [
    ("SR3_strict", "SR3 `min_bp ≤ sat` → `<`", "SH2"),
    ("FC1_strict", "FC1 `S ≥ 50` → `>`", "RP4"),
    ("FC3_strict", "FC3 `eff ≥ 7000` → `>`", "RP4"),
    ("FC4_strict", "FC4 `점유 ≥ 15%` → `>`", "RP4"),
    ("FC4_any", "FC4 `모든 장르` → `어느 한 장르`", "RP4"),
    ("FC4_removed", "FC4 제거(관객 폭 보너스 없음)", "RP4"),
    ("RG3_no_min", "RG3 입장 계수 하한 제거", "RP2/RP3"),
    ("RG3_no_max", "RG3 입장 계수 상한 제거", "RP2/RP3"),
    ("RG5_single_floor", "RG5 이중 내림 → 한 번 내림", "RP2"),
    ("RG6_no_floor", "RG6 `max(0, …)` 제거", "RP3"),
    ("TU3_cash_strict", "TU3 `cash ≥` → `>`", "RP6"),
    ("TU3_rep_strict", "TU3 `total ≥` → `>`", "RP6"),
    ("TU3_or", "TU3 AND → OR", "RP6"),
    ("TU3_no_once_guard", "TU3 해금 1회 가드(`unlocked_tier`/`max_tier`) 제거", "RP6"),
]

print(f"{'변이':20} {'설명':44} {'담당 AC':8} 기준 시나리오 | 문서 표 | 경계 케이스")
for mid, desc, ac in MUTANTS:
    caught = []
    for sc in REP["reference_scenarios"]:
        tot, dl, unl, cds, fs = run(sc, mid)
        e = sc["expected"]
        if tot != e["total"] or dl != e["delta"] or unl != e["tier_unlocked_days"] or cds != e["computed_delta"] or fs != e["factor_bp"]:
            caught.append(sc["id"])
    if mid == "SR3_strict":
        # show.json 임계는 기준 시나리오 입력(6732/5730/…)이 경계가 아니므로 등급이 같다
        ins = [x["satisfaction_bp"] for sc in REP["reference_scenarios"] for x in sc["show_cycle"] if x]
        if any(grade(s, mid) != grade(s, "base") for s in ins):
            caught.append("reputation 입력 등급 변화")
        for s in (6732, 5730, 4600):
            if grade(s, mid) != grade(s, "base"):
                caught.append(f"show:{s}")
    tc, bc = table_caught(mid), boundary_caught(mid)
    print(f"{mid:20} {desc:44} {ac:8} {', '.join(caught) or '-'} | {', '.join(tc) or '-'} | {', '.join(bc) or '-'}")
