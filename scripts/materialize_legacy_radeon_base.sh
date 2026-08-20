#!/bin/sh
# Derive the normalized base source oracle: the legacy tree before any patch.
#
# The final oracle describes the source after all seventy PATCH[] entries, which
# answers what the package builds and answers nothing about origin. Attributing
# a hunk to an upstream backport, a kernel-version adaptation, an RS48X
# mechanism, or a Palm mechanism needs the tree the series starts from, so the
# base-delta map diffs pristine upstream against this oracle rather than against
# the final one.
#
# The construction is the final one minus the series: extract the canonical
# tarball, apply no patch, then hand the tree to normalize_legacy_source_tree.sh
# so both oracles pass through one transformation. reg_srcs/rs480 arrives with
# the series and is absent here, which is the single path separating the two
# manifests.
#
#   base tarball        222 files
#     - 10 *_reg_safe.h generated build products
#     - 1  mkregtable   prebuilt host executable
#     + 1  reg_srcs/evergreen restored generator input
#     = 212 normalized base files
#     + 1  reg_srcs/rs480 added by the series
#     = 213 normalized final files
#
# The counts are asserted rather than reported, so a drifted tarball or a
# changed normalization fails here instead of propagating a wrong base into the
# origin map.
#
# Exit: 0 base oracle emitted, 2 missing inputs or a failed assertion.
set -eu

usage() {
  cat <<'EOF'
usage: materialize_legacy_radeon_base.sh --upstream DIR [options]

  --upstream DIR       pristine upstream radeon directory at the recorded base
  --out DIR            keep the normalized base tree here (default: a temp dir)
  --manifest FILE      write the normalized base manifest here
  --normalization FILE write the per-path transformation record here
  --prove-generated    regenerate every shipped header and compare
EOF
}

upstream=""; out_dir=""; manifest=""; normalization=""; prove=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream) upstream=${2:?--upstream needs a directory}; shift 2 ;;
    --out) out_dir=${2:?--out needs a directory}; shift 2 ;;
    --manifest) manifest=${2:?--manifest needs a path}; shift 2 ;;
    --normalization) normalization=${2:?--normalization needs a path}; shift 2 ;;
    --prove-generated) prove=--prove-generated; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$upstream" ] || { usage >&2; exit 2; }

repo_root=$(git rev-parse --show-toplevel) || { echo "not inside a git repo" >&2; exit 2; }
BASE="$repo_root/sources/radeon-unified-0.3-source.tar.xz"
[ -f "$BASE" ] || { echo "missing base tarball: $BASE" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/base"
tar -xJf "$BASE" -C "$WORK/base"

if [ -n "$out_dir" ]; then
  if [ -e "$out_dir" ] && [ -n "$(ls -A "$out_dir" 2>/dev/null)" ]; then
    echo "destination is not empty: $out_dir" >&2
    exit 2
  fi
  mkdir -p "$out_dir"; NORM=$(CDPATH='' cd -- "$out_dir" && pwd -P)
else
  NORM="$WORK/normalized"; mkdir -p "$NORM"
fi

set -- --upstream "$upstream" --legacy-tree "$WORK/base" --out "$NORM" \
       --manifest "$WORK/base.tsv"
[ -n "$normalization" ] && set -- "$@" --normalization "$normalization"
[ -n "$prove" ] && set -- "$@" "$prove"
sh "$repo_root/scripts/normalize_legacy_source_tree.sh" "$@"

# The base tree predates the series, so the generator input the series adds is
# absent. Its presence would mean a patched tree reached this constructor.
[ -e "$NORM/reg_srcs/rs480" ] && {
  echo "reg_srcs/rs480 is present, so this tree carries the patch series" >&2
  exit 2
}

entries=$(($(grep -cv '^#' "$WORK/base.tsv") - 1))
[ "$entries" -eq 212 ] || {
  echo "normalized base holds $entries entries, and the transformation yields 212" >&2
  exit 2
}
echo "normalized base oracle: $entries entries, reg_srcs/rs480 absent" >&2

if [ -n "$manifest" ]; then
  cp "$WORK/base.tsv" "$manifest"
  echo "normalized base manifest: $manifest" >&2
else
  cat "$WORK/base.tsv"
fi
exit 0
