#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Decompose the upstream-to-base delta into atoms, and check a map covers it.

The base-delta map assigns each changed region between pristine upstream and
the normalized 212-entry base to an origin, a mechanism lane, and a
materialization kind. Two of its requirements are closure properties rather
than judgments: every changed line belongs to exactly one row, and the union of
the mapped regions reconstructs the base from upstream. Both are mechanical, so
they run as a check.

Running this before classification is the point. Against an empty map it
reports every atom unassigned, and each classification pass moves that count
toward zero. Classifying first and then finding the union does not reconstruct
means redoing the classification.

Atoms, not unified-diff hunks. Unified-diff grouping is a presentation rule:
with three context lines two edits within six lines of each other merge into
one hunk even when their provenance differs. The classification unit is the
non-equal SequenceMatcher opcode, which is a contiguous changed region bounded
by unchanged lines on both sides, so a row never spans an unchanged line it
does not own. The changed-line total is invariant under the regrouping: 35
presentation hunks and 48 atoms both carry 346 changed lines.

Three orthogonal axes. origin_kind records where the change came from,
mechanism_lane records what hardware or kernel concern it serves, and
materialization_kind records how the evidence entered the oracle. Collapsing
them loses a real distinction: reg_srcs/evergreen carries the SMX_DC_CTL0
command-stream permission, which is Palm/Wrestler mechanism, and it was
reconstructed from the shipped generated bitmap rather than observed in the
payload. One class set would force a choice between those two true facts.

The map binds to two frozen oracles. Its header names the upstream subtree
object and the base manifest digest, and hunk_id hashes both into every row, so
a changed oracle invalidates the classification rather than silently preserving
it because a familiar-looking body remains nearby.

Reconstruction applies the mapped opcodes directly rather than invoking patch,
so application is exact by construction with no fuzz policy to inherit.

Exit: 0 the map closes over the delta, 1 the map does not close, 2 missing
inputs or a malformed schema.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

MAP_SCHEMA = "gororoba-base-delta-map-v1"
MANIFEST_SCHEMA = "gororoba-source-tree-v1"
DIFF_ENGINE = "python-difflib"
DIFF_CONTEXT = 3

COLUMNS = [
    "file",
    "symbol_or_range",
    "hunk_id",
    "parent_hunk",
    "normalized_diff_sha256",
    "origin_kind",
    "mechanism_lane",
    "materialization_kind",
    "upstream_origin_commit",
    "legacy_origin",
    "execution_scope",
    "evidence_scope",
    "future_source_commit",
    "notes",
]

ORIGIN_KINDS = {
    "exact-upstream-backport",
    "upstream-derived-adaptation",
    "project-local",
    "reconstructed-input",
}
MECHANISM_LANES = {
    "shared-radeon",
    "kernel-version-compatibility",
    "RS48X",
    "Palm/Wrestler",
    "register-policy",
}
MATERIALIZATION_KINDS = {
    "observed-in-legacy-base",
    "inferred-from-generated-output",
}

# A full upstream commit, so an abbreviated hash cannot stand in for one.
SHA40 = re.compile(r"^[0-9a-f]{40}$")

# Top-level C definition: a symbol starting at column zero. The atom's own
# added lines answer first, and the upstream context above it answers when the
# atom adds nothing that defines a symbol.
TOP_LEVEL = re.compile(
    r"^(?:[A-Za-z_][\w \t*]*?)\b(?P<name>[A-Za-z_]\w*)\s*(?:\(|\[|=|;|\{)"
)


class SchemaError(Exception):
    """The map or a manifest declares no schema, or declares a foreign one."""


@dataclass(frozen=True)
class Atom:
    path: str
    index: int
    i1: int
    i2: int
    old: tuple[str, ...]
    new: tuple[str, ...]
    symbol: str
    parent: str

    @property
    def content_digest(self) -> str:
        text = self.path + "\n" + "".join(self.old) + "\0" + "".join(self.new)
        return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()

    def hunk_id(self, upstream_tree: str, base_digest: str) -> str:
        """Bind the row to the exact comparison it was classified against."""
        material = "\0".join([
            upstream_tree, base_digest, self.path,
            f"{self.i1},{self.i2}", str(len(self.new)),
            "".join(self.old), "".join(self.new),
        ])
        return hashlib.sha256(material.encode("utf-8", "surrogateescape")).hexdigest()[:16]

    @property
    def changed_lines(self) -> int:
        return len(self.old) + len(self.new)

    @property
    def label(self) -> str:
        return f"{self.path}:{self.index}@{self.i1 + 1}"


