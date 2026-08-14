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

Each row preserves the qualification state of its package. The newest
successfully deployed package row supersedes an older deployment authority
statement. A newer recipe without installation evidence does not. Three
version axes remain distinct: 0.8.1-4 is the active source pin, package
recipe, and installed production deployment, 0.8.2-1 is a local-only
allocator-debugfs package candidate, and 0.6-1 carries the latest retained
parked device behavior verdict.

<!-- markdownlint-disable MD013 -->

Rows naming 0.8.1-3 below describe the prior recipe and its qualification
record. The 0.8.1-4 row is the current recipe record.

| Property | Current status |
| --- | --- |
| Radeon DKMS package 0.4-3 exports the protected profiled source as conflicting production and development packages plus the separate radeon-rs482-policy board package, binds each module to a fixed build profile, keeps the development runtime profile off, and admits the board policy on the RS482 Vostro 1000 alone | closed payloads, dual-kernel builds, disposable lifecycles, and the pacman transition matrix are CI-verified; the signed production and board-policy packages are installed and runtime-accepted on the RS482 target across a reboot with matching module srcversion, the prod profile, no development interface, and lockup_timeout=0, retained as steinmarder-r300 bundle cachyos_vostro1000_rs482_radeon_unified_pkg043_production_runtime_20260801T031411Z; hardware operation beyond ordinary modesetting and ring/IB initialization is not run |
| Radeon DKMS package 0.5-1 pins the signed `radeon-unified-0.5-profiled-source` checkpoint (tag object b6d737acd0a03657bfd60ce0a9ccbe5438a7102d, driver tree 20eacccb61205fd1476d3c915f95cbe2b12d272e) across the production, development, and radeon-rs482-policy package identities | source pin, closed payloads, dual-kernel builds, disposable lifecycles, and the pacman transition matrix are CI-verified; the three 0.5-1 artifacts are detached-signed in the `radeon-unified-release` namespace and durably retained (`docs/radeon-unified-0.5-1-release-attestation.toml`); the signed production and board-policy packages are installed and runtime-accepted on the RS482 target across a reboot with loaded srcversion 31F533E702034AA5546BF48 bonded to source commit 1b1f515d300f6590eb822c3e8a127e8dfc9a9abb, the prod profile, no development interface, and lockup_timeout=0, retained as steinmarder-r300 bundle cachyos_vostro1000_rs482_radeon_unified_0.5-1_prod_runtime_20260803T010326Z; the signed 0.4-3 set is the rollback baseline, and 0.6-1 later superseded 0.5-1 as the installed production authority while 0.5-1 became a rollback authority; a later attended campaign installed the development package and selected mutate-dev on the target to fire the 0060 SIGBUS refault cell (retained as steinmarder-r300 bundle `rs480_sigbus_refault_fire_rs482_20260803T030621Z`), so development installation is exercised there while RAD-06 ioctl replay and lockup recovery are not run |
| Radeon DKMS package 0.5-2 is a merged source pin that reached no artifact | superseded before artifact production by 0.6-1; its `radeon-unified-0.5-2-profiled-source` tag is annotated and unsigned, which `check_radeon_source_pin.py` now rejects, and the pin is retained as audit evidence of the superseded intermediate. No 0.5-2 package was built as release bytes, signed, published, installed, or promoted |
| Radeon DKMS package 0.6-1 pins the signed `radeon-unified-0.6-profiled-source` checkpoint (tag object 7a011a561c38258180e1f3083a0e5d8e74f5c1dd, driver tree 84b3c5c0282bf37236f2c4fda80eb17048bdd1ed) and carries the parked-device entry contract, under which `radeon_gem_object_create`, `radeon_gem_prime_import_sg_table`, and `radeon_gem_wait_idle_ioctl` each return -EIO once `gpu_parked` latches, before the allocation or the HDP MMIO flush they precede | source pin, signed-tag signer verification, closed payloads, dual-kernel builds in both profiles, both disposable DKMS lifecycles on both kernel lines, and the pacman transition matrix all pass against the exact archives; `check_parked_admission_guards.py` proves the three refusals against known-bad mutations and its own fixtures; the three 0.6-1 artifacts are detached-signed in the `radeon-unified-release` namespace against the byte-identical 0.5-1 allowed-signers file and durably retained (`docs/radeon-unified-0.6-1-release-attestation.toml`), with per-kernel module identity recorded at build time. Transition row 9 rolls production back to the exact signed 0.5-1 archive, which the 0.5-1 release recorded as not run; row 11 hazard-stack survival is not run on the build host because `sp5100-tco-ioapic-dkms` has no constructor here and no artifact there. The signed production and board-policy archives are transported, signature-verified on the target, target-compiled through DKMS against 7.1.3-2-cachyos and 6.18.38-2-cachyos-lts from the extracted signed archive, installed in one pacman transaction, and runtime-accepted across a reboot on 7.1.3-2-cachyos with loaded srcversion EA8E3BBBBA9E5580BDA7553 bonded to source commit 7a8dfb50cc4861ebd2c33a2d96cd19f961443c8e, the prod profile, no development interface, and lockup_timeout=0; the initramfs `radeon.ko.zst` digest equals the installed module and every Limine entry matches the BLAKE2b-512 hash it carries, retained as steinmarder-r300 bundle `cachyos_vostro1000_rs482_radeon_unified_0.6-1_prod_admission_20260804T232250Z`. The srcversion holds across two hosts and two kernel lines, so the target preflight rests on a measured kernel-independence property. The LTS line is compile-verified on target hardware rather than hardware-run because the single reboot booted the default 7.1.3-2-cachyos entry, and the target keeps `sp5100_tco` unloaded with no watchdog device, so the hazard stack shows package survival across the swap. Signed 0.6-1 is the installed production authority and the signed 0.5-1 set the rollback authority alongside 0.4-3. The rollback path is executed: `0.6-1 -> 0.5-1 -> 0.6-1` against the exact signed archives across three boot IDs, each direction reproducing the module bytes its earlier install produced, retained as steinmarder-r300 bundle `cachyos_vostro1000_rs482_radeon_unified_0.6-1_rollback_exercise_20260805T004529Z`, whose on-target rollback store now carries both 0.5-1 archives with signatures that verify from target material alone. The development package is installed on the target and its profile selector is exercised through an `off`, `observe-dev`, `off` cycle, which measures the canonical selector, the host modprobe configuration, the active initramfs, and the Limine content hash reaching early boot, retained as `cachyos_vostro1000_rs482_profile_dev_boot_propagation_20260805T042717Z`. The parked-device entry-contract harness is calibrated on live silicon, retained as `cachyos_vostro1000_rs482_parked_entry_contract_calibration_20260805T041150Z`. The entry contract is hardware-pass on RS482: an attended mutate-dev park latched `gpu_parked`, after which fresh native GEM creates (VRAM and GTT), USERPTR creation, and foreign PRIME import each returned -EIO with `radeon_bo_create` counting zero, post-park CS submission returned -EBUSY before parser entry, `WAIT_IDLE` returned -EIO, the pre-park VRAM mapping took SIGBUS, and the pre-park GTT mapping completed, retained as steinmarder-r300 bundle `cachyos_vostro1000_rs482_parked_entry_contract_matrix_20260805T055406Z`. The dumb-create path refused before allocation but userspace received ENOMEM because `radeon_mode_dumb_create` collapses every `radeon_gem_object_create` failure to -ENOMEM; the HDP-flush half of the wait-idle guard is a non-claim on RS482 because `rs400_asic` leaves `mmio_hdp_flush` NULL. The same run showed that an orderly warm reboot fails to reclaim a parked host: the network left and only a physical cold power cycle restored production, so a park costs physical recovery capability, and the earlier Mesa R-state spin stays unreproduced with its actor unknown |
| Radeon DKMS package 0.7-1 pins the signed `radeon-unified-0.7-profiled-source` checkpoint at source commit `293a4ae3fe82cd03585ef3157e82b0b59b641b47` and driver tree `d57a22ad5356637d7075cb2aba83e22af71f7bfb` | the signed package attestation, package gates, dual kernel builds, disposable lifecycles, and package transition matrix pass; a sealed read only target bundle joins installed package version 0.7-1, DKMS source 0.7, the installed module bytes, loaded srcversion `A7F72BE636B52D7EED42415`, loaded GNU build ID `a5f1ae7e6e040b20c53278d2978ea7a17a29b696`, source commit, driver tree, and PCI `1002:5974`. The capture does not bind the installed files to the signed release archive bytes. The module exposes `prod` and zero development parameters on kernel `7.1.3-2-cachyos`. Boot initialization records successful ring and indirect buffer tests. A broad warning filter retains 381 lines from firmware, ACPI, ATA, module taint, Radeon BIOS mapping, Broadcom b44 DMA, and Intel wireless paths; the count does not affect the identity joins and the result makes no warning free boot claim. The capture runs no controlled workload and establishes no conformance, reset, register, performance, or silicon safety verdict. The evidence lives in steinmarder-r300 bundle `cachyos-vostro1000-rs482-radeon-unified-0.7-1-production-identity` |
| Radeon DKMS package recipe 0.8.1-3 pins the signed `radeon-unified-0.8.1-profiled-source` checkpoint at source commit `ec5b88802441720b0b972b1b2a92e53171094f31` and driver tree `6fd8d3c6ec245c31f195ef86c15fadf5e206642d` | source pin verification, split package profile checks, package-input checksum verification, and source/profile self-tests pass at the packaging commit. Hosted gate run `31467145067` records production archive SHA256 `148dc5fccaa4c15b7f39dcbf23f70b49c049d36c492376aa75c39f85e4d21879` and development archive SHA256 `832f5a0e014ae514db65f8f318efb96ffd95c6b673df4aaec44636fed133a822`; both disposable DKMS lifecycles pass on `7.1.6-1-cachyos`. The transition gate passes the supplied production, development, and RS482 policy rows. Legacy rollback row 9 is not run because no legacy package is supplied, hazard-stack row 11 is not run because no hazard or watchdog packages are supplied, and kernel rows are not run because `--with-kernel` is omitted. The repository carries no 0.8.1-3 release signature, package installation record, loaded module identity, controlled workload, or silicon verdict. At that qualification point, version 0.8.1-3 is the active package recipe and target compile authority, while version 0.7-1 remains the loaded production authority |
| Radeon DKMS package recipe 0.8.1-4 closes the inherited Kbuild environment and package-controlled Make assignment boundary | local source pin, profile, checksum, composition, package verifier, and pinned-source compile gates pass; GNU Make 4.4.1 and the CachyOS package `make` 4.4.1-3.1 are current on the build workstation and the RS482 target, so no package update or CMake migration is part of this change. The final archives have SHA256 values `5712a92f9937aad6f1e11525944648ef3376347c6ace65553c13a85fc7eaa362` for production, `28951fdb004cdd35b00cbd70ff2f6705673d666916120b0399fbfd13cdb7ed13` for development, and `451b411b81cb96e82ef66d67bef37ca4636d78d71473ade76bc7daf96f69ba13` for the RS482 policy. The production and policy archives install and rebuild DKMS for `7.1.3-2-cachyos` and `6.18.38-2-cachyos-lts`, then boot on the exact RS482 target with boot ID `3b33587b-f825-4698-82a0-2ad40b20b7f7`, loaded Radeon srcversion `E07FCCC3BAFFB29C7CFD36B`, successful ring and IB tests, initialized 512 MiB GART, and successful Radeon modesetting. The run keeps `lockup_timeout=0`, `no_wb=1`, and all hazard paths closed. This is an installed, hardware-run boot and modeset result. It does not establish performance, conformance, reset recovery, or hazardous-operation safety |
| Radeon DKMS package candidate 0.8.2-1 pins the local signed `radeon-unified-0.8.2-profiled-source` checkpoint at source commit `6407ae6ee1bdd23d64c0657cced20d3a03226b06` and driver tree `6f3e3d2e4aec146aa6cd491416668ee096b94bb8` | the candidate contains the central primary-minor registration of `radeon_vram_mm` and `radeon_gtt_mm` required for the bounded allocator observation. Its source tag verifies locally against the package-owned release allowlist and source-static run `31450360220` succeeded at the pinned commit. Exact local production, development, and policy archives pass archive QA, source-export verification, both profile builds against the declared 6.18.38-2 and 7.1.4 kernel roots, two disposable DKMS lifecycles on the local 7.1.6 root, and the disposable package-transition matrix. These are local build checks only: the tag is not published, no archive or detached package signature is retained as release evidence, and no target installation, reboot, allocator event, allocation-pressure trial, workload, or silicon verdict is claimed. It remains a local build candidate until publication and the separate release gates complete. |
| Unified DKMS package 0.3-96 is the retained target-runtime baseline | installed and runtime-accepted on the RS482 target across a boot with matching module srcversion, `lockup_timeout=0`, and inert hazard interfaces, retained as steinmarder-r300 bundle `cachyos_vostro1000_rs482_radeon_unified_pkgrel96_runtime_20260730T233253Z`; hardware operation beyond debugfs inventory is not run |
| Earlier package revisions install on the recorded CachyOS kernels | installed; hardware evidence remains mechanism- and bundle-specific |
| Failed-reset host-survival containment through park and client thaw/close | hardware-pass in retained RS482 Fire 28 evidence |
| RS482 GPU resumes accelerated work after reset | not achieved; GA-rooted wedge remains |
| Display scanout recovers without reboot | not achieved |
| 0060 SIGBUS isolation gate fires on a re-faulted parked VRAM mapping | hardware-demonstrated; a targeted RS482 refault fire returned SIGBUS on one SIGUSR1 re-touch of the park-zapped mapping (si_code BUS_ADRERR, breadcrumb `parked: SIGBUS on VRAM mmap fault`, boot_id stable), retained as steinmarder-r300 bundle `rs480_sigbus_refault_fire_rs482_20260803T030621Z`; the fire ran on the dev-profile module (srcversion D49F542C, mutate-dev), the 0060 gate hunks carry no build-profile conditional so the gate code is identical to the prod module, and park is reachable only through the armed dev reset node, so this is the only obtainable evidence |
| Fresh post-park client GEM admission fails closed | refuted on RS482; a fresh client is admitted through `open`, `GEM_CREATE`, and `GEM_MMAP` on the parked device, measured in steinmarder-r300 bundle `rs480_parked_gem_placement_discriminator_rs482_20260804T041115Z`. Containment on that path is carried by placement rather than by admission: the fresh VRAM request allocated in VRAM and took SIGBUS at the 0060 gate, and the fresh GTT request completed against system RAM. The create-path refusal `radeon_gem_object_create` returns -EIO under `gpu_parked` landed upstream in linux-radeon-gororoba (commit `ca70647`) and is absent from the pinned 0.5 checkpoint tree, so no package here carries it; it prevents no failure that fire observed. The refusal's silicon acceptance is now hardware-pass on the installed 0.6-1 tree: the attended park matrix measured fresh VRAM, GTT, USERPTR, and foreign PRIME requests each refused with -EIO before allocation (`radeon_bo_create` count zero), retained as steinmarder-r300 bundle `cachyos_vostro1000_rs482_parked_entry_contract_matrix_20260805T055406Z`, so 0.6-1 flips the 0.5 admit-and-contain behavior to refuse-at-entry |
| 0060 placement scoping holds under park | hardware-demonstrated; in the same discriminator fire a VRAM mapping held across the park took SIGBUS while a GTT mapping held across it completed its touch, with each placement measured by bracketing the create with `RADEON_INFO_VRAM_USAGE` and `RADEON_INFO_GTT_USAGE` rather than inferred from the requested domain. No client in the parked window returned `VM_FAULT_RETRY`, so the leaked `dma_resv` RETRY model is untriggered rather than supported, and the R-state spin recorded for an earlier fresh Mesa client is unreproduced with its actor unidentified |
| 0063-0067 non-baseline reset masks (0068 is a comment-only grammar fix) | implemented, compile-verified, installed in earlier revisions, and not fired |
| Bounded RS480 GART page-table reader | source-verified; exact-target rows require a retained Vostro capture |

