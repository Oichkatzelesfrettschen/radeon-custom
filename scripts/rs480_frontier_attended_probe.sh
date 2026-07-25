#!/usr/bin/env bash
# Attended single-step probe of the RS480 frontier-register residual.
#
# The K8/RS480 northbridge has no MMIO completion timeout, so a wrong read
# freezes both cores with NO software recovery: sp5100_tco fails to bind on the
# SB600 (MMIO region busy, -16), the kernel boots with `nowatchdog` so the NMI
# hardlockup detector is off, and a software timer (softdog) cannot run while the
# cores are stalled in the bus transaction.  The only recovery is an attended
# power-cycle, gated further by the BIOS/disk password.  So this harness does not
# try to PREVENT a freeze; it makes each freeze ATTRIBUTABLE to one register
# and RESUMABLE across the forced reboot:
#
#   * one register per step, selected by the radeon_rs480_frontier_index module
#     param, read through the radeon_rs480_frontier_probe debugfs node (the node
#     reads exactly that one register per open);
#   * the index->register mapping is read from the committed index-map TSV, which
#     build_frontier_probe_index_map.py keeps byte-identical to the deployed
#     kernel array.  The kernel groups the low-hazard tier ahead of the high tier,
#     so index 3 is 0x1c18 PP_FOG_COLOR (low), NOT the offset-sorted manifest's
#     0x0958 CAP0_CONFIG (high), so consuming the wrong ordering would arm an
#     unrecoverable read on a register believed safe;
#   * a per-line fsync'd /var/tmp journal (ext4; survives the reboot a /tmp tmpfs
#     would lose) records the register-under-read BEFORE the read issues, so after
#     a wedge+reboot the dangling START line names the culprit and the next run
#     skips every already-obtained index;
#   * a passive forensic bundle (dmesg follow + safe-regs snapshots) is captured
#     alongside.  This harness does NOT arm the GPU-reset capture: that addresses
#     a recoverable engine hang, a different hazard class, and arming it would
#     TRIGGER a reset; it cannot help the unrecoverable northbridge stall.
#
# Pre-arm safety gates (--arm only): the loaded radeon srcversion must equal the
# on-disk built module, the operator must pin the expected DKMS package release,
# and the disarmed node's reported (0..N) count must equal the index-map length.
# The srcversion+pkgrel pin is the pre-read table-order guard available before
# the node is opened; after each armed read the kernel echo (index/name/offset)
# is cross-checked against the map and a mismatch aborts the sweep.
#
# Usage:
#   rs480_frontier_attended_probe.sh --selftest
#   rs480_frontier_attended_probe.sh --dry-run [--max-index N | --index N | --all] [--index-map PATH]
#   RS480_FRONTIER_PROBE_ATTENDED=1 rs480_frontier_attended_probe.sh --arm [--max-index N | --index N | --all] --expect-pkgrel 0.3-22 [--index-map PATH]
#
# --selftest validates the journal fsync + crash-survival logic (no hardware).
# --dry-run does everything except the hazardous node read.  --arm performs the
# live reads.  Default --max-index is the index-map's last low-hazard row;
# --max-index N sweeps indices 0..N; --index N reads exactly the one register at
# index N (START==MAX==N), the right shape for an IDCT-specific read where
# --max-index would walk the CAP registers first; --all extends through the whole
# high-hazard CAP/IDCT tier.  An explicit --max-index/--index must name an
# implemented index in the committed index map.  When the index map carries no
# low-hazard tier (every register is high-hazard CAP/IDCT), a bare invocation is
# refused: there is no safe default sweep, so the operator must name an index with
# --index N or --max-index N or sweep all with --all.

set -u

JOURNAL_DIR=/var/tmp
JOURNAL_DRY="$JOURNAL_DIR/rs480_frontier_probe_dryrun_journal.tsv"
JOURNAL_ARM="$JOURNAL_DIR/rs480_frontier_probe_arm_journal.tsv"
PARAM=/sys/module/radeon/parameters/rs480_frontier_index
HARNESS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HARNESS_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")
INDEX_MAP="${RS480_FRONTIER_INDEX_MAP:-}"

