#!/usr/bin/env python3
"""SE-030 QA 독립 손계산.

reputation.md 의 qa 스크립트를 복사하지 않고, 문서의 공식(RG2~RG6, FC1~FC4, TU1~TU4)을
Fraction 기반으로 다시 구현해 `reputation.json` `reference_scenarios` 의 리터럴과 대조한다.
스펙 스크립트와 다른 점: (1) 모든 나눗셈을 Fraction -> floor 로 계산(정수 // 와 교차 검증),
(2) 등급·티어 임계·신인 해금을 하드코딩 없이 JSON 에서 읽되 판정 코드는 별도로 작성,
(3) 경제 현금 계열을 economy.json 의 항목에서 S1~S12 로 재유도,
(4) 순환 순서 6가지, 시작 장르별 변형, 입장 수 민감도를 추가로 돌린다.

사용: python3 tools/bot/se030_hand_calc.py   (리포 루트, 읽기 전용)
종료 코드 0 = 전부 일치.
"""
import json
import sys
from fractions import Fraction
from itertools import permutations
from math import floor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
D = ROOT / "project" / "data"


def load(rel):
    with open(D / rel, encoding="utf-8") as f:
        return json.load(f)


REP = load("reputation/reputation.json")
SHOW = load("show/show.json")
ART = load("artist/artist.json")
GEN = load("genres/genres.json")
TIERS = load("tiers/tiers.json")
ECO = load("economy/economy.json")

GENRES = ART["mvp_genres"]
SCALE = ECO["rate_scale"]
BASE = REP["base_by_grade"]
ADM = REP["admission_factor"]
FOC = REP["focus"]
errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


# ---- affinity (U3: roundi(affinity x 10000), Godot roundi = 반올림 half away from zero) ----
rows = {r["id"]: r for r in GEN["rows"]}
AFF = {g: {h: int(Fraction(rows[g]["affinity"][h]).limit_denominator(1000) * SCALE + Fraction(1, 2)) for h in GENRES} for g in GENRES}


def grade_of(sat):
    chosen = None
    for g in SHOW["grades"]:
        if sat >= g["min_bp"]:
            chosen = g["id"]
    return chosen


def factor(adm):
    raw = floor(Fraction(adm * SCALE, ADM["admissions_ref"]))
    return min(max(raw, ADM["min_bp"]), ADM["max_bp"])


def focus_for(by_genre, g):
    s = sum(by_genre.values())
    if s < FOC["min_genre_sum"]:
        return "none", -1
    eff = floor(Fraction(sum(by_genre[h] * AFF[g][h] for h in GENRES), s))
    if eff >= FOC["identity_share_bp"]:
        return "identity", eff
    # FC4: 모든 장르 점유율 >= 15% (분수 비교)
    if all(Fraction(by_genre[h], s) >= Fraction(FOC["breadth_min_share_bp"], SCALE) for h in GENRES):
        return "breadth", eff
    return "none", eff


def computed_delta(by_genre, g, grade, adm):
    b = BASE[grade]
    f = factor(adm)
    if b < 0:
        return -floor(Fraction(-b * f, SCALE)), f, "none"
    fk, _ = focus_for(by_genre, g)
    bonus = {"none": 0, "identity": FOC["identity_bonus_bp"], "breadth": FOC["breadth_bonus_bp"]}[fk]
    first = floor(Fraction(b * f, SCALE))
    return floor(Fraction(first * (SCALE + bonus), SCALE)), f, fk


