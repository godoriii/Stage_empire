#!/usr/bin/env python3
"""lint_gltf.py 단위 테스트 (SE-027). 실행: python3 -I tools/assets/test_lint_gltf.py

픽스처(tools/assets/fixtures/*.glb)마다 기대 항목 id·수준을 단언한다. Godot 불필요, 표준 라이브러리만.
lint.json 출력은 전부 임시 디렉터리에 쓴다(project/ 를 건드리지 않는다).
"""
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
LINT = HERE / "lint_gltf.py"
CONFIG = HERE / "lint_config.json"
GEN = HERE / "q5_probe" / "make_probe_glb.py"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


lint_gltf = load_module("lint_gltf", LINT)
make_probe_glb = load_module("make_probe_glb", GEN)

R, W = "reject", "warn"

# 픽스처 → 기대 (id, 수준) 집합. 빈 집합 = 통과(경고 0).
EXPECTED = {
    "slots4": set(),
    "bad_names": {("L1", R), ("L2", R), ("L3", R), ("L4", R)},
    "no_base": {("L2", R)},
    "dup_two_materials": {("L3", R)},
    "dup_shared_material": {("L3", R)},
    "five_surfaces": {("L3", R)},
    "vertex_alpha": {("L5", R)},
    "vertex_color_rgb": {("L5", W)},
    "with_texture": {("L6", R)},
    "two_nodes": {("L7", R)},
    "child_node": {("L7", R)},
    "with_animation": {("L7", R)},
    "over_budget": {("L8", R)},
    "non_triangle": {("L8", R)},
    "pivot_offset": {("L9", R)},
    "node_scaled": {("L9", R)},
    "too_tall": {("L9", R)},
    "too_wide": {("L9", R)},
    "character_glass": {("L10", R)},
    "no_normal": {("A1", R)},
    "unused_material": {("A2", W)},
    "required_ext": {("A3", R)},
}


def fixture_files():
    """fixtures/ 의 생성물(.glb, .META.json). 점 파일(.gitattributes: LFS 해제)은 제외."""
    return [p for p in FIXTURES.iterdir() if not p.name.startswith(".")]


def run_lint(name, config=None, meta_override=None):
    """(items, 종료코드 상당 verdict) — 인-프로세스 호출."""
    cfg, _ = lint_gltf.load_config(config or CONFIG)
    meta_path = FIXTURES / f"{name}.META.json"
    meta = lint_gltf.load_meta(meta_path, cfg)
    if meta_override:
        meta.update(meta_override)
    return lint_gltf.lint(FIXTURES / f"{name}.glb", meta, cfg)


def cli(*args):
    return subprocess.run([sys.executable, "-I", str(LINT), *map(str, args)],
                          capture_output=True, text=True, encoding="utf-8")


def messages(items, item_id):
    return [it["message"] for it in items if it["id"] == item_id]


class FixtureTable(unittest.TestCase):
    """픽스처마다 기대 항목 id·수준(메서드는 아래에서 동적으로 만든다)."""


def _make_case(name, expected):
    def test(self):
        items = run_lint(name)
        got = {(it["id"], it["level"]) for it in items}
        self.assertEqual(got, expected, f"{name}: {items}")
    return test


for _name, _expected in EXPECTED.items():
    setattr(FixtureTable, f"test_fixture_{_name}", _make_case(_name, _expected))


class Coverage(unittest.TestCase):
    def test_every_checklist_item_has_a_fixture(self):
        covered = {i for exp in EXPECTED.values() for i, _ in exp}
        want = {f"L{n}" for n in range(1, 11)} | {"A1", "A2", "A3"}
        self.assertEqual(covered, want)

    def test_expected_matches_generator_list(self):
        names = {n for n, _, _ in make_probe_glb.FIXTURES}
        self.assertEqual(names, set(EXPECTED))

    def test_passing_fixture_has_no_items(self):
        self.assertEqual(run_lint("slots4"), [])


