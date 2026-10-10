#!/usr/bin/env python3
"""테스트용 가구 5종 .glb 결정적 생성기 (SE-041 1차, 사람 결정 2026-10-10).

*** 테스트용 — 교체 예정. *** AI 3D 생성·Blender 를 쓰지 않고 박스·원기둥·경사면을 코드로 조립한다.
실제 에셋이 나오면 같은 id 의 `.glb` 만 바꾸면 된다(규약은 실제 에셋과 같다: 서피스 = 슬롯, 피벗 = 바닥 중심,
풋프린트·높이는 furniture.json 값, 삼각형 예산, META.json 6키). 표준 라이브러리만 쓴다. 같은 명령이면 같은 바이트.

사용:
    python3 -I tools/assets/make_test_furniture.py --out project/assets/review-queue            # <out>/<id>/<id>.glb + META.json
    python3 -I tools/assets/make_test_furniture.py --out project/assets/review-queue --lint     # + lint.json (lint_gltf.py 결과)
    ... --preview  # + preview.png (선택)

규약 메모
- 축: +Y 업, -Z 전방(GLTF_SPEC §1). 풋프린트 [w, d] = x 방향 w, z 방향 d. 원점 = 바닥 중심.
- 모든 정점은 가구 풋프린트 안이고, AABB 가 풋프린트 전체를 정확히 채워 중심이 원점이다(린터 L9).
- 서피스 = 슬롯(base/accent/emissive/glass 순, 쓰는 것만). 정점 색·텍스처 없음. 노드 1개, 항등 변환.
- 노멀: 박스·캡은 면 법선(플랫), 원기둥 옆면은 반경 방향(스무스). 외곽선 패스용 NORMAL 은 전 정점에 있다.
"""
import argparse
import json
import math
import struct
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "q5_probe"))
import make_probe_glb as probe  # noqa: E402  (write_glb 와 m() 재사용)

TICKET = "SE-041"
SLOT_ORDER = ["base", "accent", "emissive", "glass"]

# 이 파일의 .glb 머티리얼 baseColorFactor 는 5종 공통 자리표시 색이다(런타임 색은 슬롯 파라미터에서 온다 - GLTF_SPEC §2).
# R-B 전에는 자리표시 색이 화면에 그대로 보인다(슬롯 파라미터를 적용하는 렌더 쪽이 아직 없다).
# 형태·바이트 불변을 위해 SE-041 1차 값을 그대로 둔다. 미리보기 PNG 색은 이 표가 아니라 furniture.json 행의
# `slots` 색(preview_colors)을 쓴다. glTF 안에서 슬롯 이름만 의미가 있고 색은 의미가 없다.
# 그래서 R-B 전에는 자리표시 색이 화면에 그대로 보인다 — 이 색으로 룩을 판단하지 말 것.
GLB_PLACEHOLDER = {
    "base": (0.23, 0.20, 0.25, 1.0),
    "accent": (0.78, 0.26, 0.23, 1.0),
    "emissive": (1.0, 0.82, 0.48, 1.0),
    "glass": (0.66, 0.85, 0.92, 0.4),
}
FURNITURE_JSON = HERE.parent.parent / "project" / "data" / "furniture" / "furniture.json"


class SlotKeyMismatch(ValueError):
    """furniture.json 행 slots 키 집합 ≠ 생성기 서피스(슬롯) 집합."""


def preview_colors(fid, furniture_json=None):
    """furniture.json 행 `fid` 의 slots('#RRGGBB') → {슬롯: (r, g, b, a) 0..1}. glass 만 알파 0.4(미리보기 반투명 표시용)."""
    rows = {r["id"]: r for r in json.loads(Path(furniture_json or FURNITURE_JSON).read_text(encoding="utf-8"))["rows"]}
    if fid not in rows:
        raise SlotKeyMismatch(f"furniture.json 에 행이 없음: {fid}")
    want, have = set(FURNITURE[fid][5]), set(rows[fid]["slots"])
    if want != have:
        raise SlotKeyMismatch(f"slots 키 ≠ 서피스: {fid} — 서피스 {sorted(want)}, slots 키 {sorted(have)}"
                              f" (없는 키 {sorted(want - have)}, 남는 키 {sorted(have - want)})")
    out = {}
    for slot, hexv in rows[fid]["slots"].items():
        out[slot] = tuple(int(hexv[i:i + 2], 16) / 255 for i in (1, 3, 5)) + (0.4 if slot == "glass" else 1.0,)
    return out


