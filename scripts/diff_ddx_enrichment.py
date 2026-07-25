#!/usr/bin/env python3
"""Find RS480-accessible register fields the DKMS radeon_reg.h lacks but the
X.Org DDX radeon_reg.h decodes.

The kernel/DKMS radeon_reg.h names every RS480 legacy MMIO register but leaves
many of them offset-only (no bitfield decode).  The X.Org xf86-video-ati
radeon_reg.h is a machine-readable superset (ATI Technologies / VA Linux, MIT)
that decodes more of the R300-family 3D pipe, and RS480 is an R300-derived
IGP, so those R300_* field decodes apply.  Cross-referencing the two
authoritative headers recovers real, sourced field geometry without fabricating
anything and without OCR-ing AMD PDFs.

This tool harvests both headers with the same self-validating harvester, then
emits the fields that satisfy ALL of:
  * the owning register's offset is in the RS480 observed-clean corpus
    (confirmed to respond on silicon during the BAR0 readout burn-down),
  * the field is present in the DDX clean harvest and absent from the DKMS one,
  * the owning register's name does not carry a post-RS480 chip prefix
    (AVIVO_/R500_/R600_/.., which are later-silicon aliases of the same
    offset, not RS480 semantics).

Offset 0x0000 is excluded: the DDX places its bare value-0 enum constants
(ROP3_ZERO, CP_PACKET0, ...) at column 0, which the offset-keyed join would
otherwise mis-bucket as fields of RADEON_MM_INDEX.  MM_INDEX's only real field
(MM_APER bit 31) is already in the DKMS header.

Offset collisions (two register names at one offset, e.g. 0x01c0 = MPP_TB_CONFIG
and SEPROM_CNTL1) are recorded in the collision column so the consumer can note
which alias is live on RS480 from the observed value.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import harvest_radeon_reg_bitfields as hv      # noqa: E402

DDX_HEADER = os.path.join(HERE, os.pardir, "sources", "xorg_ddx_radeon_reg.h")
CORPUS = os.path.join(HERE, os.pardir, os.pardir, "r300", "docs",
                      "isa_references", "rs482_observed_clean_corpus.tsv")
OUT = os.path.join(HERE, os.pardir, "docs",
                   "rs480_ddx_sourced_field_enrichment.tsv")

# Register-name prefixes for silicon newer than RS480 (R300-family).  A field
# under such a name at a colliding offset is that later chip's semantics, not
# RS480's, so it is not RS480-sourced enrichment.
POST_RS480 = re.compile(r"^(AVIVO_|R500_|R520_|RV515_|R600_|R700_|RV6|RV7|"
                        r"EVERGREEN_|SUMO_|SI_|CIK_|CAYMAN_|NI_|RS600_|RS690_)")

MM_INDEX_OFFSET = 0x0000


def load_corpus_offsets(path):
    """Offsets that responded on RS480 silicon, with their value class."""
    offsets = {}
    with open(path, encoding="utf-8") as fh:
        next(fh)
        for line in fh:
            cols = line.rstrip("\n").split("\t")
            if not cols or not cols[0]:
                continue
            try:
                offsets[int(cols[0], 16)] = cols[1] if len(cols) > 1 else ""
            except ValueError:
                pass
    return offsets


def fields_by_offset(clean):
    """clean harvest rows -> {offset_int: {field_name: (reg, start, stop, mask)}}."""
    by_off = {}
    for reg, off, field, start, stop, mask in clean:
        by_off.setdefault(int(off, 16), {})[field] = (reg, start, stop, mask)
    return by_off


def names_by_offset(regs):
    """{offset_int: [register names defined there]} for collision detection."""
    by_off = {}
    for name, off in regs.items():
        by_off.setdefault(int(off, 16), []).append(name)
    return by_off


def compute_enrichment(dkms_clean, ddx_clean, ddx_regs, corpus):
    dkms = fields_by_offset(dkms_clean)
    ddx = fields_by_offset(ddx_clean)
    ddx_names = names_by_offset(ddx_regs)
    rows = []
    for off in sorted(corpus):
        if off == MM_INDEX_OFFSET:
            continue
        have = dkms.get(off, {})
        for field, (reg, start, stop, mask) in sorted(ddx.get(off, {}).items()):
            # Drop fields whose owning register OR field name carries a
            # post-RS480 prefix.  A shared register (e.g. R300_VAP_CNTL) can
            # define a later-chip feature bit (R500_TCL_STATE_OPTIMIZATION) that
            # is reserved on the R4xx-class RS480.  R200_* fields are kept: R200
            # predates R300, so RS480 inherits them.
            if field in have or POST_RS480.match(reg) or POST_RS480.match(field):
                continue
            aliases = sorted(n for n in ddx_names.get(off, []) if n != reg)
            rows.append((off, reg, field, start, stop, mask,
                         ";".join(aliases) or "-", corpus[off]))
    return rows


def self_test():
    ok = True

    def check(label, got, want):
        nonlocal ok
        if got != want:
            print("SELF-TEST FAIL: %s -> %r want %r" % (label, got, want),
                  file=sys.stderr)
            ok = False

    check("AVIVO dropped", bool(POST_RS480.match("AVIVO_VGA41_PPLL_POST_DIV_SRC")), True)
    check("R600 dropped", bool(POST_RS480.match("R600_BIOS_0_SCRATCH")), True)
    check("RS600 dropped", bool(POST_RS480.match("RS600_MC_STATUS")), True)
    check("R300 kept", bool(POST_RS480.match("R300_VAP_CNTL")), False)
    check("RADEON kept", bool(POST_RS480.match("RADEON_RB3D_CNTL")), False)
    check("RS400 kept", bool(POST_RS480.match("RS400_TMDS2_CNTL")), False)
    check("R200 field kept", bool(POST_RS480.match("R200_FP2_DVO_CLOCK_MODE_SINGLE")), False)
    check("R500 field dropped", bool(POST_RS480.match("R500_TCL_STATE_OPTIMIZATION")), True)

    # a post-RS480 feature bit in a shared (kept) register is dropped
    fc = {0x2080: "responding"}
    ddx2 = [("R300_VAP_CNTL", "0x2080", "R300_PVS_NUM_SLOTS", 0, 3, "0x0000000f"),
            ("R300_VAP_CNTL", "0x2080", "R500_TCL_STATE_OPTIMIZATION", 23, 23, "0x00800000")]
    rows2 = compute_enrichment([], ddx2, {"R300_VAP_CNTL": "0x2080"}, fc)
    check("R500 field in shared reg dropped",
          sorted(r[2] for r in rows2), ["R300_PVS_NUM_SLOTS"])

    # offset-0 MM_INDEX enum noise is excluded even if "fields" appear there
    fake_corpus = {0x0000: "responding", 0x1c3c: "responding"}
    dkms = [("RADEON_RB3D_CNTL", "0x1c3c", "RADEON_Z_ENABLE", 8, 8, "0x00000100")]
    ddx = [("RADEON_MM_INDEX", "0x0000", "RADEON_BOGUS", 0, 0, "0x00000001"),
           ("RADEON_RB3D_CNTL", "0x1c3c", "RADEON_Z_ENABLE", 8, 8, "0x00000100"),
           ("RADEON_RB3D_CNTL", "0x1c3c", "RADEON_DITHER_ENABLE", 2, 2, "0x00000004")]
    rows = compute_enrichment(dkms, ddx, {"RADEON_MM_INDEX": "0x0000",
                                          "RADEON_RB3D_CNTL": "0x1c3c"}, fake_corpus)
    check("offset-0 excluded", any(r[0] == 0 for r in rows), False)
    check("already-present field skipped",
          any(r[2] == "RADEON_Z_ENABLE" for r in rows), False)
    check("genuinely-new field kept",
          [r[2] for r in rows], ["RADEON_DITHER_ENABLE"])
    return ok


def render(rows):
    head = ["offset", "register", "field", "start_bit", "stop_bit", "mask",
            "ddx_collision_aliases", "rs480_value_class", "source"]
    lines = ["\t".join(head)]
    for off, reg, field, start, stop, mask, aliases, vclass in rows:
        mask_hex = mask if isinstance(mask, str) else "0x%08x" % mask
        lines.append("\t".join(["0x%04x" % off, reg, field, str(start), str(stop),
                                mask_hex, aliases, vclass, "xorg_ddx_radeon_reg.h"]))
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ddx", default=DDX_HEADER)
    ap.add_argument("--check", action="store_true",
                    help="verify the on-disk enrichment TSV matches a fresh diff")
    args = ap.parse_args()

    if not (hv.self_test() and self_test()):
        raise SystemExit("self-test failed; refusing to emit")

    _dk_regs, dkms_clean, _e, _f, _s, _r = hv.harvest(hv.read_reg_header(hv.DEFAULT_TARBALL))
    with open(args.ddx, encoding="utf-8") as fh:
        ddx_regs, ddx_clean, _e, _f, _s, _r = hv.harvest(fh.read())

    rows = compute_enrichment(dkms_clean, ddx_clean, ddx_regs,
                              load_corpus_offsets(CORPUS))
    body = render(rows)

    if args.check:
        existing = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if existing != body:
            raise SystemExit("ENRICHMENT DRIFT: %s differs from fresh diff" % OUT)
        print("enrichment TSV up to date")
        return

    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(body)
    offs = sorted({r[0] for r in rows})
    print("RS480-accessible offsets enriched from DDX : %d" % len(offs))
    print("new sourced fields                         : %d (-> %s)"
          % (len(rows), os.path.basename(OUT)))


if __name__ == "__main__":
    main()
