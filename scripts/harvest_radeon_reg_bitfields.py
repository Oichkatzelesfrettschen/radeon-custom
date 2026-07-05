#!/usr/bin/env python3
"""Harvest self-validated register bitfields from the canonical radeon_reg.h.

The unified DKMS source tarball carries the upstream radeon DRM radeon_reg.h --
the authoritative, MIT-licensed Radeon register header (1000+ register offsets,
2300+ field/enum sub-defines, far richer than the radeontool subset).  It is
organized positionally: a register offset at column 0
(#define RADEON_<REG> 0x...) is followed by its bitfield and enum defines as
indented sub-defines (#       define RADEON_<FIELD> <expr>) until the next
column-0 define.

Copying those fields into a queryable form is transcription of authoritative
public data, not field discovery -- but only when the transcription cannot
mis-assign or mis-range a field.  radeon_reg.h is loose in two ways that a naive
harvest would get wrong, and both have been verified against the header:

1. Owner is positional, not by name prefix.  RADEON_GMC_BRUSH_DATATYPE_MASK is a
   field of RADEON_DP_GUI_MASTER_CNTL (0x146c); the field name carries the
   functional block (GMC_), not the register symbol.  The machine-checkable owner
   is the most recent column-0 0x-valued register define above the field.  A
   column-0 define whose value is NOT a 0x offset (a constant block such as
   ATI_DATATYPE_* or a *_SHIFT constant) breaks the nesting chain, so those
   constants never mis-own following fields.  Verified: zero orphan fields and no
   indented field follows a non-register column-0 define before the next register.

2. Field geometry comes from three forms that must be disambiguated, not one:
     * (allones << shift)            a clean contiguous field, e.g. (0xff << 16);
                                     single-bit (1 << n) is the width-1 case.
     * <FIELD>_MASK <bare-or-paren>  a field mask by naming contract, validated by
                                     reconstructing a contiguous run; a sibling
                                     <FIELD>_SHIFT cross-checks the low bit.
     * (enumval << shift)            an ENUM MEMBER, not a field, when enumval is
                                     not all-ones (e.g. (5 << 4)).  These attach to
                                     the field that covers that shift.  A (1 << 4)
                                     sitting inside a DATATYPE_MASK (0xf << 4) is an
                                     enum value 1, not a one-bit field -- emitting
                                     it as a [4:4] field would be fabrication.

A field is emitted to the clean list ONLY when its range is unambiguous: a _MASK
that reconstructs to a contiguous run, or an (allones << shift) at a shift that no
_MASK covers and that carries no competing enum value.  Everything else --
non-contiguous masks, _MASK/_SHIFT disagreement, compound expressions, and enum
values at a shift with no covering mask -- goes to the flagged list for manual
review, never emitted as a bit range.  Enum members are collected separately as
value annotations on their covering field.
"""

import argparse
import io
import os
import re
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TARBALL = os.path.join(HERE, os.pardir, "sources", "radeon-unified-0.3-source.tar.xz")
OUT_CLEAN = os.path.join(HERE, os.pardir, "docs", "radeon_reg_harvested_bitfields.tsv")
OUT_ENUM = os.path.join(HERE, os.pardir, "docs", "radeon_reg_harvested_enums.tsv")
OUT_FLAGGED = os.path.join(HERE, os.pardir, "docs", "radeon_reg_harvested_flagged.tsv")
OUT_SYNTH = os.path.join(HERE, os.pardir, "docs", "radeon_reg_harvested_synthesized_enumgroup.tsv")
OUT_RECON = os.path.join(
    HERE, os.pardir, "docs", "radeon_reg_harvested_shift_boundary_reconstructed.tsv"
)

