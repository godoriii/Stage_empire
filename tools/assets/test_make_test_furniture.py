#!/usr/bin/env python3
"""make_test_furniture.py 테스트 (SE-041 1차). 실행: python3 -I tools/assets/test_make_test_furniture.py

확인: (1) 5종 전부 린터 pass·거부 0·경고 0, (2) 두 번 생성한 결과가 바이트 동일(.glb·META.json·lint.json),
(3) 서피스(슬롯) 구성이 목표 표와 일치, (4) META 의 category·footprint·height_m·poly_budget 이 furniture.json 행과 일치,
(5) glb 서피스(머티리얼) 이름 집합 == furniture.json 행 `slots` 키 집합 (SE-051; 키를 바꾼 사본에서는 실패해야 한다),
(6) preview.png 의 슬롯 색(base·accent·emissive)이 furniture.json `slots` 색과 일치 (SE-051 픽셀 표본),
(7) 비교 도구 compare_test_furniture.py: 같은 픽셀·다른 압축의 preview.png 는 통과, 픽셀 1개 다르면 실패 (SE-059 AC1),
(8) furniture.json 행 slots 키 ≠ 서피스이면 KeyError 가 아니라 "slots 키 ≠ 서피스: <행 id>" 오류 (SE-059 AC2).
표준 라이브러리만, Godot 불필요. 출력은 전부 임시 디렉터리(project/ 를 건드리지 않는다).
"""
import importlib.util
import json
import io
import math
import shutil
import struct
import sys
import tempfile
import unittest
import zlib
from contextlib import redirect_stdout
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
cmp_tool = load_module("compare_test_furniture", HERE / "compare_test_furniture.py")

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


