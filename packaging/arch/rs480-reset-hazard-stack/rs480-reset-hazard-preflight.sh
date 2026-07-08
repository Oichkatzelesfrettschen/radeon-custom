#!/usr/bin/env bash
# rs480-reset-hazard-preflight -- runtime safety gate for RS480 RAD-05 hazardous reset fires.
#
# Package presence cannot prove machine safety: the SB600 watchdog module may not
# be loaded, /dev/watchdog may be absent, the fired latch may not have been
# cleared, netconsole may be down, or the loaded radeon module may not match the
# installed package. This preflight checks the runtime facts that actually matter
# before a destructive fire. It is advisory: it reports PASS/FAIL/WARN per check
# and exits non-zero if any hard gate fails.
#
# Watchdog policy on this Vostro: active watchdog feeding is RETIRED for RAD-05
# fire timing. The SB600 hardware reset event is not deferrable through
# WDIOC_SETTIMEOUT, WDIOC_KEEPALIVE, or magic close (calibration proved the real
# reset fires in a fixed sub-second window regardless). Hazard fires use
# boot-persistent netconsole and manual recovery. No watchdog is therefore a
# SANCTIONED condition for RAD-05i/RAD-05j design and no-fuse fires; the watchdog
# substrate is retained only for watchdog research and the fired-latch-safe boot.
# A run that explicitly requires feeding (RAD05_WD_FEEDER_REQUIRED=1) cannot be
# satisfied and hard-fails, by design.
#
# Usage:
#   rs480-reset-hazard-preflight            # full gate; nonzero exit blocks a fire
#   rs480-reset-hazard-preflight --recovery # allow lockup_timeout != 0 (recovery-test mode)
set -u

recovery_mode=0
[ "${1:-}" = "--recovery" ] && recovery_mode=1

pass=0; fail=0; warn=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  WARN  %s\n' "$1"; warn=$((warn+1)); }

echo "rs480-reset-hazard-preflight: RS480 hazardous-fire runtime gate"

# 1. SB600 watchdog module presence (substrate visibility; PASS/WARN per policy).
#    Feeding is retired, so absence is not fatal to a no-watchdog fire -- it only
#    means the watchdog substrate is not visible for research/fired-latch boots.
if lsmod | grep -q '^sp5100_tco' || modprobe sp5100_tco 2>/dev/null; then
    ok "sp5100_tco present (watchdog substrate visible)"
else
    note "sp5100_tco not loaded (watchdog substrate not visible; fine for a no-watchdog fire)"
fi

# 2. /dev/watchdog exists (general substrate visibility; PASS/WARN).
#    Feeding is retired for fire timing, so a fire never relies on this node;
#    present is PASS for research visibility, absent is WARN, never a hard gate.
if [ -c /dev/watchdog ]; then
    ok "/dev/watchdog present (substrate visible)"
else
    note "/dev/watchdog missing (watchdog substrate not visible; fine for a no-watchdog fire)"
fi

# 3. Fired-latch fix version (>= 0.4-4 clears SP5100_WDT_FIRED on first touch).
#    Relevant to a fired-latch-safe boot; not on the critical path of a no-fuse
#    fire (the watchdog is never armed), so present-but-old or absent is WARN.
sp_ver=$(pacman -Q sp5100-tco-ioapic-dkms 2>/dev/null | awk '{print $2}')
if [ -n "$sp_ver" ] && [ "$(printf '%s\n0.4-4\n' "$sp_ver" | sort -V | head -1)" = "0.4-4" ]; then
    ok "sp5100-tco-ioapic-dkms $sp_ver (fired-latch fix present)"
else
    note "sp5100-tco-ioapic-dkms ${sp_ver:-absent} < 0.4-4 (fired-latch fix not confirmed; matters only if the watchdog is ever armed)"
fi

# 4. Persistent netconsole service active (off-box capture of the last pre-freeze line).
if systemctl is-active --quiet netconsole-rad05.service 2>/dev/null && lsmod | grep -q '^netconsole'; then
    ok "netconsole-rad05 active (off-box capture live)"
else
    note "netconsole-rad05 not active -- the direct-freeze last line will not be captured off-box"
fi

# 5. lockup_timeout=0 unless deliberately testing recovery.
lt=$(cat /sys/module/radeon/parameters/lockup_timeout 2>/dev/null)
if [ "$recovery_mode" = "1" ]; then
    note "lockup_timeout=$lt (recovery-test mode: non-zero permitted)"
elif [ "$lt" = "0" ]; then
    ok "lockup_timeout=0 (safe default)"
else
    bad "lockup_timeout=$lt but not in --recovery mode (radeon may drive its own reset)"
fi

# 6. Watchdog feeder state (RETIRED for RAD-05 fire timing).
#    Active feeding is retired: WDIOC_SETTIMEOUT, WDIOC_KEEPALIVE, and magic close
#    do not defer the SB600 reset on this board (fixed sub-second window). A fire
#    profile that explicitly requires feeding cannot be satisfied and hard-fails;
#    the default (no feeder required) reports the retired state and is sanctioned.
if [ "${RS480_WD_FEEDER_REQUIRED:-${RAD05_WD_FEEDER_REQUIRED:-0}}" = "1" ]; then
    bad "WATCHDOG_FEEDER=RETIRED_FOR_RAD05_FIRE_TIMING but this run requires feeding -- unsatisfiable; use netconsole + manual recovery or validate a different recovery mechanism"
else
    ok "WATCHDOG_FEEDER=RETIRED_FOR_RAD05_FIRE_TIMING (sanctioned: hazard fires use netconsole + manual recovery)"
fi

# 7. Loaded radeon module matches the installed package (no stale module under test).
running=$(cat /sys/module/radeon/srcversion 2>/dev/null)
installed=$(modinfo -F srcversion "/lib/modules/$(uname -r)/updates/dkms/radeon.ko.zst" 2>/dev/null)
if [ -n "$running" ] && [ "$running" = "$installed" ]; then
    ok "radeon srcversion $running matches installed package"
else
    bad "radeon srcversion mismatch (running=$running installed=$installed) -- reboot to load the installed module"
fi

echo "rs480-reset-hazard-preflight: $pass pass, $warn warn, $fail fail"
[ "$fail" -eq 0 ] || { echo "rs480-reset-hazard-preflight: BLOCKED -- resolve FAIL gates before firing"; exit 1; }
echo "rs480-reset-hazard-preflight: hard gates OK (review WARN lines before firing)"
exit 0
