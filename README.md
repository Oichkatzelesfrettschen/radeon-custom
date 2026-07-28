# radeon-custom

Dedicated out-of-tree Radeon DRM/DKMS source for the RS480/RS482/RS485 and
Palm/Wrestler safety and reverse-engineering lanes.

The canonical registry of which kernel modules the Vostro 1000 runs (radeon,
snd-hda, sb600 watchdog, and the DKMS series this repo builds) lives in the
sibling Mesa checkout at
`../mesa-26-gororoba/docs/hardware/vostro1000-kernel-modules.md` (or the
equivalent path under that repository on the workstation). Treat that file as
the source of truth and update it when this repo changes the installed DKMS
`pkgrel` or patch series.

This repository is the single active kernel build source. Mesa userspace lives
in `mesa-26-gororoba`; retained RS482 probes, logs, result bundles, and hardware
verdicts live in `steinmarder-r300`. Historical Steinmarder package trees remain
provenance, not active build inputs.

Kernel source moves to `linux-radeon-gororoba`, and authority moves with it at
the source-pin cutover. Until that cutover this repository remains the
deployable authority and the source repository is a reconstruction candidate,
so deployment consumes what is built here. After cutover this repository owns
the Arch and CachyOS package, DKMS glue, compiler policy, initramfs and modprobe
policy, hazard preflight, the source pin, and package verification, while the
kernel source and its register policy tables answer to the source repository.

## What this repository proves and what it does not

The live package manifest proves which mechanisms are present in the built
module. It does not by itself prove those mechanisms worked on silicon.

| Property | Current status |
| --- | --- |
| Unified DKMS package builds and installs on the recorded CachyOS kernels | compile-verified and installed |
| Failed-reset host-survival containment through park and client thaw/close | hardware-pass in retained RS482 Fire 28 evidence |
| RS482 GPU resumes accelerated work after reset | not achieved; GA-rooted wedge remains |
| Display scanout recovers without reboot | not achieved |
| 0060 SIGBUS isolation gate fires | unverified; installed but not exercised in the retained pass |
| 0063-0068 non-baseline reset masks | implemented, compile-verified, installed, and not fired |
| Bounded RS480 GART page-table reader | source-verified; exact-target rows require a retained Vostro capture |

Therefore `radeon.lockup_timeout=0` remains the safe default. Do not describe the
package as an automatic reset-recovery driver and do not enable a nonzero timeout
until an attended RS482 run demonstrates GPU recovery, not merely host survival.

The authoritative per-patch hardware verdict is
`steinmarder-r300:src/re/r300/findings/rs480-reset-recovery-patch-status-table.md`.
The package and patch order are authoritative here.

## Unified package

The primary package is `packaging/arch/radeon-unified-dkms/`.

- `dkms.conf` is the ordered patch manifest.
- `PKGBUILD` generates and installs the canonical Radeon source tree used by
  DKMS and rebuilds the boot initramfs after installation.
- `patches/rs480/` contains RS480/RS482 instrumentation, reset experiments,
  failed-reset parking/containment, and bounded reset-mask candidates.
- `radeon_rs480_gart_page_table` exposes at most 64 hardware GART entries and
  two CPU page-table rows through a root-only read-only debugfs file. The
  reader selects the PAT bit by page-table level and emits a fixed 20-column
  schema. Decoded backing remains a DMA address, and non-dummy backing does not
  imply BO ownership, until independent target evidence closes those joins.
- Palm/Wrestler safety gates are carried in the same module package but remain a
  separate hardware-generation lane; Palm evidence does not validate RS482 and
  RS482 evidence does not validate Palm.

The older `radeon-rs480-safe-regs-dkms` and `radeon-palm-gate-dkms` package
identities were folded into the unified package. The PKGBUILD provides/replaces
them and conflicts with the superseded DKMS packages so there is one active
module source.

## Hazard stack and watchdog boundary

`packaging/arch/rs480-reset-hazard-stack/` installs the Radeon module under test,
the SB600 watchdog substrate, and a runtime preflight. The dependency records a
consistent machine configuration and the watchdog fired-latch fix; package
presence is not a safety verdict.

Active watchdog feeding is retired for RAD-05 fire timing. Retained calibration
shows the SB600 reset event is not deferred by `WDIOC_SETTIMEOUT`,
`WDIOC_KEEPALIVE`, or magic close, so the watchdog must not be represented as a
deferrable dead-man fuse for multi-second GPU wedges. Destructive runs rely on
explicit preflight, boot-persistent netconsole, retained manifests, and manual
recovery.

## Repository layout

