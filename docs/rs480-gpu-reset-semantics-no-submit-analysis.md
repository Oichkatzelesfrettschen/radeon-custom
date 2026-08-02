# RS480 GPU-reset semantics: no-submit analysis and admissibility record

This document consolidates the no-submit GPU-reset semantics for the RS482
(`1002:5974`) recovery lane: legal register read/write completion, the reset
pulse and mask ordering, the exact stop lines, the offline validation record
(calibration, retained IB replay, and the two-lane kernel build matrix), and
the definition of the first admissible recovery fire. It closes the offline
half of the RAD-05j umbrella; efficacy on silicon stays with the attended-fire
authorization it defines. `docs/rs480-containment-architecture-and-evidence-decomposition.md`
carries the containment architecture and evidence classes;
`steinmarder-r300:src/re/r300/findings/rs480-reset-recovery-patch-status-table.md`
remains the canonical fire-verdict index. This document cites both and
duplicates neither.

The mechanism under analysis is the patch series 0040-0048 (force-clock
production reset path, wedge-safe readback shim, parked-GPU failure path) plus
0063-0068 (parameterized soft-reset mask candidates), as ported onto the
native source repository: linux-radeon-gororoba `drivers/gpu/drm/radeon/r300.c`
(`r300_asic_reset`), `radeon_rs4xx_dev.c` (mask table, hang-probe tokens), and
`radeon_rs4xx_reset_mask_claim.h` (the shared atomic claim loop).

## Legal read/write completion

The completion rules divide the reset path's register traffic into three
classes, each with a distinct hazard model on this K8/HyperTransport host,
where one non-completing MMIO read stalls the reading core, IPIs stop, and the
second core follows on its next cross-CPU operation.

