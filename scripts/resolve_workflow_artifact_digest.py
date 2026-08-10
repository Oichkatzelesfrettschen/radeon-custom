#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Resolve one workflow artifact SHA-256 from the GitHub Actions API."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Callable
from typing import cast
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


API_VERSION = "2022-11-28"
ARTIFACTS_PER_PAGE = 100
MAXIMUM_ARTIFACT_COUNT = 10_000
MAXIMUM_RESPONSE_BYTES = 8 * 1024 * 1024
REPOSITORY_NAME = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
SHA256_DIGEST = re.compile(r"sha256:([0-9a-f]{64})\Z")


class ArtifactDigestError(Exception):
    """The workflow artifact metadata violates the digest contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ArtifactDigestError(message)


def validate_request_identity(
    repository: str,
    run_id: int,
    artifact_name: str,
) -> None:
    require(
        REPOSITORY_NAME.fullmatch(repository) is not None,
        "repository must have the OWNER/REPOSITORY form",
    )
    require(run_id > 0, "workflow run ID must be positive")
    try:
        artifact_name.encode("ascii")
    except UnicodeEncodeError as error:
        raise ArtifactDigestError("artifact name must be ASCII") from error
    require(artifact_name != "", "artifact name must be nonempty")
    require(len(artifact_name) <= 255, "artifact name exceeds 255 bytes")


def artifact_page_url(repository: str, run_id: int, page_number: int) -> str:
    owner, repository_name = repository.split("/", 1)
    query = urlencode(
        {
            "per_page": ARTIFACTS_PER_PAGE,
            "page": page_number,
        }
    )
    return (
        "https://api.github.com/repos/"
        f"{quote(owner, safe='')}/{quote(repository_name, safe='')}"
        f"/actions/runs/{run_id}/artifacts?{query}"
    )


def fetch_artifact_page(
    repository: str,
    run_id: int,
    token: str,
    page_number: int,
) -> object:
    request = Request(
        artifact_page_url(repository, run_id, page_number),
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "radeon-custom-artifact-digest-resolver",
            "X-GitHub-Api-Version": API_VERSION,
        },
    )
    # artifact_page_url fixes the scheme and authority to https://api.github.com.
    with urlopen(request, timeout=30) as response:  # nosec B310
        response_bytes = response.read(MAXIMUM_RESPONSE_BYTES + 1)
    require(
        len(response_bytes) <= MAXIMUM_RESPONSE_BYTES,
        "artifact API response exceeds the byte limit",
    )
    try:
        payload: object = json.loads(response_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ArtifactDigestError("artifact API response is not valid JSON") from error
    return payload


ArtifactPageFetcher = Callable[[int], object]


def resolve_artifact_digest(
    fetch_page: ArtifactPageFetcher,
    run_id: int,
    artifact_name: str,
) -> str:
    expected_total: int | None = None
    observed_count = 0
    observed_ids: set[int] = set()
    matching_rows: list[dict[str, object]] = []
    page_number = 1

    while True:
        raw_page = fetch_page(page_number)
        require(isinstance(raw_page, dict), "artifact API page must be an object")
        page = cast(dict[str, object], raw_page)
        raw_total = page.get("total_count")
        require(
            type(raw_total) is int and raw_total >= 0,
            "artifact API total_count must be a nonnegative integer",
        )
        page_total = cast(int, raw_total)
        require(
            page_total <= MAXIMUM_ARTIFACT_COUNT,
            "artifact API total_count exceeds the admission limit",
        )
        if expected_total is None:
            expected_total = page_total
        else:
            require(
                page_total == expected_total,
                "artifact API total_count changes between pages",
            )

        raw_artifacts = page.get("artifacts")
        require(
            isinstance(raw_artifacts, list),
            "artifact API artifacts field must be an array",
        )
        artifacts = cast(list[object], raw_artifacts)
        require(
            len(artifacts) <= ARTIFACTS_PER_PAGE,
            "artifact API page exceeds the requested page size",
        )

        for raw_artifact in artifacts:
            require(
                isinstance(raw_artifact, dict),
                "artifact API row must be an object",
            )
            artifact = cast(dict[str, object], raw_artifact)
            raw_artifact_id = artifact.get("id")
            require(
                type(raw_artifact_id) is int and raw_artifact_id > 0,
                "artifact API row ID must be a positive integer",
            )
            artifact_id = cast(int, raw_artifact_id)
            require(
                artifact_id not in observed_ids,
                "artifact API repeats an artifact ID",
            )
            observed_ids.add(artifact_id)
            observed_count += 1
            require(
                observed_count <= page_total,
                "artifact API returns more rows than total_count",
            )
            name = artifact.get("name")
            require(isinstance(name, str), "artifact API row name must be text")
            if name == artifact_name:
                matching_rows.append(artifact)

        if observed_count == page_total:
            break
        require(
            len(artifacts) == ARTIFACTS_PER_PAGE,
            "artifact API page ends before total_count rows arrive",
        )
        page_number += 1

    require(
        expected_total == observed_count,
        "artifact API row count differs from total_count",
    )
    require(
        len(matching_rows) == 1,
        "workflow run does not contain exactly one named artifact",
    )
    artifact = matching_rows[0]
    require(artifact.get("expired") is False, "workflow artifact is expired")
    raw_size = artifact.get("size_in_bytes")
    require(
        type(raw_size) is int and raw_size > 0,
        "workflow artifact size must be positive",
    )
    raw_workflow_run = artifact.get("workflow_run")
    require(
        isinstance(raw_workflow_run, dict),
        "workflow artifact lacks workflow-run identity",
    )
    workflow_run = cast(dict[str, object], raw_workflow_run)
    require(
        workflow_run.get("id") == run_id,
        "workflow artifact names a different workflow run",
    )
    raw_digest = artifact.get("digest")
    if not isinstance(raw_digest, str):
        raise ArtifactDigestError("workflow artifact lacks a digest")
    digest_match = SHA256_DIGEST.fullmatch(raw_digest)
    if digest_match is None:
        raise ArtifactDigestError("workflow artifact digest is not a canonical SHA-256")
    return digest_match.group(1)


def artifact_row(
    artifact_id: int,
    name: str,
    run_id: int,
    *,
    digest: str = "sha256:" + "a" * 64,
    expired: bool = False,
    size_in_bytes: int = 1,
) -> dict[str, object]:
    return {
        "id": artifact_id,
        "name": name,
        "expired": expired,
        "size_in_bytes": size_in_bytes,
        "digest": digest,
        "workflow_run": {"id": run_id},
    }


def expect_rejection(
    name: str,
    fetch_page: ArtifactPageFetcher,
    run_id: int,
    artifact_name: str,
    expected_message: str,
) -> None:
    try:
        resolve_artifact_digest(fetch_page, run_id, artifact_name)
    except ArtifactDigestError as error:
        require(
            expected_message in str(error),
            f"{name} rejected for an unexpected reason: {error}",
        )
        print(f"PASS known-bad: {name}")
        return
    raise ArtifactDigestError(f"self-test accepted known-bad fixture: {name}")


def run_self_test() -> None:
    run_id = 31363913273
    artifact_name = "radeon-unified-deadbeef-31363913273"
    first_page_rows = [
        artifact_row(row_id, f"evidence-{row_id}", run_id)
        for row_id in range(1, ARTIFACTS_PER_PAGE + 1)
    ]
    target = artifact_row(101, artifact_name, run_id)
    requested_pages: list[int] = []

    def paginated_good(page_number: int) -> object:
        requested_pages.append(page_number)
        if page_number == 1:
            return {"total_count": 101, "artifacts": first_page_rows}
        if page_number == 2:
            return {"total_count": 101, "artifacts": [target]}
        raise ArtifactDigestError("self-test requested an unexpected page")

    require(
        resolve_artifact_digest(paginated_good, run_id, artifact_name) == "a" * 64,
        "known-good artifact digest differs",
    )
    require(requested_pages == [1, 2], "known-good pagination differs")
    require(
        artifact_page_url("owner/repository", run_id, 2)
        == "https://api.github.com/repos/owner/repository/actions/runs/"
        "31363913273/artifacts?per_page=100&page=2",
        "artifact API URL differs",
    )
    print("PASS known-good: exact artifact digest across two API pages")

    def one_page(rows: list[object], total: int | None = None) -> ArtifactPageFetcher:
        page_total = len(rows) if total is None else total
        return lambda _page_number: {
            "total_count": page_total,
            "artifacts": rows,
        }

    expect_rejection(
        "missing named artifact",
        one_page([artifact_row(1, "other", run_id)]),
        run_id,
        artifact_name,
        "exactly one named artifact",
    )
    expect_rejection(
        "duplicate named artifact",
        one_page(
            [
                artifact_row(1, artifact_name, run_id),
                artifact_row(2, artifact_name, run_id),
            ]
        ),
        run_id,
        artifact_name,
        "exactly one named artifact",
    )
    expect_rejection(
        "expired artifact",
        one_page([artifact_row(1, artifact_name, run_id, expired=True)]),
        run_id,
        artifact_name,
        "artifact is expired",
    )
    expect_rejection(
        "empty artifact",
        one_page([artifact_row(1, artifact_name, run_id, size_in_bytes=0)]),
        run_id,
        artifact_name,
        "size must be positive",
    )
    expect_rejection(
        "noncanonical digest",
        one_page([artifact_row(1, artifact_name, run_id, digest="sha256:" + "A" * 64)]),
        run_id,
        artifact_name,
        "not a canonical SHA-256",
    )
    expect_rejection(
        "different workflow run",
        one_page([artifact_row(1, artifact_name, run_id + 1)]),
        run_id,
        artifact_name,
        "different workflow run",
    )
    expect_rejection(
        "duplicate artifact ID",
        one_page(
            [
                artifact_row(1, "other", run_id),
                artifact_row(1, artifact_name, run_id),
            ]
        ),
        run_id,
        artifact_name,
        "repeats an artifact ID",
    )
    expect_rejection(
        "short artifact page",
        one_page([artifact_row(1, artifact_name, run_id)], total=2),
        run_id,
        artifact_name,
        "page ends before total_count",
    )
    expect_rejection(
        "excessive artifact count",
        one_page([], total=MAXIMUM_ARTIFACT_COUNT + 1),
        run_id,
        artifact_name,
        "total_count exceeds",
    )
    expect_rejection(
        "malformed response root",
        lambda _page_number: [],
        run_id,
        artifact_name,
        "page must be an object",
    )
    expect_rejection(
        "malformed artifacts field",
        lambda _page_number: {"total_count": 1, "artifacts": {}},
        run_id,
        artifact_name,
        "artifacts field must be an array",
    )

    def changing_total(page_number: int) -> object:
        if page_number == 1:
            return {"total_count": 101, "artifacts": first_page_rows}
        return {"total_count": 102, "artifacts": [target]}

    expect_rejection(
        "changing total count",
        changing_total,
        run_id,
        artifact_name,
        "total_count changes between pages",
    )
    print(
        "Workflow artifact digest calibration: 1 known-good and 12 known-bad fixtures"
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--repository")
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--artifact-name")
    arguments = parser.parse_args()
    operational_values = (
        arguments.repository,
        arguments.run_id,
        arguments.artifact_name,
    )
    if arguments.self_test:
        if any(value is not None for value in operational_values):
            parser.error("--self-test does not accept workflow artifact identity")
    elif any(value is None for value in operational_values):
        parser.error(
            "operational mode requires --repository, --run-id, and --artifact-name"
        )
    return arguments


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.self_test:
            run_self_test()
        else:
            validate_request_identity(
                arguments.repository,
                arguments.run_id,
                arguments.artifact_name,
            )
            token = os.environ.get("GITHUB_TOKEN", "")
            require(bool(token), "GITHUB_TOKEN is empty")
            digest = resolve_artifact_digest(
                lambda page_number: fetch_artifact_page(
                    arguments.repository,
                    arguments.run_id,
                    token,
                    page_number,
                ),
                arguments.run_id,
                arguments.artifact_name,
            )
            print(digest)
    except (ArtifactDigestError, HTTPError, URLError, OSError) as error:
        print(f"workflow artifact digest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
