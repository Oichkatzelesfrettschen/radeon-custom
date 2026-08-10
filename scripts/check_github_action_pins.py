#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Verify the finite GitHub Actions workflow and immutable action pin set."""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ApprovedAction:
    revision: str
    version: str


APPROVED_ACTIONS = {
    "actions/checkout": ApprovedAction(
        "3d3c42e5aac5ba805825da76410c181273ba90b1",
        "v7.0.1",
    ),
    "actions/download-artifact": ApprovedAction(
        "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
        "v8.0.1",
    ),
    "actions/upload-artifact": ApprovedAction(
        "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "v7.0.1",
    ),
}

EXPECTED_WORKFLOW_ACTIONS = {
    ".github/workflows/gates.yml": (
        "actions/checkout",
        "actions/checkout",
        "actions/checkout",
        "actions/upload-artifact",
        "actions/upload-artifact",
        "actions/checkout",
    ),
    ".github/workflows/target-kernel.yml": (
        "actions/checkout",
        "actions/download-artifact",
        "actions/upload-artifact",
    ),
}

USES_MAPPING_KEY = re.compile(
    r"(?:(?<![A-Za-z0-9_.-])uses\s*:|[\"']uses[\"']\s*:)"
)
YAML_ANCHOR_OR_ALIAS = re.compile(
    r"(?:^|[\s:\[,-])[&*](?![&*])[^ \t,\]}#]+"
)
YAML_EXPLICIT_KEY = re.compile(r"^\s*\?")
YAML_QUOTED_KEY = re.compile(r"^\s*(?:-\s*)?[\"'][^\"']+[\"']\s*:")
YAML_FLOW_STEP = re.compile(r"^\s*-\s*\{")
YAML_TYPE_TAG = re.compile(r"(?:^|[\s:\[,-])!![A-Za-z0-9_:/.-]+")
YAML_DIRECTIVE = re.compile(r"^\s*%")
YAML_BLOCK_SCALAR = re.compile(
    r":\s*[|>](?:[1-9][+-]?|[+-][1-9]?)?\s*(?:#.*)?$"
)
PINNED_USE = re.compile(
    r"^\s*(?:-\s*)?uses\s*:\s*"
    r"(?P<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@"
    r"(?P<revision>[0-9a-f]{40})\s+"
    r"#\s+(?P<version>v[0-9]+\.[0-9]+\.[0-9]+)\s*$"
)


