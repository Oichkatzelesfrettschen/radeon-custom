# Arch Radeon DKMS packages

This directory produces two conflicting split packages from one protected
source commit:

* `radeon-unified-dkms` compiles the `prod` profile.
* `radeon-unified-dkms-dev` compiles `all-dev`, which resolves to the
  `mutate-dev` ceiling, and sets the runtime profile to `off`.

Both packages provide the same `radeon-unified` functional identity. Pacman
therefore admits exactly one compiled profile at a time.

`source-identity.toml` binds the package to the protected source commit, full
repository tree, Radeon driver tree, feature-policy tree and digest, and
upstream base. It also proves that the selected source descends from the signed
source-equivalence tag. The equivalence tag remains the authority for the
frozen migration manifest.

Each package installs these files under
`/usr/src/radeon-unified-${pkgver}/`, where `pkgver` is the active PKGBUILD
version:

* `source-identity.toml`
* `radeon-build-profile.toml`
* `radeon-build-profile.h`
* one profile-specific `dkms.conf`
* the exact exported Radeon source
* the compiler and initramfs helpers

The profile header supplies the module metadata fields checked by `modinfo`.
The production DKMS recipe passes `RADEON_BUILD_PROFILE=prod`. The development
recipe passes `RADEON_BUILD_PROFILE=mutate-dev`, the Kbuild spelling of the
`all-dev` package profile. Caller environment variables cannot change either
recipe.

The package Make wrapper defines the Kbuild environment boundary. It removes
inherited `KBUILD_*`, compiler, linker, Rust, LLVM, shell, output, and module path variables
before it invokes GNU Make. It accepts only the exact DKMS assignments for the
module path, kernel build root, package profile, kernel release, compiler helper,
the exact `LLVM=1` Kbuild selector, and numeric verbosity controls. It rejects GNU Make expansion syntax, shell
assignment operators, and every other package-controlled assignment. This
boundary prevents an inherited `KBUILD_CPPFLAGS` value from changing the
package `KCFLAGS` contract through Kbuild variable expansion.

## Package QA

The three archives retain an `x86_64` package identity because the release
contract binds them to the x86_64 CachyOS kernel-build roots and the RS482
target. They contain DKMS source and board policy rather than prebuilt ELF
objects. `namcap` therefore cannot infer the required `dkms` dependency from
the `dkms.conf` payload or the required `radeon-unified` capability from the
board-policy option file. `scripts/check_radeon_package_qa.py` proves those
payload relationships and accepts only those two semantic blind spots plus the
intentional no-ELF classification. It rejects every other warning or error.

The production package installs only the package-owned production policy. The
development package also installs `profile_dev=off`, the three canonical
runtime templates, and `/usr/bin/radeon-profile-dev`. The selector supports:

```bash
radeon-profile-dev show
radeon-profile-dev select off
radeon-profile-dev select observe-dev
radeon-profile-dev select probe-dev
radeon-profile-dev select mutate-dev
radeon-profile-dev verify
```

`probe-dev` requires an interactive acknowledgement. `mutate-dev` requires the
installed RS480 hazard preflight to pass. Selection updates only the runtime
profile override and rebuilds the initramfs. It neither reloads the module nor
arms an individual operation.

A workstation with the sibling source repository builds and verifies both
packages with:

```bash
export RADEON_UNIFIED_SOURCE_REPOSITORY=../linux-radeon-gororoba
export RADEON_UNIFIED_SOURCE_URL="git+file://$(realpath "$RADEON_UNIFIED_SOURCE_REPOSITORY")"

bash scripts/verify_radeon_unified_dkms_sources.sh \
  --source-repository "$RADEON_UNIFIED_SOURCE_REPOSITORY"

(
  cd packaging/arch/radeon-unified-dkms
  makepkg -fC --noconfirm
)

package_dir=packaging/arch/radeon-unified-dkms
prod_package="$package_dir/radeon-unified-dkms-0.8.2-1-x86_64.pkg.tar.zst"
dev_package="$package_dir/radeon-unified-dkms-dev-0.8.2-1-x86_64.pkg.tar.zst"
policy_package="$package_dir/radeon-rs482-policy-0.8.2-1-x86_64.pkg.tar.zst"

for package in "$prod_package" "$dev_package"
do
  bash scripts/verify_radeon_unified_dkms_package.sh \
    --source-repository "$RADEON_UNIFIED_SOURCE_REPOSITORY" \
    --package "$package"
  RADEON_UNIFIED_SOURCE_REPOSITORY="$RADEON_UNIFIED_SOURCE_REPOSITORY" \
    bash scripts/test_radeon_dkms_package_verifier.sh "$package"
done

python3 scripts/check_radeon_package_qa.py \
  --package "$prod_package" \
  --package "$dev_package" \
  --package "$policy_package"
```