<!-- markdownlint-enable MD013 -->

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
  default-fuzz constructor produced before the exact-context correction. Every
  manifest under `docs/` uses the
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

# Verify the protected source pin and package-owned inputs
bash scripts/verify_radeon_unified_dkms_sources.sh \
  --source-repository /path/to/linux-radeon-gororoba

# Build the pinned export against each retained kernel root
sh scripts/check_radeon_pinned_source_compiles.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --kernel-build-root /path/to/6.18-build-root \
  --profile prod
sh scripts/check_radeon_pinned_source_compiles.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --kernel-build-root /path/to/7.1-build-root \
  --profile prod
sh scripts/check_radeon_pinned_source_compiles.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --kernel-build-root /path/to/7.1-build-root \
  --profile all-dev

# Build each exact profile carried by a verified package artifact
sh scripts/check_radeon_packaged_source_compiles.sh \
  --package /path/to/radeon-unified-dkms-0.4-3-x86_64.pkg.tar.zst \
  --kernel-build-root /path/to/kernel-build-root \
  --profile prod
sh scripts/check_radeon_packaged_source_compiles.sh \
  --package /path/to/radeon-unified-dkms-dev-0.4-3-x86_64.pkg.tar.zst \
  --kernel-build-root /path/to/kernel-build-root \
  --profile all-dev

