#!/usr/bin/env python3
"""make_test_furniture.py 테스트 (SE-041 1차). 실행: python3 -I tools/assets/test_make_test_furniture.py

확인: (1) 5종 전부 린터 pass·거부 0·경고 0, (2) 두 번 생성한 결과가 바이트 동일(.glb·META.json·lint.json),
(3) 서피스(슬롯) 구성이 목표 표와 일치, (4) META 의 category·footprint·height_m·poly_budget 이 furniture.json 행과 일치.
표준 라이브러리만, Godot 불필요. 출력은 전부 임시 디렉터리(project/ 를 건드리지 않는다).
"""
import importlib.util
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FURNITURE_JSON = ROOT / "project" / "data" / "furniture" / "furniture.json"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


gen = load_module("make_test_furniture", HERE / "make_test_furniture.py")

# 목표 표(티켓 SE-041 목표 + 대응표): 가구 id → 서피스 슬롯(glb 안의 primitive 순서)
TARGET = {
    "stage_medium": ["base", "accent", "emissive"],
    "bar_counter": ["base", "accent"],
    "speaker_floor": ["base", "emissive"],
    "bar_fridge": ["base", "emissive", "glass"],  # 티켓 표기 base+glass+emissive 와 같은 집합, 서피스 순서는 base, accent, emissive, glass
    "light_spot": ["base", "emissive"],
}


def read_glb_json(path):
    b = Path(path).read_bytes()
    magic, version, length = struct.unpack_from("<4sII", b, 0)
    assert magic == b"glTF" and version == 2 and length == len(b)
    jlen, jtype = struct.unpack_from("<I4s", b, 12)
    assert jtype == b"JSON"
    return json.loads(b[20:20 + jlen].decode("utf-8"))


class TestMakeTestFurniture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.a = Path(cls.tmp.name) / "a"
        cls.b = Path(cls.tmp.name) / "b"
        cls.codes_a = gen.generate(cls.a, lint=True)
        cls.codes_b = gen.generate(cls.b, lint=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_target_table_is_the_generator_table(self):
        self.assertEqual(set(TARGET), set(gen.FURNITURE))
        for fid, slots in TARGET.items():
            self.assertEqual(gen.FURNITURE[fid][5], slots, fid)

    def test_all_five_pass_linter_without_items(self):
        for fid in TARGET:
            self.assertEqual(self.codes_a[fid], 0, fid)
            lint = json.loads((self.a / fid / "lint.json").read_text(encoding="utf-8"))
            self.assertEqual(lint["verdict"], "pass", fid)
            self.assertEqual(lint["items"], [], f"{fid}: 거부·경고 0 이어야 함")
            self.assertEqual(lint["asset_id"], fid)

    def test_byte_identical_across_runs(self):
        for fid in TARGET:
            for name in (f"{fid}.glb", "META.json", "lint.json"):
                self.assertEqual((self.a / fid / name).read_bytes(), (self.b / fid / name).read_bytes(), f"{fid}/{name}")

    def test_surface_slots_match_target_table(self):
        for fid, slots in TARGET.items():
            gl = read_glb_json(self.a / fid / f"{fid}.glb")
            prims = gl["meshes"][0]["primitives"]
            names = [gl["materials"][p["material"]]["name"] for p in prims]
            self.assertEqual(names, slots, fid)
            self.assertEqual(len(set(names)), len(names), f"{fid}: 같은 슬롯 서피스 중복")
            self.assertEqual(len(gl["nodes"]), 1)
            self.assertFalse(gl.get("extensionsRequired"))
            for k in ("images", "textures", "samplers", "skins", "animations"):
                self.assertFalse(gl.get(k), f"{fid}: {k}")
            for p in prims:
                self.assertIn("NORMAL", p["attributes"], fid)
                self.assertNotIn("COLOR_0", p["attributes"], fid)

    def test_triangle_count_within_budget(self):
        cfg = json.loads((HERE / "lint_config.json").read_text(encoding="utf-8"))
        for fid, (fn, _c, _f, _h, budget, _s) in gen.FURNITURE.items():
            self.assertLessEqual(fn().tri_count(), cfg["tri_budget"][budget], fid)

    def test_meta_matches_furniture_json_row(self):
        rows = {r["id"]: r for r in json.loads(FURNITURE_JSON.read_text(encoding="utf-8"))["rows"]}
        for fid in TARGET:
            self.assertIn(fid, rows)
            meta = json.loads((self.a / fid / "META.json").read_text(encoding="utf-8"))
            self.assertEqual(sorted(meta), ["asset_id", "category", "footprint", "height_m", "poly_budget", "ticket"])
            self.assertEqual(meta["ticket"], "SE-041")
            for k in ("category", "footprint", "height_m", "poly_budget"):
                self.assertEqual(meta[k], rows[fid][k], f"{fid}.{k}")


if __name__ == "__main__":
    unittest.main()
