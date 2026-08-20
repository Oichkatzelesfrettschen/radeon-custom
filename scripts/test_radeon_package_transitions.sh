#!/usr/bin/env bash
# Exercise radeon-unified package transitions in a disposable pacstrap root.
#
# The matrix proves the pacman-level package and configuration transitions:
# production install, production-to-development replacement, development
# profile selection, the production admission refusal while a development
# override survives, override cleanup at development removal, and foreign
# override retention. Without --with-kernel the chroot carries no DKMS kernel
# target and same-name /dev/null links suppress the stock DKMS hooks. Every
# assertion in that lane covers package, source-tree, and modprobe identity.
# --with-kernel retains the stock hooks and asserts the built module's profile,
# vermagic, and DKMS state per row.
# --temp-root selects an existing writable directory for the disposable root.
# Without it, RUNNER_TEMP, TMPDIR, or /var/tmp supplies the temporary parent.
set -euo pipefail

die() {
    printf 'test_radeon_package_transitions: %s\n' "$*" >&2
    exit 1
}

log() {
    printf 'test_radeon_package_transitions: %s\n' "$*"
}

validate_temp_root() {
    local candidate=$1

    [[ -d $candidate && ! -L $candidate && -w $candidate ]]
}

dkms_hooks=(
    70-dkms-install.hook
    70-dkms-upgrade.hook
    71-dkms-remove.hook
)

install_dkms_hook_suppression() {
    local fixture_root=$1
    local dkms_hook

    install -d "$fixture_root/etc/pacman.d/hooks"
    for dkms_hook in "${dkms_hooks[@]}"; do
        ln -s /dev/null "$fixture_root/etc/pacman.d/hooks/$dkms_hook"
    done
}

verify_dkms_hook_suppression() {
    local fixture_root=$1
    local dkms_hook

    for dkms_hook in "${dkms_hooks[@]}"; do
        [[ -L $fixture_root/etc/pacman.d/hooks/$dkms_hook ]] || return 1
        [[ $(readlink "$fixture_root/etc/pacman.d/hooks/$dkms_hook") == /dev/null ]] ||
            return 1
    done
}

