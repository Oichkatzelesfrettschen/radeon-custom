# Legacy Radeon source tree decomposition

The migration to a dedicated source repository replaces a constructed tree with
a stored one. This document records what the constructed tree contains today,
measured rather than asserted, so the replacement can be proven by comparing
manifests rather than by compiling both and finding neither broken.

The reference tree is produced by `scripts/materialize_legacy_radeon_tree.sh`,
which extracts `sources/radeon-unified-0.3-source.tar.xz` and applies the
anchored `PATCH[]` entries from `dkms.conf` in declared order, exactly as the
Arch DKMS path does. Its manifest is `docs/legacy-tree-a-manifest.tsv`,
recording path, mode, size, and SHA-256 for every regular file.

## Tree shape and series footprint

The materialized tree holds 223 regular files in a flat layout that corresponds
to upstream `drivers/gpu/drm/radeon/`, plus a `reg_srcs/` subdirectory of
register source tables.

The 70-patch series has a narrow footprint:

| Class | Count |
| --- | --- |
| Files identical to the base tarball | 206 |
| Files the series modifies | 16 |
| Files the series adds | 1 |
| Files the series deletes | 0 |

The modified set is `Makefile`, `r300.c`, `radeon.h`, `radeon_connectors.c`,
`radeon_cs.c`, `radeon_cursor.c`, `radeon_device.c`, `radeon_display.c`,
`radeon_drv.c`, `radeon_fbdev.c`, `radeon_fence.c`, `radeon_gem.c`,
`radeon_irq_kms.c`, `radeon_kms.c`, `radeon_ttm.c`, and `rs400.c`. The single
added file is `reg_srcs/rs480`.

So 206 of 223 files reach the built module exactly as the base tarball supplies
them. Whatever those files carry relative to upstream Linux comes from the base
snapshot alone, and the visible patch series says nothing about it.

## Series application fidelity

The series does not apply exactly. GNU `patch` defaults to
`--backup-if-mismatch`, so a `.orig` file appearing during application is the
fingerprint of a hunk that did not match its recorded context. Four such
backups appear: `rs400.c.orig`, `radeon.h.orig`, `radeon_device.c.orig`, and
`radeon_drv.c.orig`.

Measured across all 70 patches:

| Application class | Patches |
| --- | --- |
| Exact: no fuzz, no offset | 39 |
| Offset only | 23 |
| Fuzz: recorded context ignored | 8 |

The two classes carry different weight. An offset is the ordinary consequence
of generating hunks against the pristine base and replaying them onto a tree
earlier patches have already grown, so the 23 offset-only patches indicate an
unrebased series rather than a misplacement. The largest offsets sit in
`0021-rs480-cs-checker-r400-us-allowlist.patch` at 1152 lines and
`0072-rs480-gart-page-table-readonly-debugfs.patch` at 889 lines, both
consistent with accumulated insertions ahead of them.

Fuzz is the risk class. A fuzzed hunk applies after `patch` discards context
lines that failed to match, so placement rests on the remaining context rather
than on the recorded anchor. Eight patches apply with fuzz:
`0010`, `0012`, `0019`, `0021`, `0022`, `0025`, `0027`, and `0072`. The compile
gate passes on the resulting tree, which establishes that the fuzzed placements
produce compilable code and establishes nothing about whether each hunk landed
where its author intended. Compile equality is weaker than placement equality,
and the gate's own header names this failure mode.

A stored source tree removes this class outright: source held as source has no
context to match and no fuzz to absorb.

## Upstream base identity

The base is upstream Linux v6.18. Discriminator files the visible series leaves
untouched match `torvalds/linux` at `v6.18` and differ at `v6.17` and `v7.0`,
and a full comparison against `drivers/gpu/drm/radeon/` at that tag resolves
the snapshot:

