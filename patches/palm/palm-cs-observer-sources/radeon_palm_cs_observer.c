/*
 * radeon_palm_cs_observer.c -- read-only CS validator observer for
 * the radeon-palm-gate DKMS package.
 *
 * Components:
 *   - module_param surface: palm_cs_observer (bool, default 0),
 *     palm_cs_observer_comm (charp), palm_cs_observer_max_bytes (uint,
 *     default 4096), palm_cs_observer_max_events (uint, default 100)
 *   - debugfs root: /sys/kernel/debug/radeon_palm_cs_observer/
 *   - debugfs reader: events.jsonl (1 MiB ring, drop-whole-line on
 *     overflow)
 *   - per-tgid event-counter table (16 slots, spinlock-protected)
 *   - 4 hook surfaces wired into radeon_cs.c via prep-source.sh:
 *     cs_ioctl_entry, ib_chunk_pre_parse, packet_decode-merged-into-
 *     ib_post_validate (one post-validator walk emits both)
 *
 * Hard safety invariants enforced at every emit:
 *   1. READ-ONLY: no MMIO writes, no packet mutation, no allocation
 *      in the hot path (slab allocations under GFP_ATOMIC + bounded
 *      retry where unavoidable).
 *   2. DISABLED BY DEFAULT: every emit checks palm_cs_observer_enabled
 *      first via READ_ONCE -- ZERO overhead beyond a load+branch when
 *      the observer is off.
 *   3. COMM-FILTERED: when enabled, current->comm must equal
 *      palm_cs_observer_comm verbatim; otherwise emit short-circuits.
 *
 * Design source-of-truth:
 *   src/re/r600/findings/active/2026-05-21-radeon-palm-cs-observer-design.md
 */

#include <linux/crc32.h>
#include <linux/debugfs.h>
#include <linux/ktime.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>

#include <uapi/drm/radeon_drm.h>

#include "radeon.h"
#include "radeon_palm_cs_observer.h"

/* Shared JSONL ring buffer.  Single producer (kernel CS path under
 * observer_should_emit gate) + single consumer (debugfs reader via
 * seq_file).  Bytes written verbatim; readers parse with `jq -c '.'`
 * or shell tools (one JSON object per line).
 *
 * Ring is byte-granular, NOT record-granular: lines that do not fit
 * are dropped whole (overflow counter bumped) rather than truncated
 * mid-record.  Truncation would produce invalid JSON; better to lose
 * a line and report the loss.
 *
 * Concurrency model:
 *   - producer holds the ring lock for the whole append (line is
 *     atomic from consumer's perspective)
 *   - consumer (seq_file ->show) takes the same lock under each
 *     iteration and copies one line at a time, releasing between
 *     iterations to keep producer latency bounded
 */

#define PALM_CS_OBSERVER_RING_DEFAULT_BYTES (1u << 20)  /* 1 MiB */

static char *palm_cs_observer_ring;
static size_t palm_cs_observer_ring_size;
static size_t palm_cs_observer_ring_head;
static size_t palm_cs_observer_ring_tail;
static size_t palm_cs_observer_ring_bytes_dropped;
static DEFINE_SPINLOCK(palm_cs_observer_ring_lock);

/* Returns occupancy in bytes.  Caller must hold the ring lock. */
static size_t palm_cs_observer_ring_used_locked(void)
{
	if (palm_cs_observer_ring_head >= palm_cs_observer_ring_tail)
		return palm_cs_observer_ring_head -
			palm_cs_observer_ring_tail;
	return palm_cs_observer_ring_size -
		(palm_cs_observer_ring_tail - palm_cs_observer_ring_head);
}

/* Returns free bytes (always >= 1 because we keep one slot empty
 * to distinguish full from empty).  Caller must hold the ring lock.
 */
static size_t palm_cs_observer_ring_free_locked(void)
{
	if (palm_cs_observer_ring_size == 0)
		return 0;
	return palm_cs_observer_ring_size - 1 -
		palm_cs_observer_ring_used_locked();
}

/* Reset ring head/tail and the dropped-bytes counter.  Called from
 * the 0 -> 1 enable transition so each capture starts fresh.
 * Caller must hold the ring lock.
 */
static void palm_cs_observer_ring_reset_locked(void)
{
	palm_cs_observer_ring_head = 0;
	palm_cs_observer_ring_tail = 0;
	palm_cs_observer_ring_bytes_dropped = 0;
}

/* Append `len` bytes from `src` at the ring head.  Wraps around at
 * the buffer end.  Caller must hold the ring lock AND must have
 * already verified free space >= len.
 */
static void palm_cs_observer_ring_write_locked(const char *src, size_t len)
{
	size_t first;

	if (!len)
		return;
	first = palm_cs_observer_ring_size - palm_cs_observer_ring_head;
	if (first > len)
		first = len;
	memcpy(palm_cs_observer_ring + palm_cs_observer_ring_head,
		src, first);
	if (len > first)
		memcpy(palm_cs_observer_ring, src + first, len - first);
	palm_cs_observer_ring_head =
		(palm_cs_observer_ring_head + len) %
		palm_cs_observer_ring_size;
}

