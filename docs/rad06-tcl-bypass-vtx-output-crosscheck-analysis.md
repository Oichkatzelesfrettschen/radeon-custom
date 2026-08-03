# RAD-06 analysis: TCL-bypass VAP_VTX_SIZE vs VAP_OUT_VTX_FMT cross-check

The draft this analysis produced converted into the native source
repository: linux-radeon-gororoba commit 70ee0de ("radeon: reject
TCL-bypass draws that underfeed the GA tuple") lands the tracker cases,
the reg_srcs trims, and the draw-time cross-check, tightened to the
proven position-plus-texcoord shape with declines for color and
point-size presence and for PRIM_WALK 3 immediate draws.
`policy/rs4xx-guard-scope.tsv` row M25 there records the execution
scope.  This analysis remains the derivation record; paths below are
relative to the unpacked DKMS source tree
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
3. All eight VAP_PROG_STREAM_CNTL_EXT_0..7 writes appear in this CS and
   each is the identity swizzle 0xF688F688 (select X,Y,Z,W, full write
   mask, both halves), so the PSC maps one fetched dword to one
   delivered dword and VAP_VTX_SIZE is directly comparable to the
   GA-side tuple.  Fewer than eight identity EXT writes cause the
   check to decline (partial coverage never rejects) so unwritten
   upper slots cannot hide stale non-identity expansion.
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

- Any of the tracked VAP inputs unseen in this CS (VAP_CNTL_STATUS,
  VAP_OUT_VTX_FMT_0/1, VAP_VTX_SIZE, or any of EXT_0..7): state may be
  inherited from a previous submission the parser cannot see.
- TCL_BYPASS clear or VAP_CNTL_STATUS unseen: with the PVS active the
  GA tuple comes from the shader's output map, not from the fetch
  stream, and VAP_VTX_SIZE governs only the input side; no comparison
  is valid.
- Any non-identity PSC EXT swizzle, or fewer than eight EXT_0..7
  identity writes in this CS: the PSC can synthesize components
  (ZERO/ONE selects, replication), so a vertex narrower than the tuple
  is legitimate, and unwritten upper EXT slots may retain inherited
  non-identity state the parser cannot see.  The full eight-slot
  identity requirement is the false-negative-over-false-positive trade.
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
   smoke) on RS482, since every mesa swtcl draw writes identity PSC EXT and
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

1. **PSC EXT full identity set.**  The check declines unless
   `VAP_PROG_STREAM_CNTL_EXT_0..7` are all written in this CS and every
   write is identity `0xF688F688` (`vap_psc_ext_seen_mask == 0xff` and
   `!vap_psc_ext_nonident`).  Partial EXT coverage never rejects; only
   the full eight-slot identity set permits the VTX_SIZE vs tuple
   compare.
2. **Safe-list removal.**  The draft removes 0x2090/0x2094/0x2140 and
   the EXT range from the r300, rs480, r420, rv515, and rs600
   `reg_srcs` tables so `r300_packet0_check` sees them on every
   r300-family chip that shares that parse path.
3. **Indexed draws.**  `PACKET3_INDX_BUFFER` only binds the index BO;
   the subsequent `PACKET3_3D_DRAW_INDX` / `3D_DRAW_INDX_2` (and
   `DRAW_VBUF` / `DRAW_VBUF_2` / IMMD variants) call the same
   `r300_cs_track_check` wrapper before `r100_cs_track_check`, so
   indexed bypass IBs face the same VTX_SIZE vs OUTPUT_VTX_FMT gate as
   array draws.  No separate check is required on the bind packet.

## Open questions

- Does VAP_VTX_SIZE describe pre-PSC (memory) or post-PSC (delivered)
  dwords when the PSC expands?  The identity-only gate sidesteps this,
  but answering it (bit-bang probe on RS482) would let the check cover
  expanded streams too.
- The kernel FMT_0 defines above bit 0 are marked GUESS in
  `radeon/r300_reg.h:116-119`; mesa uses the same encodings in anger
  (`r300_state_derived.c`), so confidence is high, but a
  color-present bypass IB replay would pin the color weight of 4.
- reg_srcs tables for r420/rv515/rs600 are trimmed in the same draft
  as r300/rs480; residual open work is regenerating the sibling
  `*_reg_safe.h` headers via mkregtable when the draft is wired into
  the DKMS series.
- Whether to also require PRIM_WALK != 3 (immediate draws embed vertex
  data in the IB; the GA starvation shape may differ).  The draft
  applies the check to all six draw opcodes.

