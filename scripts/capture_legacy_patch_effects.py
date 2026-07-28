#!/usr/bin/env python3
"""Capture the per-patch effects of the radeon DKMS series.

The series in dkms.conf PATCH[] order is the unit of review: each patch lands
on the tree the preceding patches produced, so its effect is the difference it
makes at its own position, not against the base. This walks the series in that
order, applies each patch with zero fuzz, and records what each one touches:
files, hunks, line counts, new top-level symbols, module parameters, and
debugfs nodes. The output is one row per patch in a fixed schema, so a series
edit shows up as a row-level difference rather than a prose disagreement.

Zero fuzz is load-bearing: DKMS applies with default fuzz, so a hunk that
drifts can still land at an offset with mutated context. A capture that
tolerated fuzz would record the effect of a placement the review never saw.
A patch whose context does not match exactly is therefore a finding, and
the capture fails on it. Two exact-context engines run in sequence and
either acceptance passes the patch: git apply first, then GNU patch at
--fuzz=0. Each has a false-reject class the other lacks, measured on this
series: GNU patch 2.8 rejects some byte-identical fully-contexted hunks
that git apply and patch 2.7.6 accept, and git apply rejects hunks that
carry no context lines. A patch both engines reject has drifted context,
which default-fuzz DKMS application would silently relocate.

Exit: 0 effects captured, 1 calibration failure or a context mismatch,
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

SCHEMA = "gororoba-legacy-patch-effects-v1"
COLUMNS = [
    "order",
    "patch",
    "patch_sha256",
    "files_touched",
    "hunks",
    "lines_added",
    "lines_removed",
    "new_symbols",
    "module_params",
    "debugfs_nodes",
]

# Top-level C definition introduced by an added line: a name at column zero
# followed by a declarator opener. The same shape the base-delta map uses to
# label atoms, so the two captures name symbols the same way.
TOP_LEVEL = re.compile(
    r"^\+(?:[A-Za-z_][\w \t*]*?)\b(?P<name>[A-Za-z_]\w*)\s*(?:\(|\[|=|\{)"
)
MODULE_PARAM = re.compile(r"^\+module_param_named\((?P<name>\w+)")
DEBUGFS_NODE = re.compile(r'^\+.*debugfs_create_file\("(?P<name>[^"]+)"')
HUNK = re.compile(r"^@@ ")
FILE_HEADER = re.compile(r"^\+\+\+ b/(?P<path>\S+)")


def parse_series(dkms_conf: Path) -> list[str]:
    """Read PATCH[] entries in index order, the order DKMS applies them."""
    entries: dict[int, str] = {}
    pat = re.compile(r'^PATCH\[(\d+)\]="([^"]+)"')
    for ln in dkms_conf.read_text(encoding="utf-8").splitlines():
        if m := pat.match(ln):
            entries[int(m.group(1))] = m.group(2)
    return [entries[i] for i in sorted(entries)]


def patch_effects(text: str) -> dict[str, object]:
    files: list[str] = []
    hunks = added = removed = 0
    symbols: list[str] = []
    params: list[str] = []
    nodes: list[str] = []
    for ln in text.splitlines():
        if m := FILE_HEADER.match(ln):
            files.append(m.group("path"))
        elif HUNK.match(ln):
            hunks += 1
        elif ln.startswith("+") and not ln.startswith("+++"):
            added += 1
            if m := MODULE_PARAM.match(ln):
                params.append(m.group("name"))
            elif m := DEBUGFS_NODE.match(ln):
                nodes.append(m.group("name"))
            elif ln[1:2] not in " \t#/}" and (m := TOP_LEVEL.match(ln)):
                symbols.append(m.group("name"))
        elif ln.startswith("-") and not ln.startswith("---"):
            removed += 1
    return {
        "files": files, "hunks": hunks, "added": added, "removed": removed,
        "symbols": symbols, "params": params, "nodes": nodes,
    }


def capture(tree: Path, patches_dir: Path, series: list[str], out) -> int:
    """Apply the series in order into a working copy and emit one row each."""
    out.write(f"# effects-schema: {SCHEMA}\n")
    out.write("\t".join(COLUMNS) + "\n")
    with tempfile.TemporaryDirectory() as td:
        work = Path(td) / "work"
        shutil.copytree(tree, work / "radeon")
        for n, name in enumerate(series):
            pfile = patches_dir / name
            if not pfile.is_file():
                print(f"PATCH MISSING: {pfile}", file=sys.stderr)
                return 2
            text = pfile.read_text(encoding="utf-8", errors="surrogateescape")
            raw = text.encode("utf-8", "surrogateescape")
            r = subprocess.run(
                ["git", "apply", "-p1", "--unsafe-paths", "--directory", str(work)],
                input=raw, capture_output=True,
            )
            if r.returncode != 0:
                r = subprocess.run(
                    ["patch", "-p1", "--fuzz=0", "--no-backup-if-mismatch", "-s"],
                    cwd=work, input=raw, capture_output=True,
                )
            if r.returncode != 0:
                print(f"PATCH CONTEXT DOES NOT MATCH EXACTLY: {name}",
                      file=sys.stderr)
                sys.stderr.buffer.write(r.stderr)
                return 1
            e = patch_effects(text)
            out.write("\t".join([
                str(n), name,
                hashlib.sha256(pfile.read_bytes()).hexdigest(),
                ",".join(e["files"]), str(e["hunks"]),
                str(e["added"]), str(e["removed"]),
                ",".join(dict.fromkeys(e["symbols"])) or "none",
                ",".join(dict.fromkeys(e["params"])) or "none",
                ",".join(dict.fromkeys(e["nodes"])) or "none",
            ]) + "\n")
    return 0


def self_test() -> int:
    fails = 0

    def check(label: str, ok: bool) -> None:
        nonlocal fails
        print(f"  ok: {label}" if ok else f"  CALIBRATION FAIL: {label}")
        fails += 0 if ok else 1

    print("legacy-patch-effects calibration:")
    good = (
        "--- a/radeon/rs400.c\n+++ b/radeon/rs400.c\n@@ -1,3 +1,8 @@\n"
        " int keep;\n+static int rs480_probe_count;\n"
        "+module_param_named(rs480_probe, rs480_probe_count, int, 0444);\n"
        '+\tdebugfs_create_file("rs480_probe", 0444, root, rdev, &fops);\n'
        "+int rs480_read_probe(void)\n+{\n-int drop;\n int tail;\n"
    )
    e = patch_effects(good)
    check("file header parsed", e["files"] == ["radeon/rs400.c"])
    check("hunk counted", e["hunks"] == 1)
    check("added and removed counted", (e["added"], e["removed"]) == (5, 1))
    check("new symbol found", "rs480_read_probe" in e["symbols"])
    check("module parameter found", e["params"] == ["rs480_probe"])
    check("debugfs node found", e["nodes"] == ["rs480_probe"])

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
        # Context that only lands with fuzz: the capture refuses it.
        (pd / "0002-fuzz.patch").write_text(
            "--- a/radeon/rs400.c\n+++ b/radeon/rs400.c\n"
            "@@ -1,3 +1,4 @@\n int wrong_context;\n int keep;\n"
            "+int fuzzy;\n int tail;\n"
        )
        import io
        buf = io.StringIO()
        check("clean series captures",
              capture(tree, pd, ["0001-add.patch"], buf) == 0)
        rows = [ln for ln in buf.getvalue().splitlines()
                if ln and not ln.startswith("#") and not ln.startswith("order")]
        check("one row per patch", len(rows) == 1)
        check("row carries the schema arity",
              all(len(r.split("\t")) == len(COLUMNS) for r in rows))
        buf2 = io.StringIO()
        check("drifted-context patch refused",
              capture(tree, pd, ["0001-add.patch", "0002-fuzz.patch"], buf2) == 1)
        buf3 = io.StringIO()
        check("missing patch refused",
              capture(tree, pd, ["0009-absent.patch"], buf3) == 2)

    if fails:
        print(f"legacy-patch-effects calibration: FAIL ({fails})")
        return 1
    print("legacy-patch-effects calibration: 6 parser facts, 5 capture verdicts")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", type=Path, help="the radeon source tree the series applies to")
    ap.add_argument("--dkms-conf", type=Path)
    ap.add_argument("--patches-dir", type=Path)
    ap.add_argument("--out", type=Path)
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
    series = parse_series(args.dkms_conf)
    if not series:
        print(f"{args.dkms_conf} carries no PATCH[] entries", file=sys.stderr)
        return 2
    if args.out:
        with args.out.open("w") as fh:
            rc = capture(args.tree, args.patches_dir, series, fh)
        if rc == 0:
            print(f"captured {len(series)} patches into {args.out}")
        return rc
    return capture(args.tree, args.patches_dir, series, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
