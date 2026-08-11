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

for package in \
  packaging/arch/radeon-unified-dkms/radeon-unified-dkms-0.8.1-4-x86_64.pkg.tar.zst \
  packaging/arch/radeon-unified-dkms/radeon-unified-dkms-dev-0.8.1-4-x86_64.pkg.tar.zst
do
  bash scripts/verify_radeon_unified_dkms_package.sh \
    --source-repository "$RADEON_UNIFIED_SOURCE_REPOSITORY" \
    --package "$package"
  RADEON_UNIFIED_SOURCE_REPOSITORY="$RADEON_UNIFIED_SOURCE_REPOSITORY" \
    bash scripts/test_radeon_dkms_package_verifier.sh "$package"
done
```

## Target validation

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