MODE=""
MAX_INDEX=""
ONE_INDEX=""
START_INDEX=0
WANT_ALL=0
EXPECT_PKGREL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest)     MODE=selftest ;;
    --dry-run)      MODE=dry ;;
    --arm)          MODE=arm ;;
    --all)          WANT_ALL=1 ;;
    --max-index)    shift; MAX_INDEX="${1:-}" ;;
    --index)        shift; ONE_INDEX="${1:-}" ;;
    --expect-pkgrel) shift; EXPECT_PKGREL="${1:-}" ;;
    --index-map)    shift; INDEX_MAP="${1:-}" ;;
    *) echo "usage: $0 --selftest|--dry-run|--arm [--max-index N|--index N|--all] [--expect-pkgrel V] [--index-map PATH]" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$MODE" ] || { echo "must pass --selftest, --dry-run, or --arm" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "REFUSED: python3 is required for fsync journal writes" >&2; exit 4; }
if [ -z "$INDEX_MAP" ] && [ -n "$REPO" ]; then
  INDEX_MAP="$REPO/src/re/r300/docs/isa_references/rs480_frontier_probe_index_map.tsv"
fi

# fsync_append PATH LINE: append LINE to PATH and fsync both the file and its
# directory, so the breadcrumb is durably on disk BEFORE the caller continues to
# the hazardous read.  os.fsync returning is ext4's on-disk durability contract;
# `sync FILE` only flushes the filesystem and never fsyncs the directory entry,
# which a fresh-create needs.  Returns nonzero if the write or fsync fails.
fsync_append() {
  # Data goes through argv, not stdin: `python3 -` already consumes stdin as the
  # program text (the heredoc), so a piped line would be discarded.  The journal
  # fields are controlled TSV (index, name, hex offset/value), safe for argv.
  python3 - "$1" "$2" <<'PY'
import os, sys
path, line = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.write(fd, (line + "\n").encode())
os.fsync(fd)
os.close(fd)
dfd = os.open(os.path.dirname(os.path.abspath(path)), os.O_RDONLY)
os.fsync(dfd)
os.close(dfd)
PY
}

# resume_state_from_journal JOURNAL_PATH: populate the global DONE_IDX / FATAL_IDX
# maps from JOURNAL_PATH, honoring an entry ONLY when its recorded name and offset
# match the current index map at that index (MAP_NAME / MAP_OFFSET), and setting
# STALE_JOURNAL=1 if any entry mismatches.  The frontier index map is renumbered
# when the probe set changes: the high-hazard CAP/IDCT tier moved from indices
# 7..13 down to 0..6 when the low tier was promoted to safe-regs, so a journal
# written against the old numbering still holds DONE lines for indices that now
# address a different, possibly hazardous register.  Keying the skip on the index
# number alone would silently skip a never-read hazardous register because a
# benign register once sat in that slot, and the run would report completion
# without issuing the read.  A mismatched entry is ignored (not skipped); the
# operator should rotate the stale journal aside.
resume_state_from_journal() {
  local journal="$1"
  declare -gA DONE_IDX FATAL_IDX
  DONE_IDX=(); FATAL_IDX=()
  STALE_JOURNAL=0
  [ -f "$journal" ] || return 0
  local kind jidx jname joffset _rest
  while IFS=$'\t' read -r kind jidx jname joffset _rest; do
    case "$kind" in DONE|FATAL) ;; *) continue ;; esac
    [ -n "$jidx" ] || continue
    if [ "$jname" != "${MAP_NAME[$jidx]:-}" ] || [ "$joffset" != "${MAP_OFFSET[$jidx]:-}" ]; then
      STALE_JOURNAL=1
      continue
    fi
    case "$kind" in
      DONE)  DONE_IDX[$jidx]=1 ;;
      FATAL) FATAL_IDX[$jidx]=1 ;;
    esac
  done < "$journal"
  return 0
}

