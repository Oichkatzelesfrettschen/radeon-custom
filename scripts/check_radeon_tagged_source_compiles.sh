#!/bin/sh
# Build the pinned Radeon source export against one declared kernel root.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
identity="$package_dir/source-identity.toml"
pkgbuild="$package_dir/PKGBUILD"
source_repository=${RADEON_UNIFIED_SOURCE_REPOSITORY:-}
kernel_build_root=
self_test=0

die() {
    printf 'check_radeon_tagged_source_compiles: %s\n' "$*" >&2
    exit 2
}

scan_warnings() {
    unexpected=$(grep -in warning "$1" |
        grep -v 'the compiler differs from the one used to build the kernel' ||
        true)
    if [ -n "$unexpected" ]; then
        printf 'unapproved build warning:\n%s\n' "$unexpected" >&2
        return 1
    fi
}

make_work_dir() {
    temp_base=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
    [ -d "$temp_base" ] && [ -w "$temp_base" ] ||
        die "temporary build root is absent or not writable: $temp_base"
    mktemp -d "$temp_base/radeon-tagged-build.XXXXXX"
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --kernel-build-root)
            [ "$#" -ge 2 ] || die "--kernel-build-root requires a path"
            kernel_build_root=$2
            shift 2
            ;;
        --source-repository)
            [ "$#" -ge 2 ] || die "--source-repository requires a path"
            source_repository=$2
            shift 2
            ;;
        --self-test)
            self_test=1
            shift
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [ "$self_test" -eq 1 ]; then
    work=$(make_work_dir)
    trap 'rm -rf "$work"' EXIT INT TERM
    printf 'CC [M] fixture.o\nMODPOST Module.symvers\n' >"$work/good.log"
    printf 'warning: the compiler differs from the one used to build the kernel\n' \
        >"$work/allowed.log"
    printf 'warning: unused variable\n' >"$work/bad.log"
    scan_warnings "$work/good.log"
    scan_warnings "$work/allowed.log"
    if scan_warnings "$work/bad.log" 2>/dev/null; then
        die "warning calibration accepts an unapproved warning"
    fi
    printf 'tagged source compile calibration: PASS\n'
    exit 0
fi

[ -n "$kernel_build_root" ] ||
    die "--kernel-build-root is required"
if [ -z "$source_repository" ]; then
    source_repository="$repo_root/../linux-radeon-gororoba"
fi
python3 "$repo_root/scripts/check_radeon_source_pin.py" \
    --identity "$identity" \
    --repository "$source_repository" \
    --pkgbuild "$pkgbuild"

kernel_build_root=$(CDPATH='' cd -- "$kernel_build_root" && pwd -P) ||
    die "kernel build root is absent"
for required in \
    Makefile \
    Module.symvers \
    include/config/kernel.release \
    include/generated/autoconf.h \
    include/generated/uapi/linux/version.h
do
    [ -r "$kernel_build_root/$required" ] ||
        die "kernel build root omits $required"
done
kernel_release=$(cat "$kernel_build_root/include/config/kernel.release")

# PKGBUILD owns the literal source commit checked by check_radeon_source_pin.py.
# shellcheck disable=SC2034
startdir=$package_dir
# shellcheck source=/dev/null
. "$pkgbuild"

work=$(make_work_dir)
trap 'rm -rf "$work"' EXIT INT TERM
radeon_tree="$work/drivers/gpu/drm/radeon"
mkdir -p "$radeon_tree" "$work/include/trace"
git -C "$source_repository" archive \
    "${_source_commit}:drivers/gpu/drm/radeon" |
    tar -x -C "$radeon_tree"

if grep -q '^CONFIG_CC_IS_CLANG=y' \
        "$kernel_build_root/include/config/auto.conf" 2>/dev/null ||
        grep -qi clang "$kernel_build_root/include/generated/compile.h"; then
    set -- LLVM=1
else
    set --
fi

build_log="$work/build.log"
build_status=0
(
    cd "$radeon_tree"
    KCFLAGS="-I$work/include/trace" \
        "$package_dir/radeon-dkms-make" "$@" \
        -C "$kernel_build_root" M="$PWD" modules
) >"$build_log" 2>&1 || build_status=$?
cat "$build_log"
[ "$build_status" -eq 0 ] ||
    { printf 'radeon build failed against %s\n' "$kernel_release" >&2; exit 4; }
[ -f "$radeon_tree/radeon.ko" ] ||
    { printf 'radeon.ko is absent after build\n' >&2; exit 4; }
grep -q MODPOST "$build_log" ||
    { printf 'MODPOST is absent from build log\n' >&2; exit 4; }
scan_warnings "$build_log" ||
    exit 4
find "$radeon_tree" -maxdepth 1 -type f -name '*_reg_safe.h' |
    grep -q . ||
    { printf 'generated register headers are absent\n' >&2; exit 4; }
[ -x "$radeon_tree/mkregtable" ] ||
    { printf 'generated mkregtable is absent\n' >&2; exit 4; }

printf 'tagged Radeon source build: PASS against %s\n' "$kernel_release"
