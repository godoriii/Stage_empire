#!/usr/bin/env python3
"""SE-032 QA: build.md 독립 오라클 + 차분 테스트 픽스처 생성기.

GDScript 구현(project/world/)을 전혀 읽지 않고 docs/gdd/build.md 의 규칙(G1~G6, B1~B10, D1~D4, C0~C8)만으로
파이썬에서 다시 구현했다. 난수 명령 열(고정 시드)을 오라클에 돌려 단계별 결과를 JSON 픽스처로 쓰면,
project/tests/sim/test_build_oracle_qa.gd 가 같은 명령 열을 BuildSystem + Economy 에 돌려 단계마다 대조한다.

  python3 tools/bot/build_oracle.py --write      # project/tests/sim/fixtures/build_oracle.json 갱신
  python3 tools/bot/build_oracle.py --check      # 픽스처가 오라클 결과와 같은지(커밋된 픽스처 검증)
  python3 tools/bot/build_oracle.py --layouts    # tier1_club.json reference_layouts expected 독립 재계산·대조

데이터 파일(furniture.json, tier1_club.json, tiers.json, economy.json)은 읽기만 한다.
"""
import json
import os
import random
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DATA = os.path.join(ROOT, "project", "data")
FIXTURE = os.path.join(ROOT, "project", "tests", "sim", "fixtures", "build_oracle.json")

SEED = 20261009
EPISODES = 8
COMMANDS_PER_EPISODE = 100
BIG_CASH = 1_000_000  # 자금 부족을 배제해 규칙 판정만 비교한다 (자금 부족은 BC14 가 따로)


def load(*parts):
    with open(os.path.join(DATA, *parts), encoding="utf-8") as f:
        return json.load(f)


class World:
    def __init__(self):
        self.F = load("furniture", "furniture.json")
        self.M = load("maps", "tier1_club.json")
        self.T = load("tiers", "tiers.json")
        self.E = load("economy", "economy.json")
        self.rows = {r["id"]: r for r in self.F["rows"]}
        self.kinds = {k["char"]: k for k in self.M["tile_kinds"]}
        self.W = self.M["width"]
        self.D = self.M["depth"]
        self.tiles = self.M["tiles"]
        self.scale = self.E["rate_scale"]
        self.refund_bp = self.E["demolish_refund_rate_bp"]
        tier = [r for r in self.T["rows"] if r["tier"] == self.M["tier"]][0]
        self.cap_max = tier["capacity_max"]
        self.rules = self.F["build_rules"]
        self.entrances = [(x, z) for z in range(self.D) for x in range(self.W)
                          if self.kind(x, z)["id"] == "entrance"]
        self.evac_tiles = sum(self.kind(x, z)["evac_capacity"] for z in range(self.D) for x in range(self.W))

    def inside(self, x, z):
        return 0 <= x < self.W and 0 <= z < self.D

    def kind(self, x, z):
        return self.kinds[self.tiles[z][x]]


def rect(w, fid, cell, rot):
    fw, fd = w.rows[fid]["footprint"]
    if rot in (90, 270):
        fw, fd = fd, fw
    return cell[0], cell[1], cell[0] + fw - 1, cell[1] + fd - 1  # x0 z0 x1 z1


def cells_of(r):
    x0, z0, x1, z1 = r
    return [(x, z) for z in range(z0, z1 + 1) for x in range(x0, x1 + 1)]


def back_neighbors(r, rot):
    x0, z0, x1, z1 = r
    if rot == 0:
        return [(x, z1 + 1) for x in range(x0, x1 + 1)]
    if rot == 90:
        return [(x1 + 1, z) for z in range(z0, z1 + 1)]
    if rot == 180:
        return [(x, z0 - 1) for x in range(x0, x1 + 1)]
    return [(x0 - 1, z) for z in range(z0, z1 + 1)]


def front_row(r, rot):
    x0, z0, x1, z1 = r
    if rot == 0:
        return [(x, z0 - 1) for x in range(x0, x1 + 1)]
    if rot == 90:
        return [(x0 - 1, z) for z in range(z0, z1 + 1)]
    if rot == 180:
        return [(x, z1 + 1) for x in range(x0, x1 + 1)]
    return [(x1 + 1, z) for z in range(z0, z1 + 1)]


def in_front(r, rot, x, z):
    x0, z0, x1, z1 = r
    return {0: z < z0, 90: x < x0, 180: z > z1, 270: x > x1}[rot]


