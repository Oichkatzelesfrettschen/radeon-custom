#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bind package authority documentation to executable package inputs."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

PKGBUILD_PATH = Path("packaging/arch/radeon-unified-dkms/PKGBUILD")
PACKAGE_README_PATH = Path("packaging/arch/radeon-unified-dkms/README.md")
DKMS_PATHS = (
    Path("packaging/arch/radeon-unified-dkms/dkms.conf.prod"),
    Path("packaging/arch/radeon-unified-dkms/dkms.conf.dev"),
)
VERSION_LITERAL = re.compile(r"\b\d+\.\d+\.\d+(?:-\d+)?\b")
HISTORICAL_IDENTITIES = (
    ("0.8.3-1", "74cc62c478bd11778ae398d6d1e5f5f43a12fa7a", "4d5217ea558320801dde0ef8ce2d8ffdb7a21ba9"),
    ("0.8.4-1", "ca6bad052ceb718ce0814c020f71f01c710dbe0e", "cf89588ab90a763e30cd00b9cfcdf9b7291fe660"),
    ("0.8.5-1", "cc91fbcccfca4478e5f8f1b505a52da74c7af6fe", "dc473f6f0010805a5a5ecb0ad9445417f43f72b8"),
    ("0.8.6-1", "e03c1d27ba93caae59165cc61726bdca479dc402", "373a2e54129588df7b477519dd2f28370e4ecee5"),
    ("0.8.7-1", "e2528ea1a0a90f618e699fa62b4b925e06045233", "d670e3e85d162ae1a183f37deb3bae2c0d644d9d"),
    ("0.8.8-1", "2e704981b744fba5cbece0d5857c214832738326", "7996162539e0b1f314edcf77e8c01a5b54c0750c"),
    ("0.8.9-1", "164167950d0f749468474536dd76045fddedc8b7", "a50c8ce2bc6c7645c7fe658470f67dbe2e93c31f"),
)
PATCH_SUMMARY = re.compile(
    r"patch-series gate calibration: "
    r"(?P<bad>\d+) known-bad rejected, (?P<good>\d+) known-good cleared"
)
TARGET_SUMMARY = re.compile(
    r"Target artifact workflow calibration: "
    r"(?P<good>\d+) known-good and (?P<bad>\d+) known-bad fixtures"
)


class AuthorityError(Exception):
    """Package authority declarations disagree."""


@dataclass(frozen=True)
class PackageIdentity:
    version: str
    source_commit: str
    driver_tree: str
    profiled_source_tag: str


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuthorityError(message)


def unique_match(pattern: str, text: str, label: str) -> str:
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    require(len(matches) == 1, f"{label} declaration is not unique")
    return matches[0]


def parse_pkgbuild(text: str) -> PackageIdentity:
    pkgver = unique_match(r"^pkgver=([0-9]+\.[0-9]+\.[0-9]+)$", text, "pkgver")
    pkgrel = unique_match(r"^pkgrel=([0-9]+)$", text, "pkgrel")
    source_commit = unique_match(
        r"^_source_commit='([0-9a-f]{40})'$", text, "source commit"
    )
    driver_tree = unique_match(
        r"^_source_driver_tree='([0-9a-f]{40})'$", text, "driver tree"
    )
    profiled_source_tag = unique_match(
        r"^_profiled_source_tag='([^']+)'$", text, "profiled source tag"
    )
    return PackageIdentity(
        version=f"{pkgver}-{pkgrel}",
        source_commit=source_commit,
        driver_tree=driver_tree,
        profiled_source_tag=profiled_source_tag,
    )


def parse_dkms_version(text: str, label: str) -> str:
    return unique_match(
        r'^PACKAGE_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$', text, label
    )


def parse_calibration_summary(
    output: str,
    pattern: re.Pattern[str],
    label: str,
) -> tuple[int, int]:
    matches = list(pattern.finditer(output))
    require(len(matches) == 1, f"{label} summary is not unique")
    match = matches[0]
    return int(match.group("good")), int(match.group("bad"))


