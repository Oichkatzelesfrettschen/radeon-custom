#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Fail closed on bounded Namcap diagnostics for Radeon package exports."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

PACKAGE_NAMES = (
    "radeon-unified-dkms",
    "radeon-unified-dkms-dev",
    "radeon-rs482-policy",
)
ARCHITECTURE = "x86_64"
PACKAGE_SUFFIX = ".pkg.tar.zst"
DIAGNOSTIC = re.compile(
    r"^(?P<package>[A-Za-z0-9@._+:-]+) "
    r"(?P<severity>[EWI]): (?P<tag>[a-z0-9-]+)(?: (?P<detail>.*))?$"
)
PKGBUILD_SCALAR = re.compile(
    r"^(?P<key>pkgver|pkgrel)=(?P<value>[A-Za-z0-9_.+-]+)$", re.MULTILINE
)


class PackageQaError(Exception):
    """A Radeon package archive violates the bounded QA contract."""


@dataclass(frozen=True)
class NamcapDiagnostic:
    """One machine-readable Namcap verdict line."""

    package: str
    severity: str
    tag: str
    detail: str


def require(condition: bool, message: str) -> None:
    """Raise a contract error when one invariant is false."""

    if not condition:
        raise PackageQaError(message)


def read_utf8(path: Path) -> str:
    """Read one regular, non-symlink UTF-8 source file."""

    require(
        path.is_file() and not path.is_symlink(),
        f"file is absent or indirect: {path}",
    )
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise PackageQaError(f"cannot read UTF-8 file {path}: {error}") from error


def package_scalar(package_dir: Path, key: str) -> str:
    """Read one scalar PKGBUILD identity field without sourcing it."""

    matches = [
        match.group("value")
        for match in PKGBUILD_SCALAR.finditer(read_utf8(package_dir / "PKGBUILD"))
        if match.group("key") == key
    ]
    require(len(matches) == 1, f"PKGBUILD has no unique {key} scalar")
    return matches[0]


def archive_command(archive: Path, *arguments: str) -> bytes:
    """Run one bsdtar read-only archive operation."""

    try:
        result = subprocess.run(
            ["bsdtar", *arguments, str(archive)],
            check=False,
            capture_output=True,
        )
    except OSError as error:
        raise PackageQaError(f"cannot execute bsdtar: {error}") from error
    require(result.returncode == 0, f"bsdtar rejects package archive: {archive}")
    require(result.stderr == b"", f"bsdtar writes stderr for package: {archive}")
    return result.stdout


def archive_member(archive: Path, member: str) -> str:
    """Return one archive member as UTF-8 text."""

    try:
        result = subprocess.run(
            ["bsdtar", "-xOf", str(archive), member],
            check=False,
            capture_output=True,
        )
    except OSError as error:
        raise PackageQaError(f"cannot execute bsdtar: {error}") from error
    require(
        result.returncode == 0,
        f"archive omits readable member {member}: {archive}",
    )
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PackageQaError(f"archive member is not UTF-8 text: {member}") from error


def archive_members(archive: Path) -> set[str]:
    """Return the normalized nonempty member set of one package archive."""

    try:
        lines = archive_command(archive, "-tf").decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise PackageQaError(f"archive member name is not UTF-8 text: {archive}") from error
    members = {line.removeprefix("./") for line in lines if line != "./"}
    require(
        len(members) == len(lines) - int("./" in lines),
        f"archive repeats a normalized member: {archive}",
    )
    return members


def pkginfo_values(pkginfo: str, key: str) -> list[str]:
    """Return all scalar .PKGINFO values for one key."""

    prefix = f"{key} = "
    return [
        line[len(prefix) :] for line in pkginfo.splitlines() if line.startswith(prefix)
    ]


def parse_namcap(stdout: str) -> tuple[NamcapDiagnostic, ...]:
    """Parse all Namcap warning/error lines and reject output drift."""

    diagnostics: list[NamcapDiagnostic] = []
    for line in stdout.splitlines():
        if not line:
            continue
        match = DIAGNOSTIC.fullmatch(line)
        require(match is not None, f"Namcap emitted an unparseable line: {line}")
        if match.group("severity") == "I":
            continue
        diagnostics.append(
            NamcapDiagnostic(
                package=match.group("package"),
                severity=match.group("severity"),
                tag=match.group("tag"),
                detail=match.group("detail") or "",
            )
        )
    return tuple(diagnostics)


