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
from urllib.parse import urlsplit

SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SSH_SIGNATURE_OPEN = "-----BEGIN SSH SIGNATURE-----"
SSH_SIGNATURE_CLOSE = "-----END SSH SIGNATURE-----"
DEFAULT_ALLOWED_SIGNERS = "radeon-source-tag-allowed-signers"
LEGACY_REQUIRED_KEYS = {"schema", "repository", "commit", "path", "sha256"}
REPOSITORY_ID = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
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
    "equivalence_driver_tree",
    "equivalence_workflow_retrievable",
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


def require_signature_block(repository: Path, tag_object: str, field: str) -> None:
    """Require the tag object body to carry an inline SSH signature block.

    This is a structural property read from the object's own bytes, so it
    reports a missing signature as absent bytes rather than as an
    unverifiable one. It states nothing about who signed.
    """
    body = git(repository, "cat-file", "-p", tag_object)
    if SSH_SIGNATURE_OPEN not in body or SSH_SIGNATURE_CLOSE not in body:
        raise PinError(f"{field} names a tag object carrying no SSH signature")


def verify_tag_signature(repository: Path, tag: str, allowed_signers: Path) -> None:
    """Require the tag signature to verify against the release signer.

    A signature block is bytes; git verify-tag against a fixed allowed-signers
    file is the cryptographic statement. The allowed-signers path is passed as
    an explicit -c override so the result depends on the package-owned
    allowlist rather than on whatever gpg.ssh.allowedSignersFile the
    workstation happens to set, and a tag signed by any key outside that file
    fails even though its body carries a syntactically valid block.
    """
    if not allowed_signers.is_file():
        raise PinError(f"allowed-signers file is missing: {allowed_signers}")
    # git -C runs in the source repository, so a relative allowlist path would
    # resolve there and ssh-keygen would report an unmatched principal for a
    # file that is simply absent.
    allowed_signers = allowed_signers.resolve()
    result = subprocess.run(
        [
            "git", "-C", str(repository),
            "-c", "gpg.format=ssh",
            "-c", f"gpg.ssh.allowedSignersFile={allowed_signers}",
            "verify-tag", tag,
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr.strip() or result.stdout.strip()).splitlines()
        raise PinError(
            f"{tag} does not verify against {allowed_signers.name}: "
            f"{detail[-1] if detail else 'no detail'}"
        )
    # git reports the principal it matched, and the pin binds to that principal
    # rather than to any entry the allowlist happens to carry.
    principals = [
        line.split(" for ", 1)[1].split(" with ", 1)[0].strip('"')
        for line in result.stderr.splitlines()
        if line.startswith("Good ") and " for " in line and " with " in line
    ]
    if not principals:
        raise PinError(f"{tag} verification reported no signing principal")
    expected = allowed_signers.read_text(encoding="utf-8").splitlines()
    allowed = {
        line.split()[0] for line in expected if line and not line.startswith("#")
    }
    if not set(principals) & allowed:
        raise PinError(
            f"{tag} verified as {principals[0]}, which {allowed_signers.name} "
            "does not name"
        )


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


def load_legacy_identity(path: Path) -> dict[str, object]:
    if not path.is_file() or path.is_symlink():
        raise PinError("legacy identity is not a regular file")
    try:
        identity = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as error:
        raise PinError(f"cannot read legacy identity: {error}") from error
    keys = set(identity)
    missing = LEGACY_REQUIRED_KEYS - keys
    unknown = keys - LEGACY_REQUIRED_KEYS
    if missing:
        raise PinError(
            f"legacy identity omits: {', '.join(sorted(missing))}"
        )
    if unknown:
        raise PinError(
            f"legacy identity has unknown keys: {', '.join(sorted(unknown))}"
        )
    if type(identity["schema"]) is not int or identity["schema"] != 1:
        raise PinError("legacy identity schema must be 1")
    repository = identity["repository"]
    if not isinstance(repository, str) or not REPOSITORY_ID.fullmatch(repository):
        raise PinError("legacy identity repository must be owner/repository")
    commit = identity["commit"]
    if not isinstance(commit, str) or not SHA40.fullmatch(commit):
        raise PinError("legacy identity commit must be lowercase 40-hex")
    path_value = identity["path"]
    if not isinstance(path_value, str) or not path_value:
        raise PinError("legacy identity path must be a non-empty string")
    if (
        path_value.startswith("/")
        or "\\" in path_value
        or "\x00" in path_value
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in path_value)
    ):
        raise PinError("legacy identity path must be repository-relative")
    components = path_value.split("/")
    if any(not component or component in {".", ".."} for component in components):
        raise PinError("legacy identity path contains an unsafe component")
    digest = identity["sha256"]
    if not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise PinError("legacy identity sha256 must be lowercase 64-hex")
    return identity


