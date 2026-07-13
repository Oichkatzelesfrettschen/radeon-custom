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
# A run that explicitly requires feeding cannot be satisfied and hard-fails.
#
# Usage:
#   rs480-reset-hazard-preflight            # full gate; nonzero exit blocks a fire
#   rs480-reset-hazard-preflight --recovery # allow lockup_timeout != 0 (recovery-test mode)
#
# Environment (all default unset/0; exact opt-in only):
#   RS480_WD_FEEDER_REQUIRED=1
#   RAD05_WD_FEEDER_REQUIRED=1   # legacy alias of the above
#       Hard-fail: this run claims it needs the retired watchdog feeder.
#   RAD05_WD_FEEDER_OK=1
#       Hard-fail: legacy opt-in that used to enable the feeder; still unsatisfiable.
#   RS480_WD_RESEARCH=1
#       Permit a privileged visibility-only note that sp5100_tco is unloaded; the
#       preflight never loads the watchdog module (loading can wedge the host on
#       the SB600 TCO control write path).
set -u

recovery_mode=0
[ "${1:-}" = "--recovery" ] && recovery_mode=1

pass=0; fail=0; warn=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  WARN  %s\n' "$1"; warn=$((warn+1)); }

echo "rs480-reset-hazard-preflight: RS480 hazardous-fire runtime gate"

# 1. SB600 watchdog module presence (observe only; never modprobe).
#    Feeding is retired, so absence is not fatal to a no-watchdog fire. Loading
#    sp5100_tco from preflight is forbidden: the SB600 TCO control write can
#    wedge the host, and a non-fatal visibility check must not arm that path.
if lsmod | grep -q '^sp5100_tco'; then
    ok "sp5100_tco loaded (watchdog substrate visible)"
    # Prefer the running module matches the installed DKMS build when both
    # srcversions are readable; mismatch is WARN (reboot/reload needed).
    sp_running=$(cat /sys/module/sp5100_tco/srcversion 2>/dev/null || true)
    sp_path=$(modinfo -k "$(uname -r)" -n sp5100_tco 2>/dev/null || true)
    case "$sp_path" in
        *updates/*|*dkms*) ;;
        *)
            for cand in /lib/modules/"$(uname -r)"/updates/dkms/sp5100_tco.ko*; do
                [ -e "$cand" ] || continue
                sp_path=$cand
                break
            done
            ;;
    esac
    sp_installed=
    [ -n "$sp_path" ] && sp_installed=$(modinfo -F srcversion "$sp_path" 2>/dev/null || true)
    if [ -n "$sp_running" ] && [ -n "$sp_installed" ]; then
        if [ "$sp_running" = "$sp_installed" ]; then
            ok "sp5100_tco srcversion $sp_running matches installed module"
        else
            note "sp5100_tco srcversion mismatch (running=$sp_running installed=$sp_installed); reboot or reload before trusting the fired-latch fix"
        fi
    fi
else
    if [ "${RS480_WD_RESEARCH:-0}" = "1" ]; then
        note "sp5100_tco not loaded (RS480_WD_RESEARCH=1: substrate absent; preflight still never modprobes it)"
    else
        note "sp5100_tco not loaded (watchdog substrate not visible; fine for a no-watchdog fire; preflight never modprobes it)"
    fi
fi

# 2. Watchdog character device identity (observe only).
#    Feeding is retired, so missing /dev/watchdog is WARN. When present, prefer
#    an identity that names the SB600/sp5100 path so another watchdog driver
#    holding the compatibility node is not mistaken for the SB600 substrate.
wd_identity=""
if [ -d /sys/class/watchdog ]; then
    for ident in /sys/class/watchdog/*/identity; do
        [ -r "$ident" ] || continue
        val=$(cat "$ident" 2>/dev/null || true)
        case "$val" in
            *sp5100*|*SP5100*|*SB800*|*sb800*|*SB600*|*sb600*)
                wd_identity=$val
                break
                ;;
        esac
        [ -z "$wd_identity" ] && wd_identity=$val
    done
fi
if [ -n "$wd_identity" ]; then
    case "$wd_identity" in
        *sp5100*|*SP5100*|*SB800*|*sb800*|*SB600*|*sb600*)
            ok "watchdog identity '$wd_identity' (SB600-class substrate visible)"
            ;;
        *)
            note "watchdog identity '$wd_identity' is not SB600/sp5100_tco; /dev/watchdog may belong to another driver"
            ;;
    esac
elif [ -c /dev/watchdog ]; then
    note "/dev/watchdog present but no sysfs identity readable"
else
    note "/dev/watchdog missing (watchdog substrate not visible; fine for a no-watchdog fire)"
fi

# 3. Fired-latch fix version (>= 0.4-4 clears SP5100_WDT_FIRED on first touch).
#    Use pacman vercmp when available; epochs and Arch packaging compare rules
#    are not the same as sort -V.
sp_ver=$(pacman -Q sp5100-tco-ioapic-dkms 2>/dev/null | awk '{print $2}')
if [ -z "$sp_ver" ]; then
    note "sp5100-tco-ioapic-dkms absent (fired-latch fix not confirmed; matters only if the watchdog is ever armed)"
