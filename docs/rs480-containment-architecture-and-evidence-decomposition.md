# RS480 containment architecture and evidence decomposition

This document decomposes what the `radeon-unified` DKMS module does, which
silicon and host mechanisms force each design choice, and exactly how strong the
evidence behind each claim is. It exists so a reader outside this workspace can
regenerate every number, locate every source, and see which claims remain open.

`README.md` is the source of record for package contents and the promotion
ladder. `steinmarder-r300:src/re/r300/findings/rs480-reset-recovery-patch-status-table.md`
is the source of record for retained RS482 hardware verdicts. This document
cites both and duplicates neither.

Each load-bearing claim below carries four things: the claim, its source, an
evidence class from the promotion ladder, and a falsifier for anything standing
below `hardware-pass`. A claim with no rank-1 through rank-4 source by name is
marked hypothesis.

A hardware claim carries two source lines rather than one, because
`AGENTS.md` ranks retained silicon output at rank 1 and ranks findings and
manifests in `steinmarder-r300` at rank 5. The patch status table is a
canonical verdict index: it is the source of record for which verdict holds,
and it points onward to the retained bundle that is the rank-1 evidence. Citing
the index alone would present a rank-5 synthesis as primary evidence, so each
claim names the index and the bundle separately.

## Silicon and host substrate

The target is one RS480-class integrated GPU. The `radeontool` inventory bundle
identifies it as PCI `1002:5974`, an RS482 part, on the `cachyos-vostro1000`
host. The names RS480, RS482, and RS485 select variants of the same IGP class;
the Palm and Wrestler patches in the same package address a separate hardware
generation, and evidence does not transfer between the two lanes.

Three substrate facts drive the entire containment design.

The GPU shares system memory through a GART rather than owning discrete VRAM, so
a GART or aperture fault reaches host memory paths directly. The host is a K8
with two cores behind a HyperTransport link to an SB600 southbridge.

A CPU stalled on a non-posted HyperTransport MMIO read stops answering IPIs, and
the other K8 core then stalls on its next cross-CPU operation, so one read of a
wedged register block can hang the entire host. This is the mechanism that makes
an ordinary debugfs register read a host-availability hazard, and it is why
every post-park reader in this package terminates before touching MMIO rather
than after checking a return value.

The reset wedge is GA-rooted. Patch 0043 drives the force-clock plus RBBM
soft-reset ladder, and `RBBM_STATUS` walks `0x8411C100` to `0x8401C100` to
`0x8400C100`: VAP clears while GA holds. Force clock plus the implemented
soft-reset ladder executes fully and does not recover the GPU.

Canonical verdict: `steinmarder-r300` patch status table, "Settled mechanism
facts" and the 0043 row. Primary evidence:
`steinmarder-r300:src/re/r300/results/cachyos_vostro1000_rs480_wd3b_netconsole_lock_precedes_reset_body_20260707T0623Z/netconsole_capture_rung3.log`,
which carries the walk against the reset-path source lines that emit it:
`r300_asic_reset:449` reports `0x8411C100`, `r300_asic_reset:474` reports
`0x8401C100`, `r300_asic_reset:490` reports `0x8400C100`, and the ladder ends in
`failed to reset GPU`. Evidence class: hardware-run, partial.
Falsifier: an attended run in which GA clears from `RBBM_STATUS` after the 0043
ladder, or in which a host survives a confirmed non-posted read against a
wedged block.

## Containment architecture

The design goal is host survival across a failed GPU reset, not GPU recovery.
Once `radeon_device` classifies a reset as failed, the driver sets `gpu_parked`
and every subsequent path terminates in a safe terminus rather than reaching
hardware. `docs/rs480-parked-access-audit.md` enumerates the channels and their
termini: skip, return disconnected, return error, force-complete, leak until
reboot, SIGBUS, no-op, or leave the display parked.

The parked-state gates span thirteen translation units, which is the measured
blast radius of the containment property:

```text
r300.c              radeon_fbdev.c        radeon_kms.c
radeon_connectors.c radeon_fence.c        radeon_ttm.c
radeon_cursor.c     radeon_gem.c          rs400.c
radeon_device.c     radeon_irq_kms.c
radeon_display.c    radeon_drv.c
```