- Posted writes to RBBM_SOFT_RESET (0x0000F0). Register-BAR MMIO writes post
  when the MMIO Limit NP bit is 0 (AMD BKDG #32559, section 4.4.5.3), so the
  assert and deassert writes complete on the CPU side without waiting for the
  device. The 0063 reset body drops the 0043 posting-flush RREG32 on the
  assert path: posted assert, `mdelay(500)` hold that serializes the write,
  posted deassert, `mdelay(1)`. The assert path therefore performs no read
  that could black-hole under a wedged engine.
- Classification reads of RBBM_STATUS (0x000E40). The only reads the reset
  body performs are RBBM_STATUS samples, taken while SCLK_CNTL (PLL 0x0d) and
  SCLK_CNTL2 (PLL 0x1e) force the 3D clock domains, which is the condition
  under which the RBBM register bus stays readable. A failed reset keeps the
  force-clock asserted (patch 0047) precisely so these reads keep completing
  on the parked GPU.
- Forbidden reads on the wedge path. Reads into the 3D pipe space at 0x4000+
  (patch 0045 gates RB3D_DSTCACHE_CTLSTAT 0x4E4C behind an RBBM_STATUS idle
  check) and into the gated VAP aperture 0x2200-0x2504 are non-posted and do
  not complete while VAP/GA latch busy; the retained lever-freeze evidence
  (steinmarder-r300 bundle
  `cachyos_vostro1000_rs482_pvs_wedge_recovery_lever_20260612T194009Z`) shows
  the host freeze that class produces. R300_GA_SOFT_RESET (0x429c), the
  dedicated GA+RB3D block reset, sits in that space: its read is classified
  `busy_gated_read`/`read_safe_idle_only`, so any future 0x429c sequence must
  be pure posted writes with no readback, and it stays gated behind a
  read-only confirmation that the register BAR's MMIO Limit NP bit reads 0.
  The RBBM_SOFT_RESET co-mask lane needs no such precondition because its
  write surface is already host-validated by the 0043 fires.

## Reset pulse and mask ordering

The pulse shape is fixed by observation: the 0043 production ladder already
held VAP|GA asserted for 500 ms with the display quiesced and the CP stopped,
and GA held through it (RBBM_STATUS 0x8411C100 to 0x8401C100 to 0x8400C100;
VAP clears, GA holds). That falsifies "500 ms is sufficient" for the baseline
mask and leaves repeated pulses and staggered orders without primary-source
support, so the sequence stays single assert, 500 ms hold, single deassert,
and the open design axis is the mask, not the pulse.

The candidate masks are a compiled allow-listed table selected by a bounded
index, never a raw operator mask. `RS480_RESET_ALLOWED_MASK` permits only the
3D bits VAP(2)|RE(3)|PP(4)|RB(6)|GA(13) = 0x205C, enforced per candidate by
`static_assert`:

| candidate | mask | value | argument |
|---|---|---|---|
| BASELINE | VAP\|GA | 0x2004 | 0043 control; reproduces the GA-holds ladder |
| GA_RB | VAP\|GA\|RB | 0x2044 | lead: the dedicated 0x429c reset couples GA+RB3D, so RB3D backpressure holding GA is the one topology argument 0043 never tested |
| GA_RE | VAP\|GA\|RE | 0x200C | alternate: drain the raster front between GA and the backend |
| FULL_3D | VAP\|RE\|PP\|RB\|GA | 0x205C | broad fallback, equal to the allow-list |

Ordering around the mask write is the 0043 frame unchanged: `r100_mc_stop`,
CP stop (CSQ_CNTL 0, RB pointers zeroed), `pci_save_state`, bus-master
disable, force-clock, mask assert/hold/deassert, then the always-run CP reset
(assert SOFT_RESET_CP, posting read, 500 ms, deassert), PCI restore,
bus-master enable, classification. Success classification is mask-aware:
BASELINE and discrete R3xx/R4xx keep exactly the 0043 predicate
(GA_BUSY||VAP_BUSY); any non-baseline mask additionally requires the master
GUI_ACTIVE bit idle, so a newly reset block left stuck is not misread as
recovered.

A non-baseline candidate arms through the 0644 module param
`rs480_reset_mask` and is consumed exactly once by an atomic
`cmpxchg(sel, baseline)` claim loop (`radeon_rs4xx_reset_mask_claim.h`), so
concurrent resets consume at most one armed selection, a concurrent disarm
wins, and an out-of-range selector yields BASELINE without a consume. The
experimental masks are RS400/RS480-only; discrete R3xx/R4xx sharing
`r300_asic_reset` always take BASELINE.

## Exact stop lines

- Mask allow-list: any 0x0000F0 bit outside 0x205C is compile-rejected. The
  host bits HI/HDP/MC/AIC, the display/video/clock bits VIP/DISP/CG, the 2D
  engine E2, and IDCT never enter a candidate.
- CP co-mask is hazardous-special: the upstream reset path's own comment
  records that resetting the CP "sometimes ends up hard locking the
  computer," so CP(0) stays outside the allow-list and a CP co-mask candidate
  requires a new design review naming that warning.
- Failure containment is fail-parked: a failed reset leaves SCLK forced (the
  register bus stays readable), leaves the MC stopped and the display parked
  (re-enabling display memory requests against the wedge-held MC arbiter
  deadlocks the host within one or two vblank periods), and routes into the
  0046 `gpu_parked` state that blocks every later resume-side register
  access.
- Post-park MMIO silence: after parking, no reader touches the 0x4000+ 3D
  pipe space or the VAP aperture; the 0045 shim gates the last diagnostic
  read class behind RBBM_STATUS idle.
- One fire per named mask, attended, under separate authorization, with
  boot-persistent off-box capture (netconsole or serial) as a mandatory
  precondition, so a host death cannot lose its last pre-freeze line to page
  cache.

## First admissible recovery fire

The first admissible fire is the GA_RB candidate (`rs480_reset_mask=1`,
consumed one-shot), on the RS482 target with netconsole or serial capture
armed before the wedge is induced, driven through the production path
(`radeon_gpu_reset` to `r300_asic_reset`) by the WD3B hung-frontend probe
gate (frontend busy with RB3D/RE idle, the 0x8411c100 signature). The
precommitted oracle is the dev_info mask line
(`RS480 soft-reset candidate ga_rb(VAP|GA|RB) mask 0x00002044`), the three
RBBM_STATUS classification lines, and the mask-aware success predicate:

- GA_RB releases GA: RBBM_STATUS clears GA_BUSY and GUI_ACTIVE after the
  ladder and the post-reset IB test passes; the RB3D-backpressure hypothesis
  is confirmed.
- GA_RB fails: the ladder ends in "failed to reset GPU", the parked failure
  path holds (forced clocks, stopped MC, `gpu_parked`), and the host
  survives; the hypothesis is falsified and GA_RE then FULL_3D are the
  successors, one fire each.
- Any host death during the fire is a stop-line breach finding, not a
  candidate rotation.

## Execution record

Offline validation ran against linux-radeon-gororoba main 6fbac30 (the pinned
source constructor commit 1b1f515d, radeon-unified 0.5, carries the same
driver subtree) on 2026-08-02:

- Claim-loop race calibration: `scripts/calibrate_rs480_reset_mask_claim.c`
  compiled against the kernel claim header verbatim; 20000 arms, 19965
  claims, 0 duplicate-claimed, out-of-range selector returned baseline
  without consuming, and the known-bad torn consume (read-then-store) was
  refuted with 12201 duplicate claims, so the harness keeps its
  good/bad discrimination. Exit 0.
- Retained IB replay: `scripts/replay_r300_tcl_bypass_ib` at the same commit
  reproduces the validator matrix on the reset-carrying tree: synthetic
  anchor REJECT at VTX_SIZE 8 and PASS at 12, retained RS482 no-submit
  capture DECLINE, holding DECLINE under a forced VTX_SIZE 0. The CS parse
  surface the recovery path returns control to is therefore unchanged by the
  reset series.
- Kernel build matrix: `scripts/check_radeon_pinned_source_compiles.sh` PASS
  against the declared 6.18.38-2-cachyos-lts build root and PASS against the
  installed vostro kernel build root, both from the pinned source identity in
  `packaging/arch/radeon-unified-dkms/source-identity.toml`.

Retained bundle:
`steinmarder-r300:src/re/r300/results/rs480-gpu-reset-semantics-no-submit-rs482-20260802`.

## Claim boundary

Known: the reset body's write traffic is posted and readback-free on the
assert path; its only reads are force-clocked RBBM_STATUS samples; every
candidate mask is inside the 3D allow-list by compile-time proof; the armed
selection is consumed exactly once under races; the pinned source builds
clean on both kernel lanes; and the CS validator behavior is unchanged.
Hardware-established: the BASELINE ladder executes without killing the host
and GA holds through it. Not run: every efficacy question, i.e. whether
GA_RB, GA_RE, or FULL_3D releases a wedged GA, and the 0x429c posted-write
lane; those are silicon legs, one attended fire per named mask under the
admissibility definition above, and their qualification into a deployable
baseline stays with the kernel-baseline-equivalence work.