def focal(r, rot):
    x0, z0, x1, z1 = r
    if rot == 0:
        e = [(x, z0) for x in range(x0, x1 + 1)]
    elif rot == 90:
        e = [(x0, z) for z in range(z0, z1 + 1)]
    elif rot == 180:
        e = [(x, z1) for x in range(x0, x1 + 1)]
    else:
        e = [(x1, z) for z in range(z0, z1 + 1)]
    return e[len(e) // 2]


def reach(w, blocked):
    seen = set()
    q = []
    for e in w.entrances:
        if e not in blocked:
            seen.add(e)
            q.append(e)
    while q:
        x, z = q.pop(0)
        for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            n = (x + dx, z + dz)
            if n in seen or n in blocked or not w.inside(*n) or not w.kind(*n)["walkable"]:
                continue
            seen.add(n)
            q.append(n)
    return seen


def bres(a, b):
    (x0, z0), (x1, z1) = a, b
    dx = abs(x1 - x0)
    sx = 1 if x0 < x1 else -1
    dz = -abs(z1 - z0)
    sz = 1 if z0 < z1 else -1
    err = dx + dz
    x, z = x0, z0
    out = []
    while True:
        out.append((x, z))
        if (x, z) == (x1, z1):
            break
        e2 = 2 * err
        if e2 >= dz:
            err += dz
            x += sx
        if e2 <= dx:
            err += dx
            z += sz
    return out


def d2(r, x, z):
    x0, z0, x1, z1 = r
    dx = max(x0 - x, 0, x - x1)
    dz = max(z0 - z, 0, z - z1)
    return dx * dx + dz * dz


def coverage(w, insts):
    rs = [rect(w, i["fid"], i["cell"], i["rot"]) for i in insts]
    rows = [w.rows[i["fid"]] for i in insts]
    blocked = set()
    for r in rs:
        blocked.update(cells_of(r))
    R = reach(w, blocked)
    floor_free = sum(1 for t in R if w.kind(*t)["standing"])
    stage = next((k for k, row in enumerate(rows) if row["category"] == "stage"), None)
    viewing = []
    g = None
    if stage is not None:
        sr, srot = rs[stage], insts[stage]["rot"]
        g = focal(sr, srot)
        for z in range(w.D):
            for x in range(w.W):
                if (x, z) in R and w.kind(x, z)["standing"] and in_front(sr, srot, x, z):
                    viewing.append((x, z))
    sightblock = set()
    for k, row in enumerate(rows):
        if k != stage and row["effects"]["sight_block"]:
            sightblock.update(cells_of(rs[k]))

    def covered(field, t):
        for k, row in enumerate(rows):
            rad = row["effects"][field]
            if rad > 0 and d2(rs[k], *t) <= rad * rad:
                return True
        return False

    sound = [t for t in viewing if covered("sound_radius", t)]
    bar = [t for t in viewing if covered("bar_service_radius", t)]
    sight = []
    for t in viewing:
        mid = bres(t, g)[1:-1]
        if not any(w.kind(*c)["blocks_sight"] or c in sightblock for c in mid):
            sight.append(t)
    vc = len(viewing)

    def bp(n):
        return 0 if vc == 0 else n * w.scale // vc

    cap_add = sum(r["effects"]["capacity_add"] for r in rows)
    capacity = min(w.cap_max, floor_free * w.M["persons_per_tile_bp"] // w.scale + cap_add)
    evac = w.evac_tiles + sum(r["effects"]["evac_capacity"] for r in rows)
    sat = min(w.rules["satisfaction_bonus_cap_bp"], sum(r["effects"]["satisfaction_bonus_bp"] for r in rows))
    return {
        "has_stage": stage is not None,
        "floor_free": floor_free,
        "viewing_count": vc,
        "sound_count": len(sound),
        "sight_count": len(sight),
        "bar_count": len(bar),
        "sound_bp": bp(len(sound)),
        "sight_bp": bp(len(sight)),
        "bar_bp": bp(len(bar)),
        "capacity": capacity,
        "evac_capacity": evac,
        "evac_shortfall": max(0, capacity - evac),
        "light_grade": sum(r["effects"]["light_grade"] for r in rows),
        "satisfaction_bonus_bp": sat,
        "upkeep_per_day": sum(r["upkeep_per_day"] for r in rows),
    }


class Sim:
    """한 에피소드의 오라클 상태."""

    def __init__(self, w):
        self.w = w
        self.insts = []  # {eid, fid, cell, rot, paid}
        self.next = 1
        self.cash = BIG_CASH

    def occupied(self):
        s = set()
        for i in self.insts:
            s.update(cells_of(rect(self.w, i["fid"], i["cell"], i["rot"])))
        return s

    def check(self, fid, cell, rot):
        w = self.w
        if fid not in w.rows:
            return "unknown_furniture"
        row = w.rows[fid]
        if rot not in w.rules["allowed_rotations"] or (not row["rotatable"] and rot != 0):
            return "bad_rotation"
        r = rect(w, fid, cell, rot)
        cs = cells_of(r)
        if any(not w.inside(*c) for c in cs):
            return "out_of_bounds"
        if any(not w.kind(*c)["buildable"] for c in cs):
            return "blocked_tile"
        occ = self.occupied()
        if any(c in occ for c in cs):
            return "overlap"
        if row["wall_required"]:
            for c in back_neighbors(r, rot):
                if not (w.inside(*c) and w.kind(*c)["mountable"]):
                    return "wall_required"
        lim = w.rules["category_max_count"].get(row["category"])
        if lim is not None and sum(1 for i in self.insts if w.rows[i["fid"]]["category"] == row["category"]) >= lim:
            return "limit_reached"
        r0 = reach(w, occ)
        r1 = reach(w, occ | set(cs))
        if any(t not in cs and t not in r1 for t in r0):
            return "path_blocked"
        st = next((i for i in self.insts if w.rows[i["fid"]]["category"] == "stage"), None)
        if row["category"] == "stage":
            fr, frot = r, rot
        elif st is not None:
            fr, frot = rect(w, st["fid"], st["cell"], st["rot"]), st["rot"]
        else:
            fr = None
        if fr is not None and not any(c in r1 for c in front_row(fr, frot)):
            return "path_blocked"
        return ""

    def place(self, fid, cell, rot):
        why = self.check(fid, cell, rot)
        if why:
            return why
        cost = self.w.rows[fid]["build_cost"]
        if cost > self.cash:
            return "insufficient_cash"
        self.cash -= cost
        eid = "f%d" % self.next
        self.next += 1
        self.insts.append({"eid": eid, "fid": fid, "cell": list(cell), "rot": rot, "paid": cost})
        return "placed:" + eid

    def demolish(self, eid):
        for k, i in enumerate(self.insts):
            if i["eid"] == eid:
                del self.insts[k]
                self.cash += i["paid"] * self.w.refund_bp // self.w.scale
                return "demolished:" + eid
        return "not_found"


COV_KEYS = [
    "has_stage", "floor_free", "viewing_count", "sound_count", "sight_count", "bar_count", "sound_bp", "sight_bp",
    "bar_bp", "capacity", "evac_capacity", "evac_shortfall", "light_grade", "satisfaction_bonus_bp", "upkeep_per_day",
]
SMALL = ["speaker_floor", "stage_monitor", "light_spot", "light_moving_head", "fog_machine", "standing_table",
         "bench", "poster_board", "fire_extinguisher", "exit_sign"]


def gen_episode(w, rng):
    """오라클 상태를 따라가며 명령을 만든다(철거는 실제 존재하는 id 위주). 반환 (명령 목록, 단계 목록)."""
    ids = sorted(w.rows)
    sim = Sim(w)
    cmds, steps = [], []
    for n in range(COMMANDS_PER_EPISODE):
        roll = rng.random()
        if n == 0 and rng.random() < 0.8:
            c = {"op": "place", "furniture_id": rng.choice(["stage_small", "stage_medium"]),
                 "cell": [rng.randint(3, 17), rng.randint(14, 19)], "rotation": rng.choice([0, 90, 180, 270])}
        elif roll < 0.10 and sim.insts:
            c = {"op": "demolish", "entity_id": rng.choice(sim.insts)["eid"]}
        elif roll < 0.12:
            c = {"op": "demolish", "entity_id": "f%d" % rng.randint(90, 99)}
        else:
            mode = rng.random()
            if mode < 0.30:       # 벽 근처: 벽 필요 가구·B8 다중 타일 부분 일치 경계
                fid = rng.choice(ids)
                side = rng.choice(["n", "s", "w", "e"])
                a = rng.randint(1, 22)
                cell = {"n": [a, 1], "s": [a, 22], "w": [1, a], "e": [22, a]}[side]
            elif mode < 0.45:     # 모서리 고립(B10 (a)): 1x1·2x1 을 모서리 3칸 안에
                fid = rng.choice(SMALL)
                cell = [rng.choice([1, 2, 3, 20, 21, 22]), rng.choice([1, 2, 3, 20, 21, 22])]
            elif mode < 0.55:     # 입구 주변 좁은 통로
                fid = rng.choice(SMALL)
                cell = [rng.randint(8, 15), rng.randint(1, 3)]
            elif mode < 0.70:     # 무대 앞쪽 띠(B10 (b))
                fid = rng.choice(SMALL + ["bench", "bar_counter", "locker"])
                cell = [rng.randint(2, 21), rng.randint(15, 20)]
            else:
                fid = rng.choice(ids) if rng.random() > 0.02 else "stage_huge"
                cell = [rng.randint(-1, 23), rng.randint(-1, 23)]
            rot = rng.choice([0, 90, 180, 270]) if rng.random() > 0.03 else 45
            c = {"op": "place", "furniture_id": fid, "cell": cell, "rotation": rot}
        if c["op"] == "place":
            res = sim.place(c["furniture_id"], tuple(c["cell"]), c["rotation"])
        else:
            res = sim.demolish(c["entity_id"])
        cov = coverage(w, sim.insts)
        cmds.append(c)
        steps.append({"result": res, "cash": sim.cash, "cov": [int(cov[k]) for k in COV_KEYS]})
    return cmds, steps


def build_fixture():
    w = World()
    rng = random.Random(SEED)
    eps = []
    for _ in range(EPISODES):
        cmds, steps = gen_episode(w, rng)
        eps.append({"commands": cmds, "steps": steps})
    return {"seed": SEED, "big_cash": BIG_CASH, "cov_keys": COV_KEYS, "episodes": eps}


def summary(fx):
    from collections import Counter
    c = Counter()
    for ep in fx["episodes"]:
        for s in ep["steps"]:
            c[s["result"].split(":")[0]] += 1
    return dict(c)


def layouts():
    w = World()
    all_ok = True
    for lay in w.M["reference_layouts"]:
        ok = True
        exp = lay["expected"]
        sim = Sim(w)
        sim.cash = w.E["starting_cash"]
        for p in lay["placements"]:
            res = sim.place(p["furniture_id"], tuple(p["cell"]), p["rotation"])
            if not res.startswith("placed"):
                print("  배치 실패", lay["id"], p, res)
                ok = False
        cov = coverage(w, sim.insts)
        got = dict(cov)
        got["build_cost"] = sum(i["paid"] for i in sim.insts)
        got["cash_after"] = sim.cash
        got["sight_blocked_cells"] = []
        # 시야 차단 셀 목록 (G6 순서)
        rs = [rect(w, i["fid"], i["cell"], i["rot"]) for i in sim.insts]
        blocked = set()
        for r in rs:
            blocked.update(cells_of(r))
        st = next((k for k, i in enumerate(sim.insts) if w.rows[i["fid"]]["category"] == "stage"), None)
        if st is not None:
            g = focal(rs[st], sim.insts[st]["rot"])
            sb = set()
            for k, i in enumerate(sim.insts):
                if k != st and w.rows[i["fid"]]["effects"]["sight_block"]:
                    sb.update(cells_of(rs[k]))
            R = reach(w, blocked)
            cut = []
            for z in range(w.D):
                for x in range(w.W):
                    t = (x, z)
                    if t in R and w.kind(x, z)["standing"] and in_front(rs[st], sim.insts[st]["rot"], x, z):
                        mid = bres(t, g)[1:-1]
                        if any(w.kind(*c)["blocks_sight"] or c in sb for c in mid):
                            cut.append([x, z])
            got["sight_blocked_cells"] = cut
        for k, v in exp.items():
            if got.get(k) != v:
                print("  불일치", lay["id"], k, "오라클", got.get(k), "데이터", v)
                ok = False
        print("%s: %s (%d키 대조)" % (lay["id"], "일치" if ok else "불일치", len(exp)))
        all_ok = all_ok and ok
    # BC21: baseline_show + 스피커 2
    lay = [l for l in w.M["reference_layouts"] if l["id"] == "baseline_show"][0]
    sim = Sim(w)
    for p in lay["placements"] + [
        {"furniture_id": "speaker_floor", "cell": [5, 10], "rotation": 0},
        {"furniture_id": "speaker_floor", "cell": [18, 10], "rotation": 0},
    ]:
        assert sim.place(p["furniture_id"], tuple(p["cell"]), p["rotation"]).startswith("placed")
    cov = coverage(w, sim.insts)
    bc21 = (cov["viewing_count"], cov["sound_count"], cov["sound_bp"])
    print("BC21 오라클:", bc21, "문서 (403, 313, 7766)", "일치" if bc21 == (403, 313, 7766) else "불일치")
    return all_ok and bc21 == (403, 313, 7766)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--write"
    if mode == "--layouts":
        sys.exit(0 if layouts() else 1)
    fx = build_fixture()
    text = json.dumps(fx, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"
    if mode == "--write":
        os.makedirs(os.path.dirname(FIXTURE), exist_ok=True)
        with open(FIXTURE, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote", os.path.relpath(FIXTURE, ROOT), len(text), "bytes", summary(fx))
    elif mode == "--check":
        with open(FIXTURE, encoding="utf-8") as f:
            same = f.read() == text
        print("fixture", "일치" if same else "불일치", summary(fx))
        sys.exit(0 if same else 1)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
