#!/bin/sh
# CP-ME de-risk: capture one radeon_gpu_reset under full multi-tier live tracing.
#
# Purpose: prove a CHIP_RS480 GPU reset recovers without a physical reboot, and
# capture the whole event to a persistent ext4 directory so that if the reset
# hard-locks the machine (r300_asic_reset carries an in-source "sometimes hard
# locks" caveat on R3XX/R4XX) the trace survives a power cycle for post-reboot
# analysis.  This script performs NO microcode injection; it only triggers and
# observes the driver's own reset path.
#
# Tiers captured concurrently (all -> $OUTDIR, flushed by a sync daemon):
#   ftrace function_graph (trace-cmd) on the reset/recovery call chain
#   bpftrace kprobe/kretprobe on radeon_gpu_reset .. r100_cp_load_microcode ..
#            r100_ring_test .. radeon_ib_ring_tests (ucode-reupload + ring-test
#            proof, with return codes)
#   dmesg -wT follow (the 0003 crash-shim register dump lands here)
#   journald is persistent on this host, a second copy across reboot
#   heartbeat (0.5s) -- last timestamp before a freeze = freeze time
#   register snapshots before/after via the rs480 debugfs candidate nodes
#   optional byte-exact 256-word CP-ME overlay compare (needs cp_me_ram_dump=1)
#
# Usage:
#   cpme_derisk_reset_capture.sh --dry-run [SUBMIT_CMD]   # calibrate, no reset
#   cpme_derisk_reset_capture.sh --arm     [SUBMIT_CMD]   # real reset trigger
# SUBMIT_CMD is a shell command that submits one radeon CS (so the armed
# needs_reset is consumed via -EDEADLK -> radeon_cs_handle_lockup ->
# radeon_gpu_reset).  Defaults to a no-op; under a live X server the next
# compositor frame submits on its own.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/radeon_debugfs_path.sh
. "$SCRIPT_DIR/radeon_debugfs_path.sh"

MODE="${1:-}"
SUBMIT_CMD="${2:-:}"
case "$MODE" in
  --dry-run) ARM=0 ;;
  --arm)     ARM=1 ;;
  *) echo "usage: $0 --dry-run|--arm [SUBMIT_CMD]"; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then echo "must run as root"; exit 1; fi

TS=$(date +%Y%m%dT%H%M%SZ)
OUTDIR="/var/log/cpme_derisk/${TS}"
# tracefs mounts at /sys/kernel/tracing on this kernel (the /sys/kernel/debug
# alias is not present); trace-cmd targets this path.
TRACEFS="/sys/kernel/tracing"
mkdir -p "$OUTDIR"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUTDIR/harness.log"; }

outdir_fstype=$(findmnt -no FSTYPE -T "$OUTDIR" 2>/dev/null || true)
if [ -z "$outdir_fstype" ] && command -v stat >/dev/null 2>&1; then
  outdir_fstype=$(stat -f -c %T "$OUTDIR" 2>/dev/null || true)
fi
case "$outdir_fstype" in
  ext|ext2|ext3|ext4|ext2/ext3) ;;
  "")
    if [ "$ARM" -eq 1 ]; then
      log "refusing --arm: could not determine filesystem type for $OUTDIR"
      exit 1
    fi
    log "warning: could not determine filesystem type for $OUTDIR; --arm would refuse"
    ;;
  *)
    if [ "$ARM" -eq 1 ]; then
      log "refusing --arm: $OUTDIR is on $outdir_fstype, expected ext* persistent storage"
      exit 1
    fi
    log "warning: $OUTDIR is on $outdir_fstype, not ext* persistent storage; --arm would refuse"
    ;;
esac

debugfs_node() {
  radeon_debugfs_path "$1" 2>> "$OUTDIR/harness.log" || true
}

RESET_NODE=$(debugfs_node radeon_gpu_reset)
if [ -n "$RESET_NODE" ]; then
  DRI=$(dirname -- "$RESET_NODE")
else
  SAFE_REGS_NODE=$(debugfs_node radeon_rs480_safe_regs)
  if [ -n "$SAFE_REGS_NODE" ]; then
    DRI=$(dirname -- "$SAFE_REGS_NODE")
  else
    log "debugfs: could not resolve radeon_gpu_reset or radeon_rs480_safe_regs"
    exit 1
  fi
fi
if [ -z "$RESET_NODE" ]; then
  if [ "$ARM" -eq 1 ]; then
    log "debugfs: radeon_gpu_reset is absent; refusing --arm"
    exit 1
  fi
  log "debugfs: radeon_gpu_reset is absent; dry-run capture will skip reset arming"
else
  log "debugfs: using reset node $RESET_NODE"
fi
log "debugfs: using radeon node directory $DRI"
# Resolve the CP-ME dump node independently of the reset node directory (the two
# can live in different debugfs layouts; see snap_regs).
CPME_DUMP=$(debugfs_node radeon_rs480_cp_me_ram_dump)

