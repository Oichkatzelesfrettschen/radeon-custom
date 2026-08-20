---
canonical: false
status: historical
last_verified: 2026-05-28
scope: radeon DKMS patchset, packaging adapters, CachyOS Vostro, Debian/XanMod x130e
---

# Historical Radeon DKMS Unification Plan

This document preserves the retired patch-series transition design at its
2026-05-28 verification boundary. Root `README.md` owns the active package
architecture and qualification ledger. `linux-radeon-gororoba` owns the active
kernel source.

## Current State

Two radeon DKMS lanes exist and both are useful, but they must not remain
independent source trees.

| Lane | Existing path | Hardware | Kernel/package frontend | Status |
|---|---|---|---|---|
| Unified Arch DKMS | `src/re/radeon/packaging/arch/radeon-unified-dkms/` | Vostro 1000 RS482/RS485 now; Palm/Wrestler source carried for x130e alignment | CachyOS PKGBUILD | Source package is `radeon-unified-dkms 0.3-4`; builds on `6.18.32-1-cachyos-lts` and `7.0.9-1-cachyos`, owns modprobe and mkinitcpio drop-ins, and replaces the RS480 transition package. |
| Palm gate | `mesa-rekit/staged/radeon-palm-gate-dkms/` | x130e Palm/Wrestler | Debian/XanMod DKMS scripts | Built around `radeon-palm-gate-1.0`; carries bounded reset, `SMX_DC_CTL0`, perf-query scaffolding, and CS observer scaffolding. |

The new canonical root is:

