#!/bin/sh
# PRE_BUILD script invoked by DKMS before MAKE[0].
#
# Stages an applicable radeon driver source tree at ./radeon/ inside
# the DKMS build directory.
#
# Source selection priority:
#   1. ./radeon-source-prepatched.tar.xz inside the DKMS package
#      (this is the canonical, patches-already-applied source tree
#      pinned to a known-good 6.18.x base; ships with the package)
#   2. fallback: /usr/src/linux-source-${MAJ}.${MIN}.tar.xz (Debian
#      canonical, requires re-applying the patches/ series; only
#      tried if (1) is missing for whatever reason)
#
# The embedded tarball is the reliable path; patches are kept in
# patches/ for documentation and review but are NOT applied here.

set -eu

LOG_PREFIX="[radeon-palm-gate prep-source]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }

KERNELVER="${1:-${kernelver:-$(uname -r)}}"
MAJMIN="$(printf '%s' "$KERNELVER" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"

DKMS_BUILD_DIR="$(pwd)"
WORK_DIR="${DKMS_BUILD_DIR}/work"
RADEON_DIR="${DKMS_BUILD_DIR}/radeon"

EMBEDDED_TARBALL="${DKMS_BUILD_DIR}/radeon-source-prepatched.tar.xz"
DEBIAN_TARBALL="/usr/src/linux-source-${MAJMIN}.tar.xz"
DEBIAN_SUBDIR="linux-source-${MAJMIN}"
PATCH_DIR="${DKMS_BUILD_DIR}/patches"

say "kernelver=${KERNELVER}  majmin=${MAJMIN}  build-dir=${DKMS_BUILD_DIR}"

# Always start from a fresh radeon/ so partial state never carries over.
rm -rf "${RADEON_DIR}" "${WORK_DIR}"

# Source selection.
if [ -f "${EMBEDDED_TARBALL}" ]; then
    say "source: embedded ${EMBEDDED_TARBALL} (pre-patched)"
    mkdir -p "${RADEON_DIR}"
    tar -xJf "${EMBEDDED_TARBALL}" -C "${RADEON_DIR}"