## Versioning

A source-pin advance or any packaged-content change bumps the minor
version (pkgver) and resets pkgrel to 1; a packaging-only rebuild of
identical content bumps pkgrel. Each pkgver carries a matching signed
profiled-source tag radeon-unified-<pkgver>-profiled-source whose peeled
commit equals source_commit.

## Target validation

0.8.5-1 advances the source pin to linux-radeon-gororoba cc91fbc (the
paired-status census radeon_rs480_paired_status_census conformed to
transport ABI minor 1: gate-before-token -EBUSY, completed-bounded
published length, between-record signal and duration aborts,
partial_disarmed status, truthful BB CP_FIRST, nonseekable transport;
profiled-source tag object 68644aff9da7). The one-shot observer
function is byte-identical to the 0.8.4 pin, so an experiment plan
naming this package covers both the observed one-shot cell and the
census calibrations in one boot. The pinned source compiles as prod
against 7.1.8-1-cachyos via check_radeon_pinned_source_compiles.sh.
Target install, reboot, loaded-module verification of both nodes, and
the attended cells are pending.

0.8.4-1 advances the source pin to linux-radeon-gororoba ca6bad0 (the
one-shot RBBM/CP_STAT paired status reader radeon_rs480_cp_status and
the parallel Kbuild module build; profiled-source tag object
e3b2dd16b3b1). The pinned source compiles as prod against 7.1.8-1-cachyos
via check_radeon_pinned_source_compiles.sh. Target install, reboot,
loaded-module verification of the observer node, and the attended
CP_STAT-observed cell are pending; the 0.8.3-1 record below is the
latest completed target validation, and the 0.8.3 tuple re-run it lists
as pending completed CARRIER_DELIVERED on the loaded validator.

0.8.3-1 advances the source pin to linux-radeon-gororoba 74cc62c (the
ATOM/COMBIOS bounds-hardening series and the FLOAT_2 XY01
synthesized-lane width validator; profiled-source tag object
c6160832bf9d). The pinned source compiles as prod against
7.1.8-1-cachyos via check_radeon_pinned_source_compiles.sh. Target
install, reboot, loaded-module verification, and the attended one-shot
tuple re-run through the loaded validator are pending; the record below
remains the latest completed target validation.


The 0.8.1-4 production archive has SHA256
`5712a92f9937aad6f1e11525944648ef3376347c6ace65553c13a85fc7eaa362`. The
development archive has SHA256
`28951fdb004cdd35b00cbd70ff2f6705673d666916120b0399fbfd13cdb7ed13`. The
RS482 policy archive has SHA256
`451b411b81cb96e82ef66d67bef37ca4636d78d71473ade76bc7daf96f69ba13`.

The production and policy archives install through one pacman transaction and
rebuild `radeon-unified` for `7.1.3-2-cachyos` and
`6.18.38-2-cachyos-lts`. A normal reboot on the RS482 target reaches boot ID
`3b33587b-f825-4698-82a0-2ad40b20b7f7`. The loaded Radeon module reports
srcversion `E07FCCC3BAFFB29C7CFD36B`, kernel logs record successful ring and
indirect buffer tests, 512 MiB GART initialization, and Radeon modesetting,
and the runtime keeps `lockup_timeout=0` and `no_wb=1`.

This result validates package installation, DKMS generation, initramfs refresh,
and ordinary boot modesetting on the target. It does not establish workload
performance, conformance, reset recovery, or safety of a hazardous operation.

The package verifier checks metadata, root ownership, member types and modes,
the complete archive namespace, every installed Radeon byte, the selected
profile inputs, runtime policy, and package conflicts. The lifecycle gate then
builds the admitted package in disposable DKMS and kernel roots, compares the
installed module metadata to the package manifest, uninstalls it, and proves
that no DKMS state remains.

The files under `patches/`, `sources/`, and `migration/input/` are immutable
legacy evidence. Neither active package consumes them.