void radeon_palm_cs_observer_ring_emit_line(const char *line, size_t len)
{
	unsigned long flags;
	bool dropped = false;

	if (!line || len == 0 || !palm_cs_observer_ring)
		return;

	spin_lock_irqsave(&palm_cs_observer_ring_lock, flags);
	if (len > palm_cs_observer_ring_size - 1 ||
	    palm_cs_observer_ring_free_locked() < len) {
		palm_cs_observer_ring_bytes_dropped += len;
		dropped = true;
	} else {
		palm_cs_observer_ring_write_locked(line, len);
	}
	spin_unlock_irqrestore(&palm_cs_observer_ring_lock, flags);

	if (dropped)
		pr_info_ratelimited(
			"radeon-palm-gate: observer ring full, dropped "
			"%zu-byte line (total dropped: %zu bytes)\n",
			len, palm_cs_observer_ring_bytes_dropped);
}

/* debugfs reader.  Single seq_file at
 *   /sys/kernel/debug/radeon_palm_cs_observer/events.jsonl
 * Iterates ring tail to head one line at a time; releases the ring
 * lock between iterations so producer is not starved.  EOF when
 * tail catches up with head observed at the start of iteration.
 *
 * The file is one-shot per open: a fresh `cat` walks from tail to
 * head as observed at open time.  Concurrent appends after open
 * are NOT included in the same read; the next open walks them.
 * This keeps reader bookkeeping trivial and avoids tail-chasing.
 */

struct palm_cs_observer_reader_state {
	size_t pos;          /* current read cursor in ring */
	size_t head_at_open; /* head snapshot at open time   */
};

static void *palm_cs_observer_seq_start(struct seq_file *m, loff_t *pos)
{
	struct palm_cs_observer_reader_state *st = m->private;
	unsigned long flags;

	/* *pos == 0 = first call after open; snapshot the ring window
	 * (tail and head_at_open).  *pos > 0 = seq_read is asking for
	 * the next buffer fill in the same open session: resume from
	 * st->pos as left by the previous show() (do NOT reset the
	 * snapshot, that would make the iteration race with concurrent
	 * appends).  Returning NULL on *pos > 0 (the old behaviour)
	 * truncated multi-buffer reads on outputs larger than seq_file's
	 * internal page-sized fill buffer.
	 */
	if (*pos == 0) {
		spin_lock_irqsave(&palm_cs_observer_ring_lock, flags);
		st->pos = palm_cs_observer_ring_tail;
		st->head_at_open = palm_cs_observer_ring_head;
		spin_unlock_irqrestore(&palm_cs_observer_ring_lock, flags);
	}
	if (st->pos == st->head_at_open)
		return NULL;
	return st;
}

static void *palm_cs_observer_seq_next(struct seq_file *m, void *v, loff_t *pos)
{
	struct palm_cs_observer_reader_state *st = v;

	(*pos)++;
	if (st->pos == st->head_at_open)
		return NULL;
	return st;
}

static void palm_cs_observer_seq_stop(struct seq_file *m, void *v)
{
	/* Nothing to release; reader state is freed in ->release. */
}

static int palm_cs_observer_seq_show(struct seq_file *m, void *v)
{
	struct palm_cs_observer_reader_state *st = v;
	unsigned long flags;
	char ch;

	spin_lock_irqsave(&palm_cs_observer_ring_lock, flags);
	while (st->pos != st->head_at_open) {
		ch = palm_cs_observer_ring[st->pos];
		st->pos = (st->pos + 1) % palm_cs_observer_ring_size;
		spin_unlock_irqrestore(&palm_cs_observer_ring_lock,
			flags);
		seq_putc(m, ch);
		if (ch == '\n')
			return 0;
		spin_lock_irqsave(&palm_cs_observer_ring_lock, flags);
	}
	spin_unlock_irqrestore(&palm_cs_observer_ring_lock, flags);
	return 0;
}

static const struct seq_operations palm_cs_observer_seq_ops = {
	.start = palm_cs_observer_seq_start,
	.next  = palm_cs_observer_seq_next,
	.stop  = palm_cs_observer_seq_stop,
	.show  = palm_cs_observer_seq_show,
};

static int palm_cs_observer_events_open(struct inode *inode, struct file *file)
{
	struct palm_cs_observer_reader_state *st;
	int rc;

	st = kzalloc(sizeof(*st), GFP_KERNEL);
	if (!st)
		return -ENOMEM;
	rc = seq_open(file, &palm_cs_observer_seq_ops);
	if (rc) {
		kfree(st);
		return rc;
	}
	((struct seq_file *)file->private_data)->private = st;
	return 0;
}

static int palm_cs_observer_events_release(struct inode *inode,
	struct file *file)
{
	struct seq_file *sf = file->private_data;
	struct palm_cs_observer_reader_state *st;

	if (sf) {
		st = sf->private;
		kfree(st);
	}
	return seq_release(inode, file);
}

static const struct file_operations palm_cs_observer_events_fops = {
	.owner   = THIS_MODULE,
	.open    = palm_cs_observer_events_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = palm_cs_observer_events_release,
};

static struct dentry *palm_cs_observer_events_file;

/* Module parameters: gate (bool, default 0), comm filter (charp,
 * default empty -- empty filter matches no task), per-CS byte cap
 * (uint, default 4096), per-process event cap (uint, default 100).
 * The bool gate carries an explicit setter callback so 0 -> 1
 * transitions reset both the per-tgid event-counter table and the
 * ring buffer head/tail/dropped-bytes counters.
 */

static bool palm_cs_observer_enabled;

static void palm_cs_observer_tgid_table_reset(void);

/* Module-param setter for palm_cs_observer.  Resets the per-TGID event
 * counter table on any 0 -> 1 transition so each capture session
 * starts with a fresh budget without needing rmmod / modprobe.  Any
 * other transition (1 -> 0, 1 -> 1, 0 -> 0) leaves the table alone
 * since it is harmless to read stale counts when disabled.
 */