RE_REG = re.compile(r"^#define\s+([A-Z_][A-Z0-9_]+)\s+(0x[0-9A-Fa-f]+)\b")
RE_COL0 = re.compile(r"^#define\s+([A-Z_][A-Z0-9_]+)\s+(.+)")
RE_FUNC_COL0 = re.compile(r"^#define\s+([A-Z_][A-Z0-9_]*)\([^)]*\)\s+(.+)")
RE_FIELD = re.compile(r"^#\s+define\s+([A-Z_][A-Z0-9_]+)\s+(.+?)\s*(?:/\*.*)?$")
RE_SHIFT = re.compile(r"^\(\s*(0x[0-9A-Fa-f]+|\d+)\s*<<\s*(\d+)\s*\)$")
RE_BARE = re.compile(r"^\(?\s*(0x[0-9A-Fa-f]+|\d+)\s*\)?[UuLl]*$")
PROVISIONAL_FIELD_RE = re.compile(r"^R500_INST_STAT_WE_[RGBA]$")
ASIC_PREFIXES = {
    "AVIVO",
    "R100",
    "R200",
    "R300",
    "R400",
    "R500",
    "R600",
    "RADEON",
    "RS400",
    "RS480",
    "RS482",
    "RS485",
    "RS600",
    "RS690",
    "RS740",
    "RV100",
    "RV200",
    "RV250",
    "RV280",
    "RV350",
    "RV380",
    "RV515",
    "RV530",
    "RV560",
    "RV570",
}


def is_register_offset(offset_text):
    """True when a column-0 hex define is in the MMIO/indirect register space."""
    return int(offset_text, 16) <= 0xFFFF


def read_reg_header(tarball):
    """Return radeon_reg.h text from the committed DKMS source tarball."""
    with tarfile.open(tarball, "r:xz") as tar:
        for member in tar.getmembers():
            if os.path.basename(member.name) == "radeon_reg.h":
                fh = tar.extractfile(member)
                return io.TextIOWrapper(fh, encoding="utf-8").read()
    raise SystemExit("radeon_reg.h not found in %s" % tarball)


def contiguous_range(mask):
    """Return (start, stop) if mask is one contiguous run of set bits, else None."""
    if mask == 0:
        return None
    start = (mask & -mask).bit_length() - 1  # lowest set bit
    stop = mask.bit_length() - 1  # highest set bit
    if ((1 << (stop - start + 1)) - 1) << start == mask:
        return start, stop
    return None


def is_allones(val):
    """True when val is a contiguous run of set bits anchored at bit 0 (a width)."""
    return val != 0 and val == (1 << val.bit_length()) - 1


def parse_shift(expr):
    """Parse (val << shift).  Return (val, shift) or None."""
    m = RE_SHIFT.match(expr)
    if not m:
        return None
    return int(m.group(1), 0), int(m.group(2))


def parse_bare(expr):
    """Parse a bare or parenthesized integer (optional U/L suffix).  Return int or None."""
    m = RE_BARE.match(expr)
    if not m:
        return None
    return int(m.group(1), 0)


def enum_group_field_name(members):
    """Return a real shared field prefix for enum members, or None."""
    names = [name for name, _val in members]
    token_lists = [name.split("_") for name in names]
    common_tokens = []
    for tokens in zip(*token_lists):
        if len(set(tokens)) != 1:
            break
        common_tokens.append(tokens[0])

    name_set = set(names)
    if "_".join(common_tokens) in name_set:
        common_tokens = common_tokens[:-1]

    if len(common_tokens) < 2:
        return None
    if all(token in ASIC_PREFIXES for token in common_tokens):
        return None

    field = "_".join(common_tokens)
    if not field or field in name_set:
        return None
    return field


def collect(text):
    """Positional pass: ordered registers and their indented field defines.

    A column-0 0x-valued define opens a register.  Any other column-0 define
    closes the current register (constant or enum block), so following indented
    defines are not mis-owned.
    """
    regs = {}  # name -> offset string
    order = []  # register names in file order
    fields = {}  # register name -> [(field_name, expr)]
    cur = []
    for line in text.splitlines():
        m = RE_REG.match(line)
        if m and is_register_offset(m.group(2)):
            cur = [m.group(1)]
            regs[cur[0]] = m.group(2)
            order.append(cur[0])
            fields.setdefault(cur[0], [])
            continue
        m = RE_FUNC_COL0.match(line)
        if m:
            helper_name, helper_expr = m.group(1), m.group(2)
            helper_owners = [reg for reg in order if reg.startswith(helper_name + "_")]
            if cur and cur[-1].startswith(helper_name + "_") and helper_name in helper_expr:
                cur = helper_owners
                continue  # register-array address helper, keep owner
            cur = []  # function-like constant/helper block
            continue
        if RE_COL0.match(line):
            cur = []  # constant / enum block breaks nesting
            continue
        m = RE_FIELD.match(line)
        if m and cur:
            for reg in cur:
                fields[reg].append((m.group(1), m.group(2).strip()))
    return regs, order, fields


