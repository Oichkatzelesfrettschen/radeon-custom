#!/usr/bin/env python3
"""Harvest the R5xx Acceleration guide register set across document versions.

The five public revisions (v1.1 through v1.5) of the R5xx acceleration guide
carry overlapping register sections; a register's presence span and any
access/width drift across revisions is itself evidence (the v1.3 revision
introduces the CP chapter, and a row present only from v1.3 on documents a
later editorial layer, not earlier silicon).  One output row per register
name records the version span and any attribute drift.

Comparative-tier only: rows feed the registry comparative-vocabulary view
and never the master inventory census (the inventory already ingests
v1.3-v1.5 directly as PDF sources; this lane adds the v1.1/v1.2 horizon and
the cross-version delta signal).
"""

from __future__ import annotations

import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


sys.path.insert(0, str(repo_root() / "src/re/r300/scripts"))
from build_rs4xx_r300_register_opcode_atom_inventory import (  # noqa: E402
    parse_mmreg_line,
)

PDF_TEXT = Path("docs/external_sources/rs480_r300_registers_and_driver_sources/raw/pdf")
VERSIONS = ["v1.1", "v1.2", "v1.3", "v1.4", "v1.5"]
OUTPUT = Path("docs/r5xx_accel_version_delta_registers.tsv")
FIELDS = [
    "register",
    "offset_hex",
    "access",
    "width_bits",
    "first_version",
    "last_version",
    "versions_present",
    "attribute_drift",
]


def harvest_version(version: str) -> dict[str, tuple[str, str, str]]:
    path = repo_root() / PDF_TEXT / f"R5xx_Acceleration_{version}.txt"
    if not path.exists():
        raise SystemExit(f"missing R5xx acceleration text: {path}")
    registers: dict[str, tuple[str, str, str]] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parsed = parse_mmreg_line(line)
        if parsed is None:
            continue
        name, access, width, offset_text = parsed
        registers.setdefault(name, (offset_text.lower().replace(" ", ""), access, width))
    return registers


def main() -> int:
    per_version = {version: harvest_version(version) for version in VERSIONS}
    all_names = sorted(set().union(*(set(regs) for regs in per_version.values())))
    rows: list[list[str]] = []
    for name in all_names:
        present = [version for version in VERSIONS if name in per_version[version]]
        attributes = {per_version[version][name] for version in present}
        first = per_version[present[0]][name]
        if len(attributes) == 1:
            drift = "."
        else:
            drift = ";".join(
                f"{version}={'/'.join(per_version[version][name])}" for version in present
            )
        rows.append(
            [
                name,
                first[0],
                first[1],
                first[2],
                present[0],
                present[-1],
                ";".join(present),
                drift,
            ]
        )
    out = repo_root() / OUTPUT
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as handle:
        handle.write("\t".join(FIELDS) + "\n")
        for row in rows:
            handle.write("\t".join(row) + "\n")
    spans = {}
    for row in rows:
        spans[row[6]] = spans.get(row[6], 0) + 1
    print(f"registers={len(rows)} drifted={sum(1 for row in rows if row[7] != '.')}")
    for span, count in sorted(spans.items(), key=lambda item: -item[1])[:6]:
        print(f"  {count:4d}  {span}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