# Verify the split package identities and the runtime selector
python3 scripts/check_radeon_package_profiles.py
bash scripts/test_radeon_profile_dev.sh

# Exercise the pacman-level package transitions in a disposable pacstrap
# root: production install, production/development replacement in both
# directions, profile selection, the PreTransaction admission refusal while
# a development override survives, and override cleanup versus foreign
# retention at development removal. Requires root, pacstrap, and arch-chroot;
# module compilation stays in the DKMS lifecycle test.
# The script uses RUNNER_TEMP, TMPDIR, or /var/tmp by default. Pass --temp-root
# with an existing writable directory when a privilege boundary drops those
# environment variables.
sudo bash scripts/test_radeon_package_transitions.sh \
  --prod-package /path/to/radeon-unified-dkms-0.4-3-x86_64.pkg.tar.zst \
  --dev-package /path/to/radeon-unified-dkms-dev-0.4-3-x86_64.pkg.tar.zst

# Both recipes preserve admitted non-conflicting root-build KCFLAGS and enforce
# the package-owned -O2 -pipe release profile. Duplicate -O2 or -pipe and
# root-build optimization tokens other than -O2 fail before make runs. Quoted
# KCFLAGS tokens and control whitespace fail admission; the DKMS command
# separately preserves a kernel build-root pathname containing spaces.
bash scripts/test_radeon_dkms_kcflags_composition.sh

