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
    "repository_tree",
    "driver_subtree",
    "driver_tree",
    "archive_entry_count",
    "feature_policy_path",
    "feature_policy_sha256",
    "feature_policy_tree",
    "upstream_base_path",
    "upstream_commit",
    "upstream_subtree",
    "profiled_source_tag",
    "profiled_source_tag_object",
    "profiled_source_commit",
    "equivalence_tag",
    "equivalence_tag_object",
    "equivalence_commit",
    "migration_input_commit",
    "migration_manifest",
    "migration_manifest_sha256",
    "generated_output_proof_sha256",
    "equivalence_workflow_run",
    "profile_workflow_run",
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
    if identity["schema"] != 2:
        raise PinError("source identity schema must be 2")
    if identity["constructor"] != "profiled-source":
        raise PinError("constructor must be profiled-source")
    for key in (
        "source_commit",
        "repository_tree",
        "driver_tree",
        "feature_policy_tree",
        "upstream_commit",
        "upstream_subtree",
        "profiled_source_tag_object",
        "profiled_source_commit",
        "equivalence_tag_object",
        "equivalence_commit",
        "migration_input_commit",
    ):
        value = identity[key]
        if not isinstance(value, str) or not SHA40.fullmatch(value):
            raise PinError(f"{key} must be a lowercase 40-character object ID")
    for key in (
        "feature_policy_sha256",
        "migration_manifest_sha256",
        "generated_output_proof_sha256",
    ):
        value = identity[key]
        if not isinstance(value, str) or not SHA256.fullmatch(value):
            raise PinError(f"{key} must be a lowercase SHA-256 digest")
    if not isinstance(identity["archive_entry_count"], int):
        raise PinError("archive_entry_count must be an integer")
    for key in ("equivalence_workflow_run", "profile_workflow_run"):
        if not isinstance(identity[key], int) or identity[key] < 1:
            raise PinError(f"{key} must be a positive integer")
    return identity