def github_repository_identity(repository: Path) -> str:
    remote = git(repository, "config", "--get", "remote.origin.url")
    if remote.startswith("git@github.com:"):
        identity = remote.removeprefix("git@github.com:")
    else:
        parsed = urlsplit(remote)
        if parsed.hostname != "github.com":
            raise PinError("legacy repository origin uses a non-GitHub provider")
        identity = parsed.path.lstrip("/")
    identity = identity.removesuffix(".git").strip("/")
    if not REPOSITORY_ID.fullmatch(identity):
        raise PinError("legacy repository origin is not owner/repository")
    return identity


def verify_legacy_identity(
    identity_path: Path,
    repository: Path,
    checked_in_copy: Path,
) -> None:
    identity = load_legacy_identity(identity_path)
    expected_repository = str(identity["repository"])
    if github_repository_identity(repository) != expected_repository:
        raise PinError("legacy identity repository disagrees with origin")

    commit = str(identity["commit"])
    path = str(identity["path"])
    revision_path = f"{commit}:{path}"
    if git(repository, "cat-file", "-t", commit) != "commit":
        raise PinError("legacy identity commit is not a commit object")
    if git(repository, "cat-file", "-t", revision_path) != "blob":
        raise PinError("legacy identity path does not name a blob")

    if not checked_in_copy.is_file() or checked_in_copy.is_symlink():
        raise PinError("legacy identity checked-in copy is not a regular file")
    try:
        copy_bytes = checked_in_copy.read_bytes()
    except OSError as error:
        raise PinError(f"cannot read legacy identity checked-in copy: {error}") from error
    blob_bytes = read_blob(repository, revision_path)
    expected_digest = str(identity["sha256"])
    copy_digest = hashlib.sha256(copy_bytes).hexdigest()
    blob_digest = hashlib.sha256(blob_bytes).hexdigest()
    if copy_digest != expected_digest:
        raise PinError("legacy identity digest does not match the checked-in copy")
    if blob_digest != expected_digest:
        raise PinError("legacy identity digest does not match the Git blob")
    if copy_bytes != blob_bytes:
        raise PinError("legacy identity checked-in copy differs from the Git blob")