def expected_warnings(package_name: str) -> frozenset[NamcapDiagnostic]:
    """Return the complete semantic Namcap allowlist for one split package."""

    common = NamcapDiagnostic(
        package=package_name,
        severity="W",
        tag="no-elffiles-not-any-package",
        detail="",
    )
    if package_name in {"radeon-unified-dkms", "radeon-unified-dkms-dev"}:
        return frozenset(
            (
                common,
                NamcapDiagnostic(
                    package=package_name,
                    severity="W",
                    tag="dependency-not-needed",
                    detail="dkms",
                ),
            )
        )
    if package_name == "radeon-rs482-policy":
        return frozenset(
            (
                common,
                NamcapDiagnostic(
                    package=package_name,
                    severity="W",
                    tag="dependency-not-needed",
                    detail="radeon-unified",
                ),
            )
        )
    raise PackageQaError(f"unexpected split package name: {package_name}")


def require_expected_diagnostics(diagnostics: Iterable[NamcapDiagnostic]) -> None:
    """Require the exact finite Namcap warning denominator."""

    actual_sequence = tuple(diagnostics)
    actual = frozenset(actual_sequence)
    require(
        len(actual_sequence) == len(actual),
        "Namcap repeats a warning or error diagnostic",
    )
    errors = sorted(
        (diagnostic for diagnostic in actual if diagnostic.severity == "E"),
        key=lambda value: (value.package, value.tag, value.detail),
    )
    require(
        not errors,
        "Namcap reports an error: "
        + "; ".join(
            f"{diagnostic.package}:{diagnostic.tag} {diagnostic.detail}".rstrip()
            for diagnostic in errors
        ),
    )
    expected = frozenset(
        diagnostic
        for package_name in PACKAGE_NAMES
        for diagnostic in expected_warnings(package_name)
    )
    require(
        actual == expected,
        "Namcap warning denominator differs: "
        f"expected={sorted(expected, key=lambda value: (value.package, value.tag, value.detail))}, "
        f"actual={sorted(actual, key=lambda value: (value.package, value.tag, value.detail))}",
    )


def require_archive_semantics(archive: Path, expected_version: str) -> str:
    """Prove the mechanism that makes each permitted warning intentional."""

    require(
        archive.is_file() and not archive.is_symlink(),
        f"package is absent or indirect: {archive}",
    )
    pkginfo = archive_member(archive, ".PKGINFO")
    package_names = pkginfo_values(pkginfo, "pkgname")
    require(len(package_names) == 1, f"package has no unique pkgname: {archive}")
    package_name = package_names[0]
    require(
        package_name in PACKAGE_NAMES, f"unexpected split package name: {package_name}"
    )
    require(
        pkginfo_values(pkginfo, "pkgver") == [expected_version],
        f"{package_name} does not carry expected version {expected_version}",
    )
    require(
        pkginfo_values(pkginfo, "arch") == [ARCHITECTURE],
        f"{package_name} must retain the {ARCHITECTURE} target-archive identity",
    )
    require(
        archive.name
        == f"{package_name}-{expected_version}-{ARCHITECTURE}{PACKAGE_SUFFIX}",
        f"{package_name} archive name does not carry its exact target identity",
    )

    depends = pkginfo_values(pkginfo, "depend")
    members = archive_members(archive)
    if package_name in {"radeon-unified-dkms", "radeon-unified-dkms-dev"}:
        require(
            depends == ["bash", "dkms"],
            f"{package_name} must directly depend on bash and dkms",
        )
        dkms_members = sorted(
            member
            for member in members
            if re.fullmatch(
                r"usr/src/radeon-unified-[A-Za-z0-9_.+-]+/dkms\.conf", member
            )
        )
        require(
            len(dkms_members) == 1,
            f"{package_name} must carry exactly one DKMS configuration",
        )
        require(
            'PACKAGE_NAME="radeon-unified"' in archive_member(archive, dkms_members[0]),
            f"{package_name} DKMS configuration does not name radeon-unified",
        )
    else:
        require(
            depends == [f"radeon-unified={expected_version}"],
            "policy package must bind the matching radeon-unified capability",
        )
        policy_member = "etc/modprobe.d/radeon-re.conf"
        require(policy_member in members, "policy package omits radeon-re.conf")
        require(
            any(
                line.startswith("options radeon ")
                for line in archive_member(archive, policy_member).splitlines()
            ),
            "policy package does not configure the Radeon module",
        )
    return package_name


