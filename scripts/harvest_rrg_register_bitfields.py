#!/usr/bin/env python3
"""Harvest register, bitfield, and enum rows from an AMD RRG pdftotext file.

The o-revision Register Reference Guides (RS690 3.00o, RV630 1.01o, M76
1.01o, M56 RRG-216M56-03oOEM) share one layout: a register header line
naming the register, its access, its width, and one or more space-qualified
locators, followed by a Field Name / Bits / Default table whose description
column may carry value=meaning enum lines.  Two header grammars exist:

  NB_MC_INDEX - RW - 32 bits - nbconfig:0xE8
  DEVICE_ID - R - 16 bits - [gcconfig:0x2] [MMReg:0x5002]

The locator space token is the document's own address-space authority
(nbconfig, NBMCIND, CLKIND, MMReg, VGA_IO, ...); a multi-locator header is a
dual-aperture register and emits one register row per locator.

Every row is comparative-tier evidence for the RS480-class inventory: these
documents describe later silicon, so harvest output feeds only the
comparative-vocabulary registry view and must never enter the master
inventory's register census (see RS482_RS485_LATER_RRG_ARCHAEOLOGY_MAP.md).
Field rows that fail the clean grammar are quarantined to the flagged TSV,
never repair-guessed.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HEADER_BARE_RE = re.compile(
    r"^\s*(?P<name>[A-Za-z][A-Za-z0-9_]*)\s+-\s+(?P<access>RW|R/W|RO|WO|R|W)"
    r"(?:\s*\([^)]*\))?\s+-\s+(?P<width>\d+)\s+bits?\s+-\s+"
    r"(?P<locators>[A-Za-z][A-Za-z0-9_]*\s*\\?:\s*0x[0-9A-Fa-f]+)\s*$"
)
# Bracketed locator lists carry three extra shapes the bare grammar does not:
# a comma-joined space list sharing one offset ([IOReg,MMReg:0x10]), a
# trailing per-locator access qualifier after the closing bracket
# ([MMReg:0x504C]:R, emitted on that locator), and
# wrapping across physical lines (joined before matching).
HEADER_BRACKET_RE = re.compile(
    r"^\s*(?P<name>[A-Za-z][A-Za-z0-9_]*)\s+-\s+(?P<access>RW|R/W|RO|WO|R|W)"
    r"(?:\s*\([^)]*\))?\s+-\s+(?P<width>\d+)\s+bits?\s+-\s+"
    r"(?P<locators>(\[[A-Za-z][A-Za-z0-9_, ]*\s*\\?:\s*0x[0-9A-Fa-f]+\]\s*"
    r"(?::\s*(?:RW|R/W|RO|WO|R|W)\s*)?)+)$"
)
# A bracket may carry several space tokens sharing one offset, joined by
# commas ([IOReg,MMReg:0x10]) or by spaces (the pcieConfigDev2..Dev10
# multi-function chapter).
LOCATOR_RE = re.compile(r"([A-Za-z][A-Za-z0-9_, ]*?)\s*\\?:\s*(0x[0-9A-Fa-f]+)")
BRACKET_LOCATOR_RE = re.compile(
    r"\[([A-Za-z][A-Za-z0-9_, ]*?)\s*\\?:\s*(0x[0-9A-Fa-f]+)\]\s*"
    r"(?::\s*(RW|R/W|RO|WO|R|W)\s*)?"
)
# A header-shaped line that fails both full grammars must poison the current
# register, not inherit it: a missed header would otherwise donate its whole
# field table to the previous register.
HEADER_LOOSE_RE = re.compile(
    r"^\s*[A-Za-z][A-Za-z0-9_]*\s+-\s+(?:RW|R/W|RO|WO|R|W)\b.*\bbits?\b"
)
# A wrapped header's continuation line consists solely of bracketed locators
# (with optional trailing access qualifiers).
HEADER_CONTINUATION_RE = re.compile(
    r"^\s*(\[[A-Za-z][A-Za-z0-9_,]*\s*\\?:\s*0x[0-9A-Fa-f]+\]\s*"
    r"(?::\s*(?:RW|R/W|RO|WO|R|W)\s*)?)+$"
)
FIELD_TABLE_HEADER_RE = re.compile(r"^\s*Field Name\s+Bits\s+Default")
# A field name may carry a short parenthesized access qualifier
# (IO_ACCESS_EN (R)  0  0x0); the qualifier is consumed, not emitted.
FIELD_ROW_RE = re.compile(
    r"^\s{1,}(?P<field>[A-Za-z_][A-Za-z0-9_]*)\s*(?:\([A-Za-z/ ]{1,8}\))?\s+"
    r"(?P<bits>\d+(?::\d+)?)\s+"
    r"(?P<default>0x[0-9A-Fa-f]+|\d+|[Nn]one)(?:\s+(?P<description>\S.*))?$"
)
ENUM_VALUE_RE = r"(?:0x[0-9A-Fa-f]+|[01]+b|\d+)"
ENUM_LINE_RE = re.compile(
    rf"^\s+(?P<value>{ENUM_VALUE_RE})\s*=\s*(?P<meaning>\S.*?)\s*$"
)
INLINE_ENUM_RE = re.compile(
    rf"^(?P<value>{ENUM_VALUE_RE})\s*=\s*(?P<meaning>\S.*?)\s*$"
)
PAGE_NOISE_RE = re.compile(
    r"(Register Reference (Manual|Guide)|Advanced Micro Devices|Proprietary"
    r"|^\s*\d+-\d+\s*$|^\s*Page \d+|^\s*\x0c)"
)

REGISTER_FIELDS = ["doc", "space", "offset_hex", "register", "access", "width_bits"]
BITFIELD_FIELDS = [
    "doc",
    "space",
    "offset_hex",
    "register",
    "field",
    "start_bit",
    "stop_bit",
    "default_hex",
]
ENUM_FIELDS = ["doc", "space", "offset_hex", "register", "field", "value", "meaning"]
FLAGGED_FIELDS = ["doc", "line", "register", "reason", "text"]


def repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


def normalize_access(access: str) -> str:
    return access.upper().replace("R/W", "RW")


def parse_header(line: str) -> tuple[str, str, str, list[tuple[str, str, str]]] | None:
    match = HEADER_BARE_RE.match(line) or HEADER_BRACKET_RE.match(line)
    if not match:
        return None
    locators: list[tuple[str, str, str]] = []
    header_access = normalize_access(match.group("access"))
    locators_text = match.group("locators")
    if locators_text.lstrip().startswith("["):
        locator_matches = BRACKET_LOCATOR_RE.findall(locators_text)
        for spaces_text, offset, locator_access in locator_matches:
            access = normalize_access(locator_access or header_access)
            for space in re.split(r"[,\s]+", spaces_text):
                if space:
                    locators.append((space, offset, access))
    else:
        for spaces_text, offset in LOCATOR_RE.findall(locators_text):
            for space in re.split(r"[,\s]+", spaces_text):
                if space:
                    locators.append((space, offset, header_access))
    if not locators:
        return None
    return match.group("name"), header_access, match.group("width"), locators


def join_wrapped_headers(lines: list[str]) -> list[tuple[int, str]]:
    """Join a header line with its wrapped locator continuation lines.

    Long locator lists wrap across physical lines (the pcieConfigDev2..Dev10
    chapter); a continuation line consists solely of bracketed locators.
    Page-noise lines are removed here so a page break cannot split a header
    from its continuation.
    """
    numbered = [
        (line_number, line)
        for line_number, line in enumerate(lines, 1)
        if not PAGE_NOISE_RE.search(line)
    ]
    joined: list[tuple[int, str]] = []
    index = 0
    while index < len(numbered):
        line_number, line = numbered[index]
        if HEADER_LOOSE_RE.match(line):
            # Two wrap shapes: the list breaks between complete brackets
            # (continuation line is bracketed locators), or inside one
            # bracket (the line carries an unclosed '['; join until it
            # closes).
            while index + 1 < len(numbered) and not parse_header(line):
                next_line = numbered[index + 1][1]
                if line.count("[") > line.count("]") or HEADER_CONTINUATION_RE.match(next_line):
                    index += 1
                    line = line.rstrip() + " " + next_line.strip()
                else:
                    break
        joined.append((line_number, line))
        index += 1
    return joined


def deduped(rows: list[list[str]]) -> list[list[str]]:
    """Drop verbatim repeats: the documents reprint a register page in index
    sections, and a reprint is the same evidence, not more evidence."""
    seen: set[tuple[str, ...]] = set()
    unique: list[list[str]] = []
    for row in rows:
        key = tuple(row)
        if key not in seen:
            seen.add(key)
            unique.append(row)
    return unique


def harvest(doc: str, lines: list[str]):
    registers: list[list[str]] = []
    bitfields: list[list[str]] = []
    enums: list[list[str]] = []
    flagged: list[list[str]] = []
    current: tuple[str, str, str, list[tuple[str, str, str]]] | None = None
    in_field_table = False
    last_field = ""

    def emit_enum(value: str, meaning: str) -> None:
        name, _access, _width, locators = current
        for space, offset, _access in locators:
            enums.append([doc, space, offset.lower(), name, last_field, value, meaning])

    for line_number, line in join_wrapped_headers(lines):
        header = parse_header(line)
        if header:
            current = header
            in_field_table = False
            last_field = ""
            name, access, width, locators = header
            for space, offset, locator_access in locators:
                registers.append([doc, space, offset.lower(), name, locator_access, width])
            continue
        if HEADER_LOOSE_RE.match(line):
            # The fail-safe: a header-shaped line both grammars reject would
            # otherwise leave the previous register current and donate this
            # register's whole field table to it.
            flagged.append(
                [
                    doc,
                    str(line_number),
                    current[0] if current else ".",
                    "header_grammar",
                    line.strip(),
                ]
            )
            current = None
            in_field_table = False
            last_field = ""
            continue
        if current is None:
            continue
        if FIELD_TABLE_HEADER_RE.match(line):
            in_field_table = True
            continue
        if not in_field_table:
            continue
        if not line.strip():
            continue
        field_match = FIELD_ROW_RE.match(line)
        if field_match:
            bits = field_match.group("bits")
            if ":" in bits:
                stop_text, start_text = bits.split(":", 1)
                start_bit, stop_bit = int(start_text), int(stop_text)
            else:
                start_bit = stop_bit = int(bits)
            if start_bit > stop_bit:
                flagged.append(
                    [doc, str(line_number), current[0], "inverted_bit_range", line.strip()]
                )
                continue
            last_field = field_match.group("field")
            default = field_match.group("default")
            name, _access, _width, locators = current
            for space, offset, _access in locators:
                bitfields.append(
                    [
                        doc,
                        space,
                        offset.lower(),
                        name,
                        last_field,
                        str(start_bit),
                        str(stop_bit),
                        default,
                    ]
                )
            description = field_match.group("description") or ""
            inline = INLINE_ENUM_RE.match(description)
            if inline:
                emit_enum(inline.group("value"), inline.group("meaning"))
            continue
        enum_match = ENUM_LINE_RE.match(line)
        if enum_match and last_field:
            emit_enum(enum_match.group("value"), enum_match.group("meaning"))
            continue
        # A line whose first token is an identifier followed by a bit spec or
        # a parenthesized qualifier in column alignment, yet failing the full
        # field grammar, is harvest damage worth quarantining; a wrapped
        # prose sentence has single spaces.
        if (
            re.match(
                r"^\s{1,}[A-Za-z_][A-Za-z0-9_]*\s*(?:\([A-Za-z/ ]{1,8}\))?"
                r"\s{2,}\d+(?::\d+)?\s{2,}",
                line,
            )
            and not enum_match
        ):
            flagged.append([doc, str(line_number), current[0], "field_row_grammar", line.strip()])
    return deduped(registers), deduped(bitfields), deduped(enums), flagged


def write_tsv(path: Path, header: list[str], rows: list[list[str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        handle.write("\t".join(header) + "\n")
        for row in rows:
            handle.write("\t".join(row) + "\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="RRG pdftotext file")
    parser.add_argument("--doc", required=True, help="document id (rs690_rrg, m56_rrg, ...)")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("src/re/radeon/docs"),
        help="output directory for the harvest TSV triple",
    )
    args = parser.parse_args(argv)

    source = args.source if args.source.is_absolute() else repo_root() / args.source
    out_dir = args.out_dir if args.out_dir.is_absolute() else repo_root() / args.out_dir
    lines = source.read_text(encoding="utf-8", errors="replace").splitlines()
    registers, bitfields, enums, flagged = harvest(args.doc, lines)
    if not registers:
        raise SystemExit(f"no register headers parsed from {source}")
    write_tsv(out_dir / f"rrg_{args.doc}_harvested_registers.tsv", REGISTER_FIELDS, registers)
    write_tsv(out_dir / f"rrg_{args.doc}_harvested_bitfields.tsv", BITFIELD_FIELDS, bitfields)
    write_tsv(out_dir / f"rrg_{args.doc}_harvested_enums.tsv", ENUM_FIELDS, enums)
    write_tsv(out_dir / f"rrg_{args.doc}_harvested_flagged.tsv", FLAGGED_FIELDS, flagged)
    print(
        f"{args.doc}: registers={len(registers)} bitfields={len(bitfields)} "
        f"enums={len(enums)} flagged={len(flagged)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
