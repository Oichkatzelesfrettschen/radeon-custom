#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/src/re/radeon/packaging/arch/radeon-unified-dkms"
pkgbuild="$package_dir/PKGBUILD"
dkms_conf="$package_dir/dkms.conf"

die() {
    printf 'verify_radeon_unified_dkms_package: %s\n' "$*" >&2
    exit 1
}

hash_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

startdir="$package_dir"
source "$pkgbuild"
kernelver=0
dkms_tree=/tmp/radeon-unified-dkms-verify
source "$dkms_conf"

pkg_glob="$package_dir/${pkgname}-${pkgver}-${pkgrel}-*.pkg.tar*"
pkg_path=${1:-}
if [ -z "$pkg_path" ]; then
    pkg_path=$(find "$package_dir" -maxdepth 1 -type f \
        \( -name "${pkgname}-${pkgver}-${pkgrel}-*.pkg.tar.zst" -o \
        -name "${pkgname}-${pkgver}-${pkgrel}-*.pkg.tar.xz" \) | sort | tail -n 1)
fi
[ -n "$pkg_path" ] || die "no built package found matching ${pkg_glob##*/}"
[ -r "$pkg_path" ] || die "package not readable: $pkg_path"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
manifest="$tmpdir/package_manifest.txt"
bsdtar -tf "$pkg_path" | sed 's#^\./##' >"$manifest"

failures=0
check_member() {
    local canonical_path=$1
    local archive_path=$2
    local label=$3
    local extracted_path="$tmpdir/$label"

    if ! grep -Fxq -- "$archive_path" "$manifest"; then
        printf '%s: missing archive member\n' "$label" >&2
        printf '  package:  %s\n' "$pkg_path" >&2
        printf '  archive:  %s\n' "$archive_path" >&2
        failures=$((failures + 1))
        return
    fi

    bsdtar -xOf "$pkg_path" "$archive_path" >"$extracted_path"
    expected=$(hash_file "$canonical_path")
    actual=$(hash_file "$extracted_path")
    if [ "$actual" != "$expected" ]; then
        printf '%s: built package payload differs from canonical input\n' "$label" >&2
        printf '  expected: %s\n' "$expected" >&2
        printf '  actual:   %s\n' "$actual" >&2
        printf '  archive:  %s\n' "$archive_path" >&2
        printf '  source:   %s\n' "$canonical_path" >&2
        failures=$((failures + 1))
    fi
}

dkms_root="usr/src/radeon-unified-${pkgver}"
check_member \
    "$package_dir/radeon-re.conf" \
    "etc/modprobe.d/radeon-re.conf" \
    "radeon-re.conf"
check_member \
    "$package_dir/radeon-unified-mkinitcpio.conf" \
    "etc/mkinitcpio.conf.d/radeon-unified.conf" \
    "radeon-unified-mkinitcpio.conf"
check_member \
    "$package_dir/dkms.conf" \
    "${dkms_root}/dkms.conf" \
    "dkms.conf"
check_member \
    "$package_dir/pre-build.sh" \
    "${dkms_root}/pre-build.sh" \
    "pre-build.sh"
check_member \
    "$package_dir/compiler-policy.conf" \
    "${dkms_root}/compiler-policy.conf" \
    "compiler-policy.conf"
check_member \
    "$package_dir/radeon-dkms-compiler-policy" \
    "${dkms_root}/radeon-dkms-compiler-policy" \
    "radeon-dkms-compiler-policy"
check_member \
    "$package_dir/radeon-dkms-compiler" \
    "${dkms_root}/radeon-dkms-compiler" \
    "radeon-dkms-compiler"
check_member \
    "$package_dir/radeon-dkms-ccache-gcc" \
    "${dkms_root}/radeon-dkms-ccache-gcc" \
    "radeon-dkms-ccache-gcc"
check_member \
    "$package_dir/radeon-dkms-ccache-clang" \
    "${dkms_root}/radeon-dkms-ccache-clang" \
    "radeon-dkms-ccache-clang"
check_member \
    "$repo_root/src/re/radeon/patches/rs480/SAFE_REGS.tsv" \
    "${dkms_root}/SAFE_REGS.tsv" \
    "SAFE_REGS.tsv"
check_member \
    "$repo_root/src/re/radeon/patches/rs480/CANDIDATE_REGS.tsv" \
    "${dkms_root}/CANDIDATE_REGS.tsv" \
    "CANDIDATE_REGS.tsv"
check_member \
    "$repo_root/src/re/radeon/patches/rs480/0001-rs480-safe-regs-debugfs.patch" \
    "${dkms_root}/patches/0001-radeon-rs480-safe-regs-debugfs.patch" \
    "0001-rs480-safe-regs-debugfs.patch"
for patch_name in "${PATCH[@]}"; do
    check_member \
        "$repo_root/src/re/radeon/patches/rs480/$patch_name" \
        "${dkms_root}/patches/$patch_name" \
        "$patch_name"
done

[ "$failures" -eq 0 ] || exit 1
printf 'radeon unified DKMS package artifacts: ok (%s)\n' "$pkg_path"
