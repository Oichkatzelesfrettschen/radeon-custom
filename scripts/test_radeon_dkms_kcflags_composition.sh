#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
helper="$package_dir/radeon-dkms-make"

die() {
    printf 'test_radeon_dkms_kcflags_composition: %s\n' "$*" >&2
    exit 1
}

count_token() {
    local value=$1
    local token=$2
    local count=0
    local word
    for word in $value; do
        if [[ $word == "$token" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%d\n' "$count"
}

validate_capture() {
    local capture=$1
    local required_sentinel=$2
    local kcflags_value
    local cflags_value

    kcflags_value=$(sed -n 's/^KCFLAGS=//p' "$capture")
    cflags_value=$(sed -n 's/^CFLAGS=//p' "$capture")
    [[ -n $kcflags_value ]] || return 1
    if [[ -n $required_sentinel ]]; then
        [[ " $kcflags_value " == *" $required_sentinel "* ]] || return 1
        [[ $(count_token "$kcflags_value" "$required_sentinel") -eq 1 ]] ||
            return 1
    fi
    [[ $(count_token "$kcflags_value" -O2) -eq 1 ]] || return 1
    [[ $(count_token "$kcflags_value" -pipe) -eq 1 ]] || return 1
    [[ -z $cflags_value ]] || return 1
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat >"$tmpdir/bin/make" <<'EOF'
#!/bin/sh
set -eu
set -f
{
    printf 'KCFLAGS='
    for word in ${KCFLAGS-}; do
        printf '%s ' "$word"
    done
    printf '\n'
    printf 'CFLAGS=%s\n' "${CFLAGS-}"
    for argument in "$@"; do
        printf 'ARG=%s\n' "$argument"
    done
} >"$RADEON_DKMS_CAPTURE"
EOF
chmod 0755 "$tmpdir/bin/make"

run_helper_case() {
    local name=$1
    local incoming_kcflags=$2
    local sentinel=$3
    local capture="$tmpdir/$name.capture"
    local trace="$tmpdir/$name.trace"

    PATH="$tmpdir/bin:$PATH" \
        RADEON_DKMS_CAPTURE="$capture" \
        RADEON_DKMS_MAKE_TRACE=1 \
        KCFLAGS="$incoming_kcflags" \
        CFLAGS='-march=native -funsafe-math-optimizations' \
        "$helper" modules 2>"$trace"
    validate_capture "$capture" "$sentinel" ||
        die "$name does not preserve the KCFLAGS composition contract"
    grep -Fq "radeon-dkms-make: KCFLAGS=" "$trace" ||
        die "$name does not expose the opt-in KCFLAGS trace"
}

run_helper_case empty '' ''
run_helper_case multi_argument \
    '-DRADEON_CALLER_SENTINEL=1 -Wno-unused-parameter' \
    '-DRADEON_CALLER_SENTINEL=1'
run_helper_case required_flags_present \
    '-DRADEON_CALLER_SENTINEL=1 -O2 -pipe' \
    '-DRADEON_CALLER_SENTINEL=1'
run_helper_case repeated_spaces \
    '-DRADEON_CALLER_SENTINEL=1   -O2  -pipe' \
    '-DRADEON_CALLER_SENTINEL=1'

assert_helper_rejects() {
    local name=$1
    local incoming_kcflags=$2
    local diagnostic=$3

    if PATH="$tmpdir/bin:$PATH" \
            RADEON_DKMS_CAPTURE="$tmpdir/$name.capture" \
            KCFLAGS="$incoming_kcflags" \
            "$helper" modules 2>"$tmpdir/$name.trace"; then
        die "helper accepts unsafe KCFLAGS in $name"
    fi
    [[ ! -e $tmpdir/$name.capture ]] ||
        die "helper invokes make for rejected KCFLAGS in $name"
    grep -Fq -- "$diagnostic" "$tmpdir/$name.trace" ||
        die "helper rejection lacks its contract diagnostic in $name"
}

assert_helper_rejects quoted "-DVALUE='x -O2 y'" \
    'unsafe KCFLAGS token'
assert_helper_rejects shell_operator '-O2;id' \
    'unsafe KCFLAGS token'
assert_helper_rejects command_substitution '-DVALUE=$(id)' \
    'unsafe KCFLAGS token'
assert_helper_rejects backtick '-DVALUE=`id`' \
    'unsafe KCFLAGS token'
assert_helper_rejects tab $'-O2\t-pipe' \
    'must contain printable ASCII separated by spaces'
assert_helper_rejects newline $'-O2\n-pipe' \
    'must contain printable ASCII separated by spaces'
assert_helper_rejects duplicate_o2 '-O2 -O2' \
    'duplicate package KCFLAGS token: -O2'
assert_helper_rejects duplicate_pipe '-pipe -pipe' \
    'duplicate package KCFLAGS token: -pipe'
assert_helper_rejects duplicate_o2_mixed '-O2 -pipe -O2' \
    'duplicate package KCFLAGS token: -O2'

for optimization in -O -O0 -O1 -O3 -Og -Os -Oz -Ofast; do
    name="conflicting_${optimization#-}"
    assert_helper_rejects "$name" \
        "$optimization -DRADEON_CALLER_SENTINEL=1" \
        "conflicting optimization token: $optimization; package requires -O2"
done

calibration_good="$tmpdir/calibration-good"
cat >"$calibration_good" <<'EOF'
KCFLAGS=-DRADEON_CALLER_SENTINEL=1 -O2 -pipe
CFLAGS=
EOF
calibration_missing="$tmpdir/calibration-missing"
cat >"$calibration_missing" <<'EOF'
KCFLAGS=-O2 -pipe
CFLAGS=
EOF
calibration_duplicate="$tmpdir/calibration-duplicate"
cat >"$calibration_duplicate" <<'EOF'
KCFLAGS=-DRADEON_CALLER_SENTINEL=1 -O2 -pipe -pipe
CFLAGS=
EOF
calibration_duplicate_sentinel="$tmpdir/calibration-duplicate-sentinel"
cat >"$calibration_duplicate_sentinel" <<'EOF'
KCFLAGS=-DRADEON_CALLER_SENTINEL=1 -DRADEON_CALLER_SENTINEL=1 -O2 -pipe
CFLAGS=
EOF
calibration_cflags="$tmpdir/calibration-cflags"
cat >"$calibration_cflags" <<'EOF'
KCFLAGS=-DRADEON_CALLER_SENTINEL=1 -O2 -pipe
CFLAGS=-march=native
EOF

validate_capture "$calibration_good" '-DRADEON_CALLER_SENTINEL=1' ||
    die "capture validator rejects its known-good calibration"
if validate_capture "$calibration_missing" '-DRADEON_CALLER_SENTINEL=1'; then
    die "capture validator accepts a missing caller sentinel"
fi
if validate_capture "$calibration_duplicate" '-DRADEON_CALLER_SENTINEL=1'; then
    die "capture validator accepts a duplicate package flag"
fi
if validate_capture "$calibration_duplicate_sentinel" \
        '-DRADEON_CALLER_SENTINEL=1'; then
    die "capture validator accepts a duplicate caller flag"
fi
if validate_capture "$calibration_cflags" '-DRADEON_CALLER_SENTINEL=1'; then
    die "capture validator accepts userspace CFLAGS"
fi

run_dkms_recipe() {
    local config=$1
    local capture=$2
    local package_name
    local package_version
    local make_command
    local kernel_build_root="$tmpdir/kernel build"

    # shellcheck disable=SC2034
    kernelver=fixture-kernel
    dkms_tree="$tmpdir/dkms"
    # shellcheck disable=SC2034
    R300_RS480_KERNEL_BUILD_ROOT=$kernel_build_root
    # shellcheck source=/dev/null
    source "$config"
    unset R300_RS480_KERNEL_BUILD_ROOT
    package_name=$PACKAGE_NAME
    package_version=$PACKAGE_VERSION
    mkdir -p "$dkms_tree/$package_name/$package_version/build"
    cp "$helper" \
        "$dkms_tree/$package_name/$package_version/build/radeon-dkms-make"
    chmod 0755 \
        "$dkms_tree/$package_name/$package_version/build/radeon-dkms-make"
    make_command=${MAKE[0]}

    PATH="$tmpdir/bin:$PATH" \
        RADEON_DKMS_CAPTURE="$capture" \
        KCFLAGS='-DRADEON_CALLER_SENTINEL=1 -Werror=date-time' \
        CFLAGS='-march=native' \
        bash -c "$make_command"
    validate_capture "$capture" '-DRADEON_CALLER_SENTINEL=1' ||
        die "$config does not preserve the KCFLAGS composition contract"
    grep -Fxq "ARG=$kernel_build_root" "$capture" ||
        die "$config does not preserve a quoted kernel build root"
}

primary_capture="$tmpdir/primary.capture"
legacy_capture="$tmpdir/legacy.capture"
run_dkms_recipe "$package_dir/dkms.conf" "$primary_capture"
run_dkms_recipe \
    "$package_dir/dkms.conf.radeon-rs480-safe-regs-0.2" \
    "$legacy_capture"

primary_kcflags=$(sed -n 's/^KCFLAGS=//p' "$primary_capture")
legacy_kcflags=$(sed -n 's/^KCFLAGS=//p' "$legacy_capture")
[[ $primary_kcflags == "$legacy_kcflags" ]] ||
    die "the two DKMS recipes compose different KCFLAGS"

printf 'radeon DKMS KCFLAGS composition: PASS\n'
