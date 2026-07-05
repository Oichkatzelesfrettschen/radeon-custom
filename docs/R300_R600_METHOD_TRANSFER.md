# R300 / R600 Method Transfer

## Purpose

This note makes the R600/Palm reverse-engineering method reusable for
RS480/R300 without importing R600 hardware assumptions.

## Transfers Directly

| R600 method | R300 use |
|---|---|
| Document-centric source of truth | Keep public PDFs, Linux source, Mesa source, X.Org source, and captured web pages under hashed external-source bundles. |
| Machine evidence bundles | Keep host captures under `results/` with command status files, README, and hash manifests. |
| Read-only first probes | Prefer inventory, GL compiler debug, BAR snapshots, and kernel source audits before any mutating register write. |
| Source hierarchy docs | Rank hard PCI/kernel identity before family docs, then executable Mesa/X.Org source, then academic/context sources. |
| Toolkit manifest discipline | Every deployable helper has a manifest row, ISA/glibc status where relevant, and provenance notes. |

## Must Change For R300

| R600/Palm assumption | R300/RS480 replacement |
|---|---|
| Vulkan/Terakan is the main workload path | OpenGL/Mesa r300 and Piglit are the main runtime paths. |
| Evergreen / TeraScale-2 VLIW5 registers are primary | R3xx/R4xx/R5xx register PDFs and Mesa r300 compiler/state emit are primary. |
| Palm BAR2 and Evergreen GRBM status maps apply | RS480 MMIO/GART paths must be derived from Linux `rs400.c`, R300 docs, and live RS480 captures. |
| `radeon-palm-gate-dkms` is deployable | Palm kernel package remains Palm-specific until RS480 needs its own kernel module. |
| UMR Evergreen support is enough | UMR needs RS480/R300 family ID, register DB, and safe radeon MMIO backend support. |

## First R300 Empirical Ladder

| Step | Success criterion |
|---|---|
| Identity replay | PCI ID, Mesa renderer, DRM driver, and X.Org family bucket agree with the recorded RS480 identity. |
| Compiler probe replay | A GLX shader probe emits r300 compiler debug and hardware program text. |
| Register map dry run | Read-only MMIO/BAR capture maps offsets to public R3xx/RS400 names without writes. |
| Piglit smoke | A tiny GL/Piglit subset runs with clean logs and no kernel errors. |
| UMR read-only smoke | UMR can name the device family and read a documented safe register through the radeon backend. |

## Non-Goals

Do not promote R600 silicon findings to R300 facts without an RS480
capture.  Do not add write-capable UMR paths before read-only RS480
register naming is stable.  Do not make the Palm DKMS package look
generic until a non-Palm kernel patch exists.
