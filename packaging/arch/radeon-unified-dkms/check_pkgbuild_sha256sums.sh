#!/usr/bin/env bash
# Verify the radeon-unified-dkms PKGBUILD sha256sums match the committed source
# files. They drift when a patch or TSV is edited without rebuilding the package,
# which silently makes the DKMS package un-buildable (caught by makepkg only at
# build time). Run in the package directory.
# Bash is required because PKGBUILD declares source and sha256sums as arrays.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cd "$script_dir"

startdir=$script_dir
# shellcheck source=/dev/null
source ./PKGBUILD

if [ "${#source[@]}" -ne "${#sha256sums[@]}" ]; then
    echo "PKGBUILD sha256sums DRIFT: source and sha256sums lengths differ." >&2
    echo "sources=${#source[@]} sha256sums=${#sha256sums[@]}" >&2
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
        echo "PKGBUILD sha256sums DRIFT: missing source for $label: $path" >&2
        fail=$((fail + 1))
        continue
    fi

    actual=$(sha256sum -- "$path")
    actual=${actual%% *}
    if [ "$actual" != "$expected" ]; then
        echo "PKGBUILD sha256sums DRIFT: $label" >&2
        echo "  expected $expected" >&2
        echo "  actual   $actual" >&2
        fail=$((fail + 1))
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "PKGBUILD sha256sums DRIFT: $fail source file(s) fail their checksum." >&2
    echo "Regenerate with: makepkg -g  and replace the sha256sums array." >&2
    exit 1
fi
echo "PKGBUILD sha256sums: all sources match"
