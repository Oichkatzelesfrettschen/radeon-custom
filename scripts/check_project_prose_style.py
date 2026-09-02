#!/usr/bin/env python3
"""Check project-authored prose for dash constructions and emoji.

AGENTS.md states that a dash marks a clause the sentence structure states more
precisely on its own, so the construct leaves project-authored Markdown,
comments, and package metadata. This gate enforces that rule where raw grep
cannot, because several ASCII `--` runs are code rather than prose:

  * command flags such as `git diff --staged` and `mkregtable --help`;
  * the POSIX end-of-options separator in `cd -- "$dir"` and `set -- LLVM=1`;
  * fenced code blocks and indented code inside Markdown;
  * ASCII diagrams whose branches spell `|--`;
  * checked-in patch bodies, whose bytes the packaging sha256sums verify.

Three rules judge a line: `emoji`, `unicode dash` for the en and em dash, and
`dash construction` for the ASCII stand-in. Every refusal names the rule it
tripped, because the three need different edits and share one exit status.

Run without arguments to scan the tracked project-authored set. Run with
--self-test to calibrate against known-good and known-bad fixtures, which is
the calibration AGENTS.md requires of a verdict-producing script. Each
known-bad asserts the rule name it expects, so a report that refuses the right
line under the wrong rule fails the calibration.

Exit: 0 clean, 1 findings, 2 usage or environment error.
"""

from __future__ import annotations

import argparse
import collections
import re
import subprocess
import sys
from pathlib import Path

# A dash construction is a standalone `--` run with whitespace on both sides, or
# one that ends a line. A flag (`--staged`) has no leading space before its
# letters; the end-of-options separator is caught by the code rules below.
DASH = re.compile(r"(?:(?<=\s)|^)--(?=\s|$)")

# Each rule names itself in the refusal it produces, so a report says which
# edit clears the line.
DASH_RULE = "dash construction"
UNICODE_DASH_RULE = "unicode dash"
EMOJI_RULE = "emoji"

# AGENTS.md forbids the em dash, the en dash, and the ASCII `--` stand-in alike,
# so the gate recognizes all three. The two code points are built by ordinal so
# the gate stays clean against its own scan.
UNICODE_DASH = re.compile(f"[{chr(0x2013)}{chr(0x2014)}]")

# AGENTS.md states that checked-in text is emoji-free, so an emoji is a finding
# wherever the dash rule reads. The ranges cover the pictographic planes, the
# Miscellaneous Symbols and Dingbats blocks, and the variation selector that
# gives a text symbol emoji presentation. Mathematical operators, arrows,
# box-drawing, Greek letters, the degree and micro signs, and accented names
# carry meaning and sit outside every range, so they pass.
EMOJI = re.compile(
    "["
    f"{chr(0x2600)}-{chr(0x27BF)}"
    f"{chr(0x2B00)}-{chr(0x2BFF)}"
    f"{chr(0xFE0F)}"
    f"{chr(0x1F000)}-{chr(0x1FAFF)}"
    "]"
)

# POSIX end-of-options separator: the token that stops option parsing. These are
# code, and they appear in every careful shell script in this tree.
END_OF_OPTIONS = re.compile(
    r"\b(?:cd|set|basename|dirname|rm|cp|mv|grep|printf|echo|git|install|"
    r"mkdir|touch|chmod|chown|ln|sed|awk|read|export|unset|xargs|find)\s+"
    r"(?:-[A-Za-z]+\s+)*--(?=\s|$)"
)

# ASCII diagram branches: a run of drawing characters followed by a branch token
# such as `|--`, `+--`, `\--`, or a backtick corner. Matching the branch token
# rather than the first character keeps Markdown table rows, `+` list items, and
# prose opening with inline code inside the gate's judgment.
DIAGRAM = re.compile(r"^[\s|+\\`]*[|+\\`]--")

# Shell and Python comment openers, so script scanning reads comments only.
SHELL_COMMENT = re.compile(r"(?:^|\s)#")

SKIP_DIRS = {".git", "pkg", "src", "__pycache__", ".ruff_cache", "sources"}
SKIP_SUFFIXES = {".patch", ".diff", ".tar", ".xz", ".gz", ".tsv"}

# Project-authored prose that lives inside an otherwise-excluded directory. The
# directory exclusions hold vendored and generated content out of the corpus,
# and a repository-authored file sitting beside that content is still governed
# by the rule, so it is admitted by exact repository-relative path.
ADMIT_PATHS = {"sources/PROVENANCE.md"}


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
    if rel.as_posix() in ADMIT_PATHS:
        return True
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


def findings(root: Path, paths: list[Path]) -> list[tuple[Path, int, str, str]]:
    """Report every prose violation as (path, line number, rule, line).

    Each rule carries its own name so a refusal points at the edit that
    clears it: an emoji and an em dash fail the same run and need different
    fixes.
    """
    out = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in prose_lines(path, text):
            if EMOJI.search(line):
                out.append((path.relative_to(root), lineno, EMOJI_RULE, line.strip()))
                continue
            if UNICODE_DASH.search(line):
                out.append(
                    (path.relative_to(root), lineno, UNICODE_DASH_RULE, line.strip())
                )
                continue
            if DIAGRAM.match(line):
                continue
            masked = END_OF_OPTIONS.sub("", line)
            if DASH.search(masked):
                out.append((path.relative_to(root), lineno, DASH_RULE, line.strip()))
    return out