def read_lines(path: Path) -> list[str]:
    return path.read_bytes().decode("utf-8", "surrogateescape").splitlines(keepends=True)


def resolve_symbol(added: tuple[str, ...], context: list[str], i1: int) -> str:
    """Name the top-level definition the atom touches.

    An atom that introduces definitions names them; otherwise the nearest
    top-level definition above the region names it. The value is a reviewer
    label, and closure never depends on it.
    """
    defined = []
    for line in added:
        if line[:1] not in " \t\n#/" and (m := TOP_LEVEL.match(line)):
            defined.append(m.group("name"))
    if defined:
        head = defined[0] if len(defined) == 1 else f"{defined[0]}..{defined[-1]}"
        return f"defines {head}"
    for j in range(min(i1, len(context)) - 1, -1, -1):
        line = context[j]
        if line[:1] not in " \t\n#/}" and (m := TOP_LEVEL.match(line)):
            return m.group("name")
    return "file scope"


def decompose(upstream: Path, base: Path) -> list[Atom]:
    """Split the delta into contiguous changed regions.

    Paths present on one side alone are a file-set difference rather than a
    changed region, and the base oracle already asserts the file set, so this
    walks the intersection.
    """
    up = {p.relative_to(upstream).as_posix() for p in upstream.rglob("*") if p.is_file()}
    bs = {p.relative_to(base).as_posix() for p in base.rglob("*") if p.is_file()}
    atoms: list[Atom] = []
    for rel in sorted(up & bs, key=lambda s: s.encode()):
        a, b = upstream / rel, base / rel
        if a.read_bytes() == b.read_bytes():
            continue
        al, bl = read_lines(a), read_lines(b)
        # The parent records which presentation hunk a row came from, so a
        # split stays traceable to the group a reviewer would have seen.
        parents: dict[int, str] = {}
        for n, group in enumerate(
            difflib.SequenceMatcher(None, al, bl, autojunk=False)
            .get_grouped_opcodes(DIFF_CONTEXT), start=1
        ):
            for tag, i1, i2, _j1, _j2 in group:
                if tag != "equal":
                    parents[i1] = f"{rel}#{n}"
        index = 0
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            None, al, bl, autojunk=False
        ).get_opcodes():
            if tag == "equal":
                continue
            index += 1
            added = tuple(bl[j1:j2])
            atoms.append(Atom(
                path=rel, index=index, i1=i1, i2=i2,
                old=tuple(al[i1:i2]), new=added,
                symbol=resolve_symbol(added, al, i1),
                parent=parents.get(i1, f"{rel}#?"),
            ))
    return atoms


def manifest_digest(path: Path) -> str:
    """Digest the base manifest after proving it speaks the shared schema."""
    text = path.read_text(encoding="utf-8")
    declared = next(
        (ln for ln in text.splitlines() if ln.startswith("# manifest-schema:")), None
    )
    if declared is None:
        raise SchemaError(f"{path} declares no manifest schema")
    token = declared.split(":", 1)[1].strip()
    if token != MANIFEST_SCHEMA:
        raise SchemaError(f"{path} declares schema {token!r}, expected {MANIFEST_SCHEMA!r}")
    return hashlib.sha256(text.encode()).hexdigest()


def upstream_tree_from_snapshot(snapshot: Path) -> str:
    """Read the base oracle's upstream subtree from the history snapshot.

    The snapshot names a subtree under both [base] and [target], so it is
    parsed as TOML rather than scanned for a matching line: a line scan takes
    whichever match comes last and would bind the map to the v7.1 tree.
    """
    if not snapshot.is_file():
        raise SchemaError(f"missing history snapshot: {snapshot}")
    with snapshot.open("rb") as fh:
        data = tomllib.load(fh)
    tree = data.get("base", {}).get("radeon_subtree_tree")
    if not tree:
        raise SchemaError(f"{snapshot} declares no [base] radeon_subtree_tree")
    return tree


def header_value(lines: list[str], key: str) -> str | None:
    prefix = f"# {key}:"
    for ln in lines:
        if ln.startswith(prefix):
            return ln[len(prefix):].strip()
    return None


