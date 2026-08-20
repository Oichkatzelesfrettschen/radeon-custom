#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Verify the gate producer and target consumer artifact binding."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from collections.abc import Callable
from itertools import pairwise
from pathlib import Path

from check_github_action_pins import ActionPinError, verify_repository


GATES_WORKFLOW = Path(".github/workflows/gates.yml")
TARGET_WORKFLOW = Path(".github/workflows/target-kernel.yml")
STEP_START = re.compile(r"^      - (?:name|uses):")
JOB_START = re.compile(r"^  (?P<name>[A-Za-z_][A-Za-z0-9_-]*):$")

TARGET_JOB_CONTROL_LINES = (
    "  target-kernel:",
    "    if: >-",
    "      github.event.workflow_run.conclusion == 'success' &&",
    "      github.event.workflow_run.event == 'push' &&",
    "      github.event.workflow_run.head_branch == 'main'",
    "    runs-on: [self-hosted, linux, cachyos-target, target-host]",
    "    timeout-minutes: 60",
    "    env:",
    "      GATE_EVENT: ${{ github.event.workflow_run.event }}",
    "      GATE_REPOSITORY: ${{ github.event.workflow_run.head_repository.full_name }}",
    "      GATE_RUN_ID: ${{ github.event.workflow_run.id }}",
    "      GATE_SHA: ${{ github.event.workflow_run.head_sha }}",
    "      GATE_BRANCH: ${{ github.event.workflow_run.head_branch }}",
    "      PACKAGE_ARTIFACT: radeon-unified-${{ github.event.workflow_run.head_sha }}-${{ github.event.workflow_run.id }}",
    "      ARTIFACT_DOWNLOAD_NAME: radeon-gate-download-${{ github.run_id }}-${{ github.run_attempt }}",
    "      ARTIFACT_OUTPUT_NAME: radeon-gate-package-${{ github.run_id }}-${{ github.run_attempt }}",
    "    steps:",
)

RESOLVER_STEP_LINES = (
    "      - name: Resolve the gate artifact digest",
    "        id: gate-artifact",
    "        env:",
    "          GITHUB_TOKEN: ${{ github.token }}",
    "        run: |",
    "          set -euo pipefail",
    "          expected_sha256=$(python3 scripts/resolve_workflow_artifact_digest.py \\",
    '            --repository "$GITHUB_REPOSITORY" \\',
    '            --run-id "$GATE_RUN_ID" \\',
    '            --artifact-name "$PACKAGE_ARTIFACT")',
    '          printf \'sha256=%s\\n\' "$expected_sha256" >>"$GITHUB_OUTPUT"',
    "          printf 'artifact_sha256=%s\\n' \"$expected_sha256\" \\",
    '            >>"${RUNNER_TEMP}/radeon-target-evidence/gate-run.txt"',
)

DOWNLOAD_STEP_LINES = (
    "      - name: Download gate-verified package artifact",
    "        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: ${{ env.PACKAGE_ARTIFACT }}",
    "          path: ${{ runner.temp }}/${{ env.ARTIFACT_DOWNLOAD_NAME }}",
    "          github-token: ${{ github.token }}",
    "          repository: ${{ github.repository }}",
    "          run-id: ${{ github.event.workflow_run.id }}",
    "          skip-decompress: true",
    "          digest-mismatch: error",
)

ADMISSION_STEP_LINES = (
    "      - name: Admit the production package from the raw artifact",
    "        run: |",
    "          python3 scripts/admit_target_gate_artifact.py \\",
    '            --download-directory "${RUNNER_TEMP}/${ARTIFACT_DOWNLOAD_NAME}" \\',
    '            --output-directory "${RUNNER_TEMP}/${ARTIFACT_OUTPUT_NAME}" \\',
    '            --expected-sha256 "${{ steps.gate-artifact.outputs.sha256 }}"',
)

