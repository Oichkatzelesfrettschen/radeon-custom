# RS482 Vostro safety and forensic posture

This document records the current RS482 Vostro 1000 operating posture for the `radeon-custom` DKMS lane. It is the install-side contract for the radeon reset and register-hazard work. The GPU-hazard authority remains `steinmarder-r300`; this repository owns the packaged kernel module and the package-owned `radeon-re.conf` runtime policy.

## Current timeout policy

`radeon.lockup_timeout=0` is the active policy for RS482 hardware testing.

The timeout stays at zero because the RS482 reset path is unresolved. A timeout-driven reset on a wedged ring exercises the documented full-reset-on-wedged-ring hazard class. That class is prevention-only on this board until the reset sequence is root-caused. The package therefore preserves the fault state for inspection instead of invoking timeout-driven self-reset.

The installed policy lives in `packaging/arch/radeon-unified-dkms/radeon-re.conf`. The Arch package checksum in `packaging/arch/radeon-unified-dkms/PKGBUILD` must match that file. A config change without the checksum update is not a valid install artifact.

## Persistent capture paths

`ramoops` is not a survivor on this K8 board. Real panic testing shows pstore empty after reset because the platform clears DRAM across reset. Treat `ramoops` as unavailable for RS482 Vostro forensics.

`kdump` is the panic-class survivor. The crash kernel is the path that retains `vmcore` data after a panic-class failure. Panic breadcrumbs from the radeon DKMS lane target kdump, not pstore.

The CPU1 out-of-band heartbeat is the first-line wedge classifier. It is pinned away from the test CPU and reads only PCI configuration `STATUS`, then fsyncs every two seconds. If the heartbeat advances while the GPU test stops, the failure is GPU-local or driver-local. If the heartbeat stops, the failure reaches the K8 northbridge or both-core stall class.

The on-box poller remains the ordinary soft-hang recorder. During GL tests it records fence state, GEM state, RS480 safe-register state, GART status, GPU temperature, dmesg tail, and the watched test PID stack to durable disk.

`netconsole` remains secondary until delivery is verified. It is useful only after the receiving-host path is proven.

## Hazard governance

`steinmarder-r300/hazard_policy.json` gates hazardous hardware operations. Do not issue a hazardous reader, reset probe, or live-fire register operation unless the matching explicit environment gate is set and `make r300-hazard-check` passes in the hazard-authority repository.

The global RS480 GART snoop route is a refuted configuration. The canonical exact-target record lives at `steinmarder-r300:src/re/r300/findings/resolved/canonical/2026-06-21-rs482-global-gart-snoop-gart-binding-outcome.md`. Commit `2433cbd69cd99d1dd002447bb4d481ed66141562` is historical refuted-snoop evidence. At that source identity, `drivers/gpu/drm/radeon/rs400.c:181-186` writes `RS480_REQ_TYPE_SNOOP_DIS` unconditionally. The active package pin is commit `ec5b88802441720b0b972b1b2a92e53171094f31`, recorded in `packaging/arch/radeon-unified-dkms/source-identity.toml`. The active package runtime policy rejects `radeon-snoop-experiment.conf`, `rs480_gart_snoop`, and `rs480_atomic_rmw_report` before experiment allowlist handling. `RADEON_GART_PAGE_SNOOP` is declared at `drivers/gpu/drm/radeon/radeon.h:604`, and `radeon_ttm_backend_bind` adds it for `ttm_cached` buffer objects at `drivers/gpu/drm/radeon/radeon_ttm.c:420-446`. The cached-GTT request remains a separate per-PTE visibility question.

These commands run from the source repository and reproduce the historical source joins:

```sh
git grep -n RS480_REQ_TYPE_SNOOP_DIS 2433cbd69cd99d1dd002447bb4d481ed66141562 -- drivers/gpu/drm/radeon
git grep -n 'radeon_ttm_backend_bind\|RADEON_GART_PAGE_SNOOP' 2433cbd69cd99d1dd002447bb4d481ed66141562 -- drivers/gpu/drm/radeon
```

Gates such as `R300_SAFE_REGS_ACCEPTED=1` are affirmative consent gates. Unset, empty, or zero-valued gates are closed.

`rbbm_status_monitor.py` is part of the capture posture. It decodes the active block state so a hang report identifies whether the CP, VAP, GA, RB3D, or another block holds the failure signature.

## Posture discrepancy

There is a live policy discrepancy between GPU-hazard inspection and platform auto-reboot recovery. `steinmarder-r300` records the GPU bring-up position: hang-for-inspection beats auto-reboot. The `vostro1000-re` installer enables panic/reboot sysctls for broader platform recovery. For GPU hazard work, `steinmarder-r300` is the authority until the posture is reconciled explicitly.

## GL test gate

No OpenGL hardware test runs while the live module reports `radeon.lockup_timeout=20000`. Hardware GL work begins only after rebooting into the packaged `radeon.lockup_timeout=0` policy and confirming the poller plus CPU1 heartbeat are running.

OpenGL-from-r3v remains the userspace fix lane. The expected Mesa-side reduction compares the proven r3v Vulkan draw submission against the r300 GL clear/draw path, especially HyperZ, zmask, hiz, cmask, and CBZB fast-clear state that the r3v draw path does not emit.