# ---- selftest: prove the breadcrumb is fsync'd before the next step and
# survives process death, visible to a fresh reader.  This simulates the freeze
# (SIGKILL) without causing one.  It does NOT prove power-loss durability; that
# rests on fsync's ext4 contract, and /var/tmp is ext4 on this host.
if [ "$MODE" = selftest ]; then
  jf="$JOURNAL_DIR/rs480_frontier_probe_selftest.tsv"
  ready="$JOURNAL_DIR/rs480_frontier_probe_selftest.ready"
  rm -f "$jf" "$ready"
  (
    fsync_append "$jf" "START	0	SELFTEST	0x0000	low	selftest"
    : > "$ready"      # written only after fsync_append's fsync returned
    while :; do sleep 1; done
  ) &
  child=$!
  w=0
  while [ ! -f "$ready" ] && [ "$w" -lt 50 ]; do sleep 0.1; w=$((w + 1)); done
  if [ ! -f "$ready" ]; then
    echo "selftest FAIL: child never signaled fsync completion" >&2
    kill -9 "$child" 2>/dev/null; exit 1
  fi
  kill -9 "$child" 2>/dev/null; wait "$child" 2>/dev/null
  if ! grep -q SELFTEST "$jf" 2>/dev/null; then
    echo "selftest FAIL: breadcrumb missing from $jf after SIGKILL" >&2
    rm -f "$jf" "$ready"
    exit 1
  fi
  echo "selftest PASS: breadcrumb fsync'd, survived SIGKILL, visible to a fresh reader"
  echo "  proves: write+fsync ordering before the next step + cross-process visibility"
  echo "  durability of the on-disk line under power loss rests on fsync's ext4 contract"
  rm -f "$jf" "$ready"

  # resume identity-gate calibration: a journal entry from a superseded index map
  # (name/offset not matching the current map at that index) must NOT mark the
  # index obtained, and a current-map entry must.  This is the hard-lock guard:
  # an index-map renumber plus a stale journal must never silently skip a read.
  itf="$JOURNAL_DIR/rs480_frontier_probe_selftest_identity.tsv"
  rm -f "$itf"
  MAP_NAME=(); MAP_OFFSET=()
  MAP_NAME[5]="RADEON_IDCT_AUTH_CONTROL"; MAP_OFFSET[5]="0x1f88"
  printf 'DONE\t5\tRADEON_SE_CNTL\t0x1c4c\t0x00000000\t1\n' > "$itf"          # stale (old map slot)
  printf 'DONE\t5\tRADEON_IDCT_AUTH_CONTROL\t0x1f88\t0x00000000\t2\n' >> "$itf" # current map
  resume_state_from_journal "$itf"
  if [ -z "${DONE_IDX[5]:-}" ]; then
    echo "selftest FAIL: current-map DONE not honored" >&2; rm -f "$itf"; exit 1
  fi
  if [ "${STALE_JOURNAL:-0}" -ne 1 ]; then
    echo "selftest FAIL: stale entry not flagged" >&2; rm -f "$itf"; exit 1
  fi
  printf 'DONE\t5\tRADEON_SE_CNTL\t0x1c4c\t0x00000000\t1\n' > "$itf"          # stale-only journal
  resume_state_from_journal "$itf"
  if [ -n "${DONE_IDX[5]:-}" ]; then
    echo "selftest FAIL: stale-only DONE wrongly marked index 5 obtained" >&2; rm -f "$itf"; exit 1
  fi
  rm -f "$itf"
  echo "selftest PASS: resume identity-gate honors current-map entries, ignores stale ones"
  echo "  proves: a renumbered index map plus a stale journal cannot silently skip a read"
  exit 0
