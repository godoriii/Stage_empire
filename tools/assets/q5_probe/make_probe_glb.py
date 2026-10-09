#!/usr/bin/env python3
"""SE-019 Q5 확인용 최소 .glb 생성기(표준 라이브러리만 사용).

사용: python3 make_probe_glb.py <출력 디렉터리>
쿼드 N 개를 primitive 하나씩에 담고 머티리얼 이름·정점 색을 바꿔 가며 .glb 를 만든다.
GLTF_SPEC.md "Godot 임포트 확인" 절의 재현 절차용이다. 게임 에셋이 아니다.
"""
import json
import struct
import sys
from pathlib import Path


def build(path, mats, prim_mats, colors=None):
    n = len(prim_mats)
    bin_ = bytearray()
    views, accs, prims = [], [], []

    def add(data, target, comp, typ, count, extra=None):
        while len(bin_) % 4:
            bin_.append(0)
        off = len(bin_)
        bin_.extend(data)
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        a = {"bufferView": len(views) - 1, "componentType": comp, "count": count, "type": typ}
        if extra:
            a.update(extra)
        accs.append(a)
        return len(accs) - 1

    for i in range(n):
        x = float(i)
        p = [(x, 0, 0), (x + 0.5, 0, 0), (x + 0.5, 0.5, 0), (x, 0.5, 0)]
        pa = add(b"".join(struct.pack("<3f", *v) for v in p), 34962, 5126, "VEC3", 4,
                 {"min": [min(v[k] for v in p) for k in range(3)],
                  "max": [max(v[k] for v in p) for k in range(3)]})
        na = add(b"".join(struct.pack("<3f", 0, 0, 1) for _ in range(4)), 34962, 5126, "VEC3", 4)
        ia = add(struct.pack("<6H", 0, 1, 2, 0, 2, 3), 34963, 5123, "SCALAR", 6)
        attrs = {"POSITION": pa, "NORMAL": na}
        if colors is not None:
            attrs["COLOR_0"] = add(b"".join(struct.pack("<4f", *colors) for _ in range(4)),
                                   34962, 5126, "VEC4", 4)
        pr = {"attributes": attrs, "indices": ia}
        if prim_mats[i] is not None:
            pr["material"] = prim_mats[i]
        prims.append(pr)

    gl = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
          "nodes": [{"name": "Mesh", "mesh": 0}],
          "meshes": [{"name": "MeshData", "primitives": prims}],
          "materials": mats, "accessors": accs, "bufferViews": views,
          "buffers": [{"byteLength": len(bin_)}]}
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


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    glass = m("glass", (0.5, 0.7, 1.0, 0.4), "BLEND")
    build(out / "slots4.glb", [m("base"), m("accent", (1, 0, 0, 1)), m("emissive", (1, 1, 0, 1)), glass], [0, 1, 2, 3])
    # 거부 대상 이름: DCC 접미, 대소문자 변형, 이름 없는 머티리얼, 재질 이름, 머티리얼 없는 primitive
    build(out / "bad_names.glb", [m("base.001"), m("Accent"), m(None), m("metal")], [0, 1, 2, 3, None])
    # 같은 이름의 머티리얼 2개를 서피스 2개에(슬롯 중복 거부 대상)
    build(out / "dup_two_materials.glb", [m("base"), m("base")], [0, 1])
    # 머티리얼 1개를 primitive 2개가 공유(같은 슬롯 서피스 2개)
    build(out / "dup_shared_material.glb", [m("base")], [0, 0])
    # 정점 색 알파 0.5
    build(out / "vertex_alpha.glb", [m("base")], [0], colors=(1, 1, 1, 0.5))


if __name__ == "__main__":
    main()
