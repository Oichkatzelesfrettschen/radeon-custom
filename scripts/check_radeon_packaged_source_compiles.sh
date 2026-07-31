#!/bin/sh
# Build the production Radeon source carried by an admitted package artifact.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
expected_identity="$package_dir/source-identity.toml"
expected_profile="$package_dir/radeon-build-profile.prod.toml"
expected_header="$package_dir/radeon-build-profile.prod.h"
expected_dkms="$package_dir/dkms.conf.prod"
expected_policy="$package_dir/radeon-re.conf"
package_path=
kernel_build_root=
self_test=0

die() {
    printf 'check_radeon_packaged_source_compiles: %s\n' "$*" >&2
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

toml_string() {
    file=$1
    key=$2
    value=$(sed -n \
        "s/^${key}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
        "$file")
    [ "$(printf '%s\n' "$value" | grep -c .)" -eq 1 ] ||
        die "$file has no unique $key string"
    printf '%s\n' "$value"
}

toml_integer() {
    file=$1
    key=$2
    value=$(sed -n \
        "s/^${key}[[:space:]]*=[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" \
        "$file")
    [ "$(printf '%s\n' "$value" | grep -c .)" -eq 1 ] ||
        die "$file has no unique $key integer"
    printf '%s\n' "$value"
}

make_work_dir() {
    temp_base=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
    [ -d "$temp_base" ] && [ -w "$temp_base" ] ||
        die "temporary build root is absent or not writable: $temp_base"
    mktemp -d "$temp_base/radeon-packaged-build.XXXXXX"
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --package)
            [ "$#" -ge 2 ] || die "--package requires a path"
            package_path=$2
            shift 2
            ;;
        --kernel-build-root)
            [ "$#" -ge 2 ] || die "--kernel-build-root requires a path"
            kernel_build_root=$2
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
    cp "$expected_profile" "$work/profile.toml"
    cmp "$expected_profile" "$work/profile.toml"
    printf '\nprofile = "mutated"\n' >>"$work/profile.toml"
    if cmp -s "$expected_profile" "$work/profile.toml"; then
        die "profile calibration accepts changed package policy"
    fi
    [ "$(toml_string "$expected_profile" compiled_ceiling)" = prod ] ||
        die "profile calibration resolves a non-production ceiling"
    [ "$(toml_integer "$expected_profile" kernel_build_interface)" -eq 1 ] ||
        die "profile calibration resolves the wrong build interface"
    printf 'packaged source compile calibration: PASS\n'
    exit 0
fi

[ -n "$package_path" ] || die "--package is required"
[ -n "$kernel_build_root" ] || die "--kernel-build-root is required"
[ -f "$package_path" ] && [ ! -L "$package_path" ] ||
    die "package is not a regular non-symlink file: $package_path"

package_name=$(toml_string "$expected_profile" package_name)
package_version=$(toml_string "$expected_profile" package_version)
package_release=$(toml_integer "$expected_profile" package_release)
expected_basename="${package_name}-${package_version}-${package_release}-x86_64.pkg.tar.zst"
[ "$(basename -- "$package_path")" = "$expected_basename" ] ||
    die "package basename is not $expected_basename"

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

work=$(make_work_dir)
trap 'rm -rf "$work"' EXIT INT TERM
package_root="$work/package-root"
mkdir -p "$package_root"
bsdtar -xf "$package_path" -C "$package_root"

special=$(find "$package_root" \
    \( -type b -o -type c -o -type p -o -type s -o -type l \) -print)
[ -z "$special" ] ||
    die "package contains a symbolic link or special file: $special"

grep -qx "pkgname = $package_name" "$package_root/.PKGINFO" ||
    die "package metadata names another package"
grep -qx "pkgver = ${package_version}-${package_release}" \
    "$package_root/.PKGINFO" ||
    die "package metadata carries another version"
grep -qx 'arch = x86_64' "$package_root/.PKGINFO" ||
    die "package metadata carries another architecture"

