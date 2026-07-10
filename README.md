# radeon-custom

Dedicated fork of the Linux `radeon` DRM kernel module for the RS480-class
(Vostro 1000 / RS482 / K8) and Palm/Warrior targets, packaged as DKMS. This
repository is the single build source for the radeon kernel-side work that
was previously scattered across the steinmarder trees; the userspace r300
gallium and r3v Vulkan drivers live in `mesa-26-gororoba`.

The canonical registry of which kernel modules the Vostro 1000 runs (radeon,
snd-hda, sb600 watchdog, and the DKMS series this repo builds) is
`mesa-26-gororoba/docs/hardware/vostro1000-kernel-modules.md`; treat it as the
source of truth and update it when this repo changes the installed DKMS
`pkgrel` or patch series.

## Why this exists

The RS482 IGP shares the K8 northbridge, and a GPU command-stream fault
hangs the ring. With the stock `radeon.lockup_timeout=0` the kernel waits
on the fence forever rather than resetting -- an unrecoverable soft hang
(proven on the Vostro 1000: a `util_blitter` clear stalls in
`radeon_fence_default_wait`, while a Vulkan draw on the same winsys
completes, so the fence path itself works). This module supplies the
RS480-class GPU reset that makes such a hang recoverable, plus the register
read/write hazard guards that keep the northbridge alive during probing.

## lockup_timeout policy

The stock value `0` (no self-reset) is retained as the default. A non-zero
`lockup_timeout` is enabled ONLY after the reset patches in this repo
(`rs480-crash-shim-recovery`, `rs480-rbbm-soft-reset-recovery-probe`) are
proven to actually recover the GPU on RS482 hardware rather than wedge it
harder -- the reason the stock value was set to 0 in the first place. Do not
flip it globally before that evidence exists.

## Layout

| Path | Role |
| --- | --- |
| `patches/rs480/` | RS480 / Vostro reset, safe-register, and debugfs patch series (0001-0040+) |
| `patches/palm/` | Palm / x130e reset, validator, and CS-observer patches |
| `sources/` | Prepatched radeon source tarballs per kernel line (cachyos 6.18/7.0, xanmod 6.18) plus provenance |
| `packaging/arch/radeon-unified-dkms/` | Arch `PKGBUILD` + `dkms.conf` (module name `radeon`, installs to `/updates/dkms`) |
| `packaging/debian/` | Debian DKMS adapter |
| `scripts/` | Build, apply, and verification helpers |
| `docs/` | `RADEON_DKMS_UNIFICATION_PLAN.md` (canonical patchset + packaging plan), method-transfer and UMR readiness notes |

## Build and install (Arch / cachyos)

    cd packaging/arch/radeon-unified-dkms
    makepkg -f
    sudo pacman -U radeon-unified-dkms-*.pkg.tar.zst

The package `replaces` the older `radeon-rs480-safe-regs-dkms` and
`radeon-palm-gate-dkms` staging packages. The PKGBUILD reads its patches and
source tarball by relative path from `../../../patches` and
`../../../sources`, so keep the top-level layout intact.

## Relationship to the other repositories

- `mesa-26-gororoba` -- userspace r300/r3v drivers; `docs/hardware/vostro1000-kernel-modules.md` is the registry that names this module and why the hardware needs it.
- `vostro1000-re` -- non-radeon platform DKMS (SB600 `sp5100-tco-ioapic` watchdog, `vostro1000-ec-fan` hwmon) and the `vostro1000-wedge-recovery` userspace posture; those stay there.
- `steinmarder` / `steinmarder-r300` -- the reverse-engineering evidence and probe corpus that produced these patches; `MIGRATION.md` records the provenance.
