/*
 * radeon_palm_cs_observer.h: read-only CS validator observer for
 * the radeon-palm-gate DKMS package.
 *
 * Public hook surface called from radeon_cs.c with an
 * `if (unlikely(palm_cs_observer_enabled))` guard at each callsite.
 * When the observer is disabled (default), every entry point
 * compiles down to a single load + branch and returns immediately.
 *
 * Body / debugfs / module-param plumbing in radeon_palm_cs_observer.c.
 * Four hook bodies fire at successive validator-pipeline positions:
 * cs_ioctl_entry (radeon_cs_ioctl prologue), ib_chunk_pre_parse
 * (post radeon_cs_parser_init), packet_decode + ib_post_validate
 * (pre radeon_cs_parser_fini, walking the post-validator IB).
 *
 * Design source-of-truth:
 *   src/re/r600/findings/active/2026-05-21-radeon-palm-cs-observer-design.md
 */

#ifndef RADEON_PALM_CS_OBSERVER_H
#define RADEON_PALM_CS_OBSERVER_H

#include <linux/stddef.h>
#include <linux/types.h>

struct radeon_cs_parser;
struct drm_radeon_cs;

/* Module-load / module-unload entry points, called from radeon_init /
 * radeon_exit in radeon_drv.c.  Failure from _init is non-fatal: the
 * observer goes inert (palm_cs_observer_enabled stays 0) but radeon
 * still loads.  _cleanup MUST be idempotent so partial-init paths can
 * unwind safely.
 */
int  radeon_palm_cs_observer_init(void);
void radeon_palm_cs_observer_cleanup(void);

/* Cheap enable check.  Implementation is out-of-line in
 * radeon_palm_cs_observer.c (one READ_ONCE of the module-param
 * variable, so each callsite pays a function call + a load + a
 * branch when the observer is disabled; with -O2 LTO the call is
 * typically elided and the cost reduces to load + branch).  False
 * short-circuits all emitters.  An earlier comment claimed
 * "placed in the header so callers compile to a single load +
 * branch"; that was aspirational for header-only inline expansion,
 * which the present declaration does NOT provide.  If callsite
 * overhead becomes measurable, promote the body to a `static
 * inline` definition in the header reading an `extern bool`
 * variable.
 */
bool radeon_palm_cs_observer_active(void);

/* Full admit check: cheap-enable + comm filter (current->comm equals
 * palm_cs_observer_comm) + per-tgid event cap.  Increments the
 * per-tgid counter on a true return so successive calls naturally
 * hit the cap.  Single-row emit bodies (e.g. cs_ioctl_entry) call
 * this once at top to short-circuit non-matching tasks, dropped
 * events, and the disabled fast path without paying any per-event
 * allocation cost.  Multi-row emit bodies use the split form (cheap
 * enabled_and_filtered() at top + per-row pid_admit() inside the
 * loop) so the per-tgid cap is enforced per emitted row, not per
 * submission.
 *
 * Returns true exactly when the caller should proceed to write an
 * event; returns false when disabled, comm-mismatched, or per-tgid-
 * cap exceeded.  The overflow-once dmesg warning is emitted on the
 * transition from under-cap to at-cap so logs do not get spammed.
 */
bool radeon_palm_cs_observer_should_emit(void);

/* Append one already-formatted JSONL line (must end with '\n') to the
 * per-module shared ring buffer.  Spinlock-serialised.  If the ring
 * cannot fit the line, the line is dropped whole and an overflow
 * counter is bumped (no partial writes).  Called from the four hook
 * emit bodies; should_emit() must return true before calling.
 *
 * The line is byte-copied into the ring; the caller's buffer can be
 * freed or reused on return.  Empty / NULL lines are silently
 * ignored.  Lines longer than the ring's total size are dropped
 * with the overflow counter bumped (matches behaviour for ring-full
 * cases).
 */
void radeon_palm_cs_observer_ring_emit_line(const char *line, size_t len);

/* Hook 1: called from radeon_cs_ioctl prologue, AFTER the DRM
 * dispatcher copied the fixed-size drm_radeon_cs args struct from
 * userspace, but BEFORE radeon_cs_parser_init runs.  `user_data` is
 * the kernel-side copy of the userspace ioctl args (= drm_radeon_cs *
 * after a cast); the per-chunk array it points at is still in user
 * memory and must be copy_from_user'd to be read (the
 * ib_chunk_pre_parse hook below dereferences it after the parser
 * has copied it into kernel memory).
 */
void radeon_palm_cs_observer_emit_cs_ioctl_entry(void *user_data);

/* Hook 2: called after radeon_cs_parser_init has copy_from_user'd
 * the chunks[] array.  Emits one ib_chunk_pre_parse JSONL row per
 * non-empty chunk with chunk_id, length_dw, crc32_le over the full
 * chunk content, and the first up-to-64 dwords as hex.
 */
void radeon_palm_cs_observer_emit_ib_chunk_pre_parse(
	struct radeon_cs_parser *parser);

/* Hook 3+4 merged: called after the chip-specific cs_parse method
 * validates the entire IB.  Walks the post-validator IB once and
 * emits two event classes:
 *
 *   1. packet_decode: one row per filtered PKT3 packet
 *      (SET_RESOURCE / SET_SAMPLER / SET_CONFIG_REG /
 *      SET_CONTEXT_REG with texture-pipe register filter).
 *   2. ib_post_validate: one summary row with full-IB crc32_le
 *      + total packet count + filtered-packet slot list.
 *
 * The original design separated these into two callsites
 * (per-PKT3 inside the chip-specific validator loop, and a final
 * summary at parser_fini); the merged single-walk variant is
 * functionally equivalent because the per-chip validator runs to
 * completion before this hook fires, so the bytes the walker sees
 * are the same bytes the GPU will execute.  A single callsite also
 * avoids a second prep-source.sh landmark in evergreen_cs.c whose
 * exact source layout is chip-family-dependent.
 */
void radeon_palm_cs_observer_emit_ib_post_validate(
	struct radeon_cs_parser *parser);

#endif /* RADEON_PALM_CS_OBSERVER_H */
