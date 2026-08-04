# 0060 SIGBUS gate: static dominance proof (RAD-05q edge 3)

Fire 28 proved host survival through a parked-GPU teardown but never exercised
0060's `VM_FAULT_SIGBUS` arm, because no thawed client re-faulted a VRAM
mapping. This closes that gap without a hardware fire: a static argument that the
gate dominates every VRAM-mmap refault path. Citations are against the
DKMS-order patched series read as a whole, where 0070 later moves the arm under
the BO reservation that 0060 first placed ahead of it, so the handler shape here
is the post-0070 one the shipped module carries; no arbitrary reconstructed
tree.

The claim is dominator-shaped: on a parked RS480, `gpu_parked && VRAM placement &&
CPU mmap fault` reaches `VM_FAULT_SIGBUS` before any TTM driver callback, any
GART/aperture operation, and any register access; and the park path zaps
existing CPU PTEs so every later access refaults through that gate. The arm runs
under the mclk read lock and the BO reservation, which 0070 placed ahead of it
so the SIGBUS decision and the fault path share one reserved view.

## Half 1: the gate dominates the fault handler

`radeon_gem_fault` (radeon_gem.c) in patched order:

```c
bo   = vmf->vma->vm_private_data;      /* plain read */
rdev = radeon_get_rdev(bo->bdev);      /* pointer deref */
down_read(&rdev->pm.mclk_lock);        /* first lock */
ret  = ttm_bo_vm_reserve(bo, vmf);     /* reserve before placement read */
if (rdev->gpu_parked &&
    bo->resource && bo->resource->mem_type == TTM_PL_VRAM) {
    dev_err_once(...);
    ret = VM_FAULT_SIGBUS;             /* <-- the gate under reserve */
    goto unlock_resv;
}
ret = radeon_bo_fault_reserve_notify(bo);  /* first TTM driver callback */
ret = ttm_bo_vm_fault_reserved(...);       /* the aperture/PTE map */
```

Dominance holds on the gated path after 0070: the parked VRAM decision runs only
after `ttm_bo_vm_reserve`, so placement is read under a stable reserved view, and
`VM_FAULT_SIGBUS` returns through `unlock_resv` before
`radeon_bo_fault_reserve_notify` and `ttm_bo_vm_fault_reserved`. On that path no
GART/aperture map and no register access is reached before the SIGBUS return.

## Half 2: the park path forces every VRAM mapping to refault into the gate

The park path (radeon_device.c) zaps the userspace GEM mappings:

```c
unmap_mapping_range(rdev_to_drm(rdev)->anon_inode->i_mapping, 0, 0, 1);
```

- **What mapping receives it:** the DRM device `anon_inode->i_mapping` that the park path passes to
  `unmap_mapping_range` (the mapping 0060/0071 actually zap). A broader claim
  that this is the only address_space for every GEM mmap is not proven here.
