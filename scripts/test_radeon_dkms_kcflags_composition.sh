#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2153
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
canonical_helper="$package_dir/radeon-dkms-make"

die() {
    printf 'test_radeon_dkms_kcflags_composition: %s\n' "$*" >&2
    exit 1
}

assert_pkgbuild_identity() {
    local config=$1
    local expected_pkgname=$2
    local expected_pkgver=$3
    local expected_pkgrel=$4
    local actual_pkgname
    local actual_pkgver
    local actual_pkgrel

    actual_pkgname=$(sed -n 's/^pkgbase=//p' "$config")
    if [[ -z $actual_pkgname ]]; then
        actual_pkgname=$(sed -n 's/^pkgname=//p' "$config")
    fi
    actual_pkgver=$(sed -n 's/^pkgver=//p' "$config")
    actual_pkgrel=$(sed -n 's/^pkgrel=//p' "$config")
    [[ $actual_pkgname == "$expected_pkgname" ]] ||
        die "$config has package identity $actual_pkgname, expected $expected_pkgname"
    [[ $actual_pkgver == "$expected_pkgver" ]] ||
        die "$config has package version $actual_pkgver, expected $expected_pkgver"
    [[ $actual_pkgrel == "$expected_pkgrel" ]] ||
        die "$config has package release $actual_pkgrel, expected $expected_pkgrel"
}

assert_pkgbuild_identity "$package_dir/PKGBUILD" \
    radeon-unified-dkms 0.8.9 2
assert_pkgbuild_identity \
    "$package_dir/PKGBUILD.radeon-rs480-safe-regs-0.2" \
    radeon-rs480-safe-regs-dkms 0.2 12

without_trace_include() {
    local value=$1
    local argument_capture="$tmpdir/without-trace.capture"
    local skip_profile=0
    local line
    local word

    make_kcflags_args "$value" >"$argument_capture" || return 1
    while IFS= read -r line; do
        [[ $line == ARG=* ]] || continue
        word=${line#ARG=}
        if [[ $skip_profile -eq 1 ]]; then
            skip_profile=0
            continue
        fi
        case "$word" in
            -I*/.radeon-trace-include/include/trace)
                continue
                ;;
            -include)
                skip_profile=1
                continue
                ;;
        esac
        printf '%s\n' "$word"
    done <"$argument_capture"
}

make_kcflags_args() {
    local value=$1

    env -u MAKE -u MAKE_COMMAND -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKEFILES \
        -u MAKEOVERRIDES \
        KCFLAGS="$value" make -s -f "$trace_include_makefile" capture
}

validate_capture() {
    local capture=$1
    local required_sentinel=$2
    local argument_capture="${capture}.args"
    local raw_kcflags
    local cflags_value
    local control_value
    local trace_include_count=0
    local profile_header_count=0
    local previous=
    local line
    local word

    raw_kcflags=$(sed -n 's/^KCFLAGS_RAW=//p' "$capture")
    if [[ -z $raw_kcflags ]]; then
        raw_kcflags=$(sed -n 's/^KCFLAGS=//p' "$capture")
    fi
    cflags_value=$(sed -n 's/^CFLAGS=//p' "$capture")
    [[ -n $raw_kcflags ]] || return 1
    make_kcflags_args "$raw_kcflags" >"$argument_capture"
    if [[ -n $required_sentinel ]]; then
        [[ $(grep -Fxc -- "ARG=$required_sentinel" "$argument_capture") -eq 1 ]] ||
            return 1
    fi
    [[ $(grep -Fxc -- 'ARG=-O2' "$argument_capture") -eq 1 ]] || return 1
    [[ $(grep -Fxc -- 'ARG=-pipe' "$argument_capture") -eq 1 ]] || return 1
    while IFS= read -r line; do
        [[ $line == ARG=* ]] || continue
        word=${line#ARG=}
        case "$word" in
            -I*/.radeon-trace-include/include/trace)
                trace_include_count=$((trace_include_count + 1))
                ;;
        esac
        if [[ $previous == -include &&
            $word == */radeon-build-profile.h ]]; then
            profile_header_count=$((profile_header_count + 1))
        fi
        previous=$word
    done <"$argument_capture"
    [[ $trace_include_count -eq 1 ]] || return 1
    [[ $profile_header_count -eq 1 ]] || return 1
    [[ -z $cflags_value ]] || return 1
    for variable in MAKE MAKE_COMMAND MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES MAKEOVERRIDES; do
        control_value=$(sed -n "s/^${variable}=//p" "$capture")
        [[ -z $control_value ]] || return 1
    done
    for variable in KBUILD_CPPFLAGS KBUILD_AFLAGS KBUILD_CFLAGS KBUILD_RUSTFLAGS \
        KBUILD_LDFLAGS KBUILD_EXTMOD KBUILD_OUTPUT KCPPFLAGS KAFLAGS KRUSTFLAGS \
        CC LD M MO O RUSTC RUSTDOC RUSTFMT BINDGEN LLVM LLVM_IAS LLVM_IAS_FLAGS \
        LLVM_SUFFIX LLVM_LINK SHELL; do
        ! grep -q "^${variable}=" "$capture" || return 1
    done
}

temp_root=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
created_temp_paths=()
tmpdir=

ensure_temp_root() {
    local path=$1
    local parent

    [[ -d $path ]] && return
    parent=$(dirname -- "$path")
    [[ $parent != "$path" ]] || die "cannot create temporary root $path"
    ensure_temp_root "$parent"
    mkdir -- "$path"
    created_temp_paths+=("$path")
}