def decode_register(reg, off, items, clean, enums, flagged, synthesized, reconstructed):
    """Decode one register's field defines into clean fields, enums, and flags."""
    raw_masks = {}  # base -> (start, stop) from a contiguous _MASK as written
    shifts = {}  # base -> shift value
    enum_shifts = set()  # shifts that carry a non-all-ones value (enum-bearing)

    # Pass 1: collect _MASK geometry (as written), _SHIFT positions, enum shifts.
    for name, expr in items:
        if PROVISIONAL_FIELD_RE.match(name):
            flagged.append((reg, off, name, expr, "source marks field order guessed"))
            continue
        if name.endswith("_MASK"):
            base = name[:-5]
            sh = parse_shift(expr)
            if sh is not None:
                rng = contiguous_range(sh[0] << sh[1])
            else:
                bare = parse_bare(expr)
                rng = contiguous_range(bare) if bare is not None else None
                if bare is None:
                    flagged.append((reg, off, name, expr, "_MASK non-bare non-shift"))
                    continue
            if rng:
                raw_masks[base] = rng
            else:
                flagged.append((reg, off, name, expr, "non-contiguous _MASK"))
            continue
        if name.endswith("_SHIFT"):
            base = name[:-6]
            val = parse_bare(expr)
            if val is not None:
                shifts[base] = val
            else:
                flagged.append((reg, off, name, expr, "_SHIFT non-integer"))
            continue
        sh = parse_shift(expr)
        if sh is not None and not is_allones(sh[0]):
            enum_shifts.add(sh[1])  # (enumval << shift), enumval not all-ones

    # Resolve _MASK + _SHIFT into placed fields.  radeon_reg.h carries two
    # conventions and base-name pairing makes the reading unambiguous:
    #   * in-place mask: (0xff << 16) [+ optional _SHIFT 16 that confirms bit 16].
    #   * bit-0-normalized mask + _SHIFT: MASK 0xff + SHIFT 8 => field at [8:15].
    # A bit-0 mask paired with a non-zero shift can only be the normalized form;
    # an in-place mask whose low bit disagrees with a non-zero shift is a genuine
    # conflict and is flagged rather than guessed.
    mask_fields = {}  # base -> (start, stop, mask)
    for base, (start, stop) in raw_masks.items():
        width = stop - start + 1
        shift = shifts.get(base)
        if shift is None or start == shift:
            placed = start
        elif start == 0 and shift > 0:
            placed = shift
        else:
            flagged.append(
                (
                    reg,
                    off,
                    base + "_MASK",
                    "_MASK/_SHIFT",
                    "mask low bit %d disagrees with _SHIFT %d" % (start, shift),
                )
            )
            continue
        if placed + width > 32:
            flagged.append(
                (
                    reg,
                    off,
                    base + "_MASK",
                    "_MASK/_SHIFT",
                    "placed field [%d:%d] exceeds 32 bits" % (placed, placed + width - 1),
                )
            )
            continue
        mask_fields[base] = (placed, placed + width - 1, ((1 << width) - 1) << placed)

    # A _SHIFT with no _MASK sibling fixes a field's low bit but not its width;
    # record it as an annotation rather than emitting an unfounded range.
    for base, shift in shifts.items():
        if base not in raw_masks:
            enums.append((reg, off, "(shift-only)", base + "_SHIFT", "shift %d" % shift))

    # Covered bits from placed _MASK fields.
    covered = {}
    for base, (start, stop, _mask) in mask_fields.items():
        for bit in range(start, stop + 1):
            covered[bit] = base

    # Enum members at an uncovered enum-bearing shift, grouped by shift, so a
    # field can be synthesized from the group when no _MASK names it (Pass 3).
    enum_groups = {}

    # Pass 2: remaining defines -> enum members or standalone single/contiguous fields.
    for name, expr in items:
        if PROVISIONAL_FIELD_RE.match(name):
            continue
        if name.endswith("_MASK") or name.endswith("_SHIFT"):
            continue
        sh = parse_shift(expr)
        if sh is None:
            bare = parse_bare(expr)
            if bare is None:
                flagged.append((reg, off, name, expr, "compound / non-shift expr"))
            # bare-value constant with no shift: a value define, recorded as enum w/o shift
            else:
                enums.append((reg, off, "(bare)", name, "0x%x" % bare))
            continue
        val, shift = sh
        if shift in covered:
            enums.append((reg, off, covered[shift], name, "0x%x" % val))
        elif shift in enum_shifts:
            # enum-bearing shift with no covering _MASK: width is not authoritative
            enums.append((reg, off, "(shift %d)" % shift, name, "0x%x" % val))
            enum_groups.setdefault(shift, []).append((name, val))
        elif is_allones(val):
            width = val.bit_length()
            start, stop = shift, shift + width - 1
            mask = val << shift
            clean.append((reg, off, name, start, stop, mask))
            for bit in range(start, stop + 1):
                covered[bit] = name
        else:
            enums.append((reg, off, "(shift %d)" % shift, name, "0x%x" % val))

    # Emit validated _MASK fields (strip the _MASK suffix for the field name).
    for base, (start, stop, mask) in mask_fields.items():
        clean.append((reg, off, base, start, stop, mask))

    # Pass 3: synthesize a field per enum-bearing shift that no _MASK covers and
    # no _SHIFT annotation fixes.  Headers like Mesa r300_reg.h define such fields
    # only as enum-member groups (e.g. R300_GA_POLY_MODE_FRONT_PTYPE_TRI (2 << 4)),
    # so the field's low bit is the shift but its width is INFERRED from the
    # maximum enum value -- a lower bound, since a wider reserved field reads the
    # same.  These go to the synthesized tier, never the clean fields, so the
    # no-false-clean invariant holds and a consumer can treat the width as
    # provisional.
    shift_only = {sh for base, sh in shifts.items() if base not in raw_masks}
    # Field names already taken in this register (clean fields + earlier
    # syntheses), so a common-prefix that collapses two distinct shifts to the
    # same name does not emit duplicate (register, field) rows -- the colliding
    # one is suffixed with its low bit (_B<start>), keeping each row uniquely
    # named with its geometry intact.
    used_names = {row[2] for row in clean if row[0] == reg and row[1] == off}
    for shift, members in sorted(enum_groups.items()):
        if shift in shift_only:
            continue  # a _SHIFT fixes the low bit, width still unknown
        if len(members) < 2:
            continue  # one value cannot name or size a field
        maxval = max(val for _name, val in members)
        width = max(1, maxval.bit_length())
        start, stop = shift, shift + width - 1
        if stop > 31:
            continue
        if any(bit in covered for bit in range(start, stop + 1)):
            continue  # would overlap a placed _MASK field
        field = enum_group_field_name(members)
        if not field:
            continue  # no clean common field name
        if field in used_names:
            field = "%s_B%d" % (field, start)
        used_names.add(field)
        mask = ((1 << width) - 1) << start
        synthesized.append((reg, off, field, start, stop, mask))
        for bit in range(start, stop + 1):
            covered[bit] = field

    # Do not emit exact fields from pure _SHIFT geometry.  A _SHIFT fixes only
    # the field low bit; the next shift is an upper bound, not an exact stop bit,
    # when reserved holes exist.  The exact-bitfield TSV must not encode those
    # bounds as masks.


