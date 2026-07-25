# RS480 containment architecture and evidence decomposition

This document decomposes what the `radeon-unified` DKMS module does, which
silicon and host mechanisms force each design choice, and exactly how strong the
evidence behind each claim is. It exists so a reader outside this workspace can
regenerate every number, locate every source, and see which claims remain open.

`README.md` is the source of record for package contents and the promotion
ladder. `steinmarder-r300:src/re/r300/findings/rs480-reset-recovery-patch-status-table.md`
is the source of record for retained RS482 hardware verdicts. This document
cites both and duplicates neither.

Each load-bearing claim below carries four things: the claim, a named primary
source, an evidence class from the promotion ladder, and a falsifier for
anything standing below `hardware-pass`. A claim with no rank-1 through rank-4
source by name is marked hypothesis.

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

Source: `steinmarder-r300` patch status table, "Settled mechanism facts" and the
0043 row. Evidence class: hardware-run, partial. Falsifier: an attended run in
which GA clears from `RBBM_STATUS` after the 0043 ladder, or in which a host
survives a confirmed non-posted read against a wedged block.

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

Source: `steinmarder-r300` patch status table, rows 0056 through 0060. Evidence
class: hardware-pass for host survival under the Fire 28 procedure. Falsifier:
an attended repeat of the Fire 28 procedure in which `boot_id` changes or SSH
stops answering.

The achieved property is host survival alone. GPU recovery, display recovery,
and a demonstrated SIGBUS firing line each remain open, and Fire 28 does not
isolate the causal contribution of the 0060 gate from the client freeze and thaw
procedure it also changed. That attribution gap is a property of the run design,
so closing it requires a run that varies one factor.

## Register evidence partition

The package splits every register it reads into two tables with different
evidence requirements. This partition is the reusable research artifact, because
each row carries its own provenance rather than inheriting a blanket claim.

`rs480-safe-regs.tsv` holds 82 rows. A row qualifies as safe when it has no
documented write side-effect on read and a retained bundle shows the read
completing. Rows attribute to seven source classes, and the distribution shows
which evidence actually carries the table:

| Source class | Rows | What the code asserts |
|---|---|---|
| `RM,SP` and `SP,BU` and related symbol pairings | 23, 23, 3 | Public kernel or xorg symbol plus a register-manual or blind-read confirmation |
| `RT,RM,SP` | 23 | `radeontool` output, regmatch, and a public symbol agree |
| `SP,HR` | 22 | Symbol plus hazard-read observation, all 22 reads completed with no core wedge |
| `SP,FO` | 3 | Symbol plus attended frontier-probe read with heartbeat advancing |
| `SP,CO` | 3 | Symbol plus candidate-node observation at `hazard_count=0` with `boot_id` stable |
| `RM` alone | 4 | Register-manual text only |
| `RT,RM` | 1 | Tool output plus manual, no public symbol |

Every source class names a retained bundle in the file header, including
`rs480_0019_pll_hazard_live_read_20260609T172724Z` for the hazard-read class and
`cachyos_vostro1000_rs482_attended_frontier_combined_read_sweep_20260615T065527Z`
for the blind userspace readout, which recorded 116 of 116 reads done with zero
quarantine and a stable `boot_id`.

`rs480-candidate-regs.tsv` holds 30 rows that are explicitly not safe: 28 reached
through BAR0 MMIO offsets with `RREG32()`, and 2 through the RS400/RS480 MC
indirect index with `RREG32_MC()`. They are bounded candidates for one-at-a-time
live read validation. The source verifier promotes 24 of them and skips 6 that
sit in design-only attended cohorts, which is the mechanism that keeps an
unvalidated candidate out of the safe path.

Source: the two TSV files and their header legends;
`scripts/verify_radeon_unified_dkms_sources.sh` emits the accepted and skipped
counts. Evidence class: hardware-run for rows carrying `RT`, `HR`, `FO`, `CO`,
or `BU`; documentation-only for rows carrying `RM` or `SP` alone. Falsifier: an
attended read of any `RM`-only row that wedges a core establishes that
register-manual text alone does not license the safe classification.

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
module exposes 18 parameters, and every hazardous one is closed at zero.

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
| Candidate rows accepted | 24 | `verify_radeon_unified_dkms_sources.sh` |
| Candidate rows skipped, design-only attended | 6 | `verify_radeon_unified_dkms_sources.sh` |
| Candidate rows held in total | 30 | `rs480-candidate-regs.tsv` |
| Module parameters exposed | 18 | `module_param` sites across the series |
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
- A demonstrated SIGBUS isolation firing. The 0060 gate is installed and armed,
  and `docs/rs480-0060-sigbus-dominance-proof.md` argues static dominance, but
  no firing line is retained. Closing it requires a retained run in which a
  client re-faults a zapped VRAM mapping and receives SIGBUS.
- Attribution of the Fire 28 survival. The run changed both the 0060 gate and
  the client freeze and thaw procedure. Closing it requires a single-factor
  repeat.
- Every non-baseline reset-mask verdict for 0063 through 0068. All are installed
  and none has fired.

Until each closes, `radeon.lockup_timeout=0` stays the safe default and the
package is not an automatic reset-recovery driver.

## Assumption register

One statement in `AGENTS.md` is a project assumption introduced by this
workspace rather than a claim derived from a source: the fixed priority order of
host safety, containment, evidence fidelity, recovery capability, and
performance. It follows from the containment framing in `README.md` and the
`lockup_timeout=0` default, and no cited document states it. It stands as a
stated assumption open to correction.