def resolve_archives(package_dir: Path, supplied: list[Path]) -> tuple[list[Path], str]:
    """Resolve exactly one archive for every split package."""

    version = f"{package_scalar(package_dir, 'pkgver')}-{package_scalar(package_dir, 'pkgrel')}"
    if supplied:
        archives = supplied
    else:
        archives = [
            package_dir / f"{package_name}-{version}-{ARCHITECTURE}{PACKAGE_SUFFIX}"
            for package_name in PACKAGE_NAMES
        ]
    require(
        len(archives) == len(PACKAGE_NAMES), "give exactly three split package archives"
    )
    return archives, version


def verify(package_dir: Path, supplied: list[Path]) -> None:
    """Run Namcap and package-semantic checks against the complete split set."""

    require(shutil.which("namcap") is not None, "namcap is not available")
    archives, expected_version = resolve_archives(package_dir, supplied)
    package_by_path = {
        archive: require_archive_semantics(archive, expected_version)
        for archive in archives
    }
    require(
        set(package_by_path.values()) == set(PACKAGE_NAMES),
        "package archive denominator does not contain every split package exactly once",
    )
    try:
        environment = os.environ.copy()
        # Namcap 3.6.0 leaves internal readers unclosed under Python 3.14.
        # Its default warning policy suppresses that implementation-only
        # ResourceWarning; this gate still rejects every Namcap diagnostic
        # emitted for the package itself.
        environment.pop("PYTHONWARNINGS", None)
        result = subprocess.run(
            ["namcap", "--machine-readable", *(str(archive) for archive in archives)],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            env=environment,
        )
    except (OSError, UnicodeError) as error:
        raise PackageQaError(f"cannot execute Namcap: {error}") from error
    require(
        result.returncode == 0,
        f"Namcap exits {result.returncode}: {result.stderr.strip()}",
    )
    require(result.stderr == "", f"Namcap writes stderr: {result.stderr.strip()}")
    require_expected_diagnostics(parse_namcap(result.stdout))


def expect_rejection(label: str, diagnostics: tuple[NamcapDiagnostic, ...]) -> None:
    """Assert that one synthetic known-bad Namcap result fails the gate."""

    try:
        require_expected_diagnostics(diagnostics)
    except PackageQaError:
        return
    raise PackageQaError(f"{label} passes the Namcap QA gate")


def write_fixture_archive(
    directory: Path, package_name: str, version: str, *, arch: str = ARCHITECTURE
) -> Path:
    """Build one minimal regular-file package fixture without network I/O."""

    root = directory / package_name
    root.mkdir(parents=True)
    depends: list[str]
    if package_name in {"radeon-unified-dkms", "radeon-unified-dkms-dev"}:
        depends = ["bash", "dkms"]
        dkms = root / "usr/src/radeon-unified-0.0/dkms.conf"
        dkms.parent.mkdir(parents=True)
        dkms.write_text('PACKAGE_NAME="radeon-unified"\n', encoding="utf-8")
    else:
        depends = [f"radeon-unified={version}"]
        policy = root / "etc/modprobe.d/radeon-re.conf"
        policy.parent.mkdir(parents=True)
        policy.write_text("options radeon lockup_timeout=0\n", encoding="utf-8")
    pkginfo = [
        f"pkgname = {package_name}",
        f"pkgver = {version}",
        f"arch = {arch}",
        *(f"depend = {dependency}" for dependency in depends),
    ]
    (root / ".PKGINFO").write_text("\n".join(pkginfo) + "\n", encoding="utf-8")
    archive = directory / f"{package_name}-{version}-{ARCHITECTURE}{PACKAGE_SUFFIX}"
    try:
        result = subprocess.run(
            ["bsdtar", "-caf", str(archive), "-C", str(root), "."],
            check=False,
            capture_output=True,
        )
    except OSError as error:
        raise PackageQaError(f"cannot create package fixture: {error}") from error
    require(result.returncode == 0, f"cannot create package fixture: {package_name}")
    return archive


def expect_archive_rejection(label: str, archive: Path, expected: str) -> None:
    """Assert one archive-semantic mutant fails for its intended reason."""

    try:
        require_archive_semantics(archive, "0.0-1")
    except PackageQaError as error:
        require(expected in str(error), f"{label} has wrong diagnostic: {error}")
        return
    raise PackageQaError(f"{label} passes the archive QA gate")


