#!/bin/sh
# SPDX-License-Identifier: MIT
# Verify a kernel build root installed from one pinned Arch headers package.
#
# pacman verifies the package signature at install, so the root's identity
# rests on five facts the installed system can prove: the exact package
# version, the kernel.release the root carries, a LINUX_VERSION_CODE inside
# the declared half-open range, every installed file against the size, mode,
# and SHA-256 recorded in the package's signed .MTREE (pacman -Qkk), and a
# root holding exactly the non-directory paths the package owns, so an
# injected file fails as surely as an altered one. On success the script
# prints kernel_build_root=PATH on stdout.

set -eu

pacman_command=${RADEON_CI_PACMAN:-pacman}
modules_root=${RADEON_CI_MODULES_ROOT:-/usr/lib/modules}

usage() {
    cat <<'EOF'
usage: check_packaged_kernel_build_root.sh --package NAME --version VERSION
           --release RELEASE --version-code-range MIN:MAX
       check_packaged_kernel_build_root.sh --self-test

MIN is inclusive and MAX exclusive, both LINUX_VERSION_CODE integers.
EOF
}

die() {
    printf 'check_packaged_kernel_build_root: %s\n' "$*" >&2
    exit 2
}

fail() {
    printf 'check_packaged_kernel_build_root: %s\n' "$*" >&2
    return 1
}

is_decimal() {
    case $1 in
        '' | *[!0-9]*) return 1 ;;
    esac
}

verify_root() {
    package=$1
    version=$2
    release=$3
    code_min=$4
    code_max=$5

    installed=$("$pacman_command" -Q "$package" 2>/dev/null) ||
        fail "package $package is not installed" || return 1
    [ "$installed" = "$package $version" ] ||
        fail "installed package is $installed, expected $package $version" ||
        return 1

    root="$modules_root/$release/build"
    if [ ! -d "$root" ] || [ -L "$root" ]; then
        fail "build root is not a real directory: $root"
        return 1
    fi
    [ -r "$root/include/config/kernel.release" ] ||
        fail "build root omits include/config/kernel.release" || return 1
    actual_release=$(cat "$root/include/config/kernel.release")
    [ "$actual_release" = "$release" ] ||
        fail "build root carries kernel.release $actual_release, expected $release" ||
        return 1

    version_header="$root/include/generated/uapi/linux/version.h"
    [ -r "$version_header" ] ||
        fail "build root omits include/generated/uapi/linux/version.h" ||
        return 1
    code=$(awk '$1 == "#define" && $2 == "LINUX_VERSION_CODE" { print $3 }' \
        "$version_header")
    is_decimal "$code" ||
        fail "LINUX_VERSION_CODE is not one decimal integer: $code" || return 1
    if [ "$code" -lt "$code_min" ] || [ "$code" -ge "$code_max" ]; then
        fail "LINUX_VERSION_CODE $code lies outside [$code_min, $code_max)"
        return 1
    fi

    mtree_report=$("$pacman_command" -Qkk "$package" 2>&1) || {
        printf '%s\n' "$mtree_report" >&2
        fail "installed files of $package differ from its package .MTREE"
        return 1
    }

    listing=$(mktemp -d "${TMPDIR:-/tmp}/radeon-build-root-files.XXXXXX")
    find "$root" -mindepth 1 ! -type d | LC_ALL=C sort >"$listing/present"
    "$pacman_command" -Qlq "$package" |
        awk -v prefix="$root/" \
            'index($0, prefix) == 1 && substr($0, length($0)) != "/"' |
        LC_ALL=C sort >"$listing/owned"
    difference=$(LC_ALL=C comm -3 "$listing/present" "$listing/owned")
    file_count=$(wc -l <"$listing/owned")
    rm -rf "$listing"
    [ -z "$difference" ] || {
        printf 'present-only (column 1) and owned-only (column 2) paths:\n%s\n' \
            "$difference" >&2
        fail "build root file set differs from the files $package owns"
        return 1
    }
    [ "$file_count" -gt 0 ] ||
        fail "package $package owns no file under $root" || return 1

    printf 'packaged build root: %s %s, kernel.release %s, LINUX_VERSION_CODE %s, %s files owned and .MTREE-verified\n' \
        "$package" "$version" "$release" "$code" "$file_count" >&2
    printf 'kernel_build_root=%s\n' "$root"
}

write_fixture_pacman() {
    # The fixture pacman answers from files the calibration writes, so each
    # known-bad case mutates exactly one fact the verifier reads.
    cat >"$1" <<'EOF'
#!/bin/sh
set -eu
case $1 in
    -Q) cat "$RADEON_CI_FIXTURE/installed" ;;
    -Qkk) cat "$RADEON_CI_FIXTURE/mtree"; exit "$(cat "$RADEON_CI_FIXTURE/mtree-status")" ;;
    -Qlq) cat "$RADEON_CI_FIXTURE/owned" ;;
    *) exit 64 ;;
