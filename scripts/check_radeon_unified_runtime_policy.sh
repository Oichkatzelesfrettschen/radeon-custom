#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
expected_conf="$repo_root/packaging/arch/radeon-unified-dkms/radeon-re.conf"
experiment_allowlist="$repo_root/packaging/arch/radeon-unified-dkms/radeon-re-experiment-allowlist.conf"
host=

usage() {
    cat <<'USAGE'
usage: check_radeon_unified_runtime_policy.sh [--host HOST] [--expected-conf FILE]
                                               [--experiment-allowlist FILE]

Checks whether a loaded radeon module matches the unified DKMS runtime policy.
The check fails when any non-package modprobe file sets unsupported
"options radeon" values, or when /sys/module/radeon/parameters cannot verify the
package-owned radeon-re.conf policy.
USAGE
}

die() {
    printf 'check_radeon_unified_runtime_policy: %s\n' "$*" >&2
    exit 1
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
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ -r "$expected_conf" ] || die "expected config is not readable: $expected_conf"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

expected_params="$tmpdir/expected_params.tsv"
snapshot="$tmpdir/runtime_snapshot.txt"
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
' "$expected_conf" | sort -u >"$expected_params"

collect_local_snapshot() {
    printf 'SECTION modprobe\n'
    for dir in /etc/modprobe.d /usr/lib/modprobe.d; do
        [ -d "$dir" ] || continue
        find "$dir" -type f -name '*.conf' -print 2>/dev/null
    done | sort | while IFS= read -r file; do
        awk -v file="$file" '
            $1 == "options" && $2 == "radeon" {
                print file "\t" $0
            }
        ' "$file"
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
set -eu
printf 'SECTION modprobe\n'
for dir in /etc/modprobe.d /usr/lib/modprobe.d; do
    [ -d "$dir" ] || continue
    find "$dir" -type f -name '*.conf' -print 2>/dev/null
done | sort | while IFS= read -r file; do
    awk -v file="$file" '
        $1 == "options" && $2 == "radeon" {
            print file "\t" $0
        }
    ' "$file"
done

printf 'SECTION params\n'
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
REMOTE
}

if [ -n "$host" ]; then
    collect_remote_snapshot >"$snapshot"
else
    collect_local_snapshot >"$snapshot"
fi

awk '
    /^SECTION modprobe$/ { section = "modprobe"; next }
    /^SECTION params$/ { section = "params"; next }
    section == "modprobe" { print }
' "$snapshot" >"$modprobe_rows"

awk '
    /^SECTION modprobe$/ { section = "modprobe"; next }
    /^SECTION params$/ { section = "params"; next }
    section == "params" { print }
' "$snapshot" >"$runtime_params"

failures=0

while IFS='	' read -r file line; do
    [ -n "$file" ] || continue
    case "$(basename -- "$file")" in
        radeon-re.conf)
            ;;
        *)
            if [ -r "$experiment_allowlist" ] &&
               grep -v '^#' "$experiment_allowlist" | grep -v '^$' |
                   grep -qxF "$(basename -- "$file")"; then
                printf 'allowed experiment modprobe file (kernel-module lane): %s\n' "$file"
                printf '  %s\n' "$line"
                continue
            fi
            allowed_foreign=1
            for token in ${line#options radeon }; do
                case "$token" in
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
            ;;
    esac
done <"$modprobe_rows"

if [ ! -s "$runtime_params" ]; then
    printf 'radeon runtime parameters are unavailable; is the module loaded?\n' >&2
    failures=$((failures + 1))
fi

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
else
    printf 'radeon unified runtime policy: ok\n'
fi
