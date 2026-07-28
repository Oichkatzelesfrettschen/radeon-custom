#!/usr/bin/env python3
"""Decompose the upstream-to-base delta into hunks, and check a map covers it.

The base-delta map assigns each hunk between pristine upstream and the
normalized 212-file base to one origin class. Two of its requirements are
closure properties rather than judgments: every changed line belongs to exactly
one row, and the union of the mapped hunks reconstructs the base from upstream.
Both are mechanical, so they run as a check rather than as a review.

Running this before any classification is the point. Against an empty map it
reports every hunk unassigned, and each classification pass moves that count
toward zero. Classifying first and discovering afterward that the union does
not reconstruct means redoing the classification.

A hunk's identity is the SHA-256 of its path followed by its diff body with the
@@ header removed. Line numbers shift as neighboring hunks apply, so a hash
over them would change for reasons unrelated to content, and a map row keyed on
that could not survive a rebase of the oracle.

Exit: 0 the map closes over the delta, 1 the map does not close, 2 missing
inputs.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

CONTEXT = 3
COLUMNS = [
    "file",
    "symbol_or_range",
    "normalized_diff_sha256",
    "delta_class",
    "upstream_origin_commit",
    "legacy_origin",
    "execution_scope",
    "evidence_scope",
    "future_source_commit",
    "notes",
]
CLASSES = {
    "upstream backport",
    "kernel-version compatibility adaptation",
    "RS48X mechanism",
    "Palm/Wrestler mechanism",
    "reconstructed generator input",
}


@dataclass(frozen=True)
class Hunk:
    path: str
    index: int
    header: str
    body: tuple[str, ...]

    @property
    def digest(self) -> str:
        text = self.path + "\n" + "".join(self.body)
        return hashlib.sha256(text.encode()).hexdigest()

    @property
    def changed_lines(self) -> int:
        return sum(1 for ln in self.body if ln[:1] in "+-")

    @property
    def label(self) -> str:
        return f"{self.path}#{self.index}"


def read_lines(path: Path) -> list[str]:
    return path.read_bytes().decode("utf-8", "surrogateescape").splitlines(keepends=True)


def decompose(upstream: Path, base: Path) -> list[Hunk]:
    """Split the upstream-to-base delta into per-file unified hunks.

    Paths present on one side alone are a file-set difference rather than a
    hunk, and the base oracle already asserts the file set, so this walks the
    intersection.
    """
    up = {p.relative_to(upstream).as_posix() for p in upstream.rglob("*") if p.is_file()}
    bs = {p.relative_to(base).as_posix() for p in base.rglob("*") if p.is_file()}
    hunks: list[Hunk] = []
    for rel in sorted(up & bs, key=lambda s: s.encode()):
        a, b = upstream / rel, base / rel
        if a.read_bytes() == b.read_bytes():
            continue
        diff = list(difflib.unified_diff(read_lines(a), read_lines(b), n=CONTEXT))
        current: list[str] = []
        header = ""
        index = 0
        for line in diff[2:]:
            if line.startswith("@@"):
                if current:
                    index += 1
                    hunks.append(Hunk(rel, index, header, tuple(current)))
                header, current = line.rstrip("\n"), []
            else:
                current.append(line)
        if current:
            index += 1
            hunks.append(Hunk(rel, index, header, tuple(current)))
    return hunks


def read_map(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    rows = []
    header: list[str] | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if header is None:
            header = fields
            if header != COLUMNS:
                raise ValueError(f"{path} header is {header}, and the schema is {COLUMNS}")
            continue
        rows.append(dict(zip(header, fields, strict=False)))
    return rows


def reconstruct(upstream: Path, hunks: list[Hunk], mapped: set[str], work: Path) -> Path:
    """Apply the mapped hunks to a copy of upstream.

    The reconstruction proves the map's rows account for the delta rather than
    merely naming hashes that exist. A row set that hashes correctly and still
    fails to reconstruct means a hunk is named twice and another is missing.
    """
    tree = work / "reconstructed"
    subprocess.run(["cp", "-a", str(upstream), str(tree)], check=True)
    by_path: dict[str, list[Hunk]] = {}
    for h in hunks:
        if h.digest in mapped:
            by_path.setdefault(h.path, []).append(h)
    for rel, group in by_path.items():
        patch = work / "hunks.patch"
        with patch.open("w", encoding="utf-8") as fh:
            fh.write(f"--- a/{rel}\n+++ b/{rel}\n")
            for h in sorted(group, key=lambda x: x.index):
                fh.write(h.header + "\n")
                fh.writelines(h.body)
        subprocess.run(
            ["patch", "-p1", "-s", "-i", str(patch)],
            cwd=tree, check=True, capture_output=True,
        )
    return tree


def self_test() -> int:
    """Calibrate against a map that closes and every way one fails to."""
    failures = 0

    def check(label: str, ok: bool) -> None:
        nonlocal failures
        if ok:
            print(f"  ok: {label}")
        else:
            print(f"  CALIBRATION FAIL: {label}")
            failures += 1

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        up, bs = root / "up", root / "base"
        for d in (up, bs):
            d.mkdir()
        body = "".join(f"line {i}\n" for i in range(1, 41))
        (up / "a.c").write_text(body, encoding="utf-8")
        (bs / "a.c").write_text(
            body.replace("line 5\n", "line 5\nadded near the top\n")
                .replace("line 35\n", "changed near the bottom\n"),
            encoding="utf-8")
        (up / "b.c").write_text("static int x;\n", encoding="utf-8")
        (bs / "b.c").write_text("static int x;\n", encoding="utf-8")

        hunks = decompose(up, bs)
        check("distinct edits decompose to separate hunks", len(hunks) == 2)
        check("an identical file contributes no hunk",
              all(h.path == "a.c" for h in hunks))

        def run(rows: list[list[str]]) -> int:
            m = root / "map.tsv"
            with m.open("w", encoding="utf-8") as fh:
                fh.write("\t".join(COLUMNS) + "\n")
                for r in rows:
                    fh.write("\t".join(r) + "\n")
            return main_with(up, bs, m, None)

        def row(h: Hunk, cls: str = "RS48X mechanism") -> list[str]:
            return [h.path, h.header, h.digest, cls, "", "", "", "", "", ""]

        complete = [row(h) for h in hunks]
        check("a complete map closes", run(complete) == 0)
        check("an empty map fails", run([]) == 1)
        check("a partial map fails", run(complete[:1]) == 1)
        check("a duplicated hunk fails", run(complete + [row(hunks[0])]) == 1)

        bogus = row(hunks[0])
        bogus[2] = "0" * 64
        check("a hunk absent from the delta fails", run(complete + [bogus]) == 1)

        check("a class outside the declared set fails",
              run([row(hunks[0]), row(hunks[1], "misc")]) == 1)

    if failures:
        print(f"base-delta closure calibration: FAIL ({failures})")
        return 1
    print("base-delta closure calibration: 2 decomposition properties, "
          "1 closing map, 5 failure classes")
    return 0


def main_with(upstream: Path, base: Path, map_path: Path, manifest: Path | None) -> int:
    """The check itself, so the calibration drives the same code path CI does."""
    hunks = decompose(upstream, base)
    total_lines = sum(h.changed_lines for h in hunks)
    print(f"delta: {len(hunks)} hunks across "
          f"{len({h.path for h in hunks})} files, {total_lines} changed lines")

    rows = read_map(map_path)
    expected = {h.digest: h for h in hunks}
    seen: dict[str, int] = {}
    for r in rows:
        seen[r["normalized_diff_sha256"]] = seen.get(r["normalized_diff_sha256"], 0) + 1

    failures = 0
    unassigned = [h for d, h in expected.items() if d not in seen]
    if unassigned:
        lines = sum(h.changed_lines for h in unassigned)
        print(f"unassigned: {len(unassigned)} hunks, {lines} changed lines")
        for h in unassigned[:20]:
            print(f"  {h.label}  {h.changed_lines} lines  {h.header}")
        if len(unassigned) > 20:
            print(f"  ... {len(unassigned) - 20} more")
        failures += 1

    unknown = sorted(d for d in seen if d not in expected)
    for d in unknown:
        print(f"row names a hunk absent from the delta: {d}")
    failures += bool(unknown)

    duplicated = sorted(d for d, n in seen.items() if n > 1)
    for d in duplicated:
        print(f"hunk assigned to {seen[d]} rows: {expected[d].label if d in expected else d}")
    failures += bool(duplicated)

    for r in rows:
        cls = r.get("delta_class", "")
        if cls not in CLASSES:
            print(f"row {r.get('file')} carries class {cls!r}, outside the four origin "
                  f"classes and the reconstructed-input class")
            failures += 1
            break

    if failures:
        print("base-delta map does not close over the delta")
        return 1

    with tempfile.TemporaryDirectory() as td:
        tree = reconstruct(upstream, hunks, set(seen), Path(td))
        if manifest:
            emitter = Path(__file__).parent / "emit_source_tree_manifest.sh"
            got = subprocess.run(
                ["sh", str(emitter), "--tree", str(tree)],
                check=True, capture_output=True, text=True,
            ).stdout
            want = manifest.read_text(encoding="utf-8")
            got_rows = [ln for ln in got.splitlines() if not ln.startswith("#")]
            want_rows = [ln for ln in want.splitlines() if not ln.startswith("#")]
            # The reconstruction starts from upstream, which carries .gitignore;
            # the base oracle excludes it as repository metadata.
            got_rows = [ln for ln in got_rows if not ln.startswith(".gitignore\t")]
            if got_rows != want_rows:
                only_got = set(got_rows) - set(want_rows)
                only_want = set(want_rows) - set(got_rows)
                for ln in sorted(only_want)[:10]:
                    print(f"reconstruction lacks: {ln.split(chr(9))[0]}")
                for ln in sorted(only_got)[:10]:
                    print(f"reconstruction differs: {ln.split(chr(9))[0]}")
                print("the mapped hunk union does not reconstruct the base")
                return 1
            print(f"reconstruction equals the base oracle: {len(want_rows) - 1} entries")

    print(f"base-delta map closes: {len(rows)} rows, {total_lines} changed lines assigned")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--upstream", type=Path)
    ap.add_argument("--base", type=Path)
    ap.add_argument("--map", type=Path)
    ap.add_argument("--manifest", type=Path,
                    help="base manifest the reconstruction must equal")
    ap.add_argument("--emit-skeleton", type=Path,
                    help="write one unclassified row per hunk here and exit")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not (args.upstream and args.base):
        ap.error("give --upstream and --base, or --self-test")
    for d in (args.upstream, args.base):
        if not d.is_dir():
            print(f"not a directory: {d}", file=sys.stderr)
            return 2

    if args.emit_skeleton:
        hunks = decompose(args.upstream, args.base)
        with args.emit_skeleton.open("w", encoding="utf-8") as fh:
            fh.write("\t".join(COLUMNS) + "\n")
            for h in hunks:
                fh.write("\t".join([
                    h.path, h.header, h.digest, "", "", "", "", "", "", "",
                ]) + "\n")
        print(f"skeleton: {args.emit_skeleton} ({len(hunks)} rows)")
        return 0

    if not args.map:
        ap.error("give --map, or --emit-skeleton")
    return main_with(args.upstream, args.base, args.map, args.manifest)


if __name__ == "__main__":
    sys.exit(main())