def verify_texts(
    pkgbuild: str,
    dkms_texts: tuple[str, str],
    root_readme: str,
    package_readme: str,
    patch_counts: tuple[int, int],
    target_counts: tuple[int, int],
) -> None:
    identity = parse_pkgbuild(pkgbuild)
    pkgver = identity.version.rsplit("-", 1)[0]
    for path, text in zip(DKMS_PATHS, dkms_texts, strict=True):
        require(
            parse_dkms_version(text, str(path)) == pkgver,
            f"{path}: PACKAGE_VERSION disagrees with PKGBUILD",
        )

    active_row_marker = (
        f"| Radeon DKMS package recipe {identity.version} is the active package authority"
    )
    active_rows = [
        line for line in root_readme.splitlines() if active_row_marker in line
    ]
    require(len(active_rows) == 1, "root README active package row is not unique")
    active_row = active_rows[0]
    for value, label in (
        (identity.source_commit, "source commit"),
        (identity.driver_tree, "driver tree"),
        (identity.profiled_source_tag, "profiled source tag"),
    ):
        require(value in active_row, f"active package row omits {label}")

    ledger_header = root_readme.split("| Property |", 1)[0]
    normalized_header = re.sub(r"\s+", " ", ledger_header)
    current_versions = re.findall(
        r"Version (\d+\.\d+\.\d+-\d+) is the active package recipe",
        ledger_header,
    )
    require(
        current_versions == [identity.version],
        "root README active recipe declaration disagrees with PKGBUILD",
    )
    require(
        f"The {identity.version} row is the current recipe record."
        in normalized_header,
        "root README current recipe record disagrees with PKGBUILD",
    )
    require(
        "version 0.8.8-1 carries the newest recorded target run pending a retained bundle join"
        in normalized_header,
        "root README newest recorded target run is not bound",
    )
    for version, source_commit, driver_tree in HISTORICAL_IDENTITIES:
        rows = [line for line in root_readme.splitlines() if f"package {version} " in line or f"recipe {version} " in line or f"candidate {version} " in line]
        require(len(rows) == 1, f"historical package row {version} is not unique")
        require(source_commit in rows[0] and driver_tree in rows[0], f"historical package row {version} identity disagrees")

    require(
        "Root `README.md` owns the package qualification ledger" in package_readme,
        "package README does not point to the root qualification ledger",
    )
    qualification = (
        "## Qualification authority\n\n"
        "Root `README.md` owns the package qualification ledger and the active package\n"
        "identity. This package README owns build and verification mechanics and carries\n"
        "no independent promotion record.\n"
    )
    require(package_readme.count(qualification) == 1, "package qualification authority block differs")
    artifact_derivation = (
        'package_version="${pkgver}-${pkgrel}"\n'
        'prod_package="$package_dir/radeon-unified-dkms-${package_version}-x86_64.pkg.tar.zst"\n'
        'dev_package="$package_dir/radeon-unified-dkms-dev-${package_version}-x86_64.pkg.tar.zst"\n'
        'policy_package="$package_dir/radeon-rs482-policy-${package_version}-x86_64.pkg.tar.zst"'
    )
    require(package_readme.count(artifact_derivation) == 1, "package artifact derivation differs")

    patch_good, patch_bad = patch_counts
    require(
        f"# {patch_bad} known-bad inputs rejected, {patch_good} known-good inputs cleared"
        in root_readme,
        "root README patch calibration count disagrees with the self-test",
    )
    target_good, target_bad = target_counts
    require(
        f"# One target workflow passes, and {target_bad} producer, digest, transport, and retention mutations fail"
        in root_readme
        and target_good == 1,
        "root README target workflow count disagrees with the self-test",
    )


