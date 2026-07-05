#!/bin/sh
# Uninstall the radeon-palm-gate DKMS package.

set -eu

[ "$(id -u)" -eq 0 ] || {
    echo "uninstall.sh must run as root (sudo)." >&2
    exit 1
}

KVER="$(uname -r)"

echo "[uninstall] dkms uninstall (all kernels)"
dkms uninstall -m radeon-palm-gate -v 1.0 --all 2>/dev/null || true

echo "[uninstall] dkms remove"
dkms remove -m radeon-palm-gate -v 1.0 --all 2>/dev/null || true

echo "[uninstall] purge /usr/src/radeon-palm-gate-1.0/"
rm -rf /usr/src/radeon-palm-gate-1.0

echo "[uninstall] update-initramfs"
update-initramfs -u -k "${KVER}"

echo "Done.  After next reboot the stock in-tree radeon module loads."