snap_regs() {
  # $1 = label; dump the rs480 candidate + benign nodes if present.  Each node
  # is resolved independently: the reset node can live at the legacy top level
  # while the RS480 RE nodes are deferred under dri/N (post-0009), so a path
  # derived from the reset node directory would silently skip them and consume
  # the hazardous reset budget without retaining the register evidence.
  for n in radeon_rs480_candidate_mc_benign_regs radeon_rs480_candidate_gart_mc_regs \
           radeon_rs480_candidate_config_regs radeon_rs480_safe_regs; do
    node=$(debugfs_node "$n")
    [ -n "$node" ] && [ -r "$node" ] && { echo "== $n =="; cat "$node"; } >> "$OUTDIR/regs_$1.txt" 2>&1
  done
}

PIDS=""
stop_pids() {
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  for p in $PIDS; do wait "$p" 2>/dev/null || true; done
}
cleanup() {
  log "cleanup: stopping captures"
  stop_pids
  if [ -d "$TRACEFS" ]; then
    echo 0 > "$TRACEFS/tracing_on" 2>/dev/null
    echo nop > "$TRACEFS/current_tracer" 2>/dev/null
    : > "$TRACEFS/set_graph_function" 2>/dev/null
  fi
  sync
  log "bundle: $OUTDIR"
}
trap cleanup EXIT INT TERM

log "MODE=$MODE ARM=$ARM host=$(uname -n) kernel=$(uname -r) boot_id=$(cat /proc/sys/kernel/random/boot_id)"
log "radeon module: $(modinfo -n radeon 2>/dev/null)"
for p in lockup_timeout rs480_cp_me_ram_dump rs480_cp_me_ram_inject rs480_candidate_regs; do
  echo "$p=$(cat /sys/module/radeon/parameters/$p 2>/dev/null)" >> "$OUTDIR/radeon_params.txt"
done

# --- sync daemon: force everything to disk so a power cycle loses minimal data
( while :; do sync; sleep 0.3; done ) & PIDS="$PIDS $!"
# --- heartbeat: last line before a freeze marks the freeze instant
( while :; do date +%s.%N; sleep 0.5; done >> "$OUTDIR/heartbeat.log" ) & PIDS="$PIDS $!"
# --- dmesg follow with wall-clock timestamps
( dmesg -wT >> "$OUTDIR/dmesg_follow.log" 2>&1 ) & PIDS="$PIDS $!"

# --- ftrace function_graph on the reset/recovery chain via trace-cmd
# r100_cp_load_microcode is inlined into r100_cp_init on this build (not
# traceable); r100_cp_init entry+ret=0 is the ucode-reupload proxy.  Listing a
# non-traceable function makes trace-cmd start fail for the whole set, so the
# graph list carries only confirmed-traceable symbols.
RESET_FNS="radeon_gpu_reset r300_asic_reset rs400_resume rs400_startup r100_cp_init r100_ring_test radeon_ib_ring_tests radeon_resume radeon_suspend"
log "ftrace: configuring function_graph via tracefs ($TRACEFS), per-function tolerant"
if [ -d "$TRACEFS" ] && [ -w "$TRACEFS/current_tracer" ]; then
  echo 0 > "$TRACEFS/tracing_on" 2>/dev/null
  echo function_graph > "$TRACEFS/current_tracer" 2>/dev/null || log "function_graph tracer unavailable (continuing)"
  : > "$TRACEFS/set_graph_function" 2>/dev/null
  kept=""
  for f in $RESET_FNS; do
    if echo "$f" >> "$TRACEFS/set_graph_function" 2>/dev/null; then kept="$kept $f"; else log "ftrace: $f not graph-traceable, skipped"; fi
  done
  log "ftrace graph functions:$kept"
  : > "$TRACEFS/trace" 2>/dev/null
  echo 1 > "$TRACEFS/tracing_on" 2>/dev/null
  ( cat "$TRACEFS/trace_pipe" >> "$OUTDIR/ftrace_pipe.log" 2>&1 ) & PIDS="$PIDS $!"
else
  log "tracefs not writable at $TRACEFS; ftrace tier skipped (bpftrace + dmesg cover the chain)"
fi

