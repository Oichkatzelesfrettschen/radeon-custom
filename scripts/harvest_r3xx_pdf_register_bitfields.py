#!/usr/bin/env python3
"""Harvest self-validated register bitfields from the AMD R3xx 3D Register
Reference Guide text extraction.

The public corpus carries R3xx_3D_Registers.txt, the pdftotext extraction of
AMD's "Radeon R3xx 3D Register Reference Guide" (Revision 1.0, February 25,
2008) -- the authoritative vendor document for the R300-class 3D pipe that
RS480/RS482/RS485 implements.  Unlike the driver headers (kernel radeon_reg.h,
X.Org DDX, Mesa r300_reg.h), the PDF gives every field a bit range, a default,
a prose description, and per-register access mode (R/W vs W), so it can decode
registers the driver headers only name and name registers the drivers never
touch.

Copying those fields into a queryable form is transcription of authoritative
public data, not field discovery -- but only when the transcription cannot
mis-assign or mis-range a field.  The pdftotext output is loose in ways a
naive line parser would get wrong, and each has been verified against the
extraction:

1. Register headers use a middle-dot separated grammar
   (BLOCK:NAME <dot> [R/W] <dot> 32 bits <dot> Access: 8/16/32 <dot>
   MMReg:0xLO-0xHI) but the extraction damages a handful: a spaced range dash
   (RS_IP_[0-7] "0x4310 -0x432c"), a high offset wrapped to the next line
   (VAP_PVS_FLOW_CNTL_LOOP_INDEX_[0-15] "MMReg:0x2290-" / "0x22cc"), a
   missing close bracket (VAP_VTX_ST_CLR_[0-7_R), and dual-aperture rows
   listing two MMReg addresses (the VAP_VPORT_* legacy 0x1dxx alias next to
   the 0x20xx address).  Each damage class is repaired explicitly and the
   repair is recorded in the flagged TSV, never silently.

2. Array registers (TX_FILTER0_[0-15], US_ALU_RGB_INST_[0-63],
   VAP_VTX_ST_CLR_[0-7]_A) expand to per-instance rows.  The instance stride
   is reconstructed from the offset span and instance count and must divide
   exactly; a span that does not reconcile with the bracket count is flagged
   and not expanded.

3. Field rows are columnar (Field Name / Bits / Default / Description) but
   the columns are not fixed: a long field name can compress the separator
   to a single space (FORCE_COMPRESSED_STENCIL), a field name can wrap to
   the next line (the _VALUE continuation), description prose wraps to
   column 0, the field-table header can split across three damaged lines,
   and read-only status bits carry a dislodged "(Access: R)" annotation
   line.  A line is accepted as a field row only when the bits token is N or
   HI:LO and the default token is 0x-hex or "none"; everything else at column
   0 inside a field table is description continuation, and every such
   consumed line is counted so nothing is skipped silently.

A register's decode is emitted to the clean list ONLY when its fields are a
clean set: no duplicate field names and no overlapping bit ranges within the
32-bit word.  Violations flag the whole register for manual review.
POSSIBLE VALUES enumerations are collected separately as value annotations
on their field, gated on the literal "POSSIBLE VALUES:" marker so prose
dashes never fabricate an enum.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOURCE = os.path.join(
    HERE, os.pardir, os.pardir, os.pardir, os.pardir, "docs",
    "external_sources", "rs480_r300_registers_and_driver_sources", "raw", "pdf",
    "R3xx_3D_Registers.txt")
OUT_CLEAN = os.path.join(HERE, os.pardir, "docs",
                         "r3xx_pdf_harvested_bitfields.tsv")
OUT_ENUM = os.path.join(HERE, os.pardir, "docs",
                        "r3xx_pdf_harvested_enums.tsv")
OUT_FLAGGED = os.path.join(HERE, os.pardir, "docs",
                           "r3xx_pdf_harvested_flagged.tsv")
OUT_INDEX = os.path.join(HERE, os.pardir, "docs",
                         "r3xx_pdf_register_index.tsv")

SOURCE_TAG = "R3xx_3D_Registers.pdf"
# pdftotext renders the header separator as U+00B7 and the page footer
# copyright mark as U+00A9; both stay as escapes so this file is pure ASCII.
MIDDLE_DOT = "\u00b7"
COPYRIGHT_SIGN = "\u00a9"

RE_HEADER = re.compile(
    r"^([A-Z0-9]+):(\S+)\s*" + MIDDLE_DOT +
    r"\s*\[([RW/]+)\]\s*" + MIDDLE_DOT +
    r"\s*(\d+)\s*bits\s*" + MIDDLE_DOT +
    r"\s*Access:\s*([\d/]+)\s*" + MIDDLE_DOT +
    r"\s*MMReg:0x([0-9a-fA-F]+)"
    r"(?:\s*-\s*(?:0x([0-9a-fA-F]+))?)?"
    r"((?:\s*,\s*MMReg:0x[0-9a-fA-F]+)*)\s*$")
RE_HEADER_EXTRA_MMREG = re.compile(r"MMReg:0x([0-9a-fA-F]+)")
RE_ARRAY_NAME = re.compile(r"^(.*?)\[(\d+)-(\d+)\](.*)$")
# Repair form for the one extraction-damaged bracket: NAME_[0-7_R lost its ].
RE_ARRAY_NAME_REPAIR = re.compile(r"^(.*?)\[(\d+)-(\d+)(_[A-Z0-9_]*)$")
RE_FIELD = re.compile(
    r"^([A-Z][A-Za-z0-9_]*)\s+(\d+(?::\d+)?)\s+(0x[0-9A-Fa-f]+|none)"
    r"(?:\s+(.*))?$")
RE_NAME_WRAP = re.compile(r"^(_[A-Z0-9_]+)(?:\s+(.*))?$")
RE_FIELD_ACCESS = re.compile(r"^\(Access:\s*([RW/]+)\)\s*(.*)$")
RE_FIELD_TABLE_HEADER = re.compile(r"^Field Name\s+Bits\s+Default")
RE_ENUM_VALUE = re.compile(r"^\s+(\d+)\s*-\s*(.*)$")
RE_POSSIBLE_VALUES = re.compile(r"^\s*POSSIBLE VALUES:\s*$")
RE_BARE_OFFSET = re.compile(r"^0x([0-9a-fA-F]+)\s*$")
RE_JUNK = re.compile(
    r"^\s*(" + COPYRIGHT_SIGN + r" 2008 Advanced Micro Devices"
    r"|Proprietary\s+\d+\s*$"
    r"|Revision 1\.0\s+February 25, 2008)")

KNOWN_STRIDES = (4, 8, 16, 32)
POSSIBLE_VALUES_MARKER = "POSSIBLE VALUES:"
SPLIT_FIELD_TABLE_HEADER = ("Bit Defa", "Field Name Description", "s ult")

# The VAP array-of-structures block interleaves two register families in
# 3-dword groups: VTX_AOS_ATTR01 (one register describing arrays 0 and 1:
# COUNT0 6:0, STRIDE0 14:8, COUNT1 22:16, STRIDE1 30:24) followed by the two
# base addresses VTX_AOS_ADDR0 and VTX_AOS_ADDR1, then the next pair's group.
# Neither family has a uniform stride (ATTR steps 12, ADDR alternates +4/+8),
# and the ATTR bracket labels are two-digit pair names (01, 23, ... 1415),
# so both are expanded from this explicit layout instead of the generic
# bracket grammar.  Offsets validated against the header ranges
# 0x20c4-0x2118 (ATTR) and 0x20c8-0x2120 (ADDR).
INTERLEAVED_LAYOUTS = {
    "VAP_VTX_AOS_ATTR[01-1415]": [
        (f"VAP_VTX_AOS_ATTR{2 * k}{2 * k + 1}", 0x20C4 + 12 * k)
        for k in range(8)],
    "VAP_VTX_AOS_ADDR[0-15]": [
        (f"VAP_VTX_AOS_ADDR{i}", 0x20C8 + 12 * (i // 2) + 4 * (i % 2))
        for i in range(16)],
}


def clean_text(text):
    """One whitespace-collapsed line, safe to embed in a TSV cell."""
    return re.sub(r"\s+", " ", text).strip()


def clean_description(text):
    """One TSV-safe description cell; avoid trailing empty fields."""
    return clean_text(text) or "N/A"


class Register:
    def __init__(self, block, name, access, width_bits, access_width, offsets):
        self.block = block
        self.name = name
        self.access = access
        self.width_bits = width_bits
        self.access_width = access_width
        self.offsets = offsets          # expanded per-instance (name, offset)
        self.description = []
        self.fields = []                # [dict] in document order
        self.flags = []                 # (reason, detail)

    def current_field(self):
        return self.fields[-1] if self.fields else None


def split_possible_values_marker(text):
    """Split a field description at an inline POSSIBLE VALUES marker."""
    before, marker, after = text.partition(POSSIBLE_VALUES_MARKER)
    if not marker:
        return text.strip(), False
    pieces = [before.strip(), after.strip()]
    return " ".join(piece for piece in pieces if piece), True


def reserved_field_name(name, lo_bit, hi_bit):
    if name != "Reserved":
        return name
    if lo_bit == hi_bit:
        return f"RESERVED_{lo_bit}"
    return f"RESERVED_{hi_bit}_{lo_bit}"


def expand_array(raw_name, lo, hi, flags):
    """(instance_name, offset) list for a header, validating the stride.

    A scalar register yields itself.  An array name carries its instance
    range in brackets; the offset span must reconstruct an exact power-of-two
    stride or the register is flagged and kept un-expanded at the base
    offset.
    """
    if raw_name in INTERLEAVED_LAYOUTS:
        layout = INTERLEAVED_LAYOUTS[raw_name]
        if layout[0][1] != lo or (hi is not None and layout[-1][1] != hi):
            flags.append(("interleaved_layout_mismatch",
                          f"{raw_name}: header range disagrees with the"
                          f" explicit layout"))
            return raw_name, [(raw_name, lo)]
        flags.append(("interleaved_layout",
                      f"{raw_name}: expanded from the explicit 3-dword-group"
                      f" AOS layout"))
        return raw_name, list(layout)
    m = RE_ARRAY_NAME.match(raw_name)
    if not m and "[" in raw_name:
        m = RE_ARRAY_NAME_REPAIR.match(raw_name)
        if m:
            flags.append(("repaired_name",
                          f"missing ] reconstructed: {raw_name}"))
    if not m:
        return raw_name, [(raw_name, lo)]
    base, idx_lo, idx_hi, suffix = (
        m.group(1), int(m.group(2)), int(m.group(3)), m.group(4))
    count = idx_hi - idx_lo + 1
    display = f"{base}[{idx_lo}-{idx_hi}]{suffix}"
    if hi is None or count < 2:
        flags.append(("array_no_span",
                      f"{display}: no high offset to derive a stride"))
        return display, [(display, lo)]
    span = hi - lo
    if span % (count - 1) != 0 or span // (count - 1) not in KNOWN_STRIDES:
        flags.append(("array_bad_stride",
                      f"{display}: span 0x{span:x} over {count} instances"))
        return display, [(display, lo)]
    stride = span // (count - 1)
    return display, [(f"{base}{idx_lo + i}{suffix}", lo + i * stride)
                     for i in range(count)]


def parse(path):
    registers = []
    counters = {
        "header_lines": 0, "junk_lines": 0, "description_cont": 0,
        "field_desc_cont": 0, "enum_cont": 0, "preamble": 0,
        "blank": 0, "wrapped_hi_offset": 0, "split_field_headers": 0,
    }
    reg = None
    mode = "preamble"        # preamble | description | fields
    in_possible_values = False
    pending_hi_for = None    # register awaiting a wrapped high offset
    split_header_fragments = []

    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    for raw in lines:
        line = raw.lstrip("\f")
        if not line.strip():
            counters["blank"] += 1
            continue
        if RE_JUNK.match(line):
            counters["junk_lines"] += 1
            continue

        header = RE_HEADER.match(line)
        if header:
            counters["header_lines"] += 1
            block, raw_name, access, width, acc_modes = (
                header.group(1), header.group(2), header.group(3),
                int(header.group(4)), header.group(5))
            lo = int(header.group(6), 16)
            hi = int(header.group(7), 16) if header.group(7) else None
            extra = [int(x, 16) for x in
                     RE_HEADER_EXTRA_MMREG.findall(header.group(8) or "")]
            flags = []
            truncated_range = hi is None and header.group(0).rstrip().endswith("-")
            display, offsets = (raw_name, [(raw_name, lo)])
            if not truncated_range:
                display, offsets = expand_array(raw_name, lo, hi, flags)
            # Dual-aperture rows are scalar: same register at each address.
            if extra:
                offsets = [(raw_name, lo)] + [(raw_name, a) for a in extra]
                flags.append(("dual_aperture",
                              f"{raw_name}: " + ", ".join(
                                  f"0x{a:04x}" for a in [lo] + extra)))
            reg = Register(block, display, access, width, acc_modes, offsets)
            reg.flags.extend(flags)
            reg.raw_name, reg.range_lo = raw_name, lo
            registers.append(reg)
            mode = "description"
            in_possible_values = False
            pending_hi_for = (reg if truncated_range else None)
            split_header_fragments = []
            continue

        if pending_hi_for is not None:
            bare = RE_BARE_OFFSET.match(line)
            if bare:
                hi = int(bare.group(1), 16)
                counters["wrapped_hi_offset"] += 1
                flags = []
                display, offsets = expand_array(
                    pending_hi_for.raw_name, pending_hi_for.range_lo, hi,
                    flags)
                pending_hi_for.name = display
                pending_hi_for.offsets = offsets
                pending_hi_for.flags.extend(flags)
                pending_hi_for.flags.append(
                    ("wrapped_hi_offset",
                     f"high offset 0x{hi:04x} recovered from wrapped line"))
                pending_hi_for = None
                continue
            pending_hi_for = None

        if reg is None:
            counters["preamble"] += 1
            continue

        if RE_FIELD_TABLE_HEADER.match(line):
            mode = "fields"
            split_header_fragments = []
            continue

        if mode == "description":
            clean_line = clean_text(line)
            if split_header_fragments:
                candidate = split_header_fragments + [clean_line]
                if tuple(candidate) == SPLIT_FIELD_TABLE_HEADER:
                    mode = "fields"
                    counters["split_field_headers"] += 1
                    split_header_fragments = []
                    continue
                if SPLIT_FIELD_TABLE_HEADER[:len(candidate)] == tuple(candidate):
                    split_header_fragments = candidate
                    continue
                for fragment in split_header_fragments:
                    reg.description.append(fragment)
                    counters["description_cont"] += 1
                split_header_fragments = []
            if clean_line == SPLIT_FIELD_TABLE_HEADER[0]:
                split_header_fragments = [clean_line]
                continue
            text = line[len("DESCRIPTION:"):] if line.startswith(
                "DESCRIPTION:") else line
            reg.description.append(text.strip())
            counters["description_cont"] += 1
            continue

        # Field-table mode from here on.
        if RE_POSSIBLE_VALUES.match(line):
            in_possible_values = True
            continue

        if in_possible_values:
            enum = RE_ENUM_VALUE.match(line)
            if enum and reg.current_field() is not None:
                reg.current_field()["enums"].append(
                    [int(enum.group(1)), enum.group(2).strip()])
                continue
            if line[0] in " \t" and reg.current_field() is not None \
                    and reg.current_field()["enums"]:
                reg.current_field()["enums"][-1][1] += " " + line.strip()
                counters["enum_cont"] += 1
                continue
            in_possible_values = False

        field = RE_FIELD.match(line)
        if field:
            bits = field.group(2)
            if ":" in bits:
                hi_bit, lo_bit = (int(x) for x in bits.split(":"))
            else:
                hi_bit = lo_bit = int(bits)
            description, has_possible_values = split_possible_values_marker(
                field.group(4) or "")
            reg.fields.append({
                "name": reserved_field_name(field.group(1), lo_bit, hi_bit),
                "lo": lo_bit, "hi": hi_bit,
                "default": field.group(3),
                "access": "",
                "description": [description],
                "enums": [],
            })
            in_possible_values = has_possible_values
            continue

        wrap = RE_NAME_WRAP.match(line)
        if wrap and reg.current_field() is not None:
            reg.current_field()["name"] += wrap.group(1)
            if wrap.group(2):
                reg.current_field()["description"].append(wrap.group(2))
            reg.flags.append(("wrapped_field_name",
                              reg.current_field()["name"]))
            continue

        acc = RE_FIELD_ACCESS.match(line)
        if acc and reg.current_field() is not None:
            reg.current_field()["access"] = acc.group(1)
            if acc.group(2):
                description, has_possible_values = split_possible_values_marker(
                    acc.group(2))
                if description:
                    reg.current_field()["description"].append(description)
                in_possible_values = has_possible_values
            continue

        if reg.current_field() is not None:
            description, has_possible_values = split_possible_values_marker(
                line.strip())
            if description:
                reg.current_field()["description"].append(description)
            in_possible_values = has_possible_values
            counters["field_desc_cont"] += 1
        else:
            reg.description.append(line.strip())
            counters["description_cont"] += 1

    return registers, counters


def validate(reg):
    """A clean decode has unique field names and disjoint in-range bits."""
    problems = []
    seen = set()
    covered = set()
    for field in reg.fields:
        if field["hi"] < field["lo"]:
            problems.append(("reversed_bits",
                             f"{field['name']} {field['hi']}:{field['lo']}"))
        if field["hi"] >= reg.width_bits:
            problems.append(("bits_exceed_width",
                             f"{field['name']} hi={field['hi']}"))
        if field["name"] in seen:
            problems.append(("duplicate_field", field["name"]))
        seen.add(field["name"])
        bits = set(range(field["lo"], field["hi"] + 1))
        if covered & bits:
            problems.append(("overlapping_bits", field["name"]))
        covered |= bits
    return problems


def render_tsv(header, rows):
    lines = ["\t".join(header)]
    lines.extend("\t".join(row) for row in rows)
    return "\n".join(lines) + "\n"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def self_check(clean_rows, enum_rows, index_rows):
    fields = {(row[0], row[2]) for row in clean_rows}
    index = {row[0]: row for row in index_rows}

    for field in ("ALPHA_DITHER_MODE", "DC_FINISH", "ROP_ENABLE"):
        require(any(row[2] == field for row in enum_rows),
                f"missing inline POSSIBLE VALUES enum rows for {field}")

    require(("ZB_BW_CNTL", "HIZ_ENABLE") in fields,
            "split ZB_BW_CNTL header did not enter field-table mode")
    require(("ZB_BW_CNTL", "FORCE_COMPRESSED_STENCIL_VALUE") in fields,
            "split ZB_BW_CNTL wrapped field name was not preserved")
    require(("RB3D_CCTL", "RESERVED_10") in fields,
            "capitalized Reserved row for RB3D_CCTL bit 10 was not emitted")
    require(("TX_FILTER1_0", "RESERVED_13") in fields,
            "capitalized Reserved row for TX_FILTER1 bit 13 was not emitted")
    require(index["VAP_CLIP_CNTL"][5] == "32",
            "VAP_CLIP_CNTL access_width should be 32")
    require(index["ZB_BW_CNTL"][5] == "8/16/32",
            "ZB_BW_CNTL access_width should be 8/16/32")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", default=DEFAULT_SOURCE)
    parser.add_argument("--out-clean", default=OUT_CLEAN)
    parser.add_argument("--out-enums", default=OUT_ENUM)
    parser.add_argument("--out-flagged", default=OUT_FLAGGED)
    parser.add_argument("--out-index", default=OUT_INDEX)
    parser.add_argument("--check", action="store_true",
                        help="verify generated TSVs and parser invariants")
    args = parser.parse_args()

    registers, counters = parse(args.source)

    clean_rows, enum_rows, flagged_rows, index_rows = [], [], [], []
    dirty_registers = 0
    for reg in registers:
        problems = validate(reg)
        for reason, detail in reg.flags:
            flagged_rows.append((reg.name, f"0x{reg.offsets[0][1]:04x}",
                                 "(register)", reason, detail))
        reg_description = clean_description(" ".join(reg.description))
        for instance_name, offset in reg.offsets:
            index_rows.append((
                instance_name, f"0x{offset:04x}", reg.block, reg.access,
                str(reg.width_bits), reg.access_width, reg.name,
                reg_description))
        if problems:
            dirty_registers += 1
            for reason, detail in problems:
                flagged_rows.append((reg.name, f"0x{reg.offsets[0][1]:04x}",
                                     "(register)", reason, detail))
            continue
        for instance_name, offset in reg.offsets:
            for field in reg.fields:
                mask = ((1 << (field["hi"] - field["lo"] + 1)) - 1
                        ) << field["lo"]
                clean_rows.append((
                    instance_name, f"0x{offset:04x}", field["name"],
                    str(field["lo"]), str(field["hi"]), f"0x{mask:08x}",
                    SOURCE_TAG, reg.access, field["access"] or reg.access,
                    reg.access_width, field["default"], reg.block,
                    clean_description(" ".join(field["description"]))))
                for value, meaning in field["enums"]:
                    enum_rows.append((
                        instance_name, f"0x{offset:04x}", field["name"],
                        f"0x{value:x}", clean_text(meaning)))

    outputs = (
        (args.out_clean,
         ("register", "offset", "field", "start_bit", "stop_bit",
          "mask", "source", "access", "field_access", "access_width",
          "default", "block", "description"), clean_rows),
        (args.out_enums,
         ("register", "offset", "field", "value", "meaning"), enum_rows),
        (args.out_flagged,
         ("register", "offset", "field", "reason", "detail"),
         flagged_rows),
        (args.out_index,
         ("register", "offset", "block", "access", "width_bits",
          "access_width", "array_base", "description"), index_rows),
    )

    if args.check:
        try:
            self_check(clean_rows, enum_rows, index_rows)
        except AssertionError as error:
            print(f"FATAL: {error}", file=sys.stderr)
            return 1
        for path, header, rows in outputs:
            generated = render_tsv(header, rows)
            with open(path, encoding="utf-8") as handle:
                existing = handle.read()
            if existing != generated:
                print(f"FATAL: {path} is not regenerated", file=sys.stderr)
                return 1
    else:
        for path, header, rows in outputs:
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(render_tsv(header, rows))

    distinct_offsets = {offset for reg in registers
                        for _, offset in reg.offsets}
    print(f"headers parsed:        {counters['header_lines']}")
    print(f"registers (expanded):  {len(index_rows)}")
    print(f"distinct offsets:      {len(distinct_offsets)}")
    print(f"clean field rows:      {len(clean_rows)}")
    print(f"enum value rows:       {len(enum_rows)}")
    print(f"flagged rows:          {len(flagged_rows)}"
          f" (dirty registers: {dirty_registers})")
    print(f"line accounting:       {counters}")
    if counters["header_lines"] == 0:
        print("FATAL: no register headers parsed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
