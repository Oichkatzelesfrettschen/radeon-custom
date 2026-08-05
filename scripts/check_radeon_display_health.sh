#!/bin/sh
# check_radeon_display_health: compound display-health oracle for a radeon host.
#
# systemctl is-active graphical.target reports service orchestration state and
# stays active while a parked GPU rejects every modeset and the panel is dark,
# measured on RS482 (steinmarder-r300 bundle
# cachyos_vostro1000_rs482_parked_entry_contract_matrix_20260805T055406Z).
# A display-health verdict therefore rests on kernel-side facts: the expected
# connector reports connected, a mode is enabled on it, the DRM card carrying
# that connector is bound to the radeon driver, the radeon framebuffer owns a
# /proc/fb slot, and the device is unparked.
#
# The oracle answers whether the display works. A parked device answers no:
# 0050-rs480-parked-gpu-modeset-and-flip-gate.patch returns success without
# programming the mode, so connected/enabled sysfs state and a /proc/fb slot
# survive a dark panel. That state follows from containment design and still
# counts as display failure here.
#
# Parked state comes from the radeon_rs480_safe_regs debugfs node, which
# 0061-rs480-parked-gpu-debugfs-readers-hard-return.patch makes print
# "gpu parked" for as long as the device stays parked. The kernel log carries
# the same fact through "parked: rejecting modeset", emitted by dev_err_once
# and therefore lost to ring wrap on a long-uptime host, so the log serves as
# the fallback when the debugfs node is unreadable. With neither source
# readable the parked check reports not run.
#
# usage: check_radeon_display_health.sh [--connector NAME] [--fb PATTERN]
#                                       [--driver NAME] [--kernel-log FILE]
#                                       [--sysroot DIR] [--self-test]
set -u

connector=LVDS-1
fb_pattern=radeondrmfb
driver=radeon
kernel_log=""
sysroot=""
selftest=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --connector) connector=$2; shift 2 ;;
        --fb) fb_pattern=$2; shift 2 ;;
        --driver) driver=$2; shift 2 ;;
        --kernel-log) kernel_log=$2; shift 2 ;;
        --sysroot) sysroot=$2; shift 2 ;;
        --self-test) selftest=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

