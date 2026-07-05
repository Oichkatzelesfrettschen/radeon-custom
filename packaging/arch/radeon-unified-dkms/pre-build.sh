#!/bin/sh
# DKMS PRE_BUILD hook for radeon trace include compatibility.

set -eu

LOG_PREFIX="[radeon-unified pre-build]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

KERNELVER="${1:-${kernelver:-$(uname -r)}}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RADEON_DIR="${SCRIPT_DIR}/radeon"
TRACE_HEADER="${RADEON_DIR}/radeon_trace.h"
KERNEL_BUILD_ROOT="${R300_RS480_KERNEL_BUILD_ROOT:-/lib/modules/${KERNELVER}/build}"
KERNEL_HEADERS_RADEON_DIR="${KERNEL_BUILD_ROOT}/drivers/gpu/drm/radeon"
COMPILE_H="${KERNEL_BUILD_ROOT}/include/generated/compile.h"
POLICY_HELPER="${SCRIPT_DIR}/radeon-dkms-compiler-policy"

say "kernelver=${KERNELVER}"

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

if [ ! -f "${TRACE_HEADER}" ]; then
    say "trace header not present in DKMS radeon source; nothing to stage"
    exit 0
fi

if [ -f "${KERNEL_HEADERS_RADEON_DIR}/radeon_trace.h" ]; then
    say "kernel headers already provide radeon_trace.h; nothing to stage"
    exit 0
fi

say "staging radeon_trace.h in kernel-headers path for trace-include resolution"
mkdir -p "${KERNEL_HEADERS_RADEON_DIR}"
cp "${TRACE_HEADER}" "${KERNEL_HEADERS_RADEON_DIR}/radeon_trace.h"
