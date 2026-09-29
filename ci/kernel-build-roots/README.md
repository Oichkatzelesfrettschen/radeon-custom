# Kernel build roots

The series carries a `LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)` split in
`radeon_gem.c`, added by `0052-rs480-parked-gpu-close-path-pins.patch` and
extended by `0053-rs480-parked-gpu-leak-bos-by-design.patch`. Both branches
name a different TTM teardown call, so compiling against a 7.x kernel exercises
one side and leaves the other unbuilt. A pre-7.0 build root gives the second
side a compiler.

## Roots

Each root is the build directory an Arch Linux headers package installs under
`/usr/lib/modules/RELEASE/build`, resolved through the Arch Linux Archive
snapshot that `ARCH_ARCHIVE_SNAPSHOT` in `.github/workflows/gates.yml` names.
The job-level `env` of the job that compiles against a root pins its package,
version, and release, so `gates.yml` is the one home for those values.

| Job | Package | Version | Kernel release | `LINUX_VERSION_CODE` range |
| --- | --- | --- | --- | --- |
| `package` | `linux-headers` | `7.2.7.arch1-1` | `7.2.7-arch1-1` | `KERNEL_VERSION(7, 0, 0)` to below `KERNEL_VERSION(8, 0, 0)` |
| `compat-6-18` | `linux-lts-headers` | `6.18.54-1` | `6.18.54-1-lts` | `KERNEL_VERSION(6, 18, 0)` to below `KERNEL_VERSION(7, 0, 0)` |

Both packages build their kernels with GCC (`CONFIG_CC_IS_GCC=y`), and the
module compile runs under the GCC the same snapshot installs. The compile gates
reject every warning other than the compiler-mismatch notice, so a GCC
diagnostic in the pinned source fails the gate. `target-kernel.yml` compiles
the merged package against the target host's own kernel build root, under the
compiler that kernel names.

## Identity proof

pacman verifies each package signature at install. On that base,
`scripts/check_packaged_kernel_build_root.sh` proves the root the gate compiles
against:

1. `pacman -Q` reports exactly the pinned package version.
2. `include/config/kernel.release` names the pinned release.
3. `LINUX_VERSION_CODE` in `include/generated/uapi/linux/version.h` lies in the
   job's half-open range, so a pin repointed at a 7.x package fails the
   `compat-6-18` job instead of producing a green verdict against the branch
   that job exists to build.
4. `pacman -Qkk` matches every installed file against the size, mode, and
   SHA-256 in the package's signed `.MTREE`.
5. The root holds exactly the non-directory paths the package owns, so an
   injected file fails as surely as an altered one.

`scripts/check_shared_build_root_identity.py` then records the complete root,
every path, type, mode, size, digest, and symlink target, before the first
compile and verifies it after each compile step. The compiles run as an account
that cannot write the root, and the manifest comparison confirms that no step
changed it.

## Moving the snapshot

Pick the new snapshot date, read the header versions it carries, and change
`ARCH_ARCHIVE_SNAPSHOT` and both jobs' `KERNEL_HEADERS_VERSION` and
`KERNEL_RELEASE` in one commit:

```sh
snapshot=2026/09/28
curl -fsS "https://archive.archlinux.org/repos/$snapshot/core/os/x86_64/core.db" |
  tar -xzO --wildcards '*/desc' |
  awk '/^%NAME%$/ { getline; name = $0 }
       /^%VERSION%$/ { getline; if (name ~ /^linux(-lts)?-headers$/) print name, $0 }'
```
