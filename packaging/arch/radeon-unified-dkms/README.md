# Arch/CachyOS Radeon DKMS Adapter

This directory is the Arch-family packaging frontend for the canonical
`src/re/radeon/` DKMS patchset.

Current status:

| File | Meaning |
|---|---|
| `PKGBUILD` | Buildable CachyOS package frontend for `radeon-unified-dkms`. |
| `dkms.conf` | DKMS config that calls the package-owned compiler-policy wrapper and applies package-owned probe patches. |
| `pre-build.sh` | Trace-header staging plus compiler-policy logging. |
| `compiler-policy.conf` | Package-owned defaults for compiler family, compiler binary, ccache, and plain distcc. |
| `radeon-dkms-compiler-policy` | Validates and resolves the package-owned compiler/cache/distcc policy. |
| `radeon-dkms-compiler` | Generic CC wrapper used by DKMS builds; dispatches through the resolved compiler policy. |
| `radeon-dkms-ccache-*` | Family-pinned compatibility wrappers that reuse the shared compiler policy. |
| `radeon-re.conf` | Package-owned modprobe policy for RS482/RS485 reverse-engineering and stable boot defaults. |
| `radeon-unified-mkinitcpio.conf` | Package-owned mkinitcpio drop-in that appends `radeon` to `MODULES` for early KMS. |

The package builds the generated unified source tarball retained under
`src/re/radeon/sources/`.  The current tarball is based on the
RS480-tested CachyOS source because that is the verified superset for
this host; future changes should move toward an explicit upstream base
plus ordered patch application.  Do not add new Arch-only kernel fixes
here; add them to `../../patches/` and regenerate the frontend.

The `PKGBUILD` source aliases intentionally differ from the installed
DKMS filenames.  That keeps untracked files in this packaging directory
from shadowing the canonical inputs in `src/re/radeon/patches/rs480/`
and `src/re/radeon/sources/`.  Validate source integrity with a clean
temporary source cache after editing any package input:

```bash
../../../scripts/verify_radeon_unified_dkms_sources.sh
tmp_srcdest=$(mktemp -d)
trap 'rm -rf "$tmp_srcdest"' EXIT
SRCDEST="$tmp_srcdest" makepkg -fC --verifysource --noconfirm
makepkg -fC --noconfirm
../../../scripts/verify_radeon_unified_dkms_package.sh \
  ./radeon-unified-dkms-*.pkg.tar.zst
```

Existing `radeon-unified-dkms-*.pkg.tar.zst` files are build outputs,
not source authority.  Rebuild them after any `radeon-re.conf`,
compiler-policy, patch-series, register-table, or source-tarball change before installing
on RS482/RS485 hardware, then run the built-package verifier to prove the
Arch payload still matches the canonical package-owned configs, DKMS
patches, and RS480 register tables.

Compiler policy defaults to the target kernel's recorded compiler family,
uses `ccache` when present, and enables plain `distcc` only when
`RADEON_DKMS_DISTCC_HOSTS` is set.  Supported overrides are:

```bash
RADEON_DKMS_COMPILER_FAMILY=auto|clang|gcc
RADEON_DKMS_CLANG_BIN=clang-22
RADEON_DKMS_GCC_BIN=gcc
RADEON_DKMS_CACHE_MODE=auto|ccache|off
RADEON_DKMS_DISTCC_MODE=auto|plain|off
RADEON_DKMS_DISTCC_HOSTS='ALIENWARE/32,lzo x570-5600X3D/16,lzo localhost/2,lzo'
```

Pump remains intentionally unsupported in this DKMS lane because the build
consumes generated kernel headers and per-kernel ABI state.

The installed DKMS default exposes the RS482 register readers:
`rs480_safe_regs=1` for promoted safe reads and
`rs480_candidate_regs=1` for bounded candidate-register validation.
The first block-scoped candidate file is
`radeon_rs480_candidate_config_regs`; `radeon_rs480_candidate_regs`
remains as a compatibility alias for the current config-aperture cohort.
The next split cohort is `radeon_rs480_candidate_gart_mc_regs`, which
keeps the mixed reader boundary explicit by exposing only `AGP_BASE_2`,
`GART_FEATURE_ID`, and `GART_BASE` instead of promoting the full
`rs400_gart_info` surface.
The bounded 3D-state file is `radeon_rs480_candidate_z_regs`, which
holds the first bounded RS482 depth-state cohort:
`R300_SC_HYPERZ`, `R300_GB_Z_PEQ_CONFIG`, `R300_ZB_ZTOP`,
`R300_ZB_ZCACHE_CTLSTAT`, `R300_ZB_BW_CNTL`, `R300_ZB_ZMASK_OFFSET`,
`R300_ZB_ZMASK_PITCH`, `R300_ZB_ZPASS_DATA`, and `R300_ZB_ZPASS_ADDR`.
`ZB_HIZ_*` remains out of the first cohort because Mesa still models
RS482 with `hiz_ram = 0` and the retained zpass bundle did not show any
`ZB_HIZ_*` traffic. Use the candidate reader to exercise newly uncovered
registers before promotion into the safe table.

Build and install on CachyOS:

```bash
makepkg -Cf
sudo pacman -U ./radeon-unified-dkms-*.pkg.tar.zst
dkms status
```

Upgrade-survival check:

```bash
pacman -Qkk radeon-unified-dkms
pacman -Qo /etc/modprobe.d/radeon-re.conf /etc/mkinitcpio.conf.d/radeon-unified.conf
modinfo -k "$(uname -r)" radeon | grep 'rs480_.*regs'
lsinitcpio /boot/*/linux-cachyos*/initramfs-linux-cachyos* | grep updates/dkms/radeon.ko
```
