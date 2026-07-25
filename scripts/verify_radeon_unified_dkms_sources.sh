#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
pkgbuild="$package_dir/PKGBUILD"

rs480_dir="$repo_root/patches/rs480"
fragment_generator="$repo_root/scripts/generate_rs480_debugfs_fragments.py"
gart_reader_verifier="$repo_root/scripts/verify_rs400_gart_reader_schema.py"
safe_regs_tsv="$rs480_dir/SAFE_REGS.tsv"
candidate_regs_tsv="$rs480_dir/CANDIDATE_REGS.tsv"

die() {
    printf 'verify_radeon_unified_dkms_sources: %s\n' "$*" >&2
    exit 1
}

hash_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

startdir="$package_dir"
source "$pkgbuild"

[ "${#source[@]}" -eq "${#sha256sums[@]}" ] ||
    die "source and sha256sums arrays differ in length"

failures=0
for index in "${!source[@]}"; do
    spec=${source[$index]}
    expected=${sha256sums[$index]}

    case "$spec" in
        *::file://*)
            source_name=${spec%%::*}
            source_path=${spec#*::file://}
            ;;
        file://*)
            source_path=${spec#file://}
            source_name=$(basename -- "$source_path")
            ;;
        *)
            source_name=$spec
            source_path=$package_dir/$spec
            ;;
    esac

    [ -r "$source_path" ] || {
        printf '%s: missing source %s\n' "$source_name" "$source_path" >&2
        failures=$((failures + 1))
        continue
    }

    actual=$(hash_file "$source_path")
    if [ "$actual" != "$expected" ]; then
        printf '%s: canonical hash mismatch\n' "$source_name" >&2
        printf '  expected: %s\n' "$expected" >&2
        printf '  actual:   %s\n' "$actual" >&2
        printf '  path:     %s\n' "$source_path" >&2
        failures=$((failures + 1))
    fi

    cached_path=$package_dir/$source_name
    if [ -e "$cached_path" ] && [ "$cached_path" != "$source_path" ]; then
        cached_hash=$(hash_file "$cached_path")
        if [ "$cached_hash" != "$actual" ]; then
            printf '%s: package-local source cache differs from canonical input\n' "$source_name" >&2
            printf '  cache:    %s\n' "$cached_path" >&2
            printf '  canonical:%s\n' "$source_path" >&2
            failures=$((failures + 1))
        fi
    fi
done

python3 "$fragment_generator" \
    --safe-tsv "$safe_regs_tsv" \
    --candidate-tsv "$candidate_regs_tsv" \
    --safe-patch "$rs480_dir/0001-rs480-safe-regs-debugfs.patch" \
    --safe-extra-patch "$rs480_dir/0014-rs480-promote-config-regs-to-safe.patch" \
    --safe-extra-patch "$rs480_dir/0017-rs480-promote-frontier-responders-to-safe.patch" \
    --safe-extra-patch "$rs480_dir/0020-rs480-promote-hazard-read-responders-to-safe.patch" \
    --safe-extra-patch "$rs480_dir/0028-rs480-combios4-safe-and-vip-straggler-reader.patch" \
    --candidate-patch "$rs480_dir/0004-rs480-candidate-regs-debugfs.patch" \
    --candidate-extra-patch "$rs480_dir/0010-rs480-mc-benign-candidate-regs-debugfs.patch" \
    --candidate-skip-cohort attended \
    --check-patches

# Patch-apply dry-run.  A file hash can be self-consistent yet still be a
# malformed unified diff: commit cc22d3029 expanded a hunk body in 0016 without
# updating the hunk count, producing a patch that GNU patch rejects with
# "malformed patch", which the hash check above could not see.  Replicate the
# DKMS build's apply path (the canonical tarball already carries 0001; dkms.conf
# PATCH[] applies the rest with patch -p1) so a malformed hunk cannot ship a
# source tree that fails to build.  The tarball is the known-good base; a stale
# hunk count is the known-bad this catches.
dkms_conf="$package_dir/dkms.conf"
[ -r "$dkms_conf" ] || die "dkms.conf not found: $dkms_conf"

tarball=""
for spec in "${source[@]}"; do
    case "$spec" in
        *radeon-unified-canonical-source.tar.xz::file://*)
            tarball=${spec#*::file://}
            ;;
    esac
done
[ -n "$tarball" ] && [ -r "$tarball" ] ||
    die "canonical source tarball not resolvable from PKGBUILD source[]"

mapfile -t patch_chain < <(
    grep -oE '^PATCH\[[0-9]+\]="[^"]+"' "$dkms_conf" |
        sed -E 's/^PATCH\[([0-9]+)\]="([^"]+)"/\1\t\2/' |
        sort -n |
        cut -f2
)
[ "${#patch_chain[@]}" -gt 0 ] || die "no PATCH[] entries parsed from dkms.conf"

apply_root=$(mktemp -d)
trap 'rm -rf "$apply_root"' EXIT
mkdir -p "$apply_root/radeon"
tar xJf "$tarball" -C "$apply_root/radeon"
for patch_name in "${patch_chain[@]}"; do
    patch_path="$rs480_dir/$patch_name"
    [ -r "$patch_path" ] || {
        printf 'patch chain: dkms.conf references missing patch %s\n' "$patch_name" >&2
        failures=$((failures + 1))
        break
    }
    if ! patch -p1 -d "$apply_root" --no-backup-if-mismatch -i "$patch_path" \
            >/dev/null 2>&1; then
        printf 'patch chain: %s fails to apply over the canonical tarball\n' "$patch_name" >&2
        printf '  reproduce: patch -p1 -d <tarball-tree> -i %s\n' "$patch_path" >&2
        failures=$((failures + 1))
        break
    fi
done

rs400_source="$apply_root/radeon/rs400.c"
[ -r "$rs400_source" ] || die "patched rs400.c is missing"

grep -Fq '#define RS400_GART_PAGE_TABLE_ENTRY_LIMIT 64' "$rs400_source" || {
    printf 'GART reader: the 64-entry output bound is missing\n' >&2
    failures=$((failures + 1))
}
grep -Fq 'debugfs_create_file("radeon_rs480_gart_page_table", 0400' \
    "$rs400_source" || {
    printf 'GART reader: the root-only read permission is missing\n' >&2
    failures=$((failures + 1))
}
grep -Fq 'page_dma_address' "$rs400_source" || {
    printf 'GART reader: the DMA-address qualification is missing\n' >&2
    failures=$((failures + 1))
}
grep -Fq 'backing_class' "$rs400_source" || {
    printf 'GART reader: the bounded backing classification is missing\n' >&2
    failures=$((failures + 1))
}
grep -Fq 'kernel_pte_raw' "$rs400_source" || {
    printf 'GART reader: the CPU page-table evidence is missing\n' >&2
    failures=$((failures + 1))
}
if ! python3 "$gart_reader_verifier" "$rs400_source"; then
    failures=$((failures + 1))
fi

gart_reader=$(sed -n \
    '/static int rs400_debugfs_gart_page_table_show/,/DEFINE_SHOW_ATTRIBUTE(rs400_debugfs_gart_page_table)/p' \
    "$rs400_source")
if printf '%s\n' "$gart_reader" | \
        grep -Eq '\b(WREG|writel|writeq|iowrite|memcpy_toio|copy_from_user)[A-Za-z0-9_]*[[:space:]]*\('; then
    printf 'GART reader: a hardware or userspace-fed write primitive is present\n' >&2
    failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1
printf 'radeon unified DKMS source hashes: ok\n'
printf 'radeon unified DKMS patch chain: applies clean (%d patches)\n' \
    "${#patch_chain[@]}"
printf 'radeon unified DKMS GART reader policy: bounded and read-only\n'
