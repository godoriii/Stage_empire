#!/usr/bin/env python3
"""glTF 린터 (SE-027). tools/assets/GLTF_SPEC.md §10 L1~L10 + 덧붙임 3건(A1~A3).

사용:
  python3 -I tools/assets/lint_gltf.py <asset.glb> <META.json> [--out <lint.json>] [--config <lint_config.json>]

종료 코드: 0 통과(경고 포함) / 1 거부 / 2 인자·파일 오류.
표준 라이브러리만 쓴다(Godot 불필요). 허용 오차·예산 등 수치는 전부 lint_config.json 에서 읽는다
(이 파일에는 수치 리터럴을 두지 않는다 — SE-027 AC2).
"""
import argparse
import hashlib
import json
import math
import re
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
DEFAULT_CONFIG = HERE / "lint_config.json"
REVIEW_QUEUE = Path("project") / "assets" / "review-queue"

EXIT_PASS, EXIT_REJECT, EXIT_ERROR = 0, 1, 2
REJECT, WARN = "reject", "warn"
GLB_VERSION = 2

# glTF 2.0 형식 상수(검사 기준 수치가 아니다)
COMPONENT = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
TYPE_WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}
NORMALIZED_MAX = {5121: 255.0, 5123: 65535.0}
TEXTURE_KEYS_PBR = ("baseColorTexture", "metallicRoughnessTexture")
TEXTURE_KEYS_TOP = ("normalTexture", "occlusionTexture", "emissiveTexture")
LIGHT_EXTENSION = "KHR_lights_punctual"
# lint.json 항목 순서: L1~L10(GLTF_SPEC §10), 덧붙임 A1(NORMAL)·A2(미사용 머티리얼)·A3(extensionsRequired)
ITEM_ORDER = ["L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "L10", "A1", "A2", "A3"]


class LintInputError(Exception):
    """인자·파일 오류(exit 2)."""


# ---------------------------------------------------------------- 입력

def load_config(path):
    try:
        raw = Path(path).read_bytes()
        cfg = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError) as e:
        raise LintInputError(f"설정 파일을 읽을 수 없음: {path} ({e})")
    return cfg, hashlib.sha256(raw).hexdigest()


def load_meta(path, cfg):
    mc = cfg["meta"]
    try:
        meta = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise LintInputError(f"META.json 을 읽을 수 없음: {path} ({e})")
    keys = ("asset_id", "category", "footprint", "height_m", "poly_budget", "ticket")
    if not isinstance(meta, dict):
        raise LintInputError("META.json 최상위가 객체가 아님")
    missing = [k for k in keys if k not in meta]
    extra = [k for k in meta if k not in keys]
    if missing:
        raise LintInputError(f"META.json 필수 키 없음: {', '.join(missing)}")
    if extra:
        raise LintInputError(f"META.json 알 수 없는 키: {', '.join(extra)}")
    if not (isinstance(meta["asset_id"], str) and re.match(mc["asset_id_pattern"], meta["asset_id"])):
        raise LintInputError(f"META.json asset_id 형식 오류: {meta['asset_id']!r}")
    if not (isinstance(meta["ticket"], str) and re.match(mc["ticket_pattern"], meta["ticket"])):
        raise LintInputError(f"META.json ticket 형식 오류: {meta['ticket']!r}")
    if meta["category"] not in mc["categories"]:
        raise LintInputError(f"META.json category 값 오류: {meta['category']!r} ({'|'.join(mc['categories'])})")
    if meta["poly_budget"] not in cfg["tri_budget"]:
        raise LintInputError(f"META.json poly_budget 값 오류: {meta['poly_budget']!r} ({'|'.join(cfg['tri_budget'])})")
    fp = meta["footprint"]
    fr = mc["footprint_tiles"]
    if not (isinstance(fp, list) and len(fp) == 2
            and all(isinstance(v, int) and not isinstance(v, bool) and fr["min"] <= v <= fr["max"] for v in fp)):
        raise LintInputError(f"META.json footprint 은 [w, d] 정수 {fr['min']}~{fr['max']}: {fp!r}")
    h = meta["height_m"]
    hr = mc["height_m"]
    if not (isinstance(h, (int, float)) and not isinstance(h, bool) and hr["min"] <= h <= hr["max"]):
        raise LintInputError(f"META.json height_m 범위 오류 ({hr['min']}~{hr['max']}): {h!r}")
    return meta


