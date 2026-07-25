#!/bin/sh
# Apply the radeon DKMS patch series to the base source tarball and compile the
# patch-touched translation units against the host kernel.
#
# Why this exists: the PKGBUILD sha256 check (check_pkgbuild_sha256sums.sh)
# proves each patch file matches its declared checksum, but a patch can match its
# checksum and still carry a malformed hunk: a zero-context insert whose target
# line has drifted fuzz-misplaces into an unrelated statement, producing a tree
# that applies "successfully" yet does not compile. A sha check cannot see that;
# only applying the series and compiling the touched units can. This guard closes
# that gap.
#
# The default run reports NOT RUN and exits 0 when the host carries no matching
# kernel build dir, so the apply check still stands on a host that cannot
# compile. --require-compile turns that skip into exit 5, which is the mode a
# CI job uses: a green status then means the units compiled rather than that
# the compile step was absent.
#
# A verdict rests on work actually done, so an empty PATCH[] expansion and an
# empty touched-unit set each exit 2 rather than reporting a pass: a green run
# means at least one patch applied and at least one translation unit reached
# the compiler. --self-test calibrates those two guards against synthetic
# repositories, which is the calibration AGENTS.md requires of a
# verdict-producing script.
#
# Exit: 0 pass (or compile skipped when no kernel build dir is present),
#       2 missing or unparseable inputs, 3 patch reject, 4 compile failure,
#       5 compile required but no kernel build dir.
set -eu

require_compile=0
self_test=0
for arg in "$@"; do
  case "$arg" in
    --require-compile) require_compile=1 ;;
    --self-test) self_test=1 ;;
    -h|--help)
      echo "usage: $0 [--require-compile] [--self-test]"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Build a synthetic repository whose layout matches the real one, so the gate
# under test resolves it through the same git-root discovery path.
make_fixture_repo() {
  fx=$1 dkms_body=$2 patch_target=$3
  mkdir -p "$fx/packaging/arch/radeon-unified-dkms" "$fx/patches/rs480" "$fx/sources"
  ( cd "$fx" && git init -q . && git config user.email c@e && git config user.name c )
  mkdir -p "$fx/stage/radeon"
  printf 'int radeon_probe(void) { return 0; }\n' > "$fx/stage/radeon/foo.c"
  printf 'baseline\n' > "$fx/stage/radeon/notes.txt"
  # The real tarball holds the radeon sources at its top level and the gate
  # extracts it into a radeon/ directory it creates, so the fixture archives
  # the contents rather than the directory.
  ( cd "$fx/stage/radeon" && tar -cJf "$fx/sources/radeon-unified-0.3-source.tar.xz" . )
  printf '%s\n' "$dkms_body" > "$fx/packaging/arch/radeon-unified-dkms/dkms.conf"
  if [ -n "$patch_target" ]; then
    {
      printf -- '--- a/radeon/%s\n' "$patch_target"
      printf -- '+++ b/radeon/%s\n' "$patch_target"
      printf '@@ -1 +1,2 @@\n'
      case "$patch_target" in
        *.c) printf ' int radeon_probe(void) { return 0; }\n' ;;
        *)   printf ' baseline\n' ;;
      esac
      printf '+/* appended by the fixture series */\n'
    } > "$fx/patches/rs480/0001-fixture.patch"
  fi
}

expect_exit() {
  want=$1 label=$2 fx=$3
  got=0
  ( cd "$fx" && sh "$SELF" --require-compile ) >"$fx/out.log" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ok: $label exits $got"
    return 0
  fi
  echo "  CALIBRATION FAIL: $label expected exit $want and got $got" >&2
  sed 's/^/    /' "$fx/out.log" >&2
  return 1
}

expect_not_exit() {
  unwanted=$1 label=$2 fx=$3
  got=0
  ( cd "$fx" && sh "$SELF" --require-compile ) >"$fx/out.log" 2>&1 || got=$?
  if [ "$got" -ne "$unwanted" ]; then
    echo "  ok: $label clears the parse guards (exit $got)"
    return 0
  fi
  echo "  CALIBRATION FAIL: $label tripped a parse guard it should pass" >&2
  sed 's/^/    /' "$fx/out.log" >&2
  return 1
}

if [ "$self_test" -eq 1 ]; then
  SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT INT TERM
  fails=0
  echo "patch-series gate calibration:"

  # Known-bad: dkms.conf carries no parseable PATCH[] entry, so nothing applies.
  make_fixture_repo "$TMP/no_patch_entries" \
    'PACKAGE_NAME="radeon-unified"
# PATCH[0]="0001-fixture.patch"' \
    "foo.c"
  expect_exit 2 "unparseable PATCH[] array" "$TMP/no_patch_entries" || fails=$((fails + 1))

  # Known-bad: the series applies, and it touches no C translation unit, so the
  # compile step would have run against an empty object list.
  make_fixture_repo "$TMP/no_touched_units" \
    'PACKAGE_NAME="radeon-unified"
