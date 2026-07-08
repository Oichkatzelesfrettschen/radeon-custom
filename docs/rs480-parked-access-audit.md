# RS480 parked-access enforcement audit (RAD-05q)

This audit enforces one invariant across the radeon-custom patch series: after
`rdev->gpu_parked` is set on a failed RS480 reset, no reachable path may perform
a GPU MMIO read, an MC-indirect read, a GART flush readback, an AtomBIOS register
access, a modeset register access, or a debugfs register read. Every post-wedge
channel must instead terminate in a safe terminus -- skip, return disconnected,
return error, force-complete, leak until reboot, SIGBUS, no-op, or leave the
display parked. The reasoning is over `patches/rs480/*.patch` and the DKMS build
order in `packaging/arch/radeon-unified-dkms/dkms.conf`, cross-referenced against
the pristine radeon entry points; it never applies patches to an ad-hoc tree,
which rejects hunks and mislabels paths. The companion proof ledger is the
steinmarder-r300 cut graph (rs480-parked-gpu-absorbing-state-cut-graph.md);
fires are the RAD-05i series (F22/F23/F24b/F28).

`gpu_parked` enters the tree at patch 0046 (classifier in `radeon_device.c`,
`radeon_gpu_reset`) and becomes the persistent `rdev->gpu_parked` struct field at
0049 (`radeon.h`). Every patch numbered below 0046 therefore predates the flag
and cannot reference it; that fact is load-bearing for the uncovered rows.

## Covered channels

| pristine entry point | gating patch | prior hardware access | behavior under gpu_parked | proof |
|---|---|---|---|---|
| `radeon_gpu_reset` failure path (`radeon_device.c`) | 0046 | resume-side register access | classify parked, skip resume-side access, restore BIOS scratch by posted write only | F22 park path executes end to end |
| `r100_mc_resume` / display-request restore | 0046 + 0048 | MC/display request re-enable then read | leave MC/display requests parked; touch nothing after classification | F3/F4 (GART flush was the last hole) |
| PM resume (`radeon_pm_resume`) | 0046 | PLL/clock register access | acceleration off, skip pm/atom/hpd/modeset resume | F22 |
| AtomBIOS encoder / HPD / modeset init | 0046 + 0050 | AtomBIOS + modeset register I/O | skip atom/hpd resume; `radeon_display.c` modeset returns -ENODEV / rejects | F22/F23 |
| KMS output poll / connector detect (`radeon_connectors.c`) | 0058 | connector detect register reads (load-detect) | detect callbacks early-return `connector->status`; `drm_kms_helper_poll_disable` | F23 quiet window survived (one-fire proof) |
| IRQ handler | 0056 | IRQ-ack MMIO | disable IRQ line, no MMIO | F22 |
| fence lockup work (`radeon_fence.c`) | 0051 + 0057 | ring / RBBM read | early-return under gpu_parked; sync-drain the work | F22 drains printed |
| dynpm idle / hotplug work | 0056 + 0057 | clock / HPD read | cancel then sync-drain | F22 |
| DRM file close / postclose | 0052 | full teardown | hold close-path pins; postclose gated | F23 died at postclose -> F28 survived |
| GEM object free (`radeon_gem.c`) | 0052 + 0053 | TTM BO teardown | leak GEM objects, defer teardown to reboot | F23/F28 |
| TTM BO finalization | 0053 | `ttm_bo_fini` hardware path | no `ttm_bo_fini` under gpu_parked | F28 |
| GART unbind / TLB flush (`radeon_gart.c`) | 0049 + 0052 | MC-indirect flush readback | skip GART TLB flush; GART unbind flush guarded | F3/F4 identified; F28 |
| fbcon / scanout aperture (`radeon_fbdev.c`) | 0059 | `fb_read`/copyarea VRAM aperture read | aperture read returns -ENODEV; draw ops swallowed | F24b (fbcon refuted as specific actor; gate kept) |
| debugfs post-reset read (reset-hang probe) | 0046 | post-park register read | probe skips the post-park read ("no post-park register read") | F28 |

## Uncovered channels (RAD-05q rows to close, in order)

These three edges are not gated by `gpu_parked`. They are classified here; the
follow-up is one mechanical patch per gap, not a broad cleanup, in the order
below. No fire is required to close any of them.

### 1. RE debugfs register readers (patches 0001-0042) -- unguarded, close first

The RE readers (`0001` safe-regs, `0004` candidate-regs, `0005` firmware-read,
`0010` mc-benign, `0011` gart-status, `0018` sclk-cntl-pll, `0019` pll-indirect +
hazard-firstread, `0022` vertex-engine attended probe, `0039` cp-ib-scratch, and
peers) register debugfs nodes that read GPU registers via `RREG32` / `RREG32_PLL`
(102 sites) / `RREG32_MC` (49 sites). All predate `gpu_parked` (0046), so none is
gated. Classification by operating window:

- Safe in normal operation, black hole post-park: the 3D-pipe / VAP-GA / MC-indirect
  readers (`0004`, `0005`, `0011`, `0019`, `0022`) -- a read after park is a
  non-completing HT read into the GA-routed bus.
- Safe in both windows: host-domain scratch / posted-config readers where the
  register is not clock/grant-gated.

Fix: a `gpu_parked` hard-return in the RE debugfs read path so any node read after
park returns `-ENODEV` instead of touching the bus. One patch, gating the shared
reader entry (the `dri/N` root registered at 0009), not each node.

### 2. Module unload of a parked radeon -- uncovered teardown, close second

Pristine `radeon_drv.c` exposes `radeon_pci_shutdown` (line 394, wired at
`.shutdown` line 648) and `radeon_module_exit` (line 666, `module_exit` line 674).
Neither is gated on `gpu_parked`; an `rmmod radeon` of a parked GPU enters the
normal teardown, which reads hardware. It never occurs in the campaign because
the box reboots rather than unloading a parked module, but the invariant must
still cover it. Fix: refuse or no-hardware-route the unload/shutdown path under
`gpu_parked` (return early / skip the hardware teardown, leak like 0053). One
patch.

### 3. Userspace VRAM mmap SIGBUS gate (0060) -- armed but unproven, close last

0060 zaps userspace GEM PTEs (`unmap_mapping_range`) and returns `VM_FAULT_SIGBUS`
for VRAM-placed BOs in `radeon_gem_fault`. Fire 28 proved host survival but no
thawed client re-faulted a zapped VRAM mapping, so the SIGBUS arm has never
fired. This needs a STATIC proof that the gate is correctly placed (the guard
precedes any `down_read`/hardware touch and covers exactly the VRAM placement) or
a future non-fire unit-style probe -- not a WD3B fire. Until then it is armed,
placement-audited, and unproven. Close last because it is the only row that is
functionally present; the fix is proof, not code.

## Enforcement going forward

No reset-behavior change is made from this document. The next radeon-custom
change is the three patches above in order (debugfs guard, unload refusal, 0060
placement proof), one per gap. A `radeon_gpu_parked(rdev)` predicate helper
should name the rule at each new cut edge so future edits are auditable against
this table. Any new patch that adds a hardware-access entry point reachable after
park must add a row here and a `gpu_parked` terminus, or it regresses the
invariant.