def read_glb(path):
    """(gltf json dict, BIN chunk bytes)."""
    try:
        data = Path(path).read_bytes()
    except OSError as e:
        raise LintInputError(f"glb 를 읽을 수 없음: {path} ({e})")
    head = struct.Struct("<4sII")
    chunk = struct.Struct("<I4s")
    if len(data) < head.size:
        raise LintInputError(f"{Path(path).name}: glb 헤더가 잘림")
    magic, version, length = head.unpack_from(data, 0)
    if magic != b"glTF" or version != GLB_VERSION:
        raise LintInputError(f"{Path(path).name}: glTF 2.0 바이너리(.glb)가 아님")
    if length > len(data):
        raise LintInputError(f"{Path(path).name}: glb 길이가 파일보다 큼")
    pos = head.size
    js = None
    blob = b""
    while pos + chunk.size <= length:
        clen, ctype = chunk.unpack_from(data, pos)
        pos += chunk.size
        body = data[pos:pos + clen]
        if len(body) != clen:
            raise LintInputError(f"{Path(path).name}: glb 청크가 잘림")
        pos += clen
        if ctype == b"JSON" and js is None:
            js = body
        elif ctype == b"BIN\0":
            blob = body
    if js is None:
        raise LintInputError(f"{Path(path).name}: JSON 청크 없음")
    try:
        gl = json.loads(js.decode("utf-8"))
    except ValueError as e:
        raise LintInputError(f"{Path(path).name}: JSON 청크 파싱 실패 ({e})")
    if not isinstance(gl, dict):
        raise LintInputError(f"{Path(path).name}: JSON 청크 최상위가 객체가 아님")
    for i, b in enumerate(gl.get("buffers", [])):
        if "uri" in b:
            raise LintInputError(f"{Path(path).name}: buffers[{i}] 외부 uri 참조 금지(GLTF_SPEC §1: 단일 .glb)")
    return gl, blob


def read_accessor(gl, blob, idx):
    """accessor 를 튜플 리스트로. 희소(sparse)·bufferView 없는 accessor 는 지원 안 함."""
    acc = gl["accessors"][idx]
    if "sparse" in acc or "bufferView" not in acc:
        raise LintInputError(f"accessor #{idx}: sparse·bufferView 없는 accessor 는 읽을 수 없음")
    view = gl["bufferViews"][acc["bufferView"]]
    fmt = COMPONENT[acc["componentType"]]
    width = TYPE_WIDTH[acc["type"]]
    st = struct.Struct("<" + fmt * width)
    stride = view.get("byteStride", st.size)
    base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    count = acc["count"]
    if count and base + (count - 1) * stride + st.size > len(blob):
        raise LintInputError(f"accessor #{idx}: BIN 청크 범위를 벗어남")
    return [st.unpack_from(blob, base + i * stride) for i in range(count)]


# ---------------------------------------------------------------- 검사

class Report:
    def __init__(self, glb_name):
        self.glb = glb_name
        self.items = []

    def add(self, item_id, level, msg):
        self.items.append({"id": item_id, "level": level, "message": f"{self.glb}: {msg}"})


def fmt(v):
    return format(v, ".4g")


def surfaces_of(gl):
    out = []
    for mi, mesh in enumerate(gl.get("meshes", [])):
        for pi, prim in enumerate(mesh.get("primitives", [])):
            out.append({"mesh": mi, "mesh_name": mesh.get("name", ""), "prim": pi, "p": prim,
                        "mat": prim.get("material")})
    return out


def where(s):
    return f"메시 '{s['mesh_name']}' primitive #{s['prim']}"


def mat_name(gl, s):
    """(이름 또는 None, 머티리얼 있는지)."""
    if s["mat"] is None:
        return None
    return gl["materials"][s["mat"]].get("name")


