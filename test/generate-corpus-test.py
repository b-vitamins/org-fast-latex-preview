#!/usr/bin/env python3
"""Unit tests for the deterministic stress corpus generator."""

from __future__ import annotations

import importlib.util
import random
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "generate-corpus.py"

SPEC = importlib.util.spec_from_file_location("generate_corpus", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"unable to load generator from {SCRIPT_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class GenerateCorpusTest(unittest.TestCase):
    def test_valid_fragments_pass_generator_validation(self) -> None:
        for kind in ("inline", "equation", "align", "complex"):
            rng = random.Random(MODULE.stable_offset(kind))
            for uid in range(1, 300):
                fragment = MODULE.valid_fragment(kind, rng, uid)
                MODULE.validate_fragment_text(fragment)
                for pattern in MODULE.DOUBLE_SCRIPT_PATTERNS:
                    self.assertIsNone(
                        pattern.search(fragment),
                        msg=f"unexpected repeated script for {kind}: {fragment}",
                    )

    def test_small_profile_build_respects_invalid_ratio(self) -> None:
        spec = MODULE.ProfileSpec(
            name="small-failure",
            total_fragments=120,
            unique_ratio=0.65,
            invalid_ratio=0.1,
            inline_ratio=0.5,
            equation_ratio=0.25,
            align_ratio=0.15,
            complex_ratio=0.1,
            fragments_per_section=20,
            fragments_per_subsection=10,
            scenario="test",
        )
        fragments, counts = MODULE.build_fragment_sequence(spec, 424242)
        self.assertEqual(sum(counts.values()), spec.total_fragments)
        self.assertEqual(len(fragments), spec.total_fragments)
        invalid_count = sum(1 for fragment in fragments if not fragment["valid"])
        self.assertEqual(invalid_count, 12)
        self.assertEqual(spec.total_fragments - invalid_count, 108)

    def test_generate_profile_writes_metadata(self) -> None:
        spec = MODULE.ProfileSpec(
            name="tiny-throughput",
            total_fragments=40,
            unique_ratio=1.0,
            invalid_ratio=0.0,
            inline_ratio=0.5,
            equation_ratio=0.25,
            align_ratio=0.15,
            complex_ratio=0.1,
            fragments_per_section=10,
            fragments_per_subsection=5,
            scenario="test",
        )
        with tempfile.TemporaryDirectory() as directory:
            metadata = MODULE.generate_profile(Path(directory), 20260307, spec)
            path = Path(metadata["path"])
            self.assertTrue(path.exists())
            self.assertEqual(metadata["total_fragments"], spec.total_fragments)
            self.assertEqual(metadata["expected_successful_fragments"], spec.total_fragments)
            self.assertEqual(len(metadata["sha1"]), 40)


if __name__ == "__main__":
    unittest.main()
