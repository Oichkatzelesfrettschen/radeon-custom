#!/usr/bin/env bash
# Verify the radeon-unified-dkms PKGBUILD sha256sums match the committed source
# files. They drift when a patch or TSV is edited without rebuilding the package,
# which silently makes the DKMS package un-buildable (caught by makepkg only at
# build time). Run in the package directory.
# Bash is required because PKGBUILD declares source and sha256sums as arrays.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cd "$script_dir"

check_recipe() (
    recipe=$1
    # PKGBUILD consumes startdir and declares both arrays when sourced.
    # shellcheck disable=SC2034
    startdir=$script_dir
    # shellcheck source=/dev/null
    source "$recipe"

    # shellcheck disable=SC2154
    if [ "${#source[@]}" -ne "${#sha256sums[@]}" ]; then
        printf '%s: source and sha256sums lengths differ\n' "$recipe" >&2
        printf 'sources=%d sha256sums=%d\n' \
            "${#source[@]}" "${#sha256sums[@]}" >&2
        exit 1
    fi

    fail=0
    for i in "${!source[@]}"; do
        entry=${source[$i]}
        expected=${sha256sums[$i]}
        label=$entry

        case $entry in
            *::file://*)
                label=${entry%%::*}
                path=${entry#*::file://}
                ;;
            file://*)
                path=${entry#file://}
                ;;
            *)
                path=$script_dir/$entry
                ;;
        esac

        if [ "$expected" = "SKIP" ]; then
            continue
        fi
        if [ ! -f "$path" ]; then
            printf '%s: missing source for %s: %s\n' \
                "$recipe" "$label" "$path" >&2
            fail=$((fail + 1))
            continue
        fi

        actual=$(sha256sum -- "$path")
        actual=${actual%% *}
        if [ "$actual" != "$expected" ]; then
            printf '%s: checksum drift for %s\n' "$recipe" "$label" >&2
            printf '  expected %s\n' "$expected" >&2
            printf '  actual   %s\n' "$actual" >&2
            fail=$((fail + 1))
        fi
    done

    if [ "$fail" -ne 0 ]; then
        printf '%s: %d source files fail their checksum\n' \
            "$recipe" "$fail" >&2
        exit 1
    fi
    printf '%s: all source checksums match\n' "$recipe"
)

check_recipe ./PKGBUILD
check_recipe ./PKGBUILD.radeon-rs480-safe-regs-0.2