def check_materials(gl, cfg, rep, surfaces):
    """L1 L2 L3 L4."""
    slots = cfg["slots"]
    slot_text = "|".join(slots)
    by_slot = {}
    for s in surfaces:
        if s["mat"] is None:
            rep.add("L4", REJECT, f"{where(s)} 머티리얼 없음")
            continue
        name = mat_name(gl, s)
        if name is None:
            rep.add("L1", REJECT, f"머티리얼 #{s['mat']} 이름 없음 [{where(s)}]")
        elif name not in slots:
            rep.add("L1", REJECT, f"머티리얼 '{name}' 은 슬롯 이름이 아님 ({slot_text}) [{where(s)}]")
        else:
            by_slot.setdefault(name, []).append(s)
    for req in cfg["required_slots"]:
        if req not in by_slot:
            rep.add("L2", REJECT, f"{req} 슬롯 서피스 없음")
    for slot in slots:
        group = by_slot.get(slot, [])
        if len(group) > 1:
            if len({x["mesh"] for x in group}) == 1:
                where_text = "primitive " + ", ".join(f"#{x['prim']}" for x in group)
            else:
                where_text = ", ".join(where(x) for x in group)
            rep.add("L3", REJECT, f"슬롯 '{slot}' 서피스 {len(group)}개 ({where_text})")
    sc = cfg["surface_count"]
    if len(surfaces) > sc["max"]:
        rep.add("L3", REJECT, f"서피스 {len(surfaces)}개 (최대 {sc['max']})")
    if len(surfaces) < sc["min"]:
        rep.add("L3", REJECT, f"서피스 {len(surfaces)}개 (최소 {sc['min']})")
    return by_slot


def check_vertex_color(gl, blob, cfg, rep, surfaces):
    """L5."""
    tol = cfg["tolerance"]["vertex_alpha"]
    one = cfg["vertex_alpha_expected"]
    white = cfg["vertex_color_white"]
    for s in surfaces:
        idx = s["p"].get("attributes", {}).get("COLOR_0")
        if idx is None:
            continue
        acc = gl["accessors"][idx]
        scale = NORMALIZED_MAX.get(acc["componentType"], one)
        cols = [tuple(c / scale for c in row) for row in read_accessor(gl, blob, idx)]
        if any(not math.isfinite(c) for row in cols for c in row):
            rep.add("L5", REJECT, f"{where(s)} COLOR_0 에 NaN/Inf")
            continue
        alphas = [c[len(white)] for c in cols if len(c) > len(white)]
        if alphas and any(abs(a - one) > tol for a in alphas):
            bad = max(alphas, key=lambda a: abs(a - one))
            rep.add("L5", REJECT, f"{where(s)} COLOR_0 알파 {fmt(bad)} ≠ {fmt(one)} (정점 알파는 의미 채널이 아님, materials.md M1)")
        if any(abs(c[k] - white[k]) > tol for c in cols for k in range(len(white))):
            rep.add("L5", WARN, f"{where(s)} COLOR_0 RGB 가 흰색이 아님 (RGB 는 base 서피스에만 곱해짐, materials.md M2)")


def check_textures(gl, rep):
    """L6."""
    for key in ("images", "textures", "samplers"):
        n = len(gl.get(key, []))
        if n:
            rep.add("L6", REJECT, f"{key} {n}개 (텍스처 금지, GLTF_SPEC §5)")
    for i, m in enumerate(gl.get("materials", [])):
        pbr = m.get("pbrMetallicRoughness", {})
        refs = [k for k in TEXTURE_KEYS_PBR if k in pbr] + [k for k in TEXTURE_KEYS_TOP if k in m]
        for k in refs:
            rep.add("L6", REJECT, f"머티리얼 '{m.get('name', '#' + str(i))}' 텍스처 참조 {k}")


def reachable_nodes(gl):
    scenes = gl.get("scenes", [])
    if not scenes:
        return []
    seen, order = set(), []
    stack = list(reversed(scenes[gl.get("scene", 0)].get("nodes", [])))
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        order.append(n)
        stack.extend(reversed(gl["nodes"][n].get("children", [])))
    return order


def node_label(gl, idx):
    return gl["nodes"][idx].get("name", f"#{idx}")


def check_nodes(gl, cfg, rep):
    """L7. 메시 노드 인덱스 목록을 돌려준다(L9 용)."""
    order = reachable_nodes(gl)
    mesh_nodes = [n for n in order if "mesh" in gl["nodes"][n]]
    need = cfg["mesh_nodes_required"]
    if len(mesh_nodes) != need:
        rep.add("L7", REJECT, f"메시를 가진 노드 {len(mesh_nodes)}개 (정확히 {need}개)")
    need_meshes = cfg["meshes_required"]
    if len(gl.get("meshes", [])) != need_meshes:
        rep.add("L7", REJECT, f"meshes[] {len(gl.get('meshes', []))}개 (정확히 {need_meshes}개)")
    for n in order:
        node = gl["nodes"][n]
        label = node_label(gl, n)
        if node.get("children"):
            rep.add("L7", REJECT, f"노드 '{label}' 자식 노드 {len(node['children'])}개 (자식 노드 금지)")
        if "mesh" not in node:
            rep.add("L7", REJECT, f"노드 '{label}' 메시 없는 노드 (빈 부모 노드 금지)")
        if "camera" in node:
            rep.add("L7", REJECT, f"노드 '{label}' 카메라 노드 금지")
        if LIGHT_EXTENSION in node.get("extensions", {}):
            rep.add("L7", REJECT, f"노드 '{label}' 라이트 노드 금지")
        if "skin" in node:
            rep.add("L7", REJECT, f"노드 '{label}' skin 참조 금지")
    for key in ("skins", "animations"):
        if gl.get(key):
            rep.add("L7", REJECT, f"{key} {len(gl[key])}개 (v0 금지, GLTF_SPEC §6)")
    return mesh_nodes


