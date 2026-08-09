#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
expected_conf="$repo_root/packaging/arch/radeon-unified-dkms/radeon-re.conf"
experiment_allowlist="$repo_root/packaging/arch/radeon-unified-dkms/radeon-re-experiment-allowlist.conf"
installed_policy_conf=/etc/modprobe.d/radeon-re.conf
host=
snapshot_input=
self_test=0
check_files=0

usage() {
    cat <<'USAGE'
usage: check_radeon_unified_runtime_policy.sh [--host HOST] [--expected-conf FILE]
                                               [--experiment-allowlist FILE]
                                               [--snapshot FILE] [--self-test]
                                               [--check-files]

Checks whether a loaded radeon module matches the unified DKMS runtime policy.
The check fails when any non-package modprobe file sets unsupported
"options radeon" values, or when /sys/module/radeon/parameters cannot verify the
package-owned radeon-re.conf policy.
The --snapshot form evaluates a captured radeon-unified-runtime-policy-v1 record.
The --check-files form verifies the package-owned modprobe policy inputs.
The --self-test form calibrates known-good and known-bad policy records.
USAGE
}

die() {
    printf 'check_radeon_unified_runtime_policy: %s\n' "$*" >&2
    exit 1
}

normalize_modprobe_text() {
    local normalized_text

    normalized_text=${1//-/_}
    normalized_text=${normalized_text//\\/}
    normalized_text=${normalized_text//\'/}
    normalized_text=${normalized_text//\"/}
    printf '%s\n' "$normalized_text"
}

is_retired_radeon_parameter() {
    local normalized_name

    normalized_name=$(normalize_modprobe_text "$1")
    case "$normalized_name" in
        rs480_gart_snoop | rs480_atomic_rmw_report)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

emit_modprobe_logical_lines() {
    local config_file

    config_file=$1
    awk -v file="$config_file" '
        function emit_logical_line() {
            print file "\t" logical_line
            logical_line = ""
        }

        {
            physical_line = $0
            if (physical_line ~ /\\$/) {
                sub(/\\$/, "", physical_line)
                logical_line = logical_line physical_line
                next
            }
            logical_line = logical_line physical_line
            emit_logical_line()
        }

        END {
            if (logical_line != "")
                emit_logical_line()
        }
    ' "$config_file"
}

policy_text_has_retired_parameter() {
    local normalized_text retired_parameter_name

    normalized_text=$(normalize_modprobe_text "$1")
    if [[ $normalized_text =~ ^[[:space:]]*# ]]; then
        return 1
    fi
    for retired_parameter_name in rs480_gart_snoop rs480_atomic_rmw_report; do
        case "$normalized_text" in
            *"$retired_parameter_name"*)
                printf '%s\n' "$retired_parameter_name"
                return 0
                ;;
        esac
    done
    return 1
}

# modprobe.d(5) defines the default configuration directory denominator.
readonly -a default_modprobe_config_directories=(
    /etc/modprobe.d
    /run/modprobe.d
    /usr/local/lib/modprobe.d
    /usr/lib/modprobe.d
    /lib/modprobe.d
)

list_modprobe_config_files() {
    local config_directory canonical_config_directory seen_config_directories
    local -a config_directories

    if [ "$#" -gt 0 ]; then
        config_directories=("$@")
    else
        config_directories=("${default_modprobe_config_directories[@]}")
    fi

    seen_config_directories=
    for config_directory in "${config_directories[@]}"; do
        [ -d "$config_directory" ] || continue
        canonical_config_directory=$(readlink -f -- "$config_directory") || continue
        case ":$seen_config_directories:" in
            *":$canonical_config_directory:"*)
                continue
                ;;
        esac
        seen_config_directories="${seen_config_directories:+$seen_config_directories:}$canonical_config_directory"
        find -H "$config_directory" -maxdepth 1 \( -type f -o -type l \) \
            -name '*.conf' -print 2>/dev/null
    done | awk '
        {
            config_basename = $0
            sub(/^.*\//, "", config_basename)
            if (!seen_config_basenames[config_basename]++)
                print
        }
    ' | sort -u
}

run_self_test() {
    local script_path fixture_root expected_fixture good_allowlist route_allowlist
    local renamed_allowlist continued_config test_row test_name test_snapshot
    local test_allowlist expected_diagnostic good_snapshot route_file_snapshot
    local empty_route_file_snapshot renamed_route_snapshot atomic_route_snapshot
    local split_quote_route_snapshot install_route_snapshot inline_hash_snapshot
    local hyphen_route_snapshot hyphen_atomic_snapshot continued_route_snapshot
    local runtime_route_snapshot runtime_atomic_snapshot missing_policy_snapshot
    local shadowed_policy_snapshot malformed_snapshot
    local good_policy_dir bad_allowlist_dir bad_parameter_dir directory_fixture
    local directory_alias alias_first_directory alias_first_target remote_collector
    local expected_directories actual_directories expected_files actual_files
    local remote_files alias_first_expected alias_first_local alias_first_remote
    local output status failures

    script_path="$script_dir/check_radeon_unified_runtime_policy.sh"
    fixture_root=$(mktemp -d)
    trap 'rm -rf "$fixture_root"' EXIT
    expected_fixture="$fixture_root/expected.conf"
    good_allowlist="$fixture_root/good-allowlist.conf"
    route_allowlist="$fixture_root/route-allowlist.conf"
    renamed_allowlist="$fixture_root/renamed-allowlist.conf"
    continued_config="$fixture_root/continued-experiment.conf"
    good_snapshot="$fixture_root/good.snapshot"
    route_file_snapshot="$fixture_root/route-file.snapshot"
    empty_route_file_snapshot="$fixture_root/empty-route-file.snapshot"
    renamed_route_snapshot="$fixture_root/renamed-route.snapshot"
    atomic_route_snapshot="$fixture_root/atomic-route.snapshot"
    split_quote_route_snapshot="$fixture_root/split-quote-route.snapshot"
    install_route_snapshot="$fixture_root/install-route.snapshot"
    inline_hash_snapshot="$fixture_root/inline-hash-route.snapshot"
    hyphen_route_snapshot="$fixture_root/hyphen-route.snapshot"
    hyphen_atomic_snapshot="$fixture_root/hyphen-atomic.snapshot"
    continued_route_snapshot="$fixture_root/continued-route.snapshot"
    runtime_route_snapshot="$fixture_root/runtime-route.snapshot"
    runtime_atomic_snapshot="$fixture_root/runtime-atomic.snapshot"
    missing_policy_snapshot="$fixture_root/missing-policy.snapshot"
    shadowed_policy_snapshot="$fixture_root/shadowed-policy.snapshot"
    malformed_snapshot="$fixture_root/malformed.snapshot"
    good_policy_dir="$fixture_root/policy-good"
    bad_allowlist_dir="$fixture_root/policy-bad-allowlist"
    bad_parameter_dir="$fixture_root/policy-bad-parameter"
    directory_fixture="$fixture_root/config-directories"
    directory_alias="$fixture_root/config-directory-alias"
    alias_first_directory="$fixture_root/config-alias-first"
    alias_first_target="$fixture_root/config-alias-target"
    remote_collector="$fixture_root/remote-snapshot.sh"

    printf '%s\n' 'options radeon lockup_timeout=0' >"$expected_fixture"
    printf '%s\n' 'benign-experiment.conf' >"$good_allowlist"
    printf '%s\n' 'radeon-snoop-experiment.conf' >"$route_allowlist"
    printf '%s\n' \
        'renamed-experiment.conf' \
        'continued-experiment.conf' >"$renamed_allowlist"
    printf '%s\n' \
        'options radeon rs480_gart_\' \
        'snoop=1' >"$continued_config"

    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/benign-experiment.conf' \
        '/usr/lib/modprobe.d/amdgpu.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        '/etc/modprobe.d/benign-experiment.conf\toptions radeon benign_experiment=1' \
        '/etc/modprobe.d/benign-experiment.conf\t  # rs480_gart_snoop is retired' \
        '/usr/lib/modprobe.d/amdgpu.conf\toptions radeon si_support=0 cik_support=0' \
        'SECTION params' \
        'lockup_timeout\t0' >"$good_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/radeon-snoop-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        '/etc/modprobe.d/radeon-snoop-experiment.conf\toptions radeon si_support=0' \
        'SECTION params' \
        'lockup_timeout\t0' >"$route_file_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/radeon-snoop-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        'SECTION params' \
        'lockup_timeout\t0' >"$empty_route_file_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/renamed-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        '/etc/modprobe.d/renamed-experiment.conf\toptions radeon "rs480_gart_snoop=0"' \
        'SECTION params' \
        'lockup_timeout\t0' >"$renamed_route_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/renamed-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        '/etc/modprobe.d/renamed-experiment.conf\toptions radeon rs480_atomic_rmw_report=0' \
        'SECTION params' \
        'lockup_timeout\t0' >"$atomic_route_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/renamed-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        "/etc/modprobe.d/renamed-experiment.conf\toptions radeon rs480_gart_'snoop'=0" \
        'SECTION params' \
        'lockup_timeout\t0' >"$split_quote_route_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/renamed-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        '/etc/modprobe.d/renamed-experiment.conf\tinstall radeon /sbin/modprobe --ignore-install radeon rs480_gart_snoop=1' \
        'SECTION params' \
        'lockup_timeout\t0' >"$install_route_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/renamed-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        '/etc/modprobe.d/renamed-experiment.conf\toptions radeon si_support=0 # rs480_gart_snoop=1' \
        'SECTION params' \
        'lockup_timeout\t0' >"$inline_hash_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/renamed-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        '/etc/modprobe.d/renamed-experiment.conf\toptions radeon rs480-gart-snoop=1' \
        'SECTION params' \
        'lockup_timeout\t0' >"$hyphen_route_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/etc/modprobe.d/renamed-experiment.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        '/etc/modprobe.d/renamed-experiment.conf\toptions radeon rs480-atomic-rmw-report=1' \
        'SECTION params' \
        'lockup_timeout\t0' >"$hyphen_atomic_snapshot"
    {
        printf '%b\n' \
            'SCHEMA radeon-unified-runtime-policy-v1' \
            'SECTION modprobe-files' \
            '/etc/modprobe.d/radeon-re.conf' \
            "$continued_config" \
            'SECTION modprobe' \
            '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0'
        emit_modprobe_logical_lines "$continued_config"
        printf '%b\n' \
            'SECTION params' \
            'lockup_timeout\t0'
    } >"$continued_route_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        'SECTION params' \
        'lockup_timeout\t0' \
        'rs480_gart_snoop\t0' >"$runtime_route_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        'SECTION params' \
        'lockup_timeout\t0' \
        'rs480_atomic_rmw_report\t0' >"$runtime_atomic_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/usr/lib/modprobe.d/radeon-re.conf' \
        'SECTION modprobe' \
        '/usr/lib/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        'SECTION params' \
        'lockup_timeout\t0' >"$missing_policy_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe-files' \
        '/etc/modprobe.d/radeon-re.conf' \
        '/usr/lib/modprobe.d/radeon-re.conf' \
        'SECTION modprobe' \
        '/etc/modprobe.d/radeon-re.conf\toptions radeon test=1' \
        '/usr/lib/modprobe.d/radeon-re.conf\toptions radeon lockup_timeout=0' \
        'SECTION params' \
        'lockup_timeout\t0' >"$shadowed_policy_snapshot"
    printf '%b\n' \
        'SCHEMA radeon-unified-runtime-policy-v1' \
        'SECTION modprobe' \
        'SECTION params' \
        'lockup_timeout\t0' >"$malformed_snapshot"

    mkdir -p "$good_policy_dir" "$bad_allowlist_dir" "$bad_parameter_dir"
    printf '%s\n' 'options radeon lockup_timeout=0' >"$good_policy_dir/radeon-re.conf"
    printf '%s\n' 'benign-experiment.conf' >"$good_policy_dir/experiment-allowlist.conf"
    printf '%s\n' \
        '  # rs480_gart_snoop is retired' \
        'options radeon benign_experiment=1' >"$good_policy_dir/benign-experiment.conf"
    printf '%s\n' 'options radeon lockup_timeout=0' >"$bad_allowlist_dir/radeon-re.conf"
    printf '%s\n' 'radeon-snoop-experiment.conf' >"$bad_allowlist_dir/experiment-allowlist.conf"
    printf '%s\n' 'options radeon lockup_timeout=0' >"$bad_parameter_dir/radeon-re.conf"
    : >"$bad_parameter_dir/experiment-allowlist.conf"
    printf '%s\n' \
        'options radeon rs480-gart-\' \
        'snoop=0' >"$bad_parameter_dir/renamed.conf"
    mkdir -p \
        "$directory_fixture/etc" \
        "$directory_fixture/etc/disabled" \
        "$directory_fixture/run" \
        "$directory_fixture/usr-local" \
        "$directory_fixture/usr-lib" \
        "$alias_first_target"
    : >"$directory_fixture/etc/etc.conf"
    printf '%s\n' \
        'options radeon si_support=0' \
        >"$directory_fixture/etc/vendor.conf"
    printf '%s\n' \
        'options radeon rs480_gart_snoop=1' \
        >"$directory_fixture/etc/disabled/radeon-snoop-experiment.conf"
    : >"$directory_fixture/run/run.conf"
    : >"$directory_fixture/usr-local/usr-local.conf"
    : >"$directory_fixture/usr-lib/usr-lib.conf"
    printf '%s\n' \
        'options radeon rs480_gart_snoop=1' \
        >"$directory_fixture/usr-lib/vendor.conf"
    ln -s "$directory_fixture/usr-lib" "$directory_alias"
    printf '%s\n' \
        'options radeon rs480_gart_snoop=1' \
        >"$alias_first_target/radeon-snoop-experiment.conf"
    ln -s "$alias_first_target" "$alias_first_directory"

    failures=0
    if ! output=$("$script_path" --snapshot "$good_snapshot" \
        --expected-conf "$expected_fixture" \
        --experiment-allowlist "$good_allowlist" 2>&1); then
        printf 'self-test: known-good snapshot failed: %s\n' "$output" >&2
        failures=$((failures + 1))
    fi
    if ! output=$("$script_path" --check-files \
        --expected-conf "$good_policy_dir/radeon-re.conf" \
        --experiment-allowlist "$good_policy_dir/experiment-allowlist.conf" 2>&1); then
        printf 'self-test: known-good package inputs failed: %s\n' "$output" >&2
        failures=$((failures + 1))
    fi
    expected_directories=$(printf '%s\n' \
        /etc/modprobe.d \
        /run/modprobe.d \
        /usr/local/lib/modprobe.d \
        /usr/lib/modprobe.d \
        /lib/modprobe.d)
    actual_directories=$(printf '%s\n' "${default_modprobe_config_directories[@]}")
    if [ "$actual_directories" != "$expected_directories" ]; then
        printf 'self-test: default modprobe directory denominator differs\n' >&2
        failures=$((failures + 1))
    fi
    expected_files=$(printf '%s\n' \
        "$directory_fixture/etc/etc.conf" \
        "$directory_fixture/etc/vendor.conf" \
        "$directory_fixture/run/run.conf" \
        "$directory_fixture/usr-lib/usr-lib.conf" \
        "$directory_fixture/usr-local/usr-local.conf" | sort)
    actual_files=$(list_modprobe_config_files \
        "$directory_fixture/etc" \
        "$directory_fixture/run" \
        "$directory_fixture/usr-local" \
        "$directory_fixture/usr-lib" \
        "$directory_alias")
    if [ "$actual_files" != "$expected_files" ]; then
        printf 'self-test: direct modprobe file census or alias deduplication failed\n' >&2
        failures=$((failures + 1))
    fi
    awk '
        /^# radeon-runtime-policy-remote-snapshot-begin$/ { capture = 1 }
        capture { print }
        /^# radeon-runtime-policy-remote-snapshot-end$/ { exit }
    ' "$script_path" >"$remote_collector"
    remote_files=$(sh "$remote_collector" --skip-runtime-parameters \
        "$directory_fixture/etc" \
        "$directory_fixture/run" \
        "$directory_fixture/usr-local" \
        "$directory_fixture/usr-lib" \
        "$directory_alias" | awk '
            $0 == "SECTION modprobe-files" { section = 1; next }
            $0 == "SECTION modprobe" { section = 0 }
            section { print }
        ')
    if [ "$remote_files" != "$expected_files" ]; then
        printf 'self-test: remote direct modprobe file census or alias deduplication failed\n' >&2
        failures=$((failures + 1))
    fi
    alias_first_expected="$alias_first_directory/radeon-snoop-experiment.conf"
    alias_first_local=$(list_modprobe_config_files \
        "$alias_first_directory" "$alias_first_target")
    alias_first_remote=$(sh "$remote_collector" --skip-runtime-parameters \
        "$alias_first_directory" "$alias_first_target" | awk '
            $0 == "SECTION modprobe-files" { section = 1; next }
            $0 == "SECTION modprobe" { section = 0 }
            section { print }
        ')
    if [ "$alias_first_local" != "$alias_first_expected" ] ||
       [ "$alias_first_remote" != "$alias_first_expected" ]; then
        printf 'self-test: first directory alias suppresses a direct modprobe file\n' >&2
        failures=$((failures + 1))
    fi

    for test_row in \
        "retired filename|$route_file_snapshot|$route_allowlist|retired radeon modprobe configuration file" \
        "empty retired filename|$empty_route_file_snapshot|$route_allowlist|retired radeon modprobe configuration file" \
        "renamed snoop option|$renamed_route_snapshot|$renamed_allowlist|retired radeon module option" \
        "renamed atomic option|$atomic_route_snapshot|$renamed_allowlist|retired radeon module option" \
        "split quote snoop option|$split_quote_route_snapshot|$renamed_allowlist|retired radeon module option" \
        "install command snoop option|$install_route_snapshot|$renamed_allowlist|retired radeon module option" \
        "inline hash snoop option|$inline_hash_snapshot|$renamed_allowlist|retired radeon module option" \
        "hyphen snoop option|$hyphen_route_snapshot|$renamed_allowlist|retired radeon module option" \
        "hyphen atomic option|$hyphen_atomic_snapshot|$renamed_allowlist|retired radeon module option" \
        "continued snoop option|$continued_route_snapshot|$renamed_allowlist|retired radeon module option" \
        "loaded snoop parameter|$runtime_route_snapshot|$good_allowlist|retired radeon runtime parameter" \
        "loaded atomic parameter|$runtime_atomic_snapshot|$good_allowlist|retired radeon runtime parameter" \
        "missing package policy|$missing_policy_snapshot|$good_allowlist|package-owned radeon policy file is absent" \
        "shadowed package policy|$shadowed_policy_snapshot|$good_allowlist|installed radeon policy differs from package policy" \
        "malformed snapshot|$malformed_snapshot|$good_allowlist|snapshot schema is invalid"; do
        IFS='|' read -r test_name test_snapshot test_allowlist expected_diagnostic <<EOF
$test_row
EOF
        status=0
        output=$("$script_path" --snapshot "$test_snapshot" \
            --expected-conf "$expected_fixture" \
            --experiment-allowlist "$test_allowlist" 2>&1) || status=$?
        if [ "$status" -eq 0 ] || ! grep -Fq "$expected_diagnostic" <<EOF
$output
EOF
        then
            printf 'self-test: %s calibration failed: status=%s output=%s\n' \
                "$test_name" "$status" "$output" >&2
            failures=$((failures + 1))
        fi
    done

    for test_row in \
        "retired allowlist|$bad_allowlist_dir|retired radeon allowlist entry" \
        "retired package option|$bad_parameter_dir|retired radeon module option"; do
        IFS='|' read -r test_name test_snapshot expected_diagnostic <<EOF
$test_row
EOF
        status=0
        output=$("$script_path" --check-files \
            --expected-conf "$test_snapshot/radeon-re.conf" \
            --experiment-allowlist "$test_snapshot/experiment-allowlist.conf" 2>&1) || status=$?
        if [ "$status" -eq 0 ] || ! grep -Fq "$expected_diagnostic" <<EOF
$output
EOF
        then
            printf 'self-test: %s calibration failed: status=%s output=%s\n' \
                "$test_name" "$status" "$output" >&2
            failures=$((failures + 1))
        fi
    done

    rm -rf "$fixture_root"
    trap - EXIT
    if [ "$failures" -ne 0 ]; then
        return 1
    fi
    printf 'radeon unified runtime policy self-test: PASS (6 good, 17 bad)\n'
}

check_policy_files() {
    local policy_directory config_file file_basename source_path line
    local normalized_parameter
    local allowlist_entry failures

    [ -r "$expected_conf" ] || die "expected config is not readable: $expected_conf"
    [ -r "$experiment_allowlist" ] ||
        die "experiment allowlist is not readable: $experiment_allowlist"

    failures=0
    while IFS= read -r allowlist_entry; do
        case "$allowlist_entry" in
            '' | \#*)
                continue
                ;;
            radeon-snoop-experiment.conf)
                printf 'retired radeon allowlist entry: %s\n' \
                    "$allowlist_entry" >&2
                failures=$((failures + 1))
                ;;
        esac
    done <"$experiment_allowlist"

    policy_directory=$(dirname -- "$expected_conf")
    while IFS= read -r -d '' config_file; do
        file_basename=$(basename -- "$config_file")
        if [ "$file_basename" = "radeon-snoop-experiment.conf" ]; then
            printf 'retired radeon modprobe configuration file: %s\n' \
                "$config_file" >&2
            failures=$((failures + 1))
            continue
        fi
        if [ ! -r "$config_file" ]; then
            printf 'unreadable package modprobe configuration file: %s\n' \
                "$config_file" >&2
            failures=$((failures + 1))
            continue
        fi
        while IFS=$'\t' read -r source_path line; do
            [ "$source_path" = "$config_file" ] || continue
            if normalized_parameter=$(policy_text_has_retired_parameter "$line"); then
                printf 'retired radeon module option in %s: %s\n' \
                    "$config_file" "$normalized_parameter" >&2
                failures=$((failures + 1))
            fi
        done < <(emit_modprobe_logical_lines "$config_file")
    done < <(
        find "$policy_directory" -maxdepth 1 \
            \( -type f -o -type l \) -name '*.conf' -print0
    )

    [ "$failures" -eq 0 ] || return 1
    printf 'radeon unified runtime policy package inputs: ok\n'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            [ "$#" -ge 2 ] || die "--host requires an argument"
            host=$2
            case "$host" in
                -*)
                    die "--host must be a hostname, not an ssh option: $host"
                    ;;
            esac
            shift 2
            ;;
        --experiment-allowlist)
            [ "$#" -ge 2 ] || die "--experiment-allowlist requires an argument"
            experiment_allowlist=$2
            shift 2
            continue
            ;;
        --expected-conf)
            [ "$#" -ge 2 ] || die "--expected-conf requires an argument"
            expected_conf=$2
            shift 2
            ;;
        --snapshot)
            [ "$#" -ge 2 ] || die "--snapshot requires an argument"
            snapshot_input=$2
            shift 2
            ;;
        --self-test)
            self_test=1
            shift
            ;;
        --check-files)
            check_files=1
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

if [ "$self_test" -eq 1 ]; then
    [ -z "$host" ] || die "--self-test does not accept --host"
    [ -z "$snapshot_input" ] || die "--self-test does not accept --snapshot"
    [ "$check_files" -eq 0 ] || die "--self-test does not accept --check-files"
    run_self_test
    exit
fi

if [ "$check_files" -eq 1 ]; then
    [ -z "$host" ] || die "--check-files does not accept --host"
    [ -z "$snapshot_input" ] || die "--check-files does not accept --snapshot"
    check_policy_files
    exit
fi

[ -z "$host" ] || [ -z "$snapshot_input" ] || die "--host and --snapshot are mutually exclusive"
[ -z "$snapshot_input" ] || [ -r "$snapshot_input" ] || die "snapshot is not readable: $snapshot_input"

[ -r "$expected_conf" ] || die "expected config is not readable: $expected_conf"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

expected_params="$tmpdir/expected_params.tsv"
installed_policy_params="$tmpdir/installed_policy_params.tsv"
snapshot="$tmpdir/runtime_snapshot.txt"
modprobe_files="$tmpdir/modprobe_files.txt"
modprobe_rows="$tmpdir/modprobe_rows.tsv"
runtime_params="$tmpdir/runtime_params.tsv"

awk '
    $1 == "options" && $2 == "radeon" {
        for (field_index = 3; field_index <= NF; field_index++) {
            if ($field_index ~ /^[A-Za-z0-9_]+=/) {
                split($field_index, pair, "=")
                print pair[1] "\t" pair[2]
            }
        }
    }
' < <(emit_modprobe_logical_lines "$expected_conf" | cut -f 2-) |
    sort -u >"$expected_params"
: >"$installed_policy_params"

collect_local_snapshot() {
    printf 'SCHEMA radeon-unified-runtime-policy-v1\n'
    printf 'SECTION modprobe-files\n'
    list_modprobe_config_files
    printf 'SECTION modprobe\n'
    list_modprobe_config_files | while IFS= read -r file; do
        if [ ! -r "$file" ]; then
            printf '%s\t__UNREADABLE__\n' "$file"
            continue
        fi
        emit_modprobe_logical_lines "$file"
    done

    printf 'SECTION params\n'
    [ -d /sys/module/radeon/parameters ] || return 0
    for param in /sys/module/radeon/parameters/*; do
        name=$(basename -- "$param")
        # Module parameters are root-only (0600) on current radeon-unified
        # builds; fall back to a non-interactive sudo read so an unprivileged
        # verifier run reports values instead of __UNREADABLE__.  sudo -n
        # fails fast without a prompt where passwordless sudo is absent.
        if ! value=$(cat "$param" 2>/dev/null) &&
           ! value=$(sudo -n cat "$param" 2>/dev/null); then
            printf '%s\t__UNREADABLE__\n' "$name"
            continue
        fi
        printf '%s\t%s\n' "$name" "$value"
    done | sort
}

collect_remote_snapshot() {
    ssh "$host" 'sh -s' <<'REMOTE'
# radeon-runtime-policy-remote-snapshot-begin
set -eu
skip_runtime_parameters=0
if [ "${1:-}" = "--skip-runtime-parameters" ]; then
    skip_runtime_parameters=1
    shift
fi
list_modprobe_config_files() {
    seen_config_directories=
    if [ "$#" -eq 0 ]; then
        set -- \
            /etc/modprobe.d \
            /run/modprobe.d \
            /usr/local/lib/modprobe.d \
            /usr/lib/modprobe.d \
            /lib/modprobe.d
    fi
    for config_directory
    do
        [ -d "$config_directory" ] || continue
        canonical_config_directory=$(readlink -f -- "$config_directory") || continue
        case ":$seen_config_directories:" in
            *":$canonical_config_directory:"*)
                continue
                ;;
        esac
        seen_config_directories="${seen_config_directories:+$seen_config_directories:}$canonical_config_directory"
        find -H "$config_directory" -maxdepth 1 \( -type f -o -type l \) \
            -name '*.conf' -print 2>/dev/null
    done | awk '
        {
            config_basename = $0
            sub(/^.*\//, "", config_basename)
            if (!seen_config_basenames[config_basename]++)
                print
        }
    ' | sort -u
}

emit_modprobe_logical_lines() {
    config_file=$1
    awk -v file="$config_file" '
        function emit_logical_line() {
            print file "\t" logical_line
            logical_line = ""
        }

        {
            physical_line = $0
            if (physical_line ~ /\\$/) {
                sub(/\\$/, "", physical_line)
                logical_line = logical_line physical_line
                next
            }
            logical_line = logical_line physical_line
            emit_logical_line()
        }

        END {
            if (logical_line != "")
                emit_logical_line()
        }
    ' "$config_file"
}

printf 'SCHEMA radeon-unified-runtime-policy-v1\n'
printf 'SECTION modprobe-files\n'
list_modprobe_config_files "$@"
printf 'SECTION modprobe\n'
list_modprobe_config_files "$@" | while IFS= read -r file; do
    if [ ! -r "$file" ]; then
        printf '%s\t__UNREADABLE__\n' "$file"
        continue
    fi
    emit_modprobe_logical_lines "$file"
done

printf 'SECTION params\n'
[ "$skip_runtime_parameters" -eq 0 ] || exit 0
[ -d /sys/module/radeon/parameters ] || exit 0
for param in /sys/module/radeon/parameters/*; do
    name=$(basename -- "$param")
    if ! value=$(cat "$param" 2>/dev/null) &&
       ! value=$(sudo -n cat "$param" 2>/dev/null); then
        printf '%s\t__UNREADABLE__\n' "$name"
        continue
    fi
    printf '%s\t%s\n' "$name" "$value"
done | sort
# radeon-runtime-policy-remote-snapshot-end
REMOTE
}

if [ -n "$snapshot_input" ]; then
    cp -- "$snapshot_input" "$snapshot"
elif [ -n "$host" ]; then
    collect_remote_snapshot >"$snapshot"
else
    collect_local_snapshot >"$snapshot"
fi

awk '
    NR == 1 {
        if ($0 != "SCHEMA radeon-unified-runtime-policy-v1")
            invalid = 1
        next
    }
    $0 == "SECTION modprobe-files" {
        if (section != 0 || modprobe_files_sections != 0)
            invalid = 1
        section = 1
        modprobe_files_sections++
        next
    }
    $0 == "SECTION modprobe" {
        if (section != 1 || modprobe_sections != 0)
            invalid = 1
        section = 2
        modprobe_sections++
        next
    }
    $0 == "SECTION params" {
        if (section != 2 || params_sections != 0)
            invalid = 1
        section = 3
        params_sections++
        next
    }
    /^SECTION / { invalid = 1; next }
    section == 0 { invalid = 1 }
    END {
        if (section != 3 || modprobe_files_sections != 1 ||
            modprobe_sections != 1 || params_sections != 1)
            invalid = 1
        exit invalid
    }
' "$snapshot" || die "snapshot schema is invalid"

awk '
    /^SECTION modprobe-files$/ { section = "modprobe-files"; next }
    /^SECTION modprobe$/ { section = "modprobe"; next }
    /^SECTION params$/ { section = "params"; next }
    section == "modprobe-files" { print }
' "$snapshot" >"$modprobe_files"

awk '
    /^SECTION modprobe-files$/ { section = "modprobe-files"; next }
    /^SECTION modprobe$/ { section = "modprobe"; next }
    /^SECTION params$/ { section = "params"; next }
    section == "modprobe" { print }
' "$snapshot" >"$modprobe_rows"

awk '
    /^SECTION modprobe-files$/ { section = "modprobe-files"; next }
    /^SECTION modprobe$/ { section = "modprobe"; next }
    /^SECTION params$/ { section = "params"; next }
    section == "params" { print }
' "$snapshot" >"$runtime_params"

failures=0
installed_policy_present=0

while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ "$file" = "$installed_policy_conf" ]; then
        installed_policy_present=1
    fi
    if [ "$(basename -- "$file")" = "radeon-snoop-experiment.conf" ]; then
        printf 'retired radeon modprobe configuration file: %s\n' "$file" >&2
        failures=$((failures + 1))
    fi
done <"$modprobe_files"

if [ "$installed_policy_present" -ne 1 ]; then
    printf 'package-owned radeon policy file is absent: %s\n' \
        "$installed_policy_conf" >&2
    failures=$((failures + 1))
fi

while IFS='	' read -r file line; do
    [ -n "$file" ] || continue
    file_basename=$(basename -- "$file")
    if [ "$file_basename" = "radeon-snoop-experiment.conf" ]; then
        if ! grep -qxF -- "$file" "$modprobe_files"; then
            printf 'retired radeon modprobe configuration file: %s\n' \
                "$file" >&2
            failures=$((failures + 1))
        fi
        continue
    fi
    if [ "$line" = "__UNREADABLE__" ]; then
        printf 'unreadable modprobe configuration file: %s\n' "$file" >&2
        failures=$((failures + 1))
        continue
    fi

    if retired_parameter_name=$(policy_text_has_retired_parameter "$line"); then
        printf 'retired radeon module option in %s: %s\n' \
            "$file" "$retired_parameter_name" >&2
        failures=$((failures + 1))
        continue
    fi

    read -r -a config_tokens <<<"$line"
    if [ "$file" = "$installed_policy_conf" ]; then
        case "${config_tokens[0]:-}" in
            '' | \#*)
                continue
                ;;
        esac
        if [ "${config_tokens[0]:-}" != "options" ] ||
           [ "${config_tokens[1]:-}" != "radeon" ]; then
            printf 'unsupported command in package-owned radeon policy file: %s\n' \
                "$line" >&2
            failures=$((failures + 1))
            continue
        fi
        option_tokens=("${config_tokens[@]:2}")
        for option_token in "${option_tokens[@]}"; do
            case "$option_token" in
                *=*)
                    option_name=${option_token%%=*}
                    option_value=${option_token#*=}
                    option_name=$(normalize_modprobe_text "$option_name")
                    option_value=${option_value//\\/}
                    option_value=${option_value//\'/}
                    option_value=${option_value//\"/}
                    if [[ ! "$option_name" =~ ^[A-Za-z0-9_]+$ ]]; then
                        printf 'invalid option in package-owned radeon policy file: %s\n' \
                            "$option_token" >&2
                        failures=$((failures + 1))
                        continue
                    fi
                    printf '%s\t%s\n' "$option_name" "$option_value" \
                        >>"$installed_policy_params"
                    ;;
                *)
                    printf 'invalid option in package-owned radeon policy file: %s\n' \
                        "$option_token" >&2
                    failures=$((failures + 1))
                    ;;
            esac
        done
        continue
    fi

    [ "${config_tokens[0]:-}" = "options" ] || continue
    [ "${config_tokens[1]:-}" = "radeon" ] || continue
    option_tokens=("${config_tokens[@]:2}")
    if [ -r "$experiment_allowlist" ] &&
       grep -v '^#' "$experiment_allowlist" | grep -v '^$' |
           grep -qxF "$(basename -- "$file")"; then
        printf 'allowed experiment modprobe file (kernel-module lane): %s\n' "$file"
        printf '  %s\n' "$line"
        continue
    fi
    allowed_foreign=1
    for option_token in "${option_tokens[@]}"; do
        case "$option_token" in
            si_support=0 | cik_support=0)
                ;;
            *)
                allowed_foreign=0
                ;;
        esac
    done
    [ "$allowed_foreign" -eq 1 ] && continue
    printf 'foreign radeon modprobe option file: %s\n' "$file" >&2
    printf '  %s\n' "$line" >&2
    failures=$((failures + 1))
done <"$modprobe_rows"

sort -u -o "$installed_policy_params" "$installed_policy_params"
if ! cmp -s "$expected_params" "$installed_policy_params"; then
    printf 'installed radeon policy differs from package policy: %s\n' \
        "$installed_policy_conf" >&2
    failures=$((failures + 1))
fi

if [ ! -s "$runtime_params" ]; then
    printf 'radeon runtime parameters are unavailable; is the module loaded?\n' >&2
    failures=$((failures + 1))
fi

while IFS='	' read -r runtime_name runtime_value; do
    [ -n "$runtime_name" ] || continue
    if is_retired_radeon_parameter "$runtime_name"; then
        printf 'retired radeon runtime parameter present: %s=%s\n' \
            "$runtime_name" "$runtime_value" >&2
        failures=$((failures + 1))
    fi
done <"$runtime_params"

while IFS='	' read -r key expected; do
    [ -n "$key" ] || continue
    actual_line=$(awk -F '\t' -v key="$key" '$1 == key { print "FOUND:" $2; found = 1 } END { if (!found) exit 1 }' "$runtime_params" || true)
    if [ -z "$actual_line" ]; then
        printf 'runtime parameter missing: %s expected=%s\n' "$key" "$expected" >&2
        failures=$((failures + 1))
        continue
    fi
    actual=${actual_line#FOUND:}
    if [ "$actual" = "__UNREADABLE__" ]; then
        printf 'runtime parameter unreadable, cannot verify: %s expected=%s\n' "$key" "$expected" >&2
        failures=$((failures + 1))
        continue
    fi
    if [ -z "$actual" ]; then
        printf 'runtime parameter blank, cannot verify: %s expected=%s\n' "$key" "$expected" >&2
        failures=$((failures + 1))
        continue
    fi
    if [ "$actual" != "$expected" ]; then
        printf 'runtime parameter mismatch: %s expected=%s actual=%s\n' \
            "$key" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
done <"$expected_params"

[ "$failures" -eq 0 ] || exit 1
if [ -n "$host" ]; then
    printf 'radeon unified runtime policy: ok (%s)\n' "$host"
elif [ -n "$snapshot_input" ]; then
    printf 'radeon unified runtime policy: ok (snapshot)\n'
else
    printf 'radeon unified runtime policy: ok\n'
fi
