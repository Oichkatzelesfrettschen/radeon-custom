#!/bin/sh
# Emit a content manifest for a source tree in the common schema.
#
# Three constructors in this repository and one in linux-radeon-gororoba compare
# manifests against each other, so all four emit one schema. The declaration
# line names it, and a consumer that parses the token refuses a cross-schema
# comparison instead of reporting every path as changed.
#
#   # manifest-schema: gororoba-source-tree-v1
#   path<TAB>mode<TAB>size<TAB>sha256
#
# Modes are git modes rather than a three-digit permission or a two-way
# executable flag. A source tree's identity distinguishes 100644 from 100755
# from 120000, and an encoding that collapses those accepts a tree shipping a
# program as data or a symlink as a regular file.
#
# A symlink's identity is where it points, so its size and digest come from the
# link target bytes rather than from the file it resolves to. A retargeted link
# then compares unequal, and a link pointing outside the tree needs no
# dereference.
#
# GNU patch writes *.orig and *.rej beside a hunk it could not place cleanly.
# Those are construction artifacts of the apply step rather than source, so
# every constructor excludes them and the rule lives here once.
#
# Rows sort by path under C collation, which is byte order, so two manifests
# built on different hosts compare with cmp.
#
# Exit: 0 manifest emitted, 2 missing inputs, 1 calibration failure.
set -eu

SCHEMA='gororoba-source-tree-v1'

usage() {
  cat <<'EOF'
usage: emit_source_tree_manifest.sh --tree DIR [--out FILE]
       emit_source_tree_manifest.sh --self-test

  --tree DIR   the source tree to describe
  --out FILE   write the manifest here (default: stdout)
  --self-test  calibrate every drift class the manifest claims to detect
EOF
}

tree=""; out=""; self_test=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) tree=${2:?--tree needs a directory}; shift 2 ;;
    --out) out=${2:?--out needs a path}; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

emit() {
  root=$1
  printf '# manifest-schema: %s\n' "$SCHEMA"
  printf 'path\tmode\tsize\tsha256\n'
  ( cd "$root" && find . \( -type f -o -type l \) \
      ! -name '*.orig' ! -name '*.rej' -print ) \
    | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r rel; do
        f="$root/$rel"
        if [ -L "$f" ]; then
          target=$(readlink "$f")
          mode=120000
          size=$(printf '%s' "$target" | wc -c)
          sum=$(printf '%s' "$target" | sha256sum | cut -d' ' -f1)
        else
          if [ -x "$f" ]; then mode=100755; else mode=100644; fi
          size=$(stat -c '%s' "$f")
          sum=$(sha256sum "$f" | cut -d' ' -f1)
        fi
        printf '%s\t%s\t%s\t%s\n' "$rel" "$mode" "$size" "$sum"
      done
}

if [ "$self_test" -eq 1 ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT INT TERM
  fails=0
  echo "source-manifest emitter calibration:"

  T="$TMP/tree"
  mkdir -p "$T/reg_srcs"
  printf 'int probe(void) { return 0; }\n' > "$T/r300.c"
  printf 'r300 0x4000 GB_VAP_RASTER_STREAM_CLIENT_CNTL\n' > "$T/reg_srcs/r300"
  printf '#!/bin/sh\ntrue\n' > "$T/mkregtable.sh"
  chmod 755 "$T/mkregtable.sh"
  ln -s r300.c "$T/alias.c"
  base=$(emit "$T")

  check() {
    if [ "$2" = "yes" ]; then echo "  ok: $1"; else
      echo "  CALIBRATION FAIL: $1" >&2; fails=$((fails + 1)); fi
  }
  first=$(printf '%s\n' "$base" | sed -n 1p)
  [ "$first" = "# manifest-schema: $SCHEMA" ] && r=yes || r=no
  check "schema declaration is the first line" "$r"
  printf '%s\n' "$base" | grep -q '^r300\.c	100644	' && r=yes || r=no
  check "regular file records 100644" "$r"
  printf '%s\n' "$base" | grep -q '^mkregtable\.sh	100755	' && r=yes || r=no
  check "executable records 100755" "$r"
  # The target is the six bytes "r300.c", so the row carries the link target's
  # length rather than the length of the file it resolves to.
  printf '%s\n' "$base" | grep -q '^alias\.c	120000	6	' && r=yes || r=no
  check "symlink records 120000 and the target length" "$r"

  # Each mutation is a way a tree can drift while still looking plausible, and
  # the manifest exists to make each of them a textual difference.
  mutate() {
    label=$1; shift
    M="$TMP/mutated"
    rm -rf "$M"; cp -a "$T" "$M"
    ( cd "$M" && eval "$@" )
    [ "$(emit "$M")" != "$base" ] && r=yes || r=no
    check "$label" "$r"
  }
  mutate "changed content detected" "printf 'int probe(void) { return 1; }\n' > r300.c"
  mutate "changed executable bit detected" "chmod 644 mkregtable.sh"
  mutate "retargeted symlink detected" "ln -sfn reg_srcs/r300 alias.c"
  mutate "unexpected path detected" "printf 'x\n' > extra.c"
  mutate "missing path detected" "rm reg_srcs/r300"

  # A patch backup is a construction artifact, so its presence leaves the
  # manifest unchanged rather than adding a row.
  M="$TMP/backup"; rm -rf "$M"; cp -a "$T" "$M"
  printf 'stale\n' > "$M/r300.c.orig"
  printf 'stale\n' > "$M/r300.c.rej"
  [ "$(emit "$M")" = "$base" ] && r=yes || r=no
  check "patch backups stay out of the manifest" "$r"

  if [ "$fails" -gt 0 ]; then
    echo "source-manifest emitter calibration: FAIL ($fails)" >&2
    exit 1
  fi
  echo "source-manifest emitter calibration: 4 encodings correct, 6 drift classes detected"
  exit 0
fi

[ -n "$tree" ] || { usage >&2; exit 2; }
[ -d "$tree" ] || { echo "not a directory: $tree" >&2; exit 2; }
TREE=$(CDPATH= cd -- "$tree" && pwd -P)

if [ -n "$out" ]; then
  emit "$TREE" > "$out"
  echo "manifest: $out ($(($(grep -cv '^#' "$out") - 1)) entries)" >&2
else
  emit "$TREE"
fi
exit 0