def run_command(repository: Path, command: list[str]) -> str:
    result = subprocess.run(
        command,
        cwd=repository,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    require(result.returncode == 0, f"calibration command fails: {' '.join(command)}")
    return result.stdout


def repository_inputs(repository: Path) -> tuple[str, tuple[str, str], str, str]:
    return (
        (repository / PKGBUILD_PATH).read_text(encoding="utf-8"),
        tuple(
            (repository / path).read_text(encoding="utf-8") for path in DKMS_PATHS
        ),
        (repository / "README.md").read_text(encoding="utf-8"),
        (repository / PACKAGE_README_PATH).read_text(encoding="utf-8"),
    )


def current_counts(repository: Path) -> tuple[tuple[int, int], tuple[int, int]]:
    patch_output = run_command(
        repository, ["sh", "scripts/check_radeon_patch_series_compiles.sh", "--self-test"]
    )
    target_output = run_command(
        repository, ["python3", "scripts/check_target_artifact_workflow.py", "--self-test"]
    )
    return (
        parse_calibration_summary(patch_output, PATCH_SUMMARY, "patch calibration"),
        parse_calibration_summary(target_output, TARGET_SUMMARY, "target calibration"),
    )


Mutation = Callable[[dict[str, object]], None]


def replace_once(text: str, old: str, new: str) -> str:
    require(text.count(old) == 1, "self-test mutation anchor is not unique")
    return text.replace(old, new, 1)


def run_self_test(repository: Path) -> None:
    pkgbuild, dkms_texts, root_readme, package_readme = repository_inputs(repository)
    patch_counts, target_counts = current_counts(repository)
    fixture: dict[str, object] = {
        "pkgbuild": pkgbuild,
        "dkms_texts": dkms_texts,
        "root_readme": root_readme,
        "package_readme": package_readme,
        "patch_counts": patch_counts,
        "target_counts": target_counts,
    }

    def verify_fixture(values: dict[str, object]) -> None:
        verify_texts(
            str(values["pkgbuild"]),
            values["dkms_texts"],  # type: ignore[arg-type]
            str(values["root_readme"]),
            str(values["package_readme"]),
            values["patch_counts"],  # type: ignore[arg-type]
            values["target_counts"],  # type: ignore[arg-type]
        )

    verify_fixture(fixture)
    print("PASS known-good: executable package identity matches its documentation")
    identity = parse_pkgbuild(pkgbuild)
    pkgver = identity.version.rsplit("-", 1)[0]
    active_row = next(
        line
        for line in root_readme.splitlines()
        if f"recipe {identity.version} is the active package authority" in line
    )

    def mutate_dkms_prod(values: dict[str, object]) -> None:
        prod, dev = values["dkms_texts"]  # type: ignore[misc]
        values["dkms_texts"] = (
            prod.replace(
                f'PACKAGE_VERSION="{pkgver}"', 'PACKAGE_VERSION="0.0.0"'
            ),
            dev,
        )

    def mutate_dkms_dev(values: dict[str, object]) -> None:
        prod, dev = values["dkms_texts"]  # type: ignore[misc]
        values["dkms_texts"] = (
            prod,
            dev.replace(
                f'PACKAGE_VERSION="{pkgver}"', 'PACKAGE_VERSION="0.0.0"'
            ),
        )

    def omit_pkgbuild_identity(values: dict[str, object]) -> None:
        values["pkgbuild"] = re.sub(r"^_source_driver_tree=.*\n", "", str(values["pkgbuild"]), count=1, flags=re.MULTILINE)

    def omit_active_row(values: dict[str, object]) -> None:
        values["root_readme"] = str(values["root_readme"]).replace(active_row + "\n", "", 1)

    def duplicate_active_row(values: dict[str, object]) -> None:
        values["root_readme"] = str(values["root_readme"]) + "\n" + active_row + "\n"

    def omit_active_commit(values: dict[str, object]) -> None:
        changed_row = active_row.replace(identity.source_commit, "0" * 40)
        values["root_readme"] = replace_once(
            str(values["root_readme"]), active_row, changed_row
        )

    def omit_active_tree(values: dict[str, object]) -> None:
        changed_row = active_row.replace(identity.driver_tree, "1" * 40)
        values["root_readme"] = replace_once(
            str(values["root_readme"]), active_row, changed_row
        )

    def omit_active_tag(values: dict[str, object]) -> None:
        changed_row = active_row.replace(
            identity.profiled_source_tag, "wrong-profiled-source-tag"
        )
        values["root_readme"] = replace_once(
            str(values["root_readme"]), active_row, changed_row
        )

    def stale_header(values: dict[str, object]) -> None:
        values["root_readme"] = replace_once(str(values["root_readme"]), f"Version {identity.version} is the active package recipe", "Version 0.0.0-0 is the active package recipe")

    def omit_package_link(values: dict[str, object]) -> None:
        values["package_readme"] = str(values["package_readme"]).replace("Root `README.md` owns the package qualification ledger", "Package qualification is recorded elsewhere", 1)

    def duplicate_package_ledger(values: dict[str, object]) -> None:
        values["package_readme"] = str(values["package_readme"]) + "\n" + (
            "## Qualification authority\n\n"
            "Root `README.md` owns the package qualification ledger and the active package\n"
            "identity. This package README owns build and verification mechanics and carries\n"
            "no independent promotion record.\n"
        )

    def hardcode_artifact(values: dict[str, object]) -> None:
        values["package_readme"] = str(values["package_readme"]).replace(
            'package_version="${pkgver}-${pkgrel}"',
            'package_version="${pkgver}-2"',
            1,
        )

    def wrong_artifact_basename(values: dict[str, object]) -> None:
        values["package_readme"] = str(values["package_readme"]).replace(
            'prod_package="$package_dir/radeon-unified-dkms-${package_version}',
            'prod_package="$package_dir/radeon-unified-target-${package_version}',
            1,
        )

    def corrupt_historical_identity(values: dict[str, object]) -> None:
        values["root_readme"] = str(values["root_readme"]).replace(
            HISTORICAL_IDENTITIES[-2][1], "0" * 40, 1
        )

    def stale_newest_target(values: dict[str, object]) -> None:
        values["root_readme"] = str(values["root_readme"]).replace(
            "version 0.8.8-1 carries the newest recorded target run",
            "version 0.8.3-1 carries the newest recorded target run",
            1,
        )

    def drift_patch_count(values: dict[str, object]) -> None:
        good, bad = values["patch_counts"]  # type: ignore[misc]
        values["patch_counts"] = (good, bad + 1)

    def drift_target_count(values: dict[str, object]) -> None:
        good, bad = values["target_counts"]  # type: ignore[misc]
        values["target_counts"] = (good, bad + 1)

    mutations: tuple[tuple[str, Mutation], ...] = (
        ("production DKMS version drift", mutate_dkms_prod),
        ("development DKMS version drift", mutate_dkms_dev),
        ("missing PKGBUILD identity", omit_pkgbuild_identity),
        ("missing active package row", omit_active_row),
        ("duplicate active package row", duplicate_active_row),
        ("active source commit drift", omit_active_commit),
        ("active driver tree drift", omit_active_tree),
        ("active source tag drift", omit_active_tag),
        ("stale active recipe header", stale_header),
        ("missing canonical ledger link", omit_package_link),
        ("duplicate package qualification ledger", duplicate_package_ledger),
        ("hardcoded artifact version", hardcode_artifact),
        ("wrong artifact basename", wrong_artifact_basename),
        ("historical identity drift", corrupt_historical_identity),
        ("stale newest target record", stale_newest_target),
        ("patch calibration count drift", drift_patch_count),
        ("target calibration count drift", drift_target_count),
    )
    rejected = 0
    for name, mutation in mutations:
        changed = dict(fixture)
        mutation(changed)
        try:
            verify_fixture(changed)
        except AuthorityError:
            rejected += 1
            print(f"PASS known-bad: {name}")
        else:
            raise AuthorityError(f"self-test accepts known-bad fixture: {name}")
    print(
        "package authority documentation calibration: "
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
            pkgbuild, dkms_texts, root_readme, package_readme = repository_inputs(
                repository
            )
            patch_counts, target_counts = current_counts(repository)
            verify_texts(
                pkgbuild,
                dkms_texts,
                root_readme,
                package_readme,
                patch_counts,
                target_counts,
            )
            print("package authority documentation matches executable inputs")
    except (AuthorityError, OSError, UnicodeError) as error:
        print(f"package authority documentation: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
