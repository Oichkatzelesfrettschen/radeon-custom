# Provenance and migration record

This document records the historical consolidation of Radeon DKMS work from the
Steinmarder reverse-engineering trees. The originals remain part of the evidence
record. `linux-radeon-gororoba` owns the active kernel source, and
`radeon-custom` owns the source pin, package, deployment policy, and retained
migration inputs.

## Sources consolidated

| `radeon-custom` path | Origin and disposition |
| --- | --- |
| `patches/`, `sources/`, `scripts/`, `packaging/`, `docs/` | `steinmarder/src/re/radeon/` unified-DKMS corpus; migrated into the retained package and provenance tree |
| folded into the unified series | `steinmarder-r300:src/re/r300/PKGBUILDs/radeon-rs480-safe-regs-dkms/`; superseded package identity, retained as provenance |
| folded into the unified series | historical `radeon-palm-gate-dkms` staging tree; superseded package identity, retained as provenance |

The unified PKGBUILD provides/replaces the historical safe-regs and Palm package
identities and conflicts with the old DKMS packages. They must not be treated as
three independently maintained module sources.

Upstream reference trees are consulted in place and are not vendored wholesale
here. The signed source pin selects the active source repository commit. The
historical patch manifests preserve reconstruction provenance and do not define
the active package payload.

## Excluded from the migration

Build artifacts (`packaging/*/pkg/`, `packaging/*/src/`, `*.pkg.tar*`) and bulk
external-source corpora were not copied. Rebuild artifacts locally and keep
hardware result bundles in the evidence repository.

## Reset and containment series

The RS480 series contains several distinct mechanism classes:

- early instrumentation and crash-shim work, including 0003;
- 0040-0045 reset probes and the force-clock/soft-reset production path;
- 0046-0062 failed-reset parking and host-containment hardening;
- 0063-0068 bounded reset-mask candidates and review hardening.

Patch presence is not a recovery verdict. The reconciled retained result is:

- host-survival containment is achieved for the Fire 28 acceptance property;
- GPU recovery stays open: the GA-rooted wedge holds and the GPU stays parked;
- display recovery is not achieved and requires reboot;
- the 0060 SIGBUS gate is installed but was not shown firing;
- non-baseline 0063-0068 reset masks are installed but have not been fired.

Keep `radeon.lockup_timeout=0` until a retained attended run demonstrates actual
GPU recovery. The current evidence verdict is owned by
`steinmarder-r300:src/re/r300/findings/rs480-reset-recovery-patch-status-table.md`.

## Source-authority rules

- `linux-radeon-gororoba` is authoritative for active kernel source.
- This repository is authoritative for the signed source pin, historical patch
  contents and order, packaging, dependencies, and safe defaults.
- `steinmarder-r300` is authoritative for what executed on RS482 silicon and the
  verdict assigned to that run.
- `mesa-26-gororoba` is authoritative for r300g/r3v userspace behavior.
- `implemented`, `compile-verified`, `installed`, and `hardware-pass` are
  separate statuses and must not be collapsed.
- Palm/Wrestler and RS480/RS482 claims remain generation-scoped even when the
  mechanisms share one DKMS package.

## Follow-ups

- Keep the generated source tarball and both CachyOS build gates reproducible.
- Retain one manifest and one owner for every patch/package identity.
- Run each non-baseline reset-mask candidate only under a separately authorized,
  attended hardware campaign with off-box capture and the current preflight.
- Promote a reset claim only after the acceptance property is named and
  evidenced explicitly, whether that property is host survival, GPU recovery,
  display recovery, or the isolation gate.
