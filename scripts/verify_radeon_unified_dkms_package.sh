#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
pkgbuild="$package_dir/PKGBUILD"
dkms_conf="$package_dir/dkms.conf"

die() {
    printf 'verify_radeon_unified_dkms_package: %s\n' "$*" >&2
    exit 1
}

hash_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

# shellcheck disable=SC2034
startdir="$package_dir"
# shellcheck source=/dev/null
source "$pkgbuild"
# shellcheck disable=SC2034
kernelver=0
# shellcheck disable=SC2034
dkms_tree=/tmp/radeon-unified-dkms-verify
# shellcheck source=/dev/null
source "$dkms_conf"

# shellcheck disable=SC2154
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
extracted_root="$tmpdir/extracted"
mkdir "$extracted_root"
bsdtar -tf "$pkg_path" | sed 's#^\./##' >"$manifest"
bsdtar -xf "$pkg_path" -C "$extracted_root"

failures=0
check_member() {
    local canonical_path=$1
    local archive_path=$2
    local label=$3
    local expected_mode=${4:-644}
    local extracted_path="$extracted_root/$archive_path"
    local actual_mode

    if ! grep -Fxq -- "$archive_path" "$manifest"; then
        printf '%s: missing archive member\n' "$label" >&2
        printf '  package:  %s\n' "$pkg_path" >&2
        printf '  archive:  %s\n' "$archive_path" >&2
        failures=$((failures + 1))
        return
    fi

    if [ ! -f "$extracted_path" ] || [ -L "$extracted_path" ]; then
        printf '%s: archive member is not a regular file\n' "$label" >&2
        failures=$((failures + 1))
        return
    fi

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
    actual_mode=$(stat -c %a "$extracted_path")
    if [ "$actual_mode" != "$expected_mode" ]; then
        printf '%s: built package mode differs from canonical input\n' \
            "$label" >&2
        printf '  expected: %s\n' "$expected_mode" >&2
        printf '  actual:   %s\n' "$actual_mode" >&2
        printf '  archive:  %s\n' "$archive_path" >&2
        failures=$((failures + 1))
    fi
}

mapfile -t source_roots < <(
    find "$extracted_root/usr/src" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | sort
)
[ "${#source_roots[@]}" -eq 1 ] ||
    die "package must contain exactly one DKMS source root"
dkms_root="usr/src/${source_roots[0]}"

if [ "${source_roots[0]}" = "radeon-unified-0.3" ]; then
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
    "pre-build.sh" \
    755
check_member \
    "$package_dir/compiler-policy.conf" \
    "${dkms_root}/compiler-policy.conf" \
    "compiler-policy.conf"
check_member \
    "$package_dir/radeon-dkms-compiler-policy" \
    "${dkms_root}/radeon-dkms-compiler-policy" \
    "radeon-dkms-compiler-policy" \
    755
check_member \
    "$package_dir/radeon-dkms-compiler" \
    "${dkms_root}/radeon-dkms-compiler" \
    "radeon-dkms-compiler" \
    755
check_member \
    "$package_dir/radeon-dkms-make" \
    "${dkms_root}/radeon-dkms-make" \
    "radeon-dkms-make" \
    755
check_member \
    "$package_dir/radeon-dkms-ccache-gcc" \
    "${dkms_root}/radeon-dkms-ccache-gcc" \
    "radeon-dkms-ccache-gcc" \
    755
check_member \
    "$package_dir/radeon-dkms-ccache-clang" \
    "${dkms_root}/radeon-dkms-ccache-clang" \
    "radeon-dkms-ccache-clang" \
    755
check_member \
    "$repo_root/patches/rs480/SAFE_REGS.tsv" \
    "${dkms_root}/SAFE_REGS.tsv" \
    "SAFE_REGS.tsv"
check_member \
    "$repo_root/patches/rs480/CANDIDATE_REGS.tsv" \
    "${dkms_root}/CANDIDATE_REGS.tsv" \
    "CANDIDATE_REGS.tsv"
check_member \
    "$repo_root/patches/rs480/0001-rs480-safe-regs-debugfs.patch" \
    "${dkms_root}/patches/0001-radeon-rs480-safe-regs-debugfs.patch" \
    "0001-rs480-safe-regs-debugfs.patch"
for patch_name in "${PATCH[@]}"; do
    check_member \
        "$repo_root/patches/rs480/$patch_name" \
        "${dkms_root}/patches/$patch_name" \
        "$patch_name"
done
elif [ "${source_roots[0]}" = "radeon-rs480-safe-regs-0.2" ]; then
    check_member \
        "$package_dir/dkms.conf.radeon-rs480-safe-regs-0.2" \
        "${dkms_root}/dkms.conf" \
        "dkms.conf"
    check_member \
        "$package_dir/pre-build.sh" \
        "${dkms_root}/pre-build.sh" \
        "pre-build.sh" \
        755
    check_member \
        "$package_dir/compiler-policy.conf" \
        "${dkms_root}/compiler-policy.conf" \
        "compiler-policy.conf"
    check_member \
        "$package_dir/radeon-dkms-compiler-policy" \
        "${dkms_root}/radeon-dkms-compiler-policy" \
        "radeon-dkms-compiler-policy" \
        755
    check_member \
        "$package_dir/radeon-dkms-make" \
        "${dkms_root}/radeon-dkms-make" \
        "radeon-dkms-make" \
        755
    check_member \
        "$package_dir/radeon-dkms-ccache-gcc" \
        "${dkms_root}/radeon-dkms-ccache-gcc" \
        "radeon-dkms-ccache-gcc" \
        755
    check_member \
        "$package_dir/radeon-dkms-ccache-clang" \
        "${dkms_root}/radeon-dkms-ccache-clang" \
        "radeon-dkms-ccache-clang" \
        755
    check_member \
        "$repo_root/patches/rs480/SAFE_REGS.tsv" \
        "${dkms_root}/SAFE_REGS.tsv" \
        "SAFE_REGS.tsv"
    check_member \
        "$repo_root/patches/rs480/0001-rs480-safe-regs-debugfs.patch" \
        "${dkms_root}/patches/0001-radeon-rs480-safe-regs-debugfs.patch" \
        "0001-rs480-safe-regs-debugfs.patch"
else
    die "unsupported DKMS source root: ${source_roots[0]}"
fi

[ "$failures" -eq 0 ] || exit 1
printf 'radeon DKMS package artifacts: ok (%s)\n' "$pkg_path"
