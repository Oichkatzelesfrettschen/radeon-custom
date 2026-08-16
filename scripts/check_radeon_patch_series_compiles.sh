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
# The series carries a LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0) split in
# radeon_gem.c, so the running kernel selects which side of it compiles.
# --kernel-build-root names a prepared tree explicitly, which is how the pre-7.0
# side reaches a compiler on a host running 7.x. Resolution order is
# --kernel-build-root, then R300_RS480_KERNEL_BUILD_ROOT, then the running
# kernel at /lib/modules/$(uname -r)/build.
#
# Exit: 0 pass (or compile skipped when no kernel build dir is present),
#       2 missing or unparseable inputs, 3 patch reject, 4 compile failure,
#       5 compile required but no kernel build dir.
set -eu

require_compile=0
self_test=0
kernel_build_root=${R300_RS480_KERNEL_BUILD_ROOT:-}
dkms_conf=${RADEON_LEGACY_DKMS_CONF:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-compile) require_compile=1; shift ;;
    --self-test) self_test=1; shift ;;
    --kernel-build-root)
      [ "$#" -ge 2 ] || { echo "--kernel-build-root requires a directory" >&2; exit 2; }
      kernel_build_root=$2; shift 2
      ;;
    --dkms-conf)
      [ "$#" -ge 2 ] || { echo "--dkms-conf requires a file" >&2; exit 2; }
      dkms_conf=$2; shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--require-compile] [--self-test] [--kernel-build-root DIR] [--dkms-conf FILE]"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
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

# Every calibration case runs the gate under test as a child process and reads
# its exit status, so the guards are exercised through the same entry point a CI
# job uses. Trailing arguments after the fixture reach that child.
expect_exit() {
  want=$1 label=$2 fx=$3
  shift 3
  got=0
  ( cd "$fx" && sh "$SELF" "$@" ) >"$fx/out.log" 2>&1 || got=$?
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
  shift 3
  got=0
  ( cd "$fx" && sh "$SELF" "$@" ) >"$fx/out.log" 2>&1 || got=$?
  if [ "$got" -ne "$unwanted" ]; then
    echo "  ok: $label clears the parse guards (exit $got)"
    return 0
  fi
  echo "  CALIBRATION FAIL: $label tripped a parse guard it should pass" >&2
  sed 's/^/    /' "$fx/out.log" >&2
  return 1
}