def harvest(text):
    regs, order, fields = collect(text)
    clean, enums, flagged, synthesized, reconstructed = [], [], [], [], []
    for reg in order:
        decode_register(
            reg, regs[reg], fields[reg], clean, enums, flagged, synthesized, reconstructed
        )
    return regs, clean, enums, flagged, synthesized, reconstructed


def self_test():
    """Calibrate parsing and disambiguation on known-good and known-bad forms."""
    ok = True

    def check(label, got, want):
        nonlocal ok
        if got != want:
            print("SELF-TEST FAIL: %s -> %r, want %r" % (label, got, want), file=sys.stderr)
            ok = False

    check("(1 << 31) shift", parse_shift("(1 << 31)"), (1, 31))
    check("(0x7 << 4) shift", parse_shift("(0x7 << 4)"), (7, 4))
    check("(0x5 << 4) shift", parse_shift("(0x5 << 4)"), (5, 4))
    check("bare not shift", parse_shift("0x4"), None)
    check("is_allones 0x7", is_allones(0x7), True)
    check("is_allones 0x5", is_allones(0x5), False)
    check("is_allones 1", is_allones(1), True)
    check("contig 0xff<<16", contiguous_range(0xFF << 16), (16, 23))
    check("contig 0x101", contiguous_range(0x101), None)
    check("bare 0xfc", parse_bare("0xfc"), 0xFC)
    check("bare (0x7f)", parse_bare("(0x7f)"), 0x7F)
    check("bare 0x3L", parse_bare("0x00000003L"), 3)
    check("bare compound", parse_bare("RADEON_A | RADEON_B"), None)
    check(
        "enum default token parent field",
        enum_group_field_name(
            [
                ("RADEON_GMC_CONVERSION_TEMP", 1),
                ("RADEON_GMC_CONVERSION_TEMP_6500", 0),
                ("RADEON_GMC_CONVERSION_TEMP_9300", 1),
            ]
        ),
        "RADEON_GMC_CONVERSION",
    )
    check(
        "enum ASIC-only field declined",
        enum_group_field_name([("R300_GL_CLIP_SPACE_DEF", 0), ("R300_DX_CLIP_SPACE_DEF", 1)]),
        None,
    )

    # End-to-end: the DP_GUI_MASTER_CNTL cluster.  GMC_BRUSH_DATATYPE_MASK
    # (0x0f<<4) is a [4:7] field; (5<<4) is enum value 5, NOT a [4:4] field.
    sample = (
        "#define RADEON_DP_GUI_MASTER_CNTL           0x146c\n"
        "#       define RADEON_GMC_SRC_CLIPPING            (1    <<  2)\n"
        "#       define RADEON_GMC_BRUSH_DATATYPE_MASK     (0x0f <<  4)\n"
        "#       define RADEON_GMC_BRUSH_1X8_MONO_FG_LA    (5    <<  4)\n"
        "#       define RADEON_GMC_DST_DATATYPE_SHIFT      8\n"
        "#       define RADEON_GMC_DST_DATATYPE_MASK       (0x0f <<  8)\n"
        "#define RADEON_NPLL                         0x0009\n"
        "#       define RADEON_FB_DIV_SHIFT                8\n"
        "#       define RADEON_FB_DIV_MASK                 0xff\n"
        "#       define RADEON_HEX_SHIFT_SHIFT             0x00000010\n"
        "#define RADEON_OTHER                        0x1234\n"
        "#       define RADEON_OTHER_NONCONTIG_MASK        0x101\n"
        "#define RADEON_CP_PACKET3                         0xC0000000\n"
        "#       define RADEON_CP_PACKET_MASK              0xC0000000\n"
        "#define R300_US_ALU_RGB_INST_0                    0x48c0\n"
        "#define R300_US_ALU_RGB_INST_1                    0x48c4\n"
        "#define R300_US_ALU_RGB_INST_2                    0x48c8\n"
        "#define R300_US_ALU_RGB_INST(x)                   (R300_US_ALU_RGB_INST_0 + (x)*4)\n"
        "#       define R300_ALU_RGB_CLAMP                 (1 << 30)\n"
        "#define R300_US_TEX_OP(x)                         (R300_TX_FORMAT_X | (x))\n"
        "#       define R300_SRC_ADDR                      0x1f\n"
        "#define R500_US_CMN_INST_0                        0xb800\n"
        "/* Next four are guessed, documentation doesn't mention order. */\n"
        "#       define R500_INST_STAT_WE_R                (1 << 28)\n"
        # Enum-group register with no _MASK: Mesa-style FRONT/BACK_PTYPE groups
        # plus a one-bit DUAL.  FRONT/BACK get synthesized [4:5]/[7:8]; DUAL is a
        # clean one-bit field; neither PTYPE field appears in clean.
        "#define R300_GA_POLY_MODE                         0x4288\n"
        "#       define R300_GA_POLY_MODE_DUAL              (1 << 0)\n"
        "#       define R300_GA_POLY_MODE_FRONT_PTYPE_POINT (0 << 4)\n"
        "#       define R300_GA_POLY_MODE_FRONT_PTYPE_LINE  (1 << 4)\n"
        "#       define R300_GA_POLY_MODE_FRONT_PTYPE_TRI   (2 << 4)\n"
        "#       define R300_GA_POLY_MODE_BACK_PTYPE_POINT  (0 << 7)\n"
        "#       define R300_GA_POLY_MODE_BACK_PTYPE_LINE   (1 << 7)\n"
        "#       define R300_GA_POLY_MODE_BACK_PTYPE_TRI    (2 << 7)\n"
        "#define R300_VAP_CNTL                              0x2080\n"
        "#       define R300_GL_CLIP_SPACE_DEF             (0 << 22)\n"
        "#       define R300_DX_CLIP_SPACE_DEF             (1 << 22)\n"
        # Pure-geometry shift-only register: two _SHIFT macros, no _MASK, no
        # enum members.  The shifts are retained as annotations, but no exact
        # bitfield is emitted because the header does not define field widths.
        "#define RADEON_RE_WIDTH_HEIGHT                     0x1c44\n"
        "#       define RADEON_RE_WIDTH_SHIFT              0\n"
        "#       define RADEON_RE_HEIGHT_SHIFT             16\n"
    )
    _regs, clean, enums, flagged, synth, recon = harvest(sample)
    cfields = {f[2]: (f[3], f[4]) for f in clean}
    sfields = {f[2]: (f[3], f[4]) for f in synth}
    rfields = {f[2]: (f[3], f[4]) for f in recon}
    check("GMC_SRC_CLIPPING [2:2]", cfields.get("RADEON_GMC_SRC_CLIPPING"), (2, 2))
    check("GMC_BRUSH_DATATYPE [4:7]", cfields.get("RADEON_GMC_BRUSH_DATATYPE"), (4, 7))
    check("GMC_DST_DATATYPE [8:11]", cfields.get("RADEON_GMC_DST_DATATYPE"), (8, 11))
    check("enum 5<<4 not a field", "RADEON_GMC_BRUSH_1X8_MONO_FG_LA" in cfields, False)
    check(
        "enum 5<<4 collected", any(e[3] == "RADEON_GMC_BRUSH_1X8_MONO_FG_LA" for e in enums), True
    )
    # normalized mask 0xff + SHIFT 8 -> field at [8:15], not in-place [0:7]
    check("normalized FB_DIV [8:15]", cfields.get("RADEON_FB_DIV"), (8, 15))
    # hex-form _SHIFT with no _MASK -> shift-only annotation, parsed (0x10 = 16)
    check(
        "hex shift-only parsed",
        any(e[3] == "RADEON_HEX_SHIFT_SHIFT" and e[4] == "shift 16" for e in enums),
        True,
    )
    check("noncontig flagged", any("non-contiguous" in f[4] for f in flagged), True)
    check("packet word not a register", "RADEON_CP_PACKET3" in _regs, False)
    check(
        "address-helper macro preserves register ownership",
        cfields.get("R300_ALU_RGB_CLAMP"),
        (30, 30),
    )
    check(
        "address-helper macro fans out to indexed registers",
        sum(1 for f in clean if f[2] == "R300_ALU_RGB_CLAMP"),
        3,
    )
    check("non-address function-like define breaks nesting", "R300_SRC_ADDR" in cfields, False)
    check("guessed field not clean", "R500_INST_STAT_WE_R" in cfields, False)
    check(
        "guessed field flagged",
        any(f[2] == "R500_INST_STAT_WE_R" and "guessed" in f[4] for f in flagged),
        True,
    )
    # Enum-group synthesis: FRONT/BACK_PTYPE inferred from enum-max width, DUAL
    # stays a clean one-bit field, and the PTYPE names never leak into clean.
    check("GA_POLY_MODE_DUAL clean [0:0]", cfields.get("R300_GA_POLY_MODE_DUAL"), (0, 0))
    check("FRONT_PTYPE synthesized [4:5]", sfields.get("R300_GA_POLY_MODE_FRONT_PTYPE"), (4, 5))
    check("BACK_PTYPE synthesized [7:8]", sfields.get("R300_GA_POLY_MODE_BACK_PTYPE"), (7, 8))
    check("RE_WIDTH shift-only not reconstructed", "RADEON_RE_WIDTH" in rfields, False)
    check("RE_HEIGHT shift-only not reconstructed", "RADEON_RE_HEIGHT" in rfields, False)
    check(
        "RE_WIDTH shift annotation retained",
        any(e[3] == "RADEON_RE_WIDTH_SHIFT" and e[4] == "shift 0" for e in enums),
        True,
    )
    check(
        "RE_HEIGHT shift annotation retained",
        any(e[3] == "RADEON_RE_HEIGHT_SHIFT" and e[4] == "shift 16" for e in enums),
        True,
    )
    check("RE_WIDTH boundary not in clean", "RADEON_RE_WIDTH" in cfields, False)
    check("synthesized PTYPE not in clean", "R300_GA_POLY_MODE_FRONT_PTYPE" in cfields, False)
    check("ASIC-only enum prefix not synthesized", "R300" in sfields, False)
    check(
        "clip-space enum retained",
        any(e[0] == "R300_VAP_CNTL" and e[3] == "R300_GL_CLIP_SPACE_DEF" for e in enums),
        True,
    )
    return ok


