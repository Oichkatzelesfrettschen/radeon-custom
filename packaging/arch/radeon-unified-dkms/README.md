# Arch Radeon DKMS package

This directory packages the signed legacy-equivalent Radeon source checkpoint.
`linux-radeon-gororoba` owns the driver source. `radeon-custom` owns the source
pin, DKMS glue, compiler policy, runtime defaults, and package verification.

The active constructor is `PKGBUILD` at package revision 0.3-94. It resolves
commit `9079be562eebd184da9cf891fbc6a72d5ac0d9f3`, verifies the annotated tag
object and driver tree, and exports `drivers/gpu/drm/radeon` with `git archive`.
The package applies no patch and performs no source mutation.

`source-identity.toml` records the source repository, commit, annotated tag
object, driver tree, migration manifest digest, generated-output proof digest,
and source-equivalence workflow run. The file is installed beside the DKMS
source at `/usr/src/radeon-unified-0.3/source-identity.toml`.

The default transport is:

```bash
git+ssh://git@github.com/Oichkatzelesfrettschen/linux-radeon-gororoba.git
```

A workstation with the sibling source repository uses:

```bash
export RADEON_UNIFIED_SOURCE_REPOSITORY=../linux-radeon-gororoba
export RADEON_UNIFIED_SOURCE_URL="git+file://$(realpath "$RADEON_UNIFIED_SOURCE_REPOSITORY")"
```

Run the source, package, and lifecycle checks from the repository root:

```bash
bash scripts/verify_radeon_unified_dkms_sources.sh \
  --source-repository "$RADEON_UNIFIED_SOURCE_REPOSITORY"

(
  cd packaging/arch/radeon-unified-dkms
  makepkg -fC --noconfirm
)

bash scripts/verify_radeon_unified_dkms_package.sh \
  --source-repository "$RADEON_UNIFIED_SOURCE_REPOSITORY" \
  --package packaging/arch/radeon-unified-dkms/radeon-unified-dkms-0.3-94-x86_64.pkg.tar.zst
```

The package verifier compares every installed Radeon path, type, mode, link
target, and file byte with a fresh archive from the pinned driver tree.

`radeon-dkms-make` admits printable unquoted KCFLAGS tokens, preserves their
order, adds `-O2 -pipe` exactly once, and removes userspace compiler variables
before Kbuild starts. `test_radeon_dkms_kcflags_composition.sh` calibrates the
accepted and rejected forms.

The disposable lifecycle gate extracts one admitted package into private DKMS
roots, completes add, build, install, metadata capture, uninstall, unbuild, and
remove, then proves no DKMS state remains. The expected SHA-256 binds the
evidence to reviewed package bytes. It does not authenticate an externally
obtained package.

The files under `patches/`, `sources/`, and `migration/input/` are immutable
legacy evidence. The active package does not consume them.
