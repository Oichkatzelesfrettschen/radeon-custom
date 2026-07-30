#!/bin/sh
# DKMS PRE_BUILD hook for radeon trace include compatibility.

set -eu

LOG_PREFIX="[radeon-unified pre-build]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

KERNELVER="${1:-${kernelver:-$(uname -r)}}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RADEON_DIR="${SCRIPT_DIR}/radeon"
TRACE_HEADER="${RADEON_DIR}/radeon_trace.h"
KERNEL_BUILD_ROOT="${2:-${R300_RS480_KERNEL_BUILD_ROOT:-/lib/modules/${KERNELVER}/build}}"
KERNEL_HEADERS_RADEON_DIR="${KERNEL_BUILD_ROOT}/drivers/gpu/drm/radeon"
POLICY_HELPER="${SCRIPT_DIR}/radeon-dkms-compiler-policy"

say "kernelver=${KERNELVER}"

protected_directory() {
    directory=$1
    [ -d "$directory" ] &&
        [ ! -L "$directory" ] &&
        [ "$(stat -c %u "$directory")" -eq 0 ] &&
        ! find "$directory" -maxdepth 0 -perm /022 -print -quit |
            grep -q .
}

# Log the package-owned compiler policy before the DKMS build starts so failures
# preserve the exact compiler/cache/distcc decision.
if [ -x "${POLICY_HELPER}" ]; then
    R300_RS480_KERNEL_BUILD_ROOT="${KERNEL_BUILD_ROOT}" \
        "${POLICY_HELPER}" show "${KERNELVER}" |
        while IFS= read -r line; do
            say "compiler policy: ${line}"
        done
else
    say "compiler policy helper missing at ${POLICY_HELPER}"
    exit 1
fi

if [ -L "${TRACE_HEADER}" ]; then
    say "trace header is a symbolic link; refusing to stage it"
    exit 1
fi

if [ ! -f "${TRACE_HEADER}" ]; then
    say "trace header not present in DKMS radeon source; nothing to stage"
    exit 0
fi

if [ -L "${KERNEL_HEADERS_RADEON_DIR}/radeon_trace.h" ]; then
    say "kernel trace-header destination is a symbolic link; refusing to stage it"
    exit 1
fi

if [ -f "${KERNEL_HEADERS_RADEON_DIR}/radeon_trace.h" ]; then
    say "kernel headers already provide radeon_trace.h; nothing to stage"
    exit 0
fi

KERNEL_BUILD_ROOT=$(readlink -f -- "${KERNEL_BUILD_ROOT}") ||
    exit 1
protected_directory "${KERNEL_BUILD_ROOT}" || {
    say "kernel build root must be a root-owned, non-writable directory"
    exit 1
}
KERNEL_HEADERS_RADEON_DIR="${KERNEL_BUILD_ROOT}/drivers/gpu/drm/radeon"
directory=${KERNEL_BUILD_ROOT}
for component in drivers gpu drm radeon; do
    directory="${directory}/${component}"
    if [ -L "${directory}" ]; then
        say "kernel trace-header path contains a symbolic link: ${directory}"
        exit 1
    fi
    if [ -e "${directory}" ] && [ ! -d "${directory}" ]; then
        say "kernel trace-header path contains a non-directory: ${directory}"
        exit 1
    fi
    if [ -d "${directory}" ]; then
        protected_directory "${directory}" || {
            say "kernel trace-header path must be root-owned and non-writable"
            exit 1
        }
    else
        mkdir "${directory}"
        protected_directory "${directory}" || {
            say "new kernel trace-header path is not protected"
            exit 1
        }
    fi
done

say "staging radeon_trace.h in kernel-headers path for trace-include resolution"
install -m 0644 "${TRACE_HEADER}" \
    "${KERNEL_HEADERS_RADEON_DIR}/radeon_trace.h"