check_root() {
    root=$1
    root_fails=0

    connector_dir=""
    for card in "$root"/sys/class/drm/card*-"$connector"; do
        [ -r "$card/status" ] || continue
        connector_dir=$card
        break
    done
    if [ -z "$connector_dir" ]; then
        echo "  FAIL  connector $connector absent from $root/sys/class/drm"
        root_fails=$((root_fails + 1))
    else
        status=$(cat "$connector_dir/status")
        if [ "$status" = "connected" ]; then
            echo "  PASS  connector $connector connected"
        else
            echo "  FAIL  connector $connector status is $status"
            root_fails=$((root_fails + 1))
        fi
        enabled=$(cat "$connector_dir/enabled" 2>/dev/null || echo absent)
        if [ "$enabled" = "enabled" ]; then
            echo "  PASS  connector $connector has an enabled mode"
        else
            echo "  FAIL  connector $connector enabled is $enabled"
            root_fails=$((root_fails + 1))
        fi

        # The connector directory name carries its card: card0-LVDS-1 belongs
        # to card0, whose device/driver link names the bound driver. A panel
        # lit by simpledrm or efifb with radeon unbound keeps the connector
        # rows above and fails here.
        card_name=${connector_dir##*/}
        card_name=${card_name%%-*}
        driver_link="$root/sys/class/drm/$card_name/device/driver"
        if [ -L "$driver_link" ]; then
            bound=$(readlink "$driver_link")
            bound=${bound##*/}
        else
            bound=absent
        fi
        if [ "$bound" = "$driver" ]; then
            echo "  PASS  $card_name is bound to $driver"
        else
            echo "  FAIL  $card_name driver is $bound"
            root_fails=$((root_fails + 1))
        fi
    fi

    if grep -q "$fb_pattern" "$root/proc/fb" 2>/dev/null; then
        echo "  PASS  $fb_pattern owns a /proc/fb slot"
    else
        echo "  FAIL  $fb_pattern absent from /proc/fb"
        root_fails=$((root_fails + 1))
    fi

    parked_node=""
    for node in "$root"/sys/kernel/debug/dri/*/radeon_rs480_safe_regs; do
        [ -r "$node" ] || continue
        parked_node=$node
        break
    done
    if [ -n "$parked_node" ]; then
        if grep -q "gpu parked" "$parked_node"; then
            echo "  FAIL  device parked: the modeset gate holds the panel down"
            root_fails=$((root_fails + 1))
        else
            echo "  PASS  device unparked ($parked_node)"
        fi
    else
        log_source=$kernel_log
        if [ -z "$log_source" ] && [ -n "$sysroot" ]; then
            log_source="$root/kernel.log"
        fi
        if [ -n "$log_source" ] && [ -r "$log_source" ]; then
            if grep -q "parked: rejecting modeset" "$log_source"; then
                echo "  FAIL  device parked: $log_source carries the modeset refusal"
                root_fails=$((root_fails + 1))
            else
                echo "  PASS  $log_source carries no modeset refusal"
            fi
        elif [ -z "$sysroot" ] && command -v dmesg >/dev/null 2>&1 &&
             dmesg >/dev/null 2>&1; then
            if dmesg 2>/dev/null | grep -q "parked: rejecting modeset"; then
                echo "  FAIL  device parked: dmesg carries the modeset refusal"
                root_fails=$((root_fails + 1))
            else
                echo "  PASS  dmesg carries no modeset refusal (ring wrap drops" \
                     "the dev_err_once line, so this is weaker than the node)"
            fi
        else
            echo "  INFO  parked check not run: radeon_rs480_safe_regs is" \
                 "unreadable and no kernel log is available"
        fi
    fi

    # Orchestration state is reported, never judged: graphical.target stays
    # active on a parked device with a dark panel, so it carries no display
    # verdict in either direction.
    if [ -z "$sysroot" ] && command -v systemctl >/dev/null 2>&1; then
        gt=$(systemctl is-active graphical.target 2>/dev/null)  # orchestration state
        echo "  INFO  graphical.target=$gt (orchestration state, not display health)"
    fi

    return "$root_fails"
}

populate_root() {
    b=$1
    mkdir -p "$b/sys/class/drm/card0-LVDS-1" "$b/sys/class/drm/card0/device" \
        "$b/sys/kernel/debug/dri/0" "$b/proc" "$b/bus/pci/drivers/radeon"
    echo connected > "$b/sys/class/drm/card0-LVDS-1/status"
    echo enabled > "$b/sys/class/drm/card0-LVDS-1/enabled"
    ln -sf ../../../../bus/pci/drivers/radeon \
        "$b/sys/class/drm/card0/device/driver"
    echo "0 radeondrmfb" > "$b/proc/fb"
    echo "RS480 safe register rows follow" \
        > "$b/sys/kernel/debug/dri/0/radeon_rs480_safe_regs"
    echo "radeon 0000:01:05.0: ring test succeeded" > "$b/kernel.log"
}

if [ "$selftest" -eq 1 ]; then
    tmp=$(mktemp -d) || exit 2
    trap 'rm -rf "$tmp"' EXIT INT TERM
    fails=0

    good="$tmp/good"
    populate_root "$good"
    if sysroot=$good check_root "$good" >/dev/null; then
        echo "selftest known-good accepted: connected, enabled, bound, fb, unparked"
    else
        echo "selftest known-good REJECTED" >&2; fails=$((fails + 1))
    fi

    for bad in disconnected-connector missing-fb disabled-mode \
               absent-connector foreign-driver parked-debugfs \
               parked-kernel-log; do
        b="$tmp/$bad"
        populate_root "$b"
        case "$bad" in
            disconnected-connector)
                echo disconnected > "$b/sys/class/drm/card0-LVDS-1/status" ;;
            missing-fb)
                echo "0 efifb" > "$b/proc/fb" ;;
            disabled-mode)
                echo disabled > "$b/sys/class/drm/card0-LVDS-1/enabled" ;;
            absent-connector)
                rm -r "$b/sys/class/drm/card0-LVDS-1" ;;
            foreign-driver)
                ln -sf ../../../../bus/pci/drivers/simpledrm \
                    "$b/sys/class/drm/card0/device/driver" ;;
            parked-debugfs)
                echo "gpu parked: RS480 register read disabled" \
                    > "$b/sys/kernel/debug/dri/0/radeon_rs480_safe_regs" ;;
            parked-kernel-log)
                rm -r "$b/sys/kernel/debug"
                printf '%s\n' \
                    "radeon 0000:01:05.0: parked: rejecting modeset, display stays down" \
                    > "$b/kernel.log" ;;
        esac
        if sysroot=$b check_root "$b" >/dev/null; then
            echo "selftest known-bad ACCEPTED: $bad" >&2; fails=$((fails + 1))
        else
            echo "selftest known-bad rejected: $bad"
        fi
    done

    [ "$fails" -eq 0 ] || { echo "selftest: $fails misclassified" >&2; exit 1; }
    echo "selftest: 1 good and 7 bad sysroots classified"
    exit 0
fi

echo "check_radeon_display_health: connector=$connector fb=$fb_pattern driver=$driver"
if check_root "$sysroot"; then
    echo "check_radeon_display_health: PASS"
    exit 0
fi
echo "check_radeon_display_health: FAIL"
exit 1
