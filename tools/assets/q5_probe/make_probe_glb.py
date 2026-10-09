#!/usr/bin/env python3
"""최소 .glb 생성기(표준 라이브러리만 사용, 결정적).

SE-019 Q5 확인용으로 시작했고, SE-027 에서 린터 픽스처 생성기로 확장했다.
사용: python3 -I tools/assets/q5_probe/make_probe_glb.py --out tools/assets/fixtures/
(위치 인자로 출력 디렉터리를 줘도 된다 — GLTF_SPEC §9 재현 절차). 같은 입력이면 바이트가 같다.

출력(디렉터리마다): <이름>.glb 와 <이름>.META.json 한 쌍씩. META.json 형식은 GLTF_SPEC "META.json" 절.
게임 에셋이 아니다. 각 파일은 10 KB 미만(쿼드 몇 개).

기본 지오메트리: primitive i 는 폭 width(x), 높이 height(y) 쿼드이고 z 로 depth_step 씩 벌려 놓는다.
primitive 가 n 개이면 z 중심이 0 이라 기본값(width=height=1)에서 AABB 는 풋프린트 1x1, 높이 1,
피벗 = 바닥 중심이다. 삼각형 수를 늘릴 때는 같은 쿼드의 인덱스를 되풀이한다(린터는 인덱스 수만 센다).
"""
import argparse
import base64
import json
import struct
from pathlib import Path

# 1x1 PNG (텍스처 포함 픽스처용, 내용은 린터가 읽지 않는다)
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


def build(path, mats, prim_mats, colors=None, width=1.0, height=1.0, depth_step=0.25,
          offset=(0.0, 0.0, 0.0), tris=2, normals=True, modes=None, tweak=None, bad_position=None):
    """bad_position: 첫 primitive 첫 정점 x 를 이 값(nan·inf)으로 바꾼다(린터 NaN 가드 테스트용).
    tweak(gl, add) 로 glTF JSON 을 직접 고칠 수 있다(add(data, target, comp, typ, count) → accessor)."""
    n = len(prim_mats)
    bin_ = bytearray()
    views, accs, prims = [], [], []

    def add(data, target, comp, typ, count, extra=None):
        while len(bin_) % 4:
            bin_.append(0)
        off = len(bin_)
        bin_.extend(data)
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target is not None:
            v["target"] = target
        views.append(v)
        if comp is None:
            return len(views) - 1
        a = {"bufferView": len(views) - 1, "componentType": comp, "count": count, "type": typ}
        if extra:
            a.update(extra)
        accs.append(a)
        return len(accs) - 1

    for i in range(n):
        z = (i - (n - 1) / 2) * depth_step + offset[2]
        x0 = -width / 2 + offset[0]
        y0 = offset[1]
        p = [(x0 if (i or bad_position is None) else bad_position, y0, z), (x0 + width, y0, z), (x0 + width, y0 + height, z), (x0, y0 + height, z)]
        pa = add(b"".join(struct.pack("<3f", *v) for v in p), 34962, 5126, "VEC3", 4,
                 {"min": [min(v[k] for v in p) for k in range(3)],
                  "max": [max(v[k] for v in p) for k in range(3)]})
        attrs = {"POSITION": pa}
        if normals:
            attrs["NORMAL"] = add(b"".join(struct.pack("<3f", 0, 0, 1) for _ in range(4)), 34962, 5126, "VEC3", 4)
        if colors is not None:
            attrs["COLOR_0"] = add(b"".join(struct.pack("<4f", *colors) for _ in range(4)),
                                   34962, 5126, "VEC4", 4)
        idx = [0, 1, 2, 0, 2, 3] + [0, 1, 2] * (tris - 2)
        ia = add(struct.pack(f"<{len(idx)}H", *idx), 34963, 5123, "SCALAR", len(idx))
        pr = {"attributes": attrs, "indices": ia}
        if prim_mats[i] is not None:
            pr["material"] = prim_mats[i]
        if modes and modes[i] is not None:
            pr["mode"] = modes[i]
        prims.append(pr)

    gl = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
          "nodes": [{"name": "Mesh", "mesh": 0}],
          "meshes": [{"name": "MeshData", "primitives": prims}],
          "materials": mats, "accessors": accs, "bufferViews": views,
          "buffers": [{"byteLength": 0}]}
    if tweak:
        tweak(gl, add)
    gl["buffers"][0]["byteLength"] = len(bin_)
    js = json.dumps(gl).encode()
    js += b" " * (-len(js) % 4)
    b = bytes(bin_) + b"\0" * (-len(bin_) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(js) + 8 + len(b)))
        f.write(struct.pack("<I4s", len(js), b"JSON") + js)
        f.write(struct.pack("<I4s", len(b), b"BIN\0") + b)


def m(name, rgba=(0.5, 0.5, 0.5, 1.0), mode=None):
    d = {"pbrMetallicRoughness": {"baseColorFactor": list(rgba)}}
    if name is not None:
        d["name"] = name
    if mode:
        d["alphaMode"] = mode
    return d


# ---- tweak 함수들 (픽스처마다 glTF 구조를 비튼다)

def tw_texture(gl, add):
    view = add(PNG_1X1, None, None, None, 0)
    gl["images"] = [{"bufferView": view, "mimeType": "image/png"}]
    gl["samplers"] = [{}]
    gl["textures"] = [{"source": 0, "sampler": 0}]
    gl["materials"][0]["pbrMetallicRoughness"]["baseColorTexture"] = {"index": 0}


def tw_two_mesh_nodes(gl, add):
    gl["nodes"].append({"name": "MeshCopy", "mesh": 0})
    gl["scenes"][0]["nodes"] = [0, 1]


