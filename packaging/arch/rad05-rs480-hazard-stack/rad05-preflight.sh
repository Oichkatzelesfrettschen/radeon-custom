#!/usr/bin/env bash
# rad05-preflight -- runtime safety gate for RS480 RAD-05 hazardous reset fires.
#
# Package presence cannot prove machine safety: the SB600 watchdog module may not
# be loaded, /dev/watchdog may be absent, the fired latch may not have been
# cleared, netconsole may be down, the feeder may be uncalibrated, or the loaded
# radeon module may not match the installed package. This preflight checks the
# runtime facts that actually matter before a destructive fire. It is advisory:
# it reports PASS/FAIL/WARN per check and exits non-zero if any hard gate fails.
#
# Usage:
#   rad05-preflight            # full gate; nonzero exit blocks a fire
#   rad05-preflight --recovery # allow lockup_timeout != 0 (recovery-test mode)
set -u

recovery_mode=0
[ "${1:-}" = "--recovery" ] && recovery_mode=1

pass=0; fail=0; warn=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  WARN  %s\n' "$1"; warn=$((warn+1)); }

echo "rad05-preflight: RS480 hazardous-fire runtime gate"

# 1. SB600 watchdog module loads (IOAPIC-page fallback provides /dev/watchdog).
if lsmod | grep -q '^sp5100_tco' || modprobe sp5100_tco 2>/dev/null; then
    ok "sp5100_tco loaded"
else
    bad "sp5100_tco not loaded (SB600 watchdog substrate absent)"
fi

# 2. /dev/watchdog exists (the module actually claimed the 8-byte window).
if [ -c /dev/watchdog ]; then
    ok "/dev/watchdog present"
else
    bad "/dev/watchdog missing (IOAPIC-page fallback did not map the watchdog window)"
fi

# 3. Fired-latch fix version installed (>= 0.4-4 clears SP5100_WDT_FIRED on first touch).
sp_ver=$(pacman -Q sp5100-tco-ioapic-dkms 2>/dev/null | awk '{print $2}')
if [ -n "$sp_ver" ] && [ "$(printf '%s\n0.4-4\n' "$sp_ver" | sort -V | head -1)" = "0.4-4" ]; then
    ok "sp5100-tco-ioapic-dkms $sp_ver (fired-latch fix present)"
else
    bad "sp5100-tco-ioapic-dkms ${sp_ver:-absent} < 0.4-4 (fired latch may retrigger reset on warm boot)"
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

# 6. Watchdog feeder calibration passed OR explicitly disabled for this run.
#    The feeder is calibration-pending; it must be OFF unless a passing calibration
#    marker exists. RAD05_WD_FEEDER_OK=1 in the environment is the explicit opt-in.
if [ "${RAD05_WD_FEEDER_OK:-0}" = "1" ] && [ -f /var/lib/rad05/wd-feeder-calibrated ]; then
    ok "watchdog feeder calibration marker present and opted in"
else
    note "watchdog feeder DISABLED (calibration-pending: box resets during feed ~20-29 s). Fire without watchdog; accept manual recovery."
fi

# 7. Loaded radeon module matches the installed package (no stale module under test).
running=$(cat /sys/module/radeon/srcversion 2>/dev/null)
installed=$(modinfo -F srcversion "/lib/modules/$(uname -r)/updates/dkms/radeon.ko.zst" 2>/dev/null)
if [ -n "$running" ] && [ "$running" = "$installed" ]; then
    ok "radeon srcversion $running matches installed package"
else
    bad "radeon srcversion mismatch (running=$running installed=$installed) -- reboot to load the installed module"
fi

echo "rad05-preflight: $pass pass, $warn warn, $fail fail"
[ "$fail" -eq 0 ] || { echo "rad05-preflight: BLOCKED -- resolve FAIL gates before firing"; exit 1; }
echo "rad05-preflight: hard gates OK (review WARN lines before firing)"
exit 0