def verify_migration_manifest(
    repository: Path,
    commit: str,
    subtree: str,
    manifest_path: str,
) -> None:
    raw_manifest = read_blob(repository, f"{commit}:{manifest_path}")
    try:
        lines = raw_manifest.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise PinError("migration manifest is not UTF-8 text") from error
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
        identity = tomllib.loads(path.read_text(encoding="utf-8"))
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
        "equivalence_driver_tree",
        "migration_input_commit",
    ):
        value = identity[key]
        if not isinstance(value, str) or not SHA40.fullmatch(value):
            raise PinError(f"{key} must be a lowercase 40-character object ID")
    if not isinstance(identity["equivalence_workflow_retrievable"], bool):
        raise PinError("equivalence_workflow_retrievable must be a boolean")
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
        text = pkgbuild.read_text(encoding="utf-8")
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
    allowed_signers: Path | None = None,
    legacy_identity: Path | None = None,
    legacy_repository: Path | None = None,
    legacy_copy: Path | None = None,
) -> dict[str, object]:
    legacy_arguments = (legacy_identity, legacy_repository, legacy_copy)
    if any(argument is not None for argument in legacy_arguments) and not all(
        argument is not None for argument in legacy_arguments
    ):
        raise PinError(
            "legacy identity mode requires --legacy-identity, "
            "--legacy-repository, and --legacy-copy"
        )
    # The allowlist sits beside the identity it vouches for, so a pin verified
    # from a checkout of this package uses that checkout's release signers.
    if allowed_signers is None:
        allowed_signers = identity_path.parent / DEFAULT_ALLOWED_SIGNERS
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
    require_signature_block(repository, profiled_tag_object, "profiled_source_tag_object")
    verify_tag_signature(repository, profiled_tag, allowed_signers)
    if git(repository, "rev-parse", f"refs/tags/{tag}^{{tag}}") != tag_object:
        raise PinError("equivalence tag object does not match the named tag")
    if git(repository, "rev-parse", f"refs/tags/{tag}^{{}}") != equivalence_commit:
        raise PinError("equivalence tag does not peel to equivalence_commit")
    # The workflow run that proved equivalence expires from the forge while the
    # objects it proved stay reachable, so the driver tree carries the claim
    # and the run number stays explanatory.
    if (
        git(repository, "rev-parse", f"{equivalence_commit}:{subtree}")
        != identity["equivalence_driver_tree"]
    ):
        raise PinError("equivalence driver subtree does not match equivalence_driver_tree")
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
            ).decode("utf-8")
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
            ).decode("utf-8")
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
    if legacy_identity is not None:
        if legacy_repository is None or legacy_copy is None:
            raise PinError("legacy identity mode is incomplete")
        verify_legacy_identity(legacy_identity, legacy_repository, legacy_copy)
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
        git(
            repository,
            "config",
            "remote.origin.url",
            "git@github.com:fixture-owner/fixture-repository.git",
        )
        driver = repository / "drivers/gpu/drm/radeon"
        policy = repository / "policy"
        manifest = repository / "migration/expected-prefixes/mechanism"
        legacy_copy = repository / "migration/input/legacy-dkms-patch-order.conf"
        legacy_blob = repository / "packaging/arch/radeon-unified-dkms/dkms.conf"
        driver.mkdir(parents=True)
        policy.mkdir()
        manifest.mkdir(parents=True)
        legacy_copy.parent.mkdir(parents=True)
        legacy_blob.parent.mkdir(parents=True)
        legacy_text = 'PACKAGE_NAME="fixture"\n'
        legacy_copy.write_text(legacy_text, encoding="utf-8")
        legacy_blob.write_text(legacy_text, encoding="utf-8")
        driver_text = "obj-m += radeon.o\n"
        (driver / "Makefile").write_text(driver_text, encoding="utf-8")
        (driver / ".gitignore").write_text("*.o\n", encoding="utf-8")
        feature_policy_text = 'schema = 1\nprofile = "prod"\n'
        (policy / "build-features.toml").write_text(
            feature_policy_text, encoding="utf-8"
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
            encoding="utf-8",
        )
        manifest_path = manifest / "M24.manifest.tsv"
        driver_digest = hashlib.sha256(driver_text.encode("utf-8")).hexdigest()
        manifest_text = "\n".join(
            [
                "# manifest-schema: gororoba-source-tree-v1",
                "path\tmode\tsize\tsha256",
                f"Makefile\t100644\t{len(driver_text)}\t{driver_digest}",
                "",
            ]
        )
        manifest_path.write_text(manifest_text, encoding="utf-8")
        manifest_digest = hashlib.sha256(manifest_text.encode("utf-8")).hexdigest()
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
            encoding="utf-8",
        )
        subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "commit", "-qm", "equivalence"],
            check=True,
        )
        equivalence_commit = git(repository, "rev-parse", "HEAD")
        equivalence_driver_tree = git(
            repository, "rev-parse", "HEAD:drivers/gpu/drm/radeon"
        )
        subprocess.run(
            ["git", "-C", str(repository), "tag", "-am", "fixture", "fixture-tag"],
            check=True,
        )
        tag_object = git(repository, "rev-parse", "fixture-tag^{tag}")
        (repository / "profile-ready").write_text("yes\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "commit", "-qm", "profile source"],
            check=True,
        )
        commit = git(repository, "rev-parse", "HEAD")
        legacy_identity_path = repository / "legacy-dkms-patch-order.toml"
        legacy_blob_path = "packaging/arch/radeon-unified-dkms/dkms.conf"
        legacy_digest = hashlib.sha256(legacy_text.encode("utf-8")).hexdigest()
        legacy_identity_path.write_text(
            "\n".join(
                [
                    "schema = 1",
                    'repository = "fixture-owner/fixture-repository"',
                    f'commit = "{equivalence_commit}"',
                    f'path = "{legacy_blob_path}"',
                    f'sha256 = "{legacy_digest}"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        # The signature assertion needs a signed known-good tag, and an
        # ephemeral key supplies one without the release key: git records the
        # signature in the tag object either way, so the fixture exercises the
        # same bytes the checker reads.
        signing_key = repository / "fixture-signing-key"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
             "pin fixture", "-f", str(signing_key)],
            check=True,
        )
        subprocess.run(
            [
                "git", "-C", str(repository),
                "-c", "gpg.format=ssh",
                "-c", f"user.signingkey={signing_key}.pub",
                "tag", "-sm", "profiled fixture", "profiled-fixture-tag",
            ],
            check=True,
        )
        profiled_tag_object = git(
            repository, "rev-parse", "profiled-fixture-tag^{tag}"
        )
        # The unsigned twin names the same commit, so a pin naming it fails on
        # the missing signature alone rather than on tag identity or peel.
        subprocess.run(
            [
                "git", "-C", str(repository),
                "tag", "-am", "unsigned twin", "unsigned-profiled-fixture-tag",
            ],
            check=True,
        )
        unsigned_tag_object = git(
            repository, "rev-parse", "unsigned-profiled-fixture-tag^{tag}"
        )
        # A second ephemeral key produces a tag whose body carries a valid
        # signature block over the right commit, so it separates the structural
        # property from the signer-identity property: only the allowlist
        # distinguishes the two tags.
        untrusted_key = repository / "fixture-untrusted-key"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
             "pin fixture untrusted", "-f", str(untrusted_key)],
            check=True,
        )
        subprocess.run(
            [
                "git", "-C", str(repository),
                "-c", "gpg.format=ssh",
                "-c", f"user.signingkey={untrusted_key}.pub",
                "tag", "-sm", "untrusted signer", "untrusted-profiled-fixture-tag",
            ],
            check=True,
        )
        untrusted_tag_object = git(
            repository, "rev-parse", "untrusted-profiled-fixture-tag^{tag}"
        )
        # The trusted key over the equivalence commit isolates the peel
        # property: signer and signature block are both right, the commit is
        # not.
        subprocess.run(
            [
                "git", "-C", str(repository),
                "-c", "gpg.format=ssh",
                "-c", f"user.signingkey={signing_key}.pub",
                "tag", "-sm", "wrong peel", "wrong-peel-profiled-fixture-tag",
                equivalence_commit,
            ],
            check=True,
        )
        wrong_peel_tag_object = git(
            repository, "rev-parse", "wrong-peel-profiled-fixture-tag^{tag}"
        )
        # The allowlist names the trusted fixture key alone, so the untrusted
        # tag fails on signer identity rather than on signature validity.
        keytype, keydata = (
            Path(f"{signing_key}.pub").read_text(encoding="utf-8").split()[:2]
        )
        allowed_signers = repository / DEFAULT_ALLOWED_SIGNERS
        allowed_signers.write_text(
            f"fixture-signer@example.invalid {keytype} {keydata}\n",
            encoding="utf-8",
        )
        repository_tree = git(repository, "rev-parse", "HEAD^{tree}")
        tree = git(repository, "rev-parse", "HEAD:drivers/gpu/drm/radeon")
        policy_tree = git(repository, "rev-parse", "HEAD:policy")
        feature_policy_digest = hashlib.sha256(
            feature_policy_text.encode("utf-8")
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
                    "equivalence_workflow_retrievable = false",
                    f'equivalence_driver_tree = "{equivalence_driver_tree}"',
                    "profile_workflow_run = 2",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        verify_legacy_identity(legacy_identity_path, repository, legacy_copy)
        print("legacy identity known-good accepted: matching sidecar and copy")
        legacy_base_text = legacy_identity_path.read_text(encoding="utf-8")
        legacy_bad_cases = {
            "a mutated legacy identity SHA": (
                f'sha256 = "{legacy_digest}"',
                f'sha256 = "{"0" * 64}"',
            ),
            "a legacy identity with the wrong path": (
                f'path = "{legacy_blob_path}"',
                'path = "packaging/arch/radeon-unified-dkms/missing.conf"',
            ),
            "a malformed legacy repository identity": (
                'repository = "fixture-owner/fixture-repository"',
                'repository = "fixture-owner/fixture/repository"',
            ),
        }
        legacy_bad_count = 0
        bad_legacy_identity = repository / "bad-legacy-identity.toml"
        for description, (original, replacement) in legacy_bad_cases.items():
            bad_legacy_identity.write_text(
                legacy_base_text.replace(original, replacement),
                encoding="utf-8",
            )
            try:
                verify_legacy_identity(bad_legacy_identity, repository, legacy_copy)
            except PinError:
                legacy_bad_count += 1
                print(f"legacy identity known-bad rejected: {description}")
            else:
                raise PinError(f"self-test accepts {description}")
        git(
            repository,
            "config",
            "remote.origin.url",
            "https://gitlab.com/fixture-owner/fixture-repository.git",
        )
        try:
            verify_legacy_identity(legacy_identity_path, repository, legacy_copy)
        except PinError:
            legacy_bad_count += 1
            print(
                "legacy identity known-bad rejected: "
                "a non-GitHub origin provider"
            )
        else:
            raise PinError("self-test accepts a non-GitHub origin provider")
        finally:
            git(
                repository,
                "config",
                "remote.origin.url",
                "git@github.com:fixture-owner/fixture-repository.git",
            )
        legacy_symlink = repository / "legacy-identity-symlink.toml"
        legacy_symlink.symlink_to(legacy_identity_path)
        try:
            verify_legacy_identity(legacy_symlink, repository, legacy_copy)
        except PinError:
            legacy_bad_count += 1
            print("legacy identity known-bad rejected: a symlinked sidecar")
        else:
            raise PinError("self-test accepts a symlinked sidecar")
        finally:
            legacy_symlink.unlink()
        original_copy = legacy_copy.read_bytes()
        legacy_copy.write_bytes(original_copy + b"copy drift\n")
        try:
            verify_legacy_identity(legacy_identity_path, repository, legacy_copy)
        except PinError:
            legacy_bad_count += 1
            print("legacy identity known-bad rejected: a drifted checked-in copy")
        else:
            raise PinError("self-test accepts a drifted checked-in copy")
        finally:
            legacy_copy.write_bytes(original_copy)
        verify(identity_path, repository)
        print("self-test known-good accepted: trusted signer over the pinned commit")
        bad_path = repository / "bad.toml"
        # Each known-bad identity breaks exactly one property: the pinned tree,
        # the tag object, the signature block, the signing key, or the peel.
        # The run prints its classification, so a green result names the cases
        # that discriminated rather than asserting a count no output carries.
        field_substitutions = {
            "a wrong driver tree": (
                f'driver_tree = "{tree}"',
                f'driver_tree = "{"0" * 40}"',
            ),
            "a wrong profiled source tag object": (
                f'profiled_source_tag_object = "{profiled_tag_object}"',
                f'profiled_source_tag_object = "{tag_object}"',
            ),
        }
        bad_count = 0
        for description, (original, replacement) in field_substitutions.items():
            bad_text = identity_path.read_text(encoding="utf-8").replace(
                original, replacement
            )
            bad_path.write_text(bad_text, encoding="utf-8")
            try:
                verify(bad_path, repository)
            except PinError:
                bad_count += 1
                print(f"self-test known-bad rejected: {description}")
            else:
                raise PinError(f"self-test accepts {description}")
        substitutions = {
            "an unsigned profiled source tag": (
                "unsigned-profiled-fixture-tag",
                unsigned_tag_object,
            ),
            "a profiled source tag signed by an untrusted key": (
                "untrusted-profiled-fixture-tag",
                untrusted_tag_object,
            ),
            "a trusted-key tag that peels to the wrong commit": (
                "wrong-peel-profiled-fixture-tag",
                wrong_peel_tag_object,
            ),
        }
        for description, (tag_name, object_id) in substitutions.items():
            bad_text = (
                identity_path.read_text(encoding="utf-8")
                .replace(
                    'profiled_source_tag = "profiled-fixture-tag"',
                    f'profiled_source_tag = "{tag_name}"',
                )
                .replace(
                    f'profiled_source_tag_object = "{profiled_tag_object}"',
                    f'profiled_source_tag_object = "{object_id}"',
                )
            )
            bad_path.write_text(bad_text, encoding="utf-8")
            try:
                verify(bad_path, repository)
            except PinError:
                bad_count += 1
                print(f"self-test known-bad rejected: {description}")
            else:
                raise PinError(f"self-test accepts {description}")
    print(
        f"radeon source pin calibration: PASS (1 good and {bad_count} bad "
        "identities classified)"
    )
    print(
        "radeon legacy identity calibration: PASS "
        f"(1 good and {legacy_bad_count} bad identities classified)"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--identity", type=Path)
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--pkgbuild", type=Path)
    parser.add_argument("--legacy-identity", type=Path)
    parser.add_argument("--legacy-repository", type=Path)
    parser.add_argument("--legacy-copy", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--allowed-signers",
        type=Path,
        help="release signers for the profiled source tag; defaults to "
        f"{DEFAULT_ALLOWED_SIGNERS} beside the identity file",
    )
    arguments = parser.parse_args()
    legacy_arguments = (
        arguments.legacy_identity,
        arguments.legacy_repository,
        arguments.legacy_copy,
    )
    try:
        if arguments.self_test:
            if any(argument is not None for argument in legacy_arguments) or any(
                argument is not None
                for argument in (
                    arguments.identity,
                    arguments.repository,
                    arguments.pkgbuild,
                    arguments.allowed_signers,
                )
            ):
                parser.error("--self-test cannot be combined with verification options")
            run_self_test()
            return 0
        if arguments.identity is None or arguments.repository is None:
            parser.error("--identity and --repository are required")
        if any(argument is not None for argument in legacy_arguments) and not all(
            argument is not None for argument in legacy_arguments
        ):
            parser.error(
                "legacy identity mode requires --legacy-identity, "
                "--legacy-repository, and --legacy-copy"
            )
        identity = verify(
            arguments.identity,
            arguments.repository,
            arguments.pkgbuild,
            arguments.allowed_signers,
            arguments.legacy_identity,
            arguments.legacy_repository,
            arguments.legacy_copy,
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