static int palm_cs_observer_enabled_set(const char *val,
	const struct kernel_param *kp)
{
	bool prev = READ_ONCE(palm_cs_observer_enabled);
	int rc = param_set_bool(val, kp);
	bool now;
	unsigned long flags;

	if (rc)
		return rc;
	now = READ_ONCE(palm_cs_observer_enabled);
	if (now && !prev) {
		palm_cs_observer_tgid_table_reset();
		spin_lock_irqsave(&palm_cs_observer_ring_lock, flags);
		palm_cs_observer_ring_reset_locked();
		spin_unlock_irqrestore(&palm_cs_observer_ring_lock,
			flags);
	}
	return 0;
}

static const struct kernel_param_ops palm_cs_observer_enabled_ops = {
	.set = palm_cs_observer_enabled_set,
	.get = param_get_bool,
};

module_param_cb(palm_cs_observer, &palm_cs_observer_enabled_ops,
	&palm_cs_observer_enabled, 0644);
MODULE_PARM_DESC(palm_cs_observer,
	"radeon-palm-gate CS observer: 0 = off (default), 1 = enabled. "
	"Enabling without setting radeon.palm_cs_observer_comm captures "
	"nothing (the empty comm filter matches no task).  Each 0 -> 1 "
	"transition resets the per-tgid event-count table and the ring "
	"buffer head/tail/dropped counters.");

static char palm_cs_observer_comm[16] = "";
module_param_string(palm_cs_observer_comm,
	palm_cs_observer_comm, sizeof(palm_cs_observer_comm), 0644);
MODULE_PARM_DESC(palm_cs_observer_comm,
	"comm filter for observer events (e.g. \"deqp-vk\").  Empty = no "
	"process matches; events emit only when current->comm equals this.");

static unsigned int palm_cs_observer_max_bytes = 4096;
module_param_named(palm_cs_observer_max_bytes,
	palm_cs_observer_max_bytes, uint, 0644);
MODULE_PARM_DESC(palm_cs_observer_max_bytes,
	"per-CS payload byte cap (default 4096).  Events exceeding the "
	"cap are truncated; the original byte count appears in the JSONL "
	"row as \"truncated_at_bytes\".");

static unsigned int palm_cs_observer_max_events = 100;
module_param_named(palm_cs_observer_max_events,
	palm_cs_observer_max_events, uint, 0644);
MODULE_PARM_DESC(palm_cs_observer_max_events,
	"per-process event cap (default 100).  Beyond the cap, additional "
	"events are silently dropped with a single dmesg overflow line.");

/* debugfs root.  /sys/kernel/debug/radeon_palm_cs_observer/ exists
 * once observer_init succeeds; the single shared events.jsonl
 * reader hangs beneath it (registered by observer_init via
 * debugfs_create_file with the seq_file fop defined above).
 */

static struct dentry *palm_cs_observer_debugfs_root;

/* Public enable check.  Inlined at every emit callsite -- the body
 * is one READ_ONCE so the disabled-path overhead is a single load
 * + branch.  No string compare here; comm filtering runs inside the
 * emit bodies on the enabled fast-path only.
 */

bool radeon_palm_cs_observer_active(void)
{
	return READ_ONCE(palm_cs_observer_enabled);
}

/* JSON string escape helper.
 *
 * Comm strings come from user-controllable prctl(PR_SET_NAME) so they
 * can legitimately contain `"`, `\`, newline, or other control
 * characters.  Interpolating current->comm directly into a JSON
 * scalar via %s produces malformed JSONL and can line-inject the
 * downstream `jq -c '.'` consumer (a single \n inside comm splits
 * one event into two ill-formed records).
 *
 * Escape policy:
 *   - `"` and `\` become `\"` and `\\` (JSON spec).
 *   - Control characters (< 0x20) and high bytes (>= 0x80)
 *     become `\u00XX`, keeping the JSONL parseable even when a
 *     task sets a non-UTF-8 comm name.
 *
 * Writes up to `dst_size - 1` bytes plus a NUL terminator.  Returns
 * the number of bytes written (excluding terminator).  Caller-safe
 * for dst_size = 0 (returns 0).
 */
static size_t palm_cs_observer_json_escape(char *dst, size_t dst_size,
	const char *src, size_t src_max_len)
{
	size_t out = 0;
	size_t i;

	if (!dst || dst_size == 0)
		return 0;

	for (i = 0; i < src_max_len && src[i] != '\0'; i++) {
		unsigned char c = (unsigned char)src[i];
		int n;

		if (c == '"' || c == '\\') {
			if (out + 2 >= dst_size)
				break;
			dst[out++] = '\\';
			dst[out++] = (char)c;
		} else if (c < 0x20 || c >= 0x80) {
			if (out + 6 >= dst_size)
				break;
			n = scnprintf(dst + out, dst_size - out,
				"\\u%04x", c);
			if (n <= 0)
				break;
			out += (size_t)n;
		} else {
			if (out + 1 >= dst_size)
				break;
			dst[out++] = (char)c;
		}
	}
	dst[out] = '\0';
	return out;
}

/* Per-process event counter.  Small fixed-size table protected by a
 * spinlock.  Linear scan because realistic deqp-vk runs have <= a
 * handful of processes; trading bigger-O for cache-friendly walk
 * under a short critical section.  Overflow drops new entries
 * rather than evicting old ones so the cap on the deqp-vk worker
 * (which is what we actually want to observe) is honoured even when
 * stray unfiltered comms briefly pass admission.
 *
 * The table key is current->tgid (thread group leader, == process
 * id from userspace's perspective), NOT current->pid (kernel thread
 * id).  A multithreaded process with N worker threads otherwise
 * gets N * max_events budget which violates the documented per-
 * process cap.  All threads of a given process share the same TGID.
 */