fi

# ---- arming gate: presence is consent only for --arm.
if [ "$MODE" = arm ] && [ "${RS480_FRONTIER_PROBE_ATTENDED:-}" != "1" ]; then
  echo "REFUSED: set RS480_FRONTIER_PROBE_ATTENDED=1 and confirm you are physically" >&2
  echo "at vostro and able to power-cycle + enter the BIOS/disk password." >&2
  echo "A wrong read hard-locks both cores with no software recovery." >&2
  exit 3
fi

# ---- load the index map (the kernel's exact index->register order).
[ -n "$INDEX_MAP" ] || { echo "REFUSED: set --index-map or RS480_FRONTIER_INDEX_MAP (repo root not found)" >&2; exit 4; }
[ -f "$INDEX_MAP" ] || { echo "REFUSED: index map not found: $INDEX_MAP" >&2; exit 4; }

declare -a MAP_OFFSET MAP_NAME MAP_TIER
N_TOTAL=0
while IFS=$'\t' read -r idx offset name tier _; do
  case "$idx" in ''|\#*|index) continue ;; esac
  MAP_OFFSET[$idx]="$offset"; MAP_NAME[$idx]="$name"; MAP_TIER[$idx]="$tier"
  N_TOTAL=$((N_TOTAL + 1))
done < "$INDEX_MAP"
[ "$N_TOTAL" -gt 0 ] || { echo "REFUSED: index map is empty: $INDEX_MAP" >&2; exit 4; }
INDEX_MAP_SHA256=$(sha256sum "$INDEX_MAP" | awk '{print $1}')

LOW_TIER_MAX=-1
for i in $(seq 0 $((N_TOTAL - 1))); do
  [ "${MAP_TIER[$i]:-}" = low ] && LOW_TIER_MAX=$i
done

# Default: probe only the low-hazard tier.  --all or an explicit --max-index
# extends into the high-hazard CAP/IDCT tier.  When the frontier carries no
# low-hazard tier at all, since every remaining register is high-hazard CAP/IDCT,
# there is no safe default sweep: reaching any register is an explicit
# hard-lock-risk decision.  Refuse a bare invocation here, before the integer
# validation below, so a future change to LOW_TIER_MAX cannot silently turn the
# default sweep into an armed CAP read.
if [ -z "$MAX_INDEX" ] && [ -z "$ONE_INDEX" ] && [ "$WANT_ALL" -ne 1 ] && [ "$LOW_TIER_MAX" -lt 0 ]; then
  echo "REFUSED: the frontier has no low-hazard tier -- every remaining register" >&2
  echo "is high-hazard (CAP video-capture / IDCT video-decode) and a wrong read" >&2
  echo "hard-locks both cores with no software recovery on this SB600.  Name the" >&2
  echo "register explicitly with --index N or --max-index N (0..$((N_TOTAL - 1))) or" >&2
  echo "sweep the whole high tier with --all, and only with" >&2
  echo "RS480_FRONTIER_PROBE_ATTENDED=1 while physically present at the machine." >&2
  exit 2
fi
# --index N probes exactly one register (START==MAX==N), the right shape for an
# IDCT-specific read: --max-index N would walk indices 0..N (the CAP registers)
# first.  It is an explicit per-index opt-in, mutually exclusive with --max-index
# and --all, and like them still requires --arm + RS480_FRONTIER_PROBE_
# ATTENDED=1 for a live read.
if [ -n "$ONE_INDEX" ]; then
  if [ -n "$MAX_INDEX" ] || [ "$WANT_ALL" -eq 1 ]; then
    echo "--index is mutually exclusive with --max-index and --all" >&2; exit 2
  fi
  case "$ONE_INDEX" in
    ''|*[!0-9]*) echo "--index must be an integer in 0..$((N_TOTAL - 1))" >&2; exit 2 ;;
  esac
  if [ "$ONE_INDEX" -ge "$N_TOTAL" ]; then
    echo "--index $ONE_INDEX exceeds frontier max $((N_TOTAL - 1))" >&2; exit 2
  fi
  START_INDEX=$ONE_INDEX
  MAX_INDEX=$ONE_INDEX