def read_png_rgb(path):
    """8비트 RGB, 필터 0 만 쓰는 이 생성기의 PNG → (너비, 높이, [(r, g, b)*N])."""
    b = Path(path).read_bytes()
    assert b[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(b):
        n, tag = struct.unpack_from(">I4s", b, pos)
        data = b[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack_from(">IIBB", data, 0)
            assert (depth, ctype) == (8, 2)
        elif tag == b"IDAT":
            idat += data
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = 1 + 3 * w
    px = []
    for y in range(h):
        assert raw[y * stride] == 0
        row = raw[y * stride + 1:(y + 1) * stride]
        px.extend(tuple(row[i:i + 3]) for i in range(0, len(row), 3))
    return w, h, px


def hex_rgb(hexv):
    return tuple(int(hexv[i:i + 2], 16) for i in (1, 3, 5))


def shaded_candidates(rgb):
    """카메라(+X, -Z, 위)에서 보이는 축 정렬 면 3종(상면·+X·-Z)이 받는 밝기로 음영한 색. 생성기 render_png 와 같은 식."""
    lx, ly, lz = 0.4, 0.9, -0.5
    n = math.sqrt(lx * lx + ly * ly + lz * lz)
    light = (lx / n, ly / n, lz / n)
    out = set()
    for normal in ((0, 1, 0), (1, 0, 0), (0, 0, -1)):
        shade = 0.45 + 0.55 * max(0.0, sum(a * b for a, b in zip(normal, light)))
        out.add(tuple(min(255, int(c * shade)) for c in rgb))
    return out


def surface_names(glb_path):
    gl = read_glb_json(glb_path)
    return {gl["materials"][p["material"]]["name"] for p in gl["meshes"][0]["primitives"]}


def assert_surfaces_equal_slot_keys(testcase, glb_root, rows):
    """5종 각각: glb 서피스 이름 집합 == rows[id]['slots'] 키 집합. 어긋나면 AssertionError."""
    for fid in TARGET:
        testcase.assertEqual(surface_names(Path(glb_root) / fid / f"{fid}.glb"), set(rows[fid]["slots"]), fid)


class TestMakeTestFurniture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.a = Path(cls.tmp.name) / "a"
        cls.b = Path(cls.tmp.name) / "b"
        cls.codes_a = gen.generate(cls.a, lint=True)
        cls.codes_b = gen.generate(cls.b, lint=True)
        cls.p = Path(cls.tmp.name) / "p"
        gen.generate(cls.p, preview=True)  # 순수 파이썬 래스터라 느리다 — 한 번만

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

    def test_surface_names_equal_furniture_json_slot_keys(self):
        rows = {r["id"]: r for r in json.loads(FURNITURE_JSON.read_text(encoding="utf-8"))["rows"]}
        assert_surfaces_equal_slot_keys(self, self.a, rows)

    def test_slot_key_mismatch_in_temp_copy_fails(self):
        """한 행의 slots 키를 바꾼 임시 사본(원본 불변)에서 같은 대조가 실패해야 한다."""
        doc = json.loads(FURNITURE_JSON.read_text(encoding="utf-8"))
        before = FURNITURE_JSON.read_bytes()
        for fid, old, new in (("speaker_floor", "emissive", "glass"), ("bar_counter", "accent", "emissive")):
            copy = json.loads(json.dumps(doc))
            row = next(r for r in copy["rows"] if r["id"] == fid)
            row["slots"][new] = row["slots"].pop(old)
            rows = {r["id"]: r for r in copy["rows"]}
            with self.assertRaises(AssertionError, msg=f"{fid}: {old}->{new}"):
                assert_surfaces_equal_slot_keys(self, self.a, rows)
        self.assertEqual(FURNITURE_JSON.read_bytes(), before)

    def test_preview_slot_colors_match_furniture_json(self):
        """preview.png 에 슬롯 색이 나온다: emissive 는 무음영이라 정확히 그 색, base·accent 는 보이는 면 3종의 음영색 중 하나.
        (glass 는 아래 면과 섞여 표본이 불안정해 제외.)"""
        rows = {r["id"]: r for r in json.loads(FURNITURE_JSON.read_text(encoding="utf-8"))["rows"]}
        for fid in TARGET:
            w, h, px = read_png_rgb(self.p / fid / "preview.png")
            self.assertEqual((w, h), (384, 384), fid)
            counts = {}
            for c in px:
                counts[c] = counts.get(c, 0) + 1
            for slot, hexv in rows[fid]["slots"].items():
                if slot == "glass":
                    continue
                rgb = hex_rgb(hexv)
                want = {rgb} if slot == "emissive" else shaded_candidates(rgb)
                got = sum(counts.get(c, 0) for c in want)
                self.assertGreaterEqual(got, 20, f"{fid}.{slot} {hexv}: 일치 픽셀 {got}")

    # ------------------------------------------------------------ SE-059 AC1: PNG 픽셀 비교

    def _copy_tree(self, name):
        dst = Path(self.tmp.name) / name
        shutil.copytree(self.p, dst)
        return dst

    @staticmethod
    def _write_png(path, w, h, pixels, level):
        """RGB 픽셀 bytes → PNG(필터 0, IDAT 를 두 청크로 쪼갬). 압축 수준만 다르게 다시 쓴다."""
        rows = b"".join(b"\x00" + pixels[y * w * 3:(y + 1) * w * 3] for y in range(h))
        z = zlib.compress(rows, level)
        half = len(z) // 2

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", z[:half]) + chunk(b"IDAT", z[half:]) + chunk(b"IEND", b""))

    def test_png_compare_passes_for_same_pixels_other_compression(self):
        q = self._copy_tree("q_recompressed")
        for fid in TARGET:
            f = q / fid / "preview.png"
            w, h, ch, pix = cmp_tool.decode_png(f.read_bytes())
            self._write_png(f, w, h, pix, 1)
            self.assertNotEqual(f.read_bytes(), (self.p / fid / "preview.png").read_bytes(), f"{fid}: 사본이 바이트까지 같으면 시험이 아님")
        self.assertEqual(cmp_tool.compare_dirs(self.p, q), [])
        with redirect_stdout(io.StringIO()):
            self.assertEqual(cmp_tool.main(["x", str(self.p), str(q)]), 0)

    def test_png_compare_fails_for_one_changed_pixel(self):
        q = self._copy_tree("q_one_pixel")
        f = q / "bar_counter" / "preview.png"
        w, h, ch, pix = cmp_tool.decode_png(f.read_bytes())
        pix = bytearray(pix)
        i = (100 * w + 200) * 3  # (x=200, y=100)
        pix[i] ^= 1
        self._write_png(f, w, h, bytes(pix), 9)
        diffs = cmp_tool.compare_dirs(self.p, q)
        self.assertEqual([d[0] for d in diffs], ["bar_counter/preview.png"])
        self.assertIn("x=200, y=100", diffs[0][1])
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertEqual(cmp_tool.main(["x", str(self.p), str(q)]), 1)
        self.assertIn("DIFF bar_counter/preview.png", buf.getvalue())

    def test_compare_flags_byte_diff_in_glb_and_missing_file(self):
        q = self._copy_tree("q_bytes")
        g = q / "light_spot" / "light_spot.glb"
        b = bytearray(g.read_bytes())
        b[-1] ^= 1
        g.write_bytes(bytes(b))
        (q / "speaker_floor" / "META.json").unlink()
        got = dict(cmp_tool.compare_dirs(self.p, q))
        self.assertIn("바이트 다름", got["light_spot/light_spot.glb"])
        self.assertIn("없음", got["speaker_floor/META.json"])

    # ------------------------------------------------------------ SE-059 AC2: slots 키 진단

    def _json_with_mutated_row(self, fid, old, new):
        doc = json.loads(FURNITURE_JSON.read_text(encoding="utf-8"))
        row = next(r for r in doc["rows"] if r["id"] == fid)
        row["slots"][new] = row["slots"].pop(old)
        path = Path(self.tmp.name) / f"furniture_{fid}.json"
        path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        return path

    def test_preview_slot_key_mismatch_reports_row_id_not_keyerror(self):
        alt = self._json_with_mutated_row("speaker_floor", "emissive", "glass")
        with self.assertRaises(gen.SlotKeyMismatch) as cm:  # KeyError 가 아니다
            gen.preview_colors("speaker_floor", alt)
        self.assertIn("slots 키 ≠ 서피스: speaker_floor", str(cm.exception))
        # generate() 도 같은 오류로 멈춘다(첫 행 stage_medium 에서 렌더 전에 멈춰 빠르다).
        alt2 = self._json_with_mutated_row("stage_medium", "accent", "glass")
        with self.assertRaisesRegex(gen.SlotKeyMismatch, "slots 키 ≠ 서피스: stage_medium"):
            gen.generate(Path(self.tmp.name) / "mismatch", preview=True, furniture_json=alt2)


if __name__ == "__main__":
    unittest.main()