# ---------------------------------------------------------------- 벡터 보조

def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _unit(v):
    n = math.sqrt(_dot(v, v))
    return (v[0] / n, v[1] / n, v[2] / n)


# ---------------------------------------------------------------- 메시 조립

class Mesh:
    """슬롯별 (정점, 노멀, 인덱스) 목록. 면마다 정점을 따로 둔다(플랫 노멀). 와인딩은 바깥에서 봤을 때 반시계."""

    def __init__(self):
        self.surf = {}

    def _s(self, slot):
        return self.surf.setdefault(slot, {"pos": [], "nrm": [], "idx": []})

    def poly(self, slot, pts, outward):
        """볼록 다각형 1면(부채꼴 삼각분할, 플랫 노멀). outward 와 법선이 반대면 순서를 뒤집는다."""
        n = _cross(_sub(pts[1], pts[0]), _sub(pts[2], pts[0]))
        if _dot(n, outward) < 0:
            pts = list(reversed(pts))
        nrm = _unit(_cross(_sub(pts[1], pts[0]), _sub(pts[2], pts[0])))
        s = self._s(slot)
        base = len(s["pos"])
        for p in pts:
            s["pos"].append(p)
            s["nrm"].append(nrm)
        for i in range(1, len(pts) - 1):
            s["idx"].extend([base, base + i, base + i + 1])

    def smooth_quad(self, slot, p, nr, outward):
        """정점별 노멀을 주는 사각형 1면(원기둥 옆면)."""
        n = _cross(_sub(p[1], p[0]), _sub(p[2], p[0]))
        order = [0, 1, 2, 3] if _dot(n, outward) >= 0 else [3, 2, 1, 0]
        s = self._s(slot)
        base = len(s["pos"])
        for i in order:
            s["pos"].append(p[i])
            s["nrm"].append(nr[i])
        s["idx"].extend([base, base + 1, base + 2, base, base + 2, base + 3])

    # -- 프리미티브

    def box(self, slot, x0, x1, y0, y1, z0, z1, bottom=False):
        """축 정렬 박스. 바닥면은 기본 생략(바닥에 닿는 면은 보이지 않는다)."""
        c = lambda x, y, z: (float(x), float(y), float(z))  # noqa: E731
        self.poly(slot, [c(x1, y0, z0), c(x1, y1, z0), c(x1, y1, z1), c(x1, y0, z1)], (1, 0, 0))
        self.poly(slot, [c(x0, y0, z0), c(x0, y1, z0), c(x0, y1, z1), c(x0, y0, z1)], (-1, 0, 0))
        self.poly(slot, [c(x0, y1, z0), c(x1, y1, z0), c(x1, y1, z1), c(x0, y1, z1)], (0, 1, 0))
        self.poly(slot, [c(x0, y0, z1), c(x1, y0, z1), c(x1, y1, z1), c(x0, y1, z1)], (0, 0, 1))
        self.poly(slot, [c(x0, y0, z0), c(x1, y0, z0), c(x1, y1, z0), c(x0, y1, z0)], (0, 0, -1))
        if bottom:
            self.poly(slot, [c(x0, y0, z0), c(x1, y0, z0), c(x1, y0, z1), c(x0, y0, z1)], (0, -1, 0))

    def ramp_x(self, slot, xlow, xhigh, y_top, z0, z1):
        """경사면: x=xhigh 에서 높이 y_top, x=xlow 에서 높이 0 으로 내려가는 쐐기(바닥면 생략)."""
        c = lambda x, y, z: (float(x), float(y), float(z))  # noqa: E731
        sgn = 1.0 if xlow > xhigh else -1.0  # 낮은 쪽이 +x 이면 법선이 +x 쪽으로 기움
        slope_n = (sgn * y_top, abs(xhigh - xlow), 0.0)
        self.poly(slot, [c(xhigh, y_top, z0), c(xhigh, y_top, z1), c(xlow, 0, z1), c(xlow, 0, z0)], slope_n)
        self.poly(slot, [c(xhigh, 0, z0), c(xhigh, y_top, z0), c(xhigh, y_top, z1), c(xhigh, 0, z1)],
                  (-sgn, 0, 0))
        self.poly(slot, [c(xhigh, 0, z0), c(xhigh, y_top, z0), c(xlow, 0, z0)], (0, 0, -1))
        self.poly(slot, [c(xhigh, 0, z1), c(xhigh, y_top, z1), c(xlow, 0, z1)], (0, 0, 1))

    def cyl(self, slot, a, b, r, lo, hi, axis="y", n=12, cap_lo=True, cap_hi=True):
        """원기둥. axis 'y': 링은 (x=a, z=b) 중심, 높이 lo..hi. axis 'z': 링은 (x=a, y=b) 중심, z 범위 lo..hi.
        옆면은 스무스 노멀, 캡은 플랫."""
        def at(t, w):
            u, v = a + r * math.cos(t), b + r * math.sin(t)
            return (u, w, v) if axis == "y" else (u, v, w)

        def radial(t):
            return (math.cos(t), 0.0, math.sin(t)) if axis == "y" else (math.cos(t), math.sin(t), 0.0)

        ts = [2 * math.pi * i / n for i in range(n)]
        for i in range(n):
            t0 = ts[i]
            t1 = ts[i + 1] if i + 1 < n else 2 * math.pi
            quad = [at(t0, lo), at(t1, lo), at(t1, hi), at(t0, hi)]
            nr = [radial(t0), radial(t1), radial(t1), radial(t0)]
            tm = (t0 + t1) / 2
            self.smooth_quad(slot, quad, nr, radial(tm))
        up = (0.0, 1.0, 0.0) if axis == "y" else (0.0, 0.0, 1.0)
        down = (0.0, -1.0, 0.0) if axis == "y" else (0.0, 0.0, -1.0)
        if cap_hi:
            self.poly(slot, [at(t, hi) for t in ts], up)
        if cap_lo:
            self.poly(slot, [at(t, lo) for t in ts], down)

    # -- 출력

    def tri_count(self):
        return sum(len(s["idx"]) // 3 for s in self.surf.values())

    def slots(self):
        return [k for k in SLOT_ORDER if k in self.surf]


def write_mesh_glb(path, mesh):
    """Mesh → .glb. primitive = 서피스 = 슬롯(SLOT_ORDER 순). 노드 1개, 항등 변환, 텍스처·정점 색 없음."""
    bin_ = bytearray()
    views, accs, prims, mats = [], [], [], []

    def add(data, target, comp, typ, count, extra=None):
        while len(bin_) % 4:
            bin_.append(0)
        views.append({"buffer": 0, "byteOffset": len(bin_), "byteLength": len(data), "target": target})
        bin_.extend(data)
        a = {"bufferView": len(views) - 1, "componentType": comp, "count": count, "type": typ}
        if extra:
            a.update(extra)
        accs.append(a)
        return len(accs) - 1

    for slot in mesh.slots():
        s = mesh.surf[slot]
        pos = [tuple(struct.unpack("<3f", struct.pack("<3f", *p))) for p in s["pos"]]  # float32 으로 반올림한 값 기준 min/max
        pa = add(b"".join(struct.pack("<3f", *p) for p in pos), 34962, 5126, "VEC3", len(pos),
                 {"min": [min(p[k] for p in pos) for k in range(3)], "max": [max(p[k] for p in pos) for k in range(3)]})
        na = add(b"".join(struct.pack("<3f", *v) for v in s["nrm"]), 34962, 5126, "VEC3", len(pos))
        ia = add(struct.pack(f"<{len(s['idx'])}H", *s["idx"]), 34963, 5123, "SCALAR", len(s["idx"]))
        mat = probe.m(slot, GLB_PLACEHOLDER[slot], "BLEND" if slot == "glass" else None)
        if slot == "emissive":
            mat["emissiveFactor"] = list(GLB_PLACEHOLDER["emissive"][:3])
        mats.append(mat)
        prims.append({"attributes": {"POSITION": pa, "NORMAL": na}, "indices": ia, "material": len(mats) - 1})

    gl = {"asset": {"version": "2.0", "generator": "tools/assets/make_test_furniture.py (SE-041, 테스트용)"},
          "scene": 0, "scenes": [{"nodes": [0]}],
          "nodes": [{"name": "Mesh", "mesh": 0}],
          "meshes": [{"name": "MeshData", "primitives": prims}],
          "materials": mats, "accessors": accs, "bufferViews": views, "buffers": [{"byteLength": 0}]}
    probe.write_glb(path, gl, bin_)


# ---------------------------------------------------------------- 미리보기 PNG (선택, 순수 파이썬 소프트웨어 래스터)

def render_png(path, mesh, colors, size=384, ssaa=2):
    """아이소메트릭(요 45°, 피치 30°, 앞면 -Z·오른쪽 +X 쪽에서 본 직교) 플랫 셰이딩 미리보기. 검수용 대략 확인이지
    게임 룩(툰 셰이더)이 아니다. colors = preview_colors() (furniture.json slots 색). emissive 는 무음영 원색,
    그 밖은 면 밝기(0.45..1.0)를 곱한다. glass 는 불투명 면을 그린 뒤 50% 로 덮는다."""
    yaw, pitch = math.radians(45), math.radians(30)
    cam = (math.cos(pitch) * math.sin(yaw), math.sin(pitch), -math.cos(pitch) * math.cos(yaw))
    fwd = (-cam[0], -cam[1], -cam[2])
    right = _unit(_cross(fwd, (0.0, 1.0, 0.0)))
    up = _cross(right, fwd)
    light = _unit((0.4, 0.9, -0.5))
    tris = []  # (슬롯, [(sx, sy, depth)*3], 밝기)
    for slot in mesh.slots():
        s = mesh.surf[slot]
        for i in range(0, len(s["idx"]), 3):
            ids = s["idx"][i:i + 3]
            pts = [s["pos"][k] for k in ids]
            n = _unit(_cross(_sub(pts[1], pts[0]), _sub(pts[2], pts[0])))
            shade = 0.45 + 0.55 * max(0.0, _dot(n, light))
            tris.append((slot, [(_dot(p, right), _dot(p, up), _dot(p, fwd)) for p in pts], shade))
    xs = [v[0] for t in tris for v in t[1]]
    ys = [v[1] for t in tris for v in t[1]]
    w = size * ssaa
    scale = 0.86 * w / max(max(xs) - min(xs), max(ys) - min(ys))
    ox = w / 2 - scale * (max(xs) + min(xs)) / 2
    oy = w / 2 + scale * (max(ys) + min(ys)) / 2
    bg = (236, 236, 240)
    img = [[bg] * w for _ in range(w)]
    zb = [[1e9] * w for _ in range(w)]
    ordered = [t for t in tris if t[0] != "glass"] + [t for t in tris if t[0] == "glass"]
    for slot, v, shade in ordered:
        base = [int(round(c * 255)) for c in colors[slot][:3]]
        col = tuple(base) if slot == "emissive" else tuple(min(255, int(c * shade)) for c in base)
        sp = [(ox + scale * a, oy - scale * b, d) for a, b, d in v]
        x0, x1 = max(0, int(min(q[0] for q in sp))), min(w - 1, int(max(q[0] for q in sp)) + 1)
        y0, y1 = max(0, int(min(q[1] for q in sp))), min(w - 1, int(max(q[1] for q in sp)) + 1)
        (ax, ay, ad), (bx, by, bd), (cx, cy, cd) = sp
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-12:
            continue
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                px, py = x + 0.5, y + 0.5
                l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den
                l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den
                l3 = 1 - l1 - l2
                if l1 < 0 or l2 < 0 or l3 < 0:
                    continue
                d = l1 * ad + l2 * bd + l3 * cd
                if d >= zb[y][x]:
                    continue
                if slot == "glass":
                    o = img[y][x]
                    img[y][x] = tuple((a + b) // 2 for a, b in zip(o, col))
                else:
                    zb[y][x] = d
                    img[y][x] = col
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            px = [img[y * ssaa + j][x * ssaa + i] for j in range(ssaa) for i in range(ssaa)]
            rows.extend(sum(c[k] for c in px) // len(px) for k in range(3))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    Path(path).write_bytes(png)


# ---------------------------------------------------------------- 가구 5종
# 각 함수는 Mesh 를 돌려준다. 좌표는 미터, 원점 = 바닥 중심, 전방 = -Z.

def stage_medium():
    """중형 무대 6x4, 높이 0.8. base 단상 + 오른쪽(+x) 경사 램프, accent 상판, emissive 앞면 띠와 양 끝 라이트."""
    me = Mesh()
    me.box("base", -3.0, 2.4, 0.0, 0.7, -1.95, 2.0)             # 단상(앞면 z=-1.95 는 emissive 띠 두께만큼 물러남)
    me.ramp_x("base", 3.0, 2.4, 0.7, -0.8, 0.8)                 # 램프(x=2.4 에서 0.7, x=3.0 에서 0)
    me.box("accent", -2.8, 2.2, 0.7, 0.8, -1.7, 1.8)            # 상판
    me.box("emissive", -2.7, 2.7, 0.25, 0.35, -2.0, -1.95)      # 앞면 띠(z=-2.0 까지 풋프린트를 채운다)
    me.box("emissive", -2.9, -2.8, 0.7, 0.75, -1.9, -1.8)       # 앞 모서리 마커 라이트
    return me


def bar_counter():
    """바 카운터 3x1, 높이 1.1. base 몸체, accent 상판(앞으로 튀어나옴)과 발판 레일."""
    me = Mesh()
    me.box("base", -1.45, 1.45, 0.0, 1.0, -0.4, 0.5)            # 몸체(뒤쪽 z=0.5 까지)
    me.box("accent", -1.5, 1.5, 1.0, 1.1, -0.5, 0.5)            # 상판
    me.box("accent", -1.4, 1.4, 0.15, 0.2, -0.46, -0.4)         # 발판 레일
    return me


def speaker_floor():
    """바닥 스피커 1x1, 높이 1.2. base 받침+캐비닛, emissive 앞면(-Z) 우퍼·트위터 링."""
    me = Mesh()
    me.box("base", -0.5, 0.5, 0.0, 0.1, -0.5, 0.5)              # 받침(풋프린트 전체)
    me.box("base", -0.4, 0.4, 0.1, 1.2, -0.4, 0.4)              # 캐비닛
    me.cyl("emissive", 0.0, 0.5, 0.28, -0.46, -0.4, axis="z", n=12, cap_lo=True, cap_hi=False)   # 우퍼
    me.cyl("emissive", 0.0, 0.95, 0.11, -0.46, -0.4, axis="z", n=10, cap_lo=True, cap_hi=False)  # 트위터
    return me


def bar_fridge():
    """음료 냉장고 1x1, 높이 1.9, 벽 부착형(뒤쪽 +Z 이 벽). base 몸체+받침, glass 앞문, emissive 상단 간판 띠."""
    me = Mesh()
    me.box("base", -0.5, 0.5, 0.0, 1.9, -0.4, 0.5)              # 몸체
    me.box("glass", -0.42, 0.42, 0.15, 1.6, -0.5, -0.4)         # 유리문(몸체 앞면 밖으로 0.1)
    me.box("emissive", -0.42, 0.42, 1.65, 1.85, -0.5, -0.4)     # 상단 간판 띠
    return me


def light_spot():
    """스포트 조명 1x1, 높이 2.4. base 원형 발+기둥+요크+헤드 캔, emissive 렌즈(-Z)."""
    me = Mesh()
    me.cyl("base", 0.0, 0.0, 0.5, 0.0, 0.05, axis="y", n=12, cap_lo=False)       # 발(풋프린트 내접 원)
    me.cyl("base", 0.0, 0.0, 0.04, 0.05, 2.0, axis="y", n=8, cap_lo=False, cap_hi=False)  # 기둥
    me.box("base", -0.26, 0.26, 1.98, 2.02, -0.06, 0.06)        # 요크 가로대
    me.cyl("base", 0.0, 2.2, 0.2, -0.2, 0.2, axis="z", n=12)    # 헤드 캔(최상단 y=2.4)
    me.cyl("emissive", 0.0, 2.2, 0.16, -0.23, -0.2, axis="z", n=12, cap_lo=True, cap_hi=False)  # 렌즈
    return me


# id → (생성 함수, 카테고리, 풋프린트 [w,d], height_m, poly_budget, 기대 슬롯)
# 값은 project/data/furniture/furniture.json 과 같다(린터는 테이블을 읽지 않는다. 카테고리·풋프린트·높이·예산은
# test_make_test_furniture.py 가, 서피스 집합 == slots 키 집합도 같은 테스트가 대조한다).
FURNITURE = {
    "stage_medium": (stage_medium, "stage", [6, 4], 0.8, "equipment_large", ["base", "accent", "emissive"]),
    "bar_counter": (bar_counter, "bar", [3, 1], 1.1, "equipment_large", ["base", "accent"]),
    "speaker_floor": (speaker_floor, "sound", [1, 1], 1.2, "furniture_small", ["base", "emissive"]),
    "bar_fridge": (bar_fridge, "bar", [1, 1], 1.9, "furniture_small", ["base", "emissive", "glass"]),
    "light_spot": (light_spot, "light", [1, 1], 2.4, "furniture_small", ["base", "emissive"]),
}


def meta_for(fid):
    _, category, footprint, height_m, budget, _ = FURNITURE[fid]
    return {"asset_id": fid, "ticket": TICKET, "category": category, "footprint": footprint,
            "height_m": height_m, "poly_budget": budget}


def generate(out, lint=False, preview=False, furniture_json=None):
    """<out>/<id>/<id>.glb + META.json (+ lint.json). 돌려주는 값: {id: 린터 exit code}(lint=True 일 때)."""
    out = Path(out)
    codes = {}
    for fid, (fn, *_rest) in FURNITURE.items():
        d = out / fid
        d.mkdir(parents=True, exist_ok=True)
        glb, meta = d / f"{fid}.glb", d / "META.json"
        mesh = fn()
        write_mesh_glb(glb, mesh)
        if preview:
            render_png(d / "preview.png", mesh, preview_colors(fid, furniture_json))
        meta.write_text(json.dumps(meta_for(fid), indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
        if lint:
            r = subprocess.run([sys.executable, "-I", str(HERE / "lint_gltf.py"), str(glb), str(meta),
                                "--out", str(d / "lint.json")], capture_output=True, text=True)
            codes[fid] = r.returncode
            if r.returncode:
                sys.stderr.write(r.stdout + r.stderr)
    return codes


def main():
    ap = argparse.ArgumentParser(description="테스트용 가구 5종 .glb + META.json (+ lint.json) 결정적 생성")
    ap.add_argument("--out", required=True, help="출력 루트(검수 큐면 project/assets/review-queue)")
    ap.add_argument("--preview", action="store_true", help="<id>/preview.png 도 쓴다(furniture.json slots 색, 순수 파이썬 래스터, 느림)")
    ap.add_argument("--lint", action="store_true", help="lint_gltf.py 를 돌려 <id>/lint.json 도 쓴다")
    args = ap.parse_args()
    try:
        codes = generate(args.out, args.lint, args.preview)
    except SlotKeyMismatch as e:
        sys.stderr.write(f"오류: {e}\n")
        sys.exit(1)
    for fid, (fn, *_rest) in FURNITURE.items():
        print(f"{fid}: {fn().tri_count()} tri, 슬롯 {','.join(fn().slots())}" + (f", lint exit {codes[fid]}" if args.lint else ""))
    sys.exit(1 if any(codes.values()) else 0)


if __name__ == "__main__":
    main()
