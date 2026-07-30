#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
verifier="$repo_root/scripts/verify_radeon_unified_dkms_package.sh"
source_repository=${RADEON_UNIFIED_SOURCE_REPOSITORY:-}

die() {
    printf 'test_radeon_dkms_package_verifier: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 UNIFIED_PACKAGE"
package=$1
[[ -f $package && ! -L $package ]] ||
    die "package fixture is not a regular file: $package"
if [[ -z $source_repository ]]; then
    source_repository="$repo_root/../linux-radeon-gororoba"
fi

temp_root=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
mkdir -p "$temp_root"
tmpdir=$(mktemp -d "$temp_root/radeon-package-verifier.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

verify_package() {
    bash "$verifier" --source-repository "$source_repository" "$@"
}

verify_package "$package" >/dev/null

expect_rejection() {
    local name=$1
    local fixture=$2
    local diagnostic=$3

    shift 3
    if verify_package "$@" "$fixture" >"$tmpdir/$name.log" 2>&1; then
        die "$name fixture is accepted"
    fi
    grep -Fq "$diagnostic" "$tmpdir/$name.log" ||
        die "$name rejection omits its contract diagnostic"
}

create_package_fixture() {
    local output=$1
    local tree=$2

    (
        umask 000
        bsdtar -caf "$output" --uid 0 --gid 0 --uname root --gname root \
            -C "$tree" .
    )
}

mkdir "$tmpdir/source-tree" "$tmpdir/metadata-tree" "$tmpdir/extra-tree" \
    "$tmpdir/executable-tree"
bsdtar -xf "$package" -C "$tmpdir/source-tree"
printf '\n# verifier mutation fixture\n' \
    >>"$tmpdir/source-tree/usr/src/radeon-unified-0.3/radeon/Makefile"
create_package_fixture "$tmpdir/mutated-source.pkg.tar.zst" \
    "$tmpdir/source-tree"
expect_rejection source-mutation "$tmpdir/mutated-source.pkg.tar.zst" \
    "installed Radeon bytes differ from git archive"

bsdtar -xf "$package" -C "$tmpdir/metadata-tree"
sed -i 's/^pkgver = .*/pkgver = 0.3-999/' \
    "$tmpdir/metadata-tree/.PKGINFO"
create_package_fixture "$tmpdir/mutated-metadata.pkg.tar.zst" \
    "$tmpdir/metadata-tree"
expect_rejection metadata-mutation "$tmpdir/mutated-metadata.pkg.tar.zst" \
    ".PKGINFO pkgver does not equal the selected PKGBUILD value"

bsdtar -xf "$package" -C "$tmpdir/extra-tree"
: >"$tmpdir/extra-tree/usr/src/radeon-unified-0.3/unexpected"
create_package_fixture "$tmpdir/extra-file.pkg.tar.zst" \
    "$tmpdir/extra-tree"
expect_rejection extra-member "$tmpdir/extra-file.pkg.tar.zst" \
    "archive member manifest differs from the closed package payload"

bsdtar -xf "$package" -C "$tmpdir/executable-tree"
chmod 0644 \
    "$tmpdir/executable-tree/usr/src/radeon-unified-0.3/radeon-dkms-make"
create_package_fixture "$tmpdir/nonexecutable-helper.pkg.tar.zst" \
    "$tmpdir/executable-tree"
expect_rejection executable-mode "$tmpdir/nonexecutable-helper.pkg.tar.zst" \
    "radeon-dkms-make mode is 644, expected 755"

mkdir "$tmpdir/directory-mode-tree"
bsdtar -xf "$package" -C "$tmpdir/directory-mode-tree"
chmod 0777 "$tmpdir/directory-mode-tree/usr/src/radeon-unified-0.3/radeon"
create_package_fixture "$tmpdir/directory-mode.pkg.tar.zst" \
    "$tmpdir/directory-mode-tree"
expect_rejection directory-mode "$tmpdir/directory-mode.pkg.tar.zst" \
    "archive directory mode is neither 755 nor signed-source 775"

(
    umask 000
    bsdtar -caf "$tmpdir/non-root-owner.pkg.tar.zst" \
        --uid 1000 --gid 1000 --uname fixture --gname fixture \
        -C "$tmpdir/extra-tree" .
)
expect_rejection non-root-owner "$tmpdir/non-root-owner.pkg.tar.zst" \
    "archive contains a member not owned by root"

printf 'unsafe archive fixture\n' >"$tmpdir/safe-name"
(
    cd "$tmpdir"
    bsdtar -cf traversal.tar --uid 0 --gid 0 --uname root --gname root \
        -s ',safe-name,../escape,' safe-name
)
expect_rejection traversal "$tmpdir/traversal.tar" \
    "archive member contains parent traversal"

ln -s target "$tmpdir/link"
(
    cd "$tmpdir"
    bsdtar -cf symbolic-link.tar link
)
expect_rejection symbolic-link "$tmpdir/symbolic-link.tar" \
    "archive contains a symbolic link, hard link, or special file"

printf 'hard-link archive fixture\n' >"$tmpdir/hard-link-source"
ln "$tmpdir/hard-link-source" "$tmpdir/hard-link-target"
(
    cd "$tmpdir"
    bsdtar -cf hard-link.tar hard-link-source hard-link-target
)
expect_rejection hard-link "$tmpdir/hard-link.tar" \
    "archive contains a symbolic link, hard link, or special file"

expect_rejection wrong-digest "$package" \
    "admitted package SHA-256 differs from the expected digest" \
    --expected-sha256 \
    0000000000000000000000000000000000000000000000000000000000000000

printf 'radeon DKMS package verifier calibration: PASS\n'
