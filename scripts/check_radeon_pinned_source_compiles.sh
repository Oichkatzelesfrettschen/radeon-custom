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
requested_profile=prod
self_test=0

die() {
    printf 'check_radeon_pinned_source_compiles: %s\n' "$*" >&2
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

verify_module_metadata() {
    field=$1
    expected=$2
    actual=$3
    if [ -z "$actual" ]; then
        printf 'module metadata %s is missing, expected %s\n' \
            "$field" "$expected" >&2
        return 1
    fi
    if [ "$actual" != "$expected" ]; then
        printf 'module metadata %s is %s, expected %s\n' \
            "$field" "$actual" "$expected" >&2
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
        --profile)
            [ "$#" -ge 2 ] || die "--profile requires prod or all-dev"
            requested_profile=$2
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

case $requested_profile in
    prod)
        resolved_profile=prod
        profile_input=prod
        ;;
    all-dev)
        resolved_profile=mutate-dev
        profile_input=dev
        ;;
    *)
        die "--profile requires prod or all-dev"
        ;;
esac

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
    expected_driver_tree=fixture-driver-tree
    verify_module_metadata gororoba_driver_tree \
        "$expected_driver_tree" "$expected_driver_tree" ||
        die "metadata calibration rejects its known-good driver tree"
    wrong_metadata=$(verify_module_metadata gororoba_driver_tree \
        "$expected_driver_tree" wrong-driver-tree 2>&1) &&
        die "metadata calibration accepts a wrong driver tree"
    printf '%s\n' "$wrong_metadata" |
        grep -Fqx \
            "module metadata gororoba_driver_tree is wrong-driver-tree, expected $expected_driver_tree" ||
        die "metadata calibration reports an imprecise wrong driver tree"
    missing_metadata=$(verify_module_metadata gororoba_driver_tree \
        "$expected_driver_tree" '' 2>&1) &&
        die "metadata calibration accepts a missing driver tree"
    printf '%s\n' "$missing_metadata" |
        grep -Fqx \
            "module metadata gororoba_driver_tree is missing, expected $expected_driver_tree" ||
        die "metadata calibration reports an imprecise missing driver tree"
    printf 'pinned source compile calibration: PASS\n'
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
build_helper="$work/radeon-dkms-make"
cp "$package_dir/radeon-dkms-make" "$build_helper"
cp "$package_dir/radeon-build-profile.${profile_input}.h" \
    "$work/radeon-build-profile.h"
chmod 0755 "$build_helper"

if grep -q '^CONFIG_CC_IS_CLANG=y' \
        "$kernel_build_root/include/config/auto.conf" 2>/dev/null ||
        grep -qi clang "$kernel_build_root/include/generated/compile.h"; then
    set -- LLVM=1
else
    set --
fi

build_log="$work/build.log"
build_status=0
build_jobs=$(nproc 2>/dev/null || echo 1)
(
    cd "$radeon_tree"
    KCFLAGS="-I$work/include/trace" \
        "$build_helper" "$@" RADEON_BUILD_PROFILE="$resolved_profile" \
        -j"$build_jobs" -l"$build_jobs" -C "$kernel_build_root" M="$PWD" modules
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
for metadata in \
    "gororoba_build_profile:$resolved_profile" \
    "gororoba_source_commit:$_source_commit" \
    "gororoba_driver_tree:$_source_driver_tree" \
    "gororoba_feature_policy_sha256:$_source_feature_policy_sha256" \
    "gororoba_upstream_base:$_source_upstream_base"
do
    field=${metadata%%:*}
    expected=${metadata#*:}
    actual=$(modinfo -F "$field" "$radeon_tree/radeon.ko" 2>/dev/null || true)
    verify_module_metadata "$field" "$expected" "$actual" ||
        die "module metadata verification failed"
done

printf 'pinned Radeon source build: PASS against %s as %s\n' \
    "$kernel_release" "$requested_profile"