UPLOAD_STEP_LINES = (
    "      - name: Upload target compile evidence",
    "        if: always()",
    "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1",
    "        with:",
    "          name: radeon-target-${{ github.event.workflow_run.head_sha }}-${{ github.run_id }}",
    "          path: ${{ runner.temp }}/radeon-target-evidence",
    "          retention-days: 7",
    "          if-no-files-found: warn",
)

TARGET_JOB_ACTION_LINES = (
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1",
    DOWNLOAD_STEP_LINES[1],
    UPLOAD_STEP_LINES[2],
)

GATE_PACKAGE_UPLOAD_STEP_LINES = (
    "      - name: Upload package and lifecycle evidence",
    "        if: always() && github.event_name == 'push'",
    "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1",
    "        with:",
    "          name: radeon-unified-${{ github.sha }}-${{ github.run_id }}",
    "          path: ${{ runner.temp }}/radeon-package-artifacts",
    "          retention-days: 7",
    "          if-no-files-found: warn",
)

GATE_TRANSITION_UPLOAD_STEP_LINES = (
    "      - name: Upload transition matrix logs",
    "        if: always()",
    "        continue-on-error: true",
    "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1",
    "        with:",
    "          name: transition-matrix-logs-${{ github.run_id }}-${{ github.run_attempt }}",
    "          path: ${{ env.PACKAGE_WORK }}/transition-matrix-logs",
    "          if-no-files-found: ignore",
    "          retention-days: 1",
)

API_COMMAND_LINES = RESOLVER_STEP_LINES[6:10]


