# RS4xx PCI identity and chip mapping

Silicon in this lane is identified by PCI ID, because the kernel collapses
several marketed part names onto one chip constant. This table is the single
home for that mapping; other files cite it rather than restating IDs.

## Kernel chip constants

`include/drm/drm_pciids.h` carries eight RS4xx entries under `radeon_PCI_IDS`,
and `radeon_family.h` declares two constants for them: `CHIP_RS400` and
`CHIP_RS480`. The kernel declares no `CHIP_RS482` and no `CHIP_RS485`, so an
RS482 part and an RS485 part are both `CHIP_RS480` at runtime and a driver
distinguishes them by PCI device ID alone.

The entries are byte-identical at v6.18 and v7.1, and the v7.1 text matches the
7.1.4-1-cachyos build tree, so the mapping is stable across both kernel targets.

| PCI ID | Kernel constant | pci.ids name | Kernel flags |
| --- | --- | --- | --- |
| `1002:5954` | `CHIP_RS480` | RS480 [Radeon Xpress 200 Series] | IGP, MOBILITY, IGPGART |
| `1002:5955` | `CHIP_RS480` | RS480M [Mobility Radeon Xpress 200] | IGP, MOBILITY, IGPGART |
| `1002:5974` | `CHIP_RS480` | RS482/RS485 [Radeon Xpress 1100/1150] | IGP, MOBILITY, IGPGART |
| `1002:5975` | `CHIP_RS480` | RS482M [Mobility Radeon Xpress 200] | IGP, MOBILITY, IGPGART |
| `1002:5a41` | `CHIP_RS400` | RS400 [Radeon Xpress 200] | IGP, IGPGART |
| `1002:5a42` | `CHIP_RS400` | RS400M [Radeon Xpress 200M] | IGP, MOBILITY, IGPGART |
| `1002:5a61` | `CHIP_RS400` | RC410 [Radeon Xpress 200/1100] | IGP, IGPGART |
| `1002:5a62` | `CHIP_RS400` | RC410M [Mobility Radeon Xpress 200M] | IGP, MOBILITY, IGPGART |

Flags are `RADEON_IS_IGP`, `RADEON_IS_MOBILITY`, and `RADEON_IS_IGPGART`. Every
`CHIP_RS480` entry carries `RADEON_IS_MOBILITY`, including the two IDs `pci.ids`
names as desktop parts, so the flag marks the RS480 IGP class rather than a
mobile package.

The target part in this lane is `1002:5974`. Retained RS482 evidence in
`steinmarder-r300` is bound to that ID.

## The 0x5975 naming conflict

Sources disagree on what `1002:5975` is called, and the disagreement is in
naming rather than in behavior.

| Source | Name for `0x5975` |
| --- | --- |
| `hwdata` pci.ids 0.409 | RS482M [Mobility Radeon Xpress 200] |
| Mesa `include/pci_ids/r300_pci_ids.h` | `RS482_5975` |
| Mesa `src/amd/r300/vulkan/r3v_private.h` | `R3V_PCI_DEVICE_ID_RS485` |
| `patches/rs480/0001-rs480-safe-regs-debugfs.patch` | RS485 |

`pci.ids` places the RS485 name on `0x5974` alongside RS482, and Mesa's own
chipset table and its r3v header disagree with each other. The kernel resolves
nothing here, because both IDs are `CHIP_RS480`.

Code and comments in this repository therefore identify parts by PCI ID and
name the marketing string as secondary. A claim that a result applies to "RS485"
names the ID it was observed on.

## Applying the RS4xx class in code

A guard for this silicon tests `rdev->family`, which selects the whole class:

```c
if (rdev->family == CHIP_RS480)
```

That condition matches all four of `0x5954`, `0x5955`, `0x5974`, and `0x5975`.
Narrowing to one part requires the PCI device ID, since the family constant
cannot express it. `ASIC_IS_RN50` and the `radeon.h` macros around
`CHIP_RS400` and `CHIP_RS480` follow the same class granularity.
