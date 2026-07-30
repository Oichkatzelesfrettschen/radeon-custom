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
TRACE_SHIM_ROOT="${SCRIPT_DIR}/.radeon-trace-include"
TRACE_SHIM_HEADER="${TRACE_SHIM_ROOT}/drivers/gpu/drm/radeon/radeon_trace.h"
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

stage_trace_header() {
    source_header=$1
    shim_root=$2
    shim_header="${shim_root}/drivers/gpu/drm/radeon/radeon_trace.h"
    directory=$shim_root

    if [ -L "$shim_root" ]; then
        say "trace shim root is a symbolic link"
        return 1
    fi
    if [ -e "$shim_root" ] && [ ! -d "$shim_root" ]; then
        say "trace shim root is not a directory"
        return 1
    fi
    if [ ! -d "$shim_root" ]; then
        mkdir -m 0755 "$shim_root"
    fi
    protected_directory "$shim_root" || {
        say "trace shim root must be root-owned and non-writable"
        return 1
    }

    for component in include trace drivers gpu drm radeon; do
        case "$component" in
            include)
                directory="${shim_root}/include"
                ;;
            trace)
                directory="${shim_root}/include/trace"
                ;;
            drivers)
                directory="${shim_root}/drivers"
                ;;
            *)
                directory="${directory}/${component}"
                ;;
        esac
        if [ -L "$directory" ]; then
            say "trace shim path contains a symbolic link: ${directory}"
            return 1
        fi
        if [ -e "$directory" ] && [ ! -d "$directory" ]; then
            say "trace shim path contains a non-directory: ${directory}"
            return 1
        fi
        if [ ! -d "$directory" ]; then
            mkdir -m 0755 "$directory"
        fi
        protected_directory "$directory" || {
            say "trace shim path must be root-owned and non-writable: ${directory}"
            return 1
        }
    done

    if [ -L "$shim_header" ]; then
        say "trace shim destination is a symbolic link"
        return 1
    fi
    if [ -e "$shim_header" ] && [ ! -f "$shim_header" ]; then
        say "trace shim destination is not a regular file"
        return 1
    fi
    install -m 0644 "$source_header" "$shim_header"
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

KERNEL_BUILD_ROOT=$(readlink -f -- "${KERNEL_BUILD_ROOT}") ||
    exit 1
protected_directory "${KERNEL_BUILD_ROOT}" || {
    say "kernel build root must be a root-owned, non-writable directory"
    exit 1
}

say "staging radeon_trace.h in the private DKMS trace-include shim"
stage_trace_header "${TRACE_HEADER}" "${TRACE_SHIM_ROOT}"
test -f "${TRACE_SHIM_HEADER}"
cmp "${TRACE_HEADER}" "${TRACE_SHIM_HEADER}"
say "private trace-include header matches the module source"