def write_tsv(header, rows):
    lines = ["\t".join(header)]
    lines.extend("\t".join(r) for r in rows)
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--tarball", default=DEFAULT_TARBALL)
    ap.add_argument(
        "--header",
        help="harvest a raw radeon_reg.h file instead of the DKMS tarball "
        "(e.g. the X.Org DDX superset for cross-source diffing)",
    )
    ap.add_argument(
        "--stdout",
        action="store_true",
        help="emit the clean bitfield TSV to stdout only; do not write "
        "or compare the repository docs/ TSVs",
    )
    ap.add_argument(
        "--out",
        help="write the clean bitfield TSV to this path only (for "
        "harvesting an alternate header into its own committed "
        "TSV); --check compares this path instead of the defaults",
    )
    ap.add_argument(
        "--source-label",
        default="radeon_reg.h",
        help="value for the source column (name the harvested header)",
    )
    ap.add_argument(
        "--check", action="store_true", help="verify on-disk outputs match a fresh harvest"
    )
    args = ap.parse_args()

    if not self_test():
        raise SystemExit("self-test failed; refusing to emit")

    if args.header:
        with open(args.header, encoding="utf-8") as fh:
            text = fh.read()
    else:
        text = read_reg_header(args.tarball)
    regs, clean, enums, flagged, synthesized, reconstructed = harvest(text)

    clean_rows = [
        [reg, off, field, str(start), str(stop), "0x%08x" % mask, args.source_label]
        for reg, off, field, start, stop, mask in sorted(clean, key=lambda r: (int(r[1], 16), r[3]))
    ]
    clean_body = write_tsv(
        ["register", "offset", "field", "start_bit", "stop_bit", "mask", "source"], clean_rows
    )

    # Shift-boundary reconstructed fields carry an exact width for every field
    # but the top one (the boundary pins it) and a register-width upper bound
    # for the top field; the basis is named in the source column.
    recon_label = "%s (shift-boundary reconstructed; top field width<=register)" % args.source_label
    recon_rows = [
        [reg, off, field, str(start), str(stop), "0x%08x" % mask, recon_label]
        for reg, off, field, start, stop, mask in sorted(
            reconstructed, key=lambda r: (int(r[1], 16), r[3])
        )
    ]
    recon_body = write_tsv(
        ["register", "offset", "field", "start_bit", "stop_bit", "mask", "source"], recon_rows
    )

    # Synthesized enum-group fields carry a provisional (lower-bound) width, so
    # they stay in their own TSV with the basis named in the source column.
    synth_label = "%s (enum-group synthesized; width<=enum-max)" % args.source_label
    synth_rows = [
        [reg, off, field, str(start), str(stop), "0x%08x" % mask, synth_label]
        for reg, off, field, start, stop, mask in sorted(
            synthesized, key=lambda r: (int(r[1], 16), r[3])
        )
    ]
    synth_body = write_tsv(
        ["register", "offset", "field", "start_bit", "stop_bit", "mask", "source"], synth_rows
    )

    enum_rows = [
        [reg, off, field, name, val]
        for reg, off, field, name, val in sorted(enums, key=lambda r: (int(r[1], 16), r[2], r[3]))
    ]
    enum_body = write_tsv(["register", "offset", "field", "enum_name", "value"], enum_rows)

    flagged_rows = [
        [reg, off, field, expr, reason]
        for reg, off, field, expr, reason in sorted(flagged, key=lambda r: (int(r[1], 16), r[2]))
    ]
    flagged_body = write_tsv(["register", "offset", "field", "expr", "reason"], flagged_rows)

    if args.stdout:
        sys.stdout.write(clean_body)
        return

    if args.out:
        synth_out = re.sub(r"\.tsv$", "_synthesized_enumgroup.tsv", args.out)
        recon_out = re.sub(r"\.tsv$", "_shift_boundary_reconstructed.tsv", args.out)
        out_pairs = ((args.out, clean_body), (synth_out, synth_body), (recon_out, recon_body))
        if args.check:
            for path, body in out_pairs:
                existing = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
                if existing != body:
                    raise SystemExit("HARVEST DRIFT: %s differs from fresh harvest" % path)
            print(
                "%s up to date (%d clean, %d synthesized)"
                % (args.out, len(clean), len(synthesized))
            )
            return
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        for path, body in out_pairs:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
        print(
            "%d clean + %d synthesized self-validated bitfields -> %s (+ sibling)"
            % (len(clean), len(synthesized), args.out)
        )
        return

    outputs = (
        (OUT_CLEAN, clean_body),
        (OUT_ENUM, enum_body),
        (OUT_FLAGGED, flagged_body),
        (OUT_SYNTH, synth_body),
        (OUT_RECON, recon_body),
    )

    if args.check:
        for path, body in outputs:
            existing = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if existing != body:
                raise SystemExit("HARVEST DRIFT: %s differs from fresh harvest" % path)
        print("harvest outputs up to date")
        return

    os.makedirs(os.path.dirname(OUT_CLEAN), exist_ok=True)
    for path, body in outputs:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)

    print("registers in radeon_reg.h          : %d" % len(regs))
    print(
        "clean self-validated bitfields     : %d (-> %s)"
        % (len(clean), os.path.basename(OUT_CLEAN))
    )
    print(
        "enum value members                 : %d (-> %s)" % (len(enums), os.path.basename(OUT_ENUM))
    )
    print(
        "flagged for manual review          : %d (-> %s)"
        % (len(flagged), os.path.basename(OUT_FLAGGED))
    )
    print(
        "synthesized enum-group fields      : %d (-> %s)"
        % (len(synthesized), os.path.basename(OUT_SYNTH))
    )


if __name__ == "__main__":
    main()
