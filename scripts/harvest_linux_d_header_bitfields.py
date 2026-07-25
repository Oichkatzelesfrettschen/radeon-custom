#!/usr/bin/env python3
"""Harvest register bitfields from the kernel per-family *d.h headers.

The radeon kernel driver carries a second register-decode geometry alongside
radeon_reg.h: per-family headers (r300d.h, rs400d.h in the pinned corpus)
that define every register as `R_OFFSET_NAME` and every field as a
`S_OFFSET_FIELD(x) (((x) & MASK) << SHIFT)` setter macro.  The radeon_reg.h
harvesters cannot see this geometry, which is why RBBM_STATUS carried only
two decoded fields while r300d.h documents twenty-two, including the
per-block engine-busy bits.  The harvest is mechanical: the offset embeds in
the macro name, the start bit is the shift, the width is the contiguous mask
length, and the register identity comes from the R_ macro at the same
offset.  A non-contiguous mask fails loudly rather than guessing.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CORPUS_LINUX = REPO_ROOT / (
    "docs/external_sources/rs480_r300_registers_and_driver_sources/raw/source/linux"
)
SOURCES = ("r300d.h", "rs400d.h")
OUTPUT = REPO_ROOT / "docs/linux_d_header_harvested_bitfields.tsv"
HEADER = ["register", "offset", "field", "start_bit", "stop_bit", "mask", "source"]

REGISTER_RE = re.compile(r"^#define R_([0-9A-F]{6})_(\w+)\s+0x([0-9A-Fa-f]+)")
FIELD_RE = re.compile(
    r"^#define\s+S_([0-9A-F]{6})_(\w+)\(x\)\s+\(\(\(x\)\s*&\s*0x([0-9A-Fa-f]+)\)\s*<<\s*(\d+)\)"
)


def contiguous_width(mask: int) -> int:
    """Bit width of a contiguous low-aligned mask; 0 when not contiguous."""
    if mask == 0:
        return 0
    width = mask.bit_length()
    return width if mask == (1 << width) - 1 else 0


def harvest() -> list[list[str]]:
    rows: list[list[str]] = []
    seen: set[tuple[str, str, str]] = set()
    for fname in SOURCES:
        path = CORPUS_LINUX / fname
        if not path.exists():
            raise SystemExit(f"missing pinned corpus header: {path}")
        register_names: dict[int, str] = {}
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            reg = REGISTER_RE.match(line)
            if reg:
                offset = int(reg.group(1), 16)
                if int(reg.group(3), 16) != offset:
                    raise SystemExit(
                        f"{fname}: register macro offset disagrees with its "
                        f"value: {line.strip()}"
                    )
                register_names[offset] = reg.group(2)
        for line in text.splitlines():
            field = FIELD_RE.match(line)
            if not field:
                continue
            offset = int(field.group(1), 16)
            mask = int(field.group(3), 16)
            shift = int(field.group(4))
            width = contiguous_width(mask)
            if width == 0:
                raise SystemExit(
                    f"{fname}: non-contiguous field mask, refusing to guess: "
                    f"{line.strip()}"
                )
            register = register_names.get(offset)
            if register is None:
                raise SystemExit(
                    f"{fname}: field macro with no R_ register macro at the "
                    f"same offset: {line.strip()}"
                )
            key = (f"0x{offset:04x}", register, field.group(2))
            if key in seen:
                continue
            seen.add(key)
            rows.append(
                [
                    register,
                    f"0x{offset:04x}",
                    field.group(2),
                    str(shift),
                    str(shift + width - 1),
                    f"0x{mask << shift:08x}",
                    fname,
                ]
            )
    rows.sort(key=lambda r: (int(r[1], 16), int(r[3]), r[2]))
    return rows


def write_tsv(path: Path, rows: list[list[str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(HEADER)
        writer.writerows(rows)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    rows = harvest()
    if args.check:
        if not OUTPUT.exists():
            print(f"missing harvest output: {OUTPUT}", file=sys.stderr)
            return 1
        with tempfile.TemporaryDirectory() as tmp:
            candidate = Path(tmp) / OUTPUT.name
            write_tsv(candidate, rows)
            if OUTPUT.read_bytes() != candidate.read_bytes():
                print(f"stale harvest output: {OUTPUT}", file=sys.stderr)
                return 1
        print(f"check ok: {OUTPUT} rows={len(rows)}")
        return 0
    write_tsv(OUTPUT, rows)
    print(f"wrote {OUTPUT} rows={len(rows)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