class Messages(unittest.TestCase):
    """AC4: 메시지 형식(GLTF_SPEC §3 표)."""

    def test_l1_unknown_slot_name_message(self):
        items = run_lint("bad_names")
        want = "bad_names.glb: 머티리얼 'metal' 은 슬롯 이름이 아님 (base|accent|emissive|glass)"
        self.assertTrue(any(m.startswith(want) for m in messages(items, "L1")), messages(items, "L1"))
        self.assertTrue(any("primitive #3" in m for m in messages(items, "L1")))

    def test_l1_suffix_and_case_variants(self):
        msgs = " ".join(messages(run_lint("bad_names"), "L1"))
        self.assertIn("머티리얼 'base.001' 은 슬롯 이름이 아님", msgs)
        self.assertIn("머티리얼 'Accent' 은 슬롯 이름이 아님", msgs)

    def test_l1_unnamed_material(self):
        self.assertIn("bad_names.glb: 머티리얼 #2 이름 없음", messages(run_lint("bad_names"), "L1")[2])

    def test_l4_primitive_without_material(self):
        self.assertEqual(messages(run_lint("bad_names"), "L4"),
                         ["bad_names.glb: 메시 'MeshData' primitive #4 머티리얼 없음"])

    def test_l2_and_l3_messages(self):
        self.assertEqual(messages(run_lint("no_base"), "L2"), ["no_base.glb: base 슬롯 서피스 없음"])
        self.assertEqual(messages(run_lint("dup_shared_material"), "L3"),
                         ["dup_shared_material.glb: 슬롯 'base' 서피스 2개 (primitive #0, #1)"])
        self.assertIn("five_surfaces.glb: 서피스 5개 (최대 4)", messages(run_lint("five_surfaces"), "L3"))

    def test_l8_and_l9_messages_carry_numbers(self):
        self.assertEqual(messages(run_lint("over_budget"), "L8"),
                         ["over_budget.glb: 삼각형 301개 > 예산 300 (furniture_small)"])
        self.assertIn("pivot_offset.glb: 피벗: AABB min.y=0.2", messages(run_lint("pivot_offset"), "L9")[0])


class MetaInfluence(unittest.TestCase):
    def test_footprint_from_meta_decides_l9(self):
        items = run_lint("too_wide", meta_override={"footprint": [2, 1]})
        self.assertEqual(items, [])

    def test_height_tolerance_from_meta(self):
        items = run_lint("too_tall", meta_override={"height_m": 1.2})
        self.assertEqual(items, [])

    def test_poly_budget_from_meta(self):
        self.assertEqual(run_lint("over_budget", meta_override={"poly_budget": "equipment_large"}), [])

    def test_character_budget_and_glass_rule_follow_meta(self):
        ok = run_lint("character_glass", meta_override={"category": "decor", "poly_budget": "furniture_small"})
        self.assertEqual(ok, [])


class ConfigDrivesVerdict(unittest.TestCase):
    """AC2: 설정 파일을 바꾸면 판정이 바뀐다."""

    def test_lowered_budget_rejects_slots4(self):
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
        cfg["tri_budget"]["furniture_small"] = 4
        with tempfile.TemporaryDirectory() as td:
            low = Path(td) / "low.json"
            low.write_text(json.dumps(cfg), encoding="utf-8")
            items = run_lint("slots4", config=low)
            self.assertEqual({(i["id"], i["level"]) for i in items}, {("L8", R)})
            out = Path(td) / "lint.json"
            r = cli(FIXTURES / "slots4.glb", FIXTURES / "slots4.META.json", "--out", out, "--config", low)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertNotEqual(data["config_sha256"], lint_gltf.load_config(CONFIG)[1])

    def test_tolerance_comes_from_config(self):
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
        cfg["tolerance"]["pivot_m"] = 1.0
        with tempfile.TemporaryDirectory() as td:
            loose = Path(td) / "loose.json"
            loose.write_text(json.dumps(cfg), encoding="utf-8")
            self.assertEqual(run_lint("pivot_offset", config=loose), [])

    def test_no_numeric_literals_in_linter_source(self):
        """rg -n '0\\.01|1e-4|300|1500|800|150' 가 주석 밖에서 0건."""
        pat = re.compile(r"0\.01|1e-4|300|1500|800|150")
        hits = []
        for no, line in enumerate(LINT.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("#", 1)[0]
            if pat.search(code):
                hits.append((no, line))
        self.assertEqual(hits, [])

    def test_config_budgets_match_style_guide_row(self):
        """lint_config.json 의 예산은 style-guide '폴리곤 예산' 행의 복사본이다. 어긋나면 여기서 잡는다."""
        guide = HERE.parents[1] / "docs" / "style-guide.md"
        row = next(l for l in guide.read_text(encoding="utf-8").splitlines() if l.startswith("| 폴리곤 예산"))
        nums = [int(n.replace(",", "")) for n in re.findall(r"≤\s*([0-9][0-9,]*)\s*tri", row)]
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))["tri_budget"]
        self.assertEqual(nums, [cfg["furniture_small"], cfg["equipment_large"], cfg["character"], cfg["lod1"]])


