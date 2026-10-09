#!/usr/bin/env python3
"""SE-029 QA: audience.md 독립 재계산 + 상태 기계 시뮬레이션 (제품 코드 없음, 스펙 본문만 보고 옮긴 것).

  python3 tools/bot/audience_spec_check.py            # 손계산 대조 + 시드 0~39 시뮬 요약, 불일치가 있으면 exit 1
  python3 tools/bot/audience_spec_check.py --seeds 100

구성
  1) 입장 수 AD1~AD12 (PCG32 = Godot RandomNumberGenerator, FNV-1a 파생 시드)
  2) 커버리지 C0~C3 로 기준 배치 타일 집합 재구성 (viewing/sound/sight/bar)
  3) 상태 기계 T1~T15·UP1~UP6·P1·SF0~SF9 시뮬레이션(경로는 BFS; AStarGrid2D 와 동점 처리만 다를 수 있음)
audience.md 의 qa 스크립트(AU12)와 코드를 공유하지 않는다(독립 구현).
"""
import argparse, collections, json, os, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
D = os.path.join(ROOT, "project", "data")
def J(p): return json.load(open(os.path.join(D, p), encoding="utf-8"))
A = J("audience/audience.json"); ART = J("artist/artist.json"); MAP = J("maps/tier1_club.json")
FURN = {r["id"]: r for r in J("furniture/furniture.json")["rows"]}
T, AD, FL, SAT = A["types"], A["admission"], A["flow"], A["satisfaction"]
TY = {t["id"]: t for t in T}
SLOTS = {s["slot"]: s for s in ART["roster_plan"]["slots"]}
M64 = (1 << 64) - 1
# 경로 동점 처리 변형(AStarGrid2D 의 동점 처리는 구현이 정하므로 스펙이 어느 쪽에도 견디는지 본다)과 교착 해소안 실험
DIR_ORDERS = {"x": ((1, 0), (-1, 0), (0, 1), (0, -1)), "z": ((0, 1), (0, -1), (1, 0), (-1, 0)),
              "rev": ((-1, 0), (1, 0), (0, -1), (0, 1)), "revz": ((0, -1), (0, 1), (-1, 0), (1, 0))}
DIRS = DIR_ORDERS["x"]
PASS_OVERRIDE = 0   # 0 = audience.md 그대로. K > 0 = 연속 K 틱 막히면 pass_tile_cap 무시(권고안 실험, 스펙 밖)

def pcg(seed32):
    st = 0; inc = ((1442695040888963407 << 1) | 1) & M64
    def step():
        nonlocal st
        old = st; st = (old * 6364136223846793005 + inc) & M64
        xs = (((old >> 18) ^ old) >> 27) & 0xFFFFFFFF; rot = old >> 59
        return ((xs >> rot) | (xs << ((32 - rot) & 31))) & 0xFFFFFFFF
    step(); st = (st + seed32) & M64; step()
    return step

def derive(master, name):
    h = 2166136261
    for b in f"{master}:{name}".encode(): h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return h