def read_map(path: Path, upstream_tree: str, base_digest: str) -> list[dict[str, str]]:
    """Read the map after proving its header names the oracles it was built on."""
    if not path.is_file():
        raise SchemaError(f"missing map: {path}")
    lines = path.read_text(encoding="utf-8").splitlines()

    declared = header_value(lines, "schema")
    if declared != MAP_SCHEMA:
        raise SchemaError(f"{path} declares schema {declared!r}, expected {MAP_SCHEMA!r}")
    for key, want in (
        ("upstream-subtree-tree", upstream_tree),
        ("base-manifest-sha256", base_digest),
        ("diff-engine", DIFF_ENGINE),
        ("diff-context", str(DIFF_CONTEXT)),
    ):
        got = header_value(lines, key)
        if got != want:
            raise SchemaError(f"{path} declares {key} {got!r}, and this run has {want!r}")

    rows: list[dict[str, str]] = []
    header: list[str] | None = None
    for lineno, raw in enumerate(lines, start=1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if header is None:
            if fields != COLUMNS:
                raise SchemaError(f"{path} header is {fields}, and the schema is {COLUMNS}")
            header = fields
            continue
        # Strict arity. A short row would leave a required field unset and a
        # long row would carry data no column claims.
        if len(fields) != len(COLUMNS):
            raise SchemaError(
                f"{path} line {lineno} carries {len(fields)} fields, expected {len(COLUMNS)}"
            )
        rows.append(dict(zip(COLUMNS, fields, strict=True)))
    if header is None:
        raise SchemaError(f"{path} carries no column header")
    return rows


def check_provenance(row: dict[str, str]) -> list[str]:
    """Require the evidence each origin kind rests on.

    A classification without its provenance is an assertion, and the point of
    the map is that every row names what would confirm or refute it.
    """
    bad: list[str] = []
    kind = row["origin_kind"]
    commit = row["upstream_origin_commit"]
    if kind not in ORIGIN_KINDS:
        bad.append(f"origin_kind {kind!r} is outside {sorted(ORIGIN_KINDS)}")
    if row["mechanism_lane"] not in MECHANISM_LANES:
        bad.append(f"mechanism_lane {row['mechanism_lane']!r} is outside "
                   f"{sorted(MECHANISM_LANES)}")
    if row["materialization_kind"] not in MATERIALIZATION_KINDS:
        bad.append(f"materialization_kind {row['materialization_kind']!r} is outside "
                   f"{sorted(MATERIALIZATION_KINDS)}")
    for field in ("legacy_origin", "execution_scope", "evidence_scope"):
        if not row[field].strip():
            bad.append(f"{field} is empty")

    if kind in {"exact-upstream-backport", "upstream-derived-adaptation"}:
        if not SHA40.match(commit):
            bad.append(f"{kind} needs a full 40-character upstream commit, got {commit!r}")
        if kind == "upstream-derived-adaptation" and not row["notes"].strip():
            bad.append("upstream-derived-adaptation needs the local divergence in notes")
    elif kind == "project-local":
        if commit != "none":
            bad.append(f"project-local records upstream_origin_commit 'none', got {commit!r}")
    elif kind == "reconstructed-input":
        if row["materialization_kind"] != "inferred-from-generated-output":
            bad.append("reconstructed-input is inferred-from-generated-output")
        if not row["notes"].strip():
            bad.append("reconstructed-input needs its inference evidence in notes")
    return bad


def reconstruct(upstream: Path, atoms: list[Atom], base: Path) -> list[str]:
    """Apply every atom to upstream and report paths that miss the base.

    Applying the opcodes directly is exact by construction: there is no fuzz
    policy to inherit and no backup file to leak into a manifest.
    """
    by_path: dict[str, list[Atom]] = {}
    for a in atoms:
        by_path.setdefault(a.path, []).append(a)
    wrong: list[str] = []
    for rel, group in by_path.items():
        lines = read_lines(upstream / rel)
        for a in sorted(group, key=lambda x: x.i1, reverse=True):
            lines[a.i1:a.i2] = list(a.new)
        if "".join(lines).encode("utf-8", "surrogateescape") != (base / rel).read_bytes():
            wrong.append(rel)
    return wrong


def run(upstream: Path, base: Path, map_path: Path, base_manifest: Path,
        snapshot: Path) -> int:
    base_digest = manifest_digest(base_manifest)
    upstream_tree = upstream_tree_from_snapshot(snapshot)

    atoms = decompose(upstream, base)
    total = sum(a.changed_lines for a in atoms)
    print(f"delta: {len(atoms)} atoms across {len({a.path for a in atoms})} files, "
          f"{total} changed lines")

    ids = {a.hunk_id(upstream_tree, base_digest): a for a in atoms}
    if len(ids) != len(atoms):
        print("two atoms share a hunk_id, so the binding is not injective")
        return 1

    rows = read_map(map_path, upstream_tree, base_digest)
    failures = 0
    seen: dict[str, int] = {}
    for r in rows:
        seen[r["hunk_id"]] = seen.get(r["hunk_id"], 0) + 1

    unassigned = [a for i, a in ids.items() if i not in seen]
    if unassigned:
        lines = sum(a.changed_lines for a in unassigned)
        print(f"unassigned: {len(unassigned)} atoms, {lines} changed lines")
        for a in unassigned[:20]:
            print(f"  {a.label}  {a.changed_lines} lines  {a.symbol}")
        if len(unassigned) > 20:
            print(f"  ... {len(unassigned) - 20} more")
        failures += 1

    for i in sorted(d for d in seen if d not in ids):
        print(f"row names a hunk_id absent from the delta: {i}")
        failures += 1
    for i in sorted(d for d, n in seen.items() if n > 1):
        print(f"hunk assigned to {seen[i]} rows: {ids[i].label if i in ids else i}")
        failures += 1

    for r in rows:
        atom = ids.get(r["hunk_id"])
        if atom is None:
            continue
        # A row can carry a valid identifier and a wrong file label, and
        # reconstruction would still succeed, so the label is checked.
        if r["file"] != atom.path:
            print(f"row {r['hunk_id']} labels file {r['file']!r}, atom is at {atom.path!r}")
            failures += 1
        if r["normalized_diff_sha256"] != atom.content_digest:
            print(f"row {r['hunk_id']} content fingerprint disagrees with the atom")
            failures += 1
        for problem in check_provenance(r):
            print(f"row {r['hunk_id']} ({atom.path}): {problem}")
            failures += 1

    if failures:
        print("base-delta map does not close over the delta")
        return 1

    wrong = reconstruct(upstream, [ids[i] for i in seen], base)
    for rel in wrong:
        print(f"reconstruction differs from the base oracle at {rel}")
    if wrong:
        print("the mapped atom union does not reconstruct the base")
        return 1

    print("reconstruction equals the base oracle at every mapped path")
    print(f"base-delta map closes: {len(rows)} rows, {total} changed lines assigned")
    return 0


def self_test() -> int:
    """Calibrate against a closing map and every way one fails."""
    import tempfile
    failures = 0

    def check(label: str, ok: bool) -> None:
        nonlocal failures
        print(f"  ok: {label}" if ok else f"  CALIBRATION FAIL: {label}")
        failures += 0 if ok else 1

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        up, bs = root / "up", root / "base"
        (up / "reg_srcs").mkdir(parents=True)
        (bs / "reg_srcs").mkdir(parents=True)
        body = "".join(f"\tline {i};\n" for i in range(1, 41))
        (up / "a.c").write_text("int probe(void)\n{\n" + body + "}\n", encoding="utf-8")
        (bs / "a.c").write_text(
            ("int probe(void)\n{\n" + body + "}\n")
            .replace("\tline 5;\n", "\tline 5;\n\tint added;\n")
            .replace("\tline 35;\n", "\tint changed;\n"),
            encoding="utf-8")
        (up / "b.c").write_text("static int x;\n", encoding="utf-8")
        (bs / "b.c").write_text("static int x;\n", encoding="utf-8")
        (up / "reg_srcs" / "evergreen").write_text("0x0000A010 A\n", encoding="utf-8")
        (bs / "reg_srcs" / "evergreen").write_text(
            "0x0000A010 A\n0x0000A020 SMX_DC_CTL0\n", encoding="utf-8")

        snap = root / "upstream-history-snapshot.toml"
        snap.write_text(
            'schema = 1\n'
            '[base]\nradeon_subtree_tree = "tree1"\n'
            '[target]\nradeon_subtree_tree = "tree9"\n',
            encoding="utf-8")

        man = root / "base-manifest.tsv"
        man.write_text(f"# manifest-schema: {MANIFEST_SCHEMA}\npath\tmode\tsize\tsha256\n",
                       encoding="utf-8")
        digest = manifest_digest(man)

        # The snapshot names a subtree under [base] and under [target]. A line
        # scan would take the last match and bind the map to the wrong oracle.
        check("the base subtree comes from [base], not the last match",
              upstream_tree_from_snapshot(snap) == "tree1")

        atoms = decompose(up, bs)
        check("separated edits atomize apart", len([a for a in atoms if a.path == "a.c"]) == 2)
        check("an identical file contributes no atom",
              not [a for a in atoms if a.path == "b.c"])
        check("an atom records its presentation parent",
              all(a.parent.startswith(a.path + "#") for a in atoms))
        check("the enclosing symbol resolves",
              any(a.symbol == "probe" for a in atoms if a.path == "a.c"))
        check("a changed oracle changes every hunk_id",
              {a.hunk_id("tree1", digest) for a in atoms}
              .isdisjoint({a.hunk_id("tree2", digest) for a in atoms}))

        def good(a: Atom) -> list[str]:
            if a.path.startswith("reg_srcs/"):
                return [a.path, a.symbol, a.hunk_id("tree1", digest), a.parent,
                        a.content_digest, "reconstructed-input", "Palm/Wrestler",
                        "inferred-from-generated-output", "none", "legacy bitmap",
                        "CPU-only", "inferred", "", "regenerates the shipped bitmap"]
            return [a.path, a.symbol, a.hunk_id("tree1", digest), a.parent,
                    a.content_digest, "project-local", "RS48X",
                    "observed-in-legacy-base", "none", "patch 0001",
                    "CPU-only", "compile-verified", "", ""]

        def write(rows: list[list[str]], **hdr: str) -> Path:
            m = root / "map.tsv"
            head = {"schema": MAP_SCHEMA, "upstream-subtree-tree": "tree1",
                    "base-manifest-sha256": digest, "diff-engine": DIFF_ENGINE,
                    "diff-context": str(DIFF_CONTEXT), **hdr}
            with m.open("w", encoding="utf-8") as fh:
                for k, v in head.items():
                    fh.write(f"# {k}: {v}\n")
                fh.write("\t".join(COLUMNS) + "\n")
                for r in rows:
                    fh.write("\t".join(r) + "\n")
            return m

        def result(rows: list[list[str]], **hdr: str) -> int:
            try:
                return run(up, bs, write(rows, **hdr), man, snap)
            except SchemaError as exc:
                print(f"    (schema) {exc}")
                return 2

        # The snapshot file is absent in the fixture, so run() reads
        # "unrecorded" as the tree and the header must agree with that.
        complete = [good(a) for a in atoms]
        base_hdr: dict[str, str] = {}

        check("a complete map closes", result(complete, **base_hdr) == 0)
        check("an empty map fails", result([], **base_hdr) == 1)
        check("a partial map fails", result(complete[:1], **base_hdr) == 1)
        check("a duplicated atom fails",
              result(complete + [complete[0]], **base_hdr) == 1)

        def mutate(i: int, col: str, value: str) -> list[list[str]]:
            rows = [list(r) for r in complete]
            rows[i][COLUMNS.index(col)] = value
            return rows

        check("a valid identifier with the wrong file fails",
              result(mutate(0, "file", "elsewhere.c"), **base_hdr) == 1)
        check("a content fingerprint disagreeing with the atom fails",
              result(mutate(0, "normalized_diff_sha256", "0" * 64), **base_hdr) == 1)
        check("an identifier absent from the delta fails",
              result(complete + [mutate(0, "hunk_id", "f" * 16)[0]], **base_hdr) == 1)
        check("an unrecognized origin kind fails",
              result(mutate(0, "origin_kind", "misc"), **base_hdr) == 1)
        check("an unrecognized mechanism lane fails",
              result(mutate(0, "mechanism_lane", "misc"), **base_hdr) == 1)
        check("an unrecognized materialization kind fails",
              result(mutate(0, "materialization_kind", "misc"), **base_hdr) == 1)
        check("an empty execution scope fails",
              result(mutate(0, "execution_scope", ""), **base_hdr) == 1)
        check("an empty legacy origin fails",
              result(mutate(0, "legacy_origin", ""), **base_hdr) == 1)
        check("an empty evidence scope fails",
              result(mutate(0, "evidence_scope", ""), **base_hdr) == 1)

        backport = mutate(0, "origin_kind", "exact-upstream-backport")
        check("a backport without a full upstream commit fails",
              result(backport, **base_hdr) == 1)
        backport[0][COLUMNS.index("upstream_origin_commit")] = "a" * 40
        check("a backport with a full upstream commit passes",
              result(backport, **base_hdr) == 0)
        backport[0][COLUMNS.index("upstream_origin_commit")] = "a" * 12
        check("an abbreviated upstream commit fails",
              result(backport, **base_hdr) == 1)

        derived = mutate(0, "origin_kind", "upstream-derived-adaptation")
        derived[0][COLUMNS.index("upstream_origin_commit")] = "b" * 40
        check("an adaptation without its divergence described fails",
              result(derived, **base_hdr) == 1)

        rec = [list(r) for r in complete]
        idx = next(i for i, r in enumerate(rec) if r[0].startswith("reg_srcs/"))
        rec[idx][COLUMNS.index("notes")] = ""
        check("a reconstructed input lacking its inference evidence fails",
              result(rec, **base_hdr) == 1)
        rec2 = [list(r) for r in complete]
        rec2[idx][COLUMNS.index("materialization_kind")] = "observed-in-legacy-base"
        check("a reconstructed input claiming observation fails",
              result(rec2, **base_hdr) == 1)

        check("a project-local row naming an upstream commit fails",
              result(mutate(0, "upstream_origin_commit", "c" * 40), **base_hdr) == 1)

        # Arity and header binding.
        short = [list(r) for r in complete]
        short[0] = short[0][:-1]
        check("too few columns fails", result(short, **base_hdr) == 2)
        long_row = [list(r) for r in complete]
        long_row[0] = [*long_row[0], "extra"]
        check("too many columns fails", result(long_row, **base_hdr) == 2)
        check("a foreign map schema fails", result(complete, schema="other-v9") == 2)
        check("a header naming another upstream tree fails",
              result(complete, **{"upstream-subtree-tree": "tree9"}) == 2)
        check("a header naming another base manifest fails",
              result(complete, **base_hdr, **{"base-manifest-sha256": "0" * 64}) == 2)

        bad_man = root / "foreign.tsv"
        bad_man.write_text("# manifest-schema: other-v9\npath\n", encoding="utf-8")
        try:
            manifest_digest(bad_man)
            check("a foreign base-manifest schema fails", False)
        except SchemaError:
            check("a foreign base-manifest schema fails", True)

    if failures:
        print(f"base-delta closure calibration: FAIL ({failures})")
        return 1
    print("base-delta closure calibration: 6 decomposition properties, "
          "2 closing maps, 24 failure classes")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--upstream", type=Path)
    ap.add_argument("--base", type=Path)
    ap.add_argument("--map", type=Path)
    ap.add_argument("--base-manifest", type=Path)
    ap.add_argument("--snapshot", type=Path,
                    default=Path("docs/upstream-history-snapshot.toml"))
    ap.add_argument("--emit-skeleton", type=Path,
                    help="write one unclassified row per atom here and exit")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not (args.upstream and args.base and args.base_manifest):
        ap.error("give --upstream, --base, and --base-manifest, or --self-test")
    for d in (args.upstream, args.base):
        if not d.is_dir():
            print(f"not a directory: {d}", file=sys.stderr)
            return 2

    try:
        base_digest = manifest_digest(args.base_manifest)
    except SchemaError as exc:
        print(f"manifest schema: {exc}", file=sys.stderr)
        return 2

    if args.emit_skeleton:
        upstream_tree = upstream_tree_from_snapshot(args.snapshot)
        atoms = decompose(args.upstream, args.base)
        with args.emit_skeleton.open("w", encoding="utf-8") as fh:
            for k, v in (("schema", MAP_SCHEMA),
                         ("upstream-subtree-tree", upstream_tree),
                         ("base-manifest-sha256", base_digest),
                         ("diff-engine", DIFF_ENGINE),
                         ("diff-context", str(DIFF_CONTEXT))):
                fh.write(f"# {k}: {v}\n")
            fh.write("\t".join(COLUMNS) + "\n")
            for a in atoms:
                fh.write("\t".join([
                    a.path, a.symbol, a.hunk_id(upstream_tree, base_digest), a.parent,
                    a.content_digest, "", "", "", "", "", "", "", "", "",
                ]) + "\n")
        print(f"skeleton: {args.emit_skeleton} ({len(atoms)} rows)")
        return 0

    if not args.map:
        ap.error("give --map, or --emit-skeleton")
    try:
        return run(args.upstream, args.base, args.map, args.base_manifest,
                   args.snapshot)
    except SchemaError as exc:
        print(f"schema: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
