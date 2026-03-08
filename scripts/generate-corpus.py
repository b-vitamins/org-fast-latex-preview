#!/usr/bin/env python3
"""Generate deterministic stress corpora for org-fast-latex-preview."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
from dataclasses import dataclass
from pathlib import Path
from textwrap import dedent


COMMON_PREAMBLE = dedent(
    r"""
    \usepackage{mathtools}
    \usepackage{bm}
    \newcommand{\dd}{\mathop{}\!\mathrm{d}}
    \newcommand{\pd}[2]{\frac{\partial #1}{\partial #2}}
    \newcommand{\vect}[1]{\bm{#1}}
    \newcommand{\abs}[1]{\left\lvert #1 \right\rvert}
    \newcommand{\norm}[1]{\left\lVert #1 \right\rVert}
    \newcommand{\ket}[1]{\left\lvert #1 \right\rangle}
    \newcommand{\bra}[1]{\left\langle #1 \right\rvert}
    \newcommand{\comm}[2]{\left[#1, #2\right]}
    \newcommand{\acomm}[2]{\left\{#1, #2\right\}}
    """
).strip() + "\n"


@dataclass(frozen=True)
class ProfileSpec:
    name: str
    total_fragments: int
    unique_ratio: float
    invalid_ratio: float
    inline_ratio: float
    equation_ratio: float
    align_ratio: float
    complex_ratio: float
    fragments_per_section: int
    fragments_per_subsection: int | None
    scenario: str


PROFILES = {
    "throughput-50k": ProfileSpec(
        name="throughput-50k",
        total_fragments=50_000,
        unique_ratio=0.92,
        invalid_ratio=0.0,
        inline_ratio=0.60,
        equation_ratio=0.25,
        align_ratio=0.10,
        complex_ratio=0.05,
        fragments_per_section=250,
        fragments_per_subsection=None,
        scenario="throughput",
    ),
    "cache-heavy-50k": ProfileSpec(
        name="cache-heavy-50k",
        total_fragments=50_000,
        unique_ratio=0.18,
        invalid_ratio=0.0,
        inline_ratio=0.60,
        equation_ratio=0.25,
        align_ratio=0.10,
        complex_ratio=0.05,
        fragments_per_section=250,
        fragments_per_subsection=None,
        scenario="cache-heavy",
    ),
    "cold-unique-25k": ProfileSpec(
        name="cold-unique-25k",
        total_fragments=25_000,
        unique_ratio=1.0,
        invalid_ratio=0.0,
        inline_ratio=0.60,
        equation_ratio=0.25,
        align_ratio=0.10,
        complex_ratio=0.05,
        fragments_per_section=200,
        fragments_per_subsection=None,
        scenario="cold-unique",
    ),
    "failure-mixed-10k": ProfileSpec(
        name="failure-mixed-10k",
        total_fragments=10_000,
        unique_ratio=0.80,
        invalid_ratio=0.01,
        inline_ratio=0.60,
        equation_ratio=0.25,
        align_ratio=0.10,
        complex_ratio=0.05,
        fragments_per_section=150,
        fragments_per_subsection=None,
        scenario="failure-mixed",
    ),
    "edit-churn-10k": ProfileSpec(
        name="edit-churn-10k",
        total_fragments=10_000,
        unique_ratio=0.75,
        invalid_ratio=0.0,
        inline_ratio=0.60,
        equation_ratio=0.25,
        align_ratio=0.10,
        complex_ratio=0.05,
        fragments_per_section=80,
        fragments_per_subsection=20,
        scenario="edit-churn",
    ),
}


GREEK = [
    r"\alpha",
    r"\beta",
    r"\gamma",
    r"\delta",
    r"\epsilon",
    r"\eta",
    r"\theta",
    r"\lambda",
    r"\mu",
    r"\nu",
    r"\omega",
    r"\phi",
    r"\pi",
    r"\sigma",
]

BASE_SYMBOLS = [
    "x",
    "y",
    "z",
    "p",
    "q",
    "r",
    "s",
    "t",
    "u",
    "v",
    "A",
    "B",
    "C",
    "D",
    "E",
    "F",
    "G",
    "H",
    "L",
    "M",
]

OPERATORS = [r"\sin", r"\cos", r"\exp", r"\log", r"\tanh"]

DOUBLE_SCRIPT_PATTERNS = (
    re.compile(r"\^\{[^{}]*\}\^\{"),
    re.compile(r"_\{[^{}]*\}_\{"),
)


def stable_offset(name: str) -> int:
    return sum((index + 1) * ord(char) for index, char in enumerate(name))


def exact_counts(total: int, spec: ProfileSpec) -> dict[str, int]:
    inline = int(total * spec.inline_ratio)
    equation = int(total * spec.equation_ratio)
    align = int(total * spec.align_ratio)
    complex_count = total - inline - equation - align
    return {
        "inline": inline,
        "equation": equation,
        "align": align,
        "complex": complex_count,
    }


def bare_symbol(rng: random.Random) -> str:
    return rng.choice(BASE_SYMBOLS + GREEK)


def apply_scripts(base: str, uid: int, style: int) -> str:
    if style == 0:
        return f"{base}_{{{uid % 17}}}"
    if style == 1:
        return f"{base}^{{{2 + (uid % 4)}}}"
    if style == 2:
        return f"{base}_{{{uid % 7}}}^{{{1 + (uid % 3)}}}"
    return base


def choose_symbol(rng: random.Random, uid: int) -> str:
    base = bare_symbol(rng)
    style = rng.randrange(6)
    if style == 0:
        return apply_scripts(base, uid, 0)
    if style == 1:
        return apply_scripts(base, uid, 1)
    if style == 2:
        return apply_scripts(f"\\vect{{{base}}}", uid, rng.randrange(4))
    if style == 3:
        return apply_scripts(f"\\hat{{{base}}}", uid, rng.randrange(4))
    if style == 4:
        return apply_scripts(base, uid, 2)
    return apply_scripts(base, uid, 3)


def leaf(rng: random.Random, uid: int) -> str:
    choice = rng.randrange(7)
    if choice == 0:
        return choose_symbol(rng, uid)
    if choice == 1:
        return str(2 + (uid % 9))
    if choice == 2:
        return f"({uid % 5 + 1}/{uid % 7 + 2})"
    if choice == 3:
        return f"m_{{{uid % 9}}}"
    if choice == 4:
        return f"\\omega_{{{uid % 12}}}"
    if choice == 5:
        return f"\\ket{{\\psi_{{{uid % 16}}}}}"
    return f"\\bra{{\\phi_{{{uid % 16}}}}}"


def expr(rng: random.Random, uid: int, depth: int) -> str:
    if depth <= 0:
        return leaf(rng, uid)
    choice = rng.randrange(10)
    if choice == 0:
        return f"{expr(rng, uid + 1, depth - 1)} + {expr(rng, uid + 2, depth - 1)}"
    if choice == 1:
        return f"{expr(rng, uid + 3, depth - 1)} - {expr(rng, uid + 4, depth - 1)}"
    if choice == 2:
        return f"{expr(rng, uid + 5, depth - 1)} {expr(rng, uid + 6, depth - 1)}"
    if choice == 3:
        return rf"\frac{{{expr(rng, uid + 7, depth - 1)}}}{{{expr(rng, uid + 8, depth - 1)}}}"
    if choice == 4:
        return rf"\sqrt{{{expr(rng, uid + 9, depth - 1)}}}"
    if choice == 5:
        return rf"\left({expr(rng, uid + 15, depth - 1)}\right)^{{{2 + (uid % 4)}}}"
    if choice == 6:
        operator = rng.choice(OPERATORS)
        return rf"{operator}\left({expr(rng, uid + 10, depth - 1)}\right)"
    if choice == 7:
        return rf"\sum_{{n=0}}^{{{3 + (uid % 6)}}} {expr(rng, uid + 11, depth - 1)}"
    if choice == 8:
        return rf"\int_0^{{{2 + (uid % 5)}}} {expr(rng, uid + 12, depth - 1)} \,\dd {rng.choice(['x', 't', 'k'])}"
    return rf"\comm{{{expr(rng, uid + 13, depth - 1)}}}{{{expr(rng, uid + 14, depth - 1)}}}"


def equation_body(rng: random.Random, uid: int) -> str:
    left = expr(rng, uid, 2)
    right = expr(rng, uid + 1000, 2)
    variants = [
        rf"{left} = {right}",
        rf"\pd{{{left}}}{{t}} = - {right}",
        rf"\int_0^\infty {left} \,\dd k = {right}",
        rf"\comm{{{left}}}{{{right}}} = i \hbar \, {expr(rng, uid + 2000, 1)}",
        rf"\sum_{{n=0}}^{{{2 + (uid % 5)}}} {left} = {right}",
    ]
    return rng.choice(variants)


def align_body(rng: random.Random, uid: int) -> str:
    lines = []
    for offset in range(2 + (uid % 2)):
        left = expr(rng, uid + offset * 100, 1)
        right = equation_body(rng, uid + offset * 200)
        lines.append(rf"{left} &= {right}")
    return "\\\\\n".join(lines)


def matrix_body(rng: random.Random, uid: int) -> str:
    size = 2 + (uid % 2)
    rows = []
    for row in range(size):
        terms = []
        for col in range(size):
            terms.append(expr(rng, uid + row * 10 + col, 1))
        rows.append(" & ".join(terms))
    matrix = "\\\\\n".join(rows)
    left = rf"M_{{{uid % 17}}}"
    return dedent(
        rf"""
        {left} =
        \begin{{pmatrix}}
        {matrix}
        \end{{pmatrix}}
        """
    ).strip()


def cases_body(rng: random.Random, uid: int) -> str:
    x_symbol = choose_symbol(rng, uid)
    first = expr(rng, uid + 1, 1)
    second = expr(rng, uid + 2, 1)
    return dedent(
        rf"""
        f_{{{uid % 19}}}\left({x_symbol}\right) =
        \begin{{cases}}
        {first}, & {x_symbol} < {uid % 7 + 1} \\
        {second}, & {x_symbol} \ge {uid % 7 + 1}
        \end{{cases}}
        """
    ).strip()


def complex_body(rng: random.Random, uid: int) -> str:
    variants = [
        matrix_body(rng, uid),
        cases_body(rng, uid),
        rf"\norm{{{expr(rng, uid + 3, 2)}}}^2 = \abs{{{expr(rng, uid + 4, 2)}}}",
        rf"\bra{{\psi_{{{uid % 31}}}}} \hat{{H}} \ket{{\phi_{{{uid % 37}}}}} = {expr(rng, uid + 5, 2)}",
    ]
    return rng.choice(variants)


def valid_fragment(kind: str, rng: random.Random, uid: int) -> str:
    if kind == "inline":
        return f"${equation_body(rng, uid)}$"
    if kind == "equation":
        return dedent(
            rf"""
            \begin{{equation}}
            {equation_body(rng, uid)}
            \end{{equation}}
            """
        ).strip()
    if kind == "align":
        return dedent(
            rf"""
            \begin{{align}}
            {align_body(rng, uid)}
            \end{{align}}
            """
        ).strip()
    return dedent(
        rf"""
        \begin{{equation}}
        {complex_body(rng, uid)}
        \end{{equation}}
        """
    ).strip()


def invalid_fragment(kind: str, uid: int) -> str:
    bad = rf"\thismacrodoesnotexist_{{{uid}}}"
    if kind == "inline":
        return f"${bad} + \\frac{{1}}{{2}}$"
    if kind == "align":
        return dedent(
            rf"""
            \begin{{align}}
            a_{{{uid}}} &= {bad} \\
            b_{{{uid}}} &= 0
            \end{{align}}
            """
        ).strip()
    return dedent(
        rf"""
        \begin{{equation}}
        {bad} + \frac{{1}}{{2}}
        \end{{equation}}
        """
    ).strip()


def validate_fragment_text(text: str) -> None:
    if text.count("{") != text.count("}"):
        raise ValueError(f"unbalanced braces in fragment: {text[:120]!r}")
    environments = [
        "equation",
        "align",
        "pmatrix",
        "cases",
    ]
    for environment in environments:
        if text.count(rf"\begin{{{environment}}}") != text.count(rf"\end{{{environment}}}"):
            raise ValueError(f"unbalanced {environment} environment in fragment: {text[:120]!r}")
    for pattern in DOUBLE_SCRIPT_PATTERNS:
        if pattern.search(text):
            raise ValueError(f"direct repeated script in fragment: {text[:120]!r}")


def build_fragment_sequence(spec: ProfileSpec, seed: int) -> tuple[list[dict[str, object]], dict[str, int]]:
    rng = random.Random(seed)
    counts = exact_counts(spec.total_fragments, spec)
    pools: dict[str, list[str]] = {}
    for kind, count in counts.items():
        unique_count = max(1, min(count, int(round(count * spec.unique_ratio))))
        pool_rng = random.Random(seed + stable_offset(f"{spec.name}-{kind}-pool"))
        pools[kind] = []
        for index in range(unique_count):
            fragment = valid_fragment(kind, pool_rng, (stable_offset(kind) * 100_000) + index)
            validate_fragment_text(fragment)
            pools[kind].append(fragment)

    fragments: list[dict[str, object]] = []
    for kind, count in counts.items():
        for _ in range(count):
            fragments.append({"kind": kind, "text": rng.choice(pools[kind]), "valid": True})
    rng.shuffle(fragments)

    invalid_count = int(round(spec.total_fragments * spec.invalid_ratio))
    if invalid_count:
        invalid_positions = rng.sample(range(len(fragments)), invalid_count)
        for offset, position in enumerate(invalid_positions):
            kind = str(fragments[position]["kind"])
            fragment = invalid_fragment(kind, stable_offset(spec.name) + offset)
            validate_fragment_text(fragment)
            fragments[position] = {
                "kind": kind,
                "text": fragment,
                "valid": False,
            }

    return fragments, counts


def fragment_block(kind: str, text: str, uid: int) -> str:
    if kind == "inline":
        return f"The conserved quantity at sample {uid} is {text} in the chosen frame.\n\n"
    return f"{text}\n\n"


def write_corpus(path: Path, spec: ProfileSpec, fragments: list[dict[str, object]]) -> int:
    section = 0
    subsection = 0
    with path.open("w", encoding="utf-8") as handle:
        handle.write(f"#+title: OFLP Stress Corpus {spec.name}\n")
        handle.write("#+startup: overview\n")
        handle.write(
            f"#+begin_quote\nDeterministic synthetic stress corpus: {spec.name}\n#+end_quote\n\n"
        )
        for index, fragment in enumerate(fragments, start=1):
            if (index - 1) % spec.fragments_per_section == 0:
                section += 1
                subsection = 0
                handle.write(f"* Section {section}\n\n")
            if spec.fragments_per_subsection and (index - 1) % spec.fragments_per_subsection == 0:
                subsection += 1
                handle.write(f"** Cluster {section}.{subsection}\n\n")
            handle.write(fragment_block(str(fragment["kind"]), str(fragment["text"]), index))
    return section


def sha1_file(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def generate_profile(output_dir: Path, base_seed: int, spec: ProfileSpec) -> dict[str, object]:
    fragments, counts = build_fragment_sequence(spec, base_seed + stable_offset(spec.name))
    path = output_dir / f"{spec.name}.org"
    headings = write_corpus(path, spec, fragments)
    invalid_count = sum(1 for fragment in fragments if not fragment["valid"])
    metadata = {
        "name": spec.name,
        "scenario": spec.scenario,
        "path": str(path),
        "seed": base_seed + stable_offset(spec.name),
        "total_fragments": len(fragments),
        "invalid_fragments": invalid_count,
        "expected_successful_fragments": len(fragments) - invalid_count,
        "distribution": counts,
        "headings": headings,
        "fragments_per_section": spec.fragments_per_section,
        "fragments_per_subsection": spec.fragments_per_subsection,
        "unique_ratio": spec.unique_ratio,
        "invalid_ratio": spec.invalid_ratio,
        "sha1": sha1_file(path),
        "size_bytes": path.stat().st_size,
    }
    return metadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        default="stress/generated",
        help="Directory where corpora and manifest will be written.",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=20260307,
        help="Base random seed for deterministic generation.",
    )
    parser.add_argument(
        "--profile",
        action="append",
        choices=sorted(PROFILES),
        help="Generate only the named profile. Can be repeated.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    selected = args.profile or list(PROFILES)
    manifest_profiles = {}
    for name in selected:
        metadata = generate_profile(output_dir, args.seed, PROFILES[name])
        manifest_profiles[name] = metadata
        print(
            f"generated {name}: {metadata['total_fragments']} fragments, "
            f"{metadata['size_bytes']} bytes"
        )

    manifest = {
        "version": 1,
        "base_seed": args.seed,
        "extra_preamble": COMMON_PREAMBLE,
        "profiles": manifest_profiles,
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    print(f"wrote {manifest_path}")


if __name__ == "__main__":
    main()
