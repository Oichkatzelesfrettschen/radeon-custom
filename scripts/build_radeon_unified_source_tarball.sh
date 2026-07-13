#!/bin/sh
# Build the canonical Radeon DKMS source tarball from the retained
# RS480/Palm-safe source snapshot.

set -eu

usage() {
    cat <<'EOF'
usage: build_radeon_unified_source_tarball.sh [--check]

Generates:
  sources/radeon-unified-0.3-source.tar.xz

The generated source starts from the RS480/CachyOS superset snapshot,
removes patch-backup artifacts, normalizes permissions, and writes a
deterministic tarball for DKMS packaging adapters.

Options:
  --check  verify that the generated tarball is up to date
EOF
}

CHECK=0
case "${1:-}" in
    "")
        ;;
    --check)
        CHECK=1
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RADEON_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
SOURCE_TARBALL="${RADEON_ROOT}/sources/radeon-rs480-cachyos-6.18-7.0-prepatched.tar.xz"
OUTPUT_TARBALL="${RADEON_ROOT}/sources/radeon-unified-0.3-source.tar.xz"

if [ ! -f "${SOURCE_TARBALL}" ]; then
    echo "missing source tarball: ${SOURCE_TARBALL}" >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
cleanup() {
    rm -rf "${TMPDIR}"
}
trap cleanup EXIT HUP INT TERM

WORK="${TMPDIR}/radeon"
mkdir -p "${WORK}"
tar -xJf "${SOURCE_TARBALL}" -C "${WORK}"

# Patch backup files are not source-of-truth and can create package file
# conflicts on upgrades.  Kernel-generated headers and mkregtable remain.
find "${WORK}" -type f \( \
    -name '*.orig' -o \
    -name '*.rej' -o \
    -name '*.bak' -o \
    -name '*.bak.*' \
    \) -delete

find "${WORK}" -type d -exec chmod 0755 {} +
find "${WORK}" -type f -exec chmod 0644 {} +
if [ -f "${WORK}/mkregtable" ]; then
    chmod 0755 "${WORK}/mkregtable"
fi

GENERATED="${TMPDIR}/radeon-unified-0.3-source.tar.xz"
(
    cd "${WORK}"
    LC_ALL=C tar --sort=name \
        --owner=0 --group=0 --numeric-owner \
        --mtime='UTC 2026-05-23' \
        -cJf "${GENERATED}" .
)

if [ "${CHECK}" -eq 1 ]; then
    if cmp -s "${GENERATED}" "${OUTPUT_TARBALL}"; then
        exit 0
    fi
    echo "generated tarball is out of date: ${OUTPUT_TARBALL}" >&2
    exit 1
fi

install -m 0644 "${GENERATED}" "${OUTPUT_TARBALL}"
sha256sum "${OUTPUT_TARBALL}"
