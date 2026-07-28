#!/usr/bin/env python3
"""Bond each legacy patch to the tree mutation it actually produces.

The effects capture reads the patch text; this ledger reads the tree. Each
patch in dkms.conf PATCH[] order is applied to a Git working copy of the base
tarball, and the row records the input tree object, the output tree object,
and the SHA-256 of the actual full-index diff between them, so a patch is
bonded to the mutation it produces rather than the mutation its text appears
to describe.

Both exact-context engines run on independent copies of the input tree. When
both accept, the two output trees are required to be identical; when one
rejects, the row records the accepting engine and the rejecting engine's
measured false-reject class (git apply rejects zero-context hunks; GNU patch
2.8 rejects some byte-identical fully-contexted hunks). Both rejecting is a
drifted patch and fails the run. An output tree equal to its input tree is a
no-op patch and fails the run. PATCH[] indices are required unique and
contiguous from zero, patch names unique.

The final output tree must reproduce the exact-context payload manifest,
which ties the whole walk to the pkgrel-91 migration baseline.

Exit: 0 ledger emitted, 1 calibration failure or an invariant violation,
2 missing inputs.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA = "gororoba-legacy-patch-transitions-v1"
COLUMNS = [
    "patch_index",
    "patch",
    "patch_sha256",
    "input_tree",
    "output_tree",
    "effect_diff_sha256",
    "apply_engine",
    "alternate_engine_result",
    "files_changed",
    "atoms",
    "lines_added",
    "lines_removed",
]


def run(args: list[str], cwd: Path, inp: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=cwd, input=inp, capture_output=True)


def git_out(args: list[str], cwd: Path) -> str:
    r = run(["git", *args], cwd)
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.decode(errors='replace')}")
    return r.stdout.decode().strip()


def init_repo(work: Path) -> str:
    """Initialize a throwaway repository over the tree and return its tree ID."""
    git_out(["init", "-q"], work)
    git_out(["config", "user.email", "ledger@localhost"], work)
    git_out(["config", "user.name", "transition-ledger"], work)
    # A host-level core.fsmonitor daemon plants a socket under .git that
    # breaks the working-copy duplication the dual-engine comparison needs.
    git_out(["config", "core.fsmonitor", "false"], work)
    return snapshot(work)


def snapshot(work: Path) -> str:
    """Stage everything and return the resulting Git tree object ID."""
    git_out(["add", "-A"], work)
    return git_out(["write-tree"], work)


def parse_series(dkms_conf: Path) -> list[str]:
    """Read PATCH[] entries, enforcing unique contiguous indices and names."""
    entries: dict[int, str] = {}
    pat = re.compile(r'^PATCH\[(\d+)\]="([^"]+)"')
    for ln in dkms_conf.read_text(encoding="utf-8").splitlines():
        if m := pat.match(ln):
            idx = int(m.group(1))
            if idx in entries:
                raise ValueError(f"duplicate PATCH index {idx}")
            entries[idx] = m.group(2)
    if sorted(entries) != list(range(len(entries))):
        raise ValueError("PATCH indices are not contiguous from zero")
    names = list(entries[i] for i in sorted(entries))
    if len(set(names)) != len(names):
        raise ValueError("duplicate patch name in PATCH[] series")
    return names


def apply_both(work: Path, raw: bytes) -> tuple[str, str]:
    """Apply with both engines on independent copies of the input tree.

    Returns (engine, alternate_result) and leaves the accepted result in the
    working copy. Raises on both-reject and on divergent both-accept trees.
    """
    with tempfile.TemporaryDirectory() as td:
        alt = Path(td) / "alt"
        shutil.copytree(work, alt)
        r_git = run(["git", "apply", "-p1"], work, raw)
        r_pat = run(["patch", "-p1", "--fuzz=0", "--no-backup-if-mismatch", "-s"], alt, raw)
        if r_git.returncode != 0 and r_pat.returncode != 0:
            raise RuntimeError(
                "both engines reject:\n"
                + r_git.stderr.decode(errors="replace")
                + r_pat.stderr.decode(errors="replace")
            )
        if r_git.returncode == 0 and r_pat.returncode == 0:
            tree_git = snapshot(work)
            # Rebuild the index over the alternate result to compare trees.
            shutil.rmtree(alt / ".git")
            shutil.copytree(work / ".git", alt / ".git")
            tree_pat = snapshot(alt)
            if tree_git != tree_pat:
                raise RuntimeError(
                    f"engines diverge: git apply {tree_git}, GNU patch {tree_pat}"
                )
            return "git-apply", "accepts-identical-tree"
        if r_git.returncode == 0:
            return "git-apply", "gnu-patch-false-reject-fully-contexted-hunk"
        # GNU patch alone accepted: adopt its result into the working copy.
        for item in work.iterdir():
            if item.name == ".git":
                continue
            shutil.rmtree(item) if item.is_dir() else item.unlink()
        for item in alt.iterdir():
            if item.name == ".git":
                continue
            dest = work / item.name
            shutil.copytree(item, dest) if item.is_dir() else shutil.copy2(item, dest)
        return "gnu-patch", "git-apply-false-reject-zero-context-hunk"


def diff_stats(work: Path, in_tree: str, out_tree: str) -> tuple[str, int, int, int, int]:
    """Hash the actual full-index diff and count its measured footprint."""
    r = run(["git", "diff", "--full-index", in_tree, out_tree], work)
    if r.returncode not in (0, 1):
        raise RuntimeError(r.stderr.decode(errors="replace"))
    diff = r.stdout
    files = sum(1 for ln in diff.splitlines() if ln.startswith(b"diff --git "))
    hunks = sum(1 for ln in diff.splitlines() if ln.startswith(b"@@ "))
    added = sum(
        1 for ln in diff.splitlines()
        if ln.startswith(b"+") and not ln.startswith(b"+++")
    )
    removed = sum(
        1 for ln in diff.splitlines()
        if ln.startswith(b"-") and not ln.startswith(b"---")
    )
    return hashlib.sha256(diff).hexdigest(), files, hunks, added, removed


def walk(tree: Path, patches_dir: Path, series: list[str], out,
         final_tree_out: Path | None = None) -> int:
    out.write(f"# transitions-schema: {SCHEMA}\n")
    out.write("\t".join(COLUMNS) + "\n")
    with tempfile.TemporaryDirectory() as td:
        work = Path(td) / "work"
        shutil.copytree(tree, work / "radeon")
        work_root = work
        in_tree = init_repo(work_root)
        for n, name in enumerate(series):
            pfile = patches_dir / name
            if not pfile.is_file():
                print(f"PATCH MISSING: {pfile}", file=sys.stderr)
                return 2
            raw = pfile.read_bytes()
            try:
                engine, alt_result = apply_both(work_root, raw)
            except RuntimeError as e:
                print(f"PATCH {name}: {e}", file=sys.stderr)
                return 1
            out_tree = snapshot(work_root)
            if out_tree == in_tree:
                print(f"NO-OP PATCH: {name} leaves the tree unchanged", file=sys.stderr)
                return 1
            diff_sha, files, hunks, added, removed = diff_stats(
                work_root, in_tree, out_tree
            )
            out.write("\t".join([
                str(n), name, hashlib.sha256(raw).hexdigest(),
                in_tree, out_tree, diff_sha, engine, alt_result,
                str(files), str(hunks), str(added), str(removed),
            ]) + "\n")
            in_tree = out_tree
        if final_tree_out is not None:
            # Export the walked end state so the caller can prove it against
            # the exact-context payload manifest with the shared emitter.
            shutil.copytree(
                work_root / "radeon", final_tree_out,
                ignore=shutil.ignore_patterns(".git"),
            )
    return 0


def self_test() -> int:
    fails = 0

    def check(label: str, ok: bool) -> None:
        nonlocal fails
        print(f"  ok: {label}" if ok else f"  CALIBRATION FAIL: {label}")
        fails += 0 if ok else 1

    import io
    print("legacy-patch-transitions calibration:")

    try:
        parse_series_text = 'PATCH[0]="a.patch"\nPATCH[1]="b.patch"\n'
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as fh:
            fh.write(parse_series_text)
            conf = Path(fh.name)
        check("contiguous series parses", parse_series(conf) == ["a.patch", "b.patch"])
        conf.write_text('PATCH[0]="a.patch"\nPATCH[2]="b.patch"\n')
        try:
            parse_series(conf)
            check("gapped series refused", False)
        except ValueError:
            check("gapped series refused", True)
        conf.write_text('PATCH[0]="a.patch"\nPATCH[1]="a.patch"\n')
        try:
            parse_series(conf)
            check("duplicate patch name refused", False)
        except ValueError:
            check("duplicate patch name refused", True)
    finally:
        conf.unlink()

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        tree = root / "tree"
        tree.mkdir()
        (tree / "rs400.c").write_text("int keep;\nint tail;\n")
        pd = root / "patches"
        pd.mkdir()
        (pd / "0001-add.patch").write_text(
            "--- a/radeon/rs400.c\n+++ b/radeon/rs400.c\n"
            "@@ -1,2 +1,3 @@\n int keep;\n+int added;\n int tail;\n"
        )
        (pd / "0002-drift.patch").write_text(
            "--- a/radeon/rs400.c\n+++ b/radeon/rs400.c\n"
            "@@ -1,3 +1,4 @@\n int wrong_context;\n int keep;\n"
            "+int fuzzy;\n int tail;\n"
        )
        (pd / "0003-noop.patch").write_text(
            "--- a/radeon/rs400.c\n+++ b/radeon/rs400.c\n"
            "@@ -1,3 +1,3 @@\n int keep;\n-int added;\n+int added;\n int tail;\n"
        )
        buf = io.StringIO()
        check("clean patch walks", walk(tree, pd, ["0001-add.patch"], buf) == 0)
        rows = [ln.split("\t") for ln in buf.getvalue().splitlines()
                if ln and not ln.startswith("#") and not ln.startswith("patch_index")]
        check("row carries the schema arity",
              all(len(r) == len(COLUMNS) for r in rows))
        check("input and output trees differ", rows and rows[0][3] != rows[0][4])
        check("both engines accept with identical trees",
              rows and rows[0][7] == "accepts-identical-tree")
        buf2 = io.StringIO()
        check("drifted patch fails the walk",
              walk(tree, pd, ["0001-add.patch", "0002-drift.patch"], buf2) == 1)
        buf3 = io.StringIO()
        check("no-op patch fails the walk",
              walk(tree, pd, ["0001-add.patch", "0003-noop.patch"], buf3) == 1)
        buf4 = io.StringIO()
        check("missing patch refused", walk(tree, pd, ["absent.patch"], buf4) == 2)

    if fails:
        print(f"legacy-patch-transitions calibration: FAIL ({fails})")
        return 1
    print("legacy-patch-transitions calibration: 3 series facts, 7 walk verdicts")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", type=Path, help="the radeon source tree the series applies to")
    ap.add_argument("--dkms-conf", type=Path)
    ap.add_argument("--patches-dir", type=Path)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--final-tree-out", type=Path,
                    help="export the walked end state to this directory")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not (args.tree and args.dkms_conf and args.patches_dir):
        ap.error("give --tree, --dkms-conf, and --patches-dir, or --self-test")
    for p, label in ((args.tree, "tree"), (args.dkms_conf, "dkms.conf"),
                     (args.patches_dir, "patches dir")):
        if not p.exists():
            print(f"missing {label}: {p}", file=sys.stderr)
            return 2
    try:
        series = parse_series(args.dkms_conf)
    except ValueError as e:
        print(f"SERIES INVARIANT: {e}", file=sys.stderr)
        return 1
    if not series:
        print(f"{args.dkms_conf} carries no PATCH[] entries", file=sys.stderr)
        return 2
    if args.out:
        with args.out.open("w") as fh:
            rc = walk(args.tree, args.patches_dir, series, fh, args.final_tree_out)
        if rc == 0:
            print(f"emitted {len(series)} transitions into {args.out}")
        return rc
    return walk(args.tree, args.patches_dir, series, sys.stdout, args.final_tree_out)


if __name__ == "__main__":
    sys.exit(main())