esac
EOF
    chmod 0755 "$1"
}

self_test() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/radeon-build-root-selftest.XXXXXX")
    trap 'rm -rf "$work"' EXIT INT TERM
    fixture="$work/fixture"
    modules="$work/modules"
    root="$modules/6.18.54-1-lts/build"
    mkdir -p "$fixture" "$root/include/config" "$root/include/generated/uapi/linux"

    reset_fixture() {
        rm -rf "$root"
        mkdir -p "$root/include/config" "$root/include/generated/uapi/linux"
        printf '6.18.54-1-lts\n' >"$root/include/config/kernel.release"
        printf '#define LINUX_VERSION_CODE 397878\n' \
            >"$root/include/generated/uapi/linux/version.h"
        printf 'fixture:\n' >"$root/Makefile"
        ln -s Makefile "$root/Makefile.link"
        printf 'linux-lts-headers 6.18.54-1\n' >"$fixture/installed"
        printf 'linux-lts-headers: 4 total files, 0 altered files\n' \
            >"$fixture/mtree"
        printf '0\n' >"$fixture/mtree-status"
        {
            printf '%s/\n' "$modules/6.18.54-1-lts" "$root"
            printf '%s\n' "$root/Makefile" "$root/Makefile.link"
            printf '%s/\n' "$root/include" "$root/include/config"
            printf '%s\n' "$root/include/config/kernel.release"
            printf '%s/\n' "$root/include/generated" \
                "$root/include/generated/uapi" \
                "$root/include/generated/uapi/linux"
            printf '%s\n' "$root/include/generated/uapi/linux/version.h"
        } >"$fixture/owned"
    }

    write_fixture_pacman "$work/pacman"
    RADEON_CI_FIXTURE=$fixture
    export RADEON_CI_FIXTURE
    pacman_command="$work/pacman"
    modules_root=$modules

    run_fixture() {
        verify_root linux-lts-headers 6.18.54-1 6.18.54-1-lts 397824 458752
    }

    reset_fixture
    output=$(run_fixture 2>/dev/null) ||
        die "calibration rejects its known-good packaged root"
    [ "$output" = "kernel_build_root=$root" ] ||
        die "calibration reports an imprecise build root: $output"
    printf 'PASS known-good: pinned package, release, range, .MTREE, and owned file set\n'

    expect_rejection() {
        name=$1
        if run_fixture >/dev/null 2>&1; then
            die "calibration accepts $name"
        fi
        printf 'PASS known-bad: %s\n' "$name"
        reset_fixture
    }

    printf 'linux-lts-headers 6.18.55-1\n' >"$fixture/installed"
    expect_rejection 'a different package version'
    printf '6.18.54-2-lts\n' >"$root/include/config/kernel.release"
    expect_rejection 'a different kernel.release'
    printf '#define LINUX_VERSION_CODE 459271\n' \
        >"$root/include/generated/uapi/linux/version.h"
    expect_rejection 'a version code at or above the exclusive bound'
    printf '#define LINUX_VERSION_CODE 397823\n' \
        >"$root/include/generated/uapi/linux/version.h"
    expect_rejection 'a version code below the inclusive bound'
    printf '1\n' >"$fixture/mtree-status"
    expect_rejection 'a file that differs from the package .MTREE'
    printf 'injected\n' >"$root/injected.h"
    expect_rejection 'a file the package does not own'
    rm "$root/Makefile.link"
    expect_rejection 'an owned file absent from the root'
    rm -rf "$root"
    mkdir -p "$modules/elsewhere"
    ln -s ../elsewhere "$root"
    expect_rejection 'a build root that is a symbolic link'
    rm -rf "$modules/elsewhere"
    printf 'kernel build-root package calibration: PASS\n'
}

package=
version=
release=
code_range=
run_self_test=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --package | --version | --release | --version-code-range)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            case $1 in
                --package) package=$2 ;;
                --version) version=$2 ;;
                --release) release=$2 ;;
                --version-code-range) code_range=$2 ;;
            esac
            shift 2
            ;;
        --self-test)
            run_self_test=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [ "$run_self_test" -eq 1 ]; then
    self_test
    exit 0
fi

[ -n "$package" ] || die "--package is required"
[ -n "$version" ] || die "--version is required"
[ -n "$release" ] || die "--release is required"
case $release in
    */* | . | .. | '') die "--release must be one path-free token" ;;
esac
code_min=${code_range%%:*}
code_max=${code_range#*:}
if ! is_decimal "$code_min" || ! is_decimal "$code_max"; then
    die "--version-code-range requires MIN:MAX decimal integers"
fi
[ "$code_min" -lt "$code_max" ] || die "--version-code-range is empty"
verify_root "$package" "$version" "$release" "$code_min" "$code_max" ||
    exit 1
