# RS480 parked-access enforcement audit (RAD-05q)

This audit enforces one invariant across the radeon-custom patch series: after
`rdev->gpu_parked` is set on a failed RS480 reset, no reachable path may perform
a GPU MMIO read, an MC-indirect read, a GART flush readback, an AtomBIOS register
access, a modeset register access, or a debugfs register read. Every post-wedge
channel must instead terminate in a safe terminus: skip, return disconnected,
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
| `r100_mc_resume` / display-request restore | 0046 + 0048 | MC/display request re-enable then read | leave MC/display requests parked; touch nothing after classification | F22 park path; GART flush residual closed by 0049 |
| PM resume (`radeon_pm_resume`) | 0046 | PLL/clock register access | acceleration off, skip pm/atom/hpd/modeset resume | F22 |
| AtomBIOS encoder / HPD / modeset init | 0046 + 0050 | AtomBIOS + modeset register I/O | skip atom/hpd resume; `radeon_display.c` modeset returns -ENODEV / rejects | F22/F23 |
| KMS output poll / connector detect (`radeon_connectors.c`) | 0058 + 0071 | connector detect register reads (load-detect) | detect returns `connector_status_disconnected` under `gpu_parked`; `drm_kms_helper_poll_disable` | F23 quiet window survived (one-fire proof) |
| IRQ handler | 0056 + 0071 | IRQ-ack MMIO | free_irq the radeon handler (shared-line safe); handler early-returns under `gpu_parked` | F22 |
| fence lockup work (`radeon_fence.c`) | 0051 + 0057 | ring / RBBM read | early-return under gpu_parked; sync-drain the work | F22 drains printed |
| dynpm idle / hotplug work | 0056 + 0057 | clock / HPD read | cancel then sync-drain | F22 |
| DRM file close / postclose | 0052 | full teardown | hold close-path pins; postclose gated | F23 died at postclose -> F28 survived |
| GEM object free (`radeon_gem.c`) | 0052 + 0053 | TTM BO teardown | leak GEM objects, defer teardown to reboot | F23/F28 |
| TTM BO finalization | 0053 | `ttm_bo_fini` hardware path | no `ttm_bo_fini` under gpu_parked | F28 |
| GART unbind / TLB flush (`radeon_gart.c`) | 0049 + 0052 | MC-indirect flush readback | skip GART TLB flush; GART unbind flush guarded | F22/F28; GART residual named in F28 teardown |
| cursor set/move (`radeon_cursor.c`) | 0071 | CRTC cursor MMIO | return -ENODEV under `gpu_parked` | static gate |
| vblank enable/counter (`radeon_kms.c`) | 0071 | vblank register / irq_set | early return under `gpu_parked` | static gate |
| mc_flush debugfs write | 0071 | CP ring commit readback | return -EIO under `gpu_parked` | static gate |
| `radeon_gpu_reset` re-entry | 0071 | crash-shim RREG32 + asic_reset | refuse with -EIO once parked | static gate |
| fbcon / scanout aperture (`radeon_fbdev.c`) | 0059 | `fb_read`/copyarea VRAM aperture read | aperture read returns -ENODEV; draw ops swallowed | F24b (fbcon refuted as specific actor; gate kept) |
| debugfs post-reset read (reset-hang probe) | 0046 | post-park register read | probe skips the post-park read ("no post-park register read") | F28 |

## Uncovered channels (RAD-05q rows to close, in order)

These edges were classified as open at the time of the original audit table.
Several are now closed by later patches (0061, 0062, 0071). Remaining residuals
are listed after the covered subsections.

### 1. RE debugfs register readers (patches 0001-0042), covered by 0061

The RE readers (`0001` safe-regs, `0004` candidate-regs, `0005` firmware-read,
`0010` mc-benign, `0011` gart-status, `0018` sclk-cntl-pll, `0019` pll-indirect +
hazard-firstread, `0022` vertex-engine attended probe, `0039` cp-ib-scratch, and
peers) live in `rs400.c` and read GPU registers via `RREG32` / `RREG32_PLL` /
`RREG32_MC`. All predate `gpu_parked` (0046), so none was gated.

Closed by **0061-rs480-parked-gpu-debugfs-readers-hard-return.patch**: one named
helper `rs480_debugfs_refuse_if_parked()` gates all 18 seq_file show readers
(hard-return with an explanatory line); the CP-ME inject write node returns
`-EIO`; and the two shared primitives carry the no-MMIO net
(`rs480_candidate_regs_emit()` refuses before its read loop,
`rs480_candidate_reg_read()` returns the hazard sentinel). No safe/unsafe split.
The one pre-existing upstream `rs400_debugfs_gart_info_show()` is covered too.

Static verification (over the DKMS-order reconstructed tree): every debugfs
reader entry point reads hardware only behind a parked guard. Three functions
read hardware without an in-body guard and are classified out-of-scope, not
regressions: `rs480_cp_me_ram_inject_one` (helper reachable only via the guarded
inject write), `rs480_wedged_3d_reset` (the reset mechanism, which must run on
the first unparked fire; its debugfs callers are guarded), and `rs400_startup` (the
upstream init/resume path, gated by the resume-side patches 0046/0048, not a
debugfs edge). Compile verified through the real DKMS build (`dkms build`
applied the full series and built radeon.ko clean; `makepkg` only packages the
source, so the compile gate is `dkms build`); no fire.

### 2. Module unload of a parked radeon, covered by 0062

`radeon_pci_shutdown` and the module_exit/.remove path
(`radeon_driver_unload_kms` -> `radeon_modeset_fini` / `radeon_device_fini`)
predate `gpu_parked` and issue GPU MMIO on teardown. Neither callback can return
an error, so the rule is no-hardware, not refuse.