```text
src/re/radeon/
|-- patches/
|   |-- rs480/
|   `-- palm/
|-- packaging/
|   |-- arch/radeon-unified-dkms/
|   `-- debian/radeon-unified-dkms/
`-- sources/
```

## Reconciliation Model

The kernel module is one upstream Linux `drivers/gpu/drm/radeon/` base
plus an ordered patch series.  Hardware-specific behavior is gated by
chip family and module parameters, not by maintaining unrelated source
trees.

| Patch family | Applies to | Default safety policy |
|---|---|---|
| 7.x compatibility | all supported builds | always on; preserves buildability across CachyOS LTS/main and future kernels. |
| `rs480_safe_regs` | RS400/RS480/RS485 | read-only debugfs; default exposed by module param but no writes. |
| `rs480_candidate_regs` | RS400/RS480/RS485 | read-only debugfs; default exposed for bounded register validation on RS482. |
| bounded MC wait reset | Evergreen/Palm reset paths | safe abort on busy MC; avoids wedge-class reset behavior. |
| Palm PCI reset gate | Palm/Wrestler | unsafe reset is refused unless `palm_pci_reset_unsafe=1`. |
| `SMX_DC_CTL0` allowlist | Evergreen CS validator | enables documented Terakan emission path; must stay tied to r600 evidence. |
| perf-query ioctl | Evergreen/TeraScale-2 | opt-in until uAPI and Mesa integration are finalized. |
| CS observer | Palm debugging | built or staged only when requested; runtime default disabled. |

## Upgrade Survival Contract

DKMS survives kernel upgrades only when the installed package owns a
coherent `/usr/src/<name>-<version>/` tree.

For CachyOS/Arch:

```bash
cd src/re/radeon/packaging/arch/radeon-unified-dkms
../../../scripts/verify_radeon_unified_dkms_sources.sh
tmp_srcdest=$(mktemp -d)
trap 'rm -rf "$tmp_srcdest"' EXIT
SRCDEST="$tmp_srcdest" makepkg -fC --verifysource --noconfirm
makepkg -Cf
sudo pacman -U ./radeon-unified-dkms-<version>-<pkgrel>-x86_64.pkg.tar.zst
dkms status
```

The Arch frontend aliases canonical sources with package-local names
that cannot collide with stale files in the packaging directory.  The
installed DKMS patch names stay stable, but `makepkg --verifysource`
must read the tracked `patches/rs480/` files, register tables, and
`sources/radeon-unified-0.3-source.tar.xz`.  The source verifier hashes
those canonical files directly; the temporary `SRCDEST` keeps makepkg
from reusing package-local source cache files.  A package archive built
before a policy or patch change is not evidence for the current source
tree; rebuild it before installing on RS482/RS485 hardware.

The RS482 DKMS policy exposes both register snapshots by default:
`rs480_safe_regs=1` for already-promoted safe registers and
`rs480_candidate_regs=1` for the bounded candidate list used to test
newly uncovered registers.  The runner still records an explicit
`R300_CANDIDATE_REGS_ACCEPTED=1` operator gate for retained bundles,
but the installed module must create the debugfs file at boot so normal
validation sessions can read the candidate list without rebuilding or
reloading radeon.

For Debian/XanMod:

```bash
sudo install -d /usr/src/radeon-unified-<version>
sudo cp -a src/re/radeon/packaging/debian/radeon-unified-dkms/. /usr/src/radeon-unified-<version>/
sudo dkms add -m radeon-unified -v <version>
sudo dkms build -m radeon-unified -v <version> -k "$(uname -r)"
sudo dkms install -m radeon-unified -v <version> -k "$(uname -r)"
sudo update-initramfs -u -k "$(uname -r)"
```

The package must install:

| File | Reason |
|---|---|
| `dkms.conf` | Names module, source location, build command, autoinstall policy. |
| source tarball or source generator | Recreates `drivers/gpu/drm/radeon/` for every kernel build. |
| patch series | Reviewable source of truth for every deviation from upstream Linux. |
| compiler wrappers | Package-owned compiler policy with validated clang/GCC selection plus optional ccache/plain-distcc chaining, without hard-coded host paths. |
| `/etc/modprobe.d/radeon-re.conf` | Package-owned Radeon module policy; no untracked local config drift. |
| `/etc/mkinitcpio.conf.d/radeon-unified.conf` | Pins `radeon` into early userspace without editing `/etc/mkinitcpio.conf`. |
| install/uninstall helper | Human entrypoint; DKMS remains the real kernel-upgrade hook. |

## RS482 Register Exposure Debt

The radeon DKMS lane now exposes enough RS482 register state to validate
new candidates, but the kernel-side surface still has deliberate
granularity debt:

| Debt | Current limit | Better mechanism |
|---|---|---|
| Candidate list scale | `CANDIDATE_REGS.tsv` now covers the config-aperture cohort, a mixed MMIO/MC GART complement (`AGP_BASE_2`, `GART_FEATURE_ID`, `GART_BASE`), and the first bounded RS482 Z-status cohort, but it still stops short of broader 3D-state coverage. | Promote generator output from the R300 register inventory into staged candidate cohorts keyed by block and hazard class. |
| Promotion metadata | Safe and candidate TSV rows remain canonical policy tables, so they still do not carry mutable bundle IDs or verdict history. | Keep the TSVs policy-only; emit per-bundle `register_observations.jsonl` records and aggregate them into a separate validation registry with bundle ID, boot ID, read count, hazard count, and verdict. |
| Debugfs granularity | `radeon_rs480_candidate_regs` remains as a compatibility alias for the config-aperture cohort, while the candidate debugfs surface now fans out into block-scoped files for `gart_mc`, `vap`, `ga`, `sc`, `gb`, `rb3d`, and `zb`. Display and RBBM stay on the safe-regs lane and are tracked per-block through the observation registry. | Keep adding block-scoped files so config, MC/GART, display, RBBM, and 3D registers can be validated independently. |
| Kernel table generation | `0001` and `0004` still embed C arrays, but the verifier now regenerates the arrays from TSV policy and compares them with the patches. | Move the patch source to generated fragments once the package root is patch-series-derived. |
| Hazard feedback | Runner dmesg scanning catches warnings after the read. | Attach the before/after dmesg window, boot ID, path, and register cohort name to each observation record before promotion. |
| RS485 aliasing | RS485 should share the RS482-safe register surface, but exposure docs still name the lane mostly through RS480. | Keep the kernel gate on `CHIP_RS400` and `CHIP_RS480`, but name retained evidence as RS482/RS485 where that is the hardware under test. |
| R300 block coverage | Current DKMS exposure focuses identity, PCI shadows, BIOS scratch, memory aperture, display, GPIO, the config cohort, a filtered MC/GART complement, and a first bounded Z-status candidate cohort. `ZB_HIZ_*` remains excluded because Mesa still models RS482 with no HiZ RAM and the retained zpass bundle showed no HiZ traffic. | Add staged cohorts for R300 GA/RB3D/VAP/SC/RBBM status registers that are already surfaced by the r300 findings and UMR bitfield work. |
| R500 baseline | R500 is no longer total negative space: the shared GA cohort already seeds `R500_GA_IDLE`, and `R500_DKMS_BASELINE.md` now captures the next exact GA/FG/RS/US/VAP/RB3D/ZB seed rows already present in the local corpus. | Promote that inventory into an R500 seed table only after read-side-effect classification and exact-hardware validation are available. |
| Package artifact proof | The source verifier catches stale canonical inputs before build, and `verify_radeon_unified_dkms_package.sh` now extracts a built Arch package to hash the installed `radeon-re.conf`, mkinitcpio drop-in, compiler wrappers, DKMS patches, and RS480 register tables against canonical inputs. | Extend the verifier to the expanded `usr/src/radeon-unified-*/radeon/` tree once the package root moves to a fully patch-series-derived source tarball. |

## What Remains

1. Replace the RS480-superset generated source tarball with a fully
   patch-series-derived tarball built from an explicit upstream Linux
   base plus `patches/{rs480,palm}`.
2. Convert the Debian/XanMod adapter to consume
   `sources/radeon-unified-0.3-source.tar.xz` or its next generated
   successor.
3. Verify the same package root on x130e Palm/Wrestler, especially the
   `palm_pci_reset_unsafe=0` default and the r600 stability patchset.
4. Remove compatibility wrappers in old paths after both machines verify
   DKMS autoinstall on a kernel update.
5. Extend the built-package verifier from package-owned configs, patch
   files, and RS480 register tables into the expanded
   `usr/src/radeon-unified-*/radeon/` tree once the package root stops
   depending on the retained superset tarball.

## Adversarial Checks

Before merging a radeon DKMS patch:

1. State which chip family it changes and which families it must not
   change.
2. Build on at least one CachyOS kernel and one Debian/XanMod kernel, or
   mark the missing kernel as an explicit gap.
3. Verify `modinfo -k <kernel> radeon` exposes the expected module
   parameters.
4. Verify the package-owned source tree is clean:
   `pacman -Qkk <pkg>` on Arch-family hosts, or a Debian package/file
   manifest comparison on Debian-family hosts.
5. Verify initramfs was regenerated for early KMS users.
6. Verify package-owned boot configuration: `pacman -Qo
   /etc/modprobe.d/radeon-re.conf /etc/mkinitcpio.conf.d/radeon-unified.conf`.
7. Verify unpromoted RS480/RS482/RS485 candidate registers are exposed
   at boot in `/etc/modprobe.d/radeon-re.conf`; retained candidate
   reads still use the explicit runner acceptance gate.
