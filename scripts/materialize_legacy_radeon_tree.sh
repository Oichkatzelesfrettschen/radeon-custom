#!/bin/sh
# Materialize the legacy Radeon source tree and record its content manifest.
#
# The tree this produces is the historical payload oracle: the exact source the
# Arch DKMS path builds today, formed by extracting the canonical tarball and
# applying the anchored PATCH[] entries from dkms.conf in declared order.
#
# A source repository export does not equal this tree, and equality here is the
# wrong acceptance rule. This tree carries ten pre-generated *_reg_safe.h
# headers and a prebuilt mkregtable executable, which are build products a
# source repository declines to track, and it omits reg_srcs/evergreen, which a
# source repository restores so the SMX_DC_CTL0 acceptance has a generator
# input. Demanding raw equality would fail the clean source precisely because
# it removed those artifacts.
#
# The acceptance rule is two statements: an export equals the normalized source
# reference, which is this tree with those exclusions and that restoration
# applied, and regenerating from the export reproduces the generated outputs
# this tree shipped. Compile equality is weaker than either and substitutes for
# neither.
#
# emit_source_tree_manifest.sh writes the manifest, in the schema every
# constructor here and in linux-radeon-gororoba shares, so a comparison detects
# content drift, mode drift, and file-set drift alike.
#
# Exit: 0 tree materialized, 2 missing or unparseable inputs, 3 patch reject.
set -eu

usage() {
  cat <<'EOF'
usage: materialize_legacy_radeon_tree.sh [--out DIR] [--manifest FILE]
                                         [--dkms-conf FILE]

  --out DIR        keep the materialized tree at DIR (default: a temp dir)
  --manifest FILE  write the content manifest to FILE (default: stdout)
  --dkms-conf FILE read the historical patch order from FILE
EOF
}

out_dir=""
manifest=""
dkms_conf=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out_dir=${2:?--out needs a directory}; shift 2 ;;
    --manifest) manifest=${2:?--manifest needs a path}; shift 2 ;;
    --dkms-conf) dkms_conf=${2:?--dkms-conf needs a path}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

repo_root=$(git rev-parse --show-toplevel) || { echo "not inside a git repo" >&2; exit 2; }
BASE="$repo_root/sources/radeon-unified-0.3-source.tar.xz"
[ -n "$dkms_conf" ] ||
  dkms_conf="$repo_root/migration/input/legacy-dkms-patch-order.conf"
[ -f "$BASE" ] || { echo "missing base tarball: $BASE" >&2; exit 2; }
[ -f "$dkms_conf" ] || { echo "missing dkms.conf: $dkms_conf" >&2; exit 2; }

if [ -n "$out_dir" ]; then
  # A residual file under --out would enter the manifest and be attributed to
  # the legacy payload, so the destination starts empty or the run stops.
  if [ -e "$out_dir" ] && [ -n "$(ls -A "$out_dir" 2>/dev/null)" ]; then
    echo "destination is not empty: $out_dir" >&2
    exit 2
  fi
  mkdir -p "$out_dir"
  WORK=$(CDPATH= cd -- "$out_dir" && pwd)
else
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT INT TERM
fi

mkdir -p "$WORK/radeon"
tar -xJf "$BASE" -C "$WORK/radeon"

# Anchored so a commented-out entry stays unparsed, matching the apply gate and
# matching what DKMS itself replays.
grep -oE '^[[:space:]]*PATCH\[[0-9]+\]="[^"]+"' "$dkms_conf" \
  | sed -E 's/.*="([^"]+)"/\1/' > "$WORK/order.txt"

n=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  [ -f "$repo_root/patches/rs480/$p" ] || { echo "PATCH MISSING: $p" >&2; exit 2; }
  if ! ( cd "$WORK" && patch -p1 -s < "$repo_root/patches/rs480/$p" ); then
    echo "PATCH REJECT: $p" >&2; exit 3
  fi
  n=$((n + 1))
done < "$WORK/order.txt"
[ "$n" -gt 0 ] || { echo "no PATCH[] entries parsed from dkms.conf" >&2; exit 2; }
echo "legacy tree materialized: $n patches applied" >&2

# Patch backups are construction artifacts rather than source, so they stay out
# of the manifest and out of any tree a source repository would carry.
find "$WORK/radeon" -name '*.orig' -o -name '*.rej' | while IFS= read -r f; do
  echo "construction artifact present: ${f#"$WORK/"}" >&2
done

if [ -n "$manifest" ]; then
  sh "$repo_root/scripts/emit_source_tree_manifest.sh" --tree "$WORK/radeon" \
    --out "$manifest"
else
  sh "$repo_root/scripts/emit_source_tree_manifest.sh" --tree "$WORK/radeon"
fi

[ -n "$out_dir" ] && echo "tree: $WORK/radeon" >&2
exit 0
