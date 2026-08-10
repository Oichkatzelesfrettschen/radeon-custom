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

USE_PREFIX = re.compile(r"^\s*(?:-\s*)?uses\s*:")
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
    for line_number, line in enumerate(
        workflow.read_text(encoding="ascii").splitlines(),
        1,
    ):
        if USE_PREFIX.match(line) is None:
            continue
        match = PINNED_USE.fullmatch(line)
        relative = workflow.relative_to(repository).as_posix()
        if match is None:
            raise ActionPinError(
                f"{relative}:{line_number}: action use lacks an exact SHA and version label"
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

    expect_rejection("mutable action tag", mutable_tag)
    expect_rejection("unapproved action revision", stale_revision)
    expect_rejection("stale action version label", stale_label)
    expect_rejection("missing action use", missing_use)
    expect_rejection("unexpected workflow", unexpected_workflow)
    print("GitHub action pin calibration: 1 known-good and 5 known-bad fixtures")


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