elif command -v vercmp >/dev/null 2>&1; then
    if [ "$(vercmp "$sp_ver" "0.4-4")" -ge 0 ]; then
        ok "sp5100-tco-ioapic-dkms $sp_ver (fired-latch fix present)"
    else
        note "sp5100-tco-ioapic-dkms $sp_ver < 0.4-4 (fired-latch fix not confirmed; matters only if the watchdog is ever armed)"
    fi
else
    # Fallback only when vercmp is missing; still better than silent pass.
    note "vercmp unavailable; cannot authoritatively compare sp5100-tco-ioapic-dkms $sp_ver against 0.4-4"
fi

# 4. Persistent netconsole service active (off-box capture of the last pre-freeze line).
if systemctl is-active --quiet netconsole-rad05.service 2>/dev/null && lsmod | grep -q '^netconsole'; then
    ok "netconsole-rad05 active (off-box capture live)"
else
    note "netconsole-rad05 not active -- the direct-freeze last line will not be captured off-box"
fi

# 5. lockup_timeout=0 unless deliberately testing recovery.
if [ ! -r /sys/module/radeon/parameters/lockup_timeout ]; then
    bad "radeon module not loaded (missing /sys/module/radeon/parameters/lockup_timeout); cannot verify lockup_timeout=0"
elif [ "$recovery_mode" = "1" ]; then
    lt=$(cat /sys/module/radeon/parameters/lockup_timeout)
    note "lockup_timeout=$lt (recovery-test mode: non-zero permitted)"
else
    lt=$(cat /sys/module/radeon/parameters/lockup_timeout)
    if [ "$lt" = "0" ]; then
        ok "lockup_timeout=0 (safe default)"
    else
        bad "lockup_timeout=$lt but not in --recovery mode (radeon may drive its own reset)"
    fi
fi

# 6. Watchdog feeder state (RETIRED for RAD-05 fire timing).
#    Active feeding is retired. Any env that still requests the feeder is an
#    unsatisfiable fire profile and hard-fails.
feeder_required=0
feeder_reason=""
if [ "${RS480_WD_FEEDER_REQUIRED:-0}" = "1" ]; then
    feeder_required=1
    feeder_reason="RS480_WD_FEEDER_REQUIRED=1"
fi
if [ "${RAD05_WD_FEEDER_REQUIRED:-0}" = "1" ]; then
    feeder_required=1
    feeder_reason="${feeder_reason:+$feeder_reason and }RAD05_WD_FEEDER_REQUIRED=1"
fi
if [ "${RAD05_WD_FEEDER_OK:-0}" = "1" ]; then
    feeder_required=1
    feeder_reason="${feeder_reason:+$feeder_reason and }RAD05_WD_FEEDER_OK=1 (legacy feeder opt-in)"
fi
if [ "$feeder_required" = "1" ]; then
    bad "watchdog feeder is RETIRED for RAD-05 fire timing but $feeder_reason is set; unset it and use netconsole + manual recovery"
else
    ok "watchdog feeder retired (RS480_WD_FEEDER_REQUIRED/RAD05_WD_FEEDER_REQUIRED/RAD05_WD_FEEDER_OK unset; hazard fires use netconsole + manual recovery)"
fi

# 7. Loaded radeon module matches the installed package (no stale module under test).
#    Resolve by module name through modinfo so compression (.ko, .ko.zst, .ko.xz)
#    and install layout do not hard-code a single path.
running=$(cat /sys/module/radeon/srcversion 2>/dev/null || true)
# Prefer the DKMS install under updates/; modinfo -n can otherwise resolve
# an in-tree radeon.ko that is not the package under test.
radeon_path=$(modinfo -k "$(uname -r)" -n radeon 2>/dev/null || true)
case "$radeon_path" in
    *updates/dkms*|*updates/*) ;;
    *)
        radeon_path=
        for cand in /lib/modules/"$(uname -r)"/updates/dkms/radeon.ko*; do
            [ -e "$cand" ] || continue
            radeon_path=$cand
            break
        done
        ;;
esac
installed=
if [ -n "$radeon_path" ]; then
    installed=$(modinfo -F srcversion "$radeon_path" 2>/dev/null || true)
fi
if [ -z "$running" ]; then
    bad "radeon module not loaded (no /sys/module/radeon/srcversion)"
elif [ -z "$installed" ]; then
    bad "cannot resolve DKMS/updates radeon srcversion (modinfo path=${radeon_path:-none})"
elif [ "$running" = "$installed" ]; then
    ok "radeon srcversion $running matches installed package"
else
    bad "radeon srcversion mismatch (running=$running installed=$installed) -- reboot to load the installed module"
fi

echo "rs480-reset-hazard-preflight: $pass pass, $warn warn, $fail fail"
[ "$fail" -eq 0 ] || { echo "rs480-reset-hazard-preflight: BLOCKED -- resolve FAIL gates before firing"; exit 1; }
echo "rs480-reset-hazard-preflight: hard gates OK (review WARN lines before firing)"
exit 0
