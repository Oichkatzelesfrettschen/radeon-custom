# RS4xx native DRM atomic modesetting conversion feasibility

Status: proposed. This document analyzes converting the RS480/RS482/RS485
display path in the radeon KMS module to native DRM atomic modesetting
(`drm_atomic_state`, per-object plane/CRTC/connector state, atomic
check/commit) with no legacy transitional fallback retained. It is a
design/feasibility study produced read-mostly against the unified DKMS
source snapshot (`sources/radeon-unified-0.3-source.tar.xz`). It builds
nothing, loads no module, and touches no hardware. Claims about silicon
behavior remain owned by `steinmarder-r300`; this document may promote a
conversion claim only to `proposed`.

Motivation is architectural, not feature-driven. The live RS482 feasibility
gate found `DRM_CLIENT_CAP_ATOMIC` unsupported, no `vrr_capable` or
`VRR_ENABLED` properties, and a zero-byte LVDS EDID. VRR is ruled out.
Atomic conversion is pursued for deterministic transactional commits, for
testability, and as the only architecture from which such properties could
ever be revisited.

## 1. CPU atomics are orthogonal to DRM atomic modesetting

"Atomic" names two unrelated things, and conflating them is the first error
to close. DRM atomic modesetting is a *transactional* display-configuration
API: the kernel assembles a `drm_atomic_state` holding the proposed state of
every affected CRTC, plane, encoder, and connector, validates the whole set
in one `atomic_check`, and then either commits it as a unit or rejects it as
a unit. The transaction boundary is a software data-structure discipline
inside the DRM core. It is independent of any x86 compare-exchange
instruction.

The CPU atomics the kernel actually consumes underneath DRM are word-width
primitives: `atomic_t` and `refcount_t` counters, `ww_mutex`
(wound/wait mutexes, which the atomic commit path uses to acquire per-object
locks in a deadlock-free order), `qspinlock`, and RCU. On x86-64 these lower
to `LOCK XADD` and `LOCK CMPXCHG` on 32-bit and 64-bit operands, an ISA
surface present since the i486. Nothing in `drm_atomic_helper_commit`,
`drm_atomic_helper_check`, or per-object state duplication needs a 128-bit
compare-exchange.

The K8 corpus in `vostro1000-re` closes the platform question a fortiori by
showing the floor sits far above that requirement. The base compare-exchange
forms are present and promoted:

- `CMPXCHG` (opcodes `0F B0` / `0F B1`), the 8/16/32/64-bit form that
  `atomic_cmpxchg`, `qspinlock`, and `ww_mutex` compile to.
- `CMPXCHG8B mem64` (`0F C7 /1 m64`), the 64-bit double-word form.
- `CMPXCHG16B mem128` (`0F C7 /1 m128`), gated on `CPUID.00000001:ECX[13]`
  (`CX16`), the 128-bit form
  (`systems/dell-vostro-1000/cpu-microcode/k8-apm-cmpxchg16b-fldenv-promotion-corpus.tsv`,
  row `apm-cmpxchg16b-fldenv-387b19cedc538944`, with the long-mode
  addressing-model expansion retained under
  `evidence/captures/k8-cmpxchg16b-m128-long64-addressing-model-426f72726dcd47e2/`).

Even the 128-bit primitive that DRM atomic does not need is present and is
consumed elsewhere in the kernel (slub and percpu `cmpxchg_double`/`cmpxchg128`
fast paths). The platform therefore satisfies every atomic primitive the DRM
core and its helpers require, with margin. The CPU-atomics question is closed:
it never constrained the display conversion, and the corpus confirms the
silicon exceeds the requirement rather than merely meeting it.

Do not read this the other way around. `CX16` does not "enable" atomic
modesetting; atomic modesetting would work identically on a K8 stepping
lacking `CX16`. The two share a word only.

## 2. Object inventory for the RS4xx display path

RS480/RS482/RS485 is an r4xx-class IGP that carries a COMBIOS ROM, not an
atombios ROM
(`vostro1000-re:systems/dell-vostro-1000/gpu-rs482-combios/combios-table-walk.md`).
In the module this sets `rdev->is_atom_bios == false`, which routes the
display path through the legacy (non-atombios) code. The atombios files
(`atombios_crtc.c`, `atombios_encoders.c`) are present in the build but are
not the RS4xx path. Evidence: `radeon_display.c:712` gates AVIVO/atom CRTC
selection on `rdev->is_atom_bios && (ASIC_IS_AVIVO(rdev) || radeon_r4xx_atom)`;
r4xx COMBIOS parts fall to the legacy encoders and legacy CRTC. The objects
that implement the live path today:

| Object | File / symbol | Role today |
| --- | --- | --- |
| Driver flags | `radeon_drv.c:622` `.driver_features = DRIVER_GEM \| DRIVER_RENDER \| DRIVER_MODESET` | No `DRIVER_ATOMIC`. This flag absence is exactly why the live gate saw `DRM_CLIENT_CAP_ATOMIC` unsupported: the core gates that client cap on `DRIVER_ATOMIC`. |
| CRTC funcs | `radeon_display.c:668` `radeon_crtc_funcs` | Legacy `.set_config = drm_crtc_helper_set_config`, `.page_flip_target`, `.get_vblank_counter`, `.enable/disable_vblank`, `.get_vblank_timestamp = drm_crtc_vblank_helper_get_vblank_timestamp`. |
| CRTC helper | `radeon_legacy_crtc.c:1109` `legacy_helper_funcs` | `.dpms`, `.mode_fixup`, `.mode_set`, `.mode_set_base`, `.mode_set_base_atomic`, `.prepare`, `.commit`, `.disable`. Classic CRTC-helper (non-atomic) callback set. |
| CRTC mode program | `radeon_legacy_crtc.c:1038` `radeon_crtc_mode_set` | Programs scanout base, CRTC timing, PLL, overscan, RMX scaling (CRTC0 only), cursor reset. |
| CRTC prepare/commit | `radeon_legacy_crtc.c:1064` / `:1077` | `prepare` blanks *all* CRTCs (fdo #24611: the hardware wedges reconfiguring one CRTC while a sibling runs); `commit` re-enables the CRTCs marked enabled. This is a global-modeset ordering invariant. |
| Primary plane (implicit) | `radeon_legacy_crtc.c:360` `radeon_crtc_set_base` | Scanout address / display-fetch programming. There is no `drm_plane` object; the primary is folded into the CRTC. |
| Cursor plane (implicit) | `radeon_cursor.c` `radeon_crtc_cursor_set2` / `radeon_crtc_cursor_move` | Cursor BO bind, hotspot, position. No `drm_plane`; driven through legacy cursor ioctls on the CRTC. |
| Encoders | `radeon_legacy_encoders.c` LVDS `:273`, primary DAC `:709`, internal TMDS `:874`, external TMDS `:1017`, TV DAC `:1675` | `drm_encoder_helper_funcs` (dpms/mode_set/prepare/commit style). LVDS is the panel path for the Vostro internal display. |
| Connectors | `radeon_connectors.c` LVDS `:943`, VGA `:1077`, TV `:1165`, DVI `:1487` | `drm_connector_helper_funcs` (get_modes / mode_valid / best_encoder) plus legacy `.detect`/`.dpms` in the connector funcs. |
| Page flip | `radeon_display.c:478` `radeon_crtc_page_flip_target`, `:406` `radeon_flip_work_func` | Async worker: waits on the flip fence under `rdev->exclusive_lock`, busy-waits out of the target vblank (pre-AVIVO parts lack a reliable flip-done IRQ), then does the MMIO flip and arms the pflip IRQ. |
| Vblank | `radeon_display.c:282` `radeon_crtc_handle_vblank`, `radeon_get_crtc_scanoutpos`, `radeon_get_vblank_counter_kms` | Scanout-position based flip-completion accounting; hand-tuned vblank-window fudging for old ASICs. |

## 3. The conversion surface, per object

Native atomic sets `.driver_features |= DRIVER_ATOMIC`, replaces the legacy
CRTC funcs/helpers with atomic ones, and adds real `drm_plane` objects. The
DRM core then routes every modeset and flip through `drm_atomic_check_only`
and `drm_atomic_helper_commit`. Per object:

- **CRTC.** Add `atomic_check` (validate mode + active + plane assignment),
  `atomic_begin`/`atomic_flush`, `atomic_enable`, `atomic_disable`, and
  `mode_set_nofb`. Replace `.set_config`/`.page_flip` in the CRTC funcs with
  `drm_atomic_helper_set_config` / `drm_atomic_helper_page_flip`. Add
  `.atomic_duplicate_state`/`.atomic_destroy_state`/`.reset` using
  `drm_atomic_helper_crtc_*` defaults. Today's `radeon_crtc_mode_set` body
  splits: PLL/timing/overscan into `mode_set_nofb`, scanout base into the
  primary plane. Today's `prepare`/`commit` all-CRTC blank/unblank invariant
  (fdo #24611) must be reproduced in the commit ordering (see hazards).
- **Primary plane.** New `drm_plane` (type `PRIMARY`) wrapping
  `radeon_crtc_set_base`. Needs `atomic_check` (format, scaling limits,
  CRTC-fill for primaries) and `atomic_update` (program scanout base) plus
  `atomic_disable`. This is additive code, not a rewrite of an existing hook.
- **Cursor plane.** New `drm_plane` (type `CURSOR`) wrapping
  `radeon_crtc_cursor_set2`/`_move`. `atomic_update` programs BO/hotspot/pos;
  `atomic_disable` hides it. Also net-new object code.
- **Encoders.** `drm_encoder_helper_funcs` gains `atomic_check`/`atomic_mode_set`
  and `atomic_enable`/`atomic_disable` (or reuse dpms via the atomic helper
  bridge). The LVDS/DAC/TMDS/TV bodies port largely unchanged.
- **Connectors.** Add `.atomic_duplicate_state`/`.atomic_destroy_state`/`.reset`
  via `drm_atomic_helper_connector_*`; keep `.detect` and the helper
  `get_modes`/`mode_valid`. Connector state is mostly boilerplate.
- **State objects.** Each of CRTC/plane/connector gets duplicate/destroy/reset.
  The stock `__drm_atomic_helper_*_duplicate_state` defaults suffice unless a
  driver-private state field is added (none is required for the base port).

Park/reset interaction with commit ordering is the load-bearing delta and is
analyzed in Section 4.

## 4. Hazard analysis

**Park gate vs. commit ordering (primary hazard, unresolved design).** Patch
`0050-rs480-parked-gpu-modeset-and-flip-gate.patch` places the failed-reset
containment gate in two legacy entry points: `radeon_crtc_set_config` returns
`0` (no-op success -- accept the modeset, leave the display dark, keep the
host alive) when `rdev->gpu_parked`, and `radeon_crtc_page_flip_target`
returns `-ENODEV`. The rationale in the patch is specific: a modeset against a
parked RS480 re-enables display memory requests into the wedge-held MC client
arbiter, the host interface deadlocks, and the next CPU MMIO read hard-locks
the machine; the fbdev-restore-on-last-close is the trigger. Under atomic,
`.set_config` no longer exists as a driver callback -- it becomes
`drm_atomic_helper_set_config`, and the gate must move. Where it moves is not
settled; it is three candidates, each with a stated advantage and a stated
problem, and none is adopted here:

- **(A) Intercept in `mode_config_funcs.atomic_commit`, before
  `drm_atomic_helper_swap_state`.** Advantage: rejecting or diverting the
  commit before software state is published keeps software state and hardware
  state consistent -- nothing claims a mode is active when it is not.
  Problem: legacy last-close (fbdev restore) wants "accept the transaction,
  write nothing, succeed" (no-op success), while an atomic client issuing the
  same commit needs an honest completion (success or failure that reflects
  what actually happened), and a single intercept point cannot give both
  callers a different truth about the same commit without inspecting caller
  identity, which the atomic ioctl does not reliably expose at this point.
- **(B) Canonical parked state via `atomic_check` conversion to an
  inactive/dark state.** Convert the requested state to a forced-inactive
  state inside `atomic_check`, so the software state honestly reflects "off"
  rather than pretending the requested mode is live. Advantage: software
  state stays truthful -- no divergence between what `drm_atomic_state`
  claims and what silicon is doing. Problem: even the hardware-off sequence
  (disabling a CRTC, tearing down PLL/timing) may itself touch registers the
  park containment forbids touching on a wedged MC client arbiter; "turn it
  off safely" is not proven free of the same host-lockup risk as "turn it on."
- **(C) Custom `atomic_commit_tail` with fake completion (closest to the
  patch's current legacy behavior).** Swap in the software state but skip all
  hardware register writes, then synthesize a fake completion. Must prove
  every completion/lifetime rule the DRM core assumes still holds: page-flip
  events, `OUT_FENCE` signaling, `drm_crtc_commit` completion, `commit_hw_done`,
  `commit_cleanup_done`, framebuffer reference lifetime, and fbdev's belief
  about what is on screen. Accepts, as an explicit and intentional property,
  a software/hardware divergence (the atomic core believes a mode is active
  that silicon never programmed).

None of (A)/(B)/(C) is provably correct without exercising it against a
concrete state-machine test matrix on real hardware. The required matrix,
host-only until it is run:
{legacy `set_config`, legacy page flip, atomic modeset, atomic nonblocking
flip} x {event present, event absent} x {out-fence present, out-fence absent}
x {park before `atomic_check`, park between `atomic_check` and commit, park
during an outstanding commit}. State plainly: the parked-GPU problem is a
complete atomic-transaction terminal state -- every point in that matrix needs
a defined, tested outcome -- not the location of one conditional. This gate
must also continue to hold `rdev->exclusive_lock` the way
`radeon_flip_work_func` does today (`radeon_display.c:419`), because the
parked state is published under that rw_semaphore and `needs_reset`/
`in_reset` (`radeon.h:2388`), regardless of which candidate is chosen.

**Global-modeset wedge (fdo #24611), modeled as global atomic state.** Legacy
`prepare`/`commit` blank every CRTC before reconfiguring one and re-enable
afterward, because the hardware wedges reconfiguring one CRTC while a sibling
scans out. Atomic commit is per-object by construction; a naive port that
touches only the changed CRTC reintroduces the wedge, and neither "pull
siblings into the state ad hoc" nor "manually blank in `commit_tail`" gives
the invariant a canonical, checkable home. The kernel's own recommendation for
cross-object global resources is `drm_private_obj`/`drm_private_state`
(docs.kernel.org, "Atomic Mode Setting Function Reference", private-object
section): a driver-owned piece of atomic state that any CRTC's `atomic_check`
can acquire, mutate, and have validated as part of the same transaction,
giving the global invariant the same duplicate/check/swap/commit discipline
every other atomic object gets. Sketch:

```c
struct radeon_legacy_display_state {
        struct drm_private_state base;
        bool global_modeset;
        u32 active_crtc_mask;
        u32 blank_before_program_mask;
        u32 enable_after_program_mask;
};
```

`atomic_check` on any CRTC acquires this private state via
`drm_atomic_get_private_obj_state`, detects a mode, PLL, or timing transition
on that CRTC, adds every affected sibling CRTC into the atomic state (as
`drm_atomic_add_affected_connectors`/plane equivalents already do for other
cross-object constraints), and rejects any state that cannot include all
required siblings (e.g. a sibling currently owned by a concurrent commit).
Commit sequences as: blank all CRTCs in `blank_before_program_mask`, program
PLL/timing/encoders, program planes, restore (`enable_after_program_mask`),
then complete events. This gives the fdo-#24611 invariant one canonical,
atomic-checked home instead of a scattered set of manual blank calls.

**Prerequisite: a real dual-CRTC test configuration.** The invariant modeled
above governs sibling-CRTC interaction, and LVDS-only cannot exercise it --
there is only one active CRTC in that configuration, so no test run against
LVDS alone can prove or falsify the global-modeset invariant. A real
second-output configuration (external VGA on the Vostro, or an equivalent
dual-output RS4xx configuration) must be in hand and validated before any
`DRIVER_ATOMIC` attempt proceeds.

**Vblank timestamp semantics.** Today the CRTC funcs already delegate to
`drm_crtc_vblank_helper_get_vblank_timestamp` and a scanout-position callback,
which is the atomic-compatible interface, so timestamps port cleanly. The risk
is flip-completion *timing*, not timestamping: `radeon_flip_work_func`
busy-waits out of the target vblank because pre-AVIVO parts lack a reliable
flip-done IRQ. `drm_atomic_helper_page_flip` plus the helper commit model must
preserve that busy-wait (in the driver's `atomic_flush`/commit worker), or
flips will complete at the wrong edge and mis-report completion events.

**Cursor-vs-flip interaction.** Promoting the cursor to a real `drm_plane`
means cursor updates and page flips can now arrive in the same atomic commit.
Legacy code drives them through independent ioctl paths with the cursor folded
into the CRTC; the atomic commit must order cursor register writes and scanout
base writes within one `atomic_flush` without tearing, and must keep the
pre-AVIVO flip busy-wait from stalling a cursor-only commit.

**TearFree (xf86-video-ati DDX) interaction.** The DDX uses legacy KMS ioctls,
not the atomic ioctl. Advertising `DRIVER_ATOMIC` does not make it switch:
legacy userspace continues to issue legacy ioctls, and the DRM core routes them
through `drm_atomic_helper_set_config`/`_page_flip` transparently. The cap
advertisement is therefore not itself the regression surface. The real risk to
the currently-validated fixed-refresh TearFree configuration is flip-completion
timing: TearFree depends on page flips landing in vblank, and the conversion
replaces the hand-tuned `radeon_crtc_page_flip_target` completion path with the
helper commit model. Any drift in when the flip-done event is emitted is a
direct TearFree regression. This path is hardware-validated today, and the
609/609 count in `MEMORY.md` is the gradient rendercheck result, not TearFree
timing -- it does not stand in for TearFree evidence. The actual TearFree
evidence set is: categorical camera-recorded tear elimination (off/on), a
flip rate of 59.19 of a 59.94 Hz target, a VT-switch pass, a DPMS pass, a
300-second soak pass, and a mode change that survives with two nonfatal
`drmmode_do_crtc_dpms` vblank-counter EEs. The atomic conversion's regression
requirement against that evidence set is: no visible tearing, flip rate within
baseline tolerance, no increase in flip-completion failures, VT-switch and
DPMS green, no new kernel reset or fault lines, and the mode-change diagnostic
no worse than baseline -- preferably the vblank-counter EE (Section 4,
RADEON-DISPLAY-VBLANK-01) is attributed and fixed before the switch, so the
post-conversion acceptance criterion is zero errors rather than "no worse."
This is the highest-value regression to guard.

**Pre-switch blocker: RADEON-DISPLAY-VBLANK-01.** The mode-change
`drmmode_do_crtc_dpms` vblank-counter EE noted above is a named RCA lane, not
an accepted baseline wart. It must be attributed to one of: DDX ordering
(the DPMS/mode-change sequence reads the vblank counter before the CRTC is
ready), an expected read-while-disabled condition (the counter is read while
the CRTC is intentionally inactive and the EE is a logging artifact, not a
fault), kernel bookkeeping (the vblank core's enable/disable accounting is
off by one transition), or a hardware counter limit (the RS48x scanout
counter itself is unreliable across a mode change). RADEON-DISPLAY-VBLANK-01
must close, with an attributed cause and either a fix or a documented
accepted-benign classification, before the atomic switch (Section 5, step 2),
so the atomic conversion is validated against a clean baseline rather than a
baseline carrying an unattributed error.

**No upstream reference.** Mainline radeon KMS was never converted to atomic
(amdgpu was the atomic-native successor; radeon remains one of the last
legacy-KMS drivers in mainline). There is no upstream conversion to crib from,
so every hook above is first-of-kind for this silicon and carries no
reference-diff safety net.

## 5. Staged plan, and why the atomic-UAPI boundary forces one indivisible switch

The indivisible unit is narrower than "the driver": it is the atomic-UAPI
boundary specifically -- `DRIVER_ATOMIC` advertisement, `mode_config`
`atomic_check`/`atomic_commit`, CRTC atomic state plus atomic callbacks,
primary-plane atomic state plus atomic callbacks, connector state, the commit
sequencing that walks them together, and the legacy-ioctl-to-atomic-state
translation (`drm_atomic_helper_set_config`/`_page_flip`). Once `DRIVER_ATOMIC`
is set and the core drives modesets through `drm_atomic_helper_commit`, that
walk touches every CRTC, plane, and connector in the commit as a single
`drm_atomic_state`, and an object missing atomic state/funcs cannot
participate -- there is no supported "half-atomic" driver at that boundary.
The historical *transitional* helpers that let a driver keep legacy
`.mode_set` while using atomic state internally were removed from the core
years ago; they are not a landing target.

That boundary is narrower than the object inventory in Section 2, and much of
the inventory can be staged and tested *while the driver still advertises no
`DRIVER_ATOMIC` and routes through the legacy CRTC funcs*. The DRM atomic
helpers already run parts of this bridge for other drivers mid-migration: per
docs.kernel.org's KMS-helpers reference, the atomic helper commit path still
invokes legacy encoder `mode_set` and even deprecated `.commit`/`.prepare`
bridge callbacks on encoders that have not been converted, precisely so plane
and CRTC atomic conversion can land ahead of a full encoder rewrite.
Object-level readiness for this driver, before the boundary flips:

- Plane objects (primary and cursor `drm_plane` registration, Milestone 1/2
  below) build and are testable under the legacy CRTC funcs today; a
  `drm_plane` does not require an atomic CRTC to exist.
- State allocation and duplicate/destroy/reset boilerplate for CRTC, plane,
  and connector objects can be written and unit-exercised (state alloc/dup/
  free without ever being handed to `atomic_check`) before the switch.
- Connector state and the `.detect`/`get_modes`/`mode_valid` helper surface
  are already atomic-shaped (Section 3) and do not change behavior when
  staged early.
- Encoder callback bridging: encoder bodies do **not** all require
  simultaneous rewrite. As the helper docs above establish, the atomic core
  calls into legacy encoder `mode_set`/`prepare`/`commit` during a
  partially-converted encoder set; LVDS/DAC/TMDS/TV encoder bodies can port
  encoder-by-encoder, verified against the CRTC/plane atomic conversion, as
  long as each encoder exposes at minimum the bridge callback the helper
  expects for its conversion state.
- Validation helpers (format checks, CRTC-fill checks for the primary,
  scaling-limit checks) and inactive scaffolding (unused `atomic_check`
  stubs that reject non-trivial states) can be written and code-reviewed
  without `DRIVER_ATOMIC` ever being set.

None of that staged work flips `DRIVER_ATOMIC`. What remains genuinely
indivisible is the boundary crossing itself: the moment `DRIVER_ATOMIC` is
set, `mode_config.atomic_check`/`atomic_commit` must be wired, the CRTC and
primary-plane atomic callbacks must be complete and correct (not stubs), and
connector state and commit sequencing must all agree, because the core's
single `drm_atomic_state` walk does not tolerate a partially-wired object
inside a live atomic ioctl. (The distinct legacy-ioctl helpers
`drm_atomic_helper_set_config`/`_page_flip` remain permanently -- those are how
legacy userspace keeps working *after* conversion, not a partial-conversion
mode.)

Staged plan:

1. **Universal planes first (still legacy).** Register the primary and cursor
   as real `drm_plane` objects via `drm_plane` + legacy plane helpers, exposing
   them to userspace without touching modeset. This isolates and tests the
   plane-programming split (`set_base`, cursor set/move) before the atomic
   switch. Verifiable with `modetest` plane queries; no atomic ioctl involved.
   Split into Milestone 1 (primary) and Milestone 2 (cursor) per Section 6.
2. **Vblank/timestamp confirmation (still legacy).** Confirm the driver already
   uses `drm_crtc_vblank_helper_get_vblank_timestamp` end-to-end, so the atomic
   switch inherits correct timestamping. Attribute and fix the mode-change
   vblank-counter EE (RADEON-DISPLAY-VBLANK-01, Section 4) before proceeding.
3. **Encoder-by-encoder atomic callback conversion (still legacy at the
   boundary).** Port LVDS, primary DAC, internal TMDS, external TMDS, and TV
   DAC encoder bodies to atomic callbacks one at a time, relying on the
   helper's legacy-encoder bridge (docs.kernel.org drm-kms-helpers) to keep
   unconverted siblings functional during the port. This is staging work, not
   the boundary crossing, as long as `DRIVER_ATOMIC` stays unset.
4. **Park-gate design closure (still legacy, currently unresolved -- see
   Section 4).** The `gpu_parked` containment relocation is not yet a design
   decision; it is three candidate designs with unresolved tradeoffs and a
   required state-machine test matrix. This must close, with an attributed
   choice and a passing test matrix, before step 5.
5. **The atomic-UAPI boundary switch (indivisible).** Add `DRIVER_ATOMIC`,
   `mode_config.atomic_check`/`atomic_commit`, CRTC atomic state and
   callbacks, primary-plane atomic state and callbacks, connector state, and
   commit sequencing, carrying the fdo-#24611 global-modeset invariant
   (Section 4, modeled as `drm_private_obj` global state) and the chosen
   parked-GPU semantics. Bisectable as one commit; not decomposable further
   without shipping a driver that cannot pass a live atomic ioctl through a
   consistent `drm_atomic_state`.
6. **Regression hardening.** Re-validate TearFree fixed-refresh (Section 4
   evidence set) and the RS48x runtime oracle after the switch.

Honest statement: steps 1-4 are real risk reduction, much of it building and
testable while the driver is legacy at the atomic-UAPI boundary; step 5 is the
one point the no-fallback requirement makes genuinely indivisible.

## 6. Effort/risk verdict and falsifiable first milestone

Verdict: feasible but high-risk, low external leverage. The mechanical port
(encoders, connectors, state boilerplate) is routine. The concentrated risk is
in three places that are all hardware-timing- or containment-sensitive and have
no upstream reference: the parked-GPU commit semantics (host-survival is the
acceptance property and a wrong `atomic_check`-vs-`commit_tail` choice regresses
it), the fdo-#24611 global-blank invariant, and the pre-AVIVO flip-completion
timing that the validated TearFree path depends on. Because mainline radeon was
never converted, the effort/payoff that upstream declined applies here too: the
payoff is architectural (deterministic commits, testability, a future
property-revisit surface), not a working feature, since VRR is already ruled
out on this silicon. Estimated effort is moderate for the port and dominated by
the validation campaign, which must be an attended RS482 run under the existing
hazard preflight.

Falsifiable first milestones (future work; read-mostly here) are split by
plane, because the primary and cursor carry different DRM constraints and
different regression surfaces:

**Milestone 1: primary plane only.** DRM requires exactly one unique
`PRIMARY` plane per CRTC, so this milestone registers only that plane on the
*still-legacy* driver. Host gates (no hardware involved): DKMS build clean,
sparse/smatch/clang static analysis clean, format-table and
`possible_crtcs` unit checks pass, legacy `set_config` and page-flip
regression tests pass. Hardware gates (X stopped, attended RS482 run): `modetest`
enumerates one `PRIMARY` plane per CRTC, legacy modeset works unchanged,
plane-only `modetest` set-plane reprograms the scanout base successfully, no
new vblank diagnostics appear, and after X is restarted TearFree (evidence
set above) and the 609/609 gradient rendercheck result are both unchanged.
Falsified if plane registration perturbs modeset, if the rendercheck count
drops, or if TearFree tears.

**Milestone 2: cursor plane, separately.** Promoting the cursor to a real
`drm_plane` is validated only after Milestone 1 passes, and carries its own
documented warning: userspace must not mix explicit cursor-plane atomic-style
ops with the legacy cursor ioctls (`DRM_IOCTL_MODE_CURSOR`/`_CURSOR2`) in the
same session -- the two paths drive the same hardware cursor register set and
an interleaving is unspecified. Test order: legacy Xorg cursor behavior first
(confirm no regression from Milestone 1), then explicit cursor-plane ops on
an isolated VT (not concurrent with the legacy Xorg session), then
cursor-only plane updates tested separately from flip-carrying commits so a
cursor-plane regression cannot be confused with a primary-plane or flip
regression.

Each milestone's pass/fail is a gate: Milestone 1 must pass before Milestone
2 is attempted, and both must pass before the park-gate design (Section 4)
closes and step 5's `DRIVER_ATOMIC` switch (Section 5) is attempted.

**VRR does not reopen.** Atomic conversion, if completed, provides property
*architecture* -- the `vrr_capable`/`VRR_ENABLED` connector and CRTC
properties become expressible in the object model. It provides neither panel
timing range, nor sink support, nor RS482 display-engine capability for
variable refresh. The live RS482 feasibility gate (see Motivation, above)
already found no `vrr_capable` property, no `VRR_ENABLED` property, and a
zero-byte LVDS EDID; none of that changes because the driver becomes atomic.
VRR remains closed-negative on this system regardless of whether the
conversion in this document is ever attempted.