PATCH[0]="0001-fixture.patch"' \
    "notes.txt"
  expect_exit 2 "series touching no C translation unit" "$TMP/no_touched_units" || fails=$((fails + 1))

  # Known-good shape: a series that applies and touches a C unit clears both
  # parse guards and reaches the compile stage.
  make_fixture_repo "$TMP/well_formed" \
    'PACKAGE_NAME="radeon-unified"
PATCH[0]="0001-fixture.patch"' \
    "foo.c"
  expect_not_exit 2 "series touching a C translation unit" "$TMP/well_formed" || fails=$((fails + 1))

  if [ "$fails" -gt 0 ]; then
    echo "patch-series gate calibration: FAIL ($fails)" >&2
    exit 1
  fi
  echo "patch-series gate calibration: 2 known-bad rejected, 1 known-good cleared"
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel) || { echo "not inside a git repo" >&2; exit 2; }
# Standalone radeon-custom layout: package, patches, and sources live at the
# repository root (not under a nested src/re/radeon tree).
RAD="$repo_root"
DKMSDIR="$RAD/packaging/arch/radeon-unified-dkms"
BASE="$RAD/sources/radeon-unified-0.3-source.tar.xz"
[ -f "$BASE" ] || { echo "missing base tarball: $BASE" >&2; exit 2; }
[ -f "$DKMSDIR/dkms.conf" ] || { echo "missing dkms.conf: $DKMSDIR/dkms.conf" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/radeon"
tar -xJf "$BASE" -C "$WORK/radeon"

# DKMS applies the PATCH[] array with patch -p1 from the directory containing
# radeon/. Mirror that exactly, in declared order.
# Anchored to the start of the line so a commented-out entry stays unparsed:
# DKMS skips it, and applying it here would test a series the package does not
# build.
grep -oE '^[[:space:]]*PATCH\[[0-9]+\]="[^"]+"' "$DKMSDIR/dkms.conf" | sed -E 's/.*="([^"]+)"/\1/' > "$WORK/order.txt"
n=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  [ -f "$RAD/patches/rs480/$p" ] || { echo "PATCH MISSING: $p" >&2; exit 2; }
  if ! ( cd "$WORK" && patch -p1 -s < "$RAD/patches/rs480/$p" ); then
    echo "PATCH REJECT: $p (series does not apply cleanly)" >&2; exit 3
  fi
  n=$((n + 1))
done < "$WORK/order.txt"
echo "patch series applied: $n patches"
# An empty expansion is a parse failure, not a pass. A dkms.conf whose PATCH[]
# entries stop matching yields zero applied patches, and reporting success then
# would certify an untouched tree.
[ "$n" -gt 0 ] || { echo "no PATCH[] entries parsed from dkms.conf" >&2; exit 2; }

# Translation units the series modifies (auto-covers patches added later).
touched=$(while IFS= read -r p; do
            [ -z "$p" ] && continue
            grep -E '^\+\+\+ b/radeon/.*\.c$' "$RAD/patches/rs480/$p" || true
          done < "$WORK/order.txt" | sed -E 's#^\+\+\+ b/radeon/##' | sort -u)
# The series exists to modify radeon translation units, so an empty set means
# the `+++ b/radeon/*.c` extraction broke rather than that there is nothing to
# compile. Reporting success would hand a green verdict to a compiler that ran
# against no file.
[ -n "$touched" ] || { echo "no patch-touched C translation units parsed" >&2; exit 2; }
echo "patch-touched translation units:"; echo "$touched" | sed 's/^/  /'

KB="/lib/modules/$(uname -r)/build"
if [ ! -d "$KB" ]; then
  echo "NOT RUN: no kernel build dir at $KB; apply check passed, compile skipped"
  [ "$require_compile" -eq 0 ] || {
    echo "--require-compile given: a compile verdict needs a kernel build dir" >&2
    exit 5
  }
  exit 0
fi

# Clang-built kernels reject GCC-only flags; match the kernel's compiler.
if grep -qi clang "$KB/include/generated/compile.h" 2>/dev/null; then
  set -- LLVM=1
else
  set --
fi
objs=$(echo "$touched" | sed -E 's/\.c$/.o/' | tr '\n' ' ')
echo "compiling touched units against $(basename "$KB"): $objs"
# shellcheck disable=SC2086
if ! ( cd "$WORK/radeon" && make "$@" EXTRA_CFLAGS='-O2 -pipe' -C "$KB" M="$PWD" $objs ); then
  echo "COMPILE FAIL: a patch-touched translation unit did not compile" >&2
  echo "  a hunk likely fuzz-misplaced; a sha256 match does not catch this" >&2
  exit 4
fi
echo "radeon patch-series compile check: PASS"