def count_triangles(gl, blob, cfg, rep, surfaces):
    """L8."""
    total = 0
    for s in surfaces:
        p = s["p"]
        mode = p.get("mode", cfg["triangle_mode"])
        if mode != cfg["triangle_mode"]:
            rep.add("L8", REJECT, f"{where(s)} mode {mode} (삼각형만, mode {cfg['triangle_mode']})")
            continue
        if "indices" in p:
            n = gl["accessors"][p["indices"]]["count"]
        else:
            n = gl["accessors"][p["attributes"]["POSITION"]]["count"]
        if n % 3:
            rep.add("L8", REJECT, f"{where(s)} 인덱스 수 {n} 이 3의 배수가 아님")
        total += n // 3
    return total


def check_budget(total, meta, cfg, rep):
    budget = cfg["tri_budget"][meta["poly_budget"]]
    if total > budget:
        rep.add("L8", REJECT, f"삼각형 {total}개 > 예산 {budget} ({meta['poly_budget']})")


def node_identity_problems(node, cfg):
    tol = cfg["tolerance"]
    ident = cfg["identity_transform"]
    bad = []
    pairs = (("translation", tol["pivot_m"]), ("rotation", tol["identity"]),
             ("scale", tol["identity"]), ("matrix", tol["identity"]))
    for key, t in pairs:
        if key in node:
            val = node[key]
            ref = ident[key]
            if len(val) != len(ref) or any(not math.isfinite(a) or abs(a - b) > t for a, b in zip(val, ref)):
                bad.append(key)
    return bad


def check_pivot(gl, blob, meta, cfg, rep, surfaces, mesh_nodes):
    """L9."""
    tol = cfg["tolerance"]
    for n in mesh_nodes:
        bad = node_identity_problems(gl["nodes"][n], cfg)
        if bad:
            rep.add("L9", REJECT, f"노드 '{node_label(gl, n)}' 변환이 항등이 아님 ({', '.join(bad)}; 스케일 1.0·원점 기준)")
    lo = hi = None
    nonfinite = False
    for s in surfaces:
        idx = s["p"].get("attributes", {}).get("POSITION")
        if idx is None:
            rep.add("L9", REJECT, f"{where(s)} POSITION 없음")
            continue
        for v in read_accessor(gl, blob, idx):
            if not all(math.isfinite(c) for c in v):
                rep.add("L9", REJECT, f"{where(s)} POSITION 에 NaN/Inf")
                nonfinite = True
                break
            lo = list(v) if lo is None else [min(a, b) for a, b in zip(lo, v)]
            hi = list(v) if hi is None else [max(a, b) for a, b in zip(hi, v)]
    if nonfinite:
        return
    if lo is None:
        rep.add("L9", REJECT, "AABB 를 계산할 정점 없음")
        return
    ax = ("x", "y", "z")
    if abs(lo[1]) > tol["pivot_m"]:
        rep.add("L9", REJECT, f"피벗: AABB min.y={fmt(lo[1])} (바닥이 y=0 이어야 함, 허용 ±{fmt(tol['pivot_m'])} m)")
    for k in (0, 2):
        center = (lo[k] + hi[k]) / 2
        if abs(center) > tol["pivot_m"]:
            rep.add("L9", REJECT, f"피벗: AABB {ax[k]} 중심 {fmt(center)} (원점이어야 함, 허용 ±{fmt(tol['pivot_m'])} m)")
    for k, tiles in ((0, meta["footprint"][0]), (2, meta["footprint"][1])):
        size = hi[k] - lo[k]
        limit = tiles * cfg["tile_size_m"]
        if size > limit + tol["footprint_m"]:
            rep.add("L9", REJECT, f"AABB {ax[k]} 폭 {fmt(size)} m > META 풋프린트 {tiles} 타일 = {fmt(limit)} m")
    height = hi[1]
    want = meta["height_m"]
    if abs(height - want) > want * tol["height_ratio"]:
        rep.add("L9", REJECT, f"AABB 높이 {fmt(height)} m 가 META height_m {fmt(want)} m 의 ±{fmt(tol['height_ratio'] * 100)}% 밖")


