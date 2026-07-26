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

## Palm content in the constructed tree

The base tarball adds no Palm-specific file, and the series adds none. A file
named for the Palm CS observer is absent from both, so the Palm perf-query and
CS-observer material is manufactured by the Debian `PRE_BUILD` path rather than
carried in the Arch source or its patch chain.

This settles the added-file half of the question. Palm changes modified into
existing upstream files inside the base snapshot remain unresolved, because
detecting them requires a diff against an identified upstream base.

## Upstream base identity

The base is unidentified. `build_radeon_unified_source_tarball.sh` starts from
`sources/radeon-rs480-cachyos-6.18-7.0-prepatched.tar.xz`, normalizes
permissions, drops patch backups, and repacks; it names no upstream Linux
object. `radeon_drv.c` in the base declares `KMS_DRIVER_MINOR 51`, and the
snapshot filename names a CachyOS 6.18 to 7.0 range, which bounds a candidate
set without selecting from it.

The source verifier states that the base already contains patch `0001`, so the
constructed tree is an opaque snapshot plus a baked first patch plus 70 replayed
patches. Establishing the base requires comparing the 223-file tree against
`drivers/gpu/drm/radeon/` at candidate upstream tags, which needs an upstream
fetch this decomposition has not performed.

Identifying the base blocks the upstream-equivalence claim. It blocks neither
the reference tree, nor the source repository, nor the closure enumeration, all
of which rest on the constructed tree as it stands.

## What this licenses

The manifest and the counts above are compile-host measurements on
`x570-5600X3D` against kernel 7.1.4-1-cachyos. They describe source
construction and license no hardware claim. Target-silicon verdicts remain in
`steinmarder-r300` and are unaffected by how the source tree is stored.
