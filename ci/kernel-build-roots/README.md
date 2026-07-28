# Retained kernel build roots

The series carries a `LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)` split in
`radeon_gem.c`, added by `0052-rs480-parked-gpu-close-path-pins.patch` and
extended by `0053-rs480-parked-gpu-leak-bos-by-design.patch`. Both branches
name a different TTM teardown call, so compiling against a running 7.x kernel
exercises one side and leaves the other unbuilt. A retained pre-7.0 build tree
gives the second side a compiler.

Each root is identified here by its key-file hashes at repository-relative
paths. The local absolute path is a workspace fact and lives in the Actions
repository variable named in the table below.

## Roots

| Kernel release | Variable | Hash file |
| --- | --- | --- |
| `6.18.38-2-cachyos-lts` | `RADEON_KERNEL_BUILD_ROOT_618` | `6.18.38-2-cachyos-lts.sha256` |

## 6.18.38-2-cachyos-lts

| Field | Value |
| --- | --- |
| kernel release | `6.18.38-2-cachyos-lts` |
| `LINUX_VERSION_CODE` | `397862`, which is `KERNEL_VERSION(6, 18, 38)` |
| originating package | `linux-cachyos-lts-headers-6.18.38-2-x86_64_v3.pkg.tar.zst` |
| package SHA-256 | `057509fe27ef3d1cb096df59acc4eeac56a72ccc58065945873bd43b9fd68cb7` |
| package signature | good, CachyOS `882DCFE48E2051D48E2562ABF3B607488DB35A47` |
| kernel compiler | `clang version 22.1.6` |

The root is extracted from that package rather than copied from an installed
tree, so the package SHA-256 above is the provenance root and every key-file
hash below it is reachable from a signed artifact.

The retained axis is the kernel build tree. The host toolchain floats, so a
`clang` newer than 22.1.6 emits `the compiler differs from the one used to
build the kernel` and compiles anyway. The lane produces object files rather
than a loadable module, so vermagic never enters the verdict, and a future
failure attributes to the toolchain by that version line.

`sha256sum -c` covers the six files that carry version identity and
configuration surface. It reports on the identity of the root rather than on
every byte of a 183 MiB header tree.

## Preparing a root

Extract the headers package for the target release, place the tree outside
every repository workspace, and make it root-owned and world-readable with
write access removed. External-module compilation writes into the temporary
Radeon source tree, so a read-only kernel build root compiles.

```sh
release=6.18.38-2-cachyos-lts
pkg=/var/cache/pacman/pkg/linux-cachyos-lts-headers-6.18.38-2-x86_64_v3.pkg.tar.zst
pacman-key -v "$pkg.sig"
stage=$(mktemp -d)
tar -xf "$pkg" -C "$stage" "usr/lib/modules/$release/build"
sudo rsync -a --delete "$stage/usr/lib/modules/$release/build/" \
  "/opt/gororoba/kernel-builds/$release/"
sudo chown -R root:root /opt/gororoba
sudo chmod -R a-w /opt/gororoba/kernel-builds
```

Record the resulting hashes with the paths this directory uses:

```sh
( cd "/opt/gororoba/kernel-builds/$release" && sha256sum \
    .config Module.symvers include/config/kernel.release \
    include/generated/autoconf.h include/generated/compile.h \
    include/generated/uapi/linux/version.h \
) > "ci/kernel-build-roots/$release.sha256"
```

## Release selection

`6.18.34-1-cachyos-lts` is absent from this host: `pacman -Q` does not list it
and `/var/cache/pacman/pkg` retains no package for it. `6.18.33-2-cachyos-lts`
appears under `/lib/modules` with a stub build directory carrying no
`Makefile`, `Module.symvers`, or generated headers, so it compiles nothing.
`6.18.38-2-cachyos-lts` retains both the package and its signature, which is
why it roots this lane.
