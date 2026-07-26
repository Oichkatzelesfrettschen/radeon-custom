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

## Identity of the target machine

The target is a Dell Vostro 1000. Retained captures in `steinmarder-r300` and
the platform decomposition in the `vostro1000-re` bill of materials give four
identifiers across three devices, and the RS485 name enters through the
chipset rather than through the GPU.

| Device | PCI ID | Name | Note |
| --- | --- | --- | --- |
| Host bridge, 00:00.0 | `1002:5950` | RS480/RS482/RS485 Host Bridge | DMI string reads `ATI RS485M` |
| Internal graphics bridge, 00:01.0 | `1002:5a3f` | RC4xx/RS4xx PCI Bridge [int gfx] | forwards bus 0 to bus 01 |
| Integrated GPU, 01:05.0 | `1002:5974` | RS482/RS485 [Radeon Xpress 1100/1150] | subsystem Dell `1028:022a` |

The GPU carries no local VRAM and takes 128 MiB through UMA and the GART.

An older `pci.ids` renders `1002:5974` as `ATI Radeon XPRESS 200M`, so a
retained capture may name the same silicon four ways: RS482, RS485, Xpress
1100/1150, and Xpress 200M. All four describe `1002:5974`.

This resolves where the RS485 name legitimately applies on this machine. The
chipset identifies as RS485M through DMI, and the GPU device ID `1002:5974`
covers the RS482 and RS485 IGP variants together. Neither fact makes
`1002:5975` an RS485 part, so the claim in
`0001-rs480-safe-regs-debugfs.patch` that RS485 is `1002:5975` does not follow
from the machine and conflicts with `pci.ids`.

## Terminology for kernel-side work

Kernel-side text in this repository uses three levels and keeps them distinct.

`CHIP_RS480` names the family constant and covers all four RS480-class IDs. A
statement about the family uses it, and it is the correct subject for any
`rdev->family` guard.

`RS482 (1002:5974)` names the part under test. Every hardware claim from
retained evidence binds to this form, because the evidence comes from one
device ID and the family constant cannot express that scope.

`RS485M` names the chipset of the target machine, sourced from DMI and the
`1002:5950` host bridge. It describes the platform rather than the GPU, so it
stays out of GPU register and reset claims.

The marketing strings `Radeon Xpress 1100/1150` and `Radeon Xpress 200M`
appear when quoting a capture and carry the PCI ID alongside.

## Whether this silicon warrants its own chip constant

The retained evidence does not support adding a `CHIP_RS482` constant, and it
does support finer-grained gating below the family level.

A new family constant asserts that the part diverges from its siblings at a
level the driver must branch on for correctness. Establishing that requires the
same probe run on the sibling IDs and a divergent result. Every retained bundle
in `steinmarder-r300` comes from one device, `1002:5974` on one machine, so the
comparison that would justify the constant has not been run. The GA-rooted
reset wedge is characterized on RS482 and unmeasured on `1002:5954`,
`1002:5955`, and `1002:5975`, which leaves it equally consistent with a
family-wide RS480 property and with a part-specific one.

The mechanisms this lane needs are already expressible without a constant. A
part-specific quirk tests the device ID directly, since `rdev->pdev->device`
carries what the family constant discards, and a board-specific quirk tests the
subsystem ID. Behavior that a maintainer must be able to disable rides a module
parameter, which is how the existing gates work.

The falsifier is explicit: running an existing probe on `1002:5954`,
`1002:5955`, or `1002:5975` and recording a result that diverges from the RS482
result promotes the case for a constant. Until such a bundle exists, part-level
work uses device-ID gating and module parameters, and `CHIP_RS480` stays the
one family constant for this silicon.

## Applying the RS4xx class in code

A guard for this silicon tests `rdev->family`, which selects the whole class:

```c
if (rdev->family == CHIP_RS480)
```

That condition matches all four of `0x5954`, `0x5955`, `0x5974`, and `0x5975`.
Narrowing to one part requires the PCI device ID, since the family constant
cannot express it. `ASIC_IS_RN50` and the `radeon.h` macros around
`CHIP_RS400` and `CHIP_RS480` follow the same class granularity.