fi
if [ -z "$MAX_INDEX" ]; then
  if [ "$WANT_ALL" -eq 1 ]; then MAX_INDEX=$((N_TOTAL - 1)); else MAX_INDEX=$LOW_TIER_MAX; fi
fi
case "$MAX_INDEX" in
  ''|*[!0-9]*) echo "--max-index must be an integer in 0..$((N_TOTAL - 1))" >&2; exit 2 ;;
esac
if [ "$MAX_INDEX" -ge "$N_TOTAL" ]; then
  echo "--max-index $MAX_INDEX exceeds frontier max $((N_TOTAL - 1))" >&2
  exit 2
fi

JOURNAL="$JOURNAL_DRY"; [ "$MODE" = arm ] && JOURNAL="$JOURNAL_ARM"

# ---- persistent forensic bundle on ext4.
BUNDLE="$JOURNAL_DIR/rs480_frontier_probe/$(date +%Y%m%dT%H%M%SZ)"
mkdir -p "$BUNDLE"
# debugfs (/sys/kernel/debug) is mode 0700 root-only, so a non-root find returns
# nothing.  This harness runs as the operator and escalates each privileged op
# with sudo -n; node discovery must escalate the same way, or DRI/NODE come up
# empty and --arm wrongly refuses with the node actually present.
DRI=$(sudo -n find /sys/kernel/debug/dri -maxdepth 1 -name '0000:*' 2>/dev/null | head -1)

snapshot_safe_regs() {  # $1 = destination file; non-hazardous (promoted-safe set)
  # The redirect target is the user-owned bundle; only the node read needs root,
  # so the shell-side redirect is correct here.  The existence test escalates
  # because the node lives under root-only debugfs; without it the snapshot
  # silently writes nothing and the canary's safe-regs health evidence is empty.
  # shellcheck disable=SC2024
  if [ -n "$DRI" ] && sudo -n test -e "$DRI/radeon_rs480_safe_regs" 2>/dev/null; then
    sudo -n cat "$DRI/radeon_rs480_safe_regs" > "$1" 2>/dev/null || true
  fi
}

# ---- disarm + cleanup.  A left-armed index hard-locks the NEXT unrelated read of
# the node, so a disarm failure is loud, not silent.
HB=""
DMESG_PID=""
read_param() {
  cat "$PARAM" 2>/dev/null || true
}
require_disarmed() {
  [ -e "$PARAM" ] || return 0
  if [ "$(read_param)" != "-1" ]; then
    if ! echo "-1" | sudo -n tee "$PARAM" >/dev/null 2>&1; then
      echo "preflight: could not write -1 to $PARAM before opening the node" >&2
      return 1
    fi
  fi
  if [ "$(read_param)" != "-1" ]; then
    echo "preflight: $PARAM is not disarmed; refusing to open the frontier node" >&2
    return 1
  fi
  return 0
}
disarm() {
  [ "$MODE" = arm ] || return 0
  [ -e "$PARAM" ] || return 0
  if ! echo "-1" | sudo -n tee "$PARAM" >/dev/null 2>&1; then
    echo "!!! WARNING: could not write -1 to $PARAM -- the frontier index may be" >&2
    echo "!!! left ARMED.  The next read of radeon_rs480_frontier_probe will perform" >&2
    echo "!!! a hazardous RREG32.  Run manually now:  echo -1 | sudo tee $PARAM" >&2
    return 1
  fi
  if [ "$(read_param)" != "-1" ]; then
    echo "!!! WARNING: $PARAM did not read back -1 after disarm; verify manually." >&2
    return 1
  fi
  return 0
}
cleanup() {
  disarm || true
  [ -n "$HB" ] && kill "$HB" 2>/dev/null
  [ -n "$DMESG_PID" ] && kill "$DMESG_PID" 2>/dev/null
  true
}
signal_exit() {
  cleanup
  trap - INT TERM
  exit 130
}
trap cleanup EXIT
trap signal_exit INT TERM

