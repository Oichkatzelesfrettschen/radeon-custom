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

`linux-radeon-gororoba` is the canonical kernel source. This repository is the
deployment and package authority. It owns the signed source pin, Arch and
CachyOS package, DKMS glue, compiler policy, initramfs and modprobe policy,
hazard preflight, and package verification.

Mesa userspace lives in `mesa-26-gororoba`. Retained RS482 probes, logs, result
bundles, falsifiers, and hardware verdicts live in `steinmarder-r300`.
Historical patch files and source snapshots in this repository remain
provenance. The active package does not consume them.

## What this repository proves and what it does not

The live package manifest proves which mechanisms are present in the built
module. It does not by itself prove those mechanisms worked on silicon.

| Property | Current status |
| --- | --- |
| Unified DKMS package 0.3-96 exports the signed legacy-equivalent driver tree under deployment modes 0644 and 0755, composes trusted KCFLAGS, and resolves the trace include inside the private DKMS build tree | package export, 6.18 and 7.1 compile, and the disposable DKMS lifecycle on 7.1.4-1-cachyos are CI-verified; installed and runtime-accepted on the RS482 target across a boot with matching module srcversion, `lockup_timeout=0`, and inert hazard interfaces, retained as steinmarder-r300 bundle `cachyos_vostro1000_rs482_radeon_unified_pkgrel96_runtime_20260730T233253Z`; hardware operation beyond debugfs inventory is not run |
| Earlier package revisions install on the recorded CachyOS kernels | installed; hardware evidence remains mechanism- and bundle-specific |
| Failed-reset host-survival containment through park and client thaw/close | hardware-pass in retained RS482 Fire 28 evidence |
| RS482 GPU resumes accelerated work after reset | not achieved; GA-rooted wedge remains |
| Display scanout recovers without reboot | not achieved |
| 0060 SIGBUS isolation gate fires | unverified; installed but not exercised in the retained pass |
| 0063-0067 non-baseline reset masks (0068 is a comment-only grammar fix) | implemented, compile-verified, installed in earlier revisions, and not fired |
| Bounded RS480 GART page-table reader | source-verified; exact-target rows require a retained Vostro capture |

Therefore `radeon.lockup_timeout=0` remains the safe default. Do not describe the
package as an automatic reset-recovery driver and do not enable a nonzero timeout
until an attended RS482 run demonstrates GPU recovery, not merely host survival.

The authoritative per-patch hardware verdict is
`steinmarder-r300:src/re/r300/findings/rs480-reset-recovery-patch-status-table.md`.
The package and patch order are authoritative here.

## Unified package

The primary package is `packaging/arch/radeon-unified-dkms/`.

- `source-identity.toml` pins the signed source commit, tag object, driver tree,
  and equivalence proofs.
- `PKGBUILD` exports the pinned driver subtree with `git archive`, installs the
  exact bytes under `/usr/src`, and rebuilds the boot initramfs after
  installation.
- `dkms.conf` builds the exported source directly. It declares no patch phase.
- `patches/rs480/` preserves the chronological migration evidence. The active
  package consumes no patch file.
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

- `patches/` holds historical kernel changes and generated patch material.
- `sources/` holds historical source snapshots used by migration proofs.
- `migration/input/` holds immutable legacy constructor declarations.
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
  `docs/migration-oracle-0.3-91-exact-context-manifest.tsv` is the per-file
  reference the replacement is proven against, while
  `docs/legacy-payload-0.3-90-default-fuzz-manifest.tsv` preserves what the
  default-fuzz constructor produced before the exact-context correction. Every manifest under `docs/` uses the
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
# PKGBUILD sha256sums match package-owned inputs
bash packaging/arch/radeon-unified-dkms/check_pkgbuild_sha256sums.sh

# Verify the signed source pin and package-owned inputs
bash scripts/verify_radeon_unified_dkms_sources.sh \
  --source-repository /path/to/linux-radeon-gororoba

# Build the pinned export against each retained kernel root
sh scripts/check_radeon_tagged_source_compiles.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --kernel-build-root /path/to/6.18-build-root
sh scripts/check_radeon_tagged_source_compiles.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --kernel-build-root /path/to/7.1-build-root