def run_self_test() -> None:
    """Calibrate exact warning, error, and output-drift rejection."""

    known_good = tuple(
        diagnostic
        for package_name in PACKAGE_NAMES
        for diagnostic in expected_warnings(package_name)
    )
    require_expected_diagnostics(known_good)
    expect_rejection(
        "unexpected warning",
        known_good
        + (
            NamcapDiagnostic(
                package="radeon-unified-dkms",
                severity="W",
                tag="dependency-detected-not-included",
                detail="unsafe-runtime",
            ),
        ),
    )
    expect_rejection("missing semantic warning", known_good[1:])
    expect_rejection(
        "Namcap error",
        known_good
        + (
            NamcapDiagnostic(
                package="radeon-unified-dkms",
                severity="E",
                tag="dependency-detected-not-included",
                detail="unsafe-runtime",
            ),
        ),
    )
    try:
        parse_namcap("radeon-unified-dkms malformed\n")
    except PackageQaError:
        pass
    else:
        raise PackageQaError("malformed Namcap output passes the QA gate")

    with tempfile.TemporaryDirectory(prefix="radeon-package-qa.") as temporary:
        fixture_root = Path(temporary)
        for package_name in PACKAGE_NAMES:
            archive = write_fixture_archive(fixture_root, package_name, "0.0-1")
            require_archive_semantics(archive, "0.0-1")

        bad_arch_root = fixture_root / "bad-arch"
        bad_arch = write_fixture_archive(
            bad_arch_root, "radeon-unified-dkms", "0.0-1", arch="any"
        )
        expect_archive_rejection("non-x86 archive", bad_arch, "target-archive identity")

        bad_dkms_root = fixture_root / "bad-dkms"
        bad_dkms = write_fixture_archive(
            bad_dkms_root, "radeon-unified-dkms-dev", "0.0-1"
        )
        extracted = bad_dkms_root / "radeon-unified-dkms-dev"
        (extracted / "usr/src/radeon-unified-0.0/dkms.conf").unlink()
        bad_dkms.unlink()
        try:
            result = subprocess.run(
                ["bsdtar", "-caf", str(bad_dkms), "-C", str(extracted), "."],
                check=False,
                capture_output=True,
            )
        except OSError as error:
            raise PackageQaError(f"cannot create DKMS mutant: {error}") from error
        require(result.returncode == 0, "cannot create DKMS mutant")
        expect_archive_rejection(
            "missing DKMS configuration", bad_dkms, "DKMS configuration"
        )

        bad_policy_root = fixture_root / "bad-policy"
        bad_policy = write_fixture_archive(
            bad_policy_root, "radeon-rs482-policy", "0.0-1"
        )
        extracted = bad_policy_root / "radeon-rs482-policy"
        pkginfo = extracted / ".PKGINFO"
        pkginfo.write_text(
            pkginfo.read_text(encoding="utf-8").replace(
                "depend = radeon-unified=0.0-1", "depend = radeon-unified=0.0-2"
            ),
            encoding="utf-8",
        )
        bad_policy.unlink()
        try:
            result = subprocess.run(
                ["bsdtar", "-caf", str(bad_policy), "-C", str(extracted), "."],
                check=False,
                capture_output=True,
            )
        except OSError as error:
            raise PackageQaError(f"cannot create policy mutant: {error}") from error
        require(result.returncode == 0, "cannot create policy mutant")
        expect_archive_rejection(
            "wrong policy capability", bad_policy, "matching radeon-unified capability"
        )

    print("Radeon package QA calibration: 1 known-good and 7 known-bad fixtures")


def parse_arguments() -> argparse.Namespace:
    """Parse the offline archive QA command line."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-dir", type=Path)
    parser.add_argument("--package", type=Path, action="append", default=[])
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    """Run the requested calibration or package QA verdict."""

    arguments = parse_arguments()
    repository = Path(__file__).resolve().parents[1]
    package_dir = arguments.package_dir or (
        repository / "packaging/arch/radeon-unified-dkms"
    )
    try:
        if arguments.self_test:
            require(not arguments.package, "--self-test does not accept --package")
            run_self_test()
        else:
            verify(package_dir, arguments.package)
            print(
                "Radeon package QA: PASS (3 archives, exact Namcap warning denominator)"
            )
    except PackageQaError as error:
        print(f"check_radeon_package_qa: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