elif [ -f "${DEBIAN_TARBALL}" ]; then
    say "source: ${DEBIAN_TARBALL} (Debian; will apply patches/)"
    mkdir -p "${WORK_DIR}"
    tar -xJf "${DEBIAN_TARBALL}" -C "${WORK_DIR}" \
        "${DEBIAN_SUBDIR}/drivers/gpu/drm/radeon"
    cp -a "${WORK_DIR}/${DEBIAN_SUBDIR}/drivers/gpu/drm/radeon" \
        "${RADEON_DIR}"
    say "applying patches/*.patch"
    for patch in "${PATCH_DIR}"/*.patch; do
        [ -f "${patch}" ] || continue
        say "  $(basename "${patch}")"
        patch -d "${RADEON_DIR}" -p5 -N --no-backup-if-mismatch \
            <"${patch}" || {
            echo "${LOG_PREFIX} patch failed: ${patch}" >&2
            exit 1
        }
    done

    # W9.k: one-line append to reg_srcs/evergreen (only needed on the
    # Debian fallback path; the embedded tarball already has this).
    REG_SRC="${RADEON_DIR}/reg_srcs/evergreen"
    if [ -f "${REG_SRC}" ] &&
        ! grep -q "^0x0000A020 SMX_DC_CTL0$" "${REG_SRC}"; then
        say "W9.k: inserting 0x0000A020 SMX_DC_CTL0 after DB_WATERMARKS"
        awk '
            /^0x00009854 DB_WATERMARKS/ {
                print
                print "0x0000A020 SMX_DC_CTL0"
                next
            }
            { print }
        ' "${REG_SRC}" >"${REG_SRC}.tmp"
        mv "${REG_SRC}.tmp" "${REG_SRC}"
        rm -f "${RADEON_DIR}/evergreen_reg_safe.h"
    fi
else
    cat <<EOF >&2
${LOG_PREFIX} ERROR: no radeon source available for ${KERNELVER}

Checked:
  1) ${EMBEDDED_TARBALL}
  2) ${DEBIAN_TARBALL}

The embedded pre-patched tarball is the canonical source and should
have shipped with this DKMS package.  If it is missing, regenerate
via tools/build-embedded-tarball.sh on a host with a known-good
patched radeon tree.

Alternatively, install Debian's linux-source-${MAJMIN} package and
the patches/ series will be applied to a fresh extraction.
EOF
    exit 1
fi

# perf_query_ioctl: stage perf-query ioctl handler + whitelist header.
# The perf_query_ioctl patch (0005-add-perf-query-ioctl.patch) adds two new
# translation units that did not exist in the embedded prepatched tarball.
# The current sed-based wire-up for the radeon.h prototype is fragile
# (the parallel `a` command inserts into the middle of
# radeon_gem_userptr_ioctl's split-line signature, breaking C syntax).
# Until the wire-up is reworked as a proper unified-diff patch, gate the
# whole perf_query_ioctl staging behind an opt-in env var.  Default OFF
# preserves the canonical bounded-mc-wait + smx_dc_ctl0 DKMS build.
USE_PERF_QUERY="${RADEON_PALM_GATE_PERF_QUERY:-0}"
PERF_QUERY_SRC_DIR="${DKMS_BUILD_DIR}/perf-query-sources"
if [ "${USE_PERF_QUERY}" = "1" ] && [ -d "${PERF_QUERY_SRC_DIR}" ]; then
    say "perf_query_ioctl: staging radeon_perf_query.c + perf_register_whitelist.h"
    cp "${PERF_QUERY_SRC_DIR}/radeon_perf_query.c" "${RADEON_DIR}/radeon_perf_query.c"
    cp "${PERF_QUERY_SRC_DIR}/perf_register_whitelist.h" \
        "${RADEON_DIR}/perf_register_whitelist.h"

    # Wire the new TU into the radeon Makefile (idempotent grep gate).
    if ! grep -q "radeon_perf_query.o" "${RADEON_DIR}/Makefile"; then
        say "perf_query_ioctl: adding radeon_perf_query.o to radeon-y"
        sed -i '/radeon_pm.o/i\	radeon_perf_query.o \\' "${RADEON_DIR}/Makefile"
    fi

    # Wire the ioctl handler into radeon_ioctls_kms[].
    if ! grep -q "RADEON_PERF_QUERY" "${RADEON_DIR}/radeon_drv.c"; then
        say "perf_query_ioctl: appending DRM_IOCTL_DEF_DRV(RADEON_PERF_QUERY) to radeon_drv.c"
        sed -i '/DRM_IOCTL_DEF_DRV(RADEON_GEM_USERPTR/a\	DRM_IOCTL_DEF_DRV(RADEON_PERF_QUERY, radeon_perf_query_ioctl, DRM_AUTH|DRM_RENDER_ALLOW),' \
            "${RADEON_DIR}/radeon_drv.c"
    fi

    # Prototype in radeon.h.
    if ! grep -q "radeon_perf_query_ioctl" "${RADEON_DIR}/radeon.h"; then
        say "perf_query_ioctl: declaring radeon_perf_query_ioctl in radeon.h"
        sed -i '/radeon_gem_userptr_ioctl(struct drm_device/a\\nint radeon_perf_query_ioctl(struct drm_device *dev, void *data, struct drm_file *filp);' \
            "${RADEON_DIR}/radeon.h"
    fi

    # uAPI: the DRM ioctl number + struct.  Patch a copy of radeon_drm.h
    # that lives inside the embedded source tree; the DKMS build picks
    # it up via -I against the radeon/ subdir if the uAPI is shadowed,
    # otherwise the running kernel-headers must carry the same edit.
    UAPI_HEADER="${RADEON_DIR}/radeon_drm.h"
    if [ -f "${UAPI_HEADER}" ] &&
        ! grep -q "DRM_RADEON_PERF_QUERY" "${UAPI_HEADER}"; then
        say "perf_query_ioctl: adding DRM_RADEON_PERF_QUERY to local radeon_drm.h"
        sed -i '/DRM_RADEON_GEM_USERPTR.*0x2d/a\#define DRM_RADEON_PERF_QUERY\t\t0x2e' \
            "${UAPI_HEADER}"
        cat >>"${UAPI_HEADER}" <<'EOF_PERF_QUERY_UAPI'

/* radeon_perf_query_ioctl ABI (see steinmarder src/re/r300/docs/
 * radeon_perf_query_ioctl for the RFC and register whitelist). */