# ---- locate the node.  Both tests escalate: the node is under root-only debugfs,
# the same surface DRI was discovered on with sudo above.
NODE=""
if [ -n "$DRI" ] && sudo -n test -e "$DRI/radeon_rs480_frontier_probe" 2>/dev/null; then
  NODE="$DRI/radeon_rs480_frontier_probe"
fi
if [ -z "$NODE" ]; then
  NODE=$(sudo -n find /sys/kernel/debug -name radeon_rs480_frontier_probe 2>/dev/null | head -1)
fi
if [ -z "$NODE" ]; then
  if [ "$MODE" = arm ]; then
    echo "REFUSED: frontier probe node not found (deploy + reboot the 0015 patch first)" >&2
    exit 4
  fi
  echo "note: frontier probe node not present; dry-run will exercise journal/resume only"
fi

# ---- pre-arm preflight: version pin + count check (all non-hazardous reads).
preflight() {
  local hard="$1"   # "hard" => refuse on failure (arm); else warn (dry)
  local fail=0
  local loaded ondisk
  loaded=$(cat /sys/module/radeon/srcversion 2>/dev/null || true)
  ondisk=$(modinfo -F srcversion radeon 2>/dev/null || true)
  if [ -z "$loaded" ] || [ -z "$ondisk" ]; then
    echo "preflight: cannot read radeon srcversion (loaded='$loaded' ondisk='$ondisk')" >&2
    fail=1
  elif [ "$loaded" != "$ondisk" ]; then
    echo "preflight: loaded radeon ($loaded) != on-disk built module ($ondisk);" >&2
    echo "           a stale module is running -- the deployed 0015 table may differ" >&2
    echo "           from what the index map was checked against.  Reboot first." >&2
    fail=1
  else
    echo "preflight: loaded==on-disk radeon srcversion ($loaded)"
  fi
  if [ -z "$EXPECT_PKGREL" ] && [ "$hard" = hard ]; then
    echo "preflight: --arm requires --expect-pkgrel to pin the deployed table build" >&2
    fail=1
  elif [ -n "$EXPECT_PKGREL" ]; then
    local got
    got=$(pacman -Q radeon-unified-dkms 2>/dev/null | awk '{print $2}')
    if [ "$got" != "$EXPECT_PKGREL" ]; then
      echo "preflight: radeon-unified-dkms is '$got', expected '$EXPECT_PKGREL'" >&2
      fail=1
    else
      echo "preflight: radeon-unified-dkms pkgrel $got matches --expect-pkgrel"
    fi
  fi
  if [ -n "$NODE" ]; then
    # Ensure disarmed, then read the safe (0..N) count message.
    if ! require_disarmed; then
      fail=1
    else
      local msg hi
      msg=$(sudo -n cat "$NODE" 2>/dev/null)
      hi=$(printf '%s' "$msg" | sed -n 's/.*(0\.\.\([0-9]\+\)).*/\1/p')
      if [ -z "$hi" ]; then
        echo "preflight: disarmed node did not report a (0..N) range: '$msg'" >&2
        fail=1
      elif [ "$((hi + 1))" -ne "$N_TOTAL" ]; then
        echo "preflight: kernel reports $((hi + 1)) frontier registers, index map has $N_TOTAL;" >&2
        echo "           the deployed table and index-map TSV have drifted." >&2
        fail=1
      else
        echo "preflight: kernel count $((hi + 1)) == index-map length $N_TOTAL"
      fi
    fi
  fi
  if [ "$fail" -ne 0 ] && [ "$hard" = hard ]; then
    echo "REFUSED: preflight failed; not arming." >&2
    return 1
  fi
  return 0
}