#define PALM_CS_OBSERVER_TGID_TABLE_SIZE 16

struct palm_cs_observer_tgid_slot {
	pid_t tgid;
	unsigned int events;
	bool overflow_warned;
};

static struct palm_cs_observer_tgid_slot
	palm_cs_observer_tgid_table[PALM_CS_OBSERVER_TGID_TABLE_SIZE];
static DEFINE_SPINLOCK(palm_cs_observer_tgid_lock);

/* Reset the per-TGID table.  Called from observer_init + on each
 * disable -> enable transition so each capture session starts with
 * fresh per-process quotas.  Holds the spinlock to serialise against
 * concurrent should_emit() calls.
 */
static void palm_cs_observer_tgid_table_reset(void)
{
	unsigned long flags;

	spin_lock_irqsave(&palm_cs_observer_tgid_lock, flags);
	memset(palm_cs_observer_tgid_table, 0,
		sizeof(palm_cs_observer_tgid_table));
	spin_unlock_irqrestore(&palm_cs_observer_tgid_lock, flags);
}

/* Look up + bump current task's slot.  Returns true when an event
 * may proceed (slot found or allocated + counter still under cap);
 * returns false when the table is full of other tgids OR this tgid
 * has hit its cap.  The first cap-hit emits a single dmesg warning;
 * subsequent drops are silent.
 *
 * Keyed on current->tgid so the per-process cap is shared across all
 * worker threads of a multithreaded process such as deqp-vk.  Using
 * current->pid would key by kernel thread id and multiply the budget
 * by the worker-thread count.
 */
static bool palm_cs_observer_tgid_admit(void)
{
	pid_t tgid = current->tgid;
	unsigned int cap = READ_ONCE(palm_cs_observer_max_events);
	unsigned long flags;
	struct palm_cs_observer_tgid_slot *slot;
	struct palm_cs_observer_tgid_slot *empty = NULL;
	int i;
	bool admit = false;
	bool warn = false;

	spin_lock_irqsave(&palm_cs_observer_tgid_lock, flags);

	for (i = 0; i < PALM_CS_OBSERVER_TGID_TABLE_SIZE; i++) {
		slot = &palm_cs_observer_tgid_table[i];
		if (slot->tgid == tgid && slot->events > 0) {
			if (slot->events < cap) {
				slot->events++;
				admit = true;
			} else if (!slot->overflow_warned) {
				slot->overflow_warned = true;
				warn = true;
			}
			goto out;
		}
		if (!empty && slot->events == 0)
			empty = slot;
	}

	if (empty && cap > 0) {
		empty->tgid = tgid;
		empty->events = 1;
		empty->overflow_warned = false;
		admit = true;
	}

out:
	spin_unlock_irqrestore(&palm_cs_observer_tgid_lock, flags);
	if (warn) {
		pr_info_ratelimited(
			"radeon-palm-gate: observer event cap (%u) hit "
			"for tgid %d comm \"%s\"; further events dropped\n",
			cap, tgid, current->comm);
	}
	return admit;
}

/* Comm filter.  Compares current->comm against the module param
 * palm_cs_observer_comm (which is TASK_COMM_LEN-sized via
 * module_param_string).  Empty filter = nothing matches.
 */
static bool palm_cs_observer_comm_matches(void)
{
	const char *filter = palm_cs_observer_comm;
	size_t flen;

	if (!filter[0])
		return false;
	flen = strnlen(filter, sizeof(palm_cs_observer_comm));
	return strncmp(current->comm, filter, flen + 1) == 0;
}

/* Cheap gate: enabled + comm match, WITHOUT bumping the per-tgid
 * event counter.  Hot-path emit callsites that produce a single
 * JSONL row per call use the full admit gate.  Multi-event hooks
 * (where one CS submission produces N rows, e.g. one per chunk or
 * one per PKT3 packet) check this cheap gate at the top to avoid
 * spinlock acquisition on every submission, then call the full
 * admit gate per-row inside the loop so the per-tgid cap is
 * enforced per emitted event (not per CS).
 */
static bool palm_cs_observer_enabled_and_filtered(void)
{
	if (!radeon_palm_cs_observer_active())
		return false;
	return palm_cs_observer_comm_matches();
}

/* Full admit gate.  Order: cheap-enable -> comm filter -> per-tgid
 * cap.  Each predicate is the cheapest possible check at its
 * position; we never hit the spinlock unless enabled-and-matching.
 * Single-row emit callsites should call this once; multi-row hooks
 * should call enabled_and_filtered() at the top and tgid_admit
 * inside the loop -- see emit_ib_chunk_pre_parse +
 * emit_ib_post_validate for the multi-row pattern.
 */
bool radeon_palm_cs_observer_should_emit(void)
{
	if (!palm_cs_observer_enabled_and_filtered())
		return false;
	return palm_cs_observer_tgid_admit();
}

/* Module lifecycle.  Called from radeon_init / radeon_exit in
 * radeon_drv.c via the 0006 patch.  Failure of _init must be
 * non-fatal so that a debugfs-disabled kernel still loads radeon
 * cleanly; observer falls inert.
 */