Closed by **0062-rs480-parked-gpu-module-unload-no-hardware.patch**:
`radeon_driver_unload_kms` drops to the software free (`done_free`) under
`gpu_parked` on `CHIP_RS400`/`CHIP_RS480`, skipping the hardware fini, the same
shape as the existing `rmmio == NULL` early-out and the leak-by-design park
path; reboot reclaims the leaked structures. `radeon_pci_shutdown` guards its
lone hardware call (a PPC64/Loongson-only `radeon_suspend_kms`; on x86 the block
is compiled out, so the Vostro shutdown path is already hardware-free) behind the
same predicate. Software state only (`rdev->gpu_parked`, `rdev->family`); no new
reads; no live-GPU behaviour change. Compile verified through the real DKMS
build (not makepkg, which only packages): `dkms build` applied 0001-0062 and
built + signed radeon.ko clean, pkgrel 77. Runtime not exercised because a
parked-module unload is not a campaign path (the box reboots). No fire.

### 3. Userspace VRAM mmap SIGBUS gate (0060), covered by static dominance proof

0060 zaps userspace GEM PTEs (`unmap_mapping_range`) and returns `VM_FAULT_SIGBUS`
for VRAM-placed BOs in `radeon_gem_fault`. Fire 28 proved host survival but
changed both the gate and the client freeze/thaw procedure, so it did not isolate
the SIGBUS arm. A later targeted refault fire on RS482 drove one SIGUSR1
re-touch into a zapped mapping and observed the arm (si_code BUS_ADRERR,
breadcrumb match, boot_id stable), retained as steinmarder-r300 bundle
`rs480_sigbus_refault_fire_rs482_20260803T030621Z`. The fire ran on the
dev-profile module, whose 0060 gate source is identical to prod, and park is
reachable only through the armed dev reset node, so this is the only obtainable
evidence.

Closed by a static dominance proof (docs/rs480-0060-sigbus-dominance-proof.md):
in `radeon_gem_fault` the `gpu_parked && mem_type == TTM_PL_VRAM` gate returns
SIGBUS before the first lock (`down_read(mclk_lock)`), the first sleeping BO
reservation (`ttm_bo_vm_reserve`), the first TTM driver callback
(`radeon_bo_fault_reserve_notify`), the aperture/PTE map
(`ttm_bo_vm_fault_reserved`), and any register access; and the park-path
`unmap_mapping_range(anon_inode->i_mapping, 0, 0, 1)` tears down every PTE in the
device GEM address space (COW included), so every later touch refaults into that
gate. GTT/system BOs fall through (placement-scoped to VRAM), which is correct for the
gate and for containment. A later discriminator fire measured that scope on the
same silicon
(`rs480_parked_gem_placement_discriminator_rs482_20260804T041115Z`): a held VRAM
mapping took SIGBUS while a held GTT mapping completed its touch, and no client
in the parked window returned `VM_FAULT_RETRY`, so the fall-through terminates
rather than spinning. A client opened after park is admitted through `open`,
`GEM_CREATE`, and `GEM_MMAP`, and its placement decides its fate: a VRAM request
free VRAM can satisfy lands in VRAM and meets the gate, and only a request
larger than free VRAM would enter the degradation the create path addresses (see
the create/evict residual below). The unlocked-placement residual is closed by
0070, which reserves the BO before the placement test. Covered by static
dominance and by the two retained fires. No code change.

## Enforcement going forward

No reset-behavior change is made from this document. The next radeon-custom
change is the three patches above in order (debugfs guard, unload refusal, 0060
placement proof), one per gap. A `radeon_gpu_parked(rdev)` predicate helper
should name the rule at each new cut edge so future edits are auditable against
this table. Any new patch that adds a hardware-access entry point reachable after
park must add a row here and a `gpu_parked` terminus, or it regresses the
invariant.


## Remaining residuals after 0071

- **fbdev mmap**: 0059 leaves `.fb_mmap = fb_io_mmap`. GEM offset mappings are
  zapped by 0060/0071; a direct `/dev/fb0` mmap is still an uncovered aperture
  edge until gated or refused.
- **System PM resume/thaw**: park skips reset-path PM resume, but
  `radeon_pmops_resume` / thaw on a parked host without reboot is not gated.
- **Backlight and PM sysfs setters**: legacy brightness/sysfs stores can still
  reach display/clock MMIO if userspace writes them after park.
- **In-flight poll/detect**: a detect already inside DDC when park latches can
  still touch hardware until that call returns; new passes are blocked.
- **Init/resume `radeon_asic_reset` outside `radeon_gpu_reset`**: boot-time
  failure paths that never set `gpu_parked` remain a separate residual.
- **Modeset vs reset race**: a modeset that passed the parked check can still
  race a concurrent park before set_config MMIO; exclusive_lock recheck is
  not yet shared across that path.
- **TTM create/evict after park**: userspace GEM create enters TTM in the pinned
  checkpoint, and 0071 clears ring.ready to stop blit moves. The discriminator
  fire measured the funnel: a fresh post-park create is admitted and allocates in
  the requested manager, VRAM included, because the park frees no VRAM and
  fences none off. The create-path refusal `radeon_gem_object_create` returns
  -EIO under `gpu_parked` landed upstream in linux-radeon-gororoba (commit
  `ca70647`) and needs a new signed checkpoint and package re-pin to reach this
  series. It narrows the fresh-client supply without claiming full ioctl gating,
  and it prevents no failure either fire observed, because the fresh VRAM client
  was already terminated by the 0060 gate.