if [ "$MODE" = arm ]; then
  preflight hard || exit 5
else
  preflight soft || true
fi

# ---- resume: skip every already-obtained index, and any index whose START has
# no terminal record (it wedged the machine last run -> FATAL, skip).  Both
# checks are gated on index-map identity: a journal entry counts only when its
# recorded name/offset match the current map at that index, so a renumbered map
# (the CAP/IDCT tier moved from 7..13 to 0..6) cannot silently skip a read.
resume_state_from_journal "$JOURNAL"
if [ "${STALE_JOURNAL:-0}" -ne 0 ]; then
  echo "resume: $JOURNAL has entries whose name/offset do not match the current" >&2
  echo "        index map -- they are IGNORED, not skipped.  Rotate the journal" >&2
  echo "        aside if it is from a superseded frontier map." >&2
fi
if [ -f "$JOURNAL" ]; then
  # Trailing unmatched START = a read that issued but never reached a terminal
  # record: it wedged the machine.  Identity-gate it, so only a START whose
  # name/offset match the current map is a wedge of a current register, and only
  # a terminal record for that same (index,name,offset) clears it.
  if read -r last_started last_name last_offset < <(
      awk -F'\t' '$1=="START"{i=$2;n=$3;o=$4} END{if(i!="")print i"\t"n"\t"o}' "$JOURNAL"
    ) \
     && [ -n "${last_started:-}" ] \
     && [ "$last_name" = "${MAP_NAME[$last_started]:-}" ] \
     && [ "$last_offset" = "${MAP_OFFSET[$last_started]:-}" ]; then
    last_terminal=$(
      awk -F'\t' -v idx="$last_started" -v nm="$last_name" -v off="$last_offset" \
        '$2==idx && $3==nm && $4==off && ($1=="DONE"||$1=="ABORT"||$1=="MISMATCH"||$1=="FATAL"){hit=1} END{print hit+0}' \
        "$JOURNAL"
    )
    if [ "$last_terminal" -eq 0 ]; then
      fsync_append "$JOURNAL" "FATAL	$last_started	${MAP_NAME[$last_started]}	${MAP_OFFSET[$last_started]}	wedged_no_DONE	$(date +%s)"
      FATAL_IDX[$last_started]=1
      echo "resume: index $last_started wedged last run -> FATAL, skipping it"
    fi
  fi
fi

echo "mode=$MODE  registers=$N_TOTAL  low-tier 0..$LOW_TIER_MAX  probing $START_INDEX..$MAX_INDEX  journal=$JOURNAL"
echo "index-map: $INDEX_MAP sha256=$INDEX_MAP_SHA256"
echo "bundle: $BUNDLE"

# ---- passive captures (forensic, not recovery).
( while :; do date +%s.%N; sleep 0.5; done >> "$BUNDLE/heartbeat.log" ) &
HB=$!
if sudo -n true 2>/dev/null; then
  # The bundle log is user-owned; only dmesg needs root, so the shell-side append
  # redirect is correct here.
  # shellcheck disable=SC2024
  ( sudo -n dmesg -wT >> "$BUNDLE/dmesg_follow.log" 2>/dev/null ) &
  DMESG_PID=$!
else
  echo "note: passive dmesg follow needs sudo -n; skipped (heartbeat + journal still cover the freeze instant)"
fi

