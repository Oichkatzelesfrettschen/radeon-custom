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
# Exit: 0 pass (or compile skipped when no kernel build dir is present),
#       2 missing inputs, 3 patch reject, 4 compile failure.
set -eu

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
grep -oE 'PATCH\[[0-9]+\]="[^"]+"' "$DKMSDIR/dkms.conf" | sed -E 's/.*="([^"]+)"/\1/' > "$WORK/order.txt"
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

# Translation units the series modifies (auto-covers patches added later).
touched=$(while IFS= read -r p; do
            [ -z "$p" ] && continue
            grep -E '^\+\+\+ b/radeon/.*\.c$' "$RAD/patches/rs480/$p" || true
          done < "$WORK/order.txt" | sed -E 's#^\+\+\+ b/radeon/##' | sort -u)
[ -n "$touched" ] || { echo "no .c translation units touched by the series" >&2; exit 0; }
echo "patch-touched translation units:"; echo "$touched" | sed 's/^/  /'

KB="/lib/modules/$(uname -r)/build"
if [ ! -d "$KB" ]; then
  echo "NOT RUN: no kernel build dir at $KB; apply check passed, compile skipped"
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