cleanup() {
    local status=$?
    local index

    trap - EXIT
    if [[ -n ${tmpdir:-} && -d $tmpdir ]]; then
        rm -rf -- "$tmpdir" || true
    fi
    for ((index = ${#created_temp_paths[@]} - 1; index >= 0; index--)); do
        rmdir -- "${created_temp_paths[index]}" 2>/dev/null || true
    done
    exit "$status"
}

trap cleanup EXIT
ensure_temp_root "$temp_root"
tmpdir=$(mktemp -d "$temp_root/radeon-kcflags.XXXXXX")
mkdir -p "$tmpdir/bin"
helper="$tmpdir/radeon-dkms-make"
cp "$canonical_helper" "$helper"
cp "$package_dir/radeon-build-profile.prod.h" \
    "$tmpdir/radeon-build-profile.h"
cp "$package_dir/radeon-dkms-compiler" "$tmpdir/radeon-dkms-compiler"
chmod 0755 "$helper"
chmod 0755 "$tmpdir/radeon-dkms-compiler"
sh -n "$canonical_helper" ||
    die 'package Make wrapper fails the configured /bin/sh syntax check'
if grep -Eq \
    '^[[:space:]]*local[[:space:]]+(assignment_name|assignment_value)([[:space:]]|=|$)' \
    "$canonical_helper"; then
    die 'package Make wrapper uses non-POSIX local assignment declarations'
fi

cat >"$tmpdir/bin/make" <<'EOF'
#!/bin/sh
set -eu
set -f
{
    printf 'KCFLAGS_RAW=%s\n' "${KCFLAGS-}"
    printf 'KCFLAGS='
    for word in ${KCFLAGS-}; do
        printf '%s ' "$word"
    done
    printf '\n'
    printf 'CFLAGS=%s\n' "${CFLAGS-}"
    env | grep -E \
        '^(KBUILD_CPPFLAGS|KBUILD_AFLAGS|KBUILD_CFLAGS|KBUILD_RUSTFLAGS|KBUILD_LDFLAGS|KBUILD_EXTMOD|KBUILD_OUTPUT|KCPPFLAGS|KAFLAGS|KRUSTFLAGS|CC|LD|M|MO|O|RUSTC|RUSTDOC|RUSTFMT|BINDGEN|LLVM|LLVM_IAS|LLVM_IAS_FLAGS|LLVM_SUFFIX|LLVM_LINK|SHELL)=' \
        >>"$RADEON_DKMS_CAPTURE" || :
    printf 'MAKE=%s\n' "${MAKE-}"
    printf 'MAKE_COMMAND=%s\n' "${MAKE_COMMAND-}"
    printf 'MAKEFLAGS=%s\n' "${MAKEFLAGS-}"
    printf 'MFLAGS=%s\n' "${MFLAGS-}"
    printf 'GNUMAKEFLAGS=%s\n' "${GNUMAKEFLAGS-}"
    printf 'MAKEFILES=%s\n' "${MAKEFILES-}"
    printf 'MAKEOVERRIDES=%s\n' "${MAKEOVERRIDES-}"
    for argument in "$@"; do
        printf 'ARG=%s\n' "$argument"
    done
} >"$RADEON_DKMS_CAPTURE"
EOF
chmod 0755 "$tmpdir/bin/make"

trace_include_makefile="$tmpdir/trace-include.mk"
cat >"$trace_include_makefile" <<'EOF'
.PHONY: capture -f -E -I --include-dir
capture:
	@for word in $(KCFLAGS); do printf 'ARG=%s\n' "$$word"; done
-f:
	@printf 'TARGET=-f\n'
-E:
	@printf 'TARGET=-E\n'
-I:
	@printf 'TARGET=-I\n'
--include-dir:
	@printf 'TARGET=--include-dir\n'
EOF
actual_make_dir="$tmpdir/actual-make"
mkdir -p "$actual_make_dir"
cat >"$actual_make_dir/Makefile" <<'EOF'
KBUILD_CPPFLAGS += $(KCPPFLAGS)
KBUILD_AFLAGS += $(KAFLAGS)
.PHONY: capture -f -E -I --include-dir
capture:
	@printf 'KBUILD_CPPFLAGS=%s\n' "$(KBUILD_CPPFLAGS)" >/dev/null
	@for word in $(KCFLAGS); do printf 'ARG=%s\n' "$$word"; done
-f:
	@printf 'TARGET=-f\n'
-E:
	@printf 'TARGET=-E\n'
-I:
	@printf 'TARGET=-I\n'
--include-dir:
	@printf 'TARGET=--include-dir\n'
EOF
override_makefile="$tmpdir/override-makefile.mk"
cat >"$override_makefile" <<'EOF'
override KCFLAGS=-O3
.PHONY: capture
capture:
	@for word in $(KCFLAGS); do printf 'ARG=%s\n' "$$word"; done
EOF
include_dir_fixture="$tmpdir/include-directory"
mkdir -p "$include_dir_fixture"
cat >"$include_dir_fixture/Makefile" <<'EOF'
include injected.mk
.PHONY: capture
capture:
	@for word in $(KCFLAGS); do printf 'ARG=%s\n' "$$word"; done
EOF
cat >"$include_dir_fixture/injected.mk" <<'EOF'
override KCFLAGS=-O3
EOF
recursive_makefile="$tmpdir/recursive-Makefile"
cat >"$recursive_makefile" <<'EOF'
.PHONY: capture
capture:
	@$(MAKE) --no-print-directory -f Kbuild recurse
EOF
recursive_kbuild="$tmpdir/recursive-Kbuild"
cat >"$recursive_kbuild" <<'EOF'
.PHONY: recurse
recurse:
	@for word in $(KCFLAGS); do printf 'ARG=%s\n' "$$word"; done
EOF

run_helper_case() {
    local name=$1
    local incoming_kcflags=$2
    local sentinel=$3
    local incoming_makeoverrides=${4:-}
    local source_helper=${5:-$helper}
    local capture="$tmpdir/$name.capture"
    local trace="$tmpdir/$name.trace"

    PATH="$tmpdir/bin:$PATH" \
        RADEON_DKMS_CAPTURE="$capture" \
        RADEON_DKMS_MAKE_TRACE=1 \
        KCFLAGS="$incoming_kcflags" \
        CFLAGS='-march=native -funsafe-math-optimizations' \
        MAKE_COMMAND='/tmp/untrusted-make' \
        MAKEFLAGS='-j99' \
        MFLAGS='-k' \
        GNUMAKEFLAGS='-s' \
        MAKEFILES='/tmp/untrusted.mk' \
        MAKEOVERRIDES="$incoming_makeoverrides" \
        KBUILD_CPPFLAGS='$(eval override KCFLAGS=-O3)' \
        KBUILD_AFLAGS='-DUNTRUSTED_ASSEMBLY' \
        KBUILD_CFLAGS='-DUNTRUSTED_CFLAGS' \
        KBUILD_RUSTFLAGS='-DUNTRUSTED_RUST' \
        KBUILD_LDFLAGS='-Wl,-z,untrusted' \
        KBUILD_EXTMOD='/tmp/untrusted-extmod' \
        KBUILD_OUTPUT='/tmp/untrusted-output' \
        KCPPFLAGS='-DUNTRUSTED_CPPFLAGS' \
        KAFLAGS='-DUNTRUSTED_AFLAGS' \
        KRUSTFLAGS='-DUNTRUSTED_RUSTFLAGS' \
        CC='/tmp/untrusted-cc' \
        LD='/tmp/untrusted-ld' \
        M='/tmp/untrusted-module' \
        MO='/tmp/untrusted-module-output' \
        O='/tmp/untrusted-kernel-output' \
        SHELL='/tmp/untrusted-shell' \
        RUSTC='/tmp/untrusted-rustc' \
        RUSTDOC='/tmp/untrusted-rustdoc' \
        RUSTFMT='/tmp/untrusted-rustfmt' \
        BINDGEN='/tmp/untrusted-bindgen' \
        LLVM='1' \
        LLVM_IAS='0' \
        LLVM_IAS_FLAGS='-march=untrusted' \
        LLVM_SUFFIX='-untrusted' \
        LLVM_LINK='/tmp/untrusted-llvm-link' \
        "$source_helper" modules 2>"$trace"
    validate_capture "$capture" "$sentinel" ||
        die "$name does not preserve the KCFLAGS composition contract"
    grep -Fq "radeon-dkms-make: KCFLAGS=" "$trace" ||
        die "$name does not expose the opt-in KCFLAGS trace"
}

validate_spaced_trace_include() {
    local source_helper=$1
    local name=$2
    local fixture_dir="$tmpdir/$name helper path"
    local fixture_helper="$fixture_dir/radeon-dkms-make"
    local capture="$tmpdir/$name.spaced.capture"
    local raw_kcflags
    local argument_capture="$tmpdir/$name.spaced.args"
    local expected_trace="-I${fixture_dir}/.radeon-trace-include/include/trace"
    local expected_profile="${fixture_dir}/radeon-build-profile.h"

    mkdir -p "$fixture_dir"
    cp "$source_helper" "$fixture_helper"
    cp "$package_dir/radeon-build-profile.prod.h" \
        "$fixture_dir/radeon-build-profile.h"
    chmod 0755 "$fixture_helper"
    PATH="$tmpdir/bin:$PATH" \
        RADEON_DKMS_CAPTURE="$capture" \
        KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
        "$fixture_helper" modules 2>"$tmpdir/$name.spaced.trace"
    raw_kcflags=$(sed -n 's/^KCFLAGS_RAW=//p' "$capture")
    [[ -n $raw_kcflags ]] || return 1
    make_kcflags_args "$raw_kcflags" >"$argument_capture"
    grep -Fxq "ARG=$expected_trace" "$argument_capture" || return 1
    grep -Fxq 'ARG=-O2' "$argument_capture" || return 1
    grep -Fxq 'ARG=-pipe' "$argument_capture" || return 1
    grep -Fxq 'ARG=-include' "$argument_capture" || return 1
    grep -Fxq "ARG=$expected_profile" "$argument_capture" || return 1
}

run_actual_make_case() {
    local source_helper=$1
    local capture=$2
    local trace=$3
    local incoming_makeoverrides=$4
    shift 4

    (
        cd "$actual_make_dir"
        PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            MAKEOVERRIDES="$incoming_makeoverrides" \
            "$source_helper" "$@"
    ) >"$capture" 2>"$trace"
}

run_actual_make_environment_case() {
    local source_helper=$1
    local capture=$2
    local trace=$3
    local variable=$4
    local value=$5
    shift 5

    (
        cd "$actual_make_dir"
        env PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            MAKEOVERRIDES='' \
            "$variable=$value" \
            "$source_helper" "$@"
    ) >"$capture" 2>"$trace"
}

run_actual_make_include_case() {
    local source_helper=$1
    local capture=$2
    local trace=$3
    shift 3

    (
        cd "$include_dir_fixture"
        PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            MAKEOVERRIDES='' \
            "$source_helper" "$@"
    ) >"$capture" 2>"$trace"
}

run_actual_make_flags_case() {
    local source_helper=$1
    local capture=$2
    local trace=$3
    local incoming_makeflags=$4
    shift 4

    (
        cd "$actual_make_dir"
        PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            MAKEFLAGS="$incoming_makeflags" \
            "$source_helper" "$@"
    ) >"$capture" 2>"$trace"
}

run_actual_make_stdin_case() {
    local source_helper=$1
    local capture=$2
    local trace=$3
    local incoming_makeoverrides=$4
    shift 4

    (
        cd "$actual_make_dir"
        PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            MAKEOVERRIDES="$incoming_makeoverrides" \
            "$source_helper" "$@"
    ) <"$override_makefile" >"$capture" 2>"$trace"
}

prepare_recursive_fixture() {
    local fixture_dir=$1

    mkdir -p "$fixture_dir"
    cp "$canonical_helper" "$fixture_dir/radeon-dkms-make"
    cp "$recursive_makefile" "$fixture_dir/Makefile"
    cp "$recursive_kbuild" "$fixture_dir/Kbuild"
    chmod 0755 "$fixture_dir/radeon-dkms-make"
}

run_recursive_make_case() {
    local source_helper=$1
    local fixture_dir=$2
    local capture=$3
    local trace=$4
    shift 4
    if [ "$#" -eq 0 ]; then
        set -- capture
    fi

    (
        cd "$fixture_dir"
        PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            "$source_helper" "$@"
    ) >"$capture" 2>"$trace"
}

run_recursive_make_environment_case() {
    local source_helper=$1
    local fixture_dir=$2
    local capture=$3
    local trace=$4
    local incoming_make=$5
    shift 5
    if [ "$#" -eq 0 ]; then
        set -- capture
    fi

    (
        cd "$fixture_dir"
        PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            MAKE="$incoming_make" \
            RADEON_FAKE_MAKE_MARKER="${RADEON_FAKE_MAKE_MARKER-}" \
            "$source_helper" "$@"
    ) >"$capture" 2>"$trace"
}

run_recursive_make_command_case() {
    local source_helper=$1
    local fixture_dir=$2
    local capture=$3
    local trace=$4
    local incoming_make_command=$5
    shift 5
    if [ "$#" -eq 0 ]; then
        set -- capture
    fi

    (
        cd "$fixture_dir"
        PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            MAKE_COMMAND="$incoming_make_command" \
            RADEON_FAKE_MAKE_MARKER="${RADEON_FAKE_MAKE_MARKER-}" \
            "$source_helper" "$@"
    ) >"$capture" 2>"$trace"
}

run_recursive_makeoverrides_case() {
    local source_helper=$1
    local fixture_dir=$2
    local capture=$3
    local trace=$4
    local incoming_makeoverrides=$5
    shift 5
    if [ "$#" -eq 0 ]; then
        set -- capture
    fi

    (
        cd "$fixture_dir"
        PATH=/usr/bin:/bin \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            MAKEOVERRIDES="$incoming_makeoverrides" \
            "$source_helper" "$@"
    ) >"$capture" 2>"$trace"
}

run_recursive_fake_make_case() {
    local source_helper=$1
    local fixture_dir=$2
    local capture=$3
    local trace=$4

    (
        cd "$fixture_dir"
        PATH="$tmpdir/bin:$PATH" \
            RADEON_DKMS_CAPTURE="$capture" \
            KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
            "$source_helper" capture
    ) >"$capture.stdout" 2>"$trace"
}

validate_recursive_capture() {
    local fixture_dir=$1
    local capture=$2
    local expected_trace="-I${fixture_dir}/.radeon-trace-include/include/trace"

    grep -Fxq 'ARG=-DRADEON_CALLER_SENTINEL=1' "$capture" || return 1
    grep -Fxq 'ARG=-O2' "$capture" || return 1
    grep -Fxq 'ARG=-pipe' "$capture" || return 1
    grep -Fxq "ARG=$expected_trace" "$capture" || return 1
    ! grep -Fxq 'ARG=-O3' "$capture"
}

assert_dollar_path_rejected() {
    local name=$1
    local fixture_dir=$2
    local marker=$3
    local capture="$tmpdir/$name.fake.capture"
    local trace="$tmpdir/$name.fake.trace"
    local helper_path="$fixture_dir/radeon-dkms-make"

    if run_recursive_fake_make_case "$helper_path" "$fixture_dir" \
        "$capture" "$trace"; then
        die "helper accepts dollar-bearing package path in $name"
    fi
    grep -Fxq \
        "radeon-dkms-make: package paths must not contain '\$'" \
        "$trace" || die "dollar-path rejection diagnostic is wrong in $name"
    [[ ! -e $capture ]] ||
        die "helper invokes Make for dollar-bearing package path in $name"
    [[ ! -e $marker ]] ||
        die "dollar-bearing package path executes its marker in $name"
}

assert_recursive_path_mutant_executes() {
    local name=$1
    local fixture_dir=$2
    local marker=$3
    local mutant_helper="$fixture_dir/radeon-dkms-make"
    local capture="$tmpdir/$name.mutant.capture"
    local trace="$tmpdir/$name.mutant.trace"

    cp "$raw_recursive_path_mutant" "$mutant_helper"
    chmod 0755 "$mutant_helper"
    if ! run_recursive_make_case "$mutant_helper" "$fixture_dir" \
        "$capture" "$trace"; then
        die "recursive dollar-path mutant does not run in $name"
    fi
    [[ -e $marker ]] ||
        die "recursive dollar-path mutant does not execute its marker in $name"
}

assert_recursive_literal_mutant_corrupts_path() {
    local fixture_dir=$1
    local mutant_helper="$fixture_dir/radeon-dkms-make"
    local capture="$tmpdir/literal-dollar.mutant.capture"
    local trace="$tmpdir/literal-dollar.mutant.trace"

    cp "$raw_recursive_path_mutant" "$mutant_helper"
    chmod 0755 "$mutant_helper"
    if ! run_recursive_make_case "$mutant_helper" "$fixture_dir" \
        "$capture" "$trace"; then
        die 'recursive literal-dollar mutant does not run'
    fi
    grep -q '^ARG=' "$capture" ||
        die 'recursive literal-dollar mutant does not reach Kbuild'
    ! grep -Fq 'literal$path' "$capture" ||
        die 'recursive literal-dollar mutant preserves unsafe Make syntax'
}

validate_actual_make_capture() {
    local capture=$1
    local expected_trace="-I${tmpdir}/.radeon-trace-include/include/trace"
    local expected_profile="${tmpdir}/radeon-build-profile.h"

    [[ $(grep -Fxc -- 'ARG=-DRADEON_CALLER_SENTINEL=1' "$capture") -eq 1 ]] ||
        return 1
    [[ $(grep -Fxc -- 'ARG=-O2' "$capture") -eq 1 ]] || return 1
    [[ $(grep -Fxc -- 'ARG=-pipe' "$capture") -eq 1 ]] || return 1
    grep -Fxq "ARG=$expected_trace" "$capture" || return 1
    grep -Fxq 'ARG=-include' "$capture" || return 1
    grep -Fxq "ARG=$expected_profile" "$capture" || return 1
    ! grep -Fxq 'ARG=-O3' "$capture"
}

assert_actual_make_rejects_arguments() {
    local name=$1
    local diagnostic=$2
    shift 2
    local capture="$tmpdir/$name.actual.capture"
    local trace="$tmpdir/$name.actual.trace"

    if run_actual_make_case "$helper" "$capture" "$trace" '' "$@"; then
        die "helper accepts reserved GNU Make argv in $name"
    fi
    grep -Fq -- "$diagnostic" "$trace" ||
        die "helper rejection lacks its GNU Make option diagnostic in $name"
}

assert_mutant_make_bypass() {
    local name=$1
    shift
    local capture="$tmpdir/$name.mutant.capture"
    local trace="$tmpdir/$name.mutant.trace"

    if ! run_actual_make_case "$commandline_mutant" "$capture" "$trace" '' "$@"; then
        die "GNU Make known-bad mutant does not run in $name"
    fi
    grep -Fxq 'ARG=-O3' "$capture" ||
        die "GNU Make known-bad mutant does not reproduce the bypass in $name"
}

assert_expanded_assignment_mutant_bypass() {
    local name=$1
    shift
    local capture="$tmpdir/$name.expanded-assignment.mutant.capture"
    local trace="$tmpdir/$name.expanded-assignment.mutant.trace"

    if ! run_actual_make_case "$expanded_assignment_mutant" \
        "$capture" "$trace" '' "$@"; then
        die "GNU Make expanded-assignment mutant does not run in $name"
    fi
    grep -Fxq 'ARG=-O3' "$capture" ||
        die "GNU Make expanded-assignment mutant does not reproduce the bypass in $name"
}

assert_assignment_value_mutant_bypass() {
    local name=$1
    shift
    local capture="$tmpdir/$name.assignment-value.mutant.capture"
    local trace="$tmpdir/$name.assignment-value.mutant.trace"

    if ! run_actual_make_case "$assignment_value_mutant" \
        "$capture" "$trace" '' "$@"; then
        die "GNU Make assignment-value mutant does not run in $name"
    fi
    grep -Fxq 'ARG=-O3' "$capture" ||
        die "GNU Make assignment-value mutant does not reproduce the bypass in $name"
}

assert_shell_assignment_mutant_executes() {
    local name=$1
    shift
    local marker="$tmpdir/$name.shell-assignment.mutant.marker"
    local capture="$tmpdir/$name.shell-assignment.mutant.capture"
    local trace="$tmpdir/$name.shell-assignment.mutant.trace"

    if ! run_actual_make_case "$shell_assignment_mutant" \
        "$capture" "$trace" '' "$@" \
        "PROBE!=printf exploited >$marker" capture; then
        die "GNU Make shell-assignment mutant does not run in $name"
    fi
    [[ -e $marker ]] ||
        die "GNU Make shell-assignment mutant does not execute its probe in $name"
}

assert_safe_assignment_value() {
    local name=$1
    local assignment=$2
    local capture="$tmpdir/$name.safe-assignment.capture"
    local trace="$tmpdir/$name.safe-assignment.trace"

    run_actual_make_case "$helper" "$capture" "$trace" '' \
        "$assignment" -s capture
    validate_actual_make_capture "$capture" ||
        die "safe assignment value changes KCFLAGS in $name"
}

assert_actual_make_include_rejects_arguments() {
    local name=$1
    shift
    local capture="$tmpdir/$name.include.actual.capture"
    local trace="$tmpdir/$name.include.actual.trace"

    if run_actual_make_include_case "$helper" "$capture" "$trace" "$@"; then
        die "helper accepts reserved GNU Make include-directory option in $name"
    fi
    grep -Fq -- \
        'radeon-dkms-make: GNU Make include-directory options are reserved' \
        "$trace" ||
        die "helper include-directory rejection lacks its diagnostic in $name"
}

assert_mutant_make_include_bypass() {
    local name=$1
    shift
    local capture="$tmpdir/$name.include.mutant.capture"
    local trace="$tmpdir/$name.include.mutant.trace"

    if ! run_actual_make_include_case "$commandline_mutant" \
        "$capture" "$trace" "$@"; then
        die "GNU Make include-directory known-bad mutant does not run in $name"
    fi
    grep -Fxq 'ARG=-O3' "$capture" ||
        die "GNU Make include-directory known-bad mutant does not reproduce the bypass in $name"
}

assert_actual_make_stdin_rejects_arguments() {
    local name=$1
    local diagnostic=$2
    shift 2
    local capture="$tmpdir/$name.stdin.actual.capture"
    local trace="$tmpdir/$name.stdin.actual.trace"

    if run_actual_make_stdin_case "$helper" "$capture" "$trace" '' "$@"; then
        die "helper accepts reserved GNU Make stdin selector in $name"
    fi
    grep -Fq -- "$diagnostic" "$trace" ||
        die "helper stdin rejection lacks its GNU Make option diagnostic in $name"
}

assert_mutant_make_stdin_bypass() {
    local name=$1
    shift
    local capture="$tmpdir/$name.stdin.mutant.capture"
    local trace="$tmpdir/$name.stdin.mutant.trace"

    if ! run_actual_make_stdin_case "$commandline_mutant" "$capture" \
        "$trace" '' "$@"; then
        die "GNU Make stdin known-bad mutant does not run in $name"
    fi
    grep -Fxq 'ARG=-O3' "$capture" ||
        die "GNU Make stdin known-bad mutant does not reproduce the bypass in $name"
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
run_helper_case inherited_makeoverrides \
    '-DRADEON_CALLER_SENTINEL=1' \
    '-DRADEON_CALLER_SENTINEL=1' \
    'KCFLAGS=-O3'

validate_spaced_trace_include "$canonical_helper" spaced_trace_include ||
    die 'spaced private trace include loses its single KCFLAGS argument'
raw_trace_include_mutant="$tmpdir/raw-trace-include-mutant"
sed 's#-I${trace_include_for_make}#-I${trace_include}#' \
    "$canonical_helper" >"$raw_trace_include_mutant"
chmod 0755 "$raw_trace_include_mutant"
if validate_spaced_trace_include "$raw_trace_include_mutant" \
    raw_trace_include_mutant; then
    die 'raw private trace include mutant passes the spaced-path calibration'
fi
raw_recursive_path_mutant="$tmpdir/raw-recursive-path-mutant"
sed \
    -e 's#trace_include_for_make=$(encode_make_path "$trace_include")#trace_include_for_make=$trace_include#' \
    -e 's#profile_header_for_make=$(encode_make_path "$profile_header")#profile_header_for_make=$profile_header#' \
    -e 's#-I${trace_include_for_make}#-I${trace_include}#' \
    "$canonical_helper" >"$raw_recursive_path_mutant"
chmod 0755 "$raw_recursive_path_mutant"

supported_recursive_fixture="$tmpdir/supported recursive helper path"
prepare_recursive_fixture "$supported_recursive_fixture"
run_recursive_make_case \
    "$supported_recursive_fixture/radeon-dkms-make" \
    "$supported_recursive_fixture" \
    "$tmpdir/supported-recursive.capture" \
    "$tmpdir/supported-recursive.trace"
validate_recursive_capture "$supported_recursive_fixture" \
    "$tmpdir/supported-recursive.capture" ||
    die 'recursive Kbuild loses its supported spaced path token'
fake_make_marker="$tmpdir/inherited-make.marker"
fake_make="$tmpdir/inherited-make"
cat >"$fake_make" <<'EOF'
#!/bin/sh
printf '%s\n' invoked >"$RADEON_FAKE_MAKE_MARKER"
exit 1
EOF
chmod 0755 "$fake_make"
if ! RADEON_FAKE_MAKE_MARKER="$fake_make_marker" \
    run_recursive_make_environment_case \
    "$supported_recursive_fixture/radeon-dkms-make" \
    "$supported_recursive_fixture" \
    "$tmpdir/inherited-make.capture" \
    "$tmpdir/inherited-make.trace" \
    "$fake_make" capture; then
    die 'inherited MAKE prevents recursive Kbuild execution'
fi
validate_recursive_capture "$supported_recursive_fixture" \
    "$tmpdir/inherited-make.capture" ||
    die 'inherited MAKE changes the recursive KCFLAGS composition'
[[ ! -e $fake_make_marker ]] ||
    die 'inherited MAKE executes its caller-controlled replacement'
fake_make_command_marker="$tmpdir/inherited-make-command.marker"
if ! RADEON_FAKE_MAKE_MARKER="$fake_make_command_marker" \
    run_recursive_make_command_case \
    "$supported_recursive_fixture/radeon-dkms-make" \
    "$supported_recursive_fixture" \
    "$tmpdir/inherited-make-command.capture" \
    "$tmpdir/inherited-make-command.trace" \
    "$fake_make" capture; then
    die 'inherited MAKE_COMMAND prevents recursive Kbuild execution'
fi
validate_recursive_capture "$supported_recursive_fixture" \
    "$tmpdir/inherited-make-command.capture" ||
    die 'inherited MAKE_COMMAND changes the recursive KCFLAGS composition'
[[ ! -e $fake_make_command_marker ]] ||
    die 'inherited MAKE_COMMAND executes its caller-controlled replacement'
single_quote_recursive_fixture="$tmpdir/single'quote recursive path"
prepare_recursive_fixture "$single_quote_recursive_fixture"
run_recursive_make_case \
    "$single_quote_recursive_fixture/radeon-dkms-make" \
    "$single_quote_recursive_fixture" \
    "$tmpdir/single-quote-recursive.capture" \
    "$tmpdir/single-quote-recursive.trace"
validate_recursive_capture "$single_quote_recursive_fixture" \
    "$tmpdir/single-quote-recursive.capture" ||
    die 'recursive Kbuild loses its supported single-quote path token'

shell_marker_fixture="$tmpdir/\$(shell touch marker-shell)"
prepare_recursive_fixture "$shell_marker_fixture"
assert_dollar_path_rejected shell_dollar_path \
    "$shell_marker_fixture" "$shell_marker_fixture/marker-shell"
assert_recursive_path_mutant_executes shell_dollar_path \
    "$shell_marker_fixture" "$shell_marker_fixture/marker-shell"
braced_marker_fixture="$tmpdir/\${shell touch marker-braced}"
prepare_recursive_fixture "$braced_marker_fixture"
assert_dollar_path_rejected braced_dollar_path \
    "$braced_marker_fixture" "$braced_marker_fixture/marker-braced"
assert_recursive_path_mutant_executes braced_dollar_path \
    "$braced_marker_fixture" "$braced_marker_fixture/marker-braced"
literal_dollar_fixture="$tmpdir/literal\$path"
prepare_recursive_fixture "$literal_dollar_fixture"
assert_dollar_path_rejected literal_dollar_path \
    "$literal_dollar_fixture" "$literal_dollar_fixture/marker-unused"
assert_recursive_literal_mutant_corrupts_path "$literal_dollar_fixture"

makeoverrides_capture="$tmpdir/makeoverrides.capture"
makeoverrides_trace="$tmpdir/makeoverrides.trace"
run_actual_make_case "$helper" "$makeoverrides_capture" \
    "$makeoverrides_trace" 'KCFLAGS=-O3' \
    -s capture
validate_actual_make_capture "$makeoverrides_capture" ||
    die 'inherited MAKEOVERRIDES replaces the package KCFLAGS'
makeoverrides_mutant="$tmpdir/makeoverrides-mutant"
sed '/^unset MAKE MAKE_COMMAND MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES MAKEOVERRIDES$/s/ MAKEOVERRIDES$//' \
    "$canonical_helper" >"$makeoverrides_mutant"
chmod 0755 "$makeoverrides_mutant"
makeoverrides_mutant_capture="$tmpdir/makeoverrides-mutant.capture"
makeoverrides_mutant_trace="$tmpdir/makeoverrides-mutant.trace"
if ! run_recursive_makeoverrides_case "$makeoverrides_mutant" \
    "$supported_recursive_fixture" \
    "$makeoverrides_mutant_capture" \
    "$makeoverrides_mutant_trace" 'KCFLAGS=-O3' \
    -s capture ||
    ! grep -Fxq 'ARG=-O3' "$makeoverrides_mutant_capture"; then
    die 'recursive MAKEOVERRIDES known-bad mutant does not reproduce the override bypass'
fi
makeoverrides_file_capture="$tmpdir/makeoverrides-file.capture"
makeoverrides_file_trace="$tmpdir/makeoverrides-file.trace"
run_actual_make_case "$helper" "$makeoverrides_file_capture" \
    "$makeoverrides_file_trace" "-f$override_makefile" \
    -s capture
validate_actual_make_capture "$makeoverrides_file_capture" ||
    die 'inherited MAKEOVERRIDES makefile selector replaces package KCFLAGS'
makeflags_capture="$tmpdir/makeflags.capture"
makeflags_trace="$tmpdir/makeflags.trace"
run_actual_make_flags_case "$helper" "$makeflags_capture" \
    "$makeflags_trace" "-f$override_makefile" -s capture
validate_actual_make_capture "$makeflags_capture" ||
    die 'inherited MAKEFLAGS makefile selector replaces package KCFLAGS'
kbuild_environment_capture="$tmpdir/kbuild-environment.capture"
kbuild_environment_trace="$tmpdir/kbuild-environment.trace"
run_actual_make_environment_case "$helper" "$kbuild_environment_capture" \
    "$kbuild_environment_trace" KBUILD_CPPFLAGS \
    '$(eval override KCFLAGS=-O3)' -e -s capture
validate_actual_make_capture "$kbuild_environment_capture" ||
    die 'inherited KBUILD_CPPFLAGS changes the package KCFLAGS composition'
kbuild_environment_mutant="$tmpdir/kbuild-environment-mutant"
sed '/^unset KBUILD_CPPFLAGS$/d' "$canonical_helper" \
    >"$kbuild_environment_mutant"
chmod 0755 "$kbuild_environment_mutant"
kbuild_environment_mutant_capture="$tmpdir/kbuild-environment-mutant.capture"
kbuild_environment_mutant_trace="$tmpdir/kbuild-environment-mutant.trace"
if ! run_actual_make_environment_case "$kbuild_environment_mutant" \
    "$kbuild_environment_mutant_capture" \
    "$kbuild_environment_mutant_trace" KBUILD_CPPFLAGS \
    '$(eval override KCFLAGS=-O3)' -e -s capture ||
    ! grep -Fxq 'ARG=-O3' "$kbuild_environment_mutant_capture"; then
    die 'inherited KBUILD_CPPFLAGS known-bad mutant does not reproduce the override bypass'
fi
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

assert_helper_rejects_arguments() {
    local name=$1
    local diagnostic=$2
    shift 2

    if PATH="$tmpdir/bin:$PATH" \
        RADEON_DKMS_CAPTURE="$tmpdir/$name.capture" \
        KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
        "$helper" "$@" modules 2>"$tmpdir/$name.trace"; then
        die "helper accepts reserved command-line KCFLAGS in $name"
    fi
    [[ ! -e $tmpdir/$name.capture ]] ||
        die "helper invokes make for reserved command-line KCFLAGS in $name"
    grep -Fq -- "$diagnostic" "$tmpdir/$name.trace" ||
        die "helper rejection lacks its contract diagnostic in $name"
}

assert_helper_preserves_make_arguments() {
    local name=$1
    shift
    local capture="$tmpdir/$name.capture"
    local trace="$tmpdir/$name.trace"
    local argument

    PATH="$tmpdir/bin:$PATH" \
        RADEON_DKMS_CAPTURE="$capture" \
        KCFLAGS='-DRADEON_CALLER_SENTINEL=1' \
        "$helper" "$@" 2>"$trace"
    for argument in "$@"; do
        grep -Fxq "ARG=$argument" "$capture" ||
            die "helper drops legitimate Make argument $argument in $name"
    done
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
assert_helper_rejects reserved_trace_include \
    '-I/tmp/.radeon-trace-include/include/trace' \
    'caller KCFLAGS contains the reserved trace include'
assert_helper_rejects reserved_profile_include \
    '-include /tmp/radeon-build-profile.h' \
    'caller KCFLAGS contains the reserved build profile'

for assignment in 'KCFLAGS=-O3' 'KCFLAGS+=-O3' 'KCFLAGS:=-O3' \
    'KCFLAGS::=-O3' 'KCFLAGS:::= -O3' 'KCFLAGS?=-O3' 'KCFLAGS!=-O3'; do
    assignment_name=${assignment%%=*}
    assignment_name=${assignment_name//[^A-Za-z0-9]/_}
    assert_helper_rejects_arguments "reserved_argument_${assignment_name}" \
        'command-line package-controlled variable assignment is reserved' \
        "$assignment"
done
for variable in MAKE MAKE_COMMAND MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKEFILES \
    CFLAGS CPPFLAGS CXXFLAGS LDFLAGS; do
    assert_helper_rejects_arguments "reserved_argument_${variable}" \
        'command-line package-controlled variable assignment is reserved' \
        "${variable}=KCFLAGS=-O3"
done
assert_helper_rejects_arguments reserved_make_assignment \
    'command-line package-controlled variable assignment is reserved' \
    MAKE=make
assert_helper_rejects_arguments reserved_make_command_assignment \
    'command-line package-controlled variable assignment is reserved' \
    MAKE_COMMAND=make
assert_helper_rejects_arguments reserved_shell_assignment \
    'command-line package-controlled variable assignment is reserved' \
    SHELL=/bin/sh
assert_helper_rejects_arguments shell_assignment_operator \
    'command-line shell assignment operators are reserved' \
    'PROBE!=printf exploited >PATH'
computed_assignment_values=(
    'KC$()FLAGS=-O3'
    'K$()CFLAGS=-O3'
    '$(empty)KCFLAGS=-O3'
)
for assignment in "${computed_assignment_values[@]}"; do
    assignment_name=${assignment%%=*}
    assignment_name=${assignment_name//[^A-Za-z0-9]/_}
    assert_helper_rejects_arguments \
        "expanded_argument_${assignment_name}" \
        'command-line assignment names must not use GNU Make expansion syntax' \
        "$assignment"
done
safe_assignment_values=(
    'V=1'
    'W=1'
)
for assignment in "${safe_assignment_values[@]}"; do
    assignment_name=${assignment%%=*}
    assignment_name=${assignment_name//[^A-Za-z0-9]/_}
    assert_helper_preserves_make_arguments \
        "safe_argument_${assignment_name}" "$assignment"
    assert_safe_assignment_value \
        "safe_argument_${assignment_name}" "$assignment"
done
for assignment in \
    'M=/tmp/radeon-module' \
    'R300_RS480_KERNEL_BUILD_ROOT=/tmp/kernel build' \
    'RADEON_BUILD_PROFILE=prod' \
    'KERNELRELEASE=6.18.42-1-cachyos-lts' \
    'LLVM=1' \
    "CC=$tmpdir/radeon-dkms-compiler"; do
    assignment_name=${assignment%%=*}
    assert_helper_preserves_make_arguments \
        "package_argument_${assignment_name}" "$assignment"
done
reserved_assignment_values=(
    'M=/tmp/radeon;touch'
    'M=/tmp/radeon`touch`'
    'R300_RS480_KERNEL_BUILD_ROOT=/tmp/kernel>output'
    'KCFLAGS=-O3'
    'KCFLAGS+=-O3'
    'KCFLAGS:=-O3'
    'KCFLAGS::=-O3'
    'KCFLAGS:::= -O3'
    'KCFLAGS?=-O3'
    'KCFLAGS!=-O3'
    'KBUILD_CPPFLAGS=-DNAME=VALUE'
    'KBUILD_CPPFLAGS+=-DSECOND=VALUE'
    'KCPPFLAGS=-DUNTRUSTED'
    'KAFLAGS=-DUNTRUSTED'
    'LLVM=0'
    'CC=/tmp/untrusted-cc'
    'RADEON_BUILD_PROFILE=mutate-dev'
)
for variable in MAKE MAKE_COMMAND MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKEFILES \
    CFLAGS CPPFLAGS CXXFLAGS LDFLAGS; do
    reserved_assignment_values+=("${variable}=KCFLAGS=-O3")
done
leading_assignment_whitespace=(' ' $'\t' $'\n' $'\r' $'\v' $'\f' $' \t\n\r\v\f')
leading_assignment_names=(space tab newline carriage_return vertical_tab form_feed mixed)
for whitespace_index in "${!leading_assignment_whitespace[@]}"; do
    whitespace=${leading_assignment_whitespace[whitespace_index]}
    whitespace_name=${leading_assignment_names[whitespace_index]}
    for assignment in "${reserved_assignment_values[@]}"; do
        assignment_name=${assignment%%=*}
        assignment_name=${assignment_name//[^A-Za-z0-9]/_}
        assert_helper_rejects_arguments \
            "reserved_leading_${whitespace_name}_${assignment_name}" \
            'command-line package-controlled variable assignment is reserved' \
            "${whitespace}${assignment}"
    done
done
assert_helper_rejects_arguments reserved_eval_equals \
    'GNU Make eval options are reserved' \
    '--eval=KCFLAGS=-O3'
assert_helper_rejects_arguments reserved_eval_separate \
    'GNU Make eval options are reserved' \
    --eval 'KCFLAGS=-O3'
assert_helper_rejects_arguments reserved_eval_override \
    'GNU Make eval options are reserved' \
    --eval 'override KCFLAGS=-O3'
assert_helper_rejects_arguments reserved_eval_leading_space \
    'GNU Make eval options are reserved' \
    --eval ' KCFLAGS=-O3'
assert_helper_rejects_arguments reserved_eval_newline \
    'GNU Make eval options are reserved' \
    --eval $'\nKCFLAGS=-O3'
assert_helper_rejects_arguments reserved_eval_define \
    'GNU Make eval options are reserved' \
    --eval $'define KCFLAGS\n-O3\nendef'
assert_helper_preserves_make_arguments old_file_option -oEfile -s
assert_helper_preserves_make_arguments output_sync_option -OE -s
assert_helper_preserves_make_arguments warn_undefined_variables \
    --warn-undefined-variables -s
assert_helper_preserves_make_arguments what_if_option \
    --what-if=Makefile -s
assert_helper_preserves_make_arguments shuffle_option --shuffle -s
assert_helper_rejects_arguments reserved_include_directory_short_attached \
    'GNU Make include-directory options are reserved' \
    -I/usr/include/f -s
assert_helper_rejects_arguments reserved_include_directory_short_separate \
    'GNU Make include-directory options are reserved' \
    -I /usr/include/f -s
for include_option in --in --inc --incl --inclu --includ --include \
    --include- --include-d --include-di --include-dir; do
    include_name=${include_option#--}
    assert_helper_rejects_arguments "reserved_${include_name}_include_equals" \
        'GNU Make include-directory options are reserved' \
        "${include_option}=/usr/include/f" -s
    assert_helper_rejects_arguments "reserved_${include_name}_include_separate" \
        'GNU Make include-directory options are reserved' \
        "$include_option" /usr/include/f -s
done

commandline_mutant="$tmpdir/commandline-mutant"
sed '/^for argument in "\$@"; do$/,/^done$/d' \
    "$canonical_helper" >"$commandline_mutant"
chmod 0755 "$commandline_mutant"
expanded_assignment_mutant="$tmpdir/expanded-assignment-mutant"
sed -e '/^[[:space:]]*reject_expanded_assignment_name$/d' \
    -e 's/^\([[:space:]]*\)validate_package_assignment$/\1:/' \
    "$canonical_helper" >"$expanded_assignment_mutant"
chmod 0755 "$expanded_assignment_mutant"
assignment_value_mutant="$tmpdir/assignment-value-mutant"
sed -e '/^[[:space:]]*reject_expanded_assignment_value$/d' \
    -e 's/^\([[:space:]]*\)validate_package_assignment$/\1:/' \
    "$canonical_helper" >"$assignment_value_mutant"
chmod 0755 "$assignment_value_mutant"
shell_assignment_mutant="$tmpdir/shell-assignment-mutant"
sed -e 's/^\([[:space:]]*\)reject_shell_assignment$/\1:/' \
    -e 's/^\([[:space:]]*\)validate_package_assignment$/\1:/' \
    -e 's/ HOSTCC HOSTCXX RUSTC SHELL M MO O$/ HOSTCC HOSTCXX RUSTC M MO O/' \
    -e 's/ LLVM_IAS_FLAGS LLVM_SUFFIX LLVM_LINK SHELL M MO O$/ LLVM_IAS_FLAGS LLVM_SUFFIX LLVM_LINK M MO O/' \
    "$canonical_helper" >"$shell_assignment_mutant"
chmod 0755 "$shell_assignment_mutant"

post_terminator_capture="$tmpdir/post-terminator.capture"
post_terminator_trace="$tmpdir/post-terminator.trace"
run_actual_make_case "$helper" "$post_terminator_capture" \
    "$post_terminator_trace" '' -- -f -E capture
validate_actual_make_capture "$post_terminator_capture" ||
    die 'post-terminator targets change the KCFLAGS composition'
grep -Fxq 'TARGET=-f' "$post_terminator_capture" ||
    die 'post-terminator -f target is misclassified as a Makefile selector'
grep -Fxq 'TARGET=-E' "$post_terminator_capture" ||
    die 'post-terminator -E target is misclassified as an eval option'
post_terminator_include_capture="$tmpdir/post-terminator-include.capture"
post_terminator_include_trace="$tmpdir/post-terminator-include.trace"
run_actual_make_case "$helper" "$post_terminator_include_capture" \
    "$post_terminator_include_trace" '' -s -- -I capture
grep -Fxq 'TARGET=-I' "$post_terminator_include_capture" ||
    die 'post-terminator -I target is misclassified as an include option'
run_actual_make_case "$helper" "$post_terminator_include_capture" \
    "$post_terminator_include_trace" '' -s -- --include-dir capture
grep -Fxq 'TARGET=--include-dir' "$post_terminator_include_capture" ||
    die 'post-terminator include-directory target is misclassified as an option'
assert_actual_make_include_rejects_arguments reserved_short_include_attached \
    -I"$include_dir_fixture" -s capture
assert_mutant_make_include_bypass mutant_short_include_attached \
    -I"$include_dir_fixture" -s capture
assert_actual_make_include_rejects_arguments reserved_short_include_separate \
    -I "$include_dir_fixture" -s capture
assert_mutant_make_include_bypass mutant_short_include_separate \
    -I "$include_dir_fixture" -s capture
for include_option in --in --inc --incl --inclu --includ --include \
    --include- --include-d --include-di --include-dir; do
    include_name=${include_option#--}
    assert_actual_make_include_rejects_arguments \
        "reserved_${include_name}_include_equals" \
        "${include_option}=${include_dir_fixture}" -s capture
    assert_mutant_make_include_bypass \
        "mutant_${include_name}_include_equals" \
        "${include_option}=${include_dir_fixture}" -s capture
    assert_actual_make_include_rejects_arguments \
        "reserved_${include_name}_include_separate" \
        "$include_option" "$include_dir_fixture" -s capture
    assert_mutant_make_include_bypass \
        "mutant_${include_name}_include_separate" \
        "$include_option" "$include_dir_fixture" -s capture
done
trusted_c_capture="$tmpdir/trusted-c.capture"
trusted_c_trace="$tmpdir/trusted-c.trace"
run_actual_make_case "$helper" "$trusted_c_capture" "$trusted_c_trace" '' \
    -s -C "$actual_make_dir" capture
validate_actual_make_capture "$trusted_c_capture" ||
    die 'trusted -C directory option changes the package KCFLAGS'
trusted_directory_capture="$tmpdir/trusted-directory.capture"
trusted_directory_trace="$tmpdir/trusted-directory.trace"
run_actual_make_case "$helper" "$trusted_directory_capture" \
    "$trusted_directory_trace" '' -s --directory "$actual_make_dir" capture
validate_actual_make_capture "$trusted_directory_capture" ||
    die 'trusted --directory option changes the package KCFLAGS'
assert_actual_make_rejects_arguments reserved_after_terminator_kcflags \
    'command-line package-controlled variable assignment is reserved' \
    -s -- KCFLAGS=-O3 capture
assert_mutant_make_bypass mutant_after_terminator_kcflags \
    -s -- KCFLAGS=-O3 capture
for assignment in 'KCFLAGS=-O3' 'KCFLAGS+=-O3' 'KCFLAGS:=-O3' \
    'KCFLAGS::=-O3' 'KCFLAGS:::= -O3' 'KCFLAGS?=-O3' 'KCFLAGS!=-O3'; do
    assignment_name=${assignment%%=*}
    assignment_name=${assignment_name//[^A-Za-z0-9]/_}
    assert_actual_make_rejects_arguments \
        "reserved_after_terminator_${assignment_name}" \
        'command-line package-controlled variable assignment is reserved' \
        -s -- "$assignment" capture
done
for variable in MAKE MAKE_COMMAND MAKEFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKEFILES \
    CFLAGS CPPFLAGS CXXFLAGS LDFLAGS; do
    assert_actual_make_rejects_arguments \
        "reserved_after_terminator_${variable}" \
        'command-line package-controlled variable assignment is reserved' \
        -s -- "${variable}=KCFLAGS=-O3" capture
done
for assignment in "${computed_assignment_values[@]}"; do
    assignment_name=${assignment%%=*}
    assignment_name=${assignment_name//[^A-Za-z0-9]/_}
    assert_actual_make_rejects_arguments \
        "expanded_after_terminator_${assignment_name}" \
        'command-line assignment names must not use GNU Make expansion syntax' \
        -s -- "$assignment" capture
done
for whitespace_index in "${!leading_assignment_whitespace[@]}"; do
    whitespace=${leading_assignment_whitespace[whitespace_index]}
    whitespace_name=${leading_assignment_names[whitespace_index]}
    for assignment in "${reserved_assignment_values[@]}"; do
        assignment_name=${assignment%%=*}
        assignment_name=${assignment_name//[^A-Za-z0-9]/_}
        assert_actual_make_rejects_arguments \
            "reserved_leading_${whitespace_name}_${assignment_name}_before_terminator" \
            'command-line package-controlled variable assignment is reserved' \
            "${whitespace}${assignment}" -s capture
        assert_actual_make_rejects_arguments \
            "reserved_leading_${whitespace_name}_${assignment_name}_after_terminator" \
            'command-line package-controlled variable assignment is reserved' \
            -s -- "${whitespace}${assignment}" capture
    done
done
for whitespace_index in "${!leading_assignment_whitespace[@]}"; do
    whitespace=${leading_assignment_whitespace[whitespace_index]}
    whitespace_name=${leading_assignment_names[whitespace_index]}
    assert_mutant_make_bypass \
        "mutant_leading_${whitespace_name}_before_terminator" \
        "${whitespace}KCFLAGS=-O3" -s capture
    assert_mutant_make_bypass \
        "mutant_leading_${whitespace_name}_after_terminator" \
        -s -- "${whitespace}KCFLAGS=-O3" capture
done
assert_actual_make_rejects_arguments expanded_assignment_before_terminator \
    'command-line assignment names must not use GNU Make expansion syntax' \
    'KC$()FLAGS=-O3' -s capture
assert_expanded_assignment_mutant_bypass \
    expanded_assignment_before_terminator_mutant \
    'KC$()FLAGS=-O3' -s capture
assert_expanded_assignment_mutant_bypass \
    expanded_assignment_after_terminator_mutant \
    -s -- 'KC$()FLAGS=-O3' capture
assert_actual_make_rejects_arguments expanded_assignment_value_before_terminator \
    'command-line assignment values must not use GNU Make expansion syntax' \
    'KBUILD_CPPFLAGS=$(eval override KCFLAGS=-O3)' -s capture
assert_assignment_value_mutant_bypass \
    expanded_assignment_value_before_terminator_mutant \
    'KBUILD_CPPFLAGS=$(eval override KCFLAGS=-O3)' -s capture
assert_actual_make_rejects_arguments expanded_assignment_value_after_terminator \
    'command-line assignment values must not use GNU Make expansion syntax' \
    -s -- 'KBUILD_CPPFLAGS=$(eval override KCFLAGS=-O3)' capture
assert_assignment_value_mutant_bypass \
    expanded_assignment_value_after_terminator_mutant \
    -s -- 'KBUILD_CPPFLAGS=$(eval override KCFLAGS=-O3)' capture
assert_actual_make_rejects_arguments reserved_make_after_terminator \
    'command-line package-controlled variable assignment is reserved' \
    -s -- MAKE=make capture
assert_actual_make_rejects_arguments shell_assignment_after_terminator \
    'command-line shell assignment operators are reserved' \
    -s -- 'PROBE!=printf exploited >PATH' capture
assert_shell_assignment_mutant_executes shell_assignment_before_terminator -s
assert_shell_assignment_mutant_executes shell_assignment_after_terminator -s --
post_terminator_kbuild_mutant="$tmpdir/post-terminator-kbuild-mutant"
cp "$commandline_mutant" "$post_terminator_kbuild_mutant"
chmod 0755 "$post_terminator_kbuild_mutant"
post_terminator_kbuild_capture="$tmpdir/post-terminator-kbuild.capture"
post_terminator_kbuild_trace="$tmpdir/post-terminator-kbuild.trace"
if ! run_recursive_make_case "$post_terminator_kbuild_mutant" \
    "$supported_recursive_fixture" "$post_terminator_kbuild_capture" \
    "$post_terminator_kbuild_trace" -s -- KCFLAGS=-O3 capture; then
    die 'Kbuild command-line mutant does not run after the option terminator'
fi
grep -Fxq 'ARG=-O3' "$post_terminator_kbuild_capture" ||
    die 'Kbuild command-line mutant does not reproduce the post-terminator bypass'
post_terminator_kbuild_helper="$supported_recursive_fixture/radeon-dkms-make"
cp "$helper" "$post_terminator_kbuild_helper"
chmod 0755 "$post_terminator_kbuild_helper"
if run_recursive_make_case "$post_terminator_kbuild_helper" \
    "$supported_recursive_fixture" "$tmpdir/post-terminator-kbuild-safe.capture" \
    "$tmpdir/post-terminator-kbuild-safe.trace" -s -- KCFLAGS=-O3 capture; then
    die 'Kbuild helper accepts a post-terminator reserved assignment'
fi
grep -Fq -- \
    'radeon-dkms-make: command-line package-controlled variable assignment is reserved' \
    "$tmpdir/post-terminator-kbuild-safe.trace" ||
    die 'Kbuild post-terminator assignment has no contract diagnostic'
for whitespace_index in "${!leading_assignment_whitespace[@]}"; do
    whitespace=${leading_assignment_whitespace[whitespace_index]}
    whitespace_name=${leading_assignment_names[whitespace_index]}
    recursive_assignment="${whitespace}KCFLAGS=-O3"
    if ! run_recursive_make_case "$post_terminator_kbuild_mutant" \
        "$supported_recursive_fixture" \
        "$tmpdir/post-terminator-kbuild-${whitespace_name}-mutant.capture" \
        "$tmpdir/post-terminator-kbuild-${whitespace_name}-mutant.trace" \
        -s -- "$recursive_assignment" capture; then
        die "Kbuild whitespace assignment mutant does not run for $whitespace_name"
    fi
    grep -Fxq 'ARG=-O3' \
        "$tmpdir/post-terminator-kbuild-${whitespace_name}-mutant.capture" ||
        die "Kbuild whitespace assignment mutant does not reproduce the bypass for $whitespace_name"
    if run_recursive_make_case "$post_terminator_kbuild_helper" \
        "$supported_recursive_fixture" \
        "$tmpdir/post-terminator-kbuild-${whitespace_name}-safe.capture" \
        "$tmpdir/post-terminator-kbuild-${whitespace_name}-safe.trace" \
        -s -- "$recursive_assignment" capture; then
        die "Kbuild helper accepts a leading-whitespace assignment for $whitespace_name"
    fi
    grep -Fq -- \
        'radeon-dkms-make: command-line package-controlled variable assignment is reserved' \
        "$tmpdir/post-terminator-kbuild-${whitespace_name}-safe.trace" ||
        die "Kbuild whitespace assignment lacks its diagnostic for $whitespace_name"
done

assert_actual_make_rejects_arguments reserved_short_eval_separate \
    'GNU Make eval options are reserved' \
    -E KCFLAGS=-O3 -s capture
assert_mutant_make_bypass mutant_short_eval_separate \
    -E KCFLAGS=-O3 -s capture
assert_actual_make_rejects_arguments reserved_short_eval_attached \
    'GNU Make eval options are reserved' \
    -EKCFLAGS=-O3 -s capture
assert_mutant_make_bypass mutant_short_eval_attached \
    -EKCFLAGS=-O3 -s capture
assert_actual_make_rejects_arguments reserved_short_eval_cluster_separate \
    'GNU Make eval options are reserved' \
    -sE KCFLAGS=-O3 capture
assert_mutant_make_bypass mutant_short_eval_cluster_separate \
    -sE KCFLAGS=-O3 capture
assert_actual_make_rejects_arguments reserved_short_eval_cluster_attached \
    'GNU Make eval options are reserved' \
    -sEKCFLAGS=-O3 capture
assert_mutant_make_bypass mutant_short_eval_cluster_attached \
    -sEKCFLAGS=-O3 capture
assert_actual_make_rejects_arguments reserved_short_eval_equals \
    'GNU Make eval options are reserved' \
    -E=KCFLAGS=-O3 -s capture
assert_actual_make_rejects_arguments reserved_makeflags_file_assignment \
    'command-line package-controlled variable assignment is reserved' \
    "MAKEFLAGS=-f$override_makefile" -s capture

for eval_option in --ev --eva --eval; do
    eval_name=${eval_option#--}
    assert_actual_make_rejects_arguments "reserved_${eval_name}_equals" \
        'GNU Make eval options are reserved' \
        "${eval_option}=KCFLAGS=-O3" -s capture
    assert_mutant_make_bypass "mutant_${eval_name}_equals" \
        "${eval_option}=KCFLAGS=-O3" -s capture
    assert_actual_make_rejects_arguments "reserved_${eval_name}_separate" \
        'GNU Make eval options are reserved' \
        "$eval_option" KCFLAGS=-O3 -s capture
    assert_mutant_make_bypass "mutant_${eval_name}_separate" \
        "$eval_option" KCFLAGS=-O3 -s capture
done
assert_actual_make_rejects_arguments reserved_constructed_eval_join \
    'GNU Make eval options are reserved' \
    --eval '$(eval $(join KC,FLAGS)=-O3)' -s capture
assert_mutant_make_bypass mutant_constructed_eval_join \
    --eval '$(eval $(join KC,FLAGS)=-O3)' -s capture
assert_actual_make_rejects_arguments reserved_constructed_eval_subst \
    'GNU Make eval options are reserved' \
    --eval '$(eval $(subst X,KCFLAGS,X=-O3))' -s capture
assert_mutant_make_bypass mutant_constructed_eval_subst \
    --eval '$(eval $(subst X,KCFLAGS,X=-O3))' -s capture

assert_actual_make_rejects_arguments reserved_short_file_separate \
    'GNU Make makefile selector options are reserved' \
    -f "$override_makefile" -s capture
assert_mutant_make_bypass mutant_short_file_separate \
    -f "$override_makefile" -s capture
assert_actual_make_rejects_arguments reserved_short_file_attached \
    'GNU Make makefile selector options are reserved' \
    "-f$override_makefile" -s capture
assert_mutant_make_bypass mutant_short_file_attached \
    "-f$override_makefile" -s capture
for file_option in --f --fi --fil --file --mak --make --makef \
    --makefi --makefil --makefile; do
    file_name=${file_option#--}
    assert_actual_make_rejects_arguments "reserved_${file_name}_separate" \
        'GNU Make makefile selector options are reserved' \
        "$file_option" "$override_makefile" -s capture
    assert_mutant_make_bypass "mutant_${file_name}_separate" \
        "$file_option" "$override_makefile" -s capture
    assert_actual_make_rejects_arguments "reserved_${file_name}_equals" \
        'GNU Make makefile selector options are reserved' \
        "${file_option}=${override_makefile}" -s capture
    assert_mutant_make_bypass "mutant_${file_name}_equals" \
        "${file_option}=${override_makefile}" -s capture
done
assert_actual_make_stdin_rejects_arguments reserved_short_file_stdin \
    'GNU Make makefile selector options are reserved' \
    -f - -s capture
assert_mutant_make_stdin_bypass mutant_short_file_stdin \
    -f - -s capture
for file_option in --f --fi --fil --file --mak --make --makef \
    --makefi --makefil --makefile; do
    file_name=${file_option#--}
    assert_actual_make_stdin_rejects_arguments "reserved_${file_name}_stdin" \
        'GNU Make makefile selector options are reserved' \
        "$file_option" - -s capture
    assert_mutant_make_stdin_bypass "mutant_${file_name}_stdin" \
        "$file_option" - -s capture
done

response_file="$tmpdir/make-response.args"
printf '%s\n' '--eval=KCFLAGS=-O3' >"$response_file"
response_capture="$tmpdir/response.capture"
response_trace="$tmpdir/response.trace"
if run_actual_make_case "$helper" "$response_capture" "$response_trace" '' \
    "@$response_file" -s capture; then
    die 'helper accepts a response-file argv channel as a Make target'
fi
if grep -Fxq 'ARG=-O3' "$response_capture"; then
    die 'GNU Make expands a response-file argv channel into eval input'
fi
grep -Fq 'No rule to make target' "$response_trace" ||
    die 'GNU Make response-file behavior changed without a calibrated diagnostic'

commandline_mutant_capture="$tmpdir/commandline-mutant.capture"
commandline_mutant_trace="$tmpdir/commandline-mutant.trace"
if run_actual_make_case "$commandline_mutant" \
    "$commandline_mutant_capture" \
    "$commandline_mutant_trace" '' \
    KCFLAGS=-O3 -s capture; then
    grep -Fxq 'ARG=-O3' "$commandline_mutant_capture" ||
        die 'command-line KCFLAGS known-bad mutant does not reproduce the bypass'
else
    die 'command-line KCFLAGS known-bad mutant does not run'
fi
commandline_eval_mutant_capture="$tmpdir/commandline-eval-mutant.capture"
commandline_eval_mutant_trace="$tmpdir/commandline-eval-mutant.trace"
if run_actual_make_case "$commandline_mutant" \
    "$commandline_eval_mutant_capture" \
    "$commandline_eval_mutant_trace" '' \
    --eval=KCFLAGS=-O3 -s capture; then
    grep -Fxq 'ARG=-O3' "$commandline_eval_mutant_capture" ||
        die 'command-line eval known-bad mutant does not reproduce the bypass'
else
    die 'command-line eval known-bad mutant does not run'
fi
control_mutant_capture="$tmpdir/control-mutant.capture"
control_mutant_trace="$tmpdir/control-mutant.trace"
if run_actual_make_case "$commandline_mutant" \
    "$control_mutant_capture" \
    "$control_mutant_trace" '' \
    MAKEFLAGS=KCFLAGS=-O3 -s capture; then
    grep -Fxq 'ARG=-O3' "$control_mutant_capture" ||
        die 'command-line control-variable known-bad mutant does not reproduce the bypass'
else
    die 'command-line control-variable known-bad mutant does not run'
fi
define_mutant_capture="$tmpdir/define-mutant.capture"
define_mutant_trace="$tmpdir/define-mutant.trace"
if run_actual_make_case "$commandline_mutant" \
    "$define_mutant_capture" \
    "$define_mutant_trace" '' \
    --eval $'define KCFLAGS\n-O3\nendef' \
    -s capture; then
    grep -Fxq 'ARG=-O3' "$define_mutant_capture" ||
        die 'command-line define known-bad mutant does not reproduce the bypass'
else
    die 'command-line define known-bad mutant does not run'
fi

for optimization in -O -O0 -O1 -O3 -Og -Os -Oz -Ofast; do
    name="conflicting_${optimization#-}"
    assert_helper_rejects "$name" \
        "$optimization -DRADEON_CALLER_SENTINEL=1" \
        "conflicting optimization token: $optimization; package requires -O2"
done

calibration_good="$tmpdir/calibration-good"
cat >"$calibration_good" <<'EOF'
KCFLAGS=-DRADEON_CALLER_SENTINEL=1 -O2 -pipe -I/tmp/.radeon-trace-include/include/trace -include /tmp/radeon-build-profile.h
CFLAGS=
EOF
calibration_missing="$tmpdir/calibration-missing"
cat >"$calibration_missing" <<'EOF'
KCFLAGS=-O2 -pipe -I/tmp/.radeon-trace-include/include/trace -include /tmp/radeon-build-profile.h
CFLAGS=
EOF
calibration_duplicate="$tmpdir/calibration-duplicate"
cat >"$calibration_duplicate" <<'EOF'
KCFLAGS=-DRADEON_CALLER_SENTINEL=1 -O2 -pipe -pipe -I/tmp/.radeon-trace-include/include/trace -include /tmp/radeon-build-profile.h
CFLAGS=
EOF
calibration_duplicate_sentinel="$tmpdir/calibration-duplicate-sentinel"
cat >"$calibration_duplicate_sentinel" <<'EOF'
KCFLAGS=-DRADEON_CALLER_SENTINEL=1 -DRADEON_CALLER_SENTINEL=1 -O2 -pipe -I/tmp/.radeon-trace-include/include/trace -include /tmp/radeon-build-profile.h
CFLAGS=
EOF
calibration_cflags="$tmpdir/calibration-cflags"
cat >"$calibration_cflags" <<'EOF'
KCFLAGS=-DRADEON_CALLER_SENTINEL=1 -O2 -pipe -I/tmp/.radeon-trace-include/include/trace -include /tmp/radeon-build-profile.h
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
    local parallel_value=${3:-3}
    local kernel_release=${4:-fixture-kernel}
    local package_name
    local package_version
    local make_command
    local profile_file=radeon-build-profile.prod.h
    local kernel_build_root="$tmpdir/kernel build"
    local kernel_build_root_q
    local kernel_release_q

    # shellcheck disable=SC2034
    kernelver=$kernel_release
    dkms_tree="$tmpdir/dkms"
    # shellcheck disable=SC2034
    R300_RS480_KERNEL_BUILD_ROOT=$kernel_build_root
    parallel_jobs=$parallel_value
    # shellcheck source=/dev/null
    source "$config"
    unset R300_RS480_KERNEL_BUILD_ROOT
    unset parallel_jobs
    package_name=$PACKAGE_NAME
    package_version=$PACKAGE_VERSION
    mkdir -p "$dkms_tree/$package_name/$package_version/build"
    cp "$helper" \
        "$dkms_tree/$package_name/$package_version/build/radeon-dkms-make"
    make_command=${MAKE[0]}
    case "$make_command" in
        *'RADEON_BUILD_PROFILE=mutate-dev'*)
            profile_file=radeon-build-profile.dev.h
            ;;
    esac
    cp "$package_dir/$profile_file" \
        "$dkms_tree/$package_name/$package_version/build/radeon-build-profile.h"
    chmod 0755 \
        "$dkms_tree/$package_name/$package_version/build/radeon-dkms-make"
    printf -v kernel_release_q '%q' "$kernel_release"
    printf -v kernel_build_root_q '%q' "$kernel_build_root"
    [[ $PRE_BUILD == \
        "pre-build.sh ${kernel_release_q} ${kernel_build_root_q}" ]] ||
        die "$config does not quote the PRE_BUILD arguments"

    PATH="$tmpdir/bin:$PATH" \
        RADEON_DKMS_CAPTURE="$capture" \
        KCFLAGS='-DRADEON_CALLER_SENTINEL=1 -Werror=date-time' \
        CFLAGS='-march=native' \
        MAKEFLAGS='-j99' \
        MFLAGS='-k' \
        GNUMAKEFLAGS='-s' \
        MAKEFILES='/tmp/untrusted.mk' \
        bash -c "$make_command"
    validate_capture "$capture" '-DRADEON_CALLER_SENTINEL=1' ||
        die "$config does not preserve the KCFLAGS composition contract"
    grep -Fxq 'ARG=-C' "$capture" ||
        die "$config does not preserve the DKMS kernel -C option"
    grep -Fxq "ARG=$kernel_build_root" "$capture" ||
        die "$config does not preserve a quoted kernel build root"
    if [[ -n $parallel_value ]]; then
        grep -Fxq "ARG=-j$parallel_value" "$capture" ||
            die "$config does not preserve the DKMS parallel job count"
    else
        grep -Fxq 'ARG=-j' "$capture" ||
            die "$config does not preserve DKMS unlimited parallelism"
    fi
    grep -Fxq "ARG=KERNELRELEASE=$kernel_release" "$capture" ||
        die "$config does not preserve the DKMS kernel release"
    grep -Fxq "ARG=M=$dkms_tree/$package_name/$package_version/build/radeon" \
        "$capture" ||
        die "$config does not preserve a quoted DKMS module path"
    grep -Fxq 'ARG=modules' "$capture" ||
        die "$config does not preserve the DKMS modules target"
}

run_invalid_parallel_recipe() {
    local config=$1
    local diagnostic
    diagnostic="$tmpdir/$(basename "$config").invalid-parallel.log"

    # shellcheck disable=SC2034
    kernelver=fixture-kernel
    dkms_tree="$tmpdir/dkms-invalid"
    # shellcheck disable=SC2034
    R300_RS480_KERNEL_BUILD_ROOT="$tmpdir/kernel build"
    # shellcheck disable=SC2034
    parallel_jobs='invalid; printf DKMS_CONFIG_INJECTION'
    # shellcheck source=/dev/null
    source "$config"
    unset R300_RS480_KERNEL_BUILD_ROOT
    unset parallel_jobs
    [[ ${BUILT_MODULE_NAME[0]-} == radeon &&
        ${BUILT_MODULE_LOCATION[0]-} == radeon &&
        -n ${MAKE[0]-} ]] ||
        die "$config drops module directives for invalid parallel input"
    if bash -c "${MAKE[0]}" >"$diagnostic" 2>&1; then
        die "$config accepts an invalid DKMS parallel job count"
    fi
    grep -Fxq 'dkms.conf: invalid DKMS parallel job count' "$diagnostic" ||
        die "$config invalid parallel command omits its diagnostic"
    if grep -Fq 'DKMS_CONFIG_INJECTION' "$diagnostic"; then
        die "$config evaluates invalid parallel input"
    fi
}

primary_capture="$tmpdir/primary.capture"
development_capture="$tmpdir/development.capture"
legacy_capture="$tmpdir/legacy.capture"
run_dkms_recipe "$package_dir/dkms.conf.prod" "$primary_capture"
run_dkms_recipe "$package_dir/dkms.conf.dev" "$development_capture"
run_dkms_recipe \
    "$package_dir/dkms.conf.radeon-rs480-safe-regs-0.2" \
    "$legacy_capture"
run_dkms_recipe "$package_dir/dkms.conf.prod" "$tmpdir/primary-unlimited.capture" ''
run_dkms_recipe "$package_dir/dkms.conf.dev" \
    "$tmpdir/development-unlimited.capture" ''
run_dkms_recipe "$package_dir/dkms.conf.radeon-rs480-safe-regs-0.2" \
    "$tmpdir/legacy-unlimited.capture" ''
hostile_release='fixture; printf PREBUILD_INJECTION; #'
assert_helper_rejects_arguments hostile_kernel_release_assignment \
    'command-line package-controlled variable assignment is reserved' \
    "KERNELRELEASE=$hostile_release"
run_invalid_parallel_recipe "$package_dir/dkms.conf.prod"
run_invalid_parallel_recipe "$package_dir/dkms.conf.dev"
run_invalid_parallel_recipe \
    "$package_dir/dkms.conf.radeon-rs480-safe-regs-0.2"

primary_kcflags=$(sed -n 's/^KCFLAGS_RAW=//p' "$primary_capture")
development_kcflags=$(sed -n 's/^KCFLAGS_RAW=//p' "$development_capture")
legacy_kcflags=$(sed -n 's/^KCFLAGS_RAW=//p' "$legacy_capture")
[[ $(without_trace_include "$primary_kcflags") == \
    "$(without_trace_include "$development_kcflags")" ]] ||
    die "the profile DKMS recipes compose different KCFLAGS"
[[ $(without_trace_include "$primary_kcflags") == \
    "$(without_trace_include "$legacy_kcflags")" ]] ||
    die "the two DKMS recipes compose different KCFLAGS"

printf 'radeon DKMS KCFLAGS composition: PASS\n'