The containment ladder converged by elimination across attended runs, and each
step names the actor it removed. Async work drain proved insufficient: Fire 22
executed the full `cancel_delayed_work_sync` sequence, returned PARK, and still
died inside the three-second quiet window, refuting the drained set as the
killer. Fire 23 then identified KMS output polling and connector detect as the
quiet-window actor, and patch 0058 gates that path. Fire 28 completed the full
sequence of trigger, failed reset, park, mapping zap, quiet-window survival,
client freeze and thaw, and postclose, with `boot_id` stable and SSH answering.

Canonical verdict: `steinmarder-r300` patch status table, rows 0056 through
0060. Primary evidence: the retained bundles those rows name, including
`results/cachyos_vostro1000_rs480_0057_verdict_fire_post_quiesce_quiet_window_death_20260708T0257Z`
for the refuted drain set,
`results/cachyos_vostro1000_rs480_0058_output_poll_gate_quiet_window_survival_20260708T0340Z`
for the quiet-window survival, and
`results/cachyos_vostro1000_rs480_0060_parked_gpu_full_host_survival_no_fuse_20260708T1153Z`
for the Fire 28 host-survival pass. Evidence class: hardware-pass for host
survival under the Fire 28 procedure. Falsifier: an attended repeat of the Fire
28 procedure in which `boot_id` changes or SSH stops answering.

Fire 28 achieved host survival alone and did not isolate the 0060 gate from the
client freeze and thaw procedure it also changed. A later targeted refault fire
directly demonstrates the SIGBUS firing: it drives one SIGUSR1 re-touch into the
zapped mapping and returns SIGBUS (si_code BUS_ADRERR, breadcrumb match, boot_id
stable), retained as steinmarder-r300 bundle
`rs480_sigbus_refault_fire_rs482_20260803T030621Z`. The fire ran on the
dev-profile module, whose 0060 gate source is identical to the prod module, and
park is reachable only through the armed dev reset node, so this is the only
obtainable evidence. GPU recovery, display recovery, and the attribution of Fire
28 host survival to the 0060 gate remain open.

## Register evidence partition

The package splits every register it reads into two tables with different
evidence requirements. This partition is the reusable research artifact, because
each row carries its own provenance rather than inheriting a blanket claim.

`rs480-safe-regs.tsv` holds 82 rows. A row qualifies as safe when it has no
documented write side-effect on read and a retained bundle shows the read
completing.

The two tables reuse the same letters for different sources, so a code is read
against the legend of its own file. In the safe table `RM` is retained
`radeontool regmatch all` output and `SP` is a symbol in `rs400d.h` or
`radeon.h`. In the candidate table `RM` is public register-manual text and `SP`
is a public xorg `radeon_reg.h` symbol. Written as `safe.RM` and
`candidate.RM`, the two carry opposite evidence weight: one is retained tool
observation, the other is documentation. Prose below namespaces every code.

The 82 rows partition into eight exact source tuples:

| Tuple | Rows | What the tuple asserts |
|---|---|---|
| `RM,SP` | 23 | Retained regmatch output plus a kernel-header symbol |
| `RT,RM,SP` | 23 | `radeontool` regs output, regmatch, and a kernel-header symbol agree |
| `SP,HR` | 22 | Symbol plus hazard-read observation, all 22 reads completed with no core wedge |
| `RM` | 4 | Retained regmatch output alone, on the PCI config shadow registers |
| `SP,CO` | 3 | Symbol plus candidate-node observation at `hazard_count=0` with `boot_id` stable |
| `SP,FO` | 3 | Symbol plus attended frontier-probe read with heartbeat advancing |
| `SP,BU` | 3 | Symbol plus blind userspace `resource2` mmap readout |
| `RT,RM` | 1 | Tool output plus regmatch, no kernel-header symbol |

Every row therefore carries at least one retained observation code, and the
safe table holds no documentation-only row. The four `RM`-only rows are
`COMMAND`, `STATUS`, `CACHE_LINE`, and `CAPABILITIES_ID`, the PCI config
shadows, and retained regmatch output is what places them.

Every source class names a retained bundle in the file header, including
`rs480_0019_pll_hazard_live_read_20260609T172724Z` for the hazard-read class and
`cachyos_vostro1000_rs482_attended_frontier_combined_read_sweep_20260615T065527Z`
for the blind userspace readout, which recorded 116 of 116 reads done with zero
quarantine and a stable `boot_id`.