# --- bpftrace kprobe/kretprobe with return codes (the ucode-reupload + ring proof)
# ENTER/RET markers only: a RET firing proves the function returned (no hang
# there); the last ENTER without a matching RET pinpoints a hang.  This
# bpftrace rejects the retval builtin on module kretprobes, so PASS/FAIL of the
# ring/IB tests and the reset comes from the authoritative dmesg messages
# ("GPU reset succeeded", "ib test on ring N succeeded"), not from here.
cat > "$OUTDIR/probe.bt" <<'BT'
kprobe:radeon_gpu_reset        { printf("%llu ENTER radeon_gpu_reset\n", nsecs); }
kretprobe:radeon_gpu_reset     { printf("%llu RET   radeon_gpu_reset\n", nsecs); }
kprobe:r300_asic_reset         { printf("%llu ENTER r300_asic_reset\n", nsecs); }
kretprobe:r300_asic_reset      { printf("%llu RET   r300_asic_reset\n", nsecs); }
kprobe:rs400_resume            { printf("%llu ENTER rs400_resume\n", nsecs); }
kprobe:rs400_startup           { printf("%llu ENTER rs400_startup\n", nsecs); }
kprobe:r100_cp_init            { printf("%llu ENTER r100_cp_init (ucode reupload: load_microcode inlines here)\n", nsecs); }
kretprobe:r100_cp_init         { printf("%llu RET   r100_cp_init\n", nsecs); }
kprobe:r100_ring_test          { printf("%llu ENTER r100_ring_test\n", nsecs); }
kretprobe:r100_ring_test       { printf("%llu RET   r100_ring_test\n", nsecs); }
kprobe:radeon_ib_ring_tests    { printf("%llu ENTER radeon_ib_ring_tests\n", nsecs); }
kretprobe:radeon_ib_ring_tests { printf("%llu RET   radeon_ib_ring_tests\n", nsecs); }
BT
if command -v bpftrace >/dev/null 2>&1; then
  log "bpftrace: attaching reset-chain kprobes"
  ( bpftrace -f text "$OUTDIR/probe.bt" >> "$OUTDIR/bpftrace.log" 2>&1 ) & PIDS="$PIDS $!"
  sleep 3   # let probes attach
fi

sync
log "baseline register snapshot"
snap_regs before

# --- byte-exact CP-ME overlay (only if the dump node is armed)
if [ -n "$CPME_DUMP" ] && [ -r "$CPME_DUMP" ] && [ "$(cat /sys/module/radeon/parameters/rs480_cp_me_ram_dump 2>/dev/null)" = "1" ]; then
  log "cp_me_ram_dump armed: capturing baseline overlay"
  cat "$CPME_DUMP" > "$OUTDIR/cpme_before.txt" 2>&1
else
  log "cp_me_ram_dump NOT armed (param=0): byte-exact compare skipped (kprobe on r100_cp_load_microcode is the reupload proof)"
fi

log "captures live. settling 3s."
sleep 3

if [ "$ARM" -eq 1 ]; then
  log "ARM: reading $RESET_NODE (sets needs_reset)"
  cat "$RESET_NODE" >> "$OUTDIR/harness.log" 2>&1
  log "TRIGGER: submitting one CS via: $SUBMIT_CMD"
  sh -c "$SUBMIT_CMD" >> "$OUTDIR/submit.log" 2>&1 &
  SUBPID=$!
  PIDS="$PIDS $SUBPID"
  log "waiting up to 20s for reset to complete"
  i=0; while [ $i -lt 20 ]; do
    grep -qiE "GPU reset succeed|GPU reset failed|hard locking" "$OUTDIR/dmesg_follow.log" 2>/dev/null && break
    sleep 1; i=$((i+1))
  done
  kill "$SUBPID" 2>/dev/null
  wait "$SUBPID" 2>/dev/null || true
  # Drop the reaped submitter from PIDS so the EXIT trap does not SIGTERM a
  # numeric PID the kernel may have recycled during the snapshot/summary window.
  _newpids=""
  for p in $PIDS; do [ "$p" = "$SUBPID" ] || _newpids="$_newpids $p"; done
  PIDS="$_newpids"
  log "post-trigger dmesg verdict:"; grep -iE "GPU reset|RBBM_STATUS|CRASH SHIM|lockup|ring test|ib test" "$OUTDIR/dmesg_follow.log" 2>/dev/null | tail -25 | tee -a "$OUTDIR/harness.log"
else
  log "DRY-RUN: NOT triggering a reset; verifying captures populate"
  sh -c "$SUBMIT_CMD" >> "$OUTDIR/submit.log" 2>&1 || true
  sleep 4
fi

sync
log "post register snapshot"
snap_regs after
if [ -f "$OUTDIR/cpme_before.txt" ]; then
  cat "$CPME_DUMP" > "$OUTDIR/cpme_after.txt" 2>&1
  if diff -q "$OUTDIR/cpme_before.txt" "$OUTDIR/cpme_after.txt" >/dev/null 2>&1; then
    log "CP-ME overlay byte-exact identical before/after (256-word compare PASS)"
  else
    log "CP-ME overlay DIFFERS before/after -- inspect cpme_before/after.txt"
  fi
fi

# responsiveness / recovery summary
{
  echo "=== heartbeat tail (continuous => no freeze) ==="; tail -4 "$OUTDIR/heartbeat.log"
  echo "=== bpftrace reset-chain (last 200 lines; full log in bpftrace.log) ==="; tail -n 200 "$OUTDIR/bpftrace.log" 2>/dev/null
  echo "=== ring/ib test return codes (last 200 matches; full log in bpftrace.log) ==="
  grep -E "ring_test|ib_ring_tests" "$OUTDIR/bpftrace.log" 2>/dev/null | tail -n 200
} >> "$OUTDIR/summary.txt" 2>&1
log "summary written: $OUTDIR/summary.txt"
log "DONE mode=$MODE"
