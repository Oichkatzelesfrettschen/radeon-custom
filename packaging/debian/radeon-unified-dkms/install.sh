#!/bin/sh
# Install the radeon-palm-gate DKMS package on the local host.
#
# Copies the package contents to /usr/src/radeon-palm-gate-1.0/,
# registers with DKMS (add + build + install), and regenerates the
# initramfs.  Subsequent kernel installs will pick up the package
# via the dkms_autoinstaller hook.

set -eu

SRC_DIR="$(dirname "$(readlink -f "$0")")"
DEST_DIR="/usr/src/radeon-palm-gate-1.0"

[ "$(id -u)" -eq 0 ] || {
    echo "install.sh must run as root (sudo)." >&2
    exit 1
}

# Wait for competing compile/install jobs to drain.  On a 2-core
# Bobcat, kicking off a clang-19 kernel-module build while
# another long mesa or kernel-image rebuild is running causes
# both to run several times slower than necessary.  The grace
# period is bounded so a stuck job doesn't block install.sh
# forever.
WAIT_FOR_COMPILE_JOBS_TIMEOUT="${WAIT_FOR_COMPILE_JOBS_TIMEOUT:-1800}" # 30 min
deadline=$(($(date +%s) + WAIT_FOR_COMPILE_JOBS_TIMEOUT))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    busy=""
    # heavy compile-time CPU users that we should NOT race
    for pat in \
        "ninja " \
        "make -j" \
        "make modules" \
        "apt-get install.*linux-image" \
        "clang-2[1-9]" \
        "g++-[0-9]" \
        "rustc"; do
        if pgrep -fa "${pat}" 2>/dev/null |
            grep -v "install.sh\|dkms_autoinstaller\|/usr/sbin/dkms" |
            grep -q .; then
            busy="${busy:+${busy}, }${pat}"
        fi
    done
    [ -z "${busy}" ] && break
    echo "[install] waiting for compile-job(s): ${busy}"
    sleep 15
done

echo "[install] staging ${DEST_DIR}/"
rm -rf "${DEST_DIR}"
mkdir -p "${DEST_DIR}"
cp -a "${SRC_DIR}/dkms.conf" "${DEST_DIR}/"
cp -a "${SRC_DIR}/prep-source.sh" "${DEST_DIR}/"
cp -a "${SRC_DIR}/patches" "${DEST_DIR}/"
CANONICAL_STEINMARDER_EXT_DIR="${SRC_DIR}/../../../../r600/kernel_modules/radeon_steinmarder_ext"
if [ -d "${CANONICAL_STEINMARDER_EXT_DIR}" ]; then
    mkdir -p "${DEST_DIR}/radeon-steinmarder-ext-sources"
    cp -a "${CANONICAL_STEINMARDER_EXT_DIR}/radeon_steinmarder_ext.c" \
        "${DEST_DIR}/radeon-steinmarder-ext-sources/"
    cp -a "${CANONICAL_STEINMARDER_EXT_DIR}/radeon_steinmarder_ext.h" \
        "${DEST_DIR}/radeon-steinmarder-ext-sources/"
elif [ -d "${SRC_DIR}/radeon-steinmarder-ext-sources" ]; then
    cp -a "${SRC_DIR}/radeon-steinmarder-ext-sources" "${DEST_DIR}/"
fi
# Embedded pre-patched radeon source tarball, the perf_query_ioctl +
# palm_cs_observer source overlays, the install/uninstall companions, and the
# README all need to land in the dkms source dir alongside dkms.conf and
# prep-source.sh.  Copy whatever is present; missing items are
# tolerated and prep-source.sh decides what to do at build time.
#
# uninstall.sh + PALM_CS_OBSERVER_INSTALL.md MUST be copied alongside install.sh
# so the rollback path documented in PALM_CS_OBSERVER_INSTALL.md ("cd
# /usr/src/radeon-palm-gate-1.0 ; sudo ./uninstall.sh") actually
# works on the installed host.  Earlier versions of install.sh only
# copied dkms.conf + prep-source.sh + patches/ + radeon source +
# perf_query_ioctl sources + README.md, which left the operator with no way to
# uninstall short of recovering the source tree from elsewhere.
for extra in \
    radeon-source-prepatched.tar.xz \
    perf-query-sources \
    palm-cs-observer-sources \
    README.md \
    PALM_CS_OBSERVER_INSTALL.md \
    uninstall.sh \
    check.sh; do
    [ -e "${SRC_DIR}/${extra}" ] && cp -a "${SRC_DIR}/${extra}" "${DEST_DIR}/"
done
chmod +x "${DEST_DIR}/prep-source.sh"
[ -e "${DEST_DIR}/uninstall.sh" ] && chmod +x "${DEST_DIR}/uninstall.sh"
[ -e "${DEST_DIR}/check.sh" ] && chmod +x "${DEST_DIR}/check.sh"

echo "[install] dkms add"
dkms add -m radeon-palm-gate -v 1.0 || true

echo "[install] dkms build for $(uname -r)"
dkms build -m radeon-palm-gate -v 1.0

echo "[install] dkms install"
dkms install -m radeon-palm-gate -v 1.0 --force

# Install the declarative modprobe.d defaults file so subsequent
# boots load radeon with operator-pinned parameters.  The repo
# layout has it beside usr/ under the package root; installed
# /usr/src copies may not carry that sibling, so absence warns and
# continues.
PACKAGE_ROOT="$(cd "${SRC_DIR}/../../.." 2>/dev/null && pwd || printf '')"
SRC_MODPROBE=""
if [ -n "${PACKAGE_ROOT}" ] && [ "${PACKAGE_ROOT}" != "/" ] &&
    [ -f "${PACKAGE_ROOT}/etc/modprobe.d/radeon-palm-gate.conf" ]; then
    SRC_MODPROBE="${PACKAGE_ROOT}/etc/modprobe.d/radeon-palm-gate.conf"
fi
if [ -n "${SRC_MODPROBE}" ]; then
    echo "[install] modprobe.d defaults -> /etc/modprobe.d/radeon-palm-gate.conf"
    install -m 0644 -o root -g root "${SRC_MODPROBE}" /etc/modprobe.d/radeon-palm-gate.conf
else
    echo "[install] WARN: modprobe.d defaults file not found"
    echo "[install]       module will use built-in radeon parameter defaults"
fi

echo "[install] update-initramfs"
update-initramfs -u -k "$(uname -r)"

echo "[install] verify"
dkms status -m radeon-palm-gate
ls -la /lib/modules/"$(uname -r)"/updates/dkms/radeon.ko 2>&1 || true

echo
echo "Done.  Reboot to load the patched radeon module."
echo "After reboot:"
echo "  cat /sys/module/radeon/parameters/palm_pci_reset_unsafe   # expect 0"
echo "  ls /sys/kernel/debug/radeon_force_pci_reset_safe          # expect present"