int radeon_palm_cs_observer_init(void)
{
	palm_cs_observer_debugfs_root =
		debugfs_create_dir("radeon_palm_cs_observer", NULL);

	if (IS_ERR_OR_NULL(palm_cs_observer_debugfs_root)) {
		pr_info("radeon-palm-gate: observer debugfs root not "
			"available (debugfs disabled?); observer will "
			"stay inert\n");
		palm_cs_observer_debugfs_root = NULL;
		WRITE_ONCE(palm_cs_observer_enabled, false);
		return 0;
	}

	palm_cs_observer_ring_size = PALM_CS_OBSERVER_RING_DEFAULT_BYTES;
	palm_cs_observer_ring = vmalloc(palm_cs_observer_ring_size);
	if (!palm_cs_observer_ring) {
		pr_warn("radeon-palm-gate: observer ring alloc failed "
			"(%zu bytes); observer will stay inert\n",
			palm_cs_observer_ring_size);
		palm_cs_observer_ring_size = 0;
		debugfs_remove_recursive(palm_cs_observer_debugfs_root);
		palm_cs_observer_debugfs_root = NULL;
		WRITE_ONCE(palm_cs_observer_enabled, false);
		return 0;
	}
	palm_cs_observer_ring_head = 0;
	palm_cs_observer_ring_tail = 0;
	palm_cs_observer_ring_bytes_dropped = 0;

	palm_cs_observer_events_file = debugfs_create_file(
		"events.jsonl", 0444,
		palm_cs_observer_debugfs_root, NULL,
		&palm_cs_observer_events_fops);
	if (IS_ERR_OR_NULL(palm_cs_observer_events_file)) {
		pr_warn("radeon-palm-gate: observer events.jsonl create "
			"failed; observer will stay inert\n");
		palm_cs_observer_events_file = NULL;
		vfree(palm_cs_observer_ring);
		palm_cs_observer_ring = NULL;
		palm_cs_observer_ring_size = 0;
		debugfs_remove_recursive(palm_cs_observer_debugfs_root);
		palm_cs_observer_debugfs_root = NULL;
		WRITE_ONCE(palm_cs_observer_enabled, false);
		return 0;
	}

	pr_info("radeon-palm-gate: CS observer ready "
		"(debugfs root /sys/kernel/debug/radeon_palm_cs_observer, "
		"ring %zu bytes); enable via "
		"`echo 1 > /sys/module/radeon/parameters/palm_cs_observer`\n",
		palm_cs_observer_ring_size);
	return 0;
}

void radeon_palm_cs_observer_cleanup(void)
{
	/* Force-off first so any racing emit returns early. */
	WRITE_ONCE(palm_cs_observer_enabled, false);

	if (palm_cs_observer_debugfs_root) {
		debugfs_remove_recursive(palm_cs_observer_debugfs_root);
		palm_cs_observer_debugfs_root = NULL;
		palm_cs_observer_events_file = NULL;
	}
	if (palm_cs_observer_ring) {
		vfree(palm_cs_observer_ring);
		palm_cs_observer_ring = NULL;
		palm_cs_observer_ring_size = 0;
	}
}

/* Hook emit bodies.  Each emitter short-circuits on disabled / comm-
 * mismatched / per-tgid-cap-exceeded inputs via should_emit() (for
 * single-row hooks) or the split enabled_and_filtered() + per-row
 * tgid_admit() pair (for multi-row hooks).  All emitters write to the
 * shared ring buffer via ring_emit_line() and have NO direct file-
 * I/O, NO MMIO writes, NO packet-stream mutation, NO heap allocation
 * in the hot path.
 */

/* Stack buffer size for a single JSONL row.  cs_ioctl_entry has no
 * per-chunk array (chunk details defer to ib_chunk_pre_parse where
 * the parser already has them in kernel mem); the metadata fields
 * fit comfortably inside one cache line worth of text plus newline.
 */
#define PALM_CS_OBSERVER_LINE_BUF_BYTES 256

void radeon_palm_cs_observer_emit_cs_ioctl_entry(void *user_data)
{
	struct drm_radeon_cs *cs = user_data;
	char buf[PALM_CS_OBSERVER_LINE_BUF_BYTES];
	char comm_escaped[TASK_COMM_LEN * 6 + 1];
	int len;

	/* cs_ioctl_entry emits exactly one row per CS submission, so
	 * the full admit gate is the right call: enabled + comm match
	 * + per-tgid event-cap charge.
	 */
	if (!radeon_palm_cs_observer_should_emit())
		return;
	if (!cs)
		return;

	palm_cs_observer_json_escape(comm_escaped, sizeof(comm_escaped),
		current->comm, TASK_COMM_LEN);

	/* cs->chunks is a userspace pointer at this hook point; we
	 * do NOT dereference it here.  ib_chunk_pre_parse hook below emits
	 * per-chunk details once the parser has copy_from_user'd the
	 * chunk array into kernel memory.
	 */
	len = scnprintf(buf, sizeof(buf),
		"{\"event\":\"cs_ioctl_entry\","
		"\"ts_nsec\":%llu,"
		"\"pid\":%d,"
		"\"tgid\":%d,"
		"\"comm\":\"%s\","
		"\"cs_id\":%u,"
		"\"num_chunks\":%u,"
		"\"gart_limit_bytes\":%llu,"
		"\"vram_limit_bytes\":%llu}\n",
		(unsigned long long)ktime_get_ns(),
		current->pid,
		current->tgid,
		comm_escaped,
		cs->cs_id,
		cs->num_chunks,
		(unsigned long long)cs->gart_limit,
		(unsigned long long)cs->vram_limit);

	if (len > 0)
		radeon_palm_cs_observer_ring_emit_line(buf, (size_t)len);
}

