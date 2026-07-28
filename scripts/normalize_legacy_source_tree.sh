#!/bin/sh
# Derive the normalized source reference from the legacy payload, and prove the
# normalization loses nothing.
#
# The legacy tree is the historical payload oracle, not the target shape. It
# ships ten *_reg_safe.h headers the build derives from reg_srcs/ through
# mkregtable, ships mkregtable itself as a stripped executable beside its own
# source, and omits reg_srcs/evergreen so one of those headers cannot be
# regenerated. A source repository declines the first two and restores the
# third, so a source export equals this normalized reference rather than the
# raw payload.
#
# The removal is safe only if the generated outputs come back byte-identical
# from source, so --prove-generated rebuilds mkregtable from upstream
# mkregtable.c, regenerates every shipped header, and compares. Evergreen is
# the load-bearing case: its restored input must reproduce the shipped bitmap,
# which is what shows the SMX_DC_CTL0 acceptance was carried faithfully.
#
# Exit: 0 normalized (and proven when asked), 2 missing inputs,
#       3 a regenerated header differs from the one the legacy tree shipped.
set -eu

usage() {
  cat <<'EOF'
usage: normalize_legacy_source_tree.sh --upstream DIR [options]

  --upstream DIR       pristine upstream radeon directory at the recorded base
  --legacy-tree DIR    normalize this tree (default: the full 70-patch tree)
  --out DIR            keep the normalized tree here (default: a temp dir)
  --manifest FILE      write the normalized source manifest here
  --normalization FILE write the per-path transformation record here
  --prove-generated    regenerate every shipped header and compare
EOF
}

upstream=""; legacy_tree=""; out_dir=""; manifest=""; normalization=""; prove=0
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream) upstream=${2:?--upstream needs a directory}; shift 2 ;;
    --legacy-tree) legacy_tree=${2:?--legacy-tree needs a directory}; shift 2 ;;
    --out) out_dir=${2:?--out needs a directory}; shift 2 ;;
    --manifest) manifest=${2:?--manifest needs a path}; shift 2 ;;
    --normalization) normalization=${2:?--normalization needs a path}; shift 2 ;;
    --prove-generated) prove=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$upstream" ] || { usage >&2; exit 2; }
[ -f "$upstream/mkregtable.c" ] || { echo "not an upstream radeon dir: $upstream" >&2; exit 2; }
[ -f "$upstream/reg_srcs/evergreen" ] || { echo "missing upstream reg_srcs/evergreen" >&2; exit 2; }

repo_root=$(git rev-parse --show-toplevel) || { echo "not inside a git repo" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# One normalization implementation serves every oracle. The base oracle and the
# final oracle differ in which tree they hand in, so --legacy-tree names it and
# a second transformation never appears.
if [ -n "$legacy_tree" ]; then
  [ -d "$legacy_tree" ] || { echo "not a directory: $legacy_tree" >&2; exit 2; }
  LEG=$(CDPATH= cd -- "$legacy_tree" && pwd -P)
else
  sh "$repo_root/scripts/materialize_legacy_radeon_tree.sh" --out "$WORK/legacy" \
    --manifest "$WORK/legacy.tsv" >/dev/null 2>&1 || {
    echo "legacy materialization failed" >&2; exit 2; }
  LEG="$WORK/legacy/radeon"
fi

if [ -n "$out_dir" ]; then
  if [ -e "$out_dir" ] && [ -n "$(ls -A "$out_dir" 2>/dev/null)" ]; then
    echo "destination is not empty: $out_dir" >&2
    echo "  a residual file would enter the normalized reference as source" >&2
    exit 2
  fi
  mkdir -p "$out_dir"; NORM=$(CDPATH= cd -- "$out_dir" && pwd)
else
  NORM="$WORK/normalized"; mkdir -p "$NORM"
fi
cp -r "$LEG/." "$NORM/"
# The parentheses are load-bearing: without them -delete binds to the -o branch
# alone and the .orig backups survive into the manifest.
find "$NORM" \( -name '*.orig' -o -name '*.rej' \) -delete 2>/dev/null || true

: > "$WORK/norm.tsv"
printf 'path\tclass\ttransformation\treason\n' >> "$WORK/norm.tsv"

# Generated build products. The build derives each from reg_srcs/ through
# mkregtable, so tracking one lets a stale artifact outrank its source.
for h in "$NORM"/*_reg_safe.h; do
  [ -e "$h" ] || continue
  rel=${h#"$NORM"/}
  printf '%s\tgenerated\tremove\tbuild product derived from reg_srcs by mkregtable\n' \
    "$rel" >> "$WORK/norm.tsv"
  rm -f "$h"
done

# Prebuilt host program occupying the path the build invokes, beside its source.
if [ -e "$NORM/mkregtable" ]; then
  printf 'mkregtable\tprebuilt\tremove\tstripped host executable of unrecorded provenance\n' \
    >> "$WORK/norm.tsv"
  rm -f "$NORM/mkregtable"
fi

# Restore the generator input the snapshot dropped, carrying the acceptance the
# legacy tree expressed only as a cleared bit inside the generated bitmap.
mkdir -p "$NORM/reg_srcs"
awk '
  /^0x0000A0/ && !done { print "0x0000A020 SMX_DC_CTL0"; done=1 }
  { print }
  END { if (!done) print "0x0000A020 SMX_DC_CTL0" }
' "$upstream/reg_srcs/evergreen" > "$NORM/reg_srcs/evergreen"
printf 'reg_srcs/evergreen\trestored\tadd from upstream with 0x0000A020 SMX_DC_CTL0\tgenerator input for evergreen_reg_safe.h\n' \
  >> "$WORK/norm.tsv"

# The patch series adds this generator input, so it exists in the final tree and
# is absent from the base tree. The row follows the tree rather than the
# transformation, which keeps the base record from claiming a path the base
# oracle asserts absent.
if [ -f "$NORM/reg_srcs/rs480" ]; then
  printf 'reg_srcs/rs480\tretained\tpreserve\tgenerator input added by the patch series\n' \
    >> "$WORK/norm.tsv"
fi

if [ "$prove" -eq 1 ]; then
  gcc -O2 -o "$WORK/mkregtable" "$upstream/mkregtable.c" 2>/dev/null || {
    echo "mkregtable did not build from upstream source" >&2; exit 3; }
  pass=0
  for hdr in "$LEG"/*_reg_safe.h; do
    name=$(basename "$hdr" _reg_safe.h)
    src="$NORM/reg_srcs/$name"
    [ -f "$src" ] || { echo "PROOF FAIL: no source for $name" >&2; exit 3; }
    "$WORK/mkregtable" "$src" > "$WORK/$name.h" 2>/dev/null
    if ! cmp -s "$WORK/$name.h" "$hdr"; then
      echo "PROOF FAIL: regenerated ${name}_reg_safe.h differs from the shipped one" >&2
      exit 3
    fi
    pass=$((pass + 1))
  done
  echo "generated-output equivalence: $pass headers regenerate byte-identically" >&2
fi

[ -n "$normalization" ] && cp "$WORK/norm.tsv" "$normalization"

if [ -n "$manifest" ]; then
  sh "$repo_root/scripts/emit_source_tree_manifest.sh" --tree "$NORM" --out "$manifest"
else
  sh "$repo_root/scripts/emit_source_tree_manifest.sh" --tree "$NORM"
fi
exit 0
