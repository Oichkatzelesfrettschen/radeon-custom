#!/bin/sh
# DKMS PRE_BUILD hook for radeon trace include compatibility.

set -eu

LOG_PREFIX="[radeon-rs480-safe-regs pre-build]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

KERNELVER="${1:-${kernelver:-$(uname -r)}}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RADEON_DIR="${SCRIPT_DIR}/radeon"
TRACE_HEADER="${RADEON_DIR}/radeon_trace.h"
KERNEL_BUILD_ROOT="${R300_RS480_KERNEL_BUILD_ROOT:-/lib/modules/${KERNELVER}/build}"
KERNEL_HEADERS_RADEON_DIR="${KERNEL_BUILD_ROOT}/drivers/gpu/drm/radeon"
COMPILE_H="${KERNEL_BUILD_ROOT}/include/generated/compile.h"

say "kernelver=${KERNELVER}"

# Log the compiler that the MAKE line will select so failures are diagnosable.
if grep -q 'clang' "${COMPILE_H}" 2>/dev/null; then
    say "kernel compiler: clang (detected from compile.h); MAKE will use the package-local clang/ccache wrapper"
elif [ -f "${COMPILE_H}" ]; then
    say "kernel compiler: gcc (detected from compile.h); MAKE will use the package-local gcc/ccache wrapper"
else
    say "compile.h not found at ${COMPILE_H}; MAKE will default to the package-local gcc/ccache wrapper"
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