class Cli(unittest.TestCase):
    def test_pass_exit_0_and_lint_json_format(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "sub" / "lint.json"
            r = cli(FIXTURES / "slots4.glb", FIXTURES / "slots4.META.json", "--out", out)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(list(data), ["asset_id", "glb", "meta", "verdict", "items", "config_sha256"])
            self.assertEqual((data["asset_id"], data["glb"], data["meta"], data["verdict"], data["items"]),
                             ("slots4", "slots4.glb", "slots4.META.json", "pass", []))
            self.assertRegex(data["config_sha256"], r"^[0-9a-f]{64}$")

    def test_reject_exit_1_still_writes_lint_json(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "lint.json"
            r = cli(FIXTURES / "bad_names.glb", FIXTURES / "bad_names.META.json", "--out", out)
            self.assertEqual(r.returncode, 1)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(data["verdict"], "reject")
            self.assertEqual([i["id"] for i in data["items"]][:1], ["L1"])
            for it in data["items"]:
                self.assertEqual(sorted(it), ["id", "level", "message"])
                self.assertIn(it["level"], (R, W))

    def test_warning_only_exits_0_with_warn_items(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "lint.json"
            r = cli(FIXTURES / "unused_material.glb", FIXTURES / "unused_material.META.json", "--out", out)
            self.assertEqual(r.returncode, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual((data["verdict"], [i["level"] for i in data["items"]]), ("pass", [W]))

    def test_exit_2_on_missing_glb(self):
        with tempfile.TemporaryDirectory() as td:
            r = cli(Path(td) / "none.glb", FIXTURES / "slots4.META.json", "--out", Path(td) / "l.json")
            self.assertEqual(r.returncode, 2)
            self.assertFalse((Path(td) / "l.json").exists())

    def test_exit_2_on_not_a_glb(self):
        with tempfile.TemporaryDirectory() as td:
            junk = Path(td) / "junk.glb"
            junk.write_bytes(b"not a glb file at all")
            r = cli(junk, FIXTURES / "slots4.META.json", "--out", Path(td) / "l.json")
            self.assertEqual(r.returncode, 2)

    def test_exit_2_on_bad_meta(self):
        with tempfile.TemporaryDirectory() as td:
            meta = json.loads((FIXTURES / "slots4.META.json").read_text(encoding="utf-8"))
            for patch in ({"category": "metal"}, {"footprint": [0, 1]}, {"height_m": "tall"},
                          {"poly_budget": "huge"}, {"extra": 1}):
                bad = Path(td) / "bad.META.json"
                bad.write_text(json.dumps({**meta, **patch}), encoding="utf-8")
                r = cli(FIXTURES / "slots4.glb", bad, "--out", Path(td) / "l.json")
                self.assertEqual(r.returncode, 2, patch)
            del meta["ticket"]
            bad.write_text(json.dumps(meta), encoding="utf-8")
            self.assertEqual(cli(FIXTURES / "slots4.glb", bad, "--out", Path(td) / "l.json").returncode, 2)

    def test_exit_2_on_missing_arguments(self):
        self.assertEqual(cli().returncode, 2)

    def test_default_out_path_is_review_queue(self):
        p = lint_gltf.default_out_path("sofa_01")
        self.assertEqual(p, lint_gltf.REPO_ROOT / "project" / "assets" / "review-queue" / "sofa_01" / "lint.json")


class Fixtures(unittest.TestCase):
    def test_pairs_exist_and_are_small(self):
        files = sorted(p.name for p in fixture_files())
        want = sorted([f"{n}.glb" for n, _, _ in make_probe_glb.FIXTURES]
                      + [f"{n}.META.json" for n, _, _ in make_probe_glb.FIXTURES])
        self.assertEqual(files, want)
        for p in fixture_files():
            self.assertLess(p.stat().st_size, 10 * 1024, p.name)

    def test_regeneration_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as td:
            make_probe_glb.generate(td)
            for p in sorted(fixture_files()):
                self.assertEqual((Path(td) / p.name).read_bytes(), p.read_bytes(), p.name)

    def test_generator_cli_accepts_out_flag(self):
        with tempfile.TemporaryDirectory() as td:
            r = subprocess.run([sys.executable, "-I", str(GEN), "--out", td], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue((Path(td) / "slots4.glb").exists())


if __name__ == "__main__":
    unittest.main()