/* Cap on first-N dwords copied verbatim into the JSONL row.  64
 * dwords = 256 bytes per chunk is enough to identify PKT3 packet
 * headers, opening descriptor bytes, and RELOC table heads.  Larger
 * snapshots get the full ib_post_validate sha256 anyway.
 */
#define PALM_CS_OBSERVER_FIRST_N_DWORDS 64

/* Larger stack buffer than the cs_ioctl_entry path: one chunk's
 * worth of metadata + up to 64 hex-formatted dwords + JSON syntax.
 * 1536 bytes is well under the kernel-stack 16 KiB ceiling.
 */
#define PALM_CS_OBSERVER_CHUNK_BUF_BYTES 1536

/* Recover the userspace chunk_id for a parser chunk.  Linux 6.18's
 * `struct radeon_cs_chunk` dropped the `chunk_id` field; the kernel
 * preserves the typed identity only via parser->chunk_ib /
 * chunk_relocs / chunk_flags / chunk_const_ib pointer aliases set
 * in radeon_cs_parser_init.  This helper recovers the UAPI
 * identifier (RADEON_CHUNK_ID_*) by pointer-equality comparison;
 * chunks the kernel did not classify return (uint32_t)-1 ("unknown").
 */
static uint32_t palm_cs_observer_chunk_id(
	struct radeon_cs_parser *parser,
	struct radeon_cs_chunk *chunk)
{
	if (!parser || !chunk)
		return (uint32_t)-1;
	if (chunk == parser->chunk_ib)
		return RADEON_CHUNK_ID_IB;
	if (chunk == parser->chunk_relocs)
		return RADEON_CHUNK_ID_RELOCS;
	if (chunk == parser->chunk_flags)
		return RADEON_CHUNK_ID_FLAGS;
	if (chunk == parser->chunk_const_ib)
		return RADEON_CHUNK_ID_CONST_IB;
	return (uint32_t)-1;
}

void radeon_palm_cs_observer_emit_ib_chunk_pre_parse(
	struct radeon_cs_parser *parser)
{
	char buf[PALM_CS_OBSERVER_CHUNK_BUF_BYTES];
	char comm_escaped[TASK_COMM_LEN * 6 + 1];
	unsigned int chunk_idx;
	int total_len;
	int written;
	bool closed_ok;

	/* Cheap-gate at the top to avoid spinlock on every CS when the
	 * observer is disabled or the comm doesn't match.  The full
	 * admit gate (which bumps the per-tgid event counter) is
	 * called PER CHUNK below so the configured cap is enforced
	 * per emitted JSONL row, not per CS submission.
	 */
	if (!palm_cs_observer_enabled_and_filtered())
		return;
	if (!parser || !parser->chunks)
		return;

	palm_cs_observer_json_escape(comm_escaped, sizeof(comm_escaped),
		current->comm, TASK_COMM_LEN);

	for (chunk_idx = 0; chunk_idx < parser->nchunks; chunk_idx++) {
		struct radeon_cs_chunk *chunk = &parser->chunks[chunk_idx];
		unsigned int first_n;
		u32 crc;
		unsigned int i;
		size_t bytes;

		if (!chunk->kdata || chunk->length_dw == 0)
			continue;

		/* Per-row admit charge against the per-tgid event cap.
		 * Stops emitting once the cap is hit; the rest of this
		 * CS's chunks are silently skipped (the cap is global to
		 * the process, not to the CS).
		 */
		if (!palm_cs_observer_tgid_admit())
			return;

		first_n = chunk->length_dw < PALM_CS_OBSERVER_FIRST_N_DWORDS
			? chunk->length_dw
			: PALM_CS_OBSERVER_FIRST_N_DWORDS;
		bytes = (size_t)chunk->length_dw * sizeof(u32);
		crc = crc32_le(0u, (const unsigned char *)chunk->kdata,
			bytes);

		total_len = scnprintf(buf, sizeof(buf),
			"{\"event\":\"ib_chunk_pre_parse\","
			"\"ts_nsec\":%llu,"
			"\"pid\":%d,"
			"\"tgid\":%d,"
			"\"comm\":\"%s\","
			"\"chunk_index\":%u,"
			"\"chunk_id\":%u,"
			"\"length_dw\":%u,"
			"\"crc32_le\":\"0x%08x\","
			"\"first_dwords_hex\":[",
			(unsigned long long)ktime_get_ns(),
			current->pid,
			current->tgid,
			comm_escaped,
			chunk_idx,
			palm_cs_observer_chunk_id(parser, chunk),
			chunk->length_dw,
			crc);

		for (i = 0; i < first_n &&
		     total_len < (int)sizeof(buf) - 16; i++) {
			written = scnprintf(buf + total_len,
				sizeof(buf) - total_len,
				i + 1 < first_n
					? "\"0x%08x\","
					: "\"0x%08x\"",
				chunk->kdata[i]);
			if (written <= 0)
				break;
			total_len += written;
		}

		/* Append "]}\n".  If there isn't room (the stack buffer
		 * filled mid-dword), the line as-written is malformed
		 * JSON and MUST be dropped rather than committed to the
		 * ring (the ring contract says drop-whole-line over
		 * partial writes).  Track close-success and only emit
		 * the completed row.
		 */
		closed_ok = false;
		if (total_len > 0 &&
		    total_len + 3 < (int)sizeof(buf)) {
			written = scnprintf(buf + total_len,
				sizeof(buf) - total_len, "]}\n");
			if (written == 3) {
				total_len += written;
				closed_ok = true;
			}
		}

		if (closed_ok)
			radeon_palm_cs_observer_ring_emit_line(
				buf, (size_t)total_len);
	}
}