# Run the unprivileged closed-payload verifier first, and use only a package
# built from a reviewed, clean repository commit. It checks package metadata,
# archive ownership and member types, directory modes, the complete namespace,
# and the exact protected Radeon source export.
verifier_output=$(bash scripts/verify_radeon_unified_dkms_package.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --package /path/to/package)
printf '%s\n' "$verifier_output"
package_digest=$(printf '%s\n' "$verifier_output" |
  sed -n 's/^package_sha256=//p')
RADEON_UNIFIED_SOURCE_REPOSITORY=/path/to/linux-radeon-gororoba \
  bash scripts/test_radeon_dkms_package_verifier.sh /path/to/package

# Each trusted package completes disposable add, build, install, metadata, and cleanup
sudo install -d -m 0755 -o root -g root \
  /var/lib/radeon-dkms-lifecycle-evidence
sudo bash scripts/test_radeon_dkms_lifecycle.sh --package /path/to/package \
  --expected-sha256 "$package_digest" \
  --kernel-release "$(uname -r)" \
  --evidence-dir /var/lib/radeon-dkms-lifecycle-evidence/new-run

# Project-authored prose carries no dash construction
python3 scripts/check_project_prose_style.py

# The complete workflow surface uses exact approved action revisions
python3 scripts/check_github_action_pins.py

