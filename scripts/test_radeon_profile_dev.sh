#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"

die() {
    printf 'test_radeon_profile_dev: %s\n' "$*" >&2
    exit 1
}

temp_root=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
tmpdir=$(mktemp -d "$temp_root/radeon-profile-dev.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
fixture_root="$tmpdir/root"
source_root="$fixture_root/usr/src/radeon-unified-0.5"
profile_root="$fixture_root/usr/share/radeon-unified/profiles"
modprobe_root="$fixture_root/etc/modprobe.d"
sys_root="$fixture_root/sys/module/radeon"
stub_bin="$tmpdir/bin"
mkdir -p "$source_root" "$profile_root" "$modprobe_root" "$stub_bin"

cp "$package_dir/source-identity.toml" "$source_root/source-identity.toml"
cp "$package_dir/radeon-build-profile.dev.toml" \
    "$source_root/radeon-build-profile.toml"
for profile in observe-dev probe-dev mutate-dev; do
    cp "$package_dir/${profile}.conf" "$profile_root/${profile}.conf"
done

cat >"$source_root/dkms-initramfs-refresh.sh" <<'EOF'
#!/bin/sh
set -eu
: >"$RADEON_PROFILE_REFRESH_MARKER"
[ "${RADEON_PROFILE_REFRESH_FAIL:-0}" -eq 0 ]
EOF
chmod 0755 "$source_root/dkms-initramfs-refresh.sh"

cat >"$stub_bin/pacman" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -Qq ] && [ "$2" = radeon-unified-dkms-dev ]
printf '%s\n' radeon-unified-dkms-dev
EOF
cat >"$stub_bin/id" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -u ]
printf '%s\n' 0
EOF
cat >"$stub_bin/modinfo" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -F ]
case $2 in
    gororoba_build_profile)
        printf '%s\n' mutate-dev
        ;;
    gororoba_source_commit)
        printf '%s\n' 5df0aec3b7ad96b78c4f8cbb9bc4096571f8ebc2
        ;;
    gororoba_feature_policy_sha256)
        printf '%s\n' 8e2b957a49405b5e1689b5a5c1572c848b1e2a40e017addf9d53b4776661fecd
        ;;
    gororoba_upstream_base)
        printf '%s\n' 7d0a66e4bb9081d75c82ec4957c50034cb0ea449
        ;;
    srcversion)
        printf '%s\n' 0000000000000000TESTONLY
        ;;
    vermagic)
        printf '%s SMP preempt mod_unload\n' "$(uname -r)"
        ;;
    *)
        exit 1
        ;;