GOOD_FIXTURES = [
    ("good.md", "The kernel reads WORD0: it adds the relocation offset.\n"),
    ("good_flag.md", "Run `git diff --staged` before every commit.\n"),
    ("good_fence.md", "Text.\n\n```sh\ncd -- \"$dir\"\necho a -- b\n```\n"),
    ("good_diagram.md", "Layout:\n\n|-- patches/\n|   |-- rs480/\n"),
    ("good_table.md", "| Gate | Status |\n| --- | --- |\n| apply | clean |\n"),
    ("good_eoo.sh", "#!/bin/sh\ncd -- \"$(dirname -- \"$0\")\" || exit 1\nset -- LLVM=1\n"),
    ("good_code.sh", "#!/bin/sh\nprintf '%s\\n' -- \"$x\"\ngrep -- \"$pat\" file\n"),
    (
        "good_utf8_symbols.md",
        "The reader holds at 30"
        + chr(0x00B0)
        + "C while "
        + chr(0x0394)
        + "t "
        + chr(0x2264)
        + " 5 "
        + chr(0x00B5)
        + "s.\n\nState "
        + chr(0x2192)
        + " idle.\n\n"
        + chr(0x250C)
        + chr(0x2500)
        + chr(0x2510)
        + "\n",
    ),
    ("good_accented_name.md", "Reviewed by Bj" + chr(0x00F6) + "rn.\n"),
]

# The dash tokens are composed rather than written, so this gate stays clean
# against its own scan while the fixtures still carry real dashes at runtime.
_D = "-" * 2
_EN = chr(0x2013)
_EM = chr(0x2014)

# Each known-bad names the rule it must trip. An emoji and an em dash both
# refuse the run, so a fixture that only asserts refusal admits a report that
# points the author at the wrong edit.
BAD_FIXTURES = [
    ("bad_emoji.md", "The gate passes " + chr(0x2705) + " on every profile.\n", EMOJI_RULE),
    (
        "bad_emoji_pictograph.md",
        "Reset storm " + chr(0x1F525) + " on the first draw.\n",
        EMOJI_RULE,
    ),
    ("bad_prose.md", f"The reader hard-returns {_D} it never touches MMIO.\n", DASH_RULE),
    (
        "bad_trailing.md",
        f"Two arming domains exist {_D}\nand the third differs.\n",
        DASH_RULE,
    ),
    (
        "bad_comment.sh",
        f"#!/bin/sh\n# a zero-context insert {_D} whose target drifts\ntrue\n",
        DASH_RULE,
    ),
    ("bad_pkgbuild", f"optdepends=('foo: SB600 substrate {_D} REQUIRED')\n", DASH_RULE),
    # A table cell is prose. The diagram exemption matches branch tokens, so a
    # row opening with a pipe stays inside the gate's judgment.
    (
        "bad_table.md",
        f"| Gate | Meaning |\n| --- | --- |\n| apply | clean {_D} no fuzz |\n",
        DASH_RULE,
    ),
    (
        "bad_en_dash.md",
        f"The GA block holds {_EN} the VAP clears first.\n",
        UNICODE_DASH_RULE,
    ),
    (
        "bad_em_dash.md",
        f"The GA block holds {_EM} the VAP clears first.\n",
        UNICODE_DASH_RULE,
    ),
]

# Corpus selection: (repository-relative path, admitted). The detector proves
# it judges an admitted file; these prove which files reach it at all, which is
# the half a fixture-only calibration leaves unexercised.
CORPUS_FIXTURES = [
    ("README.md", True),
    ("docs/rs480-parked-access-audit.md", True),
    ("scripts/check_project_prose_style.py", True),
    ("packaging/arch/radeon-unified-dkms/PKGBUILD", True),
    # Project-authored prose inside an excluded directory, admitted by path.
    ("sources/PROVENANCE.md", True),
    # Vendored and generated content beside it stays out.
    ("sources/xorg_ddx_radeon_reg.h", False),
    ("patches/rs480/0001-example.patch", False),
    ("pkg/generated/notes.md", False),
]


def self_test(tmp: Path) -> int:
    """Calibrate detection inside a file and selection of the corpus itself."""
    failures = 0
    for name, body in GOOD_FIXTURES:
        p = tmp / name
        p.write_text(body, encoding="utf-8")
        hits = findings(tmp, [p])
        if hits:
            print(f"CALIBRATION FAIL: {name} is known-good but reported {hits}")
            failures += 1
    for name, body, rule in BAD_FIXTURES:
        p = tmp / name
        p.write_text(body, encoding="utf-8")
        hits = findings(tmp, [p])
        if not hits:
            print(f"CALIBRATION FAIL: {name} is known-bad and went unreported")
            failures += 1
            continue
        reported = {hit[2] for hit in hits}
        if reported != {rule}:
            print(
                f"CALIBRATION FAIL: {name} trips {rule} and the report named "
                f"{', '.join(sorted(reported))}"
            )
            failures += 1
    for rel, admitted in CORPUS_FIXTURES:
        got = is_scannable(tmp / rel, tmp)
        if got != admitted:
            state = "admitted" if admitted else "excluded"
            print(f"CALIBRATION FAIL: {rel} belongs {state} and selection said {got}")
            failures += 1
    if failures:
        print(f"prose-style calibration: FAIL ({failures})")
        return 1
    print(
        f"prose-style calibration: {len(GOOD_FIXTURES)} known-good silent, "
        f"{len(BAD_FIXTURES)} known-bad reported, "
        f"{len(CORPUS_FIXTURES)} corpus-selection cases correct"
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
    for rel, lineno, rule, line in hits:
        print(f"{rel}:{lineno}: {rule}: {line}")
    if hits:
        counts = collections.Counter(rule for _, _, rule, _ in hits)
        tally = ", ".join(f"{counts[r]} {r}" for r in sorted(counts))
        print(f"project prose style: {len(hits)} findings ({tally})")
        return 1
    print(f"project prose style: clean ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
