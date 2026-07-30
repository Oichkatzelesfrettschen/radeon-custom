# Arch Radeon DKMS package

This directory packages the signed legacy-equivalent Radeon source checkpoint.
`linux-radeon-gororoba` owns the driver source. `radeon-custom` owns the source
pin, DKMS glue, compiler policy, runtime defaults, and package verification.

The active constructor is `PKGBUILD` at package revision 0.3-96. It resolves
commit `9079be562eebd184da9cf891fbc6a72d5ac0d9f3`, verifies the annotated tag
object and driver tree, and exports `drivers/gpu/drm/radeon` with `git archive`.
The package applies no patch and changes no source file byte. Git tree objects
carry no directory objects, so the constructor uses `tar.umask=0022` to emit
deployment modes 0644 and 0755.

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

verifier_output=$(bash scripts/verify_radeon_unified_dkms_package.sh \
  --source-repository "$RADEON_UNIFIED_SOURCE_REPOSITORY" \
  --package packaging/arch/radeon-unified-dkms/radeon-unified-dkms-0.3-96-x86_64.pkg.tar.zst)
printf '%s\n' "$verifier_output"
package_digest=$(printf '%s\n' "$verifier_output" |
  sed -n 's/^package_sha256=//p')
RADEON_UNIFIED_SOURCE_REPOSITORY="$RADEON_UNIFIED_SOURCE_REPOSITORY" \
  bash scripts/test_radeon_dkms_package_verifier.sh \
    packaging/arch/radeon-unified-dkms/radeon-unified-dkms-0.3-96-x86_64.pkg.tar.zst
```

The package verifier binds package metadata, root ownership, regular-file and
directory member types, directory modes, the complete archive namespace, and
every installed Radeon byte to the selected recipe and signed driver tree.
Directory mode 0755 is package policy rather than source identity. The
verifier's calibration rejects source, metadata, member-set, mode, ownership,
traversal, link-type, and admitted-digest mutations.

`pre-build.sh` stages `radeon_trace.h` under the private DKMS build tree.
`radeon-dkms-make` adds that private trace include, admits printable unquoted
KCFLAGS tokens from the trusted root build environment, preserves their order,
adds `-O2 -pipe` exactly once, and removes userspace compiler flags and GNU make
control variables before Kbuild starts. The kernel build root remains
unchanged. `test_radeon_dkms_kcflags_composition.sh` calibrates the accepted and
rejected forms.

The disposable lifecycle gate extracts one admitted package into private DKMS
roots, completes add, build, install, metadata capture, uninstall, unbuild, and
remove, then proves no DKMS state remains. The expected SHA-256 binds the
evidence to reviewed package bytes. It does not authenticate an externally
obtained package. The gate accepts one canonical path-free kernel release,
requires root-owned non-writable kernel-root ancestry, distinguishes
status-command failure from residual DKMS state, and hashes retained failure
evidence before cleanup. It also proves the trace include exists only in the
private build tree and never enters the kernel root.

The files under `patches/`, `sources/`, and `migration/input/` are immutable
legacy evidence. The active package does not consume them.