/* PM4 PKT3 opcode allowlist for packet_decode events.  Keeps the
 * volume tractable on a typical CS submission (a deqp-vk gather case
 * issues O(10) SET_RESOURCE + SET_SAMPLER packets) while still
 * surfacing every shader-descriptor and texture-pipe context write
 * that affects the cube int gather verdict.  Other opcode classes
 * (draw, dispatch, sync, event) are deliberately NOT emitted to
 * avoid burying the descriptor signal under high-volume control
 * packets.
 *
 * Values match drivers/gpu/drm/radeon/r600d.h:
 *   PKT3_SET_CONFIG_REG    = 0x68
 *   PKT3_SET_CONTEXT_REG   = 0x69
 *   PKT3_SET_RESOURCE      = 0x6D  (Evergreen variant; Cayman uses 0x6C)
 *   PKT3_SET_SAMPLER       = 0x6E  (Evergreen variant)
 *   PKT3_SET_LOOP_CONST    = 0x6C  (R6xx/R7xx; same opcode reused
 *                                   for SET_RESOURCE on later families)
 *   PKT3_SET_BOOL_CONST    = 0x6B
 *
 * Evergreen ISA Ch.7 + R6xx/R7xx 3D Acceleration Guide PM4 chapter
 * are the source of truth for opcode + slot layout.
 */
#define PKT3_NOP_PALM                   0x10
#define PKT3_SET_CONFIG_REG_PALM        0x68
#define PKT3_SET_CONTEXT_REG_PALM       0x69
#define PKT3_SET_BOOL_CONST_PALM        0x6B
#define PKT3_SET_LOOP_CONST_PALM        0x6C
#define PKT3_SET_RESOURCE_PALM          0x6D
#define PKT3_SET_SAMPLER_PALM           0x6E

static bool palm_cs_observer_pkt3_is_filtered(u8 opcode)
{
	switch (opcode) {
	case PKT3_SET_CONFIG_REG_PALM:
	case PKT3_SET_CONTEXT_REG_PALM:
	case PKT3_SET_BOOL_CONST_PALM:
	case PKT3_SET_LOOP_CONST_PALM:
	case PKT3_SET_RESOURCE_PALM:
	case PKT3_SET_SAMPLER_PALM:
		return true;
	default:
		return false;
	}
}

static const char *palm_cs_observer_pkt3_opcode_name(u8 opcode)
{
	switch (opcode) {
	case PKT3_SET_CONFIG_REG_PALM:  return "PKT3_SET_CONFIG_REG";
	case PKT3_SET_CONTEXT_REG_PALM: return "PKT3_SET_CONTEXT_REG";
	case PKT3_SET_BOOL_CONST_PALM:  return "PKT3_SET_BOOL_CONST";
	case PKT3_SET_LOOP_CONST_PALM:  return "PKT3_SET_LOOP_CONST";
	case PKT3_SET_RESOURCE_PALM:    return "PKT3_SET_RESOURCE";
	case PKT3_SET_SAMPLER_PALM:     return "PKT3_SET_SAMPLER";
	default:                        return "PKT3_OTHER";
	}
}

/* Emit one packet_decode JSONL row.  Caller has verified the opcode
 * is on the filter allowlist AND that emit_n payload dwords fit in
 * the IB chunk; this function just formats and rings.  Returns true
 * iff the row was committed (closed JSON; admit charge already paid
 * by the caller).
 */
static bool palm_cs_observer_emit_packet_decode_locked(
	u32 packet_idx,
	u8 opcode,
	u32 reg_addr_or_slot,
	u32 dword_count,
	const u32 *payload,
	const char *comm_escaped)
{
	char buf[PALM_CS_OBSERVER_CHUNK_BUF_BYTES];
	int total_len;
	int written;
	unsigned int i;
	unsigned int emit_n;
	bool closed_ok = false;

	emit_n = dword_count < PALM_CS_OBSERVER_FIRST_N_DWORDS
		? dword_count
		: PALM_CS_OBSERVER_FIRST_N_DWORDS;

	total_len = scnprintf(buf, sizeof(buf),
		"{\"event\":\"packet_decode\","
		"\"ts_nsec\":%llu,"
		"\"pid\":%d,"
		"\"tgid\":%d,"
		"\"comm\":\"%s\","
		"\"packet_idx\":%u,"
		"\"opcode\":\"0x%02x\","
		"\"opcode_name\":\"%s\","
		"\"reg_addr_or_slot\":\"0x%08x\","
		"\"dword_count\":%u,"
		"\"payload_dwords\":[",
		(unsigned long long)ktime_get_ns(),
		current->pid,
		current->tgid,
		comm_escaped,
		packet_idx,
		opcode,
		palm_cs_observer_pkt3_opcode_name(opcode),
		reg_addr_or_slot,
		dword_count);

	for (i = 0; i < emit_n &&
	     total_len < (int)sizeof(buf) - 16; i++) {
		written = scnprintf(buf + total_len,
			sizeof(buf) - total_len,
			i + 1 < emit_n
				? "\"0x%08x\","
				: "\"0x%08x\"",
			payload[i]);
		if (written <= 0)
			break;
		total_len += written;
	}

	/* Drop-whole-line if no room to close JSON (see ib_chunk_pre_parse for the same
	 * matching contract).
	 */
	if (total_len > 0 &&
	    total_len + 3 < (int)sizeof(buf)) {
		written = scnprintf(buf + total_len,
			sizeof(buf) - total_len, "]}\n");
		if (written == 3) {
			total_len += written;
			closed_ok = true;
		}
	}

	if (closed_ok)
		radeon_palm_cs_observer_ring_emit_line(
			buf, (size_t)total_len);
	return closed_ok;
}

