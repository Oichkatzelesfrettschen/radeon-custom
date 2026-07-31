#!/usr/bin/env bash
# Exercise radeon-unified package transitions in a disposable pacstrap root.
#
# The matrix proves the pacman-level package and configuration transitions:
# production install, production-to-development replacement, development
# profile selection, the production admission refusal while a development
# override survives, override cleanup at development removal, and foreign
# override retention. Module compilation is the DKMS lifecycle test's
# domain; the chroot carries no DKMS kernel target, so the hooks no-op and
# every assertion here is about package, source-tree, and modprobe identity.
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
keep_root=0
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
        --keep-root)
            keep_root=1
            shift
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done
[[ -n $prod_package && -n $dev_package ]] ||
    die "--prod-package and --dev-package are required"
[[ -f $prod_package ]] || die "production package is absent: $prod_package"
[[ -f $dev_package ]] || die "development package is absent: $dev_package"
[[ -z $legacy_package || -f $legacy_package ]] ||
    die "legacy package is absent: $legacy_package"
[[ $(id -u) -eq 0 ]] || die "the disposable root requires root"
command -v pacstrap >/dev/null 2>&1 || die "pacstrap is required"
command -v arch-chroot >/dev/null 2>&1 || die "arch-chroot is required"

temp_base=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
root=$(mktemp -d "$temp_base/radeon-package-transitions.XXXXXX")
cleanup() {
    arch-chroot "$root" gpgconf --homedir /etc/pacman.d/gnupg --kill all \
        >/dev/null 2>&1 || true
    if mountpoint -q "$root"; then
        for _ in 1 2 3 4 5; do
            umount "$root" 2>/dev/null && break
            sleep 1
        done
        mountpoint -q "$root" && umount -l "$root"
    fi
    if [[ $keep_root -eq 0 ]]; then
        rm -rf -- "$root"
    else
        log "disposable root retained: $root"
    fi
}
trap cleanup EXIT
# pacman's free-space check resolves the transaction root to a mount point,
# so the disposable directory binds to itself before any chroot transaction.
mount --bind "$root" "$root"

log "constructing disposable root: $root"
pacstrap -c -K "$root" base dkms kmod python >/dev/null
# The stock DKMS transaction hook exits hard when /usr/lib/modules is
# absent. The empty directory gives the hook its mandatory root while still
# presenting no kernel target, so DKMS autoinstall stays a no-op and the
# matrix asserts package and configuration identity alone.
install -d "$root/usr/lib/modules"

install -d "$root/transition-packages"
install -m 0644 "$prod_package" "$root/transition-packages/prod.pkg.tar.zst"
install -m 0644 "$dev_package" "$root/transition-packages/dev.pkg.tar.zst"
if [[ -n $legacy_package ]]; then
    install -m 0644 "$legacy_package" \
        "$root/transition-packages/legacy.pkg.tar.zst"
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

log "row 2: replace production with development"
transaction row2 pacman -U /transition-packages/dev.pkg.tar.zst
assert_state row2-prod-to-dev radeon-unified-dkms-dev radeon-unified-0.4 \
    absent 1

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

log "row 7: development removal cleans a canonical override"
transaction row7-install pacman -U /transition-packages/dev.pkg.tar.zst
in_root radeon-profile-dev select observe-dev >/dev/null
transaction row7-remove pacman -R --noconfirm radeon-unified-dkms-dev
assert_state row7-removal-cleanup none none absent 0

log "row 8: development removal retains a foreign override"
transaction row8-install pacman -U --noconfirm /transition-packages/dev.pkg.tar.zst
printf 'options radeon profile_dev=observe-dev extra_operator_row=1\n' \
    >"$root$override"
transaction row8-remove pacman -R --noconfirm radeon-unified-dkms-dev
[[ -f "$root$override" ]] ||
    die "row8: foreign override content was deleted"
rm -f -- "$root$override"
log "row8-foreign-retention: PASS"

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

log "kernel-upgrade rows: not run (the chroot carries no DKMS kernel target;" \
    "module rebuilds are the DKMS lifecycle test's domain)"
log "radeon package transition matrix: PASS"