def run(cycle, days, cash):
    total = 0
    by = {g: 0 for g in GENRES}
    unlocked = 1
    out = {k: [] for k in ("grade", "factor_bp", "focus", "computed_delta", "delta", "total")}
    unl_days = []
    t2 = TIERS["rows"][1]
    for d in range(1, days + 1):
        sh = cycle[(d - 1) % len(cycle)]
        if sh is None:
            for k in ("grade", "factor_bp", "focus", "computed_delta", "delta"):
                out[k].append(None)
        else:
            gr = grade_of(sh["satisfaction_bp"])
            cd, f, fk = computed_delta(by, sh["genre"], gr, sh["admissions"])
            new_total = max(0, total + cd)
            by[sh["genre"]] = max(0, by[sh["genre"]] + cd)
            out["grade"].append(gr)
            out["factor_bp"].append(f)
            out["focus"].append(fk)
            out["computed_delta"].append(cd)
            out["delta"].append(new_total - total)
            total = new_total
        out["total"].append(total)
        c = cash["start"] + cash["per_day"] * d
        if unlocked + 1 <= REP["tier_unlock"]["max_tier"] and c >= t2["unlock_cash"] and total >= t2["unlock_reputation"]:
            unlocked += 1
            unl_days.append(d)
    out["by_genre_final"] = by
    out["tier_unlocked_days"] = unl_days
    return out


def first_day(series, thr):
    return next((i + 1 for i, v in enumerate(series) if v >= thr), None)


# ---- 경제 현금 계열 재유도 (economy.json tier1_baseline, S1~S12) ----
es = next(s for s in ECO["reference_scenarios"] if s["id"] == "tier1_baseline")
ex = es["expected"]
ticket = es["admissions"] * 20  # ticket_price_default 20
check(ticket == ex["ticket_revenue"], f"S1 ticket {ticket} != {ex['ticket_revenue']}")
revenue = ex["ticket_revenue"] + ex["bar_revenue"]
op = ex["rent"] + ex["upkeep"] + ex["guarantee"] + ex["bar_cost"]
pretax = revenue - op
tax = floor(Fraction(pretax * ECO.get("tax_rate_bp", 1000), SCALE)) if pretax > 0 else 0
net = pretax - tax
print(f"economy 재유도: revenue {revenue} op {op} pretax {pretax} tax {tax} net {net} (json {ex['net']})")
check(net == ex["net"] == 1142, "net != 1142")
cash0 = ECO["starting_cash"] - es["initial_build_spend"]
cash_series = [cash0 + net * d for d in range(1, 31)]
print("cash 24일", cash_series[23], "25일", cash_series[24])
check(cash_series[23] == 29408 and cash_series[24] == 30550, "cash 24/25")
t2 = TIERS["rows"][1]
cash_day = first_day(cash_series, t2["unlock_cash"])
print("자금 30,000 도달일", cash_day)

# ---- 부록 A: 일별 손계산 (문서 표와 같은 순서로 직접 전개) ----
print("\n== 부록 A 직접 전개 (indie 매일, 83명, 6732) ==")
sat, adm = 6732, 83
grade = grade_of(sat)
b = BASE[grade]
f = factor(adm)
print(f"grade {grade} b {b} f {f} 기본 floor(22*0.83)={floor(Fraction(b * f, SCALE))}")
total, S = 0, 0
series = []
for d in range(1, 31):
    if S < FOC["min_genre_sum"]:
        delta = floor(Fraction(b * f, SCALE))
        why = "none"
    else:
        # indie only: eff = S*10000/S = 10000 >= 7000 -> identity
        delta = floor(Fraction(floor(Fraction(b * f, SCALE)) * (SCALE + FOC["identity_bonus_bp"]), SCALE))
        why = "identity"
    S += delta
    total += delta
    series.append(total)
    if d <= 5 or d in (7, 8, 24, 25, 30):
        print(f"  d{d:>2} focus {why:8} delta {delta} total {total}")
check(series == REP["reference_scenarios"][0]["expected"]["total"], "부록 A 30일 total != json")
d150 = first_day(series, next(g for g in ART["grades"] if g["id"] == "rookie")["unlock_reputation"])
d500 = first_day(series, t2["unlock_reputation"])
print(f"150 도달 {d150}일, 500 도달 {d500}일 (24일 {series[23]}, 25일 {series[24]}), 자금 {cash_day}일")
unl = next((d for d in range(1, 31) if cash_series[d - 1] >= t2["unlock_cash"] and series[d - 1] >= t2["unlock_reputation"]), None)
print("해금일", unl)
check((d150, d500, cash_day, unl) == (8, 25, 25, 25), "핵심 날짜 != (8,25,25,25)")