source_root="$package_root/usr/src/radeon-unified-${package_version}"
[ -d "$source_root/radeon" ] ||
    die "package omits the Radeon source directory"
cmp "$source_root/source-identity.toml" "$expected_identity" ||
    die "package source identity differs from the repository declaration"
cmp "$source_root/radeon-build-profile.toml" "$expected_profile" ||
    die "package build profile differs from the production declaration"
cmp "$source_root/radeon-build-profile.h" "$expected_header" ||
    die "package build header differs from the production declaration"
cmp "$source_root/dkms.conf" "$expected_dkms" ||
    die "package DKMS recipe differs from the production declaration"
cmp "$package_root/etc/modprobe.d/radeon-re.conf" "$expected_policy" ||
    die "package runtime policy differs from the production declaration"

for development_path in \
    "$package_root/etc/modprobe.d/radeon-unified-dev.conf" \
    "$package_root/usr/bin/radeon-profile-dev" \
    "$package_root/usr/share/radeon-unified/profiles"
do
    [ ! -e "$development_path" ] ||
        die "production package contains development surface: $development_path"
done

# radeon_trace.h records ../../drivers/gpu/drm/radeon as its trace include
# path. The package pre-build hook stages that relative path under a private
# include root before DKMS runs. This unprivileged compiler uses the same
# topology inside its disposable package extraction and leaves the kernel root
# read-only.
trace_shim_root="$source_root/.radeon-trace-include"
trace_shim_header="$trace_shim_root/drivers/gpu/drm/radeon/radeon_trace.h"
mkdir -p \
    "$trace_shim_root/include/trace" \
    "$(dirname -- "$trace_shim_header")"
install -m 0644 "$source_root/radeon/radeon_trace.h" "$trace_shim_header"
cmp "$source_root/radeon/radeon_trace.h" "$trace_shim_header" ||
    die "private trace shim differs from the packaged header"

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
    cd "$source_root/radeon"
    "$source_root/radeon-dkms-make" "$@" \
        RADEON_BUILD_PROFILE=prod \
        -C "$kernel_build_root" M="$PWD" modules
) >"$build_log" 2>&1 || build_status=$?
cat "$build_log"
[ "$build_status" -eq 0 ] ||
    { printf 'packaged Radeon build failed against %s\n' "$kernel_release" >&2; exit 4; }
[ -f "$source_root/radeon/radeon.ko" ] ||
    { printf 'radeon.ko is absent after build\n' >&2; exit 4; }
grep -q MODPOST "$build_log" ||
    { printf 'MODPOST is absent from build log\n' >&2; exit 4; }
scan_warnings "$build_log" ||
    exit 4
find "$source_root/radeon" -maxdepth 1 -type f -name '*_reg_safe.h' |
    grep -q . ||
    { printf 'generated register headers are absent\n' >&2; exit 4; }
[ -x "$source_root/radeon/mkregtable" ] ||
    { printf 'generated mkregtable is absent\n' >&2; exit 4; }

for metadata in \
    "gororoba_build_profile:$(toml_string "$expected_profile" compiled_ceiling)" \
    "gororoba_source_commit:$(toml_string "$expected_profile" source_commit)" \
    "gororoba_feature_policy_sha256:$(toml_string "$expected_profile" feature_policy_sha256)" \
    "gororoba_upstream_base:$(toml_string "$expected_profile" upstream_base)"
do
    field=${metadata%%:*}
    expected=${metadata#*:}
    actual=$(modinfo -F "$field" "$source_root/radeon/radeon.ko")
    [ "$actual" = "$expected" ] ||
        die "module metadata $field is $actual, expected $expected"
done

package_sha256=$(sha256sum "$package_path" | cut -d' ' -f1)
printf 'packaged production source build: PASS against %s\n' "$kernel_release"
printf 'package_sha256=%s\n' "$package_sha256"