def e_centi(lu, rep, price):
    out = []
    for t in T:
        if t["needs_lineup"] and lu is None: out.append(0); continue
        draw = t["base_centi"] + (t["popularity_centi"] * lu["popularity"] if lu else 0) + t["reputation_centi"] * min(rep, AD["reputation_cap"])
        fit = t["genre_fit_bp"][lu["genre"]] if lu else 10000
        pf = min(AD["price_factor_max_bp"], max(AD["price_factor_min_bp"], 10000 - t["price_sensitivity_bp"] * (price - AD["price_ref"])))
        out.append((draw * fit // 10000) * pf // 10000)
    return out

def split(adm, e):
    E = sum(e)
    if E == 0 or adm == 0: return [0] * len(e)
    n = [adm * x // E for x in e]; rem = [adm * x % E for x in e]
    for i in sorted(range(len(e)), key=lambda i: (-rem[i], i))[: adm - sum(n)]: n[i] += 1
    return n

def admissions(lu, rep, price, seed, cap):
    e = e_centi(lu, rep, price); E = sum(e)
    u = pcg(derive(seed, "audience"))(); nb = u % (2 * AD["noise_bp"] + 1) - AD["noise_bp"]
    raw = E * (10000 + nb) // 10**6
    return dict(e=e, E=E, u=u, noise=nb, raw=raw, adm=min(raw, cap, A["max_agents"]))

SCEN = {"no_lineup": (None, 0, 20), "local_top_baseline": (SLOTS["s07"], 0, 20),
        "rookie_baseline": (SLOTS["s08"], 150, 20), "local_top_price30": (SLOTS["s07"], 0, 30)}

# ---------------------------------------------------------------- 커버리지(기준 배치)
def kind(x, z):
    if x < 0 or z < 0 or x >= MAP["width"] or z >= MAP["depth"]: return None
    return {k["char"]: k for k in MAP["tile_kinds"]}[MAP["tiles"][z][x]]
def coverage(layout_id):
    lay = [l for l in MAP["reference_layouts"] if l["id"] == layout_id][0]
    insts = []; occ = set()
    for p in lay["placements"]:
        r = FURN[p["furniture_id"]]; fp = r["footprint"]; rot = p["rotation"]
        w, d = (fp[1], fp[0]) if rot in (90, 270) else (fp[0], fp[1]); cx, cz = p["cell"]
        cells = [(cx + x, cz + z) for z in range(d) for x in range(w)]; occ |= set(cells)
        insts.append((r, cells, rot, (cx, cz), (w, d)))
    ent = sorted((x, z) for z in range(MAP["depth"]) for x in range(MAP["width"]) if kind(x, z)["id"] == "entrance")
    seen = set(ent); q = collections.deque(ent)
    while q:
        x, z = q.popleft()
        for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            n = (x + dx, z + dz); k = kind(*n)
            if k and k["walkable"] and n not in seen and n not in occ: seen.add(n); q.append(n)
    view = []; focus = None
    for r, cells, rot, mn, sz in insts:
        if r["category"] != "stage": continue
        assert rot == 0, "기준 배치 무대는 회전 0"
        focus = (mn[0] + sz[0] // 2, mn[1])
        view = [(x, z) for z in range(MAP["depth"]) for x in range(MAP["width"]) if (x, z) in seen and kind(x, z)["standing"] and z < mn[1]]
    snd = set(); bar = set()
    for t in view:
        for r, cells, rot, mn, sz in insts:
            ddx = max(mn[0] - t[0], 0, t[0] - (mn[0] + sz[0] - 1)); ddz = max(mn[1] - t[1], 0, t[1] - (mn[1] + sz[1] - 1)); d2 = ddx * ddx + ddz * ddz
            sr = r["effects"]["sound_radius"]; br = r["effects"]["bar_service_radius"]
            if sr > 0 and d2 <= sr * sr: snd.add(t)
            if br > 0 and d2 <= br * br: bar.add(t)
    blk = {c for r, cells, rot, mn, sz in insts if r["effects"]["sight_block"] and r["category"] != "stage" for c in cells}
    def line(a, b):
        dx = abs(b[0] - a[0]); sx = 1 if a[0] < b[0] else -1; dz = -abs(b[1] - a[1]); sz = 1 if a[1] < b[1] else -1
        err = dx + dz; p = a; out = []
        while True:
            out.append(p)
            if p == b: break
            e2 = 2 * err
            if e2 >= dz: err += dz; p = (p[0] + sx, p[1])
            if e2 <= dx: err += dx; p = (p[0], p[1] + sz)
        return out
    sight = set()
    for t in view:
        if not any((kind(*c) is None) or kind(*c)["blocks_sight"] or c in blk for c in line(t, focus)[1:-1]): sight.add(t)
    return dict(view=view, snd=snd, sight=sight, bar=bar, ent=ent, occ=occ, expected=lay["expected"])

# ---------------------------------------------------------------- 상태 기계 시뮬레이션
def simulate(cv, lu, rep, price, seed, cap=None):
    cap = cap or cv["expected"]["capacity"]
    view, snd, sgt, bar, ent, occf = cv["view"], cv["snd"], cv["sight"], cv["bar"], cv["ent"], cv["occ"]
    bonus = cv["expected"]["satisfaction_bonus_bp"]
    def walk(t):
        k = kind(*t); return k is not None and k["walkable"] and t not in occf
    def bfs(a, b):
        if a == b: return []
        prev = {a: None}; q = collections.deque([a])
        while q:
            p = q.popleft()
            if p == b: break
            for d in DIRS:
                n = (p[0] + d[0], p[1] + d[1])
                if n not in prev and walk(n): prev[n] = p; q.append(n)
        if b not in prev: return None
        out = []; p = b
        while p != a: out.append(p); p = prev[p]
        return out[::-1]
    def cd(t, C):
        n = len(C); return (t[0] * n - sum(c[0] for c in C)) ** 2 + (t[1] * n - sum(c[1] for c in C)) ** 2
    Cs = sorted(snd) or view; Cb = sorted(bar)
    spot_rank = {}
    for ty in T:
        w = ty["spot_weights_bp"]
        spot_rank[ty["id"]] = sorted(view, key=lambda t: (-(w["sound"] * (t in snd) + w["sight"] * (t in sgt) + w["bar"] * (t in bar)), cd(t, Cs), t[1], t[0]))
    bar_rank = sorted(bar, key=lambda t: (cd(t, Cb), t[1], t[0]))
    ents = sorted(ent, key=lambda t: (t[1], t[0]))
    a = admissions(lu, rep, price, seed, cap); N = a["adm"]; n = split(N, a["e"])
    step = pcg(derive(seed, "audience")); step()
    L = []
    for i in range(3): L += [T[i]["id"]] * n[i]
    draws = 1
    for i in range(N - 1, 0, -1):
        j = step() % (i + 1); L[i], L[j] = L[j], L[i]; draws += 1
    quota = {T[i]["id"]: n[i] * T[i]["bar_visit_bp"] // 10000 for i in range(3)}; used = collections.Counter(); arr = []
    for k in range(N):
        ty = L[k]; arr.append(dict(id=1 + k, type=ty, spawn=k * FL["arrival_window_ticks"] // N, bar_planned=used[ty] < quota[ty])); used[ty] += 1
    agents = []; allag = []; occ = collections.Counter(); claims = collections.Counter(); left = []; buyers = 0
    def ot(x): return x["next"] or x["tile"]
    def release(x):
        if x["target"] is not None and x["tk"] in ("bar", "spot"): claims[x["target"]] -= 1
        x["target"] = None; x["tk"] = ""
    def pick(x, rank, kd):
        s = ot(x)
        for t in rank:
            if claims[t] < FL["spot_tile_cap"]:
                p = bfs(s, t)
                if p is None: continue
                claims[t] += 1; x["target"] = t; x["tk"] = kd; x["path"] = p; return True
        return False
    def lineup_bp(x):
        if lu is None: return SAT["no_lineup_bp"]
        return TY[x["type"]]["genre_fit_bp"][lu["genre"]] * min(10000, SAT["skill_base_bp"] + lu["skill"] * SAT["skill_bp_per_point"]) // 10000
    def satf(x, crowd):
        t = TY[x["type"]]; sh = x["show"]
        so = x["snd"] * 10000 // sh if sh else 0; si = x["sgt"] * 10000 // sh if sh else 0
        val = max(0, min(10000, SAT["price_value_mid_bp"] - t["price_sensitivity_bp"] * (price - AD["price_ref"])))
        wb = min(10000, x["wait"] * 10000 // t["patience_ticks"]); W = SAT["weights_bp"]; P = SAT["penalty_weights_bp"]
        return min(10000, max(0, W["lineup"] * lineup_bp(x) + W["sound"] * so + W["sight"] * si + W["value"] * val - P["crowd"] * crowd - P["wait"] * wb) // 10000 + bonus)
    def p1(x, reason, tick):
        x["sat"] = satf(x, 0); x["left"] = True; left.append((tick, x["id"], reason)); release(x); x["bar_planned"] = False
        if x["state"] == "queued": x["state"] = "gone"
        else:
            x["state"] = "leaving"; s = ot(x); best = None
            for e_ in ents:
                p = bfs(s, e_)
                if p is not None and (best is None or len(p) < len(best[1])): best = (e_, p)
            x["target"] = best[0]; x["tk"] = "exit"; x["path"] = best[1]
    def addwait(x, k, tick):
        x["wait"] += k
        if x["wait"] > TY[x["type"]]["patience_ticks"] and not x["left"]: p1(x, "patience", tick)
    ai = 0; maxwait = 0; last_seat = -1; unseated = 0
    for tk in range(600 + 900):
        phase = "evening" if tk < 600 else "show"; tip = tk if tk < 600 else tk - 600
        if phase == "evening":
            while ai < len(arr) and arr[ai]["spawn"] <= tip:
                x = dict(arr[ai], state="queued", tile=None, next=None, progress=0, target=None, tk="", path=[], enter_left=0, bar_left=0, wait=0, blk=0, show=0, snd=0, sgt=0, left=False, sat=-1)
                agents.append(x); allag.append(x); ai += 1
        for x in agents:
            s = x["state"]
            if s == "gone": continue
            if s == "queued":
                free = [e_ for e_ in ents if occ[e_] == 0]
                if free: x["state"] = "entering"; x["tile"] = free[0]; x["enter_left"] = FL["entry_ticks"]; occ[free[0]] += 1
                else: addwait(x, 1, tk)
            elif s == "entering":
                if x["enter_left"] > 1: x["enter_left"] -= 1
                else:
                    x["enter_left"] = 0; x["state"] = "moving"
                    if x["bar_planned"] and not pick(x, bar_rank, "bar"):
                        x["bar_planned"] = False; addwait(x, FL["bar_fail_wait_ticks"], tk)
                    if not x["left"] and x["target"] is None and not pick(x, spot_rank[x["type"]], "spot"): p1(x, "no_spot", tk)
            elif s in ("moving", "leaving"):
                def arrive():
                    if s == "moving": x["state"] = "at_bar" if x["tk"] == "bar" else "watching"; x["bar_left"] = FL["bar_ticks"]
                    else: occ[x["tile"]] -= 1; x["state"] = "gone"
                if x["next"] is not None:
                    x["progress"] += 1
                    if x["progress"] == FL["move_ticks_per_tile"]:
                        x["tile"] = x["next"]; x["next"] = None; x["progress"] = 0
                        if not x["path"]: arrive()
                elif x["path"]:
                    nt = x["path"][0]
                    if s == "leaving" or occ[nt] < FL["pass_tile_cap"] or (PASS_OVERRIDE and x["blk"] >= PASS_OVERRIDE):
                        occ[x["tile"]] -= 1; occ[nt] += 1; x["next"] = x["path"].pop(0); x["progress"] = 1; x["blk"] = 0
                    else: x["blk"] += 1; addwait(x, 1, tk)
                else: arrive()
            elif s == "at_bar":
                if x["bar_left"] > 1: x["bar_left"] -= 1
                else:
                    buyers += 1; x["bar_planned"] = False; release(x); x["state"] = "moving"
                    if not pick(x, spot_rank[x["type"]], "spot"): p1(x, "no_spot", tk)
            if phase == "show" and not x["left"] and x["state"] != "gone":
                x["show"] += 1
                if x["state"] in ("watching", "at_bar"): x["snd"] += x["tile"] in snd; x["sgt"] += x["tile"] in sgt
            if x["state"] == "watching" and x.get("seat") is None: x["seat"] = tk; last_seat = max(last_seat, tk)
        maxwait = max([maxwait] + [x["wait"] for x in agents])
        if tk == 599: unseated = sum(1 for x in allag if x["state"] != "watching" and not x["left"])
    aud = N - len(left); ratio = aud * 10000 // cap if cap else 10000; cb = SAT["crowd_comfort_bp"]
    crowd = 0 if ratio <= cb else min(10000, (ratio - cb) * 10000 // (10000 - cb))
    for x in allag:
        if not x["left"]: x["sat"] = satf(x, crowd)
    avg = sum(x["sat"] for x in allag) // N if N else 0
    return dict(N=N, left=len(left), events=left, buyers=buyers, maxwait=maxwait, last_seat=last_seat, unseated=unseated, crowd=crowd, avg=avg, draws=draws, noise=a["noise"], e=a["e"])

def main():
    global DIRS, PASS_OVERRIDE
    ap = argparse.ArgumentParser(); ap.add_argument("--seeds", type=int, default=40)
    ap.add_argument("--bfs-order", choices=sorted(DIR_ORDERS), default="x", help="경로 동점 처리 변형")
    ap.add_argument("--pass-override", type=int, default=0, help="권고안 실험: 연속 K 틱 막히면 pass_tile_cap 무시")
    args = ap.parse_args(); DIRS = DIR_ORDERS[args.bfs_order]; PASS_OVERRIDE = args.pass_override
    bad = []
    lay = {l["id"]: l["expected"] for l in MAP["reference_layouts"]}
    cv = coverage("baseline_show")
    both = cv["snd"] & cv["sight"]
    print(f"기준 배치 타일: 관람 {len(cv['view'])} 음향 {len(cv['snd'])} 시야 {len(cv['sight'])} 바 {len(cv['bar'])} | 음향∩시야 {len(both)} 음향만 {sorted(cv['snd'] - cv['sight'])} 바∩음향 {len(cv['bar'] & cv['snd'])}")
    for k, v in (("viewing_count", len(cv["view"])), ("sound_count", len(cv["snd"])), ("sight_count", len(cv["sight"])), ("bar_count", len(cv["bar"]))):
        if lay["baseline_show"][k] != v: bad.append((k, lay["baseline_show"][k], v))
    if (len(both), len(cv["snd"] - cv["sight"]), len(cv["bar"] & cv["snd"])) != (94, 2, 0): bad.append(("B2 전제 94/2/0", len(both)))
    print("\n| 시나리오 | E | u | noise | raw | adm | 배분 | 손계산 평균 | 시뮬 평균 | 조기퇴장 | 최대대기 | 마지막 착석 틱 | 공연 전 미착석 | 바 방문 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in A["reference_scenarios"]:
        lu, rep, price = SCEN[s["id"]]; x = s["expected"]; cap = min(lay[s["layout"]]["capacity"], A["max_agents"])
        a = admissions(lu, rep, price, s["seed"], cap); n = split(a["adm"], a["e"])
        got = dict(e_centi=dict(zip([t["id"] for t in T], a["e"])), expected_centi=a["E"], first_draw=a["u"], noise_bp=a["noise"], raw=a["raw"], admissions=a["adm"],
                   by_type=dict(zip([t["id"] for t in T], n)),
                   admissions_range_other_seeds=[min(a["E"] * (10000 - AD["noise_bp"]) // 10**6, cap), min(a["E"] * (10000 + AD["noise_bp"]) // 10**6, cap)])
        for k, v in got.items():
            if x[k] != v: bad.append((s["id"], k, x[k], v))
        r = simulate(cv, lu, rep, price, s["seed"], cap)
        if not (x["avg_satisfaction_bp_range"][0] <= r["avg"] <= x["avg_satisfaction_bp_range"][1]): bad.append((s["id"], "avg 범위", r["avg"]))
        if r["left"] != x["left_early"] or r["crowd"] != x["crowd_bp"]: bad.append((s["id"], "left/crowd", r["left"], r["crowd"]))
        if r["draws"] != max(1, r["N"]): bad.append((s["id"], "draws", r["draws"]))
        print(f"| {s['id']} | {a['E']} | {a['u']} | {a['noise']:+d} | {a['raw']} | {a['adm']} | {'/'.join(map(str, n))} | {x['avg_satisfaction_bp_hand']} | {r['avg']} | {r['left']} | {r['maxwait']} | {r['last_seat']} | {r['unseated']} | {r['buyers']} |")
    print(f"\n시드 0~{args.seeds - 1} 스윕 (조기 퇴장·미착석·최대 대기·평균 만족 최소/최대)")
    print("| 시나리오 | 입장 min~max | 범위 안 | 조기퇴장 max | 미착석 max | 최대대기 max | 마지막 착석 틱 max | 평균 만족 min~max |")
    print("|---|---|---|---|---|---|---|---|")
    for s in A["reference_scenarios"]:
        lu, rep, price = SCEN[s["id"]]; rg = s["expected"]["admissions_range_other_seeds"]; cap = min(lay[s["layout"]]["capacity"], A["max_agents"])
        rs = [simulate(cv, lu, rep, price, sd, cap) for sd in range(args.seeds)]
        inr = all(rg[0] <= r["N"] <= rg[1] for r in rs)
        wide = [admissions(lu, rep, price, sd, cap)["adm"] for sd in range(101)]
        if not all(rg[0] <= v <= rg[1] for v in wide): bad.append((s["id"], "시드 0~100 입장 범위"))
        if max(r["left"] for r in rs) or max(r["unseated"] for r in rs): bad.append((s["id"], "조기퇴장/미착석 발생"))
        print(f"| {s['id']} | {min(r['N'] for r in rs)}~{max(r['N'] for r in rs)} | {inr} | {max(r['left'] for r in rs)} | {max(r['unseated'] for r in rs)} | {max(r['maxwait'] for r in rs)} | {max(r['last_seat'] for r in rs)} | {min(r['avg'] for r in rs)}~{max(r['avg'] for r in rs)} |")
    lu = dict(SLOTS["s12"], popularity=100)
    for sd in (0, 1):
        r = simulate(cv, lu, 2000, 20, sd, 150)
        print(f"스트레스(수용 150·인기 100·명성 2000·시드 {sd}): 입장 {r['N']} 조기퇴장 {r['left']} 최대대기 {r['maxwait']} 마지막 착석 {r['last_seat']} 공연 전 미착석 {r['unseated']} 평균 {r['avg']}")
    print("MISMATCH:", bad or "없음"); return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
