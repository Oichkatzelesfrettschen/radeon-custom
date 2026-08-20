#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Capture and verify a complete immutable identity for a shared build root."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
import tempfile
from pathlib import Path

SCHEMA = "radeon-shared-build-root-v1"


class IdentityError(Exception):
    """A build root does not match its sealed identity."""


def digest_regular_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rows_for_root(root: Path) -> list[tuple[str, str, str, int, str]]:
    if not root.is_dir() or root.is_symlink():
        raise IdentityError(f"build root is not a real directory: {root}")
    rows: list[tuple[str, str, str, int, str]] = []
    for path in sorted(root.rglob("*"), key=lambda candidate: candidate.as_posix()):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        mode = f"{stat.S_IMODE(metadata.st_mode):04o}"
        if path.is_symlink():
            target = os.readlink(path)
            rows.append(
                (
                    relative,
                    "symlink",
                    mode,
                    len(target.encode("utf-8", "surrogateescape")),
                    hashlib.sha256(target.encode("utf-8", "surrogateescape")).hexdigest(),
                )
            )
        elif path.is_dir():
            rows.append((relative, "directory", mode, 0, "-"))
        elif path.is_file():
            rows.append((relative, "regular", mode, metadata.st_size, digest_regular_file(path)))
        else:
            raise IdentityError(f"build root contains an unsupported file type: {relative}")
    return rows


def encode(rows: list[tuple[str, str, str, int, str]]) -> str:
    lines = [f"# identity-schema: {SCHEMA}", "path\ttype\tmode\tsize\tsha256"]
    lines.extend("\t".join((path, kind, mode, str(size), digest)) for path, kind, mode, size, digest in rows)
    return "\n".join(lines) + "\n"


def read_manifest(path: Path) -> list[tuple[str, str, str, int, str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise IdentityError(f"cannot read identity manifest: {error}") from error
    if lines[:2] != [f"# identity-schema: {SCHEMA}", "path\ttype\tmode\tsize\tsha256"]:
        raise IdentityError("identity manifest has an invalid header")
    rows: list[tuple[str, str, str, int, str]] = []
    previous_path = ""
    for line in lines[2:]:
        fields = line.split("\t")
        if len(fields) != 5:
            raise IdentityError(f"identity manifest row has {len(fields)} fields: {line}")
        relative, kind, mode, size_text, digest = fields
        if not relative or relative.startswith("/") or ".." in relative.split("/"):
            raise IdentityError(f"identity manifest path is unsafe: {relative}")
        if relative <= previous_path:
            raise IdentityError(f"identity manifest paths are not strictly ordered: {relative}")
        if kind not in {"directory", "regular", "symlink"}:
            raise IdentityError(f"identity manifest type is invalid: {relative}")
        if len(mode) != 4 or any(character not in "01234567" for character in mode):
            raise IdentityError(f"identity manifest mode is invalid: {relative}")
        if not size_text.isdecimal():
            raise IdentityError(f"identity manifest size is invalid: {relative}")
        if kind == "directory":
            if digest != "-":
                raise IdentityError(f"identity manifest directory has a digest: {relative}")
        elif len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
            raise IdentityError(f"identity manifest digest is invalid: {relative}")
        rows.append((relative, kind, mode, int(size_text), digest))
        previous_path = relative
    return rows


def compare(expected: list[tuple[str, str, str, int, str]], actual: list[tuple[str, str, str, int, str]]) -> None:
    if expected == actual:
        return
    expected_rows = {row[0]: row[1:] for row in expected}
    actual_rows = {row[0]: row[1:] for row in actual}
    missing = sorted(expected_rows.keys() - actual_rows.keys())
    extra = sorted(actual_rows.keys() - expected_rows.keys())
    changed = sorted(
        path
        for path in expected_rows.keys() & actual_rows.keys()
        if expected_rows[path] != actual_rows[path]
    )
    raise IdentityError(
        "shared build-root identity differs: "
        f"missing={missing}, extra={extra}, changed={changed}"
    )


def capture(root: Path, output: Path) -> None:
    if output.exists() or output.is_symlink():
        raise IdentityError(f"identity manifest target already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(encode(rows_for_root(root)), encoding="utf-8")


def verify(root: Path, manifest: Path) -> None:
    compare(read_manifest(manifest), rows_for_root(root))


def expect_failure(action: str, message: str) -> None:
    try:
        action()
    except IdentityError:
        print(f"PASS known-bad: {message}")
    else:
        raise IdentityError(f"self-test accepts {message}")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-build-root-identity-") as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        (root / "include").mkdir()
        regular = root / "include" / "autoconf.h"
        regular.write_text("#define CONFIG_FIXTURE 1\n", encoding="utf-8")
        executable = root / "Makefile"
        executable.write_text("fixture:\n\t@true\n", encoding="utf-8")
        executable.chmod(0o755)
        (root / "source").symlink_to("include/autoconf.h")
        manifest = Path(temporary) / "identity.tsv"
        capture(root, manifest)
        verify(root, manifest)
        print("PASS known-good: complete root identity verifies")

        regular.write_text("#define CONFIG_FIXTURE 2\n", encoding="utf-8")
        expect_failure(lambda: verify(root, manifest), "changed regular file")
        regular.write_text("#define CONFIG_FIXTURE 1\n", encoding="utf-8")
        executable.chmod(0o644)
        expect_failure(lambda: verify(root, manifest), "changed executable mode")
        executable.chmod(0o755)
        (root / "source").unlink()
        (root / "source").symlink_to("Makefile")
        expect_failure(lambda: verify(root, manifest), "retargeted symlink")
        (root / "source").unlink()
        (root / "source").symlink_to("include/autoconf.h")
        (root / "injected").write_text("unexpected\n", encoding="utf-8")
        expect_failure(lambda: verify(root, manifest), "injected path")
        (root / "injected").unlink()
        regular.unlink()
        expect_failure(lambda: verify(root, manifest), "missing path")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--write", type=Path)
    parser.add_argument("--verify", type=Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.self_test:
            if any((arguments.root, arguments.write, arguments.verify)):
                raise IdentityError("--self-test accepts no root or manifest arguments")
            run_self_test()
        else:
            if arguments.root is None or (arguments.write is None) == (arguments.verify is None):
                raise IdentityError("supply --root with exactly one of --write or --verify")
            if arguments.write is not None:
                capture(arguments.root, arguments.write)
                print(f"shared build-root identity captured: {arguments.write}")
            else:
                assert arguments.verify is not None
                verify(arguments.root, arguments.verify)
                print(f"shared build-root identity verified: {arguments.root}")
    except (IdentityError, OSError, UnicodeError) as error:
        print(f"shared build-root identity: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
