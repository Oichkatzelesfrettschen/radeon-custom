# 0060 SIGBUS gate: static dominance proof (RAD-05q edge 3)

Fire 28 proved host survival through a parked-GPU teardown but never exercised
0060's `VM_FAULT_SIGBUS` arm, because no thawed client re-faulted a VRAM
mapping. This closes that gap without a hardware fire: a static argument that the
gate dominates every VRAM-mmap refault path. Line citations are against the
DKMS-order patched series (0060 applied over 0001-0059 in `dkms.conf` order,
zero rejects); no arbitrary reconstructed tree, no fire.

The claim is dominator-shaped: on a parked RS480, `gpu_parked && VRAM placement &&
CPU mmap fault` reaches `VM_FAULT_SIGBUS` before any lock, any BO reservation
that can sleep into teardown, any TTM driver callback, any GART/aperture
operation, and any register access; and the park path zaps existing CPU PTEs so
every later access refaults through that gate.

## Half 1 -- the gate dominates the fault handler

`radeon_gem_fault` (radeon_gem.c) in patched order:

```
60  bo   = vmf->vma->vm_private_data;      /* plain read */
61  rdev = radeon_get_rdev(bo->bdev);      /* pointer deref */
62  vm_fault_t ret;
73  if (rdev->gpu_parked &&
74      bo->resource && bo->resource->mem_type == TTM_PL_VRAM) {
75      dev_err_once(...);
77      return VM_FAULT_SIGBUS;            /* <-- the gate */
80  down_read(&rdev->pm.mclk_lock);         /* first lock  */
82  ret = ttm_bo_vm_reserve(bo, vmf);       /* first sleeping BO reservation */
86  ret = radeon_bo_fault_reserve_notify(bo);   /* first TTM driver callback */
90  ret = ttm_bo_vm_fault_reserved(...);    /* the aperture/PTE map */
```

Dominance holds by line order. Everything executed before the gate (lines 60-74)
is plain-memory: a `vm_private_data` read, a `radeon_get_rdev` pointer deref, and
the reads of `rdev->gpu_parked` and `bo->resource->mem_type`. No lock is taken
(the first is `down_read(mclk_lock)` at :80), no BO reservation happens (the
first is `ttm_bo_vm_reserve` at :82, which can sleep into teardown), no TTM
driver callback runs (`radeon_bo_fault_reserve_notify` at :86), no
GART/aperture/PTE operation runs (`ttm_bo_vm_fault_reserved` at :90), and no
register is read anywhere in the function. So for a parked VRAM BO the return at
:77 strictly precedes all of them.

## Half 2 -- the park path forces every VRAM mapping to refault into the gate

The park path (radeon_device.c) zaps the userspace GEM mappings:

```
unmap_mapping_range(rdev_to_drm(rdev)->anon_inode->i_mapping, 0, 0, 1);
```

- **What mapping receives it:** the DRM device's `anon_inode->i_mapping` -- the
  single `address_space` that backs every GEM object CPU mmap for the radeon DRM
  device (DRM routes all GEM mmap offsets through the device anon inode).
- **Does it cover every GEM mmap offset, or a subset:** every one. The args are
  `holebegin = 0`, `holelen = 0` (which `unmap_mapping_range` treats as "to the
  end of the address space"), `even_cows = 1`. So all PTEs in the device GEM
  address space are torn down, COW pages included -- not a subset.
- **Can a pre-existing CPU PTE survive the zap:** no. The zap removes every PTE
  mapping that address_space, so the next userspace touch takes a fresh fault.
  And because `gpu_parked` is already set when the zap runs, that refault hits
  the gate (Half 1) and returns SIGBUS before any VRAM PTE can be re-established
  -- no VRAM mapping can exist past the park point.

## The explicit questions

- **Does `radeon_gem_fault` inspect placement before any hardware or lock path?**
  Yes -- the `mem_type == TTM_PL_VRAM` test is at :74, before the first lock
  (:80) and every hardware/reservation path (:82/:86/:90).
- **GTT / system-memory BOs:** the gate is `TTM_PL_VRAM`-only, so a GTT
  (`TTM_PL_TT`) or system BO falls through and faults normally -- its pages are
  plain system RAM, no aperture read. They do NOT SIGBUS merely because the GPU
  is parked; only VRAM does. Correct by the placement predicate.
- **Non-fault paths (`mmap` setup, `ioctl`, `read`, `write`):** `mmap(2)` setup
  (`drm_gem_mmap`) only builds the vma; it establishes no PTE and touches no
  VRAM -- the first access faults lazily into `radeon_gem_fault` (gated). A
  `read`/`write` against a GEM CPU mapping faults the same way (gated). GEM
  `ioctl`s are a different surface (not the VRAM mmap aperture) and are out of
  0060's scope; their hardware paths are covered by other parked gates
  (fence force-completion, the debugfs/reader gates 0061, GART guard 0049).
  So the only VRAM-aperture route reachable from a CPU mmap is
  `radeon_gem_fault`, and it is gated.

## Residual assumption (stated, not hidden)

The placement read `bo->resource->mem_type` at :74 is unlocked. Under
`gpu_parked` the GPU is terminal: acceleration is off and no BO migration runs,
so a VRAM BO's `mem_type` is stable at `TTM_PL_VRAM` for the life of the parked
state. If a migration could race it to a non-VRAM value the fallthrough would
take the locks and map the aperture -- but no migration occurs post-park, so the
read is stable. A `NULL bo->resource` (nothing placed) also falls through, which
is safe because there is no VRAM page to touch.

## Verdict

The gate statically dominates every VRAM-mmap refault path: the zap guarantees a
refault, and the fault handler returns SIGBUS for a parked VRAM BO before any
lock, reservation, TTM callback, GART/aperture op, or register access. No WD3B
fire is required to establish this; the fire only failed to *observe* the SIGBUS
because no client happened to re-touch VRAM in that run. Edge 3 is closed by this
static dominance argument, no code change.
