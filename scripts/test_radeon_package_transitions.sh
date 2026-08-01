#!/usr/bin/env bash
# Exercise radeon-unified package transitions in a disposable pacstrap root.
#
# The matrix proves the pacman-level package and configuration transitions:
# production install, production-to-development replacement, development
# profile selection, the production admission refusal while a development
# override survives, override cleanup at development removal, and foreign
# override retention. Without --with-kernel the chroot carries no DKMS
# kernel target, the hooks no-op, and every assertion is about package,
# source-tree, and modprobe identity; --with-kernel adds a real kernel and
# asserts the built module's profile, vermagic, and DKMS state per row.
set -euo pipefail

die() {
    printf 'test_radeon_package_transitions: %s\n' "$*" >&2
    exit 1
}

log() {
    printf 'test_radeon_package_transitions: %s\n' "$*"
}

prod_package=
dev_package=
legacy_package=
policy_package=
keep_root=0
with_kernel=0
cleanup_root=
log_dir=
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
        *)
            die "unknown argument: $1"
            ;;
    esac
done
[[ -z $prod_package || -f $prod_package ]] ||
    die "production package is absent: $prod_package"
[[ -z $dev_package || -f $dev_package ]] ||
    die "development package is absent: $dev_package"
[[ -z $legacy_package || -f $legacy_package ]] ||
    die "legacy package is absent: $legacy_package"
[[ -z $policy_package || -f $policy_package ]] ||
    die "policy package is absent: $policy_package"
[[ $(id -u) -eq 0 ]] || die "the disposable root requires root"
command -v pacstrap >/dev/null 2>&1 || die "pacstrap is required"
command -v arch-chroot >/dev/null 2>&1 || die "arch-chroot is required"

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

temp_base=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
root=$(mktemp -d "$temp_base/radeon-package-transitions.XXXXXX")
matrix_status=0
cleanup() {
    local status=$?
    trap - EXIT
    [[ $matrix_status -eq 0 ]] || status=$matrix_status
    if [[ -n $log_dir ]]; then
        mkdir -p -- "$log_dir"
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
pacstrap -c -K "$root" "${fixture_packages[@]}" >/dev/null
# The stock DKMS transaction hook exits hard when /usr/lib/modules is
# absent. The empty directory gives the hook its mandatory root while still
# presenting no kernel target, so DKMS autoinstall stays a no-op and the
# matrix asserts package and configuration identity alone.
install -d "$root/usr/lib/modules"
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
    in_root dkms status | grep -q 'radeon-unified/0.4.*installed' ||
        die "$label: dkms does not report radeon-unified/0.4 installed"
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
assert_state row1-prod-install radeon-unified-dkms radeon-unified-0.4 \
    absent 0
assert_kernel_module row1-prod-module prod

log "row 2: replace production with development"
transaction row2 pacman -U /transition-packages/dev.pkg.tar.zst
assert_state row2-prod-to-dev radeon-unified-dkms-dev radeon-unified-0.4 \
    absent 1
assert_kernel_module row2-dev-module mutate-dev

log "row 3: select the observe-dev runtime profile"
in_root radeon-profile-dev select observe-dev >/dev/null
assert_state row3-observe-selected radeon-unified-dkms-dev \
    radeon-unified-0.4 present 2

log "row 4: production admission refuses the surviving override"
if transaction row4 pacman -U /transition-packages/prod.pkg.tar.zst \
    2>/dev/null; then
    die "row4: production install succeeds over a development override"
fi
assert_state row4-admission-refusal radeon-unified-dkms-dev \
    radeon-unified-0.4 present 2

log "row 5: select off removes the override"
in_root radeon-profile-dev select off >/dev/null
assert_state row5-profile-off radeon-unified-dkms-dev radeon-unified-0.4 \
    absent 1

log "row 6: replace development with production"
transaction row6 pacman -U /transition-packages/prod.pkg.tar.zst
assert_state row6-dev-to-prod radeon-unified-dkms radeon-unified-0.4 \
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
    radeon-unified-0.4 absent 0
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
fi

transaction row8c-remove pacman -R --noconfirm radeon-unified-dkms

if [[ -n $legacy_package ]]; then
    log "row 9: roll production back to the legacy package"
    transaction row9-prod pacman -U --noconfirm /transition-packages/prod.pkg.tar.zst
    transaction row9-legacy pacman -U /transition-packages/legacy.pkg.tar.zst
    actual_src=$(find "$root/usr/src" -mindepth 1 -maxdepth 1 \
        -name 'radeon-unified-*' -printf '%f\n' | sort | paste -sd, -)
    [[ $actual_src == radeon-unified-0.3 ]] ||
        die "row9: rollback source roots are ${actual_src:-none}"
    [[ ! -d "$root/usr/src/radeon-unified-0.4" ]] ||
        die "row9: profiled source root survives the rollback"
    log "row9-legacy-rollback: PASS"
else
    log "row 9 legacy rollback: not run (no --legacy-package artifact supplied)"
fi

if [[ $with_kernel -eq 0 ]]; then
    log "kernel rows: not run (pass --with-kernel for a real DKMS kernel target)"
fi
log "radeon package transition matrix: PASS"
