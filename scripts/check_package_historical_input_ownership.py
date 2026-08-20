#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 eirikr
"""Keep historical Radeon inputs outside the active package directory."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

PACKAGE_PREFIX = "packaging/arch/radeon-unified-dkms/"
LEGACY_RECIPE_PATH = Path(
    "packaging/arch/radeon-unified-dkms/PKGBUILD.radeon-rs480-safe-regs-0.2"
)
FORBIDDEN_TABLES = {
    f"{PACKAGE_PREFIX}rs480-safe-regs.tsv",
    f"{PACKAGE_PREFIX}rs480-candidate-regs.tsv",
}
REQUIRED_LEGACY_SOURCES = (
    '"SAFE_REGS.tsv::file://${startdir}/../../../patches/rs480/SAFE_REGS.tsv"',
    '"0001-rs480-safe-regs-debugfs.patch::file://${startdir}/../../../patches/rs480/0001-rs480-safe-regs-debugfs.patch"',
)
FORBIDDEN_DOCUMENT_REFERENCES = (
    re.compile(r"packaging/arch/radeon-unified-dkms/[^\s`]+\.patch"),
    re.compile(r"(?<![A-Za-z0-9_-])rs480-safe-regs\.tsv(?![A-Za-z0-9_-])"),
    re.compile(r"(?<![A-Za-z0-9_-])rs480-candidate-regs\.tsv(?![A-Za-z0-9_-])"),
)


class OwnershipError(Exception):
    """A historical input occupies or points at the active package directory."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise OwnershipError(message)


def verify_inputs(
    tracked_paths: tuple[str, ...],
    legacy_recipe: str,
    documents: dict[str, str],
) -> None:
    package_patches = tuple(
        path
        for path in tracked_paths
        if path.startswith(PACKAGE_PREFIX) and path.endswith(".patch")
    )
    require(
        not package_patches,
        "active package directory contains historical patch inputs: "
        + ", ".join(package_patches),
    )
    package_tables = tuple(sorted(FORBIDDEN_TABLES.intersection(tracked_paths)))
    require(
        not package_tables,
        "active package directory contains historical register tables: "
        + ", ".join(package_tables),
    )

    for source in REQUIRED_LEGACY_SOURCES:
        require(
            legacy_recipe.count(source) == 1,
            "legacy package recipe does not bind exactly one canonical source: "
            + source,
        )

    for path, text in documents.items():
        for pattern in FORBIDDEN_DOCUMENT_REFERENCES:
            require(
                pattern.search(text) is None,
                f"{path}: historical input points at an obsolete package mirror",
            )


def repository_inputs(
    repository: Path,
) -> tuple[tuple[str, ...], str, dict[str, str]]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=repository,
        check=False,
        stdout=subprocess.PIPE,
    )
    require(result.returncode == 0, "git ls-files fails")
    tracked_paths = tuple(
        decoded
        for path in result.stdout.split(b"\0")
        if path
        for decoded in (path.decode("utf-8"),)
        if (repository / decoded).is_file()
    )
    legacy_recipe = (repository / LEGACY_RECIPE_PATH).read_text(encoding="utf-8")
    documents = {
        path: (repository / path).read_text(encoding="utf-8")
        for path in tracked_paths
        if Path(path).suffix in {".md", ".tsv"}
    }
    return tracked_paths, legacy_recipe, documents


def replace_once(text: str, old: str, new: str) -> str:
    require(text.count(old) == 1, "self-test mutation anchor is not unique")
    return text.replace(old, new, 1)


def run_self_test(repository: Path) -> None:
    tracked_paths, legacy_recipe, documents = repository_inputs(repository)
    verify_inputs(tracked_paths, legacy_recipe, documents)
    print("PASS known-good: historical inputs have one canonical repository home")

    mutations = (
        (
            "package patch mirror",
            tracked_paths + (f"{PACKAGE_PREFIX}rs480-example.patch",),
            legacy_recipe,
            documents,
        ),
        (
            "package safe-register mirror",
            tracked_paths + (f"{PACKAGE_PREFIX}rs480-safe-regs.tsv",),
            legacy_recipe,
            documents,
        ),
        (
            "package candidate-register mirror",
            tracked_paths + (f"{PACKAGE_PREFIX}rs480-candidate-regs.tsv",),
            legacy_recipe,
            documents,
        ),
        (
            "legacy safe-register source drift",
            tracked_paths,
            replace_once(
                legacy_recipe,
                "../../../patches/rs480/SAFE_REGS.tsv",
                "rs480-safe-regs.tsv",
            ),
            documents,
        ),
        (
            "legacy patch source drift",
            tracked_paths,
            replace_once(
                legacy_recipe,
                "../../../patches/rs480/0001-rs480-safe-regs-debugfs.patch",
                "rs480-safe-regs-debugfs.patch",
            ),
            documents,
        ),
        (
            "obsolete package patch citation",
            tracked_paths,
            legacy_recipe,
            {
                **documents,
                "README.md": documents["README.md"]
                + "\n`packaging/arch/radeon-unified-dkms/rs480-example.patch`\n",
            },
        ),
        (
            "obsolete lowercase table citation",
            tracked_paths,
            legacy_recipe,
            {
                **documents,
                "README.md": documents["README.md"] + "\n`rs480-safe-regs.tsv`\n",
            },
        ),
    )
    rejected = 0
    for name, changed_paths, changed_recipe, changed_documents in mutations:
        try:
            verify_inputs(changed_paths, changed_recipe, changed_documents)
        except OwnershipError:
            rejected += 1
            print(f"PASS known-bad: {name}")
        else:
            raise OwnershipError(f"self-test accepts known-bad fixture: {name}")
    print(
        "package historical-input ownership calibration: "
        f"1 known-good and {rejected} known-bad fixtures"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    try:
        if arguments.self_test:
            run_self_test(repository)
        else:
            verify_inputs(*repository_inputs(repository))
            print("historical package inputs have one canonical repository home")
    except (OwnershipError, OSError, UnicodeError) as error:
        print(f"package historical-input ownership: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
