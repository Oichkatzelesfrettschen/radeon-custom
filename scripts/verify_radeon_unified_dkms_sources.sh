#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
pkgbuild="$package_dir/PKGBUILD"
identity="$package_dir/source-identity.toml"
legacy_identity="$repo_root/migration/input/legacy-dkms-patch-order.toml"
legacy_copy="$repo_root/migration/input/legacy-dkms-patch-order.conf"
source_repository=${RADEON_UNIFIED_SOURCE_REPOSITORY:-}

die() {
    printf 'verify_radeon_unified_dkms_sources: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-repository)
            [[ $# -ge 2 ]] || die "--source-repository requires a path"
            source_repository=$2
            shift 2
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [[ -z $source_repository ]]; then
    source_repository="$repo_root/../linux-radeon-gororoba"
fi
[[ -d $source_repository/.git || -f $source_repository/.git ]] ||
    die "source repository is absent: $source_repository"

python3 "$repo_root/scripts/check_radeon_source_pin.py" --self-test
python3 "$repo_root/scripts/check_radeon_source_pin.py" \
    --identity "$identity" \
    --repository "$source_repository" \
    --pkgbuild "$pkgbuild" \
    --legacy-identity "$legacy_identity" \
    --legacy-repository "$repo_root" \
    --legacy-copy "$legacy_copy"
python3 "$repo_root/scripts/check_radeon_package_profiles.py" --self-test
python3 "$repo_root/scripts/check_radeon_package_profiles.py"
bash "$repo_root/scripts/test_radeon_dkms_kcflags_composition.sh"

# PKGBUILD consumes startdir and declares source and sha256sums when sourced.
# shellcheck disable=SC2034
startdir=$package_dir
# shellcheck source=/dev/null
source "$pkgbuild"

[[ ${#source[@]} -eq ${#sha256sums[@]} ]] ||
    die "source and sha256sums arrays differ in length"

vcs_sources=0
for index in "${!source[@]}"; do
    spec=${source[$index]}
    expected=${sha256sums[$index]}
    source_name=${spec%%::*}
    if [[ $spec == *::git+* ]]; then
        vcs_sources=$((vcs_sources + 1))
        [[ $source_name == radeon-source ]] ||
            die "unexpected VCS source alias: $source_name"
        [[ $expected == SKIP ]] ||
            die "the content-addressed VCS source must use SKIP"
        continue
    fi
    [[ $spec == "$source_name" ]] ||
        die "non-VCS source uses an unexpected transport: $spec"
    source_path="$package_dir/$source_name"
    [[ -f $source_path && ! -L $source_path ]] ||
        die "package source is not a regular file: $source_path"
    actual=$(sha256sum "$source_path")
    actual=${actual%% *}
    [[ $actual == "$expected" ]] ||
        die "$source_name SHA-256 mismatch: expected $expected, got $actual"
done
[[ $vcs_sources -eq 1 ]] ||
    die "PKGBUILD must declare exactly one VCS source"

for config in "$package_dir/dkms.conf.prod" "$package_dir/dkms.conf.dev"; do
    if grep -Eq '^[[:space:]]*PATCH(_MATCH)?\[' "$config"; then
        die "$(basename "$config") retains a patch phase"
    fi
done
if grep -Eq 'patch[[:space:]]+-p|git[[:space:]]+apply|canonical-source\\.tar' \
        "$pkgbuild"; then
    die "active PKGBUILD retains package-time source mutation"
fi

printf 'radeon unified DKMS source pin and package inputs: PASS\n'