class TargetWorkflowError(Exception):
    """The target workflow violates the artifact-digest binding."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise TargetWorkflowError(message)


def canonical_step_lines(lines: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(
        line.rstrip()
        for line in lines
        if line.strip() and not line.lstrip().startswith("#")
    )


def workflow_step_blocks(lines: list[str]) -> list[tuple[str, ...]]:
    starts = [
        line_index
        for line_index, line in enumerate(lines)
        if STEP_START.match(line) is not None
    ]
    require(bool(starts), "target workflow has no canonical steps")
    starts.append(len(lines))
    return [tuple(lines[start:end]) for start, end in pairwise(starts)]


def exact_named_step(
    lines: list[str],
    expected_lines: tuple[str, ...],
    workflow_name: str,
) -> None:
    step_header = expected_lines[0]
    starts = [
        line_index
        for line_index, line in enumerate(lines)
        if line.rstrip() == step_header
    ]
    require(
        len(starts) == 1,
        f"{workflow_name} does not contain exactly one step: {step_header}",
    )
    start = starts[0]
    end = len(lines)
    for line_index in range(start + 1, len(lines)):
        line = lines[line_index]
        if STEP_START.match(line) is not None or JOB_START.fullmatch(line) is not None:
            end = line_index
            break
    require(
        canonical_step_lines(tuple(lines[start:end])) == expected_lines,
        f"{workflow_name} step differs from its binding contract: {step_header}",
    )


def verify_gate_producer(repository: Path) -> None:
    workflow = repository / GATES_WORKFLOW
    require(
        workflow.is_file() and not workflow.is_symlink(),
        "gate workflow is absent or indirect",
    )
    lines = workflow.read_text(encoding="utf-8").splitlines()
    exact_named_step(lines, GATE_TRANSITION_UPLOAD_STEP_LINES, "gate workflow")
    exact_named_step(lines, GATE_PACKAGE_UPLOAD_STEP_LINES, "gate workflow")


def target_job(repository_lines: list[str]) -> tuple[list[str], list[str]]:
    jobs_markers = [
        line_index
        for line_index, line in enumerate(repository_lines)
        if line == "jobs:"
    ]
    require(len(jobs_markers) == 1, "target workflow jobs mapping is not unique")
    jobs_index = jobs_markers[0]
    job_starts = [
        (line_index, match.group("name"))
        for line_index, line in enumerate(
            repository_lines[jobs_index + 1 :], jobs_index + 1
        )
        if (match := JOB_START.fullmatch(line)) is not None
    ]
    require(
        [name for _line_index, name in job_starts] == ["target-kernel"],
        "target workflow job denominator differs from target-kernel",
    )
    job_lines = repository_lines[job_starts[0][0] :]
    steps_markers = [
        line_index for line_index, line in enumerate(job_lines) if line == "    steps:"
    ]
    require(
        len(steps_markers) == 1,
        "jobs.target-kernel steps sequence is not unique",
    )
    steps_index = steps_markers[0]
    require(
        canonical_step_lines(tuple(job_lines[: steps_index + 1]))
        == TARGET_JOB_CONTROL_LINES,
        "jobs.target-kernel control and identity contract differs",
    )
    return job_lines, job_lines[steps_index + 1 :]


def exact_step_position(
    blocks: list[tuple[str, ...]],
    expected_lines: tuple[str, ...],
) -> int:
    step_header = expected_lines[0]
    matching = [
        (position, block)
        for position, block in enumerate(blocks)
        if block[0].rstrip() == step_header
    ]
    require(
        len(matching) == 1,
        f"target workflow does not contain exactly one step: {step_header}",
    )
    position, block = matching[0]
    require(
        canonical_step_lines(block) == expected_lines,
        f"target workflow step differs from its binding contract: {step_header}",
    )
    return position


def verify_target_workflow(repository: Path) -> None:
    try:
        verify_repository(repository)
    except ActionPinError as error:
        raise TargetWorkflowError(
            f"action-pin contract fails first: {error}"
        ) from error

    verify_gate_producer(repository)

    workflow = repository / TARGET_WORKFLOW
    require(
        workflow.is_file() and not workflow.is_symlink(),
        "target workflow is absent or indirect",
    )
    lines = workflow.read_text(encoding="utf-8").splitlines()
    job_lines, step_lines = target_job(lines)
    blocks = workflow_step_blocks(step_lines)
    resolver_position = exact_step_position(blocks, RESOLVER_STEP_LINES)
    download_position = exact_step_position(blocks, DOWNLOAD_STEP_LINES)
    admission_position = exact_step_position(blocks, ADMISSION_STEP_LINES)
    exact_step_position(blocks, UPLOAD_STEP_LINES)
    require(
        download_position == resolver_position + 1,
        "artifact digest resolution does not immediately precede download",
    )
    require(
        admission_position == download_position + 1,
        "artifact admission does not immediately follow download",
    )

    observed_action_lines = tuple(
        line
        for line in canonical_step_lines(tuple(job_lines))
        if line.startswith("      - uses: ") or line.startswith("        uses: ")
    )
    require(
        observed_action_lines == TARGET_JOB_ACTION_LINES,
        "jobs.target-kernel action denominator differs",
    )

    semantic_lines = [
        line for line in lines if line.strip() and not line.lstrip().startswith("#")
    ]
    require(
        semantic_lines.count("        id: gate-artifact") == 1,
        "gate-artifact step ID is not unique",
    )
    require(
        sum("resolve_workflow_artifact_digest.py" in line for line in semantic_lines)
        == 1,
        "artifact digest resolver invocation is not unique",
    )
    require(
        sum("--expected-sha256" in line for line in semantic_lines) == 1,
        "artifact admission digest input is not unique",
    )


Mutation = Callable[[Path], None]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    require(text.count(old) == 1, "self-test mutation anchor is not unique")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def step_text(lines: tuple[str, ...]) -> str:
    return "\n".join(lines) + "\n"


def expect_rejection(repository: Path, name: str, mutation: Mutation) -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-target-workflow-") as root:
        fixture = Path(root)
        shutil.copytree(repository / ".github", fixture / ".github")
        mutation(fixture / TARGET_WORKFLOW)
        try:
            verify_repository(fixture)
        except ActionPinError as error:
            raise TargetWorkflowError(
                f"{name} fails the action-pin gate before the semantic gate: {error}"
            ) from error
        try:
            verify_target_workflow(fixture)
        except TargetWorkflowError:
            print(f"PASS known-bad: {name}")
            return
        raise TargetWorkflowError(f"self-test accepted known-bad fixture: {name}")


def expect_gate_rejection(
    repository: Path,
    name: str,
    mutation: Mutation,
) -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-gate-workflow-") as root:
        fixture = Path(root)
        shutil.copytree(repository / ".github", fixture / ".github")
        mutation(fixture / GATES_WORKFLOW)
        try:
            verify_target_workflow(fixture)
        except TargetWorkflowError:
            print(f"PASS known-bad: {name}")
            return
        raise TargetWorkflowError(f"self-test accepted known-bad fixture: {name}")


def run_self_test(repository: Path) -> None:
    verify_target_workflow(repository)
    print(
        "PASS known-good: protected-main producer binds the target artifact admission"
    )

    resolver_text = step_text(RESOLVER_STEP_LINES)
    download_text = step_text(DOWNLOAD_STEP_LINES)
    admission_text = step_text(ADMISSION_STEP_LINES)
    upload_text = step_text(UPLOAD_STEP_LINES)
    api_command_text = "\n".join(API_COMMAND_LINES)

    def omit_resolver(path: Path) -> None:
        replace_once(path, resolver_text, "")

    def move_resolver_after_download(path: Path) -> None:
        text = path.read_text(encoding="utf-8")
        require(text.count(resolver_text) == 1, "resolver step anchor is not unique")
        text = text.replace(resolver_text, "", 1)
        admission_index = text.index(admission_text)
        text = text[:admission_index] + resolver_text + text[admission_index:]
        path.write_text(text, encoding="utf-8")

    def local_archive_hash(path: Path) -> None:
        replacement = "\n".join(
            (
                "          expected_sha256=$(sha256sum \\",
                '            "${RUNNER_TEMP}/${ARTIFACT_DOWNLOAD_NAME}/artifact.zip")',
                "          expected_sha256=${expected_sha256%% *}",
            )
        )
        replace_once(path, api_command_text, replacement)

    def shell_derived_digest(path: Path) -> None:
        replace_once(path, api_command_text, "          expected_sha256=$GATE_SHA")

    def wrong_repository(path: Path) -> None:
        replace_once(
            path,
            '            --repository "$GITHUB_REPOSITORY" \\',
            "            --repository owner/other \\",
        )

    def wrong_run(path: Path) -> None:
        replace_once(
            path,
            '            --run-id "$GATE_RUN_ID" \\',
            "            --run-id 1 \\",
        )

    def wrong_artifact_name(path: Path) -> None:
        replace_once(
            path,
            '            --artifact-name "$PACKAGE_ARTIFACT")',
            "            --artifact-name other)",
        )

    def alternate_admission_source(path: Path) -> None:
        replace_once(
            path,
            '            --expected-sha256 "${{ steps.gate-artifact.outputs.sha256 }}"',
            '            --expected-sha256 "$GATE_SHA"',
        )

    def long_target_retention(path: Path) -> None:
        replace_once(
            path, "          retention-days: 7", "          retention-days: 30"
        )

    def missing_target_retention(path: Path) -> None:
        replace_once(path, "          retention-days: 7\n", "")

    def duplicate_resolver(path: Path) -> None:
        replace_once(path, resolver_text, resolver_text + resolver_text)

    def omit_token_binding(path: Path) -> None:
        replace_once(path, "          GITHUB_TOKEN: ${{ github.token }}\n", "")

    def disable_target_job(path: Path) -> None:
        original = "\n".join(TARGET_JOB_CONTROL_LINES[1:5])
        replace_once(
            path,
            original,
            "    if: github.event_name != 'workflow_run'",
        )

    def move_binding_to_sibling(path: Path, condition: str) -> None:
        text = path.read_text(encoding="utf-8")
        for binding_step in (
            resolver_text,
            download_text,
            admission_text,
            upload_text,
        ):
            require(
                text.count(binding_step) == 1,
                "binding step mutation anchor is not unique",
            )
            text = text.replace(binding_step, "", 1)
        local_admission = "\n".join(
            (
                "      - name: Admit a locally hashed artifact",
                "        run: |",
                "          set -euo pipefail",
                '          archive="${RUNNER_TEMP}/${ARTIFACT_DOWNLOAD_NAME}/artifact.zip"',
                '          mkdir -p "$(dirname "$archive")"',
                '          gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts/1/zip" >"$archive"',
                '          expected_sha256=$(sha256sum "$archive")',
                "          expected_sha256=${expected_sha256%% *}",
                "          python3 scripts/admit_target_gate_artifact.py \\",
                '            --download-directory "${RUNNER_TEMP}/${ARTIFACT_DOWNLOAD_NAME}" \\',
                '            --output-directory "${RUNNER_TEMP}/${ARTIFACT_OUTPUT_NAME}" \\',
                '            --expected-sha256 "$expected_sha256"',
            )
        )
        steps_anchor = "    steps:\n"
        require(text.count(steps_anchor) == 1, "target steps anchor is not unique")
        text = text.replace(steps_anchor, steps_anchor + local_admission + "\n\n", 1)
        sibling = "\n".join(
            (
                "  alternate-binding-job:",
                f"    if: {condition}",
                "    runs-on: ubuntu-latest",
                "    steps:",
            )
        )
        text = (
            text.rstrip()
            + "\n\n"
            + sibling
            + "\n"
            + resolver_text
            + download_text
            + admission_text
            + upload_text
        )
        path.write_text(text, encoding="utf-8")

    def disabled_binding_sibling(path: Path) -> None:
        move_binding_to_sibling(path, "github.event_name != 'workflow_run'")

    def alternate_binding_sibling(path: Path) -> None:
        move_binding_to_sibling(path, "github.event_name == 'workflow_run'")

    def package_transport_on_pull_requests(path: Path) -> None:
        replace_once(
            path,
            "        if: always() && github.event_name == 'push'",
            "        if: always()",
        )

    def missing_transport_condition(path: Path) -> None:
        replace_once(
            path,
            "        if: always() && github.event_name == 'push'\n",
            "",
        )

    def inverted_transport_condition(path: Path) -> None:
        replace_once(
            path,
            "        if: always() && github.event_name == 'push'",
            "        if: always() && github.event_name != 'push'",
        )

    def long_package_retention(path: Path) -> None:
        replace_once(
            path, "          retention-days: 7", "          retention-days: 30"
        )

    def long_transition_retention(path: Path) -> None:
        replace_once(
            path, "          retention-days: 1", "          retention-days: 30"
        )

    mutations = (
        ("omitted API resolver", omit_resolver),
        ("resolver moved after download", move_resolver_after_download),
        ("local archive hash", local_archive_hash),
        ("shell-derived digest", shell_derived_digest),
        ("different repository", wrong_repository),
        ("different workflow run", wrong_run),
        ("different artifact name", wrong_artifact_name),
        ("alternate admission digest source", alternate_admission_source),
        ("long target evidence retention", long_target_retention),
        ("missing target evidence retention", missing_target_retention),
        ("duplicate resolver", duplicate_resolver),
        ("missing API token binding", omit_token_binding),
        ("disabled target job", disable_target_job),
        ("binding moved to disabled sibling job", disabled_binding_sibling),
        ("binding moved to alternate job", alternate_binding_sibling),
    )
    for name, mutation in mutations:
        expect_rejection(repository, name, mutation)
    gate_mutations = (
        ("package transport on pull requests", package_transport_on_pull_requests),
        ("missing protected-main transport condition", missing_transport_condition),
        ("inverted protected-main transport condition", inverted_transport_condition),
        ("long package transport retention", long_package_retention),
        ("long transition log retention", long_transition_retention),
    )
    for name, mutation in gate_mutations:
        expect_gate_rejection(repository, name, mutation)
    print(
        "Target artifact workflow calibration: 1 known-good and 20 known-bad fixtures"
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repository = Path(__file__).resolve().parents[1]
    try:
        if arguments.self_test:
            run_self_test(repository)
        else:
            verify_target_workflow(repository)
            print("target artifact workflow: API digest binding verified")
    except (OSError, UnicodeError, TargetWorkflowError) as error:
        print(f"target artifact workflow: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