def require_pkgbuild_match(pkgbuild: Path, identity: dict[str, object]) -> None:
    try:
        text = pkgbuild.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise PinError(f"cannot read PKGBUILD: {error}") from error
    bindings = {
        "_source_repository": "source_repository",
        "_source_commit": "source_commit",
        "_source_repository_tree": "repository_tree",
        "_source_driver_tree": "driver_tree",
        "_source_feature_policy_tree": "feature_policy_tree",
        "_source_feature_policy_sha256": "feature_policy_sha256",
        "_source_upstream_base": "upstream_commit",
        "_profiled_source_tag": "profiled_source_tag",
        "_profiled_source_tag_object": "profiled_source_tag_object",
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
    repository_tree = str(identity["repository_tree"])
    tag = str(identity["equivalence_tag"])
    tag_object = str(identity["equivalence_tag_object"])
    equivalence_commit = str(identity["equivalence_commit"])
    subtree = str(identity["driver_subtree"])

    if git(repository, "cat-file", "-t", commit) != "commit":
        raise PinError("source_commit is not a commit object")
    if git(repository, "rev-parse", f"{commit}^{{tree}}") != repository_tree:
        raise PinError("source repository tree does not match repository_tree")
    if git(repository, "cat-file", "-t", tag_object) != "tag":
        raise PinError("equivalence_tag_object is not an annotated tag object")
    profiled_tag = str(identity["profiled_source_tag"])
    profiled_tag_object = str(identity["profiled_source_tag_object"])
    if str(identity["profiled_source_commit"]) != commit:
        raise PinError("profiled_source_commit disagrees with source_commit")
    if git(repository, "cat-file", "-t", profiled_tag_object) != "tag":
        raise PinError("profiled_source_tag_object is not an annotated tag object")
    if git(repository, "rev-parse", f"refs/tags/{profiled_tag}^{{tag}}") != profiled_tag_object:
        raise PinError("profiled source tag object does not match the named tag")
    if git(repository, "rev-parse", f"refs/tags/{profiled_tag}^{{}}") != commit:
        raise PinError("profiled source tag does not peel to source_commit")
    if git(repository, "rev-parse", f"refs/tags/{tag}^{{tag}}") != tag_object:
        raise PinError("equivalence tag object does not match the named tag")
    if git(repository, "rev-parse", f"refs/tags/{tag}^{{}}") != equivalence_commit:
        raise PinError("equivalence tag does not peel to equivalence_commit")
    try:
        git(repository, "merge-base", "--is-ancestor", equivalence_commit, commit)
    except PinError as error:
        raise PinError("source_commit does not descend from equivalence_commit") from error
    if git(repository, "rev-parse", f"{commit}:{subtree}") != identity["driver_tree"]:
        raise PinError("driver subtree does not match driver_tree")
    if (
        git(repository, "rev-parse", f"{commit}:policy")
        != identity["feature_policy_tree"]
    ):
        raise PinError("policy subtree does not match feature_policy_tree")
    feature_policy_path = str(identity["feature_policy_path"])
    if (
        digest_blob(repository, f"{commit}:{feature_policy_path}")
        != identity["feature_policy_sha256"]
    ):
        raise PinError("feature policy digest does not match the pinned source")

    try:
        upstream = tomllib.loads(
            read_blob(
                repository, f"{commit}:{identity['upstream_base_path']}"
            ).decode("ascii")
        )
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise PinError(f"pinned upstream declaration is invalid: {error}") from error
    if upstream.get("commit") != identity["upstream_commit"]:
        raise PinError("upstream commit disagrees with the source identity")
    if upstream.get("subtree_tree") != identity["upstream_subtree"]:
        raise PinError("upstream subtree disagrees with the source identity")

    entries = git(repository, "ls-tree", "-r", "--name-only", commit, subtree)
    entry_count = len(entries.splitlines()) if entries else 0
    if entry_count != identity["archive_entry_count"]:
        raise PinError(
            f"driver archive has {entry_count} entries, "
            f"expected {identity['archive_entry_count']}"
        )

    manifest_path = str(identity["migration_manifest"])
    manifest_digest = digest_blob(
        repository, f"{equivalence_commit}:{manifest_path}"
    )
    if manifest_digest != identity["migration_manifest_sha256"]:
        raise PinError("migration manifest digest does not match the pinned source")
    try:
        migration_input = tomllib.loads(
            read_blob(
                repository, f"{equivalence_commit}:MIGRATION_INPUT.toml"
            ).decode("ascii")
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
    verify_migration_manifest(
        repository, equivalence_commit, subtree, manifest_path
    )
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
        policy = repository / "policy"
        manifest = repository / "migration/expected-prefixes/mechanism"
        driver.mkdir(parents=True)
        policy.mkdir()
        manifest.mkdir(parents=True)
        driver_text = "obj-m += radeon.o\n"
        (driver / "Makefile").write_text(driver_text, encoding="ascii")
        (driver / ".gitignore").write_text("*.o\n", encoding="ascii")
        feature_policy_text = 'schema = 1\nprofile = "prod"\n'
        (policy / "build-features.toml").write_text(
            feature_policy_text, encoding="ascii"
        )
        upstream_commit = "1" * 40
        upstream_subtree = "2" * 40
        (repository / "UPSTREAM_BASE.toml").write_text(
            "\n".join(
                [
                    "schema = 1",
                    f'commit = "{upstream_commit}"',
                    f'subtree_tree = "{upstream_subtree}"',
                    "",
                ]
            ),
            encoding="ascii",
        )
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
        manifest_digest = hashlib.sha256(manifest_text.encode("ascii")).hexdigest()
        packaging_commit = "3" * 40
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
            ["git", "-C", str(repository), "commit", "-qm", "equivalence"],
            check=True,
        )
        equivalence_commit = git(repository, "rev-parse", "HEAD")
        subprocess.run(
            ["git", "-C", str(repository), "tag", "-am", "fixture", "fixture-tag"],
            check=True,
        )
        tag_object = git(repository, "rev-parse", "fixture-tag^{tag}")
        (repository / "profile-ready").write_text("yes\n", encoding="ascii")
        subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "commit", "-qm", "profile source"],
            check=True,
        )
        commit = git(repository, "rev-parse", "HEAD")
        subprocess.run(
            [
                "git", "-C", str(repository),
                "tag", "-am", "profiled fixture", "profiled-fixture-tag",
            ],
            check=True,
        )
        profiled_tag_object = git(
            repository, "rev-parse", "profiled-fixture-tag^{tag}"
        )
        repository_tree = git(repository, "rev-parse", "HEAD^{tree}")
        tree = git(repository, "rev-parse", "HEAD:drivers/gpu/drm/radeon")
        policy_tree = git(repository, "rev-parse", "HEAD:policy")
        feature_policy_digest = hashlib.sha256(
            feature_policy_text.encode("ascii")
        ).hexdigest()
        identity_path = repository / "identity.toml"
        identity_path.write_text(
            "\n".join(
                [
                    "schema = 2",
                    'constructor = "profiled-source"',
                    'source_repository = "fixture/source"',
                    f'source_commit = "{commit}"',
                    f'repository_tree = "{repository_tree}"',
                    'driver_subtree = "drivers/gpu/drm/radeon"',
                    f'driver_tree = "{tree}"',
                    "archive_entry_count = 2",
                    'feature_policy_path = "policy/build-features.toml"',
                    f'feature_policy_sha256 = "{feature_policy_digest}"',
                    f'feature_policy_tree = "{policy_tree}"',
                    'upstream_base_path = "UPSTREAM_BASE.toml"',
                    f'upstream_commit = "{upstream_commit}"',
                    f'upstream_subtree = "{upstream_subtree}"',
                    'profiled_source_tag = "profiled-fixture-tag"',
                    f'profiled_source_tag_object = "{profiled_tag_object}"',
                    f'profiled_source_commit = "{commit}"',
                    'equivalence_tag = "fixture-tag"',
                    f'equivalence_tag_object = "{tag_object}"',
                    f'equivalence_commit = "{equivalence_commit}"',
                    f'migration_input_commit = "{packaging_commit}"',
                    'migration_manifest = '
                    '"migration/expected-prefixes/mechanism/M24.manifest.tsv"',
                    f'migration_manifest_sha256 = "{manifest_digest}"',
                    "generated_output_proof_sha256 = "
                    f'"{"0" * 64}"',
                    "equivalence_workflow_run = 1",
                    "profile_workflow_run = 2",
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
        bad_text = identity_path.read_text(encoding="ascii").replace(
            f'profiled_source_tag_object = "{profiled_tag_object}"',
            f'profiled_source_tag_object = "{tag_object}"',
        )
        bad_path.write_text(bad_text, encoding="ascii")
        try:
            verify(bad_path, repository)
        except PinError:
            pass
        else:
            raise PinError("self-test accepts a wrong profiled source tag object")
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