#ifndef RADEON_PERF_QUERY_HOLD_SCLK
#define RADEON_PERF_QUERY_HOLD_SCLK     (1u << 0)
#define RADEON_PERF_QUERY_SE0_ONLY      (1u << 1)
struct drm_radeon_perf_query {
    __u32 version;
    __u32 flags;
    __u32 reg_count;
    __u32 _pad;
    __u64 regs_ptr;
    __u64 values_ptr;
    __u64 reserved[2];
};
#define DRM_IOCTL_RADEON_PERF_QUERY \
    DRM_IOWR(DRM_COMMAND_BASE + DRM_RADEON_PERF_QUERY, struct drm_radeon_perf_query)
#endif
EOF_PERF_QUERY_UAPI
    fi
fi

# palm_cs_observer: stage radeon-palm-gate CS observer skeleton.
# The palm_cs_observer patch (0006-cs-observer-skeleton.patch) adds a
# read-only, disabled-by-default Command-Stream observer translation
# unit co-located with the radeon module.  Skeleton scope only: module
# init/exit, debugfs root creation, module-param decls, no-op-when-
# disabled emit stubs.  Subsequent palm_cs_observer patches add per-event payload
# + comm filter + JSONL emission + hook callsites in radeon_cs.c /
# evergreen_cs.c.  Default stage-OFF: set RADEON_PALM_GATE_OBSERVER=1 to
# stage the new TU; the kernel module still defaults to
# palm_cs_observer=0 even when staged.
USE_OBSERVER="${RADEON_PALM_GATE_OBSERVER:-0}"
STEINMARDER_EXT_SRC_DIR="${DKMS_BUILD_DIR}/radeon-steinmarder-ext-sources"
OBSERVER_SRC_DIR="${DKMS_BUILD_DIR}/palm-cs-observer-sources"
if [ "${USE_OBSERVER}" = "1" ] && [ -d "${STEINMARDER_EXT_SRC_DIR}" ]; then
    say "radeon_steinmarder_ext: staging unified radeon extension"
    cp "${STEINMARDER_EXT_SRC_DIR}/radeon_steinmarder_ext.c" \
        "${RADEON_DIR}/radeon_steinmarder_ext.c"
    cp "${STEINMARDER_EXT_SRC_DIR}/radeon_steinmarder_ext.h" \
        "${RADEON_DIR}/radeon_steinmarder_ext.h"

    if ! grep -q "radeon_steinmarder_ext.o" "${RADEON_DIR}/Makefile"; then
        say "radeon_steinmarder_ext: adding radeon_steinmarder_ext.o to radeon-y"
        sed -i '/radeon_pm.o/i\	radeon_steinmarder_ext.o \\' "${RADEON_DIR}/Makefile"
    fi

    if ! grep -q "radeon_steinmarder_ext_init" "${RADEON_DIR}/radeon_kms.c"; then
        say "radeon_steinmarder_ext: wiring device lifecycle into radeon_kms.c"
        sed -i \
            -e '/^#include "radeon.h"/a\#include "radeon_steinmarder_ext.h"' \
            "${RADEON_DIR}/radeon_kms.c"
        sed -i \
            -e '/Again modeset_init/i\
\	(void)radeon_steinmarder_ext_init(rdev);' \
            -e '/radeon_device_fini(rdev);/i\
\	radeon_steinmarder_ext_cleanup(rdev);' \
            "${RADEON_DIR}/radeon_kms.c"
        grep -q "radeon_steinmarder_ext_init(rdev)" "${RADEON_DIR}/radeon_kms.c" || {
            echo "${LOG_PREFIX} failed to wire radeon_steinmarder_ext_init in radeon_kms.c" >&2
            exit 1
        }
        grep -q "radeon_steinmarder_ext_cleanup(rdev)" "${RADEON_DIR}/radeon_kms.c" || {
            echo "${LOG_PREFIX} failed to wire radeon_steinmarder_ext_cleanup in radeon_kms.c" >&2
            exit 1
        }
    fi

    if ! grep -q "radeon_steinmarder_ext_cs_ioctl_entry" \
        "${RADEON_DIR}/radeon_cs.c"; then
        say "radeon_steinmarder_ext: wiring cs_ioctl_entry hook into radeon_cs.c"
        awk '
            /^#include "radeon.h"/ && !inc_done {
                print
                print "#include \"radeon_steinmarder_ext.h\""
                inc_done = 1
                next
            }
            /^int radeon_cs_ioctl\(/ { in_func = 1; print; next }
            in_func && /^\{/ {
                print
                print "\tradeon_steinmarder_ext_cs_ioctl_entry(data);"
                in_func = 0
                next
            }
            { print }
        ' "${RADEON_DIR}/radeon_cs.c" >"${RADEON_DIR}/radeon_cs.c.tmp"
        mv "${RADEON_DIR}/radeon_cs.c.tmp" "${RADEON_DIR}/radeon_cs.c"
    fi

    if ! grep -q "radeon_steinmarder_ext_ib_chunk_pre_parse" \
        "${RADEON_DIR}/radeon_cs.c"; then
        say "radeon_steinmarder_ext: wiring ib_chunk_pre_parse hook into radeon_cs.c"
        sed -i '/r = radeon_cs_parser_relocs/i\
\tradeon_steinmarder_ext_ib_chunk_pre_parse(\&parser);' \
            "${RADEON_DIR}/radeon_cs.c"
    fi

    if ! grep -q "radeon_steinmarder_ext_ib_post_validate" \
        "${RADEON_DIR}/radeon_cs.c"; then
        say "radeon_steinmarder_ext: wiring ib_post_validate hook into radeon_cs.c"
        sed -i 's/^\([[:space:]]*\)radeon_cs_parser_fini(&parser/\1radeon_steinmarder_ext_ib_post_validate(\&parser);\n\1radeon_cs_parser_fini(\&parser/g' \
            "${RADEON_DIR}/radeon_cs.c"
    fi
elif [ "${USE_OBSERVER}" = "1" ] && [ -d "${OBSERVER_SRC_DIR}" ]; then
    say "palm_cs_observer: staging radeon_palm_cs_observer.c + radeon_palm_cs_observer.h"
    cp "${OBSERVER_SRC_DIR}/radeon_palm_cs_observer.c" \
        "${RADEON_DIR}/radeon_palm_cs_observer.c"
    cp "${OBSERVER_SRC_DIR}/radeon_palm_cs_observer.h" \
        "${RADEON_DIR}/radeon_palm_cs_observer.h"

    # Wire the new TU into the radeon Makefile (idempotent grep gate).
    if ! grep -q "radeon_palm_cs_observer.o" "${RADEON_DIR}/Makefile"; then
        say "palm_cs_observer: adding radeon_palm_cs_observer.o to radeon-y"
        sed -i '/radeon_pm.o/i\	radeon_palm_cs_observer.o \\' "${RADEON_DIR}/Makefile"
    fi

    # Wire the init/cleanup calls into radeon_drv.c (idempotent grep
    # gate).  An earlier draft used `/return ret;/i\...` as the
    # init-insertion landmark, but radeon_init's success path
    # returns `0` (or `r`) -- not `ret` -- so the sed substitution
    # was a no-op in practice and the observer never got
    # initialized (the cleanup hook ran but found nothing to
    # tear down).  Use a wider regex that matches any of the
    # canonical return-statements at function tail, AND fall back
    # to inserting before the function's closing `}` if no return
    # landmark matched.
    if ! grep -q "radeon_palm_cs_observer_init" "${RADEON_DIR}/radeon_drv.c"; then
        say "palm_cs_observer: wiring radeon_palm_cs_observer_init / _cleanup into radeon_drv.c"
        # Step 1: include header (idempotent: grep gate above).
        sed -i \
            -e '/^#include "radeon.h"/a\#include "radeon_palm_cs_observer.h"' \
            "${RADEON_DIR}/radeon_drv.c"
        # Step 2: insert observer_init via awk.  Tracks the last
        # `return <0|r|ret>;` inside radeon_init and inserts the
        # observer call immediately before it.  If radeon_init has
        # no return at all (unlikely; degenerate), the function's
        # closing `}` is the fallback insertion point.
        awk '
            /^static int __init radeon_init/ {
                in_func = 1
                depth = 0
                last_return = ""
                buf_count = 0
                seen_open_brace = 0
            }
            in_func {
                lines[buf_count++] = $0
                if ($0 ~ /^[[:space:]]*return[[:space:]]+(0|r|ret)[[:space:]]*;[[:space:]]*$/) {
                    last_return = buf_count - 1
                }
                open_count = gsub(/\{/, "{")
                close_count = gsub(/\}/, "}")
                if (open_count > 0)
                    seen_open_brace = 1
                depth += open_count - close_count
                if (seen_open_brace && close_count > 0 && depth == 0) {
                    if (last_return != "") {
                        for (j = 0; j < buf_count; j++) {
                            if (j == last_return) {
                                print "\t(void)radeon_palm_cs_observer_init();"
                            }
                            print lines[j]
                        }
                    } else {
                        for (j = 0; j < buf_count - 1; j++)
                            print lines[j]
                        print "\t(void)radeon_palm_cs_observer_init();"
                        print lines[buf_count - 1]
                    }
                    in_func = 0
                    next
                }
                next
            }
            { print }
        ' "${RADEON_DIR}/radeon_drv.c" >"${RADEON_DIR}/radeon_drv.c.tmp"
        mv "${RADEON_DIR}/radeon_drv.c.tmp" "${RADEON_DIR}/radeon_drv.c"
        # Step 3: insert observer_cleanup before platform_driver_
        # unregister in radeon_exit (single occurrence; safe sed).
        sed -i \
            -e '/^static void __exit radeon_exit/,/^}/{
                /platform_driver_unregister/i\
\	radeon_palm_cs_observer_cleanup();
            }' \
            "${RADEON_DIR}/radeon_drv.c"
    fi

    # Wire the cs_ioctl_entry hook into radeon_cs.c.  awk is used here
    # (not sed) because the insertion has to land AFTER the function's
    # body-open brace, which can be 1 or 2 lines after the signature
    # depending on radeon_cs.c's formatting.  Idempotent grep gate.
    if ! grep -q "radeon_palm_cs_observer_emit_cs_ioctl_entry" \
        "${RADEON_DIR}/radeon_cs.c"; then
        say "palm_cs_observer: wiring cs_ioctl_entry hook into radeon_cs.c"
        awk '
            /^#include "radeon.h"/ && !inc_done {
                print
                print "#include \"radeon_palm_cs_observer.h\""
                inc_done = 1
                next
            }
            /^int radeon_cs_ioctl\(/ { in_func = 1; print; next }
            in_func && /^\{/ {
                print
                print "\tradeon_palm_cs_observer_emit_cs_ioctl_entry(data);"
                in_func = 0
                next
            }
            { print }
        ' "${RADEON_DIR}/radeon_cs.c" >"${RADEON_DIR}/radeon_cs.c.tmp"
        mv "${RADEON_DIR}/radeon_cs.c.tmp" "${RADEON_DIR}/radeon_cs.c"
    fi

    # Wire the ib_chunk_pre_parse hook into radeon_cs.c.  Insertion
    # lands AFTER the radeon_cs_parser_init success-path return so
    # parser->chunks[] is fully populated and copy_from_user'd.  The
    # safest landmark is the first call site of radeon_cs_parser_init
    # in radeon_cs_ioctl; we insert the hook immediately after the
    # `if (r) { ... return r; }` block that follows that call.
    #
    # Because the post-parser_init success-path is harder to pin down
    # uniquely, we use the call site of radeon_cs_parser_relocs as
    # the landmark (it is called once per CS, AFTER parser_init is
    # known to have succeeded).  The hook line lands BEFORE that
    # call so parser->chunks is fully present.
    if ! grep -q "radeon_palm_cs_observer_emit_ib_chunk_pre_parse" \
        "${RADEON_DIR}/radeon_cs.c"; then
        say "palm_cs_observer: wiring ib_chunk_pre_parse hook into radeon_cs.c"
        sed -i '/r = radeon_cs_parser_relocs/i\
\tradeon_palm_cs_observer_emit_ib_chunk_pre_parse(\&parser);' \
            "${RADEON_DIR}/radeon_cs.c"
    fi

    # Wire the ib_post_validate hook into radeon_cs.c.  This hook
    # absorbs the originally-planned packet_decode hook: both
    # event classes emit from a single post-validator walk of the
    # IB chunk (see radeon_palm_cs_observer_emit_ib_post_validate
    # body).  Insertion lands BEFORE every radeon_cs_parser_fini
    # call site -- the validator has run to completion by then
    # regardless of success or error path, so the IB bytes the
    # observer walks are the same bytes the GPU would have
    # executed (success) or the validator rejected (error).  Both
    # readings are informative.  Idempotent grep gate.
    if ! grep -q "radeon_palm_cs_observer_emit_ib_post_validate" \
        "${RADEON_DIR}/radeon_cs.c"; then
        say "palm_cs_observer: wiring ib_post_validate hook into radeon_cs.c"
        sed -i 's/^\([[:space:]]*\)radeon_cs_parser_fini(&parser/\1radeon_palm_cs_observer_emit_ib_post_validate(\&parser);\n\1radeon_cs_parser_fini(\&parser/g' \
            "${RADEON_DIR}/radeon_cs.c"
    fi
fi

# radeon_trace.h: out-of-tree trace-include path workaround.
# When building out-of-tree against a kernel-headers package that does
# NOT ship drivers/gpu/drm/radeon/ (xanmod 6.18.30+ behaviour), the
# trace-include path embedded in radeon_trace.h
# (TRACE_INCLUDE_PATH ../../drivers/gpu/drm/radeon) fails because the
# headers tree has no such subtree.  Stage radeon_trace.h at the path
# the resolver looks for, inside the kernel-headers tree itself.
# DKMS runs PRE_BUILD as root so no sudo is required.
TRACE_HEADER="${RADEON_DIR}/radeon_trace.h"
KERNEL_HEADERS_RADEON_DIR="/lib/modules/${KERNELVER}/build/drivers/gpu/drm/radeon"
if [ -f "${TRACE_HEADER}" ] && [ ! -f "${KERNEL_HEADERS_RADEON_DIR}/radeon_trace.h" ]; then
    say "staging radeon_trace.h in kernel-headers path for trace-include resolution"
    mkdir -p "${KERNEL_HEADERS_RADEON_DIR}"
    cp "${TRACE_HEADER}" "${KERNEL_HEADERS_RADEON_DIR}/radeon_trace.h"
fi

# Generate MAKE.sh: distcc-aware build wrapper.
# dkms.conf::MAKE[0] is `sh ${dkms_tree}/.../build/MAKE.sh ${kernelver}`.
# We emit a concrete shell script here so the build environment
# (DISTCC_HOSTS, CC, parallelism) is captured at prep-time and
# survives whatever env scrubbing dkms_autoinstaller does between
# PRE_BUILD and MAKE.
#
# Canonical toolchain on x130e is clang-22 + ld.lld-22 (matches
# mesa-26-gororoba's distcc setup; the kernel itself was built
# with clang-19 but that mismatch is cosmetic because
# CONFIG_MODVERSIONS is off on this kernel and vermagic does not
# include the compiler version).  Override via
# RADEON_PALM_GATE_CLANG_VERSION=19 in the build env if the
# resulting module fails to load or modpost rejects.
#
# Distcc daemons probed by hostname + TCP port 3632.  Unreachable
# hosts from the selected profile get dropped from DISTCC_HOSTS so the
# build falls back to whatever is alive (always includes localhost).
CLANG_VER="${RADEON_PALM_GATE_CLANG_VERSION:-22}"
user_home=$(cd && pwd -P)
DISTCC_HOSTS_FILE="${RADEON_PALM_GATE_DISTCC_HOSTS_FILE:-${user_home}/.distcc/hosts.clang22-latest}"
DISTCC_BIN="$(command -v distcc 2>/dev/null)"
CLANG_BIN="$(command -v clang-${CLANG_VER} 2>/dev/null)"
LD_BIN="$(command -v ld.lld-${CLANG_VER} 2>/dev/null)"
if [ -z "${CLANG_BIN}" ] && [ "${CLANG_VER}" != "19" ]; then
    say "clang-${CLANG_VER} not found; falling back to clang-19"
    CLANG_VER=19
    CLANG_BIN="$(command -v clang-19 2>/dev/null)"
    LD_BIN="$(command -v ld.lld-19 2>/dev/null)"
fi

probe_distcc_host() {
    # $1: host[/slots[,opts]]
    h="${1%%[/,]*}"
    nc -z -w 2 "${h}" 3632 >/dev/null 2>&1
}

MAKE_WRAPPER="${DKMS_BUILD_DIR}/MAKE.sh"
LOCAL_JOBS="$(nproc 2>/dev/null || echo 2)"

# Distcc parallelism is gated by local preprocessing capacity unless
# pump mode is used.  On the 2-core Bobcat in x130e, plain distcc with
# -j(sum-of-slots) thrashes badly: ~50 parallel local clang -E
# instances make the run slower than -j2 local-only.
#
# Default: plain distcc with -j(LOCAL_JOBS * 4) so the local
# preprocessor queue stays drainable.  Robust for kernel-module
# builds where pump's include-server can stall on the deep kernel
# header tree.
#
# Opt-in: set RADEON_PALM_GATE_PUMP=1 to enable distcc-pump.  Pump
# ships the preprocessing step to remote daemons (cpp option in
# DISTCC_HOSTS) so high -j is safe.  Empirically slow to initialise
# on Bobcat for kernel-module builds; the mesa userspace builds
# use it successfully.
USE_PUMP="${RADEON_PALM_GATE_PUMP:-0}"
PUMP_BIN="$(command -v distcc-pump 2>/dev/null)"

if [ -n "${DISTCC_BIN}" ] && [ -n "${CLANG_BIN}" ]; then
    say "probing distcc mesh"
    hosts=""
    remote_slots=0
    remote_specs=""
    if [ -r "${DISTCC_HOSTS_FILE}" ]; then
        say "distcc hosts profile: ${DISTCC_HOSTS_FILE}"
        for token in $(tr '[:space:]' '\n' <"${DISTCC_HOSTS_FILE}"); do
            case "${token}" in
                "" | "#"* | --*) continue ;;
                */*) ;;
                *) continue ;;
            esac
            host_slots="${token%%,*}"
            host="${host_slots%/*}"
            slots="${host_slots#*/}"
            case "${slots}" in
                *[!0-9]* | "") continue ;;
            esac
            remote_specs="${remote_specs} ${host}/${slots}"
        done
    else
        say "distcc hosts profile not readable: ${DISTCC_HOSTS_FILE}"
    fi
    if [ "${USE_PUMP}" = "1" ] && [ -n "${PUMP_BIN}" ]; then
        HOST_OPTS_BASE="cpp,lzo"
    else
        HOST_OPTS_BASE="lzo"
    fi
    for spec in ${remote_specs}; do
        host="${spec%/*}"
        slots="${spec#*/}"
        if probe_distcc_host "${host}"; then
            hosts="${hosts} ${host}/${slots},${HOST_OPTS_BASE}"
            remote_slots=$((remote_slots + slots))
            say "  reachable: ${host} (${slots} slots)"
        else
            say "  unreachable: ${host}"
        fi
    done
    hosts="${hosts} localhost/${LOCAL_JOBS},lzo"
    DISTCC_HOSTS_VAL="--randomize ${hosts# }"
    CC_VAL="distcc clang-${CLANG_VER}"
    if [ "${USE_PUMP}" = "1" ] && [ -n "${PUMP_BIN}" ] && [ "${remote_slots}" -gt 0 ]; then
        # Pump mode: high parallelism is safe because the preprocess
        # step is shipped remote.  Opt-in only (kernel-module builds
        # sometimes stall in include-server analysis on Bobcat).
        JOBS_VAL=$((remote_slots + LOCAL_JOBS))
        MAKE_DRIVER="${PUMP_BIN} make"
        say "distcc PUMP mode: -j${JOBS_VAL} (cpp+compile on remotes)  clang-${CLANG_VER}"
    else
        # Default: plain distcc with -j capped at 4 * local cores.
        # Local preprocessing is the bottleneck; ~4 in-flight per
        # core keeps the queue drainable without thrashing.
        JOBS_VAL=$((LOCAL_JOBS * 4))
        MAKE_DRIVER="make"
        say "distcc plain mode: -j${JOBS_VAL} (cpp local-bound)  clang-${CLANG_VER}"
    fi
    say "  DISTCC_HOSTS='${DISTCC_HOSTS_VAL}'"
