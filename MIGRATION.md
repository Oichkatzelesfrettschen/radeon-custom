# Provenance and migration record

This repository consolidates the radeon DKMS work that was developed in place
across the steinmarder reverse-engineering trees. The originals remain as the
RE record; radeon-custom is the single build source going forward.

## Sources consolidated

| radeon-custom path | Origin |
| --- | --- |
| `patches/`, `sources/`, `scripts/`, `packaging/`, `docs/` | `steinmarder/src/re/radeon/` (the `radeon-unified-dkms` v0.3 corpus) |
| (folded into the unified series) | `steinmarder-r300/src/re/r300/PKGBUILDs/radeon-rs480-safe-regs-dkms/` -- rs480 safe-regs debugfs; the PKGBUILD here `replaces` it |
| (folded into the unified series) | `steinmarder/mesa-rekit/staged/radeon-palm-gate-dkms/` -- Palm gate (`mc_wait_for_idle` timeout, `pci_config_reset_safe`, SMX_DC_CTL0); `replaces`d |

Upstream reference tree (not vendored here; consult in place):
`steinmarder-r600-terakan/docs/external_sources/linux_6_18_32_radeon_drm/`.

## Excluded from the copy

Build artifacts (`packaging/*/pkg/`, `packaging/*/src/`, `*.pkg.tar*`) and the
bulk `docs/external_sources/` corpus were not copied; only the canonical plan
and readiness docs came over. Rebuild artifacts locally with `makepkg`.

## Key reset patches (the wedge fix)

- `patches/rs480/0003-rs480-crash-shim-recovery.patch` -- gpu_reset shim.
- `patches/rs480/0041`/`0042-rs480-rbbm-soft-reset-recovery-probe.patch` -- RBBM soft-reset probe.

These are the recoverable-reset mechanism for the `radeon_fence_default_wait`
hang class documented in
`mesa-26-gororoba/docs/hardware/vostro1000-kernel-modules.md`.

## Follow-ups

- Verify the PKGBUILD builds against the running cachyos 7.0.x kernel and the
  prepatched `radeon-rs480-cachyos-6.18-7.0` source tarball.
- Dedupe any overlap between the unified series and the folded staging
  packages (safe-regs patch 0001 already is the former `radeon-rs480-safe-regs`).
- Prove RS482 reset recovery before enabling a non-zero `lockup_timeout`.