`rs480-candidate-regs.tsv` holds 30 rows that are explicitly not safe: 28 reached
through BAR0 MMIO offsets with `RREG32()`, and 2 through the RS400/RS480 MC
indirect index with `RREG32_MC()`. They are bounded candidates for one-at-a-time
live read validation. The generator promotes 24 of them and skips 6 that sit in
design-only attended cohorts, which is the mechanism that keeps an unvalidated
candidate out of the safe path.

Source: the two TSV files and their header legends;
`scripts/generate_rs480_debugfs_fragments.py` computes the accepted and skipped
split that `scripts/verify_radeon_unified_dkms_sources.sh` reports. Evidence
class: retained hardware observation for every safe row, since each carries at
least one of `RT`, `safe.RM`, `HR`, `FO`, `CO`, or `BU`; documentation plus
symbol for candidate rows resting on `candidate.RM` or `SP` alone. Falsifier: an
attended read of any safe row that wedges a core establishes that the retained
observation behind its tuple does not generalize to the running configuration.

## Bounded GART page-table reader

The GART reader exposes at most 64 hardware GART entries and two CPU page-table
rows through a root-only, read-only debugfs file, emitting a fixed 20-column
schema across 10 output paths. `rs400_gart_cpu_pat_index` selects `_PAGE_PAT` at
`PG_LEVEL_4K` and `_PAGE_PAT_LARGE` at `PG_LEVEL_2M` and `PG_LEVEL_1G`, so a
large-page bit cannot masquerade as a physical-address bit in an emitted row.
`rs400_gart_page_dma_address` decodes each entry to a DMA address.

The decode stops at backing. A non-dummy row reports that the entry has backing;
it does not report BO ownership, and closing that join needs a retained target
capture.

Source: `packaging/arch/radeon-unified-dkms/rs480-gart-page-table-readonly-debugfs.patch`
and `scripts/verify_rs400_gart_reader_schema.py`. Evidence class:
source-verified, with the schema and DMA round trips checked by the verifier.
Falsifier: a retained Vostro capture whose emitted rows disagree with the
verifier's schema, or in which a decoded address fails to round-trip.

## Bounded experiment space

The hazard surface is parameterized rather than open, which is what makes the
package a laboratory instrument instead of a driver with dangerous defaults. The
series declares 18 module parameters, and the defaults separate the read-only
evidence surface from the arming surface.

`radeon_rs480_safe_regs` and `radeon_rs480_candidate_regs` default to `1`. Both
expose read-only debugfs snapshots whose rows carry the evidence classification
above, so the open default costs a read of already-classified registers.

Every selector that arms a one-at-a-time hazardous read defaults to `-1`, a
no-selection sentinel: `radeon_rs480_force_clock_index`,
`radeon_rs480_force_clock_3d_index`, `radeon_rs480_frontier_index`,
`radeon_rs480_gated_read_index`, `radeon_rs480_hazard_index`, and
`radeon_rs480_vertex_index`. The guard reads
`idx < 0 || idx >= ARRAY_SIZE(...)`, so an index of `0` selects the first entry
and performs the read; only a negative value is inert.

The reset-mask selector resolves to a mask rather than to nothing.
`RS480_RESET_MASK_BASELINE` is `0`, so `rs480_reset_mask=0` selects the baseline
mask, named nonzero values select experimental masks, and an out-of-range value
collapses to baseline. A hazardous path therefore opens on a deliberate index or
mask write, and the closed state is whatever each declaration makes inert rather
than zero across the board.

The reset-mask candidates (patches 0063 through 0067) form a named table with
one-shot consume semantics: `cmpxchg` prevents a concurrent parameter write from
being lost while the selector reverts to BASELINE, and a `GUI_ACTIVE` check
covers every block a non-baseline mask resets while preserving the exact 0043
predicate for BASELINE and discrete parts.

Source: `steinmarder-r300` patch status table, rows 0063 through 0067. Evidence
class: compile-verified and installed at 0.3-83 for both the 6.18.34-lts and
7.0.11 kernels, and **not fired**. Efficacy is unproven. Falsifier: an attended
campaign that arms one non-baseline mask and records whether GA clears.