# The target artifact path admits one production package from a raw ZIP
python3 scripts/admit_target_gate_artifact.py --self-test

# The target artifact identity resolves across every workflow artifact page
python3 scripts/resolve_workflow_artifact_digest.py --self-test

# The target workflow binds the API digest through raw artifact admission
python3 scripts/check_target_artifact_workflow.py
```

Each verdict-producing gate calibrates against known-good and known-bad inputs
before it is trusted to judge the tree. Run the calibration when changing a
gate:

```bash
# 5 known-bad inputs rejected, 2 known-good inputs cleared
sh scripts/check_radeon_patch_series_compiles.sh --self-test

# Wrong tree and malformed source identities fail
python3 scripts/check_radeon_source_pin.py --self-test

# A production recipe that compiles development objects fails
python3 scripts/check_radeon_package_profiles.py --self-test

# Runtime selection defaults closed and mutation requires its preflight
bash scripts/test_radeon_profile_dev.sh

# clean and allowlisted logs pass, an unapproved warning fails
sh scripts/check_radeon_pinned_source_compiles.sh --self-test

# Profile policy drift and unapproved warnings fail
sh scripts/check_radeon_packaged_source_compiles.sh --self-test
sh scripts/check_radeon_packaged_source_compiles.sh --self-test --profile all-dev

