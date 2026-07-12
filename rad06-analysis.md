# RAD-06 analysis: TCL-bypass VAP_VTX_SIZE vs VAP_OUT_VTX_FMT cross-check

Companion to the tracked draft
`rad06-tcl-bypass-vtx-output-crosscheck.draft.patch` at the repo root
(not yet wired into the DKMS series).  Paths below are relative to the
unpacked DKMS source tree
`packaging/arch/radeon-unified-dkms/pkg/radeon-unified-dkms/usr/src/radeon-unified-0.3/`.

## Register-identity correction

The task background named VAP_VTX_SIZE as 0x2140.  Both the kernel
`radeon/r300_reg.h` and mesa `src/gallium/drivers/r300/r300_reg.h` agree the
registers are:

- VAP_VTX_SIZE = 0x20B4 (kernel tracks it: `radeon/r300.c:738`)
- VAP_CNTL_STATUS = 0x2140, carrying `R300_VAP_TCL_BYPASS` (1 << 8)
  (`radeon/r300_reg.h:151,155`; mesa `r300_reg.h:152,164`)

The hang mechanism is unchanged: the malformed IB wrote VAP_VTX_SIZE = 8
while VAP_OUT_VTX_FMT_0/1 advertised a 12-dword tuple (pos 4 + 2 texcoords
at 4 components each), and the GA latched waiting for the missing 4
dwords per vertex.

## Checker map (deliverable 1)

All symbols located with `rg`/`grep -n` over the unpacked DKMS tree;
polarity of the safe-register bitmap confirmed by reading
`mkregtable.c` (`t->table[i] ^= m` clears the bit for listed registers).

- vtx_size tracking: `radeon/r300.c:738-741` (`case 0x20B4` in
  `r300_packet0_check`, `track->vtx_size = idx_value & 0x7F`); field
  declared at `radeon/r100_track.h:62`.
- vtx_size consumption: `radeon/r100.c:2382` inside `r100_cs_track_check`
  (`size = track->vtx_size * nverts`), used ONLY for the PRIM_WALK==3
  immediate-mode dword-count check; PW 1/2 coverage uses
  `track->arrays[i].esize`, never vtx_size (`radeon/r100.c:2337-2402`).
- Unparsed passthrough: `radeon/reg_srcs/r300:38,39,42` list 0x2090
  VAP_OUT_VTX_FMT_0, 0x2094 VAP_OUT_VTX_FMT_1, 0x2140 VAP_CNTL_STATUS as
  safe.  `r100_cs_parse_packet0` (`radeon/r100.c:1394-1437`) invokes the
  per-register `check()` callback only when the bitmap bit is SET;
  mkregtable clears bits for listed registers, so these three never reach
  `r300_packet0_check` and their values are invisible to the tracker.
  The rs480 fork table created by
  `patches/rs480/0021-rs480-cs-checker-r400-us-allowlist.patch` mirrors
  the same three lines and also lists them safe.
- TCL_BYPASS visibility: none today.  0x2140 passes through unparsed, so
  the checker cannot distinguish bypass from PVS draws.  The bit is
  `R300_VAP_TCL_BYPASS` (`radeon/r300_reg.h:155`).
- Rejection points: `r300_packet0_check` default -> `fail:` -EINVAL
  (`radeon/r300.c:1157-1170`); draw-time checks in `r300_packet3_check`
  call `r100_cs_track_check` from all six PACKET3_3D_DRAW_* cases
  (`radeon/r300.c:1215,1230,1237,1244,1251,1258`).  Parser wiring:
  `radeon/r300.c:1295-1303` (`r300_cs_parse` passes
  `config.r300.reg_safe_bm` + `r300_packet0_check`); track is kzalloc'ed
  per CS (`radeon/r300.c:1287`), so all new "seen" flags default to
  false each submission.

## When the check is sound

The cross-check fires only when the SAME command stream proves every
input:

1. A VAP_CNTL_STATUS write with R300_VAP_TCL_BYPASS set (bypass proven,
   not inherited).
2. Both VAP_OUT_VTX_FMT words and VAP_VTX_SIZE written.
3. At least one VAP_PROG_STREAM_CNTL_EXT write, and every such write is
   the identity swizzle 0xF688F688 (select X,Y,Z,W, full write mask,
   both halves), so the PSC maps one fetched dword to one delivered
   dword and VAP_VTX_SIZE is directly comparable to the GA-side tuple.
4. No format bits outside the decoded set (FMT_0 outside
   POS|COLOR0..3|PT_SIZE, FMT_1 above bit 23, any texcoord component
   count above 4).

Under those conditions the dword requirement is: position 4, point size
1, each color 4, each texcoord its 3-bit component count.  This matches
mesa's producer (`r300_state_derived.c` sets POS_PRESENT/PT_SIZE_PRESENT/
COLOR_i_PRESENT and 3-bit texcoord counts) and the on-silicon RCA
evidence: the retiring IB ran VTX_SIZE 12 for a pos+2tex tuple, the
hanging IB ran VTX_SIZE 8 with the identical tuple.  `vtx_size <
required` is then a proven GA-starvation shape and is rejected -EINVAL.