def check_glass_character(meta, cfg, rep, by_slot):
    """L10."""
    ch = cfg["meta"]["character_value"]
    if ch not in (meta["category"], meta["poly_budget"]):
        return
    for s in by_slot.get("glass", []):
        rep.add("L10", REJECT, f"캐릭터 에셋에 glass 서피스 ({where(s)}) — 인스턴싱 투명 정렬 비용 (GLTF_SPEC §8)")


def check_extras(gl, rep, surfaces):
    """A1 NORMAL, A2 미사용 머티리얼, A3 extensionsRequired."""
    for s in surfaces:
        if "NORMAL" not in s["p"].get("attributes", {}):
            rep.add("A1", REJECT, f"{where(s)} NORMAL 없음 (외곽선 패스가 법선을 씀, GLTF_SPEC §1)")
    used = {s["mat"] for s in surfaces if s["mat"] is not None}
    for i, m in enumerate(gl.get("materials", [])):
        if i not in used:
            rep.add("A2", WARN, f"미사용 머티리얼 #{i} '{m.get('name', '')}' (어느 primitive 도 참조하지 않음)")
    req = gl.get("extensionsRequired", [])
    if req:
        rep.add("A3", REJECT, f"extensionsRequired 가 비어 있지 않음: {', '.join(map(str, req))} (확장 금지, GLTF_SPEC §1)")


def lint(glb_path, meta, cfg):
    """검사 항목 리스트(id·level·message)를 돌려준다."""
    gl, blob = read_glb(glb_path)
    rep = Report(Path(glb_path).name)
    try:
        surfaces = surfaces_of(gl)
        by_slot = check_materials(gl, cfg, rep, surfaces)
        check_vertex_color(gl, blob, cfg, rep, surfaces)
        check_textures(gl, rep)
        mesh_nodes = check_nodes(gl, cfg, rep)
        total = count_triangles(gl, blob, cfg, rep, surfaces)
        check_budget(total, meta, cfg, rep)
        check_pivot(gl, blob, meta, cfg, rep, surfaces, mesh_nodes)
        check_glass_character(meta, cfg, rep, by_slot)
        check_extras(gl, rep, surfaces)
    except (KeyError, IndexError, TypeError, ValueError, struct.error) as e:
        raise LintInputError(f"{Path(glb_path).name}: glTF 구조 오류 ({type(e).__name__}: {e})")
    rep.items.sort(key=lambda it: ITEM_ORDER.index(it["id"]))
    return rep.items


def default_out_path(asset_id):
    return REPO_ROOT / REVIEW_QUEUE / asset_id / "lint.json"


def build_result(glb_path, meta_path, meta, items, cfg_sha):
    verdict = "reject" if any(it["level"] == REJECT for it in items) else "pass"
    return {"asset_id": meta["asset_id"], "glb": Path(glb_path).name, "meta": Path(meta_path).name,
            "verdict": verdict, "items": items, "config_sha256": cfg_sha}


def main(argv=None):
    ap = argparse.ArgumentParser(description="glTF 린터 (GLTF_SPEC §10). 종료 코드 0 통과 / 1 거부 / 2 인자·파일 오류")
    ap.add_argument("glb")
    ap.add_argument("meta")
    ap.add_argument("--out", help="lint.json 경로 (기본: project/assets/review-queue/<asset_id>/lint.json)")
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    args = ap.parse_args(argv)
    try:
        cfg, cfg_sha = load_config(args.config)
        meta = load_meta(args.meta, cfg)
        items = lint(args.glb, meta, cfg)
        result = build_result(args.glb, args.meta, meta, items, cfg_sha)
        out = Path(args.out) if args.out else default_out_path(meta["asset_id"])
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (LintInputError, OSError, KeyError) as e:
        print(f"lint_gltf: 오류: {e}", file=sys.stderr)
        return EXIT_ERROR
    for it in items:
        print(f"[{it['level']}] {it['id']} {it['message']}")
    print(f"{result['glb']}: {result['verdict']} -> {out}")
    return EXIT_REJECT if result["verdict"] == "reject" else EXIT_PASS


if __name__ == "__main__":
    sys.exit(main())
