#!/usr/bin/env python3
"""Check project-authored prose for dash constructions.

AGENTS.md states that a dash marks a clause the sentence structure states more
precisely on its own, so the construct leaves project-authored Markdown,
comments, and package metadata. This gate enforces that rule where raw grep
cannot, because several ASCII `--` runs are code rather than prose:

  * command flags such as `git diff --staged` and `mkregtable --help`;
  * the POSIX end-of-options separator in `cd -- "$dir"` and `set -- LLVM=1`;
  * fenced code blocks and indented code inside Markdown;
  * ASCII diagrams whose branches spell `|--`;
  * checked-in patch bodies, whose bytes the packaging sha256sums verify.

Run without arguments to scan the tracked project-authored set. Run with
--self-test to calibrate against known-good and known-bad fixtures, which is
the calibration AGENTS.md requires of a verdict-producing script.

Exit: 0 clean, 1 findings, 2 usage or environment error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# A dash construction is a standalone `--` run with whitespace on both sides, or
# one that ends a line. A flag (`--staged`) has no leading space before its
# letters; the end-of-options separator is caught by the code rules below.
DASH = re.compile(r"(?:(?<=\s)|^)--(?=\s|$)")

# POSIX end-of-options separator: the token that stops option parsing. These are
# code, and they appear in every careful shell script in this tree.
END_OF_OPTIONS = re.compile(
    r"\b(?:cd|set|basename|dirname|rm|cp|mv|grep|printf|echo|git|install|"
    r"mkdir|touch|chmod|chown|ln|sed|awk|read|export|unset|xargs|find)\s+"
    r"(?:-[A-Za-z]+\s+)*--(?=\s|$)"
)

# ASCII diagram branches: `|--`, `+--`, `\--`, and continuation rows.
DIAGRAM = re.compile(r"^\s*[|+\\`]")

# Shell and Python comment openers, so script scanning reads comments only.
SHELL_COMMENT = re.compile(r"(?:^|\s)#")

SKIP_DIRS = {".git", "pkg", "src", "__pycache__", ".ruff_cache", "sources"}
SKIP_SUFFIXES = {".patch", ".diff", ".tar", ".xz", ".gz", ".tsv"}


def tracked_files(root: Path) -> list[Path]:
    """Return tracked files, so untracked scratch and build output stay out."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [root / line for line in result.stdout.splitlines() if line]


def is_scannable(path: Path, root: Path) -> bool:
    rel = path.relative_to(root)
    if any(part in SKIP_DIRS for part in rel.parts):
        return False
    if path.suffix in SKIP_SUFFIXES:
        return False
    if path.suffix in {".md", ".sh", ".py", ".c", ".h", ".conf"}:
        return True
    return path.name.startswith("PKGBUILD")


def prose_lines(path: Path, text: str):
    """Yield (lineno, line) for lines carrying project-authored prose.

    Markdown yields every line outside a fenced block. A script yields comment
    lines and package metadata strings, since its executable statements are
    code and their `--` runs are options.
    """
    fenced = False
    markdown = path.suffix == ".md"
    for lineno, line in enumerate(text.splitlines(), start=1):
        if markdown:
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            if fenced or line.startswith("    ") or line.startswith("\t"):
                continue
            yield lineno, line
            continue
        # Scripts, headers, and PKGBUILD: comments plus quoted description text.
        if SHELL_COMMENT.search(line) or line.lstrip().startswith(("*", "/*", "//")):
            yield lineno, line
        elif "desc=" in line or "optdepends=" in line or line.lstrip().startswith("'"):
            yield lineno, line


def findings(root: Path, paths: list[Path]) -> list[tuple[Path, int, str]]:
    out = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in prose_lines(path, text):
            if DIAGRAM.match(line):
                continue
            masked = END_OF_OPTIONS.sub("", line)
            if DASH.search(masked):
                out.append((path.relative_to(root), lineno, line.strip()))
    return out


GOOD_FIXTURES = [
    ("good.md", "The kernel reads WORD0: it adds the relocation offset.\n"),
    ("good_flag.md", "Run `git diff --staged` before every commit.\n"),
    ("good_fence.md", "Text.\n\n```sh\ncd -- \"$dir\"\necho a -- b\n```\n"),
    ("good_diagram.md", "Layout:\n\n|-- patches/\n|   |-- rs480/\n"),
    ("good_eoo.sh", "#!/bin/sh\ncd -- \"$(dirname -- \"$0\")\" || exit 1\nset -- LLVM=1\n"),
    ("good_code.sh", "#!/bin/sh\nprintf '%s\\n' -- \"$x\"\ngrep -- \"$pat\" file\n"),
]

# The dash token is composed rather than written, so this gate stays clean
# against its own scan while the fixtures still carry a real dash at runtime.
_D = "-" * 2

BAD_FIXTURES = [
    ("bad_prose.md", f"The reader hard-returns {_D} it never touches MMIO.\n"),
    ("bad_trailing.md", f"Two arming domains exist {_D}\nand the third differs.\n"),
    ("bad_comment.sh", f"#!/bin/sh\n# a zero-context insert {_D} whose target drifts\ntrue\n"),
    ("bad_pkgbuild", f"optdepends=('foo: SB600 substrate {_D} REQUIRED')\n"),
]


def self_test(tmp: Path) -> int:
    """Calibrate: every good fixture stays silent, every bad fixture reports."""
    failures = 0
    for name, body in GOOD_FIXTURES:
        p = tmp / name
        p.write_text(body, encoding="utf-8")
        hits = findings(tmp, [p])
        if hits:
            print(f"CALIBRATION FAIL: {name} is known-good but reported {hits}")
            failures += 1
    for name, body in BAD_FIXTURES:
        p = tmp / name
        p.write_text(body, encoding="utf-8")
        hits = findings(tmp, [p])
        if not hits:
            print(f"CALIBRATION FAIL: {name} is known-bad and went unreported")
            failures += 1
    if failures:
        print(f"prose-style calibration: FAIL ({failures})")
        return 1
    print(
        f"prose-style calibration: {len(GOOD_FIXTURES)} known-good silent, "
        f"{len(BAD_FIXTURES)} known-bad reported"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="calibrate against known-good and known-bad fixtures",
    )
    args = parser.parse_args()

    if args.self_test:
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            return self_test(Path(td))

    try:
        root = Path(
            subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("not inside a git repo", file=sys.stderr)
        return 2

    paths = [p for p in tracked_files(root) if p.is_file() and is_scannable(p, root)]
    hits = findings(root, paths)
    for rel, lineno, line in hits:
        print(f"{rel}:{lineno}: dash construction: {line}")
    if hits:
        print(f"project prose style: {len(hits)} dash constructions")
        return 1
    print(f"project prose style: clean ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
