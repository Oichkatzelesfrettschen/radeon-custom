#!/usr/bin/env bash
set -euo pipefail

die() {
    printf 'test_radeon_dkms_lifecycle: %s\n' "$*" >&2
    exit 1
}

toml_value() {
    local key=$1
    local file=$2

    awk -F '[[:space:]]*=[[:space:]]*' -v key="$key" '
        $1 == key {
            value = $2
            sub(/[[:space:]]+#.*/, "", value)
            if (value ~ /^".*"$/) {
                sub(/^"/, "", value)
                sub(/"$/, "", value)
            }
            print value
            found = 1
        }
        END { if (!found) exit 1 }
    ' "$file"
}

make_temp_dir() {
    local temp_base=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}

    [[ -d $temp_base && -w $temp_base ]] ||
        die "temporary lifecycle root is absent or not writable: $temp_base"
    mktemp -d "$temp_base/radeon-dkms-lifecycle.XXXXXX"
}

find_dkms_conf() {
    local root=$1
    local -a configs=()
    mapfile -t configs < <(
        find "$root/usr/src" -mindepth 2 -maxdepth 2 -type f \
            -name dkms.conf -print 2>/dev/null | sort
    )
    [[ ${#configs[@]} -eq 1 ]] ||
        return 1
    printf '%s\n' "${configs[0]}"
}

package_sha256_matches() {
    local package=$1
    local expected=$2
    local actual

    [[ $expected =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum -- "$package")
    actual=${actual%% *}
    [[ $actual == "$expected" ]]
}

verify_module_metadata() {
    local field=$1
    local expected=$2
    local actual=$3

    if [[ -z $actual ]]; then
        printf 'module metadata %s is missing, expected %s\n' \
            "$field" "$expected" >&2
        return 1
    fi
    if [[ $actual != "$expected" ]]; then
        printf 'module metadata %s is %s, expected %s\n' \
            "$field" "$actual" "$expected" >&2
        return 1
    fi
}

valid_kernel_release() {
    local release=$1

    [[ $release =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]
}

root_protected_directory() {
    local directory=$1

    [[ -d $directory && ! -L $directory ]] &&
        [[ $(stat -c %u "$directory") -eq 0 ]] &&
        ! find "$directory" -maxdepth 0 -perm /022 -print -quit |
            grep -q .
}

root_protected_path() {
    local path=$1
    local current=/
    local remainder
    local component

    [[ $path == /* ]] || return 1
    root_protected_directory / || return 1
    remainder=${path#/}
    while [[ -n $remainder ]]; do
        component=${remainder%%/*}
        if [[ $remainder == */* ]]; then
            remainder=${remainder#*/}
        else
            remainder=
        fi
        [[ -n $component ]] || continue
        current=${current%/}/$component
        root_protected_directory "$current" || return 1
    done
}

trace_header_stat() {
    local path=$1

    stat -c '%i %F %a %u %g %s %Y %y %Z %z' -- "$path"
}

symlink_free_subpath() {
    # The harness writes the trace header as root. A symlink component below
    # the disposable kernel build root would redirect that write outside the
    # copy, so every component from the base down to the header itself is a
    # real directory or a real file.
    local base=$1
    local path=$2
    local current=$base
    local remainder
    local component

    [[ $path == "$base"/* ]] || return 1
    remainder=${path#"$base"/}
    while [[ -n $remainder ]]; do
        component=${remainder%%/*}
        if [[ $remainder == */* ]]; then
            remainder=${remainder#*/}
        else
            remainder=
        fi
        [[ -n $component ]] || continue
        current=${current%/}/$component
        [[ ! -L $current ]] || return 1
    done
}

verify_empty_command_output() {
    local output_path=$1

    shift
    if ! "$@" >"$output_path"; then
        return 2
    fi
    [[ ! -s $output_path ]]
}

retain_failure_evidence() {
    local private_tree=$1
    local output_directory=$2
    local exit_status=$3
    local package=$4
    local release=$5
    local make_log
    local make_log_index=0
    local retained_log_count
    local manifest="$output_directory/failure-evidence.sha256"

    {
        printf 'exit_status=%d\n' "$exit_status"
        printf 'package=%s\n' "$package"
        printf 'kernel_release=%s\n' "$release"
    } >"$output_directory/failure.txt"
    while IFS= read -r make_log; do
        make_log_index=$((make_log_index + 1))
        cp "$make_log" \
            "$output_directory/failure-make-${make_log_index}.log"
    done < <(
        find "$private_tree" -type f -name make.log -print 2>/dev/null |
            sort
    )
    retained_log_count=$(find "$output_directory" -maxdepth 1 -type f \
        -name 'failure-make-*.log' -print | wc -l)
    [[ $retained_log_count -eq $make_log_index ]] || return 1
    (
        cd "$output_directory"
        find . -maxdepth 1 -type f \
            \( -name 'failure.txt' -o -name 'failure-make-*.log' \) \
            -printf '%P\0' |
            sort -z |
            xargs -0 sha256sum
    ) >"$manifest"
    [[ -s $manifest ]] || return 1
    (cd "$output_directory" && sha256sum -c failure-evidence.sha256) \
        >/dev/null
}

run_self_test() {
    local tmpdir
    local found
    local package_sha256
    local status_result
    local trace_header_legacy_after
    local trace_header_legacy_before
    local trace_header_stat_after
    local trace_header_stat_before
    local trace_header_stat_unchanged
    local attempt=0
    local same_second_rewrite=0
    local -a retained_logs=()

    tmpdir=$(make_temp_dir)
    trap 'rm -rf "$tmpdir"' RETURN
    mkdir -p "$tmpdir/good/usr/src/module-1" \
        "$tmpdir/missing/usr/src" \
        "$tmpdir/ambiguous/usr/src/module-a" \
        "$tmpdir/ambiguous/usr/src/module-b"
    : >"$tmpdir/good/usr/src/module-1/dkms.conf"
    : >"$tmpdir/ambiguous/usr/src/module-a/dkms.conf"
    : >"$tmpdir/ambiguous/usr/src/module-b/dkms.conf"
    printf 'admitted package bytes\n' >"$tmpdir/package"

    found=$(find_dkms_conf "$tmpdir/good") ||
        die "dkms.conf finder rejects its known-good calibration"
    [[ $found == "$tmpdir/good/usr/src/module-1/dkms.conf" ]] ||
        die "dkms.conf finder returns the wrong known-good path"
    if find_dkms_conf "$tmpdir/missing" >/dev/null; then
        die "dkms.conf finder accepts its missing-config calibration"
    fi
    if find_dkms_conf "$tmpdir/ambiguous" >/dev/null; then
        die "dkms.conf finder accepts its ambiguous-config calibration"
    fi
    package_sha256=$(sha256sum "$tmpdir/package")
    package_sha256=${package_sha256%% *}
    package_sha256_matches "$tmpdir/package" "$package_sha256" ||
        die "package digest validator rejects its known-good calibration"
    if package_sha256_matches "$tmpdir/package" \
            0000000000000000000000000000000000000000000000000000000000000000; then
        die "package digest validator accepts a wrong digest"
    fi
    if package_sha256_matches "$tmpdir/package" "${package_sha256^^}"; then
        die "package digest validator accepts a noncanonical digest"
    fi
    printf '%s\n' 'trace header bytes' >"$tmpdir/trace-header-source"
    cp "$tmpdir/trace-header-source" "$tmpdir/trace-header"
    trace_header_stat_before=$(trace_header_stat "$tmpdir/trace-header")
    trace_header_stat_unchanged=$(trace_header_stat "$tmpdir/trace-header")
    [[ $trace_header_stat_before == "$trace_header_stat_unchanged" ]] ||
        die "trace header stat calibration rejects an untouched header"
    trace_header_legacy_before=$(stat -c '%i %F %a %u %g %s %Y' -- \
        "$tmpdir/trace-header")
    while ((attempt < 20)); do
        attempt=$((attempt + 1))
        cp "$tmpdir/trace-header-source" "$tmpdir/trace-header"
        trace_header_stat_after=$(trace_header_stat "$tmpdir/trace-header")
        trace_header_legacy_after=$(stat -c '%i %F %a %u %g %s %Y' -- \
            "$tmpdir/trace-header")
        if [[ $trace_header_legacy_before == "$trace_header_legacy_after" ]]; then
            same_second_rewrite=1
            break
        fi
        trace_header_stat_before=$trace_header_stat_after
        trace_header_legacy_before=$trace_header_legacy_after
    done
    [[ $same_second_rewrite -eq 1 ]] ||
        die "trace header stat calibration cannot create a same-second rewrite"
    [[ $trace_header_stat_before != "$trace_header_stat_after" ]] ||
        die "trace header stat calibration misses a byte-identical rewrite"
    expected_driver_tree=fixture-driver-tree
    verify_module_metadata gororoba_driver_tree \
        "$expected_driver_tree" "$expected_driver_tree" ||
        die "module metadata calibration rejects its known-good driver tree"
    metadata_error=$(verify_module_metadata gororoba_driver_tree \
        "$expected_driver_tree" wrong-driver-tree 2>&1) &&
        die "module metadata calibration accepts a wrong driver tree"
    [[ $metadata_error == \
        "module metadata gororoba_driver_tree is wrong-driver-tree, expected $expected_driver_tree" ]] ||
        die "module metadata calibration reports an imprecise wrong driver tree"
    metadata_error=$(verify_module_metadata gororoba_driver_tree \
        "$expected_driver_tree" '' 2>&1) &&
        die "module metadata calibration accepts a missing driver tree"
    [[ $metadata_error == \
        "module metadata gororoba_driver_tree is missing, expected $expected_driver_tree" ]] ||
        die "module metadata calibration reports an imprecise missing driver tree"
    valid_kernel_release 6.18.38-2-cachyos-lts ||
        die "kernel release validator rejects its known-good calibration"
    for invalid_release in \
        . \
        .. \
        /absolute \
        ../escape \
        'release/name' \
        $'release\nname'
    do
        if valid_kernel_release "$invalid_release"; then
            die "kernel release validator accepts: $invalid_release"
        fi
    done
    root_protected_path / ||
        die "root path validator rejects the filesystem root"
    if root_protected_path /tmp; then
        die "root path validator accepts a world-writable directory"
    fi
    mkdir -p "$tmpdir/subpath/drivers/gpu/drm/radeon" "$tmpdir/outside"
    : >"$tmpdir/subpath/drivers/gpu/drm/radeon/radeon_trace.h"
    symlink_free_subpath "$tmpdir/subpath" \
        "$tmpdir/subpath/drivers/gpu/drm/radeon/radeon_trace.h" ||
        die "subpath validator rejects its known-good calibration"
    mkdir -p "$tmpdir/linked-parent/drivers/gpu/drm"
    ln -s "$tmpdir/outside" "$tmpdir/linked-parent/drivers/gpu/drm/radeon"
    if symlink_free_subpath "$tmpdir/linked-parent" \
            "$tmpdir/linked-parent/drivers/gpu/drm/radeon/radeon_trace.h"; then
        die "subpath validator accepts a symlinked parent component"
    fi
    mkdir -p "$tmpdir/linked-leaf/drivers/gpu/drm/radeon"
    ln -s "$tmpdir/outside/radeon_trace.h" \
        "$tmpdir/linked-leaf/drivers/gpu/drm/radeon/radeon_trace.h"
    if symlink_free_subpath "$tmpdir/linked-leaf" \
            "$tmpdir/linked-leaf/drivers/gpu/drm/radeon/radeon_trace.h"; then
        die "subpath validator accepts a dangling symlinked header"
    fi
    if symlink_free_subpath "$tmpdir/subpath" "$tmpdir/outside/radeon_trace.h"; then
        die "subpath validator accepts a path outside the base"
    fi
    mkdir -p "$tmpdir/private/module/build" "$tmpdir/failure-evidence"
    printf 'decisive failure log\n' \
        >"$tmpdir/private/module/build/make.log"
    retain_failure_evidence "$tmpdir/private" \
        "$tmpdir/failure-evidence" 10 "$tmpdir/package" fixture-kernel
    rm -rf "$tmpdir/private"
    [[ ! -e $tmpdir/private ]] ||
        die "failure calibration retains its private tree"
    [[ -s $tmpdir/failure-evidence/failure.txt ]] ||
        die "failure calibration omits failure metadata"
    mapfile -t retained_logs < <(
        find "$tmpdir/failure-evidence" -type f \
            -name 'failure-make-*.log' -print
    )
    [[ ${#retained_logs[@]} -eq 1 ]] ||
        die "failure calibration does not retain every make.log"
    grep -Fxq 'decisive failure log' "${retained_logs[0]}" ||
        die "failure calibration changes the retained make.log"
    (cd "$tmpdir/failure-evidence" &&
        sha256sum -c failure-evidence.sha256) >/dev/null ||
        die "failure calibration emits an invalid evidence manifest"
    : >"$tmpdir/blocked-retention-target"
    if retain_failure_evidence "$tmpdir/failure-evidence" \
            "$tmpdir/blocked-retention-target" 10 \
            "$tmpdir/package" fixture-kernel 2>/dev/null; then
        die "failure retention accepts a nondirectory output path"
    fi
    verify_empty_command_output "$tmpdir/status-empty" true ||
        die "status calibration rejects successful empty output"
    if verify_empty_command_output "$tmpdir/status-residual" \
            printf '%s\n' residual; then
        die "status calibration accepts residual DKMS state"
    fi
    status_result=0
    verify_empty_command_output "$tmpdir/status-failed" false ||
        status_result=$?
    [[ $status_result -eq 2 ]] ||
        die "status calibration masks command failure"
    printf 'radeon DKMS lifecycle calibration: PASS\n'
}

package_path=
expected_sha256=
kernel_release=
inject_trace_header=
evidence_dir=
self_test=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --package)
            [[ $# -ge 2 ]] || die "--package requires a path"
            package_path=$2
            shift 2
            ;;
        --kernel-release)
            [[ $# -ge 2 ]] || die "--kernel-release requires a value"
            kernel_release=$2
            shift 2
            ;;
        --expected-sha256)
            [[ $# -ge 2 ]] || die "--expected-sha256 requires a value"
            expected_sha256=$2
            shift 2
            ;;
        --evidence-dir)
            [[ $# -ge 2 ]] || die "--evidence-dir requires a path"
            evidence_dir=$2
            shift 2
            ;;
        --inject-trace-header)
            [[ $# -ge 2 ]] || die "--inject-trace-header requires matching or conflicting"
            inject_trace_header=$2
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

if [[ $self_test -eq 1 ]]; then
    run_self_test
    exit 0
fi

[[ -n $kernel_release ]] || die "--kernel-release is required"
valid_kernel_release "$kernel_release" ||
    die "kernel release must be one canonical path-free token"
[[ $EUID -eq 0 ]] ||
    die "the full DKMS install lifecycle requires root"
[[ -f $package_path && ! -L $package_path ]] ||
    die "package must be a readable regular file, not a symbolic link"
[[ -r $package_path ]] || die "package is not readable: $package_path"
[[ -d /lib/modules/$kernel_release/build ]] ||
    die "kernel build root is absent: /lib/modules/$kernel_release/build"
[[ -n $evidence_dir ]] || die "--evidence-dir is required"
evidence_parent=$(dirname -- "$evidence_dir")
root_protected_path "$evidence_parent" ||
    die "evidence parent must be an absolute root-owned, non-writable path"
[[ ! -e $evidence_dir && ! -L $evidence_dir ]] ||
    die "evidence directory must be a new path: $evidence_dir"
mkdir -m 0700 "$evidence_dir"

tmpdir=$(make_temp_dir)
extract_root="$tmpdir/package"
source_tree="$tmpdir/usr/src"
dkms_tree="$tmpdir/var/lib/dkms"
install_tree="$tmpdir/install"
stub_bin="$tmpdir/bin"
kernel_build_root="$tmpdir/kernel-build"
admitted_package="$tmpdir/admitted-package.pkg.tar"

capture_failure_and_cleanup() {
    local exit_status=$?

    trap - EXIT
    if [[ $exit_status -ne 0 ]]; then
        if ! retain_failure_evidence "$dkms_tree" "$evidence_dir" \
                "$exit_status" "$package_path" "$kernel_release"; then
            printf '%s\n' \
                "test_radeon_dkms_lifecycle: failure evidence retention failed; root-private state preserved: $tmpdir" \
                >&2
            exit "$exit_status"
        fi
    fi
    rm -rf "$tmpdir"
    exit "$exit_status"
}
trap capture_failure_and_cleanup EXIT

mkdir -p "$extract_root" "$source_tree" "$dkms_tree" \
    "$install_tree" "$stub_bin" "$kernel_build_root"
install -m 0400 -- "$package_path" "$admitted_package"
package_sha256=$(sha256sum -- "$admitted_package")
package_sha256=${package_sha256%% *}
package_sha256_matches "$admitted_package" "$expected_sha256" ||
    die "admitted package SHA-256 does not match the expected lowercase digest"

resolved_kernel_build_root=$(readlink -f "/lib/modules/$kernel_release/build")
[[ -d $resolved_kernel_build_root ]] ||
    die "resolved kernel build root is absent: $resolved_kernel_build_root"
root_protected_path "$resolved_kernel_build_root" ||
    die "resolved kernel build root has non-root or writable ancestry"
cp -a --reflink=auto "$resolved_kernel_build_root/." "$kernel_build_root/"
[[ -f $kernel_build_root/include/generated/compile.h ]] ||
    die "disposable kernel build root lacks include/generated/compile.h"
# A headers-only root omits drivers/gpu/drm/radeon/radeon_trace.h and the
# DKMS pre-build satisfies define_trace.h through its private shim; a target
# root ships the real header and the build resolves it in place. Both layouts
# complete the lifecycle, so the harness records which one it exercises. The
# --inject-trace-header calibration flag synthesizes the target layout on a
# headers-only host: matching copies the module source header, conflicting
# writes a differing header that the post-extraction byte comparison rejects.
# The evidence names the layout and its source, so a synthesized header stays
# distinguishable from a kernel root that ships its own.
kernel_trace_header="$kernel_build_root/drivers/gpu/drm/radeon/radeon_trace.h"
if [[ -e $kernel_trace_header || -L $kernel_trace_header ]] &&
   [[ -n $inject_trace_header ]]; then
    die "--inject-trace-header on a root that already ships the trace header"
fi
case $inject_trace_header in
    "" ) ;;
    matching|conflicting)
        symlink_free_subpath "$kernel_build_root" "$kernel_trace_header" ||
            die "trace header path crosses a symlink below the build root"
        mkdir -p "$(dirname -- "$kernel_trace_header")"
        ;;
    *)
        die "--inject-trace-header accepts matching or conflicting"
        ;;
esac
install -Dm755 "$kernel_build_root/scripts/sign-file" \
    "$install_tree/$kernel_release/build/scripts/sign-file"

bsdtar -xf "$admitted_package" -C "$extract_root"
packaged_conf=$(find_dkms_conf "$extract_root") ||
    die "package must contain exactly one usr/src/*/dkms.conf"
packaged_source=$(dirname "$packaged_conf")

# shellcheck disable=SC2034
kernelver=$kernel_release
# shellcheck source=/dev/null
source "$packaged_conf"
module_name=$PACKAGE_NAME
module_version=$PACKAGE_VERSION
expected_source="$extract_root/usr/src/$module_name-$module_version"
[[ $packaged_source == "$expected_source" ]] ||
    die "package source path does not match PACKAGE_NAME and PACKAGE_VERSION"
source_identity="$packaged_source/source-identity.toml"
[[ -f $source_identity && ! -L $source_identity ]] ||
    die "package source identity is absent or not a regular file"
cp "$source_identity" "$evidence_dir/source-identity.toml"
expected_driver_tree=$(toml_value driver_tree "$source_identity")
[[ $expected_driver_tree =~ ^[0-9a-f]{40}$ ]] ||
    die "package source identity driver_tree is not a canonical object ID"
[[ $expected_driver_tree != 0000000000000000000000000000000000000000 ]] ||
    die "package source identity driver_tree is the all-zero git object"
build_manifest="$packaged_source/radeon-build-profile.toml"
[[ -f $build_manifest && ! -L $build_manifest ]] ||
    die "package build profile is absent or not a regular file"
cp "$build_manifest" "$evidence_dir/radeon-build-profile.toml"
requested_profile=$(toml_value build_profile "$build_manifest")
case $requested_profile in
    prod)
        expected_module_profile=prod
        ;;
    all-dev)
        expected_module_profile=mutate-dev
        ;;
    *)
        die "package build profile is neither prod nor all-dev"
        ;;
esac
expected_source_commit=$(toml_value source_commit "$build_manifest")
manifest_driver_tree=$(toml_value driver_tree "$build_manifest")
[[ $manifest_driver_tree == "$expected_driver_tree" ]] ||
    die "package build profile driver tree disagrees with the pinned source identity"
expected_policy=$(toml_value feature_policy_sha256 "$build_manifest")
expected_upstream=$(toml_value upstream_base "$build_manifest")
case $inject_trace_header in
    matching)
        install -m 0644 "$packaged_source/radeon/radeon_trace.h" \
            "$kernel_trace_header"
        ;;
    conflicting)
        { cat "$packaged_source/radeon/radeon_trace.h"
          printf '/* divergent kernel-root copy */\n'; } \
            >"$kernel_trace_header"
        chmod 0644 "$kernel_trace_header"
        ;;
esac
if [[ -e $kernel_trace_header || -L $kernel_trace_header ]]; then
    [[ -f $kernel_trace_header && ! -L $kernel_trace_header ]] ||
        die "kernel root trace header is not a regular file"
    symlink_free_subpath "$kernel_build_root" "$kernel_trace_header" ||
        die "kernel root trace header path crosses a symlink"
    trace_header_layout=kernel-root
    cmp -s "$kernel_trace_header" "$packaged_source/radeon/radeon_trace.h" ||
        die "kernel root trace header differs from the module source header"
    cp "$kernel_trace_header" "$evidence_dir/kernel-radeon_trace.h.pre"
    # A byte-identical in-place reinstall retains the inode and can share the
    # same whole-second mtime. The record carries nanosecond mtime and ctime
    # alongside ownership and mode, so the retained record preserves each
    # subsecond timestamp change the filesystem reports.
    trace_header_stat "$kernel_trace_header" \
        >"$evidence_dir/kernel-radeon_trace.h.stat.pre"
else
    trace_header_layout=shim
fi
# An injected header synthesizes the target layout on a headers-only host, so
# the retained bundle separates it from a kernel root that ships its own.
if [[ -n $inject_trace_header ]]; then
    trace_header_source=injected-$inject_trace_header
else
    trace_header_source=natural
fi
printf 'trace_header_layout=%s\ntrace_header_source=%s\n' \
    "$trace_header_layout" "$trace_header_source" \
    >"$evidence_dir/trace-header-layout.txt"
cp -a "$packaged_source" "$source_tree/$module_name-$module_version"

cat >"$stub_bin/limine-mkinitcpio" <<'EOF'
#!/bin/sh
set -eu
printf 'limine-mkinitcpio invoked\n' >>"$RADEON_DKMS_INITRAMFS_LOG"
EOF
chmod 0755 "$stub_bin/limine-mkinitcpio"
initramfs_log="$evidence_dir/initramfs-hook.log"
: >"$initramfs_log"

dkms_common=(
    --dkmstree "$dkms_tree"
    --sourcetree "$source_tree"
    --installtree "$install_tree"
)
kernel_source_args=(
    --kernelsourcedir "$kernel_build_root"
)

dkms add -m "$module_name" -v "$module_version" \
    "${dkms_common[@]}" |
    tee "$evidence_dir/dkms-add.log"

PATH="$stub_bin:$PATH" \
    RADEON_DKMS_MAKE_TRACE=1 \
    KCFLAGS='-DRADEON_CALLER_SENTINEL=1 -Werror=date-time' \
    CFLAGS='-march=native -funsafe-math-optimizations' \
    R300_RS480_KERNEL_BUILD_ROOT="$kernel_build_root" \
    RADEON_DKMS_INITRAMFS_LOG="$initramfs_log" \
    dkms build -m "$module_name" -v "$module_version" \
        -k "$kernel_release" "${dkms_common[@]}" \
        "${kernel_source_args[@]}" -j 1 |
    tee "$evidence_dir/dkms-build.log"

mapfile -t make_logs < <(
    find "$dkms_tree/$module_name/$module_version" -type f \
        -name make.log -print | sort
)
[[ ${#make_logs[@]} -eq 1 ]] ||
    die "expected one DKMS make.log, observed ${#make_logs[@]}"
cp "${make_logs[0]}" "$evidence_dir/make.log"
if [[ $trace_header_layout == kernel-root ]]; then
    cmp -s "$kernel_trace_header" "$evidence_dir/kernel-radeon_trace.h.pre" ||
        die "DKMS build rewrote the kernel root trace header"
    trace_header_stat "$kernel_trace_header" \
        >"$evidence_dir/kernel-radeon_trace.h.stat.post"
    cmp -s "$evidence_dir/kernel-radeon_trace.h.stat.pre" \
        "$evidence_dir/kernel-radeon_trace.h.stat.post" ||
        die "DKMS build replaced the kernel root trace header in place"
else
    [[ ! -e $kernel_trace_header ]] ||
        die "DKMS build writes the external trace header into the kernel root"
fi
grep -Fq -- \
    'private trace-include header matches the module source' \
    "$evidence_dir/make.log" ||
    die "DKMS pre-build log omits the private trace-header byte comparison"
grep -Fq -- '-DRADEON_CALLER_SENTINEL=1' "$evidence_dir/make.log" ||
    die "DKMS make invocation omits incoming KCFLAGS"
grep -Fq -- '-pipe' "$evidence_dir/make.log" ||
    die "DKMS make invocation omits the package -pipe flag"
grep -Fq -- \
    "-I$dkms_tree/$module_name/$module_version/build/.radeon-trace-include/include/trace" \
    "$evidence_dir/make.log" ||
    die "DKMS make invocation omits the private trace-include path"
grep -Fq -- \
    "-include $dkms_tree/$module_name/$module_version/build/radeon-build-profile.h" \
    "$evidence_dir/make.log" ||
    die "DKMS make invocation omits the package build-profile header"
grep -Fq -- "RADEON_BUILD_PROFILE=$expected_module_profile" \
    "$evidence_dir/make.log" ||
    die "DKMS make invocation omits the selected build profile"
if grep -Eq -- '(^|[[:space:]])-march=native([[:space:]]|$)|(^|[[:space:]])-funsafe-math-optimizations([[:space:]]|$)' \
        "$evidence_dir/make.log"; then
    die "DKMS compiler commands admit userspace CFLAGS"
fi

PATH="$stub_bin:$PATH" \
    RADEON_DKMS_INITRAMFS_LOG="$initramfs_log" \
    dkms install -m "$module_name" -v "$module_version" \
        -k "$kernel_release" "${dkms_common[@]}" \
        "${kernel_source_args[@]}" --no-depmod |
    tee "$evidence_dir/dkms-install.log"

mapfile -t modules < <(
    find "$install_tree/$kernel_release" -type f \
        \( -name 'radeon.ko' -o -name 'radeon.ko.*' \) -print | sort
)
[[ ${#modules[@]} -eq 1 ]] ||
    die "expected one installed radeon module, observed ${#modules[@]}"
module_path=${modules[0]}
module_name_actual=$(modinfo -F name "$module_path")
module_srcversion=$(modinfo -F srcversion "$module_path")
module_vermagic=$(modinfo -F vermagic "$module_path")
module_profile=$(modinfo -F gororoba_build_profile "$module_path")
module_source_commit=$(modinfo -F gororoba_source_commit "$module_path")
module_driver_tree=$(modinfo -F gororoba_driver_tree "$module_path" 2>/dev/null || true)
module_policy=$(modinfo -F gororoba_feature_policy_sha256 "$module_path")
module_upstream=$(modinfo -F gororoba_upstream_base "$module_path")
[[ $module_name_actual == radeon ]] ||
    die "installed module name is $module_name_actual"
[[ -n $module_srcversion ]] ||
    die "installed module srcversion is empty"
[[ $module_vermagic == "$kernel_release "* ]] ||
    die "installed module vermagic does not start with $kernel_release"
[[ $module_profile == "$expected_module_profile" ]] ||
    die "installed module build profile disagrees with the package manifest"
[[ $module_source_commit == "$expected_source_commit" ]] ||
    die "installed module source commit disagrees with the package manifest"
verify_module_metadata gororoba_driver_tree "$expected_driver_tree" \
    "$module_driver_tree" ||
    die "installed module driver tree metadata is not pinned"
[[ $module_policy == "$expected_policy" ]] ||
    die "installed module feature policy disagrees with the package manifest"
[[ $module_upstream == "$expected_upstream" ]] ||
    die "installed module upstream base disagrees with the package manifest"

{
    printf 'package=%s\n' "$package_path"
    printf 'package_sha256=%s\n' "$package_sha256"
    printf 'module=%s\n' "$module_name"
    printf 'version=%s\n' "$module_version"
    printf 'kernel_release=%s\n' "$kernel_release"
    printf 'kernel_build_source=%s\n' "$resolved_kernel_build_root"
    printf 'kernel_build_disposition=disposable-copy\n'
    printf 'module_path=%s\n' "$module_path"
    printf 'module_name=%s\n' "$module_name_actual"
    printf 'srcversion=%s\n' "$module_srcversion"
    printf 'vermagic=%s\n' "$module_vermagic"
    printf 'build_profile=%s\n' "$module_profile"
    printf 'source_commit=%s\n' "$module_source_commit"
    printf 'driver_tree=%s\n' "$module_driver_tree"
    printf 'feature_policy_sha256=%s\n' "$module_policy"
    printf 'upstream_base=%s\n' "$module_upstream"
    printf 'sha256=%s\n' "$(sha256sum "$module_path" | awk '{print $1}')"
} >"$evidence_dir/module-metadata.txt"

dkms uninstall -m "$module_name" -v "$module_version" \
    -k "$kernel_release" "${dkms_common[@]}" --no-depmod |
    tee "$evidence_dir/dkms-uninstall.log"
dkms unbuild -m "$module_name" -v "$module_version" \
    -k "$kernel_release" "${dkms_common[@]}" \
    "${kernel_source_args[@]}" |
    tee "$evidence_dir/dkms-unbuild.log"
dkms remove -m "$module_name" -v "$module_version" \
    --all "${dkms_common[@]}" |
    tee "$evidence_dir/dkms-remove.log"

status_result=0
verify_empty_command_output "$evidence_dir/dkms-status.log" \
    dkms status -m "$module_name" -v "$module_version" \
    "${dkms_common[@]}" || status_result=$?
case $status_result in
    0)
        ;;
    1)
        die "DKMS status retains the module after cleanup"
        ;;
    2)
        die "DKMS status command fails after cleanup"
        ;;
    *)
        die "DKMS status verification returns unexpected status $status_result"
        ;;
esac

printf 'radeon DKMS lifecycle: PASS (%s/%s, %s)\n' \
    "$module_name" "$module_version" "$kernel_release"
