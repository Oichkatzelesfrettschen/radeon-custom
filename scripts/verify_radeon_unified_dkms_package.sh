#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
pkgbuild="$package_dir/PKGBUILD"
identity="$package_dir/source-identity.toml"
source_repository=${RADEON_UNIFIED_SOURCE_REPOSITORY:-}
pkg_path=

die() {
    printf 'verify_radeon_unified_dkms_package: %s\n' "$*" >&2
    exit 1
}

hash_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-repository)
            [[ $# -ge 2 ]] || die "--source-repository requires a path"
            source_repository=$2
            shift 2
            ;;
        --package)
            [[ $# -ge 2 ]] || die "--package requires a path"
            pkg_path=$2
            shift 2
            ;;
        *)
            [[ -z $pkg_path ]] || die "multiple package paths supplied"
            pkg_path=$1
            shift
            ;;
    esac
done

if [[ -z $source_repository ]]; then
    source_repository="$repo_root/../linux-radeon-gororoba"
fi
python3 "$repo_root/scripts/check_radeon_source_pin.py" \
    --identity "$identity" \
    --repository "$source_repository" \
    --pkgbuild "$pkgbuild"

# PKGBUILD consumes startdir and declares package identity when sourced.
# shellcheck disable=SC2034
startdir=$package_dir
# shellcheck source=/dev/null
source "$pkgbuild"

if [[ -z $pkg_path ]]; then
    pkg_path=$(find "$package_dir" -maxdepth 1 -type f \
        \( -name "${pkgname}-${pkgver}-${pkgrel}-*.pkg.tar.zst" -o \
        -name "${pkgname}-${pkgver}-${pkgrel}-*.pkg.tar.xz" \) |
        sort | tail -n 1)
fi
[[ -n $pkg_path && -f $pkg_path && ! -L $pkg_path ]] ||
    die "built package is absent or not a regular file"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
extracted_root="$tmpdir/package"
expected_radeon="$tmpdir/expected-radeon"
actual_manifest="$tmpdir/actual-tree.tsv"
expected_manifest="$tmpdir/expected-tree.tsv"
mkdir "$extracted_root" "$expected_radeon"
bsdtar -xf "$pkg_path" -C "$extracted_root"

mapfile -t source_roots < <(
    find "$extracted_root/usr/src" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | sort
)
[[ ${#source_roots[@]} -eq 1 ]] ||
    die "package must contain exactly one DKMS source root"
[[ ${source_roots[0]} == "radeon-unified-${pkgver}" ]] ||
    die "unexpected DKMS source root: ${source_roots[0]}"
dkms_root="$extracted_root/usr/src/${source_roots[0]}"

check_member() {
    local canonical_path=$1
    local installed_path=$2
    local expected_mode=$3
    local label=$4
    local actual_mode

    [[ -f $installed_path && ! -L $installed_path ]] ||
        die "$label is absent or not a regular file"
    [[ $(hash_file "$installed_path") == "$(hash_file "$canonical_path")" ]] ||
        die "$label differs from its package input"
    actual_mode=$(stat -c %a "$installed_path")
    [[ $actual_mode == "$expected_mode" ]] ||
        die "$label mode is $actual_mode, expected $expected_mode"
}

check_member "$package_dir/source-identity.toml" \
    "$dkms_root/source-identity.toml" 644 source-identity.toml
check_member "$package_dir/dkms.conf" "$dkms_root/dkms.conf" 644 dkms.conf
check_member "$package_dir/pre-build.sh" "$dkms_root/pre-build.sh" 755 pre-build.sh
check_member "$package_dir/dkms-initramfs-refresh.sh" \
    "$dkms_root/dkms-initramfs-refresh.sh" 755 dkms-initramfs-refresh.sh
check_member "$package_dir/compiler-policy.conf" \
    "$dkms_root/compiler-policy.conf" 644 compiler-policy.conf
check_member "$package_dir/radeon-dkms-compiler-policy" \
    "$dkms_root/radeon-dkms-compiler-policy" 755 radeon-dkms-compiler-policy
check_member "$package_dir/radeon-dkms-compiler" \
    "$dkms_root/radeon-dkms-compiler" 755 radeon-dkms-compiler
check_member "$package_dir/radeon-dkms-make" \
    "$dkms_root/radeon-dkms-make" 755 radeon-dkms-make
check_member "$package_dir/radeon-dkms-ccache-gcc" \
    "$dkms_root/radeon-dkms-ccache-gcc" 755 radeon-dkms-ccache-gcc
check_member "$package_dir/radeon-dkms-ccache-clang" \
    "$dkms_root/radeon-dkms-ccache-clang" 755 radeon-dkms-ccache-clang
check_member "$package_dir/radeon-unified-mkinitcpio.conf" \
    "$extracted_root/etc/mkinitcpio.conf.d/radeon-unified.conf" 644 \
    radeon-unified-mkinitcpio.conf
check_member "$package_dir/radeon-re.conf" \
    "$extracted_root/etc/modprobe.d/radeon-re.conf" 644 radeon-re.conf

git -C "$source_repository" archive \
    "${_source_commit}:drivers/gpu/drm/radeon" |
    bsdtar -xf - -C "$expected_radeon"

(cd "$expected_radeon" && find . -printf '%y\t%m\t%P\t%l\n' | sort) \
    >"$expected_manifest"
(cd "$dkms_root/radeon" && find . -printf '%y\t%m\t%P\t%l\n' | sort) \
    >"$actual_manifest"
cmp "$expected_manifest" "$actual_manifest" ||
    die "installed Radeon path, type, mode, or link manifest differs from git archive"
diff -qr "$expected_radeon" "$dkms_root/radeon" >/dev/null ||
    die "installed Radeon bytes differ from git archive"

entry_count=$(find "$dkms_root/radeon" -type f -o -type l | wc -l)
[[ $entry_count -eq 214 ]] ||
    die "installed Radeon archive has $entry_count entries, expected 214"

printf 'radeon unified DKMS package source export: PASS (%s)\n' "$pkg_path"
