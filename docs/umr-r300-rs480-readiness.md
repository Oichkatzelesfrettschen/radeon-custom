# UMR R300 / RS480 Readiness

## Purpose

UMR is useful for Radeon reverse engineering only when it names the
actual device family, uses the correct register database, and talks to
the active kernel stack safely.  RS480/R300 support must therefore land
as a read-only bring-up before any write path.

## Required UMR Work

| Area | Required behavior |
|---|---|
| Device identity | Recognize `1002:5974` as RS480/RS482/RS485-class Radeon Xpress using the radeon kernel driver. |
| Family model | Add an R300/RS4xx family bucket distinct from Evergreen/R600 and from amdgpu-only families. |
| Register database | Seed RS400/RS480 GART and R3xx 3D registers from Linux `rs400.c`, `r300.c`, and AMD/X.Org PDFs. |
| Backend | Use the existing radeon BAR/MMIO backend style; do not require amdgpu. |
| Safety | Default to read-only operations; write support must require an explicit opt-in flag and a finding that justifies it. |
| Output | Emit machine-readable JSON for family, PCI ID, register name, offset, raw value, and source citation. |

## Initial Register Set

| Group | Source |
|---|---|
| PCI identity | Linux `drm_pciids.h` at stable `v6.18.32`. |
| RS480 GART | Linux `drivers/gpu/drm/radeon/rs400.c` and `rs400d.h`. |
| R300 init and command path | Linux `r300.c`, `r300d.h`, and `radeon_cs.c`. |
| Radeon UAPI | Linux `include/uapi/drm/radeon_drm.h`. |
| 3D register names | AMD/X.Org `R3xx_3D_Registers.pdf`. |
| Compiler/state names | Mesa `src/gallium/drivers/r300/`. |

## Acceptance Criteria

| Check | Command shape |
|---|---|
| Build | Build UMR with radeon backend enabled and no amdgpu-only assumption for RS480. |
| Identity | Run an RS480 detect command and emit `vendor=1002`, `device=5974`, `family=rs480`. |
| Safe read | Read one documented RS480 GART or R300 status register without kernel warnings. |
| Cross-check | Compare one UMR read with an existing BAR/MMIO capture from the R300 results bundle. |
| No writes | Verify default command path does not write MMIO or submit command streams. |

## Deferred Work

Shader disassembly, wavefront inspection, and write-capable register
experiments stay deferred until read-only naming and capture parity are
proven on RS480.