- **Does it cover every GEM mmap offset, or a subset:** every one. The args are
  `holebegin = 0`, `holelen = 0` (which `unmap_mapping_range` treats as "to the
  end of the address space"), `even_cows = 1`. So all PTEs in the device GEM
  address space are torn down, COW pages included, and the zap covers every
  entry rather than a subset.
- **Can a pre-existing CPU PTE survive the zap:** no. The zap removes every PTE
  mapping that address_space, so the next userspace touch takes a fresh fault.
  And because `gpu_parked` is already set when the zap runs, that refault hits
  the gate (Half 1) and returns SIGBUS before any VRAM PTE can be
  re-established, so no VRAM mapping survives past the park point.

## The explicit questions

- **Does `radeon_gem_fault` inspect placement before any hardware path?**
  Yes for every hardware path, and after two software ones. Since 0070 the test
  runs under `down_read(&rdev->pm.mclk_lock)` and after `ttm_bo_vm_reserve`, and
  it still precedes `radeon_bo_fault_reserve_notify`, `ttm_bo_vm_fault_reserved`,
  and every GART/aperture and register access. The parked-window tracer confirms
  the shape from the running kernel: both VRAM clients recorded
  `ttm_bo_vm_reserve` returning 0, no `ttm_bo_vm_fault_reserved` call, and
  `radeon_gem_fault` returning `VM_FAULT_SIGBUS`.
- **GTT / system-memory BOs:** the gate is `TTM_PL_VRAM`-only, so a GTT
  (`TTM_PL_TT`) or system BO falls through and faults normally; its pages are
  plain system RAM, no aperture read. They do NOT SIGBUS merely because the GPU
  is parked; only VRAM does. Correct by the placement predicate. The fall-through
  is correct for the gate and for containment, because a non-VRAM BO touches
  system RAM and reads no aperture, so the host survives. The fall-through is
  also measured to terminate: in the discriminator fire a GTT mapping held
  across the park completed its touch, and no client in the parked window
  returned `VM_FAULT_RETRY`. A fresh client opened after park is admitted
  through `open`, `GEM_CREATE`, and `GEM_MMAP`, and its placement decides its
  fate: a VRAM request that free VRAM can satisfy lands in VRAM and meets this
  gate, while a GTT request completes. The degradation of a VRAM request to GTT
  needs a request larger than free VRAM and stays untriggered. That analysis and
  the create-path refusal live in steinmarder-r300 finding
  `src/re/r300/findings/active/2026-08-03-parked-device-fresh-client-fault-placement-rca.md`.
- **Non-fault paths (`mmap` setup, `ioctl`, `read`, `write`):** `mmap(2)` setup
  (`drm_gem_mmap`) only builds the vma; it establishes no PTE and touches no
  VRAM, so the first access faults lazily into `radeon_gem_fault` (gated). A
  `read`/`write` against a GEM CPU mapping faults the same way (gated). GEM
  `ioctl`s are a different surface (not the VRAM mmap aperture) and are out of
  0060's scope; their hardware paths are covered by other parked gates
  (fence force-completion, the debugfs/reader gates 0061, GART guard 0049).
  So the only VRAM-aperture route reachable from a CPU mmap is
  `radeon_gem_fault`, and it is gated.

## Residual assumption (stated, not hidden)

The unlocked-placement-read residual is closed by 0070, which reserves the BO
before the placement test so the SIGBUS decision and the fault path observe one
resource. The argument no longer rests on the terminal-GPU claim that no BO
migration runs post-park.

A `NULL bo->resource` (nothing placed) still falls through, which is safe
because there is no VRAM page to touch and no aperture bus offset to install.

## Verdict

The gate statically dominates every VRAM-mmap refault path: the zap guarantees a
refault, and the fault handler returns SIGBUS for a parked VRAM BO before any
TTM callback, GART/aperture op, or register access. A targeted refault fire on
RS482 corroborates the static argument: it drove one SIGUSR1 re-touch into a
zapped mapping and observed the SIGBUS return (si_code BUS_ADRERR, breadcrumb
match, boot_id stable), retained as steinmarder-r300 bundle
`rs480_sigbus_refault_fire_rs482_20260803T030621Z`. A later discriminator fire
measured the placement scope the proof asserts, retained as
`rs480_parked_gem_placement_discriminator_rs482_20260804T041115Z`: a held VRAM
mapping took SIGBUS while a held GTT mapping completed its touch, with each
placement measured by bracketing the create with `RADEON_INFO_VRAM_USAGE` and
`RADEON_INFO_GTT_USAGE` rather than inferred from the requested domain. Both
fires ran on the dev-profile module, whose gate source is identical to prod, and
park is reachable only through the armed dev reset node. Edge 3 holds by static
dominance and by those two retained fires, no code change.


## Remaining proof residuals

- Pre-zap window: 0071 zaps immediately after latching `gpu_parked` and
  free_irq, before the drain sleeps. A PTE touch strictly between latch and
  zap remains a theoretical race; the window is milliseconds of pure software.
- Post-park TTM create/migrate: GEM create ioctls are not gated in the pinned
  checkpoint, and 0071 clears `ring.ready` to stop blit moves. The discriminator
  fire measured that funnel: a fresh post-park create is admitted and allocates
  in the requested manager, VRAM included, because the park frees no VRAM. The
  create-path refusal `radeon_gem_object_create` returns -EIO under `gpu_parked`
  landed upstream in linux-radeon-gororoba (commit `ca70647`); pinning it here
  needs a new signed checkpoint and package re-pin. It prevents no failure
  either fire observed, since the fresh VRAM client was already terminated by
  this gate, so it narrows the supply without proving full TTM quiescence and
  without an established necessity.
- fbdev `/dev/fb0` mmap is outside the GEM offset zap (see parked-access audit).