void radeon_palm_cs_observer_emit_ib_post_validate(
	struct radeon_cs_parser *parser)
{
	char summary[PALM_CS_OBSERVER_LINE_BUF_BYTES];
	char comm_escaped[TASK_COMM_LEN * 6 + 1];
	int summary_len;
	struct radeon_cs_chunk *ib_chunk = NULL;
	unsigned int i;
	u32 crc;
	u32 packet_idx = 0;
	u32 filtered_count = 0;

	/* Cheap gate at top (no spinlock); per-row admit charges
	 * happen inside the PKT3 walk + at summary-row emit time.
	 */
	if (!palm_cs_observer_enabled_and_filtered())
		return;
	if (!parser || !parser->chunks)
		return;

	palm_cs_observer_json_escape(comm_escaped, sizeof(comm_escaped),
		current->comm, TASK_COMM_LEN);

	/* Use the kernel's typed pointer alias (parser->chunk_ib) set
	 * during radeon_cs_parser_init.  This replaces a hand-rolled
	 * scan over parser->chunks[i].chunk_id, which 6.18 no longer
	 * supports (the `chunk_id` field was removed; only the typed
	 * pointers carry the identity).
	 */
	ib_chunk = parser->chunk_ib;
	if (!ib_chunk || !ib_chunk->kdata || ib_chunk->length_dw == 0)
		return;

	/* Walk PM4 packets in the post-validator IB and emit one
	 * packet_decode row per filtered PKT3 opcode.  PKT3 header
	 * layout (R6xx/R7xx 3D Accel Guide):
	 *     bits 31..30 = 0b11   (type 3)
	 *     bits 29..16 = count - 1
	 *     bits 15..8  = opcode
	 *     bits 7..0   = (reserved / predicate)
	 * Payload follows the header dword; payload length = count dwords.
	 *
	 * Bounds-check every read: a malformed PKT3 header in an
	 * error-path IB (which the observer hooks intentionally also walk) can
	 * specify count fields that overrun the chunk.  Compute
	 * (i + 1 + count) before reading anything past i.
	 */
	i = 0;
	while (i < ib_chunk->length_dw) {
		u32 header = ib_chunk->kdata[i];
		u32 pkt_type = header >> 30;
		u32 count;
		u8 opcode;
		u32 reg_addr_or_slot = 0;
		u32 next_i;

		if (pkt_type != 3) {
			/* Non-PKT3: type 0 (count of regs), type 2 (NOP),
			 * type 1 (reserved).  Walk by length per type.
			 */
			if (pkt_type == 0) {
				count = ((header >> 16) & 0x3FFF) + 1;
				next_i = i + 1 + count;
			} else {
				/* type 2 / reserved: single dword */
				next_i = i + 1;
			}
			if (next_i <= i || next_i > ib_chunk->length_dw)
				break; /* malformed; stop walking */
			i = next_i;
			packet_idx++;
			continue;
		}

		count = ((header >> 16) & 0x3FFF) + 1;
		opcode = (header >> 8) & 0xFF;
		next_i = i + 1 + count;

		/* Validate the full payload fits BEFORE dereferencing
		 * any payload dword.  An overflow-or-out-of-bounds
		 * `next_i` would otherwise cause a kernel OOB read.
		 */
		if (next_i <= i || next_i > ib_chunk->length_dw)
			break;

		/* For SET_* packets, the first payload dword carries the
		 * register address (for CONFIG/CONTEXT) or the slot
		 * offset (for RESOURCE/SAMPLER).
		 */
		if (count >= 1 &&
		    palm_cs_observer_pkt3_is_filtered(opcode) &&
		    palm_cs_observer_tgid_admit()) {
			reg_addr_or_slot = ib_chunk->kdata[i + 1];
			if (palm_cs_observer_emit_packet_decode_locked(
				packet_idx,
				opcode,
				reg_addr_or_slot,
				count - 1,
				&ib_chunk->kdata[i + 2],
				comm_escaped))
				filtered_count++;
		}

		i = next_i;
		packet_idx++;
	}

	/* Summary row: full-IB crc32_le + total + filtered counts.
	 * Comparing against ib_chunk_pre_parse's crc32 detects
	 * validator mutation between parse and execute.  The summary
	 * row carries its own admit charge so it counts toward the
	 * per-tgid event cap independently of the packet_decode rows
	 * above.
	 */
	if (!palm_cs_observer_tgid_admit())
		return;

	crc = crc32_le(0u, (const unsigned char *)ib_chunk->kdata,
		(size_t)ib_chunk->length_dw * sizeof(u32));

	summary_len = scnprintf(summary, sizeof(summary),
		"{\"event\":\"ib_post_validate\","
		"\"ts_nsec\":%llu,"
		"\"pid\":%d,"
		"\"tgid\":%d,"
		"\"comm\":\"%s\","
		"\"ib_length_dw\":%u,"
		"\"ib_crc32_le\":\"0x%08x\","
		"\"total_packets\":%u,"
		"\"filtered_packets\":%u}\n",
		(unsigned long long)ktime_get_ns(),
		current->pid,
		current->tgid,
		comm_escaped,
		ib_chunk->length_dw,
		crc,
		packet_idx,
		filtered_count);

	if (summary_len > 0)
		radeon_palm_cs_observer_ring_emit_line(
			summary, (size_t)summary_len);
}
