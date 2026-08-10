#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Admit one production package from a raw GitHub artifact archive."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
import tempfile
import warnings
import zipfile
from collections.abc import Callable, Iterable
from pathlib import Path


MAXIMUM_PACKAGE_BYTES = 512 * 1024 * 1024
PRODUCTION_PACKAGE_NAME = re.compile(
    r"radeon-unified-dkms-(?!dev-).+\.pkg\.tar\.zst\Z"
)


class ArtifactAdmissionError(Exception):
    """The downloaded artifact violates the target admission contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ArtifactAdmissionError(message)


def canonical_member_name(member: zipfile.ZipInfo) -> str:
    name = member.filename
    try:
        name.encode("ascii")
    except UnicodeEncodeError as error:
        raise ArtifactAdmissionError(
            f"archive member name is not ASCII: {name!r}"
        ) from error
    require(name != "", "archive contains an empty member name")
    require("\\" not in name, f"archive member uses a backslash: {name}")
    require(not name.startswith("/"), f"archive member is absolute: {name}")

    components = name.split("/")
    if member.is_dir() and components[-1] == "":
        components.pop()
    require(
        bool(components) and all(components),
        f"archive member contains an empty path component: {name}",
    )
    require(
        all(component not in {".", ".."} for component in components),
        f"archive member contains a relative traversal component: {name}",
    )
    require(
        re.fullmatch(r"[A-Za-z]:", components[0]) is None,
        f"archive member uses a drive-qualified path: {name}",
    )
    return "/".join(components)


def validate_member_type(member: zipfile.ZipInfo, canonical_name: str) -> None:
    require(
        member.flag_bits & 0x1 == 0,
        f"archive member is encrypted: {canonical_name}",
    )
    require(
        member.compress_type in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED},
        f"archive member uses an unsupported compression method: {canonical_name}",
    )
    unix_mode = member.external_attr >> 16
    file_type = stat.S_IFMT(unix_mode)
    if member.is_dir():
        require(
            file_type in {0, stat.S_IFDIR},
            f"archive directory has a conflicting file type: {canonical_name}",
        )
        return
    require(
        file_type in {0, stat.S_IFREG},
        f"archive member is not a regular file: {canonical_name}",
    )


def select_production_package(
    members: Iterable[zipfile.ZipInfo],
) -> zipfile.ZipInfo:
    seen_names: set[str] = set()
    package_candidates: list[zipfile.ZipInfo] = []
    member_count = 0
    for member in members:
        member_count += 1
        canonical_name = canonical_member_name(member)
        require(
            canonical_name not in seen_names,
            f"archive contains a duplicate member name: {canonical_name}",
        )
        seen_names.add(canonical_name)
        validate_member_type(member, canonical_name)
        if not member.is_dir() and PRODUCTION_PACKAGE_NAME.fullmatch(
            canonical_name.rsplit("/", 1)[-1]
        ):
            package_candidates.append(member)

    require(member_count > 0, "artifact archive has no members")
    require(
        len(package_candidates) == 1,
        "artifact archive does not contain exactly one production package",
    )
    package = package_candidates[0]
    require(package.file_size > 0, "production package member is empty")
    require(
        package.file_size <= MAXIMUM_PACKAGE_BYTES,
        "production package member exceeds the admission limit",
    )
    return package


def one_downloaded_archive(download_directory: Path) -> Path:
    require(
        download_directory.is_dir() and not download_directory.is_symlink(),
        "download directory is absent or indirect",
    )
    entries = list(download_directory.iterdir())
    require(
        len(entries) == 1,
        "download directory does not contain exactly one entry",
    )
    archive = entries[0]
    archive_status = archive.lstat()
    require(
        stat.S_ISREG(archive_status.st_mode),
        "downloaded artifact is not a direct regular file",
    )
    return archive


def admit_artifact(download_directory: Path, output_directory: Path) -> Path:
    archive_path = one_downloaded_archive(download_directory)
    require(
        not os.path.lexists(output_directory),
        "artifact output path already exists",
    )
    output_parent = output_directory.parent
    require(
        output_parent.is_dir() and not output_parent.is_symlink(),
        "artifact output parent is absent or indirect",
    )

    temporary_output = Path(
        tempfile.mkdtemp(
            prefix=f".{output_directory.name}.",
            dir=output_parent,
        )
    )

    def direct_file_opener(path: str, flags: int) -> int:
        direct_flags = flags | getattr(os, "O_CLOEXEC", 0)
        if hasattr(os, "O_NOFOLLOW"):
            direct_flags |= os.O_NOFOLLOW
        return os.open(path, direct_flags)

    try:
        with open(archive_path, "rb", opener=direct_file_opener) as archive_stream:
            admitted_status = os.fstat(archive_stream.fileno())
            require(
                stat.S_ISREG(admitted_status.st_mode),
                "opened artifact is not a regular file",
            )
            with zipfile.ZipFile(archive_stream, "r") as archive:
                package = select_production_package(archive.infolist())
                package_name = canonical_member_name(package).rsplit("/", 1)[-1]
                destination = temporary_output / package_name
                with archive.open(package, "r") as source, destination.open(
                    "xb"
                ) as target:
                    shutil.copyfileobj(source, target, length=1024 * 1024)
                    target.flush()
                    os.fsync(target.fileno())
                require(
                    destination.stat().st_size == package.file_size,
                    "production package byte count differs after extraction",
                )
                destination.chmod(0o600)
        os.replace(temporary_output, output_directory)
    except Exception:
        shutil.rmtree(temporary_output, ignore_errors=True)
        raise
    return output_directory / package_name


def regular_member(name: str) -> zipfile.ZipInfo:
    member = zipfile.ZipInfo(name)
    member.create_system = 3
    member.external_attr = (stat.S_IFREG | 0o600) << 16
    return member


def directory_member(name: str) -> zipfile.ZipInfo:
    member = zipfile.ZipInfo(name.rstrip("/") + "/")
    member.create_system = 3
    member.external_attr = (stat.S_IFDIR | 0o700) << 16
    return member


def write_archive(
    path: Path,
    members: Iterable[tuple[str | zipfile.ZipInfo, bytes]],
) -> None:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for member, payload in members:
                archive.writestr(member, payload)


def good_members() -> list[tuple[str | zipfile.ZipInfo, bytes]]:
    return [
        (directory_member("package"), b""),
        (
            regular_member(
                "package/radeon-unified-dkms-0.8.1-1-x86_64.pkg.tar.zst"
            ),
            b"production package fixture\n",
        ),
        (regular_member("lifecycle-evidence-prod/compile.log"), b"PASS\n"),
    ]


FixtureSetup = Callable[[Path, Path], None]


def write_good_download(download_directory: Path) -> None:
    write_archive(download_directory / "artifact.zip", good_members())


def expect_rejection(
    name: str,
    setup: FixtureSetup,
    expected_message: str,
    *,
    output_preexists: bool = False,
) -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-artifact-admission-") as root:
        fixture_root = Path(root)
        download_directory = fixture_root / "download"
        output_directory = fixture_root / "output"
        download_directory.mkdir()
        setup(download_directory, output_directory)
        try:
            admit_artifact(download_directory, output_directory)
        except (ArtifactAdmissionError, OSError, zipfile.BadZipFile) as error:
            require(
                expected_message in str(error),
                f"{name} rejected for an unexpected reason: {error}",
            )
            require(
                not list(fixture_root.glob(".output.*")),
                f"{name} left a temporary output directory",
            )
            if not output_preexists:
                require(
                    not os.path.lexists(output_directory),
                    f"{name} left an admitted output path",
                )
            print(f"PASS known-bad: {name}")
            return
        raise ArtifactAdmissionError(f"self-test accepted known-bad fixture: {name}")


def expect_member_rejection(
    name: str,
    member: zipfile.ZipInfo,
    expected_message: str,
) -> None:
    try:
        select_production_package([member])
    except ArtifactAdmissionError as error:
        require(
            expected_message in str(error),
            f"{name} rejected for an unexpected reason: {error}",
        )
        print(f"PASS known-bad: {name}")
        return
    raise ArtifactAdmissionError(f"self-test accepted known-bad fixture: {name}")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-artifact-admission-") as root:
        fixture_root = Path(root)
        download_directory = fixture_root / "download"
        output_directory = fixture_root / "output"
        download_directory.mkdir()
        write_good_download(download_directory)
        package = admit_artifact(download_directory, output_directory)
        require(
            package.read_bytes() == b"production package fixture\n",
            "known-good package bytes differ after admission",
        )
        require(
            [path.name for path in output_directory.iterdir()] == [package.name],
            "known-good output contains more than the production package",
        )
        require(
            stat.S_IMODE(package.stat().st_mode) == 0o600,
            "known-good package mode is not 600",
        )
        print("PASS known-good: one production package admitted")

    def multiple_downloads(download: Path, _output: Path) -> None:
        write_good_download(download)
        write_archive(download / "second.zip", good_members())

    def indirect_download(download: Path, _output: Path) -> None:
        target = download.parent / "artifact.zip"
        write_archive(target, good_members())
        (download / "artifact.zip").symlink_to(target)

    def directory_download(download: Path, _output: Path) -> None:
        (download / "artifact.zip").mkdir()

    def invalid_zip(download: Path, _output: Path) -> None:
        (download / "artifact.zip").write_bytes(b"not a zip archive\n")

    def empty_archive(download: Path, _output: Path) -> None:
        write_archive(download / "artifact.zip", [])

    def archive_with(
        extra_member: zipfile.ZipInfo,
        payload: bytes = b"unsafe\n",
    ) -> FixtureSetup:
        def setup(download: Path, _output: Path) -> None:
            members = good_members()
            members.append((extra_member, payload))
            write_archive(download / "artifact.zip", members)

        return setup

    def two_packages(download: Path, _output: Path) -> None:
        members = good_members()
        members.append(
            (
                regular_member(
                    "package/radeon-unified-dkms-0.8.2-1-x86_64.pkg.tar.zst"
                ),
                b"second production package\n",
            )
        )
        write_archive(download / "artifact.zip", members)

    def duplicate_member(download: Path, _output: Path) -> None:
        members = good_members()
        members.append(
            (regular_member("lifecycle-evidence-prod/compile.log"), b"again\n")
        )
        write_archive(download / "artifact.zip", members)

    def corrupt_package_payload(download: Path, _output: Path) -> None:
        archive_path = download / "artifact.zip"
        write_archive(archive_path, good_members())
        archive_bytes = bytearray(archive_path.read_bytes())
        marker = b"production package fixture\n"
        marker_offset = archive_bytes.find(marker)
        require(marker_offset >= 0, "self-test package payload marker is absent")
        archive_bytes[marker_offset] ^= 0x01
        archive_path.write_bytes(archive_bytes)

    def development_only(download: Path, _output: Path) -> None:
        write_archive(
            download / "artifact.zip",
            [
                (
                    regular_member(
                        "package/radeon-unified-dkms-dev-0.8.1-1-x86_64.pkg.tar.zst"
                    ),
                    b"development package\n",
                )
            ],
        )

    def empty_package(download: Path, _output: Path) -> None:
        write_archive(
            download / "artifact.zip",
            [
                (
                    regular_member(
                        "package/radeon-unified-dkms-0.8.1-1-x86_64.pkg.tar.zst"
                    ),
                    b"",
                )
            ],
        )

    def preexisting_output(download: Path, output: Path) -> None:
        write_good_download(download)
        output.mkdir()

    symbolic_link = zipfile.ZipInfo("evidence/link")
    symbolic_link.create_system = 3
    symbolic_link.external_attr = (stat.S_IFLNK | 0o777) << 16
    named_pipe = zipfile.ZipInfo("evidence/pipe")
    named_pipe.create_system = 3
    named_pipe.external_attr = (stat.S_IFIFO | 0o600) << 16
    unsupported_compression = regular_member(
        "package/radeon-unified-dkms-0.8.1-1-x86_64.pkg.tar.zst"
    )
    unsupported_compression.compress_type = 99
    unsupported_compression.file_size = 1
    oversized_package = regular_member(
        "package/radeon-unified-dkms-0.8.1-1-x86_64.pkg.tar.zst"
    )
    oversized_package.file_size = MAXIMUM_PACKAGE_BYTES + 1

    expect_rejection(
        "empty download directory",
        lambda _download, _output: None,
        "does not contain exactly one entry",
    )
    expect_rejection(
        "multiple downloaded files",
        multiple_downloads,
        "does not contain exactly one entry",
    )
    expect_rejection(
        "indirect downloaded file",
        indirect_download,
        "not a direct regular file",
    )
    expect_rejection(
        "downloaded directory",
        directory_download,
        "not a direct regular file",
    )
    expect_rejection("invalid ZIP", invalid_zip, "File is not a zip file")
    expect_rejection("empty ZIP", empty_archive, "artifact archive has no members")
    expect_rejection(
        "parent traversal member",
        archive_with(regular_member("../escape")),
        "relative traversal component",
    )
    expect_rejection(
        "absolute member",
        archive_with(regular_member("/escape")),
        "archive member is absolute",
    )
    expect_rejection(
        "backslash member",
        archive_with(regular_member("evidence\\escape")),
        "uses a backslash",
    )
    expect_rejection(
        "drive-qualified member",
        archive_with(regular_member("C:/escape")),
        "drive-qualified path",
    )
    expect_rejection(
        "symbolic-link member",
        archive_with(symbolic_link, b"target"),
        "not a regular file",
    )
    expect_rejection(
        "special-file member",
        archive_with(named_pipe),
        "not a regular file",
    )
    expect_member_rejection(
        "unsupported compression method",
        unsupported_compression,
        "uses an unsupported compression method",
    )
    expect_rejection(
        "multiple production packages",
        two_packages,
        "does not contain exactly one production package",
    )
    expect_rejection(
        "duplicate member name",
        duplicate_member,
        "archive contains a duplicate member name",
    )
    expect_rejection(
        "development package only",
        development_only,
        "does not contain exactly one production package",
    )
    expect_rejection(
        "empty production package",
        empty_package,
        "production package member is empty",
    )
    expect_member_rejection(
        "oversized production package",
        oversized_package,
        "production package member exceeds the admission limit",
    )
    expect_rejection(
        "corrupt production package",
        corrupt_package_payload,
        "Bad CRC-32",
    )
    expect_rejection(
        "preexisting output",
        preexisting_output,
        "artifact output path already exists",
        output_preexists=True,
    )
    print("Target artifact admission calibration: 1 known-good and 20 known-bad fixtures")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--download-directory", type=Path)
    parser.add_argument("--output-directory", type=Path)
    arguments = parser.parse_args()
    if arguments.self_test:
        if arguments.download_directory is not None or arguments.output_directory is not None:
            parser.error("--self-test does not accept artifact directories")
    elif arguments.download_directory is None or arguments.output_directory is None:
        parser.error(
            "operational mode requires --download-directory and --output-directory"
        )
    return arguments


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.self_test:
            run_self_test()
        else:
            package = admit_artifact(
                arguments.download_directory,
                arguments.output_directory,
            )
            print(f"admitted_package={package}")
    except (ArtifactAdmissionError, OSError, zipfile.BadZipFile) as error:
        print(f"target artifact admission: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
