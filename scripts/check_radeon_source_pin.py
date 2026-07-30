#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Verify the Radeon packaging pin against a source repository."""

from __future__ import annotations

import argparse
import hashlib
import io
import re
import subprocess
import sys
import tarfile
import tempfile
import tomllib
from pathlib import Path

SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_KEYS = {
    "schema",
    "constructor",
    "source_repository",
    "source_commit",
    "source_tag",
    "source_tag_object",
    "driver_subtree",
    "driver_tree",
    "archive_entry_count",
    "migration_input_commit",
    "migration_manifest",
    "migration_manifest_sha256",
    "generated_output_proof_sha256",
    "equivalence_workflow_run",
}


class PinError(Exception):
    """The source identity or repository state violates the pin."""


def git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise PinError(f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout.strip()


def digest_blob(repository: Path, revision_path: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), "show", revision_path],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise PinError(f"git show {revision_path} failed: {detail}")
    return hashlib.sha256(result.stdout).hexdigest()


def read_blob(repository: Path, revision_path: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repository), "show", revision_path],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise PinError(f"git show {revision_path} failed: {detail}")
    return result.stdout


def verify_migration_manifest(
    repository: Path,
    commit: str,
    subtree: str,
    manifest_path: str,
) -> None:
    raw_manifest = read_blob(repository, f"{commit}:{manifest_path}")
    try:
        lines = raw_manifest.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise PinError("migration manifest is not ASCII") from error
    if lines[:2] != [
        "# manifest-schema: gororoba-source-tree-v1",
        "path\tmode\tsize\tsha256",
    ]:
        raise PinError("migration manifest has an invalid header")
    expected: dict[str, tuple[str, int, str]] = {}
    for line in lines[2:]:
        fields = line.split("\t")
        if len(fields) != 4:
            raise PinError(f"malformed migration manifest row: {line}")
        path, mode, size_text, digest = fields
        if path in expected:
            raise PinError(f"duplicate migration manifest path: {path}")
        if not size_text.isdecimal() or not SHA256.fullmatch(digest):
            raise PinError(f"malformed migration manifest metadata: {path}")
        expected[path] = (mode, int(size_text), digest)

    result = subprocess.run(
        ["git", "-C", str(repository), "archive", f"{commit}:{subtree}"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise PinError(f"git archive failed: {detail}")
    actual: dict[str, tuple[str, int, str]] = {}
    with tarfile.open(fileobj=io.BytesIO(result.stdout), mode="r:") as archive:
        for member in archive.getmembers():
            if member.isdir():
                continue
            if not member.isfile():
                raise PinError(f"driver archive contains a non-file entry: {member.name}")
            stream = archive.extractfile(member)
            if stream is None:
                raise PinError(f"cannot read driver archive entry: {member.name}")
            content = stream.read()
            mode = "100755" if member.mode & 0o111 else "100644"
            actual[member.name] = (
                mode,
                len(content),
                hashlib.sha256(content).hexdigest(),
            )
    repository_only = actual.pop(".gitignore", None)
    if repository_only is None:
        raise PinError("driver archive omits its tracked .gitignore")
    if actual != expected:
        missing = sorted(expected.keys() - actual.keys())
        extra = sorted(actual.keys() - expected.keys())
        changed = sorted(
            path
            for path in expected.keys() & actual.keys()
            if expected[path] != actual[path]
        )
        raise PinError(
            "migration manifest does not describe the archived driver inputs: "
            f"missing={missing}, extra={extra}, changed={changed}"
        )


def load_identity(path: Path) -> dict[str, object]:
    try:
        identity = tomllib.loads(path.read_text(encoding="ascii"))
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as error:
        raise PinError(f"cannot read source identity: {error}") from error
    missing = REQUIRED_KEYS - identity.keys()
    unknown = identity.keys() - REQUIRED_KEYS
    if missing:
        raise PinError(f"source identity omits: {', '.join(sorted(missing))}")
    if unknown:
        raise PinError(f"source identity has unknown keys: {', '.join(sorted(unknown))}")
    if identity["schema"] != 1:
        raise PinError("source identity schema must be 1")
    if identity["constructor"] != "legacy-equivalent":
        raise PinError("constructor must be legacy-equivalent")
    for key in (
        "source_commit",
        "source_tag_object",
        "driver_tree",
        "migration_input_commit",
    ):
        value = identity[key]
        if not isinstance(value, str) or not SHA40.fullmatch(value):
            raise PinError(f"{key} must be a lowercase 40-character object ID")
    for key in ("migration_manifest_sha256", "generated_output_proof_sha256"):
        value = identity[key]
        if not isinstance(value, str) or not SHA256.fullmatch(value):
            raise PinError(f"{key} must be a lowercase SHA-256 digest")
    if not isinstance(identity["archive_entry_count"], int):
        raise PinError("archive_entry_count must be an integer")
    if not isinstance(identity["equivalence_workflow_run"], int):
        raise PinError("equivalence_workflow_run must be an integer")
    return identity


def require_pkgbuild_match(pkgbuild: Path, identity: dict[str, object]) -> None:
    try:
        text = pkgbuild.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise PinError(f"cannot read PKGBUILD: {error}") from error
    bindings = {
        "_source_repository": "source_repository",
        "_source_commit": "source_commit",
        "_source_tag": "source_tag",
        "_source_tag_object": "source_tag_object",
        "_source_driver_tree": "driver_tree",
    }
    for shell_name, identity_name in bindings.items():
        pattern = rf"^{re.escape(shell_name)}='([^']+)'$"
        match = re.search(pattern, text, re.MULTILINE)
        if match is None:
            raise PinError(f"PKGBUILD omits literal {shell_name}")
        if match.group(1) != identity[identity_name]:
            raise PinError(f"PKGBUILD {shell_name} disagrees with source identity")
    forbidden = ("PATCH[", "patch -p", "git apply", "radeon-unified-canonical-source")
    for token in forbidden:
        if token in text:
            raise PinError(f"PKGBUILD active constructor contains {token}")


def verify(
    identity_path: Path,
    repository: Path,
    pkgbuild: Path | None = None,
) -> dict[str, object]:
    identity = load_identity(identity_path)
    if pkgbuild is not None:
        require_pkgbuild_match(pkgbuild, identity)

    commit = str(identity["source_commit"])
    tag = str(identity["source_tag"])
    tag_object = str(identity["source_tag_object"])
    subtree = str(identity["driver_subtree"])

    if git(repository, "cat-file", "-t", commit) != "commit":
        raise PinError("source_commit is not a commit object")
    if git(repository, "cat-file", "-t", tag_object) != "tag":
        raise PinError("source_tag_object is not an annotated tag object")
    if git(repository, "rev-parse", f"refs/tags/{tag}^{{tag}}") != tag_object:
        raise PinError("source tag object does not match the named tag")
    if git(repository, "rev-parse", f"refs/tags/{tag}^{{}}") != commit:
        raise PinError("source tag does not peel to source_commit")
    if git(repository, "rev-parse", f"{commit}:{subtree}") != identity["driver_tree"]:
        raise PinError("driver subtree does not match driver_tree")

    entries = git(repository, "ls-tree", "-r", "--name-only", commit, subtree)
    entry_count = len(entries.splitlines()) if entries else 0
    if entry_count != identity["archive_entry_count"]:
        raise PinError(
            f"driver archive has {entry_count} entries, "
            f"expected {identity['archive_entry_count']}"
        )

    manifest_path = str(identity["migration_manifest"])
    manifest_digest = digest_blob(repository, f"{commit}:{manifest_path}")
    if manifest_digest != identity["migration_manifest_sha256"]:
        raise PinError("migration manifest digest does not match the pinned source")
    try:
        migration_input = tomllib.loads(
            read_blob(repository, f"{commit}:MIGRATION_INPUT.toml").decode("ascii")
        )
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise PinError(f"pinned MIGRATION_INPUT.toml is invalid: {error}") from error
    input_bindings = {
        "packaging_commit": "migration_input_commit",
        "migration_manifest_sha256": "migration_manifest_sha256",
        "generated_output_proof_sha256": "generated_output_proof_sha256",
    }
    for input_name, identity_name in input_bindings.items():
        if migration_input.get(input_name) != identity[identity_name]:
            raise PinError(
                f"MIGRATION_INPUT.toml {input_name} disagrees with source identity"
            )
    verify_migration_manifest(repository, commit, subtree, manifest_path)
    return identity


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-source-pin.") as temporary:
        repository = Path(temporary)
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "config", "user.name", "Pin Test"],
            check=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(repository),
                "config",
                "user.email",
                "pin-test@example.invalid",
            ],
            check=True,
        )
        driver = repository / "drivers/gpu/drm/radeon"
        manifest = repository / "migration/expected-prefixes/mechanism"
        driver.mkdir(parents=True)
        manifest.mkdir(parents=True)
        driver_text = "obj-m += radeon.o\n"
        (driver / "Makefile").write_text(driver_text, encoding="ascii")
        (driver / ".gitignore").write_text("*.o\n", encoding="ascii")
        manifest_path = manifest / "M24.manifest.tsv"
        driver_digest = hashlib.sha256(driver_text.encode("ascii")).hexdigest()
        manifest_text = "\n".join(
            [
                "# manifest-schema: gororoba-source-tree-v1",
                "path\tmode\tsize\tsha256",
                f"Makefile\t100644\t{len(driver_text)}\t{driver_digest}",
                "",
            ]
        )
        manifest_path.write_text(manifest_text, encoding="ascii")
        subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "commit", "-qm", "fixture"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(repository), "tag", "-am", "fixture", "fixture-tag"],
            check=True,
        )
        commit = git(repository, "rev-parse", "HEAD")
        packaging_commit = commit
        tag_object = git(repository, "rev-parse", "fixture-tag^{tag}")
        tree = git(repository, "rev-parse", "HEAD:drivers/gpu/drm/radeon")
        manifest_digest = hashlib.sha256(manifest_text.encode("ascii")).hexdigest()
        (repository / "MIGRATION_INPUT.toml").write_text(
            "\n".join(
                [
                    f'packaging_commit = "{packaging_commit}"',
                    f'migration_manifest_sha256 = "{manifest_digest}"',
                    f'generated_output_proof_sha256 = "{"0" * 64}"',
                    "",
                ]
            ),
            encoding="ascii",
        )
        subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "commit", "-qm", "migration input"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(repository), "tag", "-d", "fixture-tag"],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            ["git", "-C", str(repository), "tag", "-am", "fixture", "fixture-tag"],
            check=True,
        )
        commit = git(repository, "rev-parse", "HEAD")
        tag_object = git(repository, "rev-parse", "fixture-tag^{tag}")
        tree = git(repository, "rev-parse", "HEAD:drivers/gpu/drm/radeon")
        identity_path = repository / "identity.toml"
        identity_path.write_text(
            "\n".join(
                [
                    "schema = 1",
                    'constructor = "legacy-equivalent"',
                    'source_repository = "fixture/source"',
                    f'source_commit = "{commit}"',
                    'source_tag = "fixture-tag"',
                    f'source_tag_object = "{tag_object}"',
                    'driver_subtree = "drivers/gpu/drm/radeon"',
                    f'driver_tree = "{tree}"',
                    "archive_entry_count = 2",
                    f'migration_input_commit = "{packaging_commit}"',
                    'migration_manifest = '
                    '"migration/expected-prefixes/mechanism/M24.manifest.tsv"',
                    f'migration_manifest_sha256 = "{manifest_digest}"',
                    "generated_output_proof_sha256 = "
                    f'"{"0" * 64}"',
                    "equivalence_workflow_run = 1",
                    "",
                ]
            ),
            encoding="ascii",
        )
        verify(identity_path, repository)
        bad_text = identity_path.read_text(encoding="ascii").replace(
            f'driver_tree = "{tree}"',
            f'driver_tree = "{"0" * 40}"',
        )
        bad_path = repository / "bad.toml"
        bad_path.write_text(bad_text, encoding="ascii")
        try:
            verify(bad_path, repository)
        except PinError:
            pass
        else:
            raise PinError("self-test accepts a wrong driver tree")
    print("radeon source pin calibration: PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--identity", type=Path)
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--pkgbuild", type=Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    try:
        if arguments.self_test:
            run_self_test()
            return 0
        if arguments.identity is None or arguments.repository is None:
            parser.error("--identity and --repository are required")
        identity = verify(
            arguments.identity,
            arguments.repository,
            arguments.pkgbuild,
        )
    except PinError as error:
        print(f"check_radeon_source_pin: {error}", file=sys.stderr)
        return 1
    print(
        "radeon source pin: PASS "
        f"({identity['source_commit']}, {identity['driver_tree']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