# known-good prose silent, known-bad prose reported, corpus selection correct
python3 scripts/check_project_prose_style.py --self-test

# 4 mode encodings correct, 6 manifest drift classes detected
sh scripts/emit_source_tree_manifest.sh --self-test

# 6 decomposition properties, 2 closing maps, 24 failure classes
python3 scripts/check_base_delta_map_closure.py --self-test

# Exact action identities and required inputs pass, and 40 mutations fail
python3 scripts/check_github_action_pins.py --self-test

# One production package passes, and 21 archive admission classes fail
python3 scripts/admit_target_gate_artifact.py --self-test

# One paginated digest lookup passes, and 12 metadata classes fail
python3 scripts/resolve_workflow_artifact_digest.py --self-test

# One target workflow passes, and 13 digest-binding mutations fail
python3 scripts/check_target_artifact_workflow.py --self-test
```

Build the active Arch package from `packaging/arch/radeon-unified-dkms/` with
the intended kernel trees available:

`makepkg -D` resolves its directory after changing away from the invocation
directory, so a relative argument exits 1 with no diagnostic under makepkg
7.1.0. Pass an absolute path, and direct the build products outside the package
directory so the checked-in tree stays clean:

```bash
repo_root=$(git rev-parse --show-toplevel)
build_root=$(mktemp -d)
RADEON_UNIFIED_SOURCE_URL=git+file:///path/to/linux-radeon-gororoba \
  BUILDDIR="$build_root/build" \
  PKGDEST="$build_root/pkgdest" \
  SRCDEST="$build_root/srcdest" \
  makepkg -D "$repo_root/packaging/arch/radeon-unified-dkms" -fC --noconfirm
```

The exported driver source and the DKMS build tree together exceed a gigabyte,
so `build_root` belongs on a filesystem with that headroom. A quota-bounded
`tmpfs` reports `Disk quota exceeded` mid-archive and leaves a partial package
directory.

After both package artifacts exist, verify each payload and its executable
modes against the canonical inputs:

```bash
bash scripts/verify_radeon_unified_dkms_package.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --package /path/to/radeon-unified-dkms.pkg.tar.zst
bash scripts/verify_radeon_unified_dkms_package.sh \
  --source-repository /path/to/linux-radeon-gororoba \
  --package /path/to/radeon-unified-dkms-dev.pkg.tar.zst
```

Optional runtime check on a live host (module loaded from the unified package):

```bash
bash scripts/check_radeon_unified_runtime_policy.sh --self-test
bash scripts/check_radeon_unified_runtime_policy.sh --check-files
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