| Class | Count |
| --- | --- |
| Common files identical to upstream v6.18 | 196 |
| Common files the snapshot modified | 15 |
| Present only in the snapshot | 11 |
| Present only upstream | 2 |

The 15 modified files are `rs400.c` (112 changed lines), `evergreen.c` (61),
`radeon_drv.c` (41), `radeon_kms.c` (39), `radeon_ttm.c` (14), `radeon_fbdev.c`
(8), `radeon_device.c` (8), `radeon_mode.h` (4), `radeon_legacy_crtc.c` (4),
`radeon_irq_kms.c` (4), `radeon.h` (4), `radeon_gem.c` (4), `atombios_crtc.c`
(4), `pptable.h` (2), and `radeon_asic.h` (1).

Two baked change sets account for them. `0001-rs480-safe-regs-debugfs.patch`
sits in `patches/rs480/` and appears in no `PATCH[]` entry, and its mechanisms
are present in the snapshot: `rs400.c` carries
`rs480_safe_regs_debugfs_init` and the pinned safe-register table, and
`radeon_drv.c` declares `radeon_rs480_safe_regs`. The Palm lane accounts for
the rest.

## Palm content in the constructed tree

Deployable Palm changes live inside the base snapshot as modifications to
existing upstream files. `evergreen.c` carries
`evergreen_gpu_pci_config_reset_safe`, which refuses a PCI-config reset on
`CHIP_PALM` because the reset propagates a link-training stall across the
shared PCIe root complex, and `radeon_drv.c` declares the
`radeon_palm_pci_reset_unsafe` override that gates it. Neither the snapshot nor
the series adds a Palm-specific file, so the Palm perf-query and CS-observer
material stays manufactured by the Debian `PRE_BUILD` path.

## Generated register tables ship pre-generated

The snapshot carries all ten `*_reg_safe.h` headers as files. Upstream
generates them during the build: `Makefile` declares `hostprogs := mkregtable`
and derives each header from its `reg_srcs/` input. The snapshot also omits
`reg_srcs/evergreen`, so the rule that would regenerate
`evergreen_reg_safe.h` cannot fire and the shipped header stands as source.

That shipped header carries a one-bit edit. Rebuilding `mkregtable` from
upstream `mkregtable.c` and running it against upstream `reg_srcs/evergreen`
reproduces `r300_reg_safe.h` byte-identically, which calibrates the method, and
produces an `evergreen_reg_safe.h` differing from the shipped one at exactly one
array entry: index 320 bit 8, `0xFFFFFFFF` against `0xFFFFFEFF`. That bit is
register offset `0xA020`, `SMX_DC_CTL0` in `evergreend.h`, and clearing it moves
the register from rejected to accepted in the command-stream checker. The Debian
lane reaches the same result by editing `reg_srcs/evergreen` directly, so the
two lanes deliver one change through different mechanisms.

The snapshot also carries `mkregtable` as a stripped x86-64 ELF executable
beside its own `mkregtable.c`. The build declares that name as a host program
and runs `$(obj)/mkregtable` to generate each safe-register header, so a
prebuilt binary of unrecorded provenance occupies the path the build invokes.
The source repository carries `mkregtable.c` and leaves the binary out.

## Source closure

The closure is upstream `drivers/gpu/drm/radeon/` at v6.18 plus the deltas
above. It reaches outside that directory nowhere: every file in the
materialized tree maps to a path under it, and the two upstream files the
snapshot omits are `.gitignore` and `reg_srcs/evergreen`. A source repository
preserving the upstream path therefore carries the whole closure, and the
generated `*_reg_safe.h` headers become build products again once
`reg_srcs/evergreen` returns carrying the `SMX_DC_CTL0` change as source.

## What this licenses

The manifest and the counts above are compile-host measurements on
`x570-5600X3D` against kernel 7.1.4-1-cachyos. They describe source
construction and license no hardware claim. Target-silicon verdicts remain in
`steinmarder-r300` and are unaffected by how the source tree is stored.