# ---- 4개 시나리오를 JSON 리터럴과 대조 ----
print("\n== reference_scenarios 대조 ==")
for sc in REP["reference_scenarios"]:
    got = run(sc["show_cycle"], sc["days"], sc["cash"])
    cs = [sc["cash"]["start"] + sc["cash"]["per_day"] * d for d in range(1, sc["days"] + 1)]
    got["day_reach_rookie_unlock"] = first_day(got["total"], 150)
    got["day_reach_tier2_reputation"] = first_day(got["total"], t2["unlock_reputation"])
    got["day_reach_tier2_cash"] = first_day(cs, t2["unlock_cash"])
    bad = [k for k, v in got.items() if sc["expected"][k] != v]
    print(f"  {sc['id']:22} 150:{got['day_reach_rookie_unlock']} 500:{got['day_reach_tier2_reputation']} cash:{got['day_reach_tier2_cash']} unlock:{got['tier_unlocked_days']} end:{got['total'][-1]} 불일치:{bad or '없음'}")
    for k in bad:
        errors.append(f"{sc['id']}.{k} 불일치")
    if sc.get("cash_from_economy_scenario"):
        check(sc["cash"] == {"start": cash0, "per_day": net}, sc["id"] + " 현금 계열 != 재유도")

# ---- 순환 순서 6가지 ----
print("\n== 순환 순서 6가지(rock/indie/electronic, 83명 호평) ==")
for perm in permutations(GENRES):
    cyc = [{"genre": g, "satisfaction_bp": 6732, "admissions": 83} for g in perm]
    r = run(cyc, 30, {"start": cash0, "per_day": net})
    print(f"  {'>'.join(perm):28} 500:{first_day(r['total'], 500)} 해금:{r['tier_unlocked_days']} focus 4~6일:{r['focus'][3:6]} end:{r['total'][-1]} by:{list(r['by_genre_final'].values())}")
    check(first_day(r["total"], 500) == 25, f"순환 {perm} 500 도달 != 25")

# ---- 호평 경계 민감도 (입장 수 / 등급) ----
print("\n== 민감도: indie 매일, 호평, 입장 수별 500 도달일 ==")
for a in (40, 50, 60, 70, 83, 90, 100, 122):
    r = run([{"genre": "indie", "satisfaction_bp": 6732, "admissions": a}], 60, {"start": cash0, "per_day": net})
    print(f"  입장 {a:>3}: f={factor(a):>5} 500 도달 {first_day(r['total'], 500)}일, 150 도달 {first_day(r['total'], 150)}일, 일 Δ(정체성) {r['computed_delta'][10]}")
print("== 민감도: 등급별(83명, indie 매일) 500 도달일 ==")
for name, s in (("ok", 5500), ("good", 6732), ("rave", 7600)):
    r = run([{"genre": "indie", "satisfaction_bp": s, "admissions": 83}], 80, {"start": cash0, "per_day": net})
    print(f"  {name:5}: 500 도달 {first_day(r['total'], 500)}일, 일 Δ(정체성) {r['computed_delta'][10]}")
print("== 민감도: 호평 하한 직전(5999)/직후(6000) 500 도달일 ==")
for s in (5999, 6000):
    r = run([{"genre": "indie", "satisfaction_bp": s, "admissions": 83}], 80, {"start": cash0, "per_day": net})
    print(f"  만족 {s}: 등급 {grade_of(s)} 500 도달 {first_day(r['total'], 500)}일")
print("== 민감도: 호평/보통 혼합(호평 비율 p, 10일 주기 83명 indie) ==")
for goods in (10, 9, 8, 7, 6, 5):
    cyc = [{"genre": "indie", "satisfaction_bp": 6732 if i < goods else 5500, "admissions": 83} for i in range(10)]
    r = run(cyc, 80, {"start": cash0, "per_day": net})
    print(f"  호평 {goods}/10: 500 도달 {first_day(r['total'], 500)}일, 해금 {r['tier_unlocked_days']}")

