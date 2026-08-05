#!/bin/sh
# check_radeon_display_health: compound display-health oracle for a radeon host.
#
# systemctl is-active graphical.target reports service orchestration state and
# stays active while a parked GPU rejects every modeset and the panel is dark,
# measured on RS482 (steinmarder-r300 bundle
# cachyos_vostro1000_rs482_parked_entry_contract_matrix_20260805T055406Z).
# A display-health verdict therefore rests on the DRM and framebuffer facts:
# the expected connector reports connected, a mode is enabled on it, and the
# radeon framebuffer owns a /proc/fb slot. The kernel log check is separate
# because "parked: rejecting modeset" names explicit display loss, which is
# the expected state on a parked device rather than a defect.
#
# usage: check_radeon_display_health.sh [--connector NAME] [--fb PATTERN]
#                                       [--sysroot DIR] [--selftest]
set -u

connector=LVDS-1
fb_pattern=radeondrmfb
sysroot=""
selftest=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --connector) connector=$2; shift 2 ;;
        --fb) fb_pattern=$2; shift 2 ;;
        --sysroot) sysroot=$2; shift 2 ;;
        --selftest) selftest=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

check_root() {
    root=$1
    root_fails=0

    status_file=""
    for card in "$root"/sys/class/drm/card*-"$connector"; do
        [ -r "$card/status" ] || continue
        status_file="$card/status"
        break
    done
    if [ -z "$status_file" ]; then
        echo "  FAIL  connector $connector absent from $root/sys/class/drm"
        root_fails=$((root_fails + 1))
    else
        status=$(cat "$status_file")
        if [ "$status" = "connected" ]; then
            echo "  PASS  connector $connector connected"
        else
            echo "  FAIL  connector $connector status is $status"
            root_fails=$((root_fails + 1))
        fi
        enabled=$(cat "$(dirname "$status_file")/enabled" 2>/dev/null || echo absent)
        if [ "$enabled" = "enabled" ]; then
            echo "  PASS  connector $connector has an enabled mode"
        else
            echo "  FAIL  connector $connector enabled is $enabled"
            root_fails=$((root_fails + 1))
        fi
    fi

    if grep -q "$fb_pattern" "$root/proc/fb" 2>/dev/null; then
        echo "  PASS  $fb_pattern owns a /proc/fb slot"
    else
        echo "  FAIL  $fb_pattern absent from /proc/fb"
        root_fails=$((root_fails + 1))
    fi

    # Orchestration state is reported, never judged: graphical.target stays
    # active on a parked device with a dark panel, so it cannot carry a
    # display verdict in either direction.
    if [ -z "$sysroot" ] && command -v systemctl >/dev/null 2>&1; then
        gt=$(systemctl is-active graphical.target 2>/dev/null || true)
        echo "  INFO  graphical.target=$gt (orchestration state, not display health)"
    fi

    return "$root_fails"
}

if [ "$selftest" -eq 1 ]; then
    tmp=$(mktemp -d) || exit 2
    trap 'rm -rf "$tmp"' EXIT INT TERM
    fails=0

    good="$tmp/good"
    mkdir -p "$good/sys/class/drm/card0-LVDS-1" "$good/proc"
    echo connected > "$good/sys/class/drm/card0-LVDS-1/status"
    echo enabled > "$good/sys/class/drm/card0-LVDS-1/enabled"
    echo "0 radeondrmfb" > "$good/proc/fb"
    if sysroot=$good check_root "$good" >/dev/null; then
        echo "selftest known-good accepted: connected, enabled, fb present"
    else
        echo "selftest known-good REJECTED" >&2; fails=$((fails + 1))
    fi

    for bad in disconnected-connector missing-fb disabled-mode absent-connector; do
        b="$tmp/$bad"
        mkdir -p "$b/sys/class/drm/card0-LVDS-1" "$b/proc"
        echo connected > "$b/sys/class/drm/card0-LVDS-1/status"
        echo enabled > "$b/sys/class/drm/card0-LVDS-1/enabled"
        echo "0 radeondrmfb" > "$b/proc/fb"
        case "$bad" in
            disconnected-connector) echo disconnected > "$b/sys/class/drm/card0-LVDS-1/status" ;;
            missing-fb) echo "0 efifb" > "$b/proc/fb" ;;
            disabled-mode) echo disabled > "$b/sys/class/drm/card0-LVDS-1/enabled" ;;
            absent-connector) rm -r "$b/sys/class/drm/card0-LVDS-1" ;;
        esac
        if sysroot=$b check_root "$b" >/dev/null; then
            echo "selftest known-bad ACCEPTED: $bad" >&2; fails=$((fails + 1))
        else
            echo "selftest known-bad rejected: $bad"
        fi
    done

    [ "$fails" -eq 0 ] || { echo "selftest: $fails misclassified" >&2; exit 1; }
    echo "selftest: 1 good and 4 bad sysroots classified"
    exit 0
fi

echo "check_radeon_display_health: connector=$connector fb=$fb_pattern"
if check_root "$sysroot"; then
    echo "check_radeon_display_health: PASS"
    exit 0
fi
echo "check_radeon_display_health: FAIL"
exit 1
