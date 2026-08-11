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

The package verifier checks metadata, root ownership, member types and modes,
the complete archive namespace, every installed Radeon byte, the selected
profile inputs, runtime policy, and package conflicts. The lifecycle gate then
builds the admitted package in disposable DKMS and kernel roots, compares the
installed module metadata to the package manifest, uninstalls it, and proves
that no DKMS state remains.

The files under `patches/`, `sources/`, and `migration/input/` are immutable
legacy evidence. Neither active package consumes them.
