#!/usr/bin/env bash
# shellcheck disable=SC2154
# PKGBUILD sourcing defines the package metadata checked below.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$repo_root/packaging/arch/radeon-unified-dkms"
pkgbuild="$package_dir/PKGBUILD"
identity="$package_dir/source-identity.toml"
source_repository=${RADEON_UNIFIED_SOURCE_REPOSITORY:-}
package_path=
expected_sha256=

die() {
    printf 'verify_radeon_unified_dkms_package: %s\n' "$*" >&2
    exit 1
}

hash_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

valid_sha256() {
    [[ $1 =~ ^[0-9a-f]{64}$ ]]
}

preflight_archive() {
    local archive=$1
    local normalized_manifest=$2
    local raw_manifest="$normalized_manifest.raw"
    local verbose_manifest="$normalized_manifest.verbose"
    local member
    local normalized

    LC_ALL=C bsdtar -tf "$archive" >"$raw_manifest" ||
        die "cannot list package archive"
    LC_ALL=C bsdtar --numeric-owner -tvf "$archive" >"$verbose_manifest" ||
        die "cannot inspect package archive members"
    [[ -s $raw_manifest ]] || die "package archive has no members"
    if awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" {
            found = 1
        }
        END { exit found ? 0 : 1 }' "$verbose_manifest"; then
        die "archive contains a symbolic link, hard link, or special file"
    fi
    if awk '$3 != "0" || $4 != "0" { found = 1 }
            END { exit found ? 0 : 1 }' "$verbose_manifest"; then
        die "archive contains a member whose numeric UID or GID is not zero"
    fi
    if awk '$1 ~ /^d/ &&
            $1 != "drwxr-xr-x" { found = 1 }
            END { exit found ? 0 : 1 }' "$verbose_manifest"; then
        die "archive directory mode is not 755"
    fi
    if awk '$1 ~ /^-/ &&
            $1 != "-rw-r--r--" &&
            $1 != "-rwxr-xr-x" { found = 1 }
            END { exit found ? 0 : 1 }' "$verbose_manifest"; then
        die "archive regular file mode is neither 644 nor 755"
    fi

    : >"$normalized_manifest"
    while IFS= read -r member; do
        normalized=${member#./}
        [[ -n $normalized ]] || continue
        case "/$normalized/" in
            *'/../'*)
                die "archive member contains parent traversal: $member"
                ;;
        esac
        [[ $normalized != /* ]] ||
            die "archive member is absolute: $member"
        printf '%s\n' "$normalized" >>"$normalized_manifest"
    done <"$raw_manifest"
    if [[ $(sort "$normalized_manifest" | uniq -d | wc -l) -ne 0 ]]; then
        die "archive contains duplicate normalized member names"
    fi
}

pkginfo_values() {
    local field=$1
    local pkginfo=$2

    awk -F ' = ' -v field="$field" '$1 == field {
        print substr($0, index($0, " = ") + 3)
    }' "$pkginfo"
}

assert_pkginfo_scalar() {
    local field=$1
    local expected=$2
    local pkginfo=$3
    local -a actual=()

    mapfile -t actual < <(pkginfo_values "$field" "$pkginfo")
    [[ ${#actual[@]} -eq 1 && ${actual[0]} == "$expected" ]] ||
        die ".PKGINFO $field does not equal the selected PKGBUILD value"
}

assert_pkginfo_array() {
    local field=$1
    local pkginfo=$2
    local expected_file=$3
    local actual_file=$4

    shift 4
    printf '%s\n' "$@" | sed '/^$/d' | sort >"$expected_file"
    pkginfo_values "$field" "$pkginfo" | sort >"$actual_file"
    cmp -s "$expected_file" "$actual_file" ||
        die ".PKGINFO $field entries do not equal the selected PKGBUILD"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-repository)
            [[ $# -ge 2 ]] || die "--source-repository requires a path"
            source_repository=$2
            shift 2
            ;;
        --expected-sha256)
            [[ $# -ge 2 ]] || die "--expected-sha256 requires a digest"
            expected_sha256=$2
            shift 2
            ;;
        --package)
            [[ $# -ge 2 ]] || die "--package requires a path"
            package_path=$2
            shift 2
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            [[ -z $package_path ]] || die "multiple package paths supplied"
            package_path=$1
            shift
            ;;
    esac
done

if [[ -z $source_repository ]]; then
    source_repository="$repo_root/../linux-radeon-gororoba"
fi
python3 "$repo_root/scripts/check_radeon_source_pin.py" \
    --identity "$identity" \
    --repository "$source_repository" \
    --pkgbuild "$pkgbuild"
python3 "$repo_root/scripts/check_radeon_package_profiles.py" >/dev/null

# shellcheck disable=SC2034
startdir=$package_dir
# shellcheck source=/dev/null
source "$pkgbuild"

if [[ -z $package_path ]]; then
    mapfile -t package_candidates < <(
        find "$package_dir" -maxdepth 1 -type f \
            \( -name "radeon-unified-dkms-${pkgver}-${pkgrel}-*.pkg.tar.zst" -o \
            -name "radeon-unified-dkms-dev-${pkgver}-${pkgrel}-*.pkg.tar.zst" -o \
            -name "radeon-unified-dkms-${pkgver}-${pkgrel}-*.pkg.tar.xz" -o \
            -name "radeon-unified-dkms-dev-${pkgver}-${pkgrel}-*.pkg.tar.xz" \) |
            sort
    )
    [[ ${#package_candidates[@]} -eq 1 ]] ||
        die "pass --package when zero or multiple split packages are present"
    package_path=${package_candidates[0]}
fi
[[ -n $package_path && -f $package_path && ! -L $package_path ]] ||
    die "built package is absent or not a regular file"

temp_root=${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}
mkdir -p "$temp_root"
tmpdir=$(mktemp -d "$temp_root/radeon-package-admission.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
admitted_package="$tmpdir/admitted-package.pkg.tar"
install -m 0400 -- "$package_path" "$admitted_package"
package_sha256=$(hash_file "$admitted_package")
if [[ -n $expected_sha256 ]]; then
    valid_sha256 "$expected_sha256" ||
        die "expected package SHA-256 is not canonical lowercase hex"
    [[ $package_sha256 == "$expected_sha256" ]] ||
        die "admitted package SHA-256 differs from the expected digest"
fi

archive_manifest="$tmpdir/archive-members.txt"
preflight_archive "$admitted_package" "$archive_manifest"
extracted_root="$tmpdir/package"
expected_radeon="$tmpdir/expected-radeon"
actual_tree_manifest="$tmpdir/actual-tree.tsv"
expected_tree_manifest="$tmpdir/expected-tree.tsv"
expected_files="$tmpdir/expected-files.txt"
expected_members="$tmpdir/expected-members.txt"
mkdir "$extracted_root" "$expected_radeon"
: >"$expected_files"
bsdtar -xpf "$admitted_package" -C "$extracted_root"

pkginfo="$extracted_root/.PKGINFO"
[[ -f $pkginfo && ! -L $pkginfo ]] ||
    die "package metadata is absent or not a regular file"
for metadata_file in .BUILDINFO .MTREE .PKGINFO; do
    metadata_path="$extracted_root/$metadata_file"
    [[ -f $metadata_path && ! -L $metadata_path ]] ||
        die "package metadata is not a regular file: $metadata_file"
    [[ $(stat -c %a "$metadata_path") == 644 ]] ||
        die "package metadata mode is not 644: $metadata_file"
done
mapfile -t actual_package_names < <(pkginfo_values pkgname "$pkginfo")
[[ ${#actual_package_names[@]} -eq 1 ]] ||
    die ".PKGINFO does not contain exactly one package name"
actual_package_name=${actual_package_names[0]}
case $actual_package_name in
    radeon-unified-dkms)
        profile_suffix=prod
        expected_pkgdesc=$_prod_pkgdesc
        expected_optdepends=()
        expected_conflicts=('radeon-unified-dkms-dev' "${_legacy_conflicts[@]}")
        ;;
    radeon-unified-dkms-dev)
        profile_suffix=dev
        expected_pkgdesc=$_dev_pkgdesc
        expected_optdepends=("${_dev_optdepends[@]}")
        expected_conflicts=('radeon-unified-dkms' "${_legacy_conflicts[@]}")
        ;;
    *)
        die "unexpected split package name: $actual_package_name"
        ;;
esac
assert_pkginfo_scalar pkgname "$actual_package_name" "$pkginfo"
assert_pkginfo_scalar pkgbase "$pkgbase" "$pkginfo"
assert_pkginfo_scalar pkgver "${pkgver}-${pkgrel}" "$pkginfo"
assert_pkginfo_scalar pkgdesc "$expected_pkgdesc" "$pkginfo"
assert_pkginfo_scalar url "$url" "$pkginfo"
assert_pkginfo_array arch "$pkginfo" "$tmpdir/arch.expected" \
    "$tmpdir/arch.actual" "${arch[@]}"
assert_pkginfo_array license "$pkginfo" "$tmpdir/license.expected" \
    "$tmpdir/license.actual" "${license[@]}"
assert_pkginfo_array depend "$pkginfo" "$tmpdir/depend.expected" \
    "$tmpdir/depend.actual" "${depends[@]}"
assert_pkginfo_array optdepend "$pkginfo" "$tmpdir/optdepend.expected" \
    "$tmpdir/optdepend.actual" "${expected_optdepends[@]}"
assert_pkginfo_array makedepend "$pkginfo" "$tmpdir/makedepend.expected" \
    "$tmpdir/makedepend.actual" "${makedepends[@]}"
assert_pkginfo_array provides "$pkginfo" "$tmpdir/provides.expected" \
    "$tmpdir/provides.actual" "${_common_provides[@]}"
assert_pkginfo_array conflict "$pkginfo" "$tmpdir/conflict.expected" \
    "$tmpdir/conflict.actual" "${expected_conflicts[@]}"
assert_pkginfo_array replaces "$pkginfo" "$tmpdir/replaces.expected" \
    "$tmpdir/replaces.actual" "${_legacy_replaces[@]}"

mapfile -t source_roots < <(
    find "$extracted_root/usr/src" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | sort
)
[[ ${#source_roots[@]} -eq 1 ]] ||
    die "package must contain exactly one DKMS source root"
[[ ${source_roots[0]} == "radeon-unified-${pkgver}" ]] ||
    die "unexpected DKMS source root: ${source_roots[0]}"
dkms_relative="usr/src/${source_roots[0]}"
dkms_root="$extracted_root/$dkms_relative"
while IFS= read -r -d '' directory; do
    case $directory in
        "$extracted_root"|"$dkms_root/radeon"|"$dkms_root/radeon/"*)
            continue
            ;;
    esac
    [[ $(stat -c %a "$directory") == 755 ]] ||
        die "package infrastructure directory mode is not 755: ${directory#"$extracted_root/"}"
done < <(find "$extracted_root" -type d -print0)

check_member() {
    local canonical_path=$1
    local archive_path=$2
    local expected_mode=$3
    local label=$4
    local installed_path="$extracted_root/$archive_path"
    local actual_mode

    printf '%s\n' "$archive_path" >>"$expected_files"
    [[ -f $installed_path && ! -L $installed_path ]] ||
        die "$label is absent or not a regular file"
    [[ $(hash_file "$installed_path") == "$(hash_file "$canonical_path")" ]] ||
        die "$label differs from its package input"
    actual_mode=$(stat -c %a "$installed_path")
    [[ $actual_mode == "$expected_mode" ]] ||
        die "$label mode is $actual_mode, expected $expected_mode"
}

check_member "$package_dir/source-identity.toml" \
    "$dkms_relative/source-identity.toml" 644 source-identity.toml
check_member "$package_dir/dkms.conf.${profile_suffix}" \
    "$dkms_relative/dkms.conf" 644 dkms.conf
check_member "$package_dir/radeon-build-profile.${profile_suffix}.toml" \
    "$dkms_relative/radeon-build-profile.toml" 644 \
    radeon-build-profile.toml
check_member "$package_dir/radeon-build-profile.${profile_suffix}.h" \
    "$dkms_relative/radeon-build-profile.h" 644 radeon-build-profile.h
check_member "$package_dir/pre-build.sh" \
    "$dkms_relative/pre-build.sh" 755 pre-build.sh
check_member "$package_dir/dkms-initramfs-refresh.sh" \
    "$dkms_relative/dkms-initramfs-refresh.sh" 755 dkms-initramfs-refresh.sh
check_member "$package_dir/compiler-policy.conf" \
    "$dkms_relative/compiler-policy.conf" 644 compiler-policy.conf
check_member "$package_dir/radeon-dkms-compiler-policy" \
    "$dkms_relative/radeon-dkms-compiler-policy" 755 \
    radeon-dkms-compiler-policy
check_member "$package_dir/radeon-dkms-compiler" \
    "$dkms_relative/radeon-dkms-compiler" 755 radeon-dkms-compiler
check_member "$package_dir/radeon-dkms-make" \
    "$dkms_relative/radeon-dkms-make" 755 radeon-dkms-make
check_member "$package_dir/radeon-dkms-ccache-gcc" \
    "$dkms_relative/radeon-dkms-ccache-gcc" 755 radeon-dkms-ccache-gcc
check_member "$package_dir/radeon-dkms-ccache-clang" \
    "$dkms_relative/radeon-dkms-ccache-clang" 755 radeon-dkms-ccache-clang
check_member "$package_dir/radeon-unified-mkinitcpio.conf" \
    "etc/mkinitcpio.conf.d/radeon-unified.conf" 644 \
    radeon-unified-mkinitcpio.conf
check_member "$package_dir/radeon-re.conf" \
    "etc/modprobe.d/radeon-re.conf" 644 radeon-re.conf
if [[ $profile_suffix == dev ]]; then
    check_member "$package_dir/radeon-dev.conf" \
        "etc/modprobe.d/radeon-unified-dev.conf" 644 radeon-dev.conf
    for profile in observe-dev probe-dev mutate-dev; do
        check_member "$package_dir/${profile}.conf" \
            "usr/share/radeon-unified/profiles/${profile}.conf" 644 \
            "${profile}.conf"
    done
    check_member "$package_dir/radeon-profile-dev" \
        "usr/bin/radeon-profile-dev" 755 radeon-profile-dev
fi

git -C "$source_repository" -c tar.umask=0022 archive \
    "${_source_commit}:drivers/gpu/drm/radeon" |
    bsdtar -xpf - -C "$expected_radeon"
(cd "$expected_radeon" && find . -printf '%y\t%m\t%P\t%l\n' | sort) \
    >"$expected_tree_manifest"
(cd "$dkms_root/radeon" && find . -printf '%y\t%m\t%P\t%l\n' | sort) \
    >"$actual_tree_manifest"
cmp "$expected_tree_manifest" "$actual_tree_manifest" ||
    die "installed Radeon path, type, mode, or link manifest differs from git archive"
diff -qr "$expected_radeon" "$dkms_root/radeon" >/dev/null ||
    die "installed Radeon bytes differ from git archive"

while IFS= read -r -d '' source_path; do
    relative=${source_path#"$expected_radeon/"}
    [[ $relative != "$source_path" ]] || continue
    if [[ -f $source_path ]]; then
        printf '%s\n' "$dkms_relative/radeon/$relative" >>"$expected_files"
    fi
done < <(find "$expected_radeon" -type f -print0 | sort -z)

{
    printf '%s\n' .BUILDINFO .MTREE .PKGINFO
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        printf '%s\n' "$path"
        directory=$(dirname -- "$path")
        while [[ $directory != . ]]; do
            printf '%s/\n' "$directory"
            directory=$(dirname -- "$directory")
        done
    done <"$expected_files"
} | sort -u >"$expected_members"
sort -u "$archive_manifest" -o "$archive_manifest"
cmp "$expected_members" "$archive_manifest" ||
    die "archive member manifest differs from the closed package payload"

entry_count=$(find "$dkms_root/radeon" -type f | wc -l)
expected_entry_count=$(git -C "$source_repository" ls-tree -r --name-only \
    "${_source_commit}:drivers/gpu/drm/radeon" | wc -l)
[[ $entry_count -eq $expected_entry_count ]] ||
    die "installed Radeon archive has $entry_count entries, expected $expected_entry_count"

printf 'package_sha256=%s\n' "$package_sha256"
printf 'package_profile=%s\n' "$profile_suffix"
printf 'radeon unified DKMS package source export: PASS (%s)\n' "$package_path"