# ---- the probe loop.
for idx in $(seq "$START_INDEX" "$MAX_INDEX"); do
  if [ -n "${DONE_IDX[$idx]:-}" ]; then echo "  skip index $idx (already obtained)"; continue; fi
  if [ -n "${FATAL_IDX[$idx]:-}" ]; then echo "  skip index $idx (FATAL last run)"; continue; fi

  name="${MAP_NAME[$idx]}"; offset="${MAP_OFFSET[$idx]}"; tier="${MAP_TIER[$idx]}"

  if ! fsync_append "$JOURNAL" "START	$idx	$name	$offset	$tier	$(date +%s)"; then
    echo "ABORT: journal write failed before reading index $idx" >&2
    exit 6
  fi

  dmesg_mark=0
  [ -f "$BUNDLE/dmesg_follow.log" ] && dmesg_mark=$(wc -l < "$BUNDLE/dmesg_follow.log")
  snapshot_safe_regs "$BUNDLE/safe_before_${idx}.txt"

  if [ "$MODE" != arm ]; then
    echo "  [$tier] index $idx $name ($offset): dry-run (would arm $PARAM=$idx, read $NODE)"
    fsync_append "$JOURNAL" "DONE	$idx	$name	$offset	dry-run	$(date +%s)"
    continue
  fi

  # Arm exactly this index; ABORT on write failure or readback mismatch.
  if ! echo "$idx" | sudo -n tee "$PARAM" >/dev/null 2>&1; then
    fsync_append "$JOURNAL" "ABORT	$idx	$name	$offset	param_write_failed	$(date +%s)"
    echo "ABORT: could not write $PARAM=$idx" >&2
    exit 6
  fi
  if [ "$(read_param)" != "$idx" ]; then
    fsync_append "$JOURNAL" "ABORT	$idx	$name	$offset	param_readback_mismatch	$(date +%s)"
    echo "ABORT: $PARAM did not read back $idx" >&2
    exit 6
  fi

  echo "  [$tier] index $idx $name ($offset) ... reading"
  line=$(sudo -n cat "$NODE" 2>&1)
  # Immediately re-disarm so a stray re-open cannot re-read; the exit trap is the
  # guarantee, this is defense in depth.
  echo "-1" | sudo -n tee "$PARAM" >/dev/null 2>&1 || true

  # Post-read echo cross-check.  The read already fired, so this is not pre-read
  # safety for THIS index, but aborting the sweep here makes it pre-read safety
  # for every index after a detected drift.
  echo_idx=$(printf '%s' "$line" | sed -n 's/^index \([0-9]\+\):.*/\1/p')
  echo_name=$(printf '%s' "$line" | sed -n 's/^index [0-9]\+: \([A-Za-z0-9_]\+\) .*/\1/p')
  echo_off=$(printf '%s' "$line" | sed -n 's/.*(\(0x[0-9A-Fa-f]\+\)).*/\1/p')
  if [ "$echo_idx" != "$idx" ] || [ "$echo_name" != "$name" ] || [ "$echo_off" != "$offset" ]; then
    fsync_append "$JOURNAL" "MISMATCH	$idx	$name	$offset	kernel:[$line]	$(date +%s)"
    echo "ABORT: kernel echo for index $idx disagrees with the index map:" >&2
    echo "  map:    $name ($offset)" >&2
    echo "  kernel: $line" >&2
    echo "  The loaded table and the index map have drifted; not reading further." >&2
    exit 7
  fi

  value=$(printf '%s' "$line" | sed -n 's/.*= \(0x[0-9A-Fa-f]\+\).*/\1/p')
  {
    echo "index=$idx name=$name offset=$offset tier=$tier ts=$(date +%s)"
    echo "node: $line"
    echo "--- dmesg delta during this read ---"
    [ -f "$BUNDLE/dmesg_follow.log" ] && tail -n +"$((dmesg_mark + 1))" "$BUNDLE/dmesg_follow.log"
  } > "$BUNDLE/index_${idx}_${name}.txt" 2>/dev/null
  snapshot_safe_regs "$BUNDLE/safe_after_${idx}.txt"

  fsync_append "$JOURNAL" "DONE	$idx	$name	$offset	${value:-noval}	$(date +%s)"
  echo "    = ${value:-<no value parsed>}"
done

echo "done indices $START_INDEX..$MAX_INDEX; journal: $JOURNAL; bundle: $BUNDLE"