# ---- AC3 데이터 성질 ----
print("\n== AC3 / AC4 성질 ==")
mins = [g["min_bp"] for g in SHOW["grades"]]
check(all(b > a for a, b in zip(mins, mins[1:])), "임계 단조")
bs = [BASE[g] for g in ART["show_grades"]]
check(all(b > a for a, b in zip(bs, bs[1:])), "base 단조")
check(BASE["disaster"] < 0 and BASE["poor"] < 0, "실패 base 음수")
# 입장 0~무한대 전 범위에서 실패 Δ < 0
neg_ok = all(computed_delta({g: 0 for g in GENRES}, "indie", gr, a)[0] < 0 for gr in ("disaster", "poor") for a in list(range(0, 400)) + [10**6])
print("실패 Δ < 0 (입장 0~399, 10^6):", neg_ok)
check(neg_ok, "실패 Δ 가 어떤 입장 수에서 0 이상")
# 하한: 총합·장르별 각각, 무작위 아닌 결정적 입력 열 (실패 연속)
r = run([{"genre": "rock", "satisfaction_bp": 1000, "admissions": 10}] * 20, 20, {"start": 0, "per_day": 0})
check(min(r["total"]) >= 0 and min(r["by_genre_final"].values()) >= 0, "하한 0")
# total 과 장르가 따로 하한되는 경우 (RG6 / Q7): 장르별 0 인 장르의 실패 -> total 은 감소
mix = [{"genre": "indie", "satisfaction_bp": 6732, "admissions": 83}] * 3 + [{"genre": "rock", "satisfaction_bp": 1000, "admissions": 83}]
r = run(mix * 1, 4, {"start": 0, "per_day": 0})
print(f"RG6 total/장르 분리 예: indie 3일 호평 후 rock 참사 -> total {r['total']} by {r['by_genre_final']}")
check(r["total"][-1] == 54 - 24 and r["by_genre_final"]["rock"] == 0, "RG6 분리")
print("affinity_bp:", AFF)
for g in GENRES:
    check(AFF[g][g] == SCALE, f"대각 {g}")
    for h in GENRES:
        check(AFF[g][h] == AFF[h][g], f"대칭 {g}-{h}")

# ---- reputation.md "보정 판정 예" 7행 대조 (비율 rock/indie/electronic -> 오늘 장르별 eff_bp, focus) ----
print("\n== 보정 판정 예 7행 ==")
TABLE = [
    ((0, 100, 0), [(5000, "none"), (10000, "identity"), (4000, "none")]),
    ((50, 50, 0), [(7500, "identity"), (7500, "identity"), (3000, "none")]),
    ((0, 50, 50), [(3500, "none"), (7000, "identity"), (7000, "identity")]),
    ((50, 0, 50), [(6000, "none"), (4500, "none"), (6000, "none")]),
    ((33, 33, 33), [(5666, "breadth"), (6333, "breadth"), (5333, "breadth")]),
    ((20, 60, 20), [(5400, "breadth"), (7800, "identity"), (4800, "breadth")]),
    ((10, 90, 0), [(5500, "none"), (9500, "identity"), (3800, "none")]),
]
for ratio, exp in TABLE:
    by = dict(zip(GENRES, ratio))
    for g, (eff_e, fk_e) in zip(GENRES, exp):
        fk, eff = focus_for(by, g)
        ok = (fk, eff) == (fk_e, eff_e)
        if not ok:
            errors.append(f"보정 예 {ratio} {g}: {(fk, eff)} != {(fk_e, eff_e)}")
    print("  ", ratio, "OK" if not any(str(ratio) in e for e in errors) else "불일치")

print("\n" + ("\n".join(errors) if errors else "HAND OK"))
sys.exit(1 if errors else 0)