## Which table protects which path

The two `reg_srcs` edits in this draft protect different paths, and the binder
in `patches/rs480/0021-rs480-cs-checker-r400-us-allowlist.patch` decides which
one an RS482 part reaches. That patch adds `rs480_reg_safe.h` to the mkregtable
targets, binds `rs400.o` to it, and selects it only under an explicit gate:

```c
if (rdev->family == CHIP_RS480 && radeon_rs480_r400_us_cs == 1) {
```

RS482 therefore receives `r300_reg_safe_bm` on the ordinary path and reaches
`rs480_reg_safe_bm` only when `rs480_r400_us_cs=1` is set at module load for an
attended run. Removing the tracked registers from `reg_srcs/r300` protects the
ordinary RS482 path, and removing them from `reg_srcs/rs480` protects the
explicitly armed R400-US path. Editing one table alone leaves the other path
unprotected.

## Blockers before the draft is wired

Two unresolved semantic questions in this analysis affect runtime rejection
behavior rather than wording, so each one gates integration.

The kernel `FMT_0` defines above the position bit are marked `GUESS`, and the
draft nonetheless assigns colors and point size concrete tuple widths. A CS
checker that rejects on a guessed field width rejects valid command streams.
The first integrated version declines whenever `FMT_0` carries a color or
point-size field and enforces only the witnessed shape, which is the position
plus texcoord component counts. Color and point-size widths enter after a
positive and a negative hardware replay pin them.

Immediate-mode semantics stay unresolved while the draft applies the check to
all six draw opcodes. `r100_cs_track_check` uses `vtx_size` only in the
`PRIM_WALK == 3` branch, and the GA starvation shape may differ there. The
first integrated version either declines when `PRIM_WALK == 3` or carries a
targeted immediate-mode positive control plus a malformed negative control.
Applying a rejection rule to an unresolved draw mode contradicts the draft's
own false-negative-over-false-positive posture.

## Cross-check execution record

The semantic audit and the offline gates from the acceptance contract ran
against linux-radeon-gororoba main (`1b1f515`, which carries `70ee0de` and
the position-presence tightening `5bbc12f`), the commit the DKMS
`source-identity.toml` pins as `radeon-unified 0.5` profiled source.

Color and point-size semantics: mesa r300g SWTCL emission is the strongest
available source for the GUESSed FMT_0 dword weights.
`r300_draw_emit_all_attribs` (`src/gallium/drivers/r300/r300_state_derived.c`)
emits position `EMIT_4F` (4 dwords), each color and back-color `EMIT_4F`
(4 dwords), and point size `EMIT_1F_PSIZE` (1 dword), and
`r300_swtcl_vertex_psc` derives `VAP_VTX_SIZE` from that same
`vinfo->size` sum.  That is rank-4 driver evidence, not a silicon
measurement, so the GUESS marks in `radeon/r300_reg.h:116-119` stand and
the checker keeps the decline for any FMT_0 bit beyond position.
Immediate-draw semantics stay declined on the same posture:
`r100_cs_track_check` consumes `vtx_size` itself in its `PRIM_WALK == 3`
branch, and the GA starvation shape there is uncharacterized.

Offline replay: `scripts/replay_r300_tcl_bypass_ib.c` in the native tree
walks a raw PM4 dword stream (bare or `R3RKIB1`-wrapped retained capture)
with the same register tracking `r300_packet0_check` keeps and evaluates
the shared `r300_tcl_bypass_vtx_check.h` decision at each of the six draw
opcodes, taking `VAP_VF_CNTL` from the draw packet payload as
`r300_packet3_check` does.  Calibration: a synthetic fully pinned
position-plus-two-texcoord stream returns REJECT at `VTX_SIZE` 8 and PASS
at `VTX_SIZE` 12 (the anchor tuple).  The retained RS482 no-submit
capture
`cachyos_vostro1000_r300vk_nosubmit_triangle_pm4_capture_20260525T023522Z`
(`1779676213-79574-3/pre_ib.bin`, TCL_BYPASS set, position-only tuple,
`3D_DRAW_IMMD_2`, one of eight PSC EXT words written) replays to DECLINE,
and stays DECLINE under a forced `VAP_VTX_SIZE` 0 mutation: the
fail-closed arms hold on genuine capture bytes, and an underfeed inside
an unpinned premise set never escalates to a false rejection.