# Both recipes preserve admitted non-conflicting root-build KCFLAGS and enforce
# the package-owned -O2 -pipe release profile. Duplicate -O2 or -pipe and
# root-build optimization tokens other than -O2 fail before make runs. Quoted
# KCFLAGS tokens and control whitespace fail admission; the DKMS command
# separately preserves a kernel build-root pathname containing spaces.
bash scripts/test_radeon_dkms_kcflags_composition.sh

# Run the unprivileged closed-payload verifier first, and use only a package
# built from a reviewed, clean repository commit. It checks package metadata,
# archive ownership and member types, directory modes, the complete namespace,
# and the exact signed Radeon source export.
verifier_output=$(bash scripts/verify_radeon_unified_dkms_package.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --package /path/to/package)
printf '%s\n' "$verifier_output"
package_digest=$(printf '%s\n' "$verifier_output" |
  sed -n 's/^package_sha256=//p')
RADEON_UNIFIED_SOURCE_REPOSITORY=/path/to/linux-radeon-gororoba \
  bash scripts/test_radeon_dkms_package_verifier.sh /path/to/package

# One trusted package completes disposable add, build, install, metadata, and cleanup
sudo install -d -m 0755 -o root -g root \
  /var/lib/radeon-dkms-lifecycle-evidence
sudo bash scripts/test_radeon_dkms_lifecycle.sh --package /path/to/package \
  --expected-sha256 "$package_digest" \
  --kernel-release "$(uname -r)" \
  --evidence-dir /var/lib/radeon-dkms-lifecycle-evidence/new-run

# Project-authored prose carries no dash construction
python3 scripts/check_project_prose_style.py
```

Each verdict-producing gate calibrates against known-good and known-bad inputs
before it is trusted to judge the tree. Run the calibration when changing a
gate:

```bash
# 5 known-bad inputs rejected, 2 known-good inputs cleared
sh scripts/check_radeon_patch_series_compiles.sh --self-test

# wrong tree and malformed source identities fail
python3 scripts/check_radeon_source_pin.py --self-test

# clean and allowlisted logs pass, an unapproved warning fails
sh scripts/check_radeon_tagged_source_compiles.sh --self-test

# known-good prose silent, known-bad prose reported, corpus selection correct
python3 scripts/check_project_prose_style.py --self-test

# 4 mode encodings correct, 6 manifest drift classes detected
sh scripts/emit_source_tree_manifest.sh --self-test

# 6 decomposition properties, 2 closing maps, 24 failure classes
python3 scripts/check_base_delta_map_closure.py --self-test
```

Build the active Arch package from `packaging/arch/radeon-unified-dkms/` with
the intended kernel trees available:

```bash
# keep the shell at the repository root for the checks below
RADEON_UNIFIED_SOURCE_URL=git+file:///path/to/linux-radeon-gororoba \
  makepkg -D packaging/arch/radeon-unified-dkms -fC --noconfirm
```

After package artifacts exist, verify each payload and its executable modes
against the canonical inputs:

```bash
bash scripts/verify_radeon_unified_dkms_package.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --package /path/to/radeon-unified-dkms.pkg.tar.zst
```

Optional runtime check on a live host (module loaded from the unified package):

```bash
bash scripts/check_radeon_unified_runtime_policy.sh
```

A successful build or install may promote a claim only to `compile-verified`
or `installed`; promotion to `hardware-run`, `partial`, `hardware-pass`, or
`refuted` requires a retained target-silicon result bundle.

## Cross-repository contract

- `linux-radeon-gororoba` owns modified kernel source, register policy inputs,
  source history, and source-equivalence attestations.
- `radeon-custom` owns package contents, source pins, dependencies, DKMS glue,
  deployment policy, and safe defaults.
- `steinmarder-r300` owns RS482 probes, evidence bundles, falsifiers, and hardware
  verdicts.
- `mesa-26-gororoba` owns r300g/r3v userspace behavior and the cross-repository
  integration index at `docs/hardware/rs482-source-authority.md`.