- `patches/` holds ordered kernel changes and generated patch material.
- `sources/` holds the canonical source snapshots used to construct the DKMS tree.
- `scripts/` holds source generation, validation, and packaging helpers.
- `packaging/arch/radeon-unified-dkms/` is the active Arch DKMS package.
- `packaging/arch/rs480-reset-hazard-stack/` is the hazardous-run meta-package
  and preflight.
- `packaging/debian/` holds Debian-family packaging adapters that are retired.
  Packaging targets Arch and CachyOS alone, so the Debian adapters take no
  further work and are removed at the source-pin cutover rather than now. They
  carry the only constructor for the Palm perf-query and CS-observer material,
  which the Arch source and its patch chain never held, so deleting them ahead
  of that material's reconstruction would lose it.
- `docs/` holds package and readiness documentation; hardware run verdicts
  remain in `steinmarder-r300`.
  `docs/rs480-containment-architecture-and-evidence-decomposition.md` is the
  entry point: it decomposes the silicon substrate, the containment ladder, the
  register evidence partition, and the reproducible quantitative spine, and it
  states the evidence class and falsifier for each claim.
  `docs/legacy-source-tree-decomposition.md` measures the constructed source
  tree that a dedicated source repository replaces, and
  `docs/legacy-tree-a-manifest.tsv` is the per-file reference the replacement is
  proven against. Every manifest under `docs/` uses the
  `gororoba-source-tree-v1` schema that `scripts/emit_source_tree_manifest.sh`
  emits and that `linux-radeon-gororoba` shares.
- `ci/kernel-build-roots/` identifies each retained kernel build tree by its
  key-file hashes and records the release, originating package, and compiler
  each root carries. The local path of a root is a workspace fact and lives in
  an Actions repository variable.

## Build and validation

There is no top-level `Makefile`. Before packaging, run the scripted checks
from the repository root. Several checks source the PKGBUILD or use bash
arrays, so invoke them with `bash` rather than `sh`:

```bash
# PKGBUILD sha256sums match the patch files on disk
bash packaging/arch/radeon-unified-dkms/check_pkgbuild_sha256sums.sh

# Patch series applies and (when a kernel build dir is present) compiles
# (POSIX sh; uses repository-root packaging/, patches/, and sources/)
sh scripts/check_radeon_patch_series_compiles.sh

# Same gate in the mode a CI job uses: a missing kernel build dir becomes
# exit 5, so a green status means the touched units reached the compiler
sh scripts/check_radeon_patch_series_compiles.sh --require-compile

# Compile the pre-7.0 side of the radeon_gem.c LINUX_VERSION_CODE split against
# a retained 6.18 kernel build tree; ci/kernel-build-roots/README.md records
# how a root is prepared and which release this repository pins
sh scripts/check_radeon_patch_series_compiles.sh --require-compile \
  --kernel-build-root /path/to/6.18-build-root

# Unified DKMS source tree hashes and patch-chain apply dry-run
bash scripts/verify_radeon_unified_dkms_sources.sh

# Project-authored prose carries no dash construction
python3 scripts/check_project_prose_style.py
```

Each verdict-producing gate calibrates against known-good and known-bad inputs
before it is trusted to judge the tree. Run the calibration when changing a
gate:

```bash
# 5 known-bad inputs rejected, 2 known-good inputs cleared
sh scripts/check_radeon_patch_series_compiles.sh --self-test

# known-good prose silent, known-bad prose reported, corpus selection correct
python3 scripts/check_project_prose_style.py --self-test

# 4 mode encodings correct, 6 manifest drift classes detected
sh scripts/emit_source_tree_manifest.sh --self-test

# 2 decomposition properties, 1 closing map, 5 failure classes
python3 scripts/check_base_delta_map_closure.py --self-test
```

Build the active Arch package from `packaging/arch/radeon-unified-dkms/` with
the intended kernel trees available:

```bash
# keep the shell at the repository root for the checks below
( cd packaging/arch/radeon-unified-dkms && makepkg -f )
```

After a package artifact exists under that directory, verify its payload
against the canonical inputs:

```bash
# Requires a built radeon-unified-dkms-*.pkg.tar.* in the package directory
bash scripts/verify_radeon_unified_dkms_package.sh
```

Optional runtime check on a live host (module loaded from the unified package):

```bash
bash scripts/check_radeon_unified_runtime_policy.sh
```

A successful build or install may promote a claim only to `compile-verified`
or `installed`; promotion to `hardware-run`, `partial`, `hardware-pass`, or
`refuted` requires a retained target-silicon result bundle.

## Cross-repository contract

- `radeon-custom` owns kernel code, package contents, patch order, dependencies,
  and safe defaults.
- `steinmarder-r300` owns RS482 probes, evidence bundles, falsifiers, and hardware
  verdicts.
- `mesa-26-gororoba` owns r300g/r3v userspace behavior and the cross-repository
  integration index at `docs/hardware/rs482-source-authority.md`.