Generated bitmaps: `mkregtable` over `reg_srcs/{r300,rs480,r420,rv515,rs600}`
routes 0x2084, 0x2090, 0x2094, 0x20B4, 0x2140, and 0x21E0-0x21FC to the
packet0 check callback (bitmap bit set) in all five headers, and the
`reg_srcs/r300` versus `reg_srcs/rs480` diff is exactly the gated R400-US
allowlist, so the ordinary and the armed RS482 parse paths carry the same
tracking.

Build matrix: `check_radeon_pinned_source_compiles.sh` passes against the
declared 6.18.38-2-cachyos-lts build root and against the RS482 host's
installed 7.1.3-2-cachyos build root, both from the pinned source, with
the warning scan clean.

The ioctl-level negative/positive replay and the regression sweep on
silicon remain with the parked kernel-baseline-equivalence work; the
offline record above covers the source, generated-state, and build gates
only.

## Measured firing coverage over the retained corpus

A reason-coded replay of the shared decision function over the whole retained
RS482 corpus revises the test-plan item-2 expectation. Item 2 expected the
archived malformed delivery capture to reject with -EINVAL. The measurement
finds the opposite: across 8537 real draw packets in 2405 retained IBs the
decision returns 8535 DECLINE and exactly one PASS and one REJECT, both the
synthetic `known_good`/`known_bad` fixtures that were never submitted. No
retained `.bin` corresponds to the item-2 malformed capture: the
`recur40`/`spill1` delivery-capture directory holds only text `.raw_ib.log`
logs, and its RCA concerns a different wedge, the HBTCL-04f fence-wedge, which
it records as invariant HOLD and register EQUIVALENT with the cause below the
command stream. The retained `.bin` closest to the anchor, the nosubmit triangle
capture, declines. The decline is dominated by `no_vtx_size`, 7091 of 8535:
the real producer inherits `VAP_VTX_SIZE` across submissions rather than
re-emitting it in each draw CS, and the real full-EXT draws write non-identity
PSC, so the fully witnessed identity underfeed shape is not a natural producer
output.

The check stays source-correct and compile-verified but dormant over the
retained corpus, so the live ioctl campaign is parked pending coverage redesign.
The census tool is
`linux-radeon-gororoba/scripts/rad06_corpus_reason_census.sh`, and the finding
is `steinmarder-r300:src/re/r300/findings/active/2026-08-03-rad06-empty-firing-surface-retained-rs482-corpus.md`.

## Claim boundary

The check is submission-local. Its tracking structure zeroes for each CS, and
it declines whenever relevant state may have been inherited from a previous
submission. The claim this work can earn is therefore bounded:

> Rejects the proven, fully witnessed, same-CS TCL-bypass vertex-underfeed
> shape.

A userspace stream that splits state across submissions makes the checker
decline by design, so the work does not support the broader claim of preventing
every TCL-bypass GA-starvation command stream. The bounded claim is a defense
against the reproduced mesa failure rather than validation against arbitrary or
hostile command streams.

## Integration acceptance contract

Wiring the draft into the DKMS series is complete when every gate below holds.
The natural integration position is the series tail, because the draft was
regenerated against a post-series tree and the 0021 dependency only establishes
when `reg_srcs/rs480` begins to exist. The filename names the mechanism rather
than the task identifier.

| Gate | Required result |
|---|---|
| Strict application | The draft applies at its final series position with no recount, fuzz, offset, or reject |
| Packaging integrity | `PKGBUILD` source and sha256sums arrays align, the new checksum verifies, and pkgrel advances |
| Source verification | 71 DKMS patches apply cleanly after integration |
| Compilation | The touched units compile against the selected kernel headers with zero warnings, through `check_radeon_patch_series_compiles.sh --require-compile` so no skip can read as a pass |
| Translation-unit accounting | Expected to stay 13, since the draft adds no newly touched `.c` beyond `r300.c`; verify rather than assume |
| Generated bitmaps | `mkregtable` output shows the tracked bits are no longer safe in `r300`, `rs480`, `r420`, `rv515`, and `rs600` |
| Negative replay | The archived 8-dword input against a 12-dword output tuple returns `-EINVAL` with no GA latch and no ring stall |
| Positive replay | The corrected 12-dword stream stays accepted and retires identically |
| Decline controls | Inherited state, partial EXT coverage, nonidentity EXT, unresolved `FMT_0` shapes, and immediate mode remain accepted through explicit decline |
| Regression | Ordinary RS482 SWTCL, hardware TCL, indexed draws, and representative non-RS480 R300-family paths show no new rejection |
| Promotion | A clean build earns `compile-verified` only; `hardware-pass` requires retained replay and regression bundles |