def tw_child_node(gl, add):
    gl["nodes"] = [{"name": "Root", "children": [1]}, {"name": "Mesh", "mesh": 0}]


def tw_animation(gl, add):
    gl["animations"] = [{"name": "Idle", "channels": [], "samplers": []}]


def tw_node(**props):
    """메시 노드(0번)에 translation·rotation·scale·matrix 등을 직접 쓴다."""
    def tweak(gl, add):
        gl["nodes"][0].update(props)
    return tweak


def tw_node_scaled(gl, add):
    gl["nodes"][0]["scale"] = [2.0, 2.0, 2.0]


def tw_required_ext(gl, add):
    gl["extensionsUsed"] = ["KHR_materials_unlit"]
    gl["extensionsRequired"] = ["KHR_materials_unlit"]


def slot_mats():
    return [m("base"), m("accent", (1, 0, 0, 1)), m("emissive", (1, 1, 0, 1)),
            m("glass", (0.5, 0.7, 1.0, 0.4), "BLEND")]


# (이름, build 인자, META 덮어쓰기). 기본 META: 풋프린트 1x1, 높이 1.0, 소형 가구.
FIXTURES = [
    # 통과
    ("slots4", dict(mats=slot_mats(), prim_mats=[0, 1, 2, 3]), {}),
    # L1·L2·L4: DCC 접미, 대소문자 변형, 이름 없는 머티리얼, 재질 이름, 머티리얼 없는 primitive
    ("bad_names", dict(mats=[m("base.001"), m("Accent"), m(None), m("metal")], prim_mats=[0, 1, 2, 3, None]), {}),
    # L2: base 없음
    ("no_base", dict(mats=[m("accent")], prim_mats=[0]), {}),
    # L3: 같은 이름 머티리얼 2개를 서피스 2개에 / 머티리얼 1개를 primitive 2개가 공유 / 서피스 5개
    ("dup_two_materials", dict(mats=[m("base"), m("base")], prim_mats=[0, 1]), {}),
    ("dup_shared_material", dict(mats=[m("base")], prim_mats=[0, 0]), {}),
    ("five_surfaces", dict(mats=slot_mats(), prim_mats=[0, 1, 2, 3, 0]), {}),
    # L5: 정점 알파 0.5(거부) / RGB 가 흰색이 아님(경고)
    ("vertex_alpha", dict(mats=[m("base")], prim_mats=[0], colors=(1, 1, 1, 0.5)), {}),
    ("vertex_color_rgb", dict(mats=[m("base")], prim_mats=[0], colors=(0.8, 0.2, 0.2, 1.0)), {}),
    # L6: 텍스처
    ("with_texture", dict(mats=[m("base")], prim_mats=[0], tweak=tw_texture), {}),
    # L7: 메시 노드 2개 / 자식 노드(빈 부모) / 애니메이션
    ("two_nodes", dict(mats=[m("base")], prim_mats=[0], tweak=tw_two_mesh_nodes), {}),
    ("child_node", dict(mats=[m("base")], prim_mats=[0], tweak=tw_child_node), {}),
    ("with_animation", dict(mats=[m("base")], prim_mats=[0], tweak=tw_animation), {}),
    # L8: 삼각형 301개(소형 예산 초과) / TRIANGLES 가 아닌 mode(LINES)
    ("over_budget", dict(mats=[m("base")], prim_mats=[0], tris=301), {}),
    ("non_triangle", dict(mats=[m("base")], prim_mats=[0], modes=[1]), {}),
    # L9: 피벗이 바닥 중심이 아님 / 노드 스케일 / 키가 큼 / 풋프린트보다 넓음
    ("pivot_offset", dict(mats=[m("base")], prim_mats=[0], offset=(0.5, 0.2, 0.0), height=0.8), {}),
    ("node_scaled", dict(mats=[m("base")], prim_mats=[0], tweak=tw_node_scaled), {}),
    ("too_tall", dict(mats=[m("base")], prim_mats=[0], height=1.2), {}),
    ("too_wide", dict(mats=[m("base")], prim_mats=[0], width=1.5), {}),
    # L10: 캐릭터에 glass
    ("character_glass", dict(mats=[m("base"), m("glass", (0.5, 0.7, 1.0, 0.4), "BLEND")], prim_mats=[0, 1]),
     {"category": "character", "poly_budget": "character"}),
    # 덧붙임: NORMAL 없음 / 미사용 머티리얼(경고) / extensionsRequired
    ("no_normal", dict(mats=[m("base")], prim_mats=[0], normals=False), {}),
    ("unused_material", dict(mats=[m("base"), m("accent")], prim_mats=[0]), {}),
    ("required_ext", dict(mats=[m("base")], prim_mats=[0], tweak=tw_required_ext), {}),
]


def meta_for(name, override):
    meta = {"asset_id": name, "category": "decor", "footprint": [1, 1], "height_m": 1.0,
            "poly_budget": "furniture_small", "ticket": "SE-027"}
    meta.update(override)
    return meta


def generate(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for name, kwargs, override in FIXTURES:
        build(out / f"{name}.glb", **kwargs)
        text = json.dumps(meta_for(name, override), indent=2, sort_keys=True) + "\n"
        (out / f"{name}.META.json").write_text(text, encoding="utf-8", newline="\n")


def main():
    ap = argparse.ArgumentParser(description="린터 픽스처(.glb + .META.json) 결정적 생성")
    ap.add_argument("out_dir", nargs="?", help="출력 디렉터리(--out 과 같음)")
    ap.add_argument("--out", help="출력 디렉터리")
    args = ap.parse_args()
    target = args.out or args.out_dir
    if not target:
        ap.error("출력 디렉터리가 필요함 (--out <dir>)")
    generate(target)


if __name__ == "__main__":
    main()