write_fixture_pacman_config() {
    local fixture_root=$1

    [[ $fixture_root == /* && $fixture_root != *$'\n'* ]] || return 1
    awk -v fixture_root="$fixture_root" '
        /^(RootDir|DBPath|HookDir|GPGDir|LogFile) = / {
            next
        }
        /^\[/ {
            if (extra_count == 1 && $0 != "[extra]")
                exit
            if ($0 == "[options]")
                options_count++
            else if ($0 == "[core]")
                core_count++
            else if ($0 == "[extra]")
                extra_count++
        }
        { print }
        $0 == "[options]" {
            print "HookDir = " fixture_root "/etc/pacman.d/hooks/"
            print "GPGDir = " fixture_root "/etc/pacman.d/gnupg/"
            print "LogFile = " fixture_root "/var/log/pacman.log"
        }
        END {
            if (options_count != 1 || core_count != 1 || extra_count != 1)
                exit 1
        }
    '
}

run_self_test() {
    local expected_config filtered_config hook_fixture raw_config tmpdir

    tmpdir=$(mktemp -d "${TMPDIR:-/var/tmp}/radeon-package-transitions-self-test.XXXXXX")
    trap 'rm -rf -- "$tmpdir"' RETURN
    mkdir -p -- "$tmpdir/good"
    validate_temp_root "$tmpdir/good" ||
        die "temporary root validator rejects its known-good calibration"
    : >"$tmpdir/regular-file"
    if validate_temp_root "$tmpdir/regular-file"; then
        die "temporary root validator accepts a regular file"
    fi
    if validate_temp_root "$tmpdir/absent"; then
        die "temporary root validator accepts an absent directory"
    fi
    if validate_temp_root ''; then
        die "temporary root validator accepts an empty path"
    fi
    ln -s -- "$tmpdir/good" "$tmpdir/symlink"
    if validate_temp_root "$tmpdir/symlink"; then
        die "temporary root validator accepts a symbolic link"
    fi

    raw_config="$tmpdir/pacman.conf.raw"
    filtered_config="$tmpdir/pacman.conf.filtered"
    expected_config="$tmpdir/pacman.conf.expected"
    printf '%s\n' \
        '[options]' \
        'RootDir = /' \
        'DBPath = /var/lib/pacman/' \
        'HookDir = /etc/pacman.d/hooks/' \
        'GPGDir = /etc/pacman.d/gnupg/' \
        'LogFile = /var/log/pacman.log' \
        'Architecture = x86_64' \
        '[cachyos]' \
        'Server = https://packages.example.invalid/cachyos' \
        '[core]' \
        'Server = https://packages.example.invalid/core' \
        '[extra]' \
        'Server = https://packages.example.invalid/extra' \
        '[blackarch]' \
        'Server = https://packages.example.invalid/blackarch' \
        >"$raw_config"
    printf '%s\n' \
        '[options]' \
        'HookDir = /fixture-root/etc/pacman.d/hooks/' \
        'GPGDir = /fixture-root/etc/pacman.d/gnupg/' \
        'LogFile = /fixture-root/var/log/pacman.log' \
        'Architecture = x86_64' \
        '[cachyos]' \
        'Server = https://packages.example.invalid/cachyos' \
        '[core]' \
        'Server = https://packages.example.invalid/core' \
        '[extra]' \
        'Server = https://packages.example.invalid/extra' \
        >"$expected_config"
    write_fixture_pacman_config /fixture-root \
        <"$raw_config" >"$filtered_config" ||
        die "fixture repository filter rejects its known-good calibration"
    cmp "$filtered_config" "$expected_config" ||
        die "fixture repository filter admits repositories after extra"
    if printf '%s\n' '[options]' '[core]' |
        write_fixture_pacman_config /fixture-root >/dev/null; then
        die "fixture repository filter accepts a missing extra repository"
    fi
    if printf '%s\n' '[options]' '[core]' '[extra]' '[extra]' |
        write_fixture_pacman_config /fixture-root >/dev/null; then
        die "fixture repository filter accepts duplicate extra repositories"
    fi
    hook_fixture="$tmpdir/hook-fixture"
    install_dkms_hook_suppression "$hook_fixture"
    verify_dkms_hook_suppression "$hook_fixture" ||
        die "hook suppression verifier rejects the known-good links"
    ln -sfn /tmp/not-dev-null \
        "$hook_fixture/etc/pacman.d/hooks/70-dkms-upgrade.hook"
    if verify_dkms_hook_suppression "$hook_fixture"; then
        die "hook suppression verifier accepts a wrong link target"
    fi
    printf '%s\n' \
        'radeon package transition calibration: 3 known-good and 7 known-bad cases'
}

prod_package=
dev_package=
legacy_package=
policy_package=
hazard_package=
watchdog_package=
keep_root=0
with_kernel=0
cleanup_root=
log_dir=
temp_root_override=
temp_root_set=0
self_test=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --prod-package)
            [[ $# -ge 2 ]] || die "--prod-package requires a path"
            prod_package=$2
            shift 2
            ;;
        --dev-package)
            [[ $# -ge 2 ]] || die "--dev-package requires a path"
            dev_package=$2
            shift 2
            ;;
        --legacy-package)
            [[ $# -ge 2 ]] || die "--legacy-package requires a path"
            legacy_package=$2
            shift 2
            ;;
        --policy-package)
            [[ $# -ge 2 ]] || die "--policy-package requires a path"
            policy_package=$2
            shift 2
            ;;
        --hazard-package)
            [[ $# -ge 2 ]] || die "--hazard-package requires a path"
            hazard_package=$2
            shift 2
            ;;
        --watchdog-package)
            [[ $# -ge 2 ]] || die "--watchdog-package requires a path"
            watchdog_package=$2
            shift 2
            ;;
        --keep-root)
            keep_root=1
            shift
            ;;
        --with-kernel)
            with_kernel=1
            shift
            ;;
        --cleanup-root)
            [[ $# -ge 2 ]] || die "--cleanup-root requires a path"
            cleanup_root=$2
            shift 2
            ;;
        --log-dir)
            [[ $# -ge 2 ]] || die "--log-dir requires a path"
            log_dir=$2
            shift 2
            ;;
        --temp-root)
            [[ $# -ge 2 ]] || die "--temp-root requires a path"
            [[ -n $2 ]] || die "--temp-root requires a non-empty path"
            temp_root_override=$2
            temp_root_set=1
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
[[ -z $prod_package || -f $prod_package ]] ||
    die "production package is absent: $prod_package"
[[ -z $dev_package || -f $dev_package ]] ||
    die "development package is absent: $dev_package"
[[ -z $legacy_package || -f $legacy_package ]] ||
    die "legacy package is absent: $legacy_package"
[[ -z $policy_package || -f $policy_package ]] ||
    die "policy package is absent: $policy_package"
[[ -z $hazard_package || -f $hazard_package ]] ||
    die "hazard package is absent: $hazard_package"
[[ -z $watchdog_package || -f $watchdog_package ]] ||
    die "watchdog package is absent: $watchdog_package"
[[ -z $hazard_package || -n $watchdog_package ]] ||
    die "--hazard-package requires --watchdog-package for its dependency"
[[ $(id -u) -eq 0 ]] || die "the disposable root requires root"
command -v pacstrap >/dev/null 2>&1 || die "pacstrap is required"
command -v arch-chroot >/dev/null 2>&1 || die "arch-chroot is required"
command -v pacman-conf >/dev/null 2>&1 || die "pacman-conf is required"

# Cleanup is part of the verdict: a chroot gpg-agent, a surviving mount, or
# a root that resists deletion converts a passing matrix into a failure, so
# privileged state never outlives the declared lifecycle silently.
destroy_root() {
    local target=$1 failed=0 mounts

    pkill -f -- "--homedir ${target}/" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        mounts=$(findmnt -Rrn -o TARGET "$target" 2>/dev/null || true)
        [[ -n $mounts ]] || break
        while IFS= read -r mount_target; do
            umount -- "$mount_target" 2>/dev/null || true
        done < <(printf '%s\n' "$mounts" | tac)
        sleep 1
    done
    if findmnt -Rrn -o TARGET "$target" 2>/dev/null | grep -q .; then
        printf 'test_radeon_package_transitions: mounts survive under %s\n' \
            "$target" >&2
        return 1
    fi
    rm -rf --one-file-system -- "$target" || failed=1
    if [[ -e $target ]]; then
        printf 'test_radeon_package_transitions: root survives removal: %s\n' \
            "$target" >&2
        failed=1
    fi
    return "$failed"
}

if [[ -n $cleanup_root ]]; then
    [[ -e $cleanup_root ]] || die "cleanup root is absent: $cleanup_root"
    case $cleanup_root in
        */radeon-package-transitions.*) ;;
        *) die "cleanup root is not a transition-matrix root: $cleanup_root" ;;
    esac
    destroy_root "$cleanup_root" || die "cleanup failed for $cleanup_root"
    log "cleanup-root: PASS ($cleanup_root)"
    exit 0
fi
[[ -n $prod_package && -n $dev_package ]] ||
    die "--prod-package and --dev-package are required"

# The installed source root and dkms version follow the packaged pkgver, so
# derive them from the prod package basename rather than pinning a release.
pkgver=$(basename "$prod_package" | sed -E 's/^radeon-unified-dkms-([^-]+)-.*/\1/')
[[ -n $pkgver ]] || die "cannot derive pkgver from $prod_package"
src_root="radeon-unified-${pkgver}"
if [[ -n $legacy_package ]]; then
    legacy_pkgver=$(basename "$legacy_package" |
        sed -E 's/^radeon-unified-dkms-([^-]+)-.*/\1/')
    [[ -n $legacy_pkgver ]] || die "cannot derive pkgver from $legacy_package"
fi

if [[ $temp_root_set -eq 1 ]]; then
    temp_base=$temp_root_override
else
    temp_base=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
fi
validate_temp_root "$temp_base" ||
    die "temporary transition root is absent, indirect, or not writable: $temp_base"
root=$(mktemp -d "$temp_base/radeon-package-transitions.XXXXXX")
matrix_status=0
cleanup() {
    local status=$?
    trap - EXIT
    [[ $matrix_status -eq 0 ]] || status=$matrix_status
    if [[ -n $log_dir ]]; then
        mkdir -p -- "$log_dir"
        cp -- "$root"/pacstrap.log "$log_dir"/ 2>/dev/null || true
        cp -- "$root"/transition-packages/*.log "$log_dir"/ 2>/dev/null || true
    fi
    if [[ $keep_root -eq 1 ]]; then
        log "disposable root retained: $root"
        exit "$status"
    fi
    if ! destroy_root "$root"; then
        printf 'test_radeon_package_transitions: cleanup FAILED for %s\n' \
            "$root" >&2
        [[ $status -ne 0 ]] || status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'matrix_status=$?' ERR
# pacman's free-space check resolves the transaction root to a mount point,
# so the disposable directory binds to itself before any chroot transaction.
mount --bind "$root" "$root"

log "constructing disposable root: $root"
fixture_packages=(base dkms kmod python)
if [[ $with_kernel -eq 1 ]]; then
    fixture_packages+=(linux linux-headers)
fi
# The fixture exercises Arch package transactions and uses no multilib or
# third-party package. The resolved host configuration through extra preserves
# CachyOS precedence while excluding unrelated repositories whose availability
# carries no evidence for this matrix. Root-sensitive path directives leave so
# pacstrap roots its database, hooks, keyring, and log inside the fixture.
# pacstrap copies the matching host keyring because those keys authorize the
# selected repositories.
fixture_pacman_config="$root/radeon-package-transition-pacman.conf"
install -d "$root/etc/pacman.d/hooks"
pacman-conf | write_fixture_pacman_config "$root" \
    >"$fixture_pacman_config" ||
    die "host pacman configuration lacks one options, core, or extra section"
fixture_repositories=$(sed -n 's/^\[\([^]]*\)\]$/\1/p' \
    "$fixture_pacman_config" | grep -vx options | paste -sd, -)
[[ -n $fixture_repositories ]] || die "fixture repository set is empty"
log "fixture repositories: $fixture_repositories"
pacstrap_log="$root/pacstrap.log"
if ! pacstrap -C "$fixture_pacman_config" -c "$root" \
    "${fixture_packages[@]}" >"$pacstrap_log" 2>&1; then
    cat "$pacstrap_log" >&2
    die "pacstrap cannot construct the fixture root"
fi
if grep -q 'error: command failed to execute correctly' "$pacstrap_log"; then
    cat "$pacstrap_log" >&2
    die "a pacstrap package scriptlet failed"
fi
if [[ $with_kernel -eq 0 ]]; then
    # alpm-hooks(5) defines a same-name /dev/null link as hook suppression.
    # Package-only rows carry no kernel target, so the stock DKMS install,
    # upgrade, and removal hooks have no verdict role. The --with-kernel lane
    # retains those hooks and asserts their real module outputs.
    install_dkms_hook_suppression "$root"
    verify_dkms_hook_suppression "$root" ||
        die "stock DKMS hook suppression is incomplete"
fi
if [[ $with_kernel -eq 1 ]]; then
    # pacstrap installs the kernel without a bootloader flow, so no
    # mkinitcpio preset exists and the selector's initramfs refresh would
    # fail on an empty /etc/mkinitcpio.d. A minimal preset for the fixture
    # kernel lets mkinitcpio -P run for real inside the chroot.
    fixture_release=$(find "$root/usr/lib/modules" -mindepth 1 -maxdepth 1 \
        -type d -printf '%f\n' | sort | head -n 1)
    [[ -n $fixture_release ]] || die "kernel fixture installed no modules"
    install -d "$root/etc/mkinitcpio.d"
    cat >"$root/etc/mkinitcpio.d/linux.preset" <<PRESET
ALL_kver="/usr/lib/modules/${fixture_release}/vmlinuz"
PRESETS=('default')
default_image="/boot/initramfs-linux.img"
PRESET
fi

install -d "$root/transition-packages"
install -m 0644 "$prod_package" "$root/transition-packages/prod.pkg.tar.zst"
install -m 0644 "$dev_package" "$root/transition-packages/dev.pkg.tar.zst"
if [[ -n $legacy_package ]]; then
    install -m 0644 "$legacy_package" \
        "$root/transition-packages/legacy.pkg.tar.zst"
fi
if [[ -n $policy_package ]]; then
    install -m 0644 "$policy_package" \
        "$root/transition-packages/policy.pkg.tar.zst"
fi
if [[ -n $hazard_package ]]; then
    install -m 0644 "$hazard_package" \
        "$root/transition-packages/hazard.pkg.tar.zst"
    install -m 0644 "$watchdog_package" \
        "$root/transition-packages/watchdog.pkg.tar.zst"
fi

in_root() {
    arch-chroot "$root" "$@"
}

# pacman closes stdin once its prompts are answered, so a long-lived yes(1)
# writer dies with SIGPIPE under pipefail; a bounded printf answers the
# conflict-removal and proceed prompts and exits cleanly. The transaction log
# prints on failure so a scriptlet error names itself.
transaction() {
    local label=$1
    shift
    local log_file="$root/transition-packages/${label}.log"
    if ! printf 'y\ny\n' | in_root "$@" >"$log_file" 2>&1; then
        cat "$log_file" >&2
        return 1
    fi
    if grep -q 'error: command failed to execute correctly' "$log_file"; then
        cat "$log_file" >&2
        die "$label: a package scriptlet failed inside the transaction"
    fi
}

override=/etc/modprobe.d/radeon-unified-profile-dev.conf

installed_package() {
    in_root pacman -Qq radeon-unified-dkms 2>/dev/null ||
        in_root pacman -Qq radeon-unified-dkms-dev 2>/dev/null ||
        printf '%s\n' none
}

profile_dev_rows() {
    in_root modprobe -c 2>/dev/null | awk '
        $1 == "options" && $2 == "radeon" {
            for (i = 3; i <= NF; i++)
                if ($i ~ /^profile_dev=/) print $i
        }' | wc -l
}

kernel_release() {
    find "$root/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | sort | head -n 1
}

# With the kernel fixture the pacman transaction drives the real DKMS hook,
# so the built module attests the build profile, source commit, and vermagic
# of the disposable kernel.
assert_kernel_module() {
    local label=$1 expected_profile=$2 release module actual

    [[ $with_kernel -eq 1 ]] || return 0
    release=$(kernel_release)
    [[ -n $release ]] || die "$label: kernel fixture has no modules directory"
    module="/usr/lib/modules/${release}/updates/dkms/radeon.ko.zst"
    [[ -f "$root$module" ]] ||
        die "$label: DKMS module is absent: $module"
    actual=$(in_root modinfo -F gororoba_build_profile "$module")
    [[ $actual == "$expected_profile" ]] ||
        die "$label: module build profile is $actual, expected $expected_profile"
    actual=$(in_root modinfo -F vermagic "$module")
    [[ $actual == "$release "* ]] ||
        die "$label: module vermagic ${actual%% *} does not match $release"
    in_root dkms status | grep -q "radeon-unified/${pkgver}.*installed" ||
        die "$label: dkms does not report radeon-unified/${pkgver} installed"
    log "$label: PASS (kernel $release)"
}

assert_state() {
    local label=$1 expected_pkg=$2 expected_src=$3 expected_override=$4
    local expected_rows=$5
    local actual_pkg actual_src actual_rows

    actual_pkg=$(installed_package)
    [[ $actual_pkg == "$expected_pkg" ]] ||
        die "$label: installed package is $actual_pkg, expected $expected_pkg"
    actual_src=$(find "$root/usr/src" -mindepth 1 -maxdepth 1 \
        -name 'radeon-unified-*' -printf '%f\n' | sort | paste -sd, -)
    [[ ${actual_src:-none} == "$expected_src" ]] ||
        die "$label: source roots are ${actual_src:-none}, expected $expected_src"
    if [[ $expected_override == present ]]; then
        [[ -f "$root$override" ]] ||
            die "$label: profile override is absent"
    else
        [[ ! -e "$root$override" ]] ||
            die "$label: profile override survives"
    fi
    actual_rows=$(profile_dev_rows)
    [[ $actual_rows -eq $expected_rows ]] ||
        die "$label: effective profile_dev row count is $actual_rows, expected $expected_rows"
    if [[ $expected_pkg == radeon-unified-dkms ]]; then
        [[ ! -e "$root/etc/modprobe.d/radeon-unified-dev.conf" ]] ||
            die "$label: development modprobe policy survives under production"
        [[ ! -d "$root/usr/share/radeon-unified/profiles" ]] ||
            die "$label: development profile templates survive under production"
    fi
    log "$label: PASS"
}

log "row 1: install the production package"
transaction row1 pacman -U --noconfirm /transition-packages/prod.pkg.tar.zst
assert_state row1-prod-install radeon-unified-dkms "$src_root" \
    absent 0
assert_kernel_module row1-prod-module prod

log "row 2: replace production with development"
transaction row2 pacman -U /transition-packages/dev.pkg.tar.zst
assert_state row2-prod-to-dev radeon-unified-dkms-dev "$src_root" \
    absent 1
assert_kernel_module row2-dev-module mutate-dev

log "row 3: select the observe-dev runtime profile"
in_root radeon-profile-dev select observe-dev >/dev/null
assert_state row3-observe-selected radeon-unified-dkms-dev \
    "$src_root" present 2

log "row 4: production admission refuses the surviving override"
if transaction row4 pacman -U /transition-packages/prod.pkg.tar.zst \
    2>/dev/null; then
    die "row4: production install succeeds over a development override"
fi
assert_state row4-admission-refusal radeon-unified-dkms-dev \
    "$src_root" present 2

log "row 5: select off removes the override"
in_root radeon-profile-dev select off >/dev/null
assert_state row5-profile-off radeon-unified-dkms-dev "$src_root" \
    absent 1

log "row 6: replace development with production"
transaction row6 pacman -U /transition-packages/prod.pkg.tar.zst
assert_state row6-dev-to-prod radeon-unified-dkms "$src_root" \
    absent 0
assert_kernel_module row6-prod-module prod

if [[ $with_kernel -eq 1 ]]; then
    log "row 6k: kernel reinstall reproduces the production module"
    transaction row6k pacman -S --noconfirm linux
    assert_kernel_module row6k-kernel-upgrade prod
fi

log "row 7: the removal guard retires a canonical override"
transaction row7-install pacman -U /transition-packages/dev.pkg.tar.zst
in_root radeon-profile-dev select observe-dev >/dev/null
transaction row7-remove pacman -R --noconfirm radeon-unified-dkms-dev
assert_state row7-removal-cleanup none none absent 0

log "row 8a: a foreign override blocks development removal"
transaction row8-install pacman -U --noconfirm /transition-packages/dev.pkg.tar.zst
printf 'options radeon profile_dev=observe-dev extra_operator_row=1\n' \
    >"$root$override"
if transaction row8a pacman -R --noconfirm radeon-unified-dkms-dev \
    2>/dev/null; then
    die "row8a: development removal succeeds over a foreign override"
fi
[[ -f "$root$override" ]] ||
    die "row8a: foreign override content was deleted by a refused removal"
in_root pacman -Qq radeon-unified-dkms-dev >/dev/null ||
    die "row8a: development package was removed despite the refusal"
log "row8a-foreign-blocks-removal: PASS"

log "row 8b: operator cleanup permits development removal"
rm -f -- "$root$override"
transaction row8b pacman -R --noconfirm radeon-unified-dkms-dev
assert_state row8b-removal-after-cleanup none none absent 0

log "row 8c: production installs on the emptied configuration"
transaction row8c pacman -U --noconfirm /transition-packages/prod.pkg.tar.zst
assert_state row8c-prod-after-cleanup radeon-unified-dkms \
    "$src_root" absent 0
if [[ -n $policy_package ]]; then
    # arch-chroot binds the host /sys, so the board-policy admission sees
    # the real PCI inventory: the target host admits the policy package and
    # any other machine calibrates the refusal path.
    if find /sys/bus/pci/devices -maxdepth 2 -name device -exec cat {} + \
        2>/dev/null | grep -qx 0x5974; then
        log "row 10: target host admits the RS482 board policy"
        transaction row10 pacman -U --noconfirm \
            /transition-packages/policy.pkg.tar.zst
        [[ -f "$root/etc/modprobe.d/radeon-re.conf" ]] ||
            die "row10: admitted policy package installed no board policy"
        transaction row10-remove pacman -R --noconfirm radeon-rs482-policy
        log "row10-policy-admitted: PASS"
    else
        log "row 10: non-target host refuses the RS482 board policy"
        if transaction row10 pacman -U --noconfirm \
            /transition-packages/policy.pkg.tar.zst 2>/dev/null; then
            die "row10: board policy installs on a non-target host"
        fi
        [[ ! -e "$root/etc/modprobe.d/radeon-re.conf" ]] ||
            die "row10: refused policy transaction left board policy behind"
        log "row10-policy-refused: PASS"
    fi
else
    log "row 10 board policy: not run (no --policy-package artifact supplied)"
fi

transaction row8c-remove pacman -R --noconfirm radeon-unified-dkms

if [[ -n $hazard_package ]]; then
    # The hazard stack depends on the shared radeon-unified capability, so
    # the prod<->dev module swap keeps it installed; a literal module-name
    # dependency would let pacman drop the safety stack in the exact
    # transition a mutation campaign requires.
    log "row 11: hazard stack survives the prod<->dev module swap"
    transaction row11-prod pacman -U --noconfirm \
        /transition-packages/prod.pkg.tar.zst
    transaction row11-substrate pacman -U --noconfirm \
        /transition-packages/watchdog.pkg.tar.zst \
        /transition-packages/hazard.pkg.tar.zst
    in_root pacman -Qq rs480-reset-hazard-stack >/dev/null ||
        die "row11: hazard stack did not install alongside production"
    transaction row11-to-dev pacman -U /transition-packages/dev.pkg.tar.zst
    in_root pacman -Qq rs480-reset-hazard-stack >/dev/null ||
        die "row11: hazard stack was removed by the prod-to-dev swap"
    in_root pacman -Qq radeon-unified-dkms-dev >/dev/null ||
        die "row11: development module is absent after the swap"
    transaction row11-to-prod pacman -U /transition-packages/prod.pkg.tar.zst
    in_root pacman -Qq rs480-reset-hazard-stack >/dev/null ||
        die "row11: hazard stack was removed by the dev-to-prod swap"
    log "row11-hazard-stack-survival: PASS"
    transaction row11-remove pacman -R --noconfirm \
        rs480-reset-hazard-stack sp5100-tco-ioapic-dkms radeon-unified-dkms
else
    log "row 11 hazard-stack survival: not run (pass --hazard-package and --watchdog-package)"
fi

if [[ -n $legacy_package ]]; then
    log "row 9: roll production back to the legacy package"
    transaction row9-prod pacman -U --noconfirm /transition-packages/prod.pkg.tar.zst
    transaction row9-legacy pacman -U /transition-packages/legacy.pkg.tar.zst
    actual_src=$(find "$root/usr/src" -mindepth 1 -maxdepth 1 \
        -name 'radeon-unified-*' -printf '%f\n' | sort | paste -sd, -)
    [[ $actual_src == "radeon-unified-${legacy_pkgver}" ]] ||
        die "row9: rollback source roots are ${actual_src:-none}"
    [[ ! -d "$root/usr/src/${src_root}" ]] ||
        die "row9: profiled source root survives the rollback"
    log "row9-legacy-rollback: PASS"
else
    log "row 9 legacy rollback: not run (no --legacy-package artifact supplied)"
fi

if [[ $with_kernel -eq 0 ]]; then
    log "kernel rows: not run (pass --with-kernel to add real DKMS kernel assertions" \
        "to package rows whose artifacts this invocation supplies)"
fi
log "supplied radeon package transition rows: PASS"