else
    say "distcc not available; local build only (clang-${CLANG_VER})"
    DISTCC_HOSTS_VAL=""
    CC_VAL="clang-${CLANG_VER}"
    JOBS_VAL="${LOCAL_JOBS}"
    MAKE_DRIVER="make"
fi

cat >"${MAKE_WRAPPER}" <<EOF
#!/bin/sh
# Generated by prep-source.sh -- do not edit by hand.
# dkms.conf::MAKE[0] invokes this with one argument: the kernel
# version.  We add distcc env + parallelism + clang/ld overrides
# that survive whatever env scrubbing dkms_autoinstaller does.
set -eu
KERNELVER="\$1"
export DISTCC_HOSTS='${DISTCC_HOSTS_VAL}'
exec ${MAKE_DRIVER} -C /lib/modules/\${KERNELVER}/build \\
    M=${DKMS_BUILD_DIR}/radeon \\
    CC='${CC_VAL}' \\
    LD='${LD_BIN:-ld.lld-${CLANG_VER}}' \\
    -j${JOBS_VAL} \\
    modules
EOF
chmod +x "${MAKE_WRAPPER}"
say "generated MAKE wrapper: ${MAKE_WRAPPER}"

say "prep-source complete; ${RADEON_DIR}/ ready for MAKE"