class ActionPinError(Exception):
    """A workflow or action reference violates the finite pin contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ActionPinError(message)


def workflow_paths(repository: Path) -> list[Path]:
    workflow_root = repository / ".github/workflows"
    require(
        workflow_root.is_dir() and not workflow_root.is_symlink(),
        "workflow directory is absent or indirect",
    )
    paths = sorted(
        path
        for path in workflow_root.iterdir()
        if path.suffix in {".yml", ".yaml"}
    )
    for path in paths:
        require(
            path.is_file() and not path.is_symlink(),
            f"workflow is not a regular file: {path.name}",
        )
    actual = {path.relative_to(repository).as_posix() for path in paths}
    expected = set(EXPECTED_WORKFLOW_ACTIONS)
    require(
        actual == expected,
        "workflow denominator differs: "
        f"missing={sorted(expected - actual)} unexpected={sorted(actual - expected)}",
    )
    return paths


def workflow_action_sequence(repository: Path, workflow: Path) -> tuple[str, ...]:
    actions: list[str] = []
    block_scalar_indent: int | None = None
    for line_number, line in enumerate(
        workflow.read_text(encoding="ascii").splitlines(),
        1,
    ):
        stripped = line.lstrip(" ")
        indentation = len(line) - len(stripped)
        if block_scalar_indent is not None:
            if not stripped or indentation > block_scalar_indent:
                continue
            block_scalar_indent = None
        if not stripped or stripped.startswith("#"):
            continue
        relative = workflow.relative_to(repository).as_posix()
        if YAML_ANCHOR_OR_ALIAS.search(line) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: YAML anchors and aliases are outside "
                "the canonical workflow subset"
            )
        if YAML_EXPLICIT_KEY.match(line) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: explicit YAML keys are outside "
                "the canonical workflow subset"
            )
        if YAML_DIRECTIVE.match(line) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: YAML directives are outside "
                "the canonical workflow subset"
            )
        if YAML_TYPE_TAG.search(line) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: YAML type tags are outside "
                "the canonical workflow subset"
            )
        if YAML_QUOTED_KEY.match(line) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: quoted YAML keys are outside "
                "the canonical workflow subset"
            )
        if YAML_FLOW_STEP.match(line) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: flow-style steps are outside "
                "the canonical workflow subset"
            )
        if YAML_BLOCK_SCALAR.search(line) is not None:
            block_scalar_indent = indentation
        if USES_MAPPING_KEY.search(line) is None:
            continue
        match = PINNED_USE.fullmatch(line)
        if match is None:
            raise ActionPinError(
                f"{relative}:{line_number}: action use lacks canonical block syntax, "
                "an exact SHA, or a version label"
            )
        action = match.group("action")
        approved = APPROVED_ACTIONS.get(action)
        if approved is None:
            raise ActionPinError(
                f"{relative}:{line_number}: "
                f"action is outside the approved denominator: {action}"
            )
        require(
            match.group("revision") == approved.revision,
            f"{relative}:{line_number}: {action} revision differs from {approved.revision}",
        )
        require(
            match.group("version") == approved.version,
            f"{relative}:{line_number}: {action} version label differs from {approved.version}",
        )
        actions.append(action)
    return tuple(actions)


def verify_repository(repository: Path) -> tuple[int, int]:
    paths = workflow_paths(repository)
    total = 0
    observed_actions: set[str] = set()
    for workflow in paths:
        relative = workflow.relative_to(repository).as_posix()
        actual = workflow_action_sequence(repository, workflow)
        expected = EXPECTED_WORKFLOW_ACTIONS[relative]
        require(
            actual == expected,
            f"{relative}: action sequence differs: expected={expected} actual={actual}",
        )
        total += len(actual)
        observed_actions.update(actual)
    require(
        observed_actions == set(APPROVED_ACTIONS),
        "approved action denominator differs from workflow use",
    )
    return len(paths), total


def write_fixture(repository: Path) -> None:
    for relative, actions in EXPECTED_WORKFLOW_ACTIONS.items():
        lines = ["name: action-pin-fixture", "jobs:", "  verify:", "    steps:"]
        for action in actions:
            approved = APPROVED_ACTIONS[action]
            lines.append(
                f"      - uses: {action}@{approved.revision} # {approved.version}"
            )
        path = repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="ascii")


def expect_rejection(name: str, mutation: Callable[[Path], None]) -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-action-pin-") as directory:
        repository = Path(directory)
        write_fixture(repository)
        mutation(repository)
        try:
            verify_repository(repository)
        except ActionPinError:
            print(f"PASS known-bad: {name}")
            return
        raise ActionPinError(f"self-test accepted known-bad fixture: {name}")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-action-pin-") as directory:
        repository = Path(directory)
        write_fixture(repository)
        verify_repository(repository)
        print("PASS known-good: exact workflow action denominator")

    def mutable_tag(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        content = path.read_text(encoding="ascii")
        path.write_text(
            content.replace(APPROVED_ACTIONS["actions/checkout"].revision, "v7", 1),
            encoding="ascii",
        )

    def stale_revision(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        content = path.read_text(encoding="ascii")
        path.write_text(
            content.replace(APPROVED_ACTIONS["actions/checkout"].revision, "0" * 40, 1),
            encoding="ascii",
        )

    def stale_label(repository: Path) -> None:
        path = repository / ".github/workflows/target-kernel.yml"
        content = path.read_text(encoding="ascii")
        path.write_text(content.replace("# v8.0.1", "# v4", 1), encoding="ascii")

    def missing_use(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        lines = path.read_text(encoding="ascii").splitlines()
        path.write_text("\n".join(lines[:-1]) + "\n", encoding="ascii")

    def unexpected_workflow(repository: Path) -> None:
        path = repository / ".github/workflows/unreviewed.yml"
        path.write_text("name: unreviewed\n", encoding="ascii")

    def anchored_flow_alias(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/upload-artifact"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - &hidden {name: Hidden action, uses: "
                f"actions/upload-artifact@{approved.revision}}}\n"
                "      - *hidden\n"
            )

    def flow_mapping(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/upload-artifact"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - {name: Hidden action, uses: "
                f"actions/upload-artifact@{approved.revision}}}\n"
            )

    def quoted_uses_key(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/upload-artifact"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - name: Hidden action\n"
                f"        \"uses\": actions/upload-artifact@{approved.revision}\n"
            )

    def escaped_quoted_key(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/upload-artifact"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - name: Hidden action\n"
                f"        \"\\x75ses\": actions/upload-artifact@{approved.revision}\n"
            )

    def tagged_flow_mapping(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/upload-artifact"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - !!map {name: Hidden action, \"\\x75ses\": "
                f"actions/upload-artifact@{approved.revision}}}\n"
            )

    expect_rejection("mutable action tag", mutable_tag)
    expect_rejection("unapproved action revision", stale_revision)
    expect_rejection("stale action version label", stale_label)
    expect_rejection("missing action use", missing_use)
    expect_rejection("unexpected workflow", unexpected_workflow)
    expect_rejection("anchored flow action alias", anchored_flow_alias)
    expect_rejection("flow-style action mapping", flow_mapping)
    expect_rejection("quoted uses key", quoted_uses_key)
    expect_rejection("escaped quoted key", escaped_quoted_key)
    expect_rejection("tagged flow mapping", tagged_flow_mapping)
    print("GitHub action pin calibration: 1 known-good and 10 known-bad fixtures")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--repository",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.self_test:
            run_self_test()
        else:
            workflows, uses = verify_repository(arguments.repository.resolve())
            print(
                f"GitHub action pins: {uses} exact uses across {workflows} workflows"
            )
    except (ActionPinError, OSError, UnicodeError) as error:
        print(f"GitHub action pin check: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
