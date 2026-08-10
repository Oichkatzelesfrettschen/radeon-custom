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
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path


@dataclass(frozen=True)
class ApprovedAction:
    revision: str
    version: str
    required_inputs: tuple[tuple[str, str], ...] = ()


APPROVED_ACTIONS = {
    "actions/checkout": ApprovedAction(
        "3d3c42e5aac5ba805825da76410c181273ba90b1",
        "v7.0.1",
    ),
    "actions/download-artifact": ApprovedAction(
        "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
        "v8.0.1",
        (
            ("skip-decompress", "true"),
            ("digest-mismatch", "error"),
        ),
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

YAML_ANCHOR_OR_ALIAS = re.compile(
    r"(?:^|[\s:\[,-])[&*](?![&*])[^ \t,\]}#]+"
)
YAML_EXPLICIT_KEY = re.compile(r"^\s*(?:-\s*)?\?(?:\s|$)")
YAML_FLOW_MAPPING_NODE = re.compile(
    r"^\s*(?:-\s*)?(?:[A-Za-z0-9_.-]+\s*:\s*)?\{"
)
YAML_DIRECTIVE = re.compile(r"^\s*%")
YAML_NODE_TAG = re.compile(
    r"^\s*(?:-\s*)?(?:[A-Za-z0-9_.-]+\s*:\s*)?!"
)
YAML_MERGE_KEY = re.compile(r"^\s*(?:-\s*)?<<\s*:")
YAML_BLOCK_SCALAR = re.compile(
    r":\s*[|>](?:[1-9][+-]?|[+-][1-9]?)?\s*(?:#.*)?$"
)
PLAIN_MAPPING_ENTRY = re.compile(
    r"^(?P<indent> *)(?:(?P<sequence>-\s+))?"
    r"(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)\s*:\s*(?P<value>.*)$"
)
YAML_SEQUENCE_ITEM = re.compile(r"^\s*-(?:\s|$)")
PINNED_USE = re.compile(
    r"^\s*(?:-\s*)?uses\s*:\s*"
    r"(?P<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@"
    r"(?P<revision>[0-9a-f]{40})\s+"
    r"#\s+(?P<version>v[0-9]+\.[0-9]+\.[0-9]+)\s*$"
)


class ActionPinError(Exception):
    """A workflow or action reference violates the finite pin contract."""


class ActionReferenceContext(Enum):
    """Structural location of a plain uses mapping key."""

    OTHER = "other"
    REUSABLE_JOB = "reusable-job"
    STEP_ACTION = "step-action"
    STEP_ACTION_INPUT = "step-action-input"


@dataclass(frozen=True)
class PlainMappingEntry:
    """One block-style plain mapping entry."""

    indentation: int
    key_column: int
    sequence_item: bool
    key: str
    value: str


@dataclass(frozen=True)
class YamlLineScan:
    """Comment-free code plus multiline quoted-scalar state."""

    code: str
    quote: str | None
    multiline_scalar: bool
    opened_multiline_scalar: bool


@dataclass
class WorkflowPathTracker:
    """Track action-bearing block paths in one workflow document."""

    root_keys: set[str] = field(default_factory=set)
    job_ids: set[str] = field(default_factory=set)
    job_property_keys: set[str] = field(default_factory=set)
    step_property_keys: set[str] = field(default_factory=set)
    jobs_indent: int | None = None
    job_indent: int | None = None
    job_property_indent: int | None = None
    steps_indent: int | None = None
    step_indent: int | None = None
    step_property_indent: int | None = None
    with_indent: int | None = None
    with_property_indent: int | None = None
    with_property_keys: set[str] = field(default_factory=set)

    def clear_with(self) -> None:
        self.with_indent = None
        self.with_property_indent = None
        self.with_property_keys.clear()

    def clear_step(self) -> None:
        self.clear_with()
        self.step_indent = None
        self.step_property_indent = None
        self.step_property_keys.clear()

    def clear_steps(self) -> None:
        self.steps_indent = None
        self.clear_step()

    def clear_job(self) -> None:
        self.job_indent = None
        self.job_property_indent = None
        self.job_property_keys.clear()
        self.clear_steps()

    def clear_jobs(self) -> None:
        self.jobs_indent = None
        self.job_ids.clear()
        self.clear_job()

    def classify(
        self,
        entry: PlainMappingEntry | None,
        indentation: int,
        sequence_item: bool,
    ) -> ActionReferenceContext:
        if self.with_indent is not None and indentation <= self.with_indent:
            self.clear_with()
        if self.step_indent is not None and indentation <= self.step_indent:
            self.clear_step()
        if self.steps_indent is not None and (
            indentation < self.steps_indent
            or (indentation == self.steps_indent and not sequence_item)
        ):
            self.clear_steps()
        if self.job_indent is not None and indentation <= self.job_indent:
            self.clear_job()
        if self.jobs_indent is not None and indentation <= self.jobs_indent:
            self.clear_jobs()

        if entry is not None and not sequence_item and indentation == 0:
            require(
                entry.key not in self.root_keys,
                f"duplicate root mapping key: {entry.key}",
            )
            self.root_keys.add(entry.key)
            if entry.key == "jobs":
                require(
                    not entry.value.strip(),
                    "jobs must use a block-style mapping",
                )
                self.jobs_indent = indentation
            return ActionReferenceContext.OTHER

        if self.jobs_indent is None or indentation <= self.jobs_indent:
            return ActionReferenceContext.OTHER

        if entry is not None and not sequence_item:
            if self.job_indent is None:
                require(
                    not entry.value.strip(),
                    f"job {entry.key} must use a block-style mapping",
                )
                require(
                    entry.key not in self.job_ids,
                    f"duplicate job identifier: {entry.key}",
                )
                self.job_ids.add(entry.key)
                self.job_indent = indentation
                return ActionReferenceContext.OTHER

        if self.job_indent is None or indentation <= self.job_indent:
            return ActionReferenceContext.OTHER

        if entry is not None and not sequence_item:
            if self.job_property_indent is None:
                self.job_property_indent = indentation
            if indentation == self.job_property_indent:
                require(
                    entry.key not in self.job_property_keys,
                    f"duplicate job property: {entry.key}",
                )
                self.job_property_keys.add(entry.key)
                if entry.key == "steps":
                    require(
                        not entry.value.strip(),
                        "job steps must use a block-style sequence",
                    )
                    self.steps_indent = indentation
                    self.clear_step()
                if entry.key == "uses":
                    return ActionReferenceContext.REUSABLE_JOB

        if self.steps_indent is None or indentation < self.steps_indent or (
            indentation == self.steps_indent and not sequence_item
        ):
            return ActionReferenceContext.OTHER

        if sequence_item:
            if self.step_indent is not None and indentation > self.step_indent:
                return ActionReferenceContext.OTHER
            if entry is None:
                raise ActionPinError(
                    "workflow step sequence entries must start with a plain "
                    "mapping key"
                )
            self.step_indent = indentation
            self.step_property_indent = entry.key_column
            self.step_property_keys = {entry.key}
            if entry.key == "uses":
                return ActionReferenceContext.STEP_ACTION
            return ActionReferenceContext.OTHER

        if (
            entry is not None
            and self.step_property_indent is not None
            and indentation == self.step_property_indent
        ):
            require(
                entry.key not in self.step_property_keys,
                f"duplicate step property: {entry.key}",
            )
            self.step_property_keys.add(entry.key)
            if entry.key == "with":
                require(
                    not entry.value.strip(),
                    "action inputs must use a block-style mapping",
                )
                self.with_indent = indentation
                self.with_property_indent = None
                self.with_property_keys.clear()
            if entry.key == "uses":
                return ActionReferenceContext.STEP_ACTION

        if self.with_indent is not None and indentation > self.with_indent:
            if sequence_item or entry is None:
                raise ActionPinError(
                    "action inputs must use plain scalar mapping entries"
                )
            if self.with_property_indent is None:
                self.with_property_indent = indentation
            require(
                indentation == self.with_property_indent,
                "nested action input values are outside the canonical subset",
            )
            require(
                entry.key not in self.with_property_keys,
                f"duplicate action input: {entry.key}",
            )
            self.with_property_keys.add(entry.key)
            return ActionReferenceContext.STEP_ACTION_INPUT

        return ActionReferenceContext.OTHER


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ActionPinError(message)


def mask_github_expressions(line: str) -> str:
    masked = list(line)
    search_start = 0
    while True:
        expression_start = line.find("${{", search_start)
        if expression_start < 0:
            return "".join(masked)

        cursor = expression_start + 3
        in_string = False
        expression_end: int | None = None
        while cursor < len(line) - 1:
            if line[cursor] == "'":
                if in_string and line[cursor : cursor + 2] == "''":
                    cursor += 2
                    continue
                in_string = not in_string
                cursor += 1
                continue
            if not in_string and line[cursor : cursor + 2] == "}}":
                expression_end = cursor + 2
                break
            cursor += 1

        if expression_end is None:
            raise ActionPinError("unterminated GitHub expression")
        masked[expression_start:expression_end] = " " * (
            expression_end - expression_start
        )
        search_start = expression_end


def yaml_quote_starts(line: str, index: int) -> bool:
    prefix = line[:index].strip()
    if prefix in {"", "-"}:
        return True
    return (
        re.fullmatch(
            r"(?:-\s+)?[A-Za-z_][A-Za-z0-9_.-]*\s*:\s*"
            r"(?:\[[^\]]*)?",
            prefix,
        )
        is not None
    )


def scan_yaml_line(line: str, quote: str | None) -> YamlLineScan:
    continued_multiline_scalar = quote is not None
    open_quote_index: int | None = None
    cursor = 0
    while cursor < len(line):
        character = line[cursor]
        if quote == "'":
            if character == "'":
                if line[cursor : cursor + 2] == "''":
                    cursor += 2
                    continue
                quote = None
                open_quote_index = None
            cursor += 1
            continue
        if quote == '"':
            if character == "\\":
                cursor += 2
                continue
            if character == '"':
                quote = None
                open_quote_index = None
            cursor += 1
            continue
        if character == "'" and yaml_quote_starts(line, cursor):
            quote = "'"
            open_quote_index = cursor
        elif character == '"' and yaml_quote_starts(line, cursor):
            quote = '"'
            open_quote_index = cursor
        elif character == "#" and (cursor == 0 or line[cursor - 1].isspace()):
            return YamlLineScan(
                code="" if continued_multiline_scalar else line[:cursor],
                quote=quote,
                multiline_scalar=continued_multiline_scalar,
                opened_multiline_scalar=False,
            )
        cursor += 1
    opened_multiline_scalar = (
        not continued_multiline_scalar and quote is not None
    )
    multiline_scalar = continued_multiline_scalar or opened_multiline_scalar
    if continued_multiline_scalar:
        code = ""
    elif opened_multiline_scalar:
        require(open_quote_index is not None, "multiline quote start is absent")
        code = line[:open_quote_index]
    else:
        code = line
    return YamlLineScan(
        code=code,
        quote=quote,
        multiline_scalar=multiline_scalar,
        opened_multiline_scalar=opened_multiline_scalar,
    )


def parse_plain_mapping_entry(line: str) -> PlainMappingEntry | None:
    match = PLAIN_MAPPING_ENTRY.fullmatch(line)
    if match is None:
        return None
    return PlainMappingEntry(
        indentation=len(match.group("indent")),
        key_column=match.start("key"),
        sequence_item=match.group("sequence") is not None,
        key=match.group("key"),
        value=match.group("value"),
    )


def has_quoted_mapping_key(line: str) -> bool:
    cursor = 0
    while cursor < len(line):
        quote = line[cursor]
        if quote not in {"'", '"'} or not yaml_quote_starts(line, cursor):
            cursor += 1
            continue

        quote_start = cursor
        cursor += 1
        while cursor < len(line):
            character = line[cursor]
            if quote == '"' and character == "\\":
                cursor += 2
                continue
            if character == quote:
                if quote == "'" and line[cursor : cursor + 2] == "''":
                    cursor += 2
                    continue
                cursor += 1
                following = line[cursor:].lstrip()
                if following.startswith(":") and (
                    len(following) == 1
                    or following[1].isspace()
                    or line[:quote_start].strip() in {"", "-"}
                ):
                    return True
                break
            cursor += 1
    return False


def mask_yaml_quoted_scalars(line: str) -> str:
    masked = list(line)
    quote: str | None = None
    cursor = 0
    while cursor < len(line):
        character = line[cursor]
        if quote == "'":
            masked[cursor] = " "
            if character == "'":
                if line[cursor : cursor + 2] == "''":
                    masked[cursor + 1] = " "
                    cursor += 2
                    continue
                quote = None
            cursor += 1
            continue
        if quote == '"':
            masked[cursor] = " "
            if character == "\\" and cursor + 1 < len(line):
                masked[cursor + 1] = " "
                cursor += 2
                continue
            if character == '"':
                quote = None
            cursor += 1
            continue
        if character in {"'", '"'} and yaml_quote_starts(line, cursor):
            quote = character
            masked[cursor] = " "
        cursor += 1
    return "".join(masked)


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
    multiline_quote: str | None = None
    path_tracker = WorkflowPathTracker()
    relative = workflow.relative_to(repository).as_posix()
    step_action: str | None = None
    step_action_line: int | None = None
    step_inputs: dict[str, str] = {}

    def finish_step() -> None:
        nonlocal step_action, step_action_line
        if step_action is not None:
            approved = APPROVED_ACTIONS[step_action]
            for input_name, expected_value in approved.required_inputs:
                actual_value = step_inputs.get(input_name)
                require(
                    actual_value == expected_value,
                    f"{relative}:{step_action_line}: {step_action} input "
                    f"{input_name} must equal {expected_value}",
                )
        step_action = None
        step_action_line = None
        step_inputs.clear()

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
        try:
            scanned = scan_yaml_line(line, multiline_quote)
            multiline_quote = scanned.quote
            if scanned.multiline_scalar and not scanned.opened_multiline_scalar:
                continue
            expression_masked_line = mask_github_expressions(scanned.code)
        except ActionPinError as error:
            raise ActionPinError(f"{relative}:{line_number}: {error}") from error
        code = expression_masked_line
        raw_entry = parse_plain_mapping_entry(scanned.code)
        if not code.strip():
            continue
        structural = mask_yaml_quoted_scalars(code)
        if YAML_ANCHOR_OR_ALIAS.search(structural) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: YAML anchors and aliases are outside "
                "the canonical workflow subset"
            )
        if YAML_EXPLICIT_KEY.match(structural) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: explicit YAML keys are outside "
                "the canonical workflow subset"
            )
        if YAML_DIRECTIVE.match(structural) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: YAML directives are outside "
                "the canonical workflow subset"
            )
        if YAML_NODE_TAG.match(structural) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: tagged YAML mapping nodes are outside "
                "the canonical workflow subset"
            )
        if YAML_MERGE_KEY.match(structural) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: YAML merge keys are outside "
                "the canonical workflow subset"
            )
        if YAML_FLOW_MAPPING_NODE.match(structural) is not None:
            raise ActionPinError(
                f"{relative}:{line_number}: flow-style mappings are outside "
                "the canonical workflow subset"
            )
        if has_quoted_mapping_key(code):
            raise ActionPinError(
                f"{relative}:{line_number}: quoted YAML mapping keys are outside "
                "the canonical workflow subset"
            )
        entry = parse_plain_mapping_entry(code)
        if YAML_BLOCK_SCALAR.search(structural) is not None:
            block_scalar_indent = (
                entry.key_column if entry is not None else indentation
            )
        if (
            path_tracker.steps_indent is not None
            and path_tracker.step_indent is None
            and indentation >= path_tracker.steps_indent
            and structural.lstrip().startswith("[")
        ):
            raise ActionPinError(
                f"{relative}:{line_number}: flow-style step sequences are outside "
                "the canonical workflow subset"
            )
        sequence_item = YAML_SEQUENCE_ITEM.match(structural) is not None
        if (
            path_tracker.step_indent is not None
            and sequence_item
            and indentation <= path_tracker.step_indent
        ):
            finish_step()
        try:
            reference_context = path_tracker.classify(
                entry,
                indentation,
                sequence_item,
            )
        except ActionPinError as error:
            raise ActionPinError(f"{relative}:{line_number}: {error}") from error
        if scanned.opened_multiline_scalar:
            if (
                entry is not None
                and entry.key == "uses"
                and reference_context is not ActionReferenceContext.OTHER
            ):
                raise ActionPinError(
                    f"{relative}:{line_number}: action references must use "
                    "single-line canonical syntax"
                )
            continue
        if reference_context is ActionReferenceContext.STEP_ACTION_INPUT:
            if (
                entry is None
                or raw_entry is None
                or not raw_entry.value.strip()
            ):
                raise ActionPinError(
                    f"{relative}:{line_number}: action inputs must use nonempty "
                    "single-line scalar values"
                )
            step_inputs[entry.key] = raw_entry.value.strip()
            continue
        if entry is None or entry.key != "uses":
            continue
        if reference_context is ActionReferenceContext.OTHER:
            continue
        if reference_context is ActionReferenceContext.REUSABLE_JOB:
            raise ActionPinError(
                f"{relative}:{line_number}: reusable workflow references are outside "
                "the approved action denominator"
            )
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
        step_action = action
        step_action_line = line_number
        actions.append(action)
    require(
        multiline_quote is None,
        f"{relative}: unterminated multiline YAML quoted scalar",
    )
    finish_step()
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
        checkout = APPROVED_ACTIONS["actions/checkout"]
        lines = [
            "name: action-pin-fixture",
            "on:",
            "  push:",
            "jobs:",
            "  verify:",
            '    name: "Literal {brace}" # literal ${{ in comment',
            "    runs-on: ubuntu-latest",
            "    env:",
            '      MESSAGE: "Literal {brace}"',
            "      RUN_LABEL: Literal {brace}",
            "      COLON_BRACE: foo:{bar}",
            "      COMMA_BRACE: foo,{bar}",
            "      BRACKET_BRACE: foo[{bar}",
            "      DASH_BRACE: foo-{bar}",
            '      DOUBLE_QUOTED_PLAIN_TEXT: foo "bar":baz',
            "      SINGLE_QUOTED_PLAIN_TEXT: foo 'bar':baz",
            '      QUOTED_COMMA_TEXT: foo "bar":,baz',
            '      QUOTED_OPEN_BRACE_TEXT: foo "bar":{baz}',
            '      QUOTED_OPEN_BRACKET_TEXT: foo "bar":[baz]',
            '      QUOTED_CLOSE_BRACE_TEXT: foo "bar":}baz',
            '      QUOTED_CLOSE_BRACKET_TEXT: foo "bar":]baz',
            '      QUOTED_ACTION_TEXT: "uses: actions/checkout@v4"',
            '      QUOTED_COMMENT_TEXT: "literal # scanner: |"',
            '      MULTILINE_ACTION_TEXT: "prefix',
            "      - uses: actions/checkout@"
            f"{checkout.revision} # {checkout.version}",
            '        suffix"',
            "      SINGLE_MULTILINE_ACTION_TEXT: 'prefix",
            "        it''s uses-looking text",
            "      - uses: actions/checkout@"
            f"{checkout.revision} # {checkout.version}",
            "        suffix'",
            "    steps:",
        ]
        lines.extend(
            [
                "      - name: |",
                "          Block-scalar step name",
                "        run: echo block-scalar key-column control",
                "      - name: 'Single multiline step name",
                "        it''s uses-looking text",
                "        trailing'",
                "        run: echo single-quoted multiline control",
                "      - name: Non-action uses mapping",
                "        env:",
                "          uses: "
                f"actions/checkout@{checkout.revision} # {checkout.version}",
                "        run: echo non-action mapping",
            ]
        )
        for action_index, action in enumerate(actions):
            approved = APPROVED_ACTIONS[action]
            if action_index == 0:
                lines.extend(
                    [
                        '      - name: "Multiline action name',
                        "        uses-looking text",
                        '        trailing"',
                        f"        uses: {action}@{approved.revision} "
                        f"# {approved.version}",
                    ]
                )
            else:
                lines.append(
                    f"      - uses: {action}@{approved.revision} # {approved.version}"
                )
            if approved.required_inputs:
                lines.append("        with:")
                lines.extend(
                    f"          {input_name}: {input_value}"
                    for input_name, input_value in approved.required_inputs
                )
        lines.extend(
            [
                "  data-only-job:",
                "    runs-on: ubuntu-latest",
                "    steps:",
                "      - run: echo job-path transition control",
            ]
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

    def rewrite_first_step_action(
        repository: Path,
        replacement: str | None,
    ) -> None:
        path = repository / ".github/workflows/gates.yml"
        lines = path.read_text(encoding="ascii").splitlines()
        steps_index = lines.index("    steps:")
        for line_index in range(steps_index + 1, len(lines)):
            if lines[line_index].startswith("      - uses: actions/checkout@"):
                if replacement is None:
                    del lines[line_index]
                else:
                    lines[line_index] = replacement
                path.write_text("\n".join(lines) + "\n", encoding="ascii")
                return
        raise ActionPinError("self-test fixture has no checkout step action")

    def mutable_tag(repository: Path) -> None:
        rewrite_first_step_action(
            repository,
            "      - uses: actions/checkout@v7 # v7.0.1",
        )

    def stale_revision(repository: Path) -> None:
        rewrite_first_step_action(
            repository,
            "      - uses: actions/checkout@" + "0" * 40 + " # v7.0.1",
        )

    def stale_label(repository: Path) -> None:
        path = repository / ".github/workflows/target-kernel.yml"
        content = path.read_text(encoding="ascii")
        path.write_text(content.replace("# v8.0.1", "# v4", 1), encoding="ascii")

    def missing_use(repository: Path) -> None:
        rewrite_first_step_action(repository, None)

    def unexpected_workflow(repository: Path) -> None:
        path = repository / ".github/workflows/unreviewed.yml"
        path.write_text("name: unreviewed\n", encoding="ascii")

    def rewrite_download_input(
        repository: Path,
        input_name: str,
        replacement: str | None,
        *,
        duplicate: bool = False,
    ) -> None:
        path = repository / ".github/workflows/target-kernel.yml"
        lines = path.read_text(encoding="ascii").splitlines()
        prefix = f"          {input_name}:"
        matching = [
            line_index
            for line_index, line in enumerate(lines)
            if line.startswith(prefix)
        ]
        if len(matching) != 1:
            raise ActionPinError(
                f"self-test fixture has {len(matching)} {input_name} inputs"
            )
        line_index = matching[0]
        if duplicate:
            lines.insert(line_index + 1, lines[line_index])
        elif replacement is None:
            del lines[line_index]
        else:
            lines[line_index] = f"          {input_name}: {replacement}"
        path.write_text("\n".join(lines) + "\n", encoding="ascii")

    def missing_raw_download(repository: Path) -> None:
        rewrite_download_input(repository, "skip-decompress", None)

    def disabled_raw_download(repository: Path) -> None:
        rewrite_download_input(repository, "skip-decompress", "false")

    def quoted_raw_download(repository: Path) -> None:
        rewrite_download_input(repository, "skip-decompress", '"true"')

    def warning_digest_mismatch(repository: Path) -> None:
        rewrite_download_input(repository, "digest-mismatch", "warn")

    def duplicate_raw_download(repository: Path) -> None:
        rewrite_download_input(
            repository,
            "skip-decompress",
            None,
            duplicate=True,
        )

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

    def encoded_flow_job(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/upload-artifact"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "  hidden: {runs-on: ubuntu-latest, steps: "
                "[{name: Hidden action, \"\\x75ses\":"
                f"actions/upload-artifact@{approved.revision}}}]}}\n"
            )

    def comment_forged_block_scalar(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - name: Hidden action # scanner: |\n"
                "        uses: attacker/action@v1\n"
            )

    def sequence_explicit_key(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/upload-artifact"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - ? uses\n"
                f"        : actions/upload-artifact@{approved.revision}\n"
            )

    def compact_flow_step_sequence(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "  hidden:\n"
                "    runs-on: ubuntu-latest\n"
                "    steps: [\"\\x75ses\":actions/checkout@v4]\n"
            )

    def verbatim_string_tag(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - !<tag:yaml.org,2002:str> "
                "\"\\x75ses\": actions/checkout@v4\n"
            )

    def local_tagged_flow_mapping(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/checkout"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - !foo {name: Hidden, \"\\x75ses\": "
                f"actions/checkout@{approved.revision}}}\n"
            )

    def local_tagged_quoted_key(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/checkout"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - !foo \"\\x75ses\": "
                f"actions/checkout@{approved.revision}\n"
            )

    def bare_tagged_quoted_key(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/checkout"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - ! \"\\x75ses\": "
                f"actions/checkout@{approved.revision}\n"
            )

    def multiline_quoted_scalar_action_substitution(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/checkout"]
        rewrite_first_step_action(repository, None)
        content = path.read_text(encoding="ascii")
        path.write_text(
            content.replace(
                "    steps:\n",
                "      MULTILINE_ACTION_TEXT: \"prefix\n"
                f"      - uses: actions/checkout@{approved.revision} "
                f"# {approved.version}\n"
                "        suffix\"\n"
                "    steps:\n",
                1,
            ),
            encoding="ascii",
        )

    def non_action_mapping_substitution(repository: Path) -> None:
        rewrite_first_step_action(repository, None)

    def reusable_workflow_job(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "  reusable-workflow:\n"
                "    uses: octo-org/example/.github/workflows/gate.yml@main\n"
            )

    def indentationless_step_action(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "  hidden-indentless:\n"
                "    runs-on: ubuntu-latest\n"
                "    steps:\n"
                "    - uses: attacker/action@v1\n"
            )

    def duplicate_root_key(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write("name: duplicate-name\n")

    def duplicate_job_identifier(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "  verify:\n"
                "    runs-on: ubuntu-latest\n"
                "    steps:\n"
                "      - run: echo duplicate job\n"
            )

    def duplicate_job_property(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        content = path.read_text(encoding="ascii")
        path.write_text(
            content.replace(
                "    runs-on: ubuntu-latest\n",
                "    runs-on: ubuntu-latest\n"
                "    runs-on: ubuntu-24.04\n",
                1,
            ),
            encoding="ascii",
        )

    def duplicate_step_property(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        content = path.read_text(encoding="ascii")
        path.write_text(
            content.replace(
                "      - name: Non-action uses mapping\n",
                "      - name: Non-action uses mapping\n"
                "        name: Duplicate step name\n",
                1,
            ),
            encoding="ascii",
        )

    def multiline_step_action(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                '      - uses: "attacker/action@\\\n'
                '          v1"\n'
            )

    def single_quoted_multiline_step_action(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - uses: 'attacker/action@\n"
                "          v1'\n"
            )

    def literal_block_scalar_step_action(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - uses: |\n"
                "          attacker/action@v1\n"
            )

    def folded_block_scalar_step_action(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - uses: >-\n"
                "          attacker/action@v1\n"
            )

    def dynamic_step_action(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - uses: ${{ 'attacker/action@v1' }}\n"
            )

    def yaml_merge_key(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "  hidden-merge:\n"
                "    runs-on: ubuntu-latest\n"
                "    <<: {steps: [{uses: attacker/action@v1}]}\n"
            )

    def unterminated_multiline_scalar(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write('      - name: "unterminated scalar\n')

    def detached_step_mapping(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        approved = APPROVED_ACTIONS["actions/checkout"]
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      -\n"
                "        name: Detached action mapping\n"
                f"        uses: actions/checkout@{approved.revision} "
                f"# {approved.version}\n"
            )

    def sequence_block_scalar_sibling_action(repository: Path) -> None:
        path = repository / ".github/workflows/gates.yml"
        with path.open("a", encoding="ascii") as workflow:
            workflow.write(
                "      - name: |\n"
                "          Hidden action name\n"
                "        uses: attacker/action@v1\n"
            )

    expect_rejection("mutable action tag", mutable_tag)
    expect_rejection("unapproved action revision", stale_revision)
    expect_rejection("stale action version label", stale_label)
    expect_rejection("missing action use", missing_use)
    expect_rejection("unexpected workflow", unexpected_workflow)
    expect_rejection("missing raw artifact input", missing_raw_download)
    expect_rejection("disabled raw artifact input", disabled_raw_download)
    expect_rejection("quoted raw artifact input", quoted_raw_download)
    expect_rejection("nonfatal digest mismatch", warning_digest_mismatch)
    expect_rejection("duplicate raw artifact input", duplicate_raw_download)
    expect_rejection("anchored flow action alias", anchored_flow_alias)
    expect_rejection("flow-style action mapping", flow_mapping)
    expect_rejection("quoted uses key", quoted_uses_key)
    expect_rejection("escaped quoted key", escaped_quoted_key)
    expect_rejection("tagged flow mapping", tagged_flow_mapping)
    expect_rejection("encoded flow job", encoded_flow_job)
    expect_rejection("comment-forged block scalar", comment_forged_block_scalar)
    expect_rejection("sequence explicit key", sequence_explicit_key)
    expect_rejection("compact flow step sequence", compact_flow_step_sequence)
    expect_rejection("verbatim string tag", verbatim_string_tag)
    expect_rejection("local tagged flow mapping", local_tagged_flow_mapping)
    expect_rejection("local tagged quoted key", local_tagged_quoted_key)
    expect_rejection("bare tagged quoted key", bare_tagged_quoted_key)
    expect_rejection(
        "multiline quoted scalar action substitution",
        multiline_quoted_scalar_action_substitution,
    )
    expect_rejection(
        "non-action mapping substitution",
        non_action_mapping_substitution,
    )
    expect_rejection("reusable workflow job", reusable_workflow_job)
    expect_rejection("indentationless step action", indentationless_step_action)
    expect_rejection("duplicate root key", duplicate_root_key)
    expect_rejection("duplicate job identifier", duplicate_job_identifier)
    expect_rejection("duplicate job property", duplicate_job_property)
    expect_rejection("duplicate step property", duplicate_step_property)
    expect_rejection("multiline step action", multiline_step_action)
    expect_rejection(
        "single-quoted multiline step action",
        single_quoted_multiline_step_action,
    )
    expect_rejection(
        "literal block-scalar step action",
        literal_block_scalar_step_action,
    )
    expect_rejection(
        "folded block-scalar step action",
        folded_block_scalar_step_action,
    )
    expect_rejection("dynamic step action", dynamic_step_action)
    expect_rejection("YAML merge key", yaml_merge_key)
    expect_rejection(
        "unterminated multiline scalar",
        unterminated_multiline_scalar,
    )
    expect_rejection("detached step mapping", detached_step_mapping)
    expect_rejection(
        "sequence block-scalar sibling action",
        sequence_block_scalar_sibling_action,
    )
    print("GitHub action pin calibration: 1 known-good and 40 known-bad fixtures")


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