esac
EOF
cat >"$stub_bin/rs480-reset-hazard-preflight" <<'EOF'
#!/bin/sh
set -eu
: >"$RADEON_PROFILE_PREFLIGHT_MARKER"
EOF
cat >"$stub_bin/modprobe" <<EOF
#!/bin/sh
set -eu
[ "\$1" = -c ]
cat -- "$modprobe_root"/*.conf 2>/dev/null || :
EOF
chmod 0755 "$stub_bin"/*

helper="$tmpdir/radeon-profile-dev"
sed \
    -e "s|^source_root=.*|source_root=$source_root|" \
    -e "s|^profile_root=.*|profile_root=$profile_root|" \
    -e "s|/etc/modprobe.d|$modprobe_root|g" \
    -e "s|^override=.*|override=$modprobe_root/radeon-unified-profile-dev.conf|" \
    -e "s|/sys/module/radeon|$sys_root|g" \
    "$package_dir/radeon-profile-dev" >"$helper"
chmod 0755 "$helper"

refresh_marker="$tmpdir/refresh"
preflight_marker="$tmpdir/preflight"
run_helper() {
    PATH="$stub_bin:$PATH" \
        RADEON_PROFILE_REFRESH_MARKER="$refresh_marker" \
        RADEON_PROFILE_REFRESH_FAIL="${RADEON_PROFILE_REFRESH_FAIL:-0}" \
        RADEON_PROFILE_PREFLIGHT_MARKER="$preflight_marker" \
        "$helper" "$@"
}

# script(1) gives the helper a pty stdin, so the attended acknowledgement
# paths run under calibration instead of only their noninteractive refusals.
run_helper_tty() {
    profile=$1
    answer=$2
    printf '%s\n' "$answer" | script -qec \
        "env PATH='$stub_bin':\"\$PATH\" \
             RADEON_PROFILE_REFRESH_MARKER='$refresh_marker' \
             RADEON_PROFILE_REFRESH_FAIL='${RADEON_PROFILE_REFRESH_FAIL:-0}' \
             RADEON_PROFILE_PREFLIGHT_MARKER='$preflight_marker' \
             '$helper' select '$profile'" /dev/null
}

show_output=$(run_helper show)
grep -Fxq 'build_profile=all-dev' <<<"$show_output" ||
    die "show omits the all-dev build identity"
grep -Fxq 'requested_profile=off' <<<"$show_output" ||
    die "show does not report the closed requested default"
grep -Fxq 'effective_modprobe_profile=off' <<<"$show_output" ||
    die "show does not report the closed effective default"

run_helper select observe-dev >"$tmpdir/observe.log"
cmp "$profile_root/observe-dev.conf" \
    "$modprobe_root/radeon-unified-profile-dev.conf" ||
    die "observe-dev selection does not copy the canonical template"
[[ -f $refresh_marker ]] || die "observe-dev selection omits initramfs refresh"

if RADEON_PROFILE_REFRESH_FAIL=1 \
        run_helper select observe-dev >"$tmpdir/rollback.log" 2>&1; then
    die "profile selection accepts a failed initramfs refresh"
fi
grep -Fq 'prior profile was restored' "$tmpdir/rollback.log" ||
    die "initramfs failure omits its rollback diagnostic"
cmp "$profile_root/observe-dev.conf" \
    "$modprobe_root/radeon-unified-profile-dev.conf" ||
    die "initramfs failure does not restore the prior profile"

printf 'options radeon profile_dev=probe-dev\n' \
    >"$modprobe_root/zz-duplicate.conf"
if run_helper select observe-dev >"$tmpdir/duplicate.log" 2>&1; then
    die "selection accepts a duplicate effective profile_dev row"
fi
grep -Fq 'prior profile was restored' "$tmpdir/duplicate.log" ||
    die "duplicate-row rejection omits its rollback diagnostic"
cmp "$profile_root/observe-dev.conf" \
    "$modprobe_root/radeon-unified-profile-dev.conf" ||
    die "duplicate-row rejection does not restore the prior profile"
rm -f "$modprobe_root/zz-duplicate.conf"

rm -f "$refresh_marker"
run_helper select off >"$tmpdir/off.log"
[[ ! -e $modprobe_root/radeon-unified-profile-dev.conf ]] ||
    die "off selection retains the profile override"
[[ -f $refresh_marker ]] || die "off selection omits initramfs refresh"

if run_helper select mutate-dev >"$tmpdir/mutate-nontty.log" 2>&1; then
    die "noninteractive mutate-dev selection bypasses acknowledgement"
fi
grep -Fq 'requires an interactive acknowledgement' "$tmpdir/mutate-nontty.log" ||
    die "mutate-dev rejection omits its acknowledgement diagnostic"

run_helper_tty mutate-dev mutate-dev >"$tmpdir/mutate.log" 2>&1 ||
    die "acknowledged mutate-dev selection fails"
[[ -f $preflight_marker ]] ||
    die "mutate-dev selection omits the hazard preflight"
cmp "$profile_root/mutate-dev.conf" \
    "$modprobe_root/radeon-unified-profile-dev.conf" ||
    die "mutate-dev selection does not copy the canonical template"

if run_helper_tty mutate-dev wrong-answer >"$tmpdir/mutate-refuse.log" 2>&1
then
    die "mutate-dev selection accepts a mismatched acknowledgement"
fi

if run_helper select probe-dev >"$tmpdir/probe.log" 2>&1; then
    die "noninteractive probe-dev selection bypasses acknowledgement"
fi
grep -Fq 'requires an interactive acknowledgement' "$tmpdir/probe.log" ||
    die "probe-dev rejection omits its acknowledgement diagnostic"

run_helper_tty probe-dev probe-dev >"$tmpdir/probe-tty.log" 2>&1 ||
    die "acknowledged probe-dev selection fails"
cmp "$profile_root/probe-dev.conf" \
    "$modprobe_root/radeon-unified-profile-dev.conf" ||
    die "probe-dev selection does not copy the canonical template"

run_helper verify >"$tmpdir/verify.log"
grep -Fq 'installed-attestation: PASS' "$tmpdir/verify.log" ||
    die "installed attestation does not pass its known-good fixture"
grep -Fq 'loaded-attestation: NOT RUN' "$tmpdir/verify.log" ||
    die "verify without a loaded module does not report NOT RUN"

cp "$package_dir/radeon-build-profile.prod.toml" \
    "$source_root/radeon-build-profile.toml"
if run_helper show >"$tmpdir/prod.log" 2>&1; then
    die "development selector accepts a production package manifest"
fi
grep -Fq 'installed build manifest names another package' "$tmpdir/prod.log" ||
    die "production-manifest rejection omits its diagnostic"

printf 'radeon development profile selector calibration: PASS\n'
