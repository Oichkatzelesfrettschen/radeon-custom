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
source_root="$fixture_root/usr/src/radeon-unified-0.3"
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
        printf '%s\n' 9f74840dcc542f84bf396247ee4aba6de52e24f4
        ;;
    gororoba_feature_policy_sha256)
        printf '%s\n' 1cc57d53a5493ad79d61463960632a3a3ecdbd2b1836e228fc4e74f22421669f
        ;;
    gororoba_upstream_base)
        printf '%s\n' 7d0a66e4bb9081d75c82ec4957c50034cb0ea449
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

show_output=$(run_helper show)
grep -Fxq 'build_profile=all-dev' <<<"$show_output" ||
    die "show omits the all-dev build identity"
grep -Fxq 'selected_profile=off' <<<"$show_output" ||
    die "show does not report the closed default"

run_helper select observe-dev >"$tmpdir/observe.log"
cmp "$profile_root/observe-dev.conf" \
    "$modprobe_root/radeon-unified-profile-dev.conf" ||
    die "observe-dev selection does not copy the canonical template"
[[ -f $refresh_marker ]] || die "observe-dev selection omits initramfs refresh"

if RADEON_PROFILE_REFRESH_FAIL=1 \
        run_helper select mutate-dev >"$tmpdir/rollback.log" 2>&1; then
    die "profile selection accepts a failed initramfs refresh"
fi
grep -Fq 'prior profile was restored' "$tmpdir/rollback.log" ||
    die "initramfs failure omits its rollback diagnostic"
cmp "$profile_root/observe-dev.conf" \
    "$modprobe_root/radeon-unified-profile-dev.conf" ||
    die "initramfs failure does not restore the prior profile"

rm -f "$refresh_marker"
run_helper select off >"$tmpdir/off.log"
[[ ! -e $modprobe_root/radeon-unified-profile-dev.conf ]] ||
    die "off selection retains the profile override"
[[ -f $refresh_marker ]] || die "off selection omits initramfs refresh"

run_helper select mutate-dev >"$tmpdir/mutate.log"
[[ -f $preflight_marker ]] ||
    die "mutate-dev selection omits the hazard preflight"
cmp "$profile_root/mutate-dev.conf" \
    "$modprobe_root/radeon-unified-profile-dev.conf" ||
    die "mutate-dev selection does not copy the canonical template"

if run_helper select probe-dev >"$tmpdir/probe.log" 2>&1; then
    die "noninteractive probe-dev selection bypasses acknowledgement"
fi
grep -Fq 'requires an interactive acknowledgement' "$tmpdir/probe.log" ||
    die "probe-dev rejection omits its acknowledgement diagnostic"

run_helper verify >"$tmpdir/verify.log"
grep -Fq 'attestation: PASS' "$tmpdir/verify.log" ||
    die "module attestation does not pass its known-good fixture"

cp "$package_dir/radeon-build-profile.prod.toml" \
    "$source_root/radeon-build-profile.toml"
if run_helper show >"$tmpdir/prod.log" 2>&1; then
    die "development selector accepts a production package manifest"
fi
grep -Fq 'installed build manifest names another package' "$tmpdir/prod.log" ||
    die "production-manifest rejection omits its diagnostic"

printf 'radeon development profile selector calibration: PASS\n'