## When it must decline

- Any of the five registers unseen in this CS: state may be inherited
  from a previous submission the parser cannot see.
- TCL_BYPASS clear or VAP_CNTL_STATUS unseen: with the PVS active the
  GA tuple comes from the shader's output map, not from the fetch
  stream, and VAP_VTX_SIZE governs only the input side; no comparison
  is valid.
- Any non-identity PSC EXT swizzle: the PSC can synthesize components
  (ZERO/ONE selects, replication), so a vertex narrower than the tuple
  is legitimate.  This also declines on streams whose unused upper EXT
  slots carry stale non-identity values -- a deliberate
  false-negative-over-false-positive trade.
- Undecoded FMT bits or texcoord component counts of 5-7: unknown tuple
  width.
- vtx_size larger than the tuple: not rejected; over-delivery is not
  the starvation hazard (and the kernel cannot prove it is harmful).

## Interaction with existing vtx_size buffer-coverage math

`r100_cs_track_check` uses vtx_size only in the PRIM_WALK==3 branch as an
immediate-data dword count (`radeon/r100.c:2382`); PW 1/2 vertex-buffer
coverage uses per-array esize.  The new check is orthogonal: it compares
vtx_size against the GA consumption side, not against buffer sizes, and
runs before `r100_cs_track_check` via the new `r300_cs_track_check`
wrapper, so existing coverage rejections are unchanged.  No field the
old math reads is modified; the patch only adds fields and one wrapper
indirection in r300's six draw cases.  r100/r200 parse paths call
`r100_cs_track_check` directly and are untouched.

## Test plan

1. Rebuild via the real gate: `dkms build --force radeon-unified/0.3`
   with the draft appended to the dkms.conf PATCH series (after
   0021, whose reg_srcs/rs480 table this draft also edits).  Not run in
   this session (task is read-only investigation plus draft).
2. Replay the archived malformed IB (VTX_SIZE=8, FMT tuple=12dw; the
   recur40 spill1 NOVAR delivery capture in steinmarder src/re/r300):
   expect the submit ioctl to fail -EINVAL with the
   "TCL-bypass draw: VAP_VTX_SIZE ..." warning and NO GA latch in
   RBBM_STATUS, no ring stall.
3. Replay the fixed IB (R300_R2VB_OUTPUT_REINGEST reconstruction,
   VTX_SIZE=12): expect acceptance and byte-identical retirement, as on
   the pre-patch kernel.
4. Regression sweep: a normal SWTCL GL workload (glxgears, deqp-gles2
   smoke) on RS482 -- every mesa swtcl draw writes identity PSC EXT and
   consistent VTX_SIZE, so zero new rejections expected.  A HW-TCL
   r300-class run (PVS draws) must also show zero rejections since
   TCL_BYPASS is clear.
5. Decline-path probe: submit a bypass IB that omits the
   VAP_CNTL_STATUS write; expect acceptance (permissive default), even
   with a mismatched size, demonstrating the check never fires on
   inherited state.

## Review closure (draft intent)

These clauses answer residual review on the draft without changing the
kernel series wiring (still a draft):

1. **PSC EXT required.**  The check declines unless at least one
   VAP_PROG_STREAM_CNTL_EXT write appears in this CS and every such write
   is identity `0xF688F688`.  Partial EXT coverage never rejects; only
   the full identity set permits the VTX_SIZE vs tuple compare.
2. **Safe-list removal.**  The draft removes 0x2090/0x2094/0x2140 (and
   the EXT range) from the r300 and rs480 mkregtable sources so
   `r300_packet0_check` sees them.  Sibling family tables (r420/rv515)
   remain a follow-on trim; they are not silent false rejections, only
   absent coverage.
3. **Indexed draws.**  Every `PACKET3_3D_DRAW_*` case in
   `r300_packet3_check` (including `3D_DRAW_INDX` / `3D_DRAW_INDX_2` /
   `DRAW_VBUF` / `DRAW_VBUF_2` / IMMD variants) routes through the same
   wrapper before `r100_cs_track_check`, so indexed bypass IBs face the
   same VTX_SIZE vs OUTPUT_VTX_FMT gate as array draws.

## Open questions

- Does VAP_VTX_SIZE describe pre-PSC (memory) or post-PSC (delivered)
  dwords when the PSC expands?  The identity-only gate sidesteps this,
  but answering it (bit-bang probe on RS482) would let the check cover
  expanded streams too.
- The kernel FMT_0 defines above bit 0 are marked GUESS in
  `radeon/r300_reg.h:116-119`; mesa uses the same encodings in anger
  (`r300_state_derived.c`), so confidence is high, but a
  color-present bypass IB replay would pin the color weight of 4.
- reg_srcs tables for r420/rv515/rs600 still list the three registers
  as safe; RV515 draws route through r300_packet0_check too, so those
  chips silently keep the old permissive behavior until their tables
  get the same trim.
- Whether to also require PRIM_WALK != 3 (immediate draws embed vertex
  data in the IB; the GA starvation shape may differ).  The draft
  applies the check to all six draw opcodes.
