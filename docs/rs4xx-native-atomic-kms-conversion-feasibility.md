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

**Park gate vs. commit ordering (primary hazard).** Patch
`0050-rs480-parked-gpu-modeset-and-flip-gate.patch` places the failed-reset
containment gate in two legacy entry points: `radeon_crtc_set_config` returns
`0` (no-op success -- accept the modeset, leave the display dark, keep the
host alive) when `rdev->gpu_parked`, and `radeon_crtc_page_flip_target`
returns `-ENODEV`. The rationale in the patch is specific: a modeset against a
parked RS480 re-enables display memory requests into the wedge-held MC client
arbiter, the host interface deadlocks, and the next CPU MMIO read hard-locks
the machine; the fbdev-restore-on-last-close is the trigger. Under atomic,
`.set_config` no longer exists as a driver callback -- it becomes
`drm_atomic_helper_set_config`, and the gate must move. The trap: putting the
`gpu_parked` check in `atomic_check` and returning `-ENODEV`/`-EACCES` makes
the fbdev restore *fail* rather than *succeed-as-no-op*, which changes error
handling on the last-close path and can leave the DRM core retrying. The
correct home is a custom `atomic_commit_tail` (or a `mode_config.helper_private`
commit hook) that, when `gpu_parked`, swaps in the software state but skips all
hardware register writes -- preserving today's "accept the transaction, write
nothing to silicon, console stays down, host survives" semantics. The page-flip
`-ENODEV` maps cleanly onto `drm_atomic_helper_page_flip` returning the same
errno from the same guard. This gate must also continue to hold
`rdev->exclusive_lock` the way `radeon_flip_work_func` does today
(`radeon_display.c:419`), because the parked state is published under that
rw_semaphore and `needs_reset`/`in_reset` (`radeon.h:2388`).

**Global-modeset wedge (fdo #24611).** Legacy `prepare`/`commit` blank every
CRTC before reconfiguring one and re-enable afterward, because the hardware
wedges reconfiguring one CRTC while a sibling scans out. Atomic commit is
per-object by construction; a naive port that touches only the changed CRTC
reintroduces the wedge. The commit must force a blank of sibling CRTCs across
any CRTC mode change -- expressed as a CRTC `atomic_check` that pulls affected
siblings into the state, or an explicit disable/enable sequence in
`atomic_commit_tail`.

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
direct TearFree regression. This path is hardware-validated today
(`MEMORY.md` RS48x runtime oracle 609/609), so it is the highest-value
regression to guard.

**No upstream reference.** Mainline radeon KMS was never converted to atomic
(amdgpu was the atomic-native successor; radeon remains one of the last
legacy-KMS drivers in mainline). There is no upstream conversion to crib from,
so every hook above is first-of-kind for this silicon and carries no
reference-diff safety net.

## 5. Staged plan, and why "native" forces a big-bang core switch

The no-fallback requirement is not a stylistic preference here; the kernel
enforces it. `drm_atomic_helper_commit` walks a `drm_atomic_state` that carries
per-object state for *every* CRTC, plane, encoder, and connector in the commit.
Once `DRIVER_ATOMIC` is set and the core drives modesets through the atomic
ioctl, an object that lacks atomic state and atomic funcs cannot participate --
there is no supported "half-atomic" driver in modern DRM. The historical
*transitional* helpers that let a driver keep legacy `.mode_set` while using
atomic state internally were removed from the core years ago; they are not a
landing target. (The distinct legacy-ioctl helpers
`drm_atomic_helper_set_config`/`_page_flip` remain permanently -- those are how
legacy userspace keeps working *after* conversion, not a partial-conversion
mode.) Therefore the flip of `DRIVER_ATOMIC` plus the CRTC/plane/encoder/
connector funcs is one indivisible change: the module is legacy before it and
atomic after it, with no intermediate buildable half-atomic driver.

What *can* be staged is de-risking and testing work that lands while the
driver is still legacy, so that the big-bang commit is as small and as tested
as possible:

1. **Universal planes first (still legacy).** Register the primary and cursor
   as real `drm_plane` objects via `drm_plane` + legacy plane helpers, exposing
   them to userspace without touching modeset. This isolates and tests the
   plane-programming split (`set_base`, cursor set/move) before the atomic
   switch. Verifiable with `modetest` plane queries; no atomic ioctl involved.
2. **Vblank/timestamp confirmation (still legacy).** Confirm the driver already
   uses `drm_crtc_vblank_helper_get_vblank_timestamp` end-to-end, so the atomic
   switch inherits correct timestamping.
3. **Park-gate relocation design (still legacy).** Land the `gpu_parked`
   containment as a single choke point (a commit hook the atomic path will call)
   so step 4 moves one guard, not two scattered returns.
4. **The atomic switch (indivisible).** Add `DRIVER_ATOMIC`, atomic CRTC/plane/
   encoder/connector funcs, state duplicate/destroy/reset, custom
   `atomic_commit_tail` carrying the fdo-#24611 sibling-blank and the parked
   no-op-write semantics. Bisectable as one commit; not decomposable further
   without shipping a non-building driver.
5. **Regression hardening.** Re-validate TearFree fixed-refresh and the RS48x
   runtime oracle after the switch.

Honest statement: steps 1-3 are real risk reduction but they are not stages of
a partially-atomic driver; step 4 is a single big-bang core conversion that the
no-fallback requirement makes unavoidable.

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

Falsifiable first milestone (future work; read-mostly here): with the primary
and cursor registered as universal `drm_plane` objects on the *still-legacy*
driver, `modetest -p` enumerates a `PRIMARY` and a `CURSOR` plane on each RS482
CRTC and a plane-only `modetest` set-plane on the primary reprograms scanout
base with no change to modeset behavior and no regression in the RS48x runtime
oracle (609/609) or the fixed-refresh TearFree configuration. Falsified if
plane registration perturbs modeset, if the oracle count drops, or if TearFree
tears. This milestone exercises the plane-split delta in isolation before the
irreversible `DRIVER_ATOMIC` switch, and its pass/fail is the gate on whether
step 4 is attempted.
