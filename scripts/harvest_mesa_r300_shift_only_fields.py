#!/usr/bin/env python3
"""Reconstruct mesa r300 fields from SHIFT-only register defines.

The main radeon_reg harvest reconstructs a field's extent from a SHIFT/MASK
pair.  A few mesa r300_reg.h registers declare their fields as bare bit-index
defines with no matching `_MASK` (R300_GB_VAP_RASTER_VTX_FMT_1's eight
TEX_n_COMP_CNT shifts, R300_GB_PIPE_SELECT's pipe-id shifts plus PIPE_MASK,
MAX_PIPE and BAD_PIPES that drop the `_SHIFT` suffix), so the pair-based harvest
skips them and the register stays fieldless even though the driver documents it.

This harvest reconstructs those by shift boundary: a register's bare-integer
field defines, when they form a strictly increasing distinct sequence of bit
indices, are the field starts, and each field runs up to the bit below the next
start.  The last field has no following start: when every gap is identical the
regular array completes itself and the last field carries that same width
(TEX_7_COMP_CNT).  Otherwise its width is indeterminate unless a retained
primary source documents the final field as a single bit.  The one known case is
GB_PIPE_SELECT.CONFIG_PIPES, pinned at bit 18 by both mesa r300_reg.h and the
R5xx acceleration register text.
Enum-value defines of the `(N << S)` form are not bare integers and are ignored.

mesa is the r300 driver's own register documentation, so this is a clean
`reconstructed`-tier source, not a comparative guess.  The harvest emits only
for registers with no decode from another tier (excluding this tier keeps it
idempotent across regeneration), so it never overlaps an existing field.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
MESA_REG_H = REPO_ROOT / (
    "docs/external_sources/rs480_r300_registers_and_driver_sources/"
    "raw/source/mesa_r300/r300_reg.h"
)
REGISTERS = REPO_ROOT / "src/re/r300/registry/registers.tsv"
FIELDS = REPO_ROOT / "src/re/r300/registry/fields.tsv"
OUT = REPO_ROOT / "src/re/radeon/docs/radeon_reg_mesa_r300_shift_only_reconstructed.tsv"
HEADER = ["register", "offset", "field", "start_bit", "stop_bit", "mask", "source"]
SOURCE = "mesa_r300_reg.h (shift-only boundary reconstructed)"
DOCUMENTED_SINGLE_BIT_LAST_FIELDS = {
    ("R300_GB_PIPE_SELECT", "CONFIG_PIPES"): 18,
}

REG_RE = re.compile(r"^#\s*define\s+(\w+)\s+0x([0-9a-fA-F]{3,4})\b")
DEFINE_RE = re.compile(r"^#\s+define\s+(\w+)\s+(\d+)\b")


def field_of(symbol: str, register: str) -> str | None:
    """The field name of a `<register>_<field>[_SHIFT]` symbol, or None.

    mesa labels a field start either `<register>_<field>_SHIFT` or, sloppily,
    bare `<register>_<field>` (GB_PIPE_SELECT's MAX_PIPE/BAD_PIPES/CONFIG_PIPES
    drop the suffix); both are field-start positions when the value is a bare
    bit index, so the suffix is stripped if present and the rest is the name."""
    if not symbol.startswith(register):
        return None
    middle = symbol[len(register):].lstrip("_")
    if middle.endswith("_SHIFT"):
        middle = middle[: -len("_SHIFT")]
    return middle or None


def read(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def fielded_by_other_tiers() -> set[int]:
    return {
        int(row["offset_hex"], 16)
        for row in read(FIELDS)
        if row["tier"] != "reconstructed" or row["source"] != SOURCE
    }


def parse_mesa() -> dict[int, tuple[str, list[tuple[str, int]]]]:
    """offset -> (register name, [(field, shift), ...]) for SHIFT-only registers.

    A register is shift-only when its indented field defines carry `_SHIFT`
    starts and no `_MASK` extent; a `_MASK` for the register means the main
    pair-based harvest already covers it and this reconstruction stands down."""
    by_offset: dict[int, tuple[str, list[tuple[str, int]], bool]] = {}
    current: tuple[str, int] | None = None
    for line in MESA_REG_H.read_text(encoding="utf-8").splitlines():
        reg = REG_RE.match(line)
        if reg:
            current = (reg.group(1), int(reg.group(2), 16))
            by_offset.setdefault(current[1], (current[0], [], False))
            continue
        if current is None:
            continue
        symbol_match = re.match(r"^#\s+define\s+(\w+)\b", line)
        if not symbol_match:
            continue
        symbol = symbol_match.group(1)
        if not symbol.startswith(current[0]):
            continue
        if symbol.endswith("_MASK"):
            name, shifts, _ = by_offset[current[1]]
            by_offset[current[1]] = (name, shifts, True)
            continue
        field = field_of(symbol, current[0])
        define = DEFINE_RE.match(line)
        if field and define:
            name, shifts, has_mask = by_offset[current[1]]
            shifts.append((field, int(define.group(2))))
            by_offset[current[1]] = (name, shifts, has_mask)
    return {
        offset: (name, shifts)
        for offset, (name, shifts, has_mask) in by_offset.items()
        if shifts and not has_mask and len(shifts) >= 2
    }


def analyze() -> list[list[str]]:
    census = {int(r["offset_hex"], 16) for r in read(REGISTERS) if r["offset_hex"]}
    skip = fielded_by_other_tiers()
    rows: list[list[str]] = []
    for offset, (register, shifts) in parse_mesa().items():
        if offset not in census or offset in skip:
            continue
        ordered = sorted(shifts, key=lambda item: item[1])
        starts = [start for _, start in ordered]
        if len(set(starts)) != len(starts) or starts != sorted(starts):
            # Not a strictly-increasing distinct position sequence -- the values
            # are not field starts (an enum group or constants), so refuse it.
            continue
        gaps = {b - a for a, b in zip(starts, starts[1:])}
        uniform_last = next(iter(gaps)) if len(gaps) == 1 else None
        for index, (field, start) in enumerate(ordered):
            if index + 1 < len(ordered):
                stop = ordered[index + 1][1] - 1
            elif uniform_last is not None:
                # Every gap is identical, so the last field carries that same
                # width -- the regular array completes itself (TEX_7_COMP_CNT).
                stop = start + uniform_last - 1
            elif DOCUMENTED_SINGLE_BIT_LAST_FIELDS.get((register, field)) == start:
                # Mesa gives the bare field start, and the retained R5xx
                # acceleration text gives CONFIG_PIPES as bit 18.  Preserve the
                # documented single-bit tail without generalizing every
                # irregular final field to one bit.
                stop = start
            else:
                # Irregular spacing leaves the last field's width indeterminate;
                # extending it to the register top would fabricate the extent, so
                # it is dropped (the register keeps its bounded fields).
                continue
            if stop < start or stop > 31:
                continue
            mask = (((1 << (stop - start + 1)) - 1) << start) & 0xFFFFFFFF
            rows.append([register, f"0x{offset:04x}", field, str(start), str(stop),
                         f"0x{mask:08x}", SOURCE])
    rows.sort(key=lambda r: (int(r[1], 16), int(r[3])))
    return rows


def write_tsv(path: Path, rows: list[list[str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(HEADER)
        writer.writerows(rows)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    rows = analyze()
    if args.check:
        if not OUT.exists():
            print(f"missing generated file: {OUT}", file=sys.stderr)
            return 1
        with tempfile.TemporaryDirectory() as tmp:
            candidate = Path(tmp) / OUT.name
            write_tsv(candidate, rows)
            if OUT.read_bytes() != candidate.read_bytes():
                print(f"stale generated file: {OUT}", file=sys.stderr)
                return 1
        print(f"check ok: {OUT} rows={len(rows)}")
        return 0
    write_tsv(OUT, rows)
    print(f"wrote {OUT} rows={len(rows)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