The SB600 watchdog is retired as a fire fuse. Fires 24 through 27 plus two benign
calibrations show that `WDIOC_SETTIMEOUT`, `WDIOC_KEEPALIVE`, and magic close do
not defer the real reset event, so the interface is not a deferrable dead-man
fuse for a multi-second GPU wedge. It remains platform substrate and fired-latch
support.

## Reproducible quantitative spine

Every number in this document comes from a command in this repository. The
following reproduce the full set on a host with a kernel build directory
present.

```sh
# 70 patches apply clean; source hashes and GART reader policy verified
bash scripts/verify_radeon_unified_dkms_sources.sh

# patch series applies and the touched translation units compile
sh scripts/check_radeon_patch_series_compiles.sh

# packaged sources match their recorded sha256sums
bash packaging/arch/radeon-unified-dkms/check_pkgbuild_sha256sums.sh
```

| Quantity | Value | Emitting source |
|---|---|---|
| Patches in the ordered series | 70 | `PATCH[]` entries in `dkms.conf` |
| Patch files held for the RS480 lane | 73 | `patches/rs480/*.patch` |
| Patch files held for the Palm lane | 9 | `patches/palm/*.patch` |
| Translation units the series touches | 13 | `check_radeon_patch_series_compiles.sh` |
| Safe-register rows | 82 | `rs480-safe-regs.tsv` |
| Candidate rows accepted | 24 | `generate_rs480_debugfs_fragments.py` via the source verifier |
| Candidate rows skipped, design-only attended | 6 | `generate_rs480_debugfs_fragments.py` via the source verifier |
| Candidate rows held in total | 30 | `rs480-candidate-regs.tsv` |
| Module parameters declared | 18 | `module_param` sites across the series |
| GART reader output paths | 10 | `verify_rs400_gart_reader_schema.py` |
| GART reader schema fields | 20 | `verify_rs400_gart_reader_schema.py` |
| GART hardware entries bounded per read | 64 | GART reader patch |

The verified run recorded here used kernel `7.1.4-1-cachyos`, and all three
checks passed with zero warnings. The installed evidence in the sibling findings
covers `0.3-83` on the 6.18.34-lts and 7.0.11 kernels, so the compile evidence
and the installed evidence come from different kernels and stay separate
classes.

## Open claims

Five properties remain unproven, and each names what would close it.

- GPU recovery after a failed reset. GA holds the wedge. Closing it requires an
  attended run in which `RBBM_STATUS` shows GA clearing.
- Display recovery without reboot. The parked GPU keeps a black or frozen
  display. Closing it requires a retained run in which KMS scanout returns.
- A parked device that refuses fresh client admission. The 0060 gate covers a
  re-faulted pre-park VRAM mapping, while a client opened after park still
  admits through `open(/dev/dri/renderD128)`. The create-path refusal
  `radeon_gem_object_create` returns -EIO under `gpu_parked` landed upstream in
  linux-radeon-gororoba (commit `ca70647`) and is absent from the pinned
  checkpoint, so no package here carries it. Closing it requires the source
  refusal pinned into a package, a retained run in which a fresh allocation and
  mmap fail closed, and a pre-park GTT-mapping discriminator cell that proves the
  refusal suffices rather than only removing the fresh-client supply.
- Attribution of the Fire 28 survival. The run changed both the 0060 gate and
  the client freeze and thaw procedure. Closing it requires a single-factor
  repeat.
- Every named nonbaseline reset-mask candidate introduced by 0063 and hardened
  through 0067. All are installed and none has fired. Patch 0068 carries a
  comment correction with no code delta, so it holds no mask verdict.

Until each closes, `radeon.lockup_timeout=0` stays the safe default and the
package is not an automatic reset-recovery driver.

## Assumption register

One statement in `AGENTS.md` is a project decision rather than a claim derived
from a source: the fixed priority order of host safety, containment, evidence
fidelity, recovery capability, and performance. It follows from the containment
framing in `README.md` and the `lockup_timeout=0` default, and no cited document
states it.

The maintainer ratified this ordering, so it governs conflicts as written. It
carries the authority of a project decision, and a reader looking for a silicon
or specification source behind it finds a maintainer choice instead. The
alternative orderings considered were the `mesa-26-gororoba` sequence of
conformance, standards, stability, and performance, which governs a userspace
conformance target rather than an out-of-tree kernel safety module, and an
evidence-first sequence that would rank the research-instrument role above the
host-safety role.