# The retained pre-7.0 root was compiled by its kernel package's own clang, so
# the host compiler drifts ahead of it between package updates and Kbuild
# reports the difference. That notice is the one explained diagnostic; every
# other warning in a compile log is a defect until explained, so the scan
# fails on it.
scan_compile_warnings() {
  unexpected=$(grep -in 'warning' "$1" |
    grep -iv 'the compiler differs from the one used to build the kernel' || true)
  if [ -n "$unexpected" ]; then
    echo "COMPILE WARNINGS: the log carries warnings outside the allowlist" >&2
    printf '%s\n' "$unexpected" | sed 's/^/  /' >&2
    return 1
  fi
  return 0
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
  expect_exit 2 "unparseable PATCH[] array" "$TMP/no_patch_entries" \
    --require-compile || fails=$((fails + 1))

  # Known-bad: the series applies, and it touches no C translation unit, so the
  # compile step would have run against an empty object list.
  make_fixture_repo "$TMP/no_touched_units" \
    'PACKAGE_NAME="radeon-unified"
PATCH[0]="0001-fixture.patch"' \
    "notes.txt"
  expect_exit 2 "series touching no C translation unit" "$TMP/no_touched_units" \
    --require-compile || fails=$((fails + 1))

  # Known-good shape: a series that applies and touches a C unit clears both
  # parse guards and reaches the compile stage.
  make_fixture_repo "$TMP/well_formed" \
    'PACKAGE_NAME="radeon-unified"
PATCH[0]="0001-fixture.patch"' \
    "foo.c"
  expect_not_exit 2 "series touching a C translation unit" "$TMP/well_formed" \
    --require-compile || fails=$((fails + 1))

  # Build-root resolution. Each case names a way the root can be wrong, and the
  # gate distinguishes them: an option carrying no value is a usage error, an
  # absent root is a missing prerequisite the strict mode refuses to skip, and a
  # directory lacking the Kbuild surface is an invalid root rather than an
  # absent one.
  expect_exit 2 "--kernel-build-root without an argument" "$TMP/well_formed" \
    --require-compile --kernel-build-root || fails=$((fails + 1))

  expect_exit 5 "explicit nonexistent root under --require-compile" "$TMP/well_formed" \
    --require-compile --kernel-build-root "$TMP/absent" || fails=$((fails + 1))

  # A directory that exists and carries none of the Kbuild surface. The gate
  # reports the first missing file rather than entering make.
  mkdir -p "$TMP/stub_root"
  expect_exit 2 "existing directory missing the prepared-kernel surface" "$TMP/well_formed" \
    --require-compile --kernel-build-root "$TMP/stub_root" || fails=$((fails + 1))

  # The environment path resolves the same way the option does, and without
  # --require-compile an absent root reports NOT RUN and exits 0 so the apply
  # check still stands on a host that cannot compile. The running-kernel
  # fallback is the default every ordinary run exercises.
  got=0
  ( cd "$TMP/well_formed" && R300_RS480_KERNEL_BUILD_ROOT="$TMP/absent" sh "$SELF" ) \
    >"$TMP/well_formed/env.log" 2>&1 || got=$?
  if [ "$got" -eq 0 ] && grep -q '^NOT RUN: ' "$TMP/well_formed/env.log"; then
    echo "  ok: absent environment root without strict mode reports NOT RUN and exits 0"
  else
    echo "  CALIBRATION FAIL: absent environment root without strict mode" >&2
    sed 's/^/    /' "$TMP/well_formed/env.log" >&2
    fails=$((fails + 1))
  fi

  # Warning-scan calibration: a clean log and the allowlisted compiler-differs
  # notice pass; any other warning fails.
  printf 'CC [M] radeon_gem.o\nLD [M] radeon.ko\n' > "$TMP/clean.log"
  printf 'warning: the compiler differs from the one used to build the kernel\nCC [M] radeon_gem.o\n' > "$TMP/allowed.log"
  printf 'rs400.c:12:5: warning: unused variable [-Wunused-variable]\n' > "$TMP/bad.log"
  printf 'WARNING: modpost found an unresolved symbol\n' > "$TMP/bad-uppercase.log"
  if scan_compile_warnings "$TMP/clean.log" && \
     scan_compile_warnings "$TMP/allowed.log" 2>/dev/null && \
     ! scan_compile_warnings "$TMP/bad.log" 2>/dev/null && \
     ! scan_compile_warnings "$TMP/bad-uppercase.log" 2>/dev/null; then
    echo "  ok: warning scan passes clean and allowlisted logs, fails on lowercase and uppercase warnings"
  else
    echo "  CALIBRATION FAIL: warning scan verdicts" >&2
    fails=$((fails + 1))
  fi

  if [ "$fails" -gt 0 ]; then
    echo "patch-series gate calibration: FAIL ($fails)" >&2
    exit 1
  fi
  echo "patch-series gate calibration: 6 known-bad rejected, 4 known-good cleared"
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel) || { echo "not inside a git repo" >&2; exit 2; }
# Standalone radeon-custom layout: package, patches, and sources live at the
# repository root (not under a nested src/re/radeon tree).
RAD="$repo_root"
DKMSDIR="$RAD/packaging/arch/radeon-unified-dkms"
BASE="$RAD/sources/radeon-unified-0.3-source.tar.xz"
[ -n "$dkms_conf" ] || dkms_conf="$DKMSDIR/dkms.conf"
[ -f "$BASE" ] || { echo "missing base tarball: $BASE" >&2; exit 2; }
[ -f "$dkms_conf" ] || { echo "missing dkms.conf: $dkms_conf" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/radeon"
tar -xJf "$BASE" -C "$WORK/radeon"

# DKMS applies the PATCH[] array with patch -p1 from the directory containing
# radeon/. Mirror that exactly, in declared order.
# Anchored to the start of the line so a commented-out entry stays unparsed:
# DKMS skips it, and applying it here would test a series the package does not
# build.
grep -oE '^[[:space:]]*PATCH\[[0-9]+\]="[^"]+"' "$dkms_conf" |
  sed -E 's/.*="([^"]+)"/\1/' > "$WORK/order.txt"
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

if [ -n "$kernel_build_root" ]; then
  KB=$kernel_build_root
else
  KB="/lib/modules/$(uname -r)/build"
fi
if [ ! -d "$KB" ]; then
  echo "NOT RUN: no kernel build dir at $KB; apply check passed, compile skipped"
  [ "$require_compile" -eq 0 ] || {
    echo "--require-compile given: a compile verdict needs a kernel build dir" >&2
    exit 5
  }
  exit 0
fi
KB=$(CDPATH='' cd -- "$KB" && pwd -P)

# A directory alone is not a prepared kernel tree. Kbuild for an external module
# needs the top Makefile, the exported symbol table, and the generated
# configuration headers, and a tree missing any of them fails deep inside make
# with a message that reads as a source defect. Naming the missing file here
# keeps a stub headers directory from being diagnosed as a patch problem.
for required in \
  Makefile \
  Module.symvers \
  include/config/kernel.release \
  include/generated/autoconf.h \
  include/generated/compile.h \
  include/generated/uapi/linux/version.h
do
  [ -r "$KB/$required" ] || {
    echo "invalid kernel build root: missing $KB/$required" >&2
    exit 2
  }
done

kernel_release=$(cat "$KB/include/config/kernel.release")
version_code=$(awk '$1 == "#define" && $2 == "LINUX_VERSION_CODE" { print $3 }' \
                 "$KB/include/generated/uapi/linux/version.h")
[ -n "$version_code" ] || { echo "cannot resolve LINUX_VERSION_CODE from $KB" >&2; exit 2; }

# The version code decides which side of the radeon_gem.c split compiles, so it
# is reported rather than inferred from the directory name.
echo "kernel build root: $KB"
echo "kernel release: $kernel_release"
echo "LINUX_VERSION_CODE: $version_code"

# Clang-built kernels reject GCC-only flags; match the kernel's compiler.
# CONFIG_CC_IS_CLANG is the recorded configuration, and compile.h carries the
# version banner, so the configuration answers first and the banner covers a
# tree shipped without auto.conf.
if grep -q '^CONFIG_CC_IS_CLANG=y' "$KB/include/config/auto.conf" 2>/dev/null ||
   grep -qi clang "$KB/include/generated/compile.h" 2>/dev/null; then
  set -- LLVM=1
else
  set --
fi
objs=$(echo "$touched" | sed -E 's/\.c$/.o/' | tr '\n' ' ')
echo "compiling touched units against $kernel_release: $objs"
compile_log="$WORK/compile.log"
# shellcheck disable=SC2086
compile_status=0
build_jobs=$(nproc 2>/dev/null || echo 1)
( cd "$WORK/radeon" && "$DKMSDIR/radeon-dkms-make" "$@" -j"$build_jobs" -C "$KB" M="$PWD" $objs ) \
  >"$compile_log" 2>&1 || compile_status=$?
cat "$compile_log"
if [ "$compile_status" -ne 0 ]; then
  echo "COMPILE FAIL: a patch-touched translation unit did not compile" >&2
  echo "  a hunk likely fuzz-misplaced; a sha256 match does not catch this" >&2
  exit 4
fi
if ! scan_compile_warnings "$compile_log"; then
  exit 4
fi
echo "radeon patch-series compile check: PASS"
