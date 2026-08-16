#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Verify the deterministic Radeon package profile inputs."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
import tomllib
from collections.abc import Callable
from pathlib import Path


class ProfileError(Exception):
    """A package profile input violates the split-package contract."""


SHA40 = re.compile(r"^[0-9a-f]{40}$")
ZERO_SHA40 = "0" * 40
WRONG_SHA40 = "1" * 40
PROFILE_INPUT_NAMES = (
    "PKGBUILD",
    "source-identity.toml",
    "radeon-build-profile.prod.toml",
    "radeon-build-profile.prod.h",
    "radeon-build-profile.dev.toml",
    "radeon-build-profile.dev.h",
    "dkms.conf.prod",
    "dkms.conf.dev",
    "radeon-re.conf",
    "radeon-dev.conf",
    "observe-dev.conf",
    "probe-dev.conf",
    "mutate-dev.conf",
)
UNOWNED_ARTIFACT_PATHS = (
    "src/linux/include/generated/autoconf.h",
    "pkg/radeon-unified.pkg.tar.zst",
    ".cache/ccache/index",
    "cache/meson-private/coredata.dat",
    "sources/radeon-unified.tar.xz",
    "signatures/radeon-unified.tar.xz.sig",
    "unowned-artifact.txt",
)


def read_utf8(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ProfileError(f"cannot read {path}: {error}") from error


def read_toml(path: Path) -> dict[str, object]:
    try:
        return tomllib.loads(read_utf8(path))
    except tomllib.TOMLDecodeError as error:
        raise ProfileError(f"invalid TOML in {path}: {error}") from error


def require_regular_file(path: Path, description: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ProfileError(
            f"{description} must be a regular non-symlink file: {path}"
        )


def copy_profile_inputs(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise ProfileError(
            "profile input source must be a regular non-symlink directory: "
            f"{source}"
        )
    if destination.is_symlink() or (
        destination.exists() and not destination.is_dir()
    ):
        raise ProfileError(
            "profile copy destination must be a regular non-symlink directory: "
            f"{destination}"
        )
    destination.mkdir(parents=True, exist_ok=True)
    for name in PROFILE_INPUT_NAMES:
        source_path = source / name
        destination_path = destination / name
        require_regular_file(source_path, f"profile input {name}")
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.copy2(source_path, destination_path)
        except OSError as error:
            raise ProfileError(
                f"self-test cannot copy profile input {name}: {error}"
            ) from error


def require_profile_copy_shape(
    source: Path, destination: Path, unowned_paths: tuple[str, ...]
) -> None:
    if destination.is_symlink() or not destination.is_dir():
        raise ProfileError(
            "self-test profile copy destination must be a regular "
            f"non-symlink directory: {destination}"
        )
    expected_paths = {Path(name) for name in PROFILE_INPUT_NAMES}
    expected_directories = {
        parent
        for name in PROFILE_INPUT_NAMES
        for parent in Path(name).parents
        if str(parent) != "."
    }
    actual_paths: set[Path] = set()
    actual_directories: set[Path] = set()
    for path in destination.rglob("*"):
        relative_path = path.relative_to(destination)
        if path.is_symlink():
            raise ProfileError(
                "self-test profile copy contains a symlink: "
                f"{relative_path}"
            )
        if path.is_dir():
            actual_directories.add(relative_path)
        elif path.is_file():
            actual_paths.add(relative_path)
        else:
            raise ProfileError(
                "self-test profile copy contains a non-regular entry: "
                f"{relative_path}"
            )
    if actual_paths != expected_paths or actual_directories != expected_directories:
        raise ProfileError(
            "self-test profile copy has an unexpected entry set: "
            f"files={sorted(str(path) for path in actual_paths)}, "
            f"directories={sorted(str(path) for path in actual_directories)}"
        )
    for name in unowned_paths:
        source_path = source / name
        destination_path = destination / name
        if not source_path.is_file() or source_path.stat().st_size < 65536:
            raise ProfileError(
                f"self-test unowned fixture is not large enough: {name}"
            )
        if destination_path.exists():
            raise ProfileError(f"self-test copied unowned artifact: {name}")


def shell_integer(text: str, name: str) -> int:
    match = re.search(rf"^{re.escape(name)}=([0-9]+)$", text, re.MULTILINE)
    if match is None:
        raise ProfileError(f"PKGBUILD omits integer {name}")
    return int(match.group(1))


def shell_scalar(text: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}=([A-Za-z0-9_.+-]+)$", text, re.MULTILINE)
    if match is None:
        raise ProfileError(f"PKGBUILD omits scalar {name}")
    return match.group(1)


def macro_value(path: Path, macro: str) -> str:
    pattern = re.compile(rf'^#define {re.escape(macro)} "([^"]+)"$', re.MULTILINE)
    match = pattern.search(read_utf8(path))
    if match is None:
        raise ProfileError(f"{path.name} omits {macro}")
    return match.group(1)


def option_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, line in enumerate(read_utf8(path).splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if fields[:2] != ["options", "radeon"]:
            raise ProfileError(f"{path.name}:{number} is not a radeon option row")
        for token in fields[2:]:
            if "=" not in token:
                raise ProfileError(f"{path.name}:{number} has a malformed option")
            key, value = token.split("=", 1)
            if key in values:
                raise ProfileError(f"{path.name} repeats option {key}")
            values[key] = value
    return values


def require_make_profile(path: Path, expected: str) -> None:
    text = read_utf8(path)
    assignments = re.findall(r"RADEON_BUILD_PROFILE=([^ ]+)", text)
    if assignments != [expected]:
        raise ProfileError(
            f"{path.name} build profile is {assignments}, expected {[expected]}"
        )
    forbidden = ("PATCH[", "patch -p", "git apply")
    for token in forbidden:
        if token in text:
            raise ProfileError(f"{path.name} contains source mutation token {token}")


def require_package_version(path: Path, expected: str) -> None:
    text = read_utf8(path)
    versions = re.findall(r'^PACKAGE_VERSION="([^"]+)"$', text, re.MULTILINE)
    if len(versions) != 1:
        raise ProfileError(
            f"{path.name} must declare exactly one PACKAGE_VERSION"
        )
    if versions[0] != expected:
        raise ProfileError(
            f"{path.name} PACKAGE_VERSION {versions[0]!r} disagrees with "
            f"PKGBUILD pkgver {expected!r}"
        )


def require_nonzero_git_object(value: object, field: str) -> None:
    if not isinstance(value, str) or not SHA40.fullmatch(value):
        raise ProfileError(f"{field} must be a lowercase 40-character object ID")
    if value == ZERO_SHA40:
        raise ProfileError(f"{field} is the all-zero git object")


def verify(package_dir: Path, prod_config: Path | None = None) -> None:
    pkgbuild_path = package_dir / "PKGBUILD"
    pkgbuild = read_utf8(pkgbuild_path)
    identity = read_toml(package_dir / "source-identity.toml")
    pkgver = shell_scalar(pkgbuild, "pkgver")
    pkgrel = shell_integer(pkgbuild, "pkgrel")
    require_nonzero_git_object(identity.get("driver_tree"), "driver_tree")

    required_names = (
        "pkgname=('radeon-unified-dkms' 'radeon-unified-dkms-dev' "
        "'radeon-rs482-policy')"
    )
    if required_names not in pkgbuild:
        raise ProfileError("PKGBUILD does not declare both split packages")
    if "conflicts=('radeon-unified-dkms-dev'" not in pkgbuild:
        raise ProfileError("production package does not conflict with development")
    if "conflicts=('radeon-unified-dkms'" not in pkgbuild:
        raise ProfileError("development package does not conflict with production")
    if "_common_provides=(\"radeon-unified=${pkgver}-${pkgrel}\"" not in pkgbuild:
        raise ProfileError("split packages lack the shared functional identity")

    expected_common = {
        "package_version": pkgver,
        "package_release": pkgrel,
        "source_repository": identity["source_repository"],
        "source_commit": identity["source_commit"],
        "repository_tree": identity["repository_tree"],
        "driver_tree": identity["driver_tree"],
        "feature_policy_sha256": identity["feature_policy_sha256"],
        "upstream_base": identity["upstream_commit"],
        "kernel_build_interface": 1,
    }
    profiles = {
        "prod": {
            "package_name": "radeon-unified-dkms",
            "build_profile": "prod",
            "compiled_ceiling": "prod",
            "header_profile": "prod",
        },
        "dev": {
            "package_name": "radeon-unified-dkms-dev",
            "build_profile": "all-dev",
            "compiled_ceiling": "mutate-dev",
            "header_profile": "mutate-dev",
        },
    }
    for suffix, expected in profiles.items():
        manifest = read_toml(
            package_dir / f"radeon-build-profile.{suffix}.toml"
        )
        if manifest.get("schema") != 1:
            raise ProfileError(f"{suffix} build manifest schema is not 1")
        for key, value in expected_common.items():
            if manifest.get(key) != value:
                raise ProfileError(f"{suffix} build manifest disagrees on {key}")
        for key in ("package_name", "build_profile", "compiled_ceiling"):
            if manifest.get(key) != expected[key]:
                raise ProfileError(f"{suffix} build manifest disagrees on {key}")
        header = package_dir / f"radeon-build-profile.{suffix}.h"
        header_bindings = {
            "RADEON_BUILD_PROFILE": expected["header_profile"],
            "RADEON_BUILD_SOURCE_COMMIT": identity["source_commit"],
            "RADEON_BUILD_DRIVER_TREE": identity["driver_tree"],
            "RADEON_BUILD_FEATURE_POLICY_SHA256": identity[
                "feature_policy_sha256"
            ],
            "RADEON_BUILD_UPSTREAM_BASE": identity["upstream_commit"],
        }
        for macro, value in header_bindings.items():
            if macro_value(header, macro) != value:
                raise ProfileError(f"{header.name} disagrees on {macro}")

    require_make_profile(
        prod_config or package_dir / "dkms.conf.prod", "prod"
    )
    require_package_version(prod_config or package_dir / "dkms.conf.prod", pkgver)
    require_make_profile(package_dir / "dkms.conf.dev", "mutate-dev")
    require_package_version(package_dir / "dkms.conf.dev", pkgver)

    production_options = option_values(package_dir / "radeon-re.conf")
    if production_options.get("lockup_timeout") != "0":
        raise ProfileError("production policy must set lockup_timeout=0")
    for key in ("benchmark", "test"):
        if production_options.get(key) != "0":
            raise ProfileError(f"production policy must set {key}=0")
    for key in production_options:
        if key == "profile_dev" or key.startswith(("rs480_", "palm_")):
            raise ProfileError(f"production policy contains development option {key}")

    if option_values(package_dir / "radeon-dev.conf") != {"profile_dev": "off"}:
        raise ProfileError("development policy must default profile_dev to off")
    for profile in ("observe-dev", "probe-dev", "mutate-dev"):
        expected = {"profile_dev": profile}
        actual = option_values(package_dir / f"{profile}.conf")
        if actual != expected:
            raise ProfileError(f"{profile} template has unexpected options")


def verify_hazard_stack(pkgbuild_text: str) -> None:
    """The hazard stack rides through the prod<->dev module swap.

    The production and development module packages conflict with each
    other and share the radeon-unified capability. A hazard-stack
    dependency naming a literal module package would make pacman remove
    the stack during the swap a mutation campaign requires, so the
    driver dependency binds to the shared capability.
    """
    match = re.search(r"^depends=\(([^)]*)\)", pkgbuild_text, re.MULTILINE)
    if match is None:
        raise ProfileError("hazard-stack PKGBUILD omits depends")
    depends = re.findall(r"'([^']+)'", match.group(1))
    dependency_names = [
        re.split(r"[<>=]", dependency, maxsplit=1)[0]
        for dependency in depends
    ]
    for name in dependency_names:
        if name in ("radeon-unified-dkms", "radeon-unified-dkms-dev"):
            raise ProfileError(
                f"hazard-stack depends on literal module package {name}; "
                "the prod<->dev swap removes it -- depend on the shared "
                "radeon-unified capability"
            )
    if "radeon-unified" not in dependency_names:
        raise ProfileError(
            "hazard-stack lacks a radeon-unified capability dependency"
        )


def expect_profile_error(
    label: str, action: Callable[[], None], expected_text: str
) -> None:
    try:
        action()
    except ProfileError as error:
        if expected_text not in str(error):
            raise ProfileError(
                f"{label} rejected with an unexpected diagnostic: {error}"
            ) from error
    else:
        raise ProfileError(f"{label} unexpectedly passes the profile gate")


def verify_invalid_production_fixture(
    package_dir: Path, fixture: Path
) -> None:
    require_regular_file(fixture, "negative production fixture")
    expected_error = (
        f"{fixture.name} build profile is ['mutate-dev'], expected ['prod']"
    )
    try:
        verify(package_dir, prod_config=fixture)
    except ProfileError as error:
        if str(error) != expected_error:
            raise ProfileError(
                "negative production fixture has an unexpected diagnostic: "
                f"{error}"
            ) from error
    else:
        raise ProfileError("negative production fixture passes")


def run_self_test(package_dir: Path, fixture: Path) -> None:
    verify(package_dir)
    pkgver = shell_scalar(read_utf8(package_dir / "PKGBUILD"), "pkgver")
    verify_invalid_production_fixture(package_dir, fixture)

    with tempfile.TemporaryDirectory(prefix="radeon-package-fixture.") as temp:
        fixture_root = Path(temp)
        missing_fixture = fixture_root / "missing.conf"
        expect_profile_error(
            "missing production fixture",
            lambda: verify_invalid_production_fixture(
                package_dir, missing_fixture
            ),
            "negative production fixture must be a regular non-symlink file",
        )

        directory_fixture = fixture_root / "directory.conf"
        directory_fixture.mkdir()
        expect_profile_error(
            "directory production fixture",
            lambda: verify_invalid_production_fixture(
                package_dir, directory_fixture
            ),
            "negative production fixture must be a regular non-symlink file",
        )

        external_fixture = fixture_root / "external-generated.conf"
        external_fixture.write_text(
            'PACKAGE_VERSION="0.3"\n', encoding="utf-8"
        )
        symlink_fixture = fixture_root / "symlink.conf"
        symlink_fixture.symlink_to(external_fixture)
        expect_profile_error(
            "symlink production fixture",
            lambda: verify_invalid_production_fixture(
                package_dir, symlink_fixture
            ),
            "negative production fixture must be a regular non-symlink file",
        )

        unrelated_fixture = fixture_root / "unrelated.conf"
        unrelated_fixture.write_text(
            'PACKAGE_VERSION="0.3"\n'
            'MAKE[0]="make RADEON_BUILD_PROFILE=prod modules"\n',
            encoding="utf-8",
        )
        expect_profile_error(
            "unrelated malformed production fixture",
            lambda: verify_invalid_production_fixture(
                package_dir, unrelated_fixture
            ),
            "negative production fixture has an unexpected diagnostic",
        )

    hazard_dir = package_dir.parent / "rs480-reset-hazard-stack"
    verify_hazard_stack(read_utf8(hazard_dir / "PKGBUILD"))
    verify_hazard_stack(
        "depends=('radeon-unified>=0.8-1' "
        "'sp5100-tco-ioapic-dkms>=0.4-4')\n"
    )
    known_bad = (
        "depends=('radeon-unified-dkms' 'sp5100-tco-ioapic-dkms>=0.4-4')\n"
    )
    try:
        verify_hazard_stack(known_bad)
    except ProfileError:
        pass
    else:
        raise ProfileError("literal module dependency fixture passes")
    for invalid_capability in (
        "radeon-unified-dkms-git",
        "radeon-unifiedness>=999",
    ):
        invalid_dependency = (
            f"depends=('{invalid_capability}' "
            "'sp5100-tco-ioapic-dkms>=0.4-4')\n"
        )
        expect_profile_error(
            f"invalid capability dependency fixture {invalid_capability}",
            lambda invalid_dependency=invalid_dependency: verify_hazard_stack(
                invalid_dependency
            ),
            "hazard-stack lacks a radeon-unified capability dependency",
        )

    identity_value = str(
        read_toml(package_dir / "source-identity.toml")["driver_tree"]
    )

    with tempfile.TemporaryDirectory(prefix="radeon-package-profile.") as temp:
        profile_source = Path(temp) / "profile-source"
        copy_profile_inputs(package_dir, profile_source)
        artifact_payload = "generated package artifact\n" * 4096
        for name in UNOWNED_ARTIFACT_PATHS:
            artifact_path = profile_source / name
            artifact_path.parent.mkdir(parents=True, exist_ok=True)
            artifact_path.write_text(artifact_payload, encoding="utf-8")

        external_generated = Path(temp) / "external-generated.conf"
        external_generated.write_text(
            'PACKAGE_VERSION="0.3"\n', encoding="utf-8"
        )

        source_directory_link = Path(temp) / "source-directory-link"
        source_directory_link.symlink_to(profile_source, target_is_directory=True)
        expect_profile_error(
            "symlink profile source directory",
            lambda: copy_profile_inputs(
                source_directory_link, Path(temp) / "symlink-source-destination"
            ),
            "profile input source must be a regular non-symlink directory",
        )

        source_file_mutant = Path(temp) / "source-file-mutant"
        copy_profile_inputs(profile_source, source_file_mutant)
        source_file = source_file_mutant / "PKGBUILD"
        source_file.unlink()
        source_file.symlink_to(external_generated)
        expect_profile_error(
            "symlink profile input",
            lambda: copy_profile_inputs(
                source_file_mutant, Path(temp) / "symlink-file-destination"
            ),
            "profile input PKGBUILD must be a regular non-symlink file",
        )

        source_directory_mutant = Path(temp) / "source-directory-mutant"
        copy_profile_inputs(profile_source, source_directory_mutant)
        source_identity = source_directory_mutant / "source-identity.toml"
        source_identity.unlink()
        source_identity.mkdir()
        expect_profile_error(
            "directory profile input",
            lambda: copy_profile_inputs(
                source_directory_mutant,
                Path(temp) / "directory-file-destination",
            ),
            "profile input source-identity.toml must be a regular "
            "non-symlink file",
        )

        source_missing_mutant = Path(temp) / "source-missing-mutant"
        copy_profile_inputs(profile_source, source_missing_mutant)
        (source_missing_mutant / "dkms.conf.dev").unlink()
        expect_profile_error(
            "missing profile input",
            lambda: copy_profile_inputs(
                source_missing_mutant,
                Path(temp) / "missing-file-destination",
            ),
            "profile input dkms.conf.dev must be a regular non-symlink file",
        )

        external_destination = Path(temp) / "external-destination"
        external_destination.mkdir()
        destination_directory_link = Path(temp) / "destination-directory-link"
        destination_directory_link.symlink_to(
            external_destination, target_is_directory=True
        )
        expect_profile_error(
            "symlink profile copy destination",
            lambda: copy_profile_inputs(
                profile_source, destination_directory_link
            ),
            "profile copy destination must be a regular non-symlink directory",
        )

        destination_file_mutant = Path(temp) / "destination-file-mutant"
        copy_profile_inputs(profile_source, destination_file_mutant)
        destination_file = destination_file_mutant / "PKGBUILD"
        destination_file.unlink()
        destination_file.symlink_to(external_generated)
        expect_profile_error(
            "symlink copied profile input",
            lambda: require_profile_copy_shape(
                profile_source,
                destination_file_mutant,
                UNOWNED_ARTIFACT_PATHS,
            ),
            "self-test profile copy contains a symlink",
        )

        destination_entry_mutant = Path(temp) / "destination-entry-mutant"
        copy_profile_inputs(profile_source, destination_entry_mutant)
        destination_entry = destination_entry_mutant / "PKGBUILD"
        destination_entry.unlink()
        destination_entry.mkdir()
        expect_profile_error(
            "non-regular copied profile input",
            lambda: require_profile_copy_shape(
                profile_source,
                destination_entry_mutant,
                UNOWNED_ARTIFACT_PATHS,
            ),
            "self-test profile copy has an unexpected entry set",
        )

        mutated = Path(temp) / "package"

        def reset_mutated() -> None:
            if mutated.exists():
                shutil.rmtree(mutated)
            copy_profile_inputs(profile_source, mutated)
            require_profile_copy_shape(
                profile_source, mutated, UNOWNED_ARTIFACT_PATHS
            )

        def replace_once(path: Path, old: str, new: str) -> None:
            text = read_utf8(path)
            if text.count(old) != 1:
                raise ProfileError(f"self-test cannot mutate {path.name}")
            path.write_text(text.replace(old, new), encoding="utf-8")

        def expect_rejection(label: str, expected_text: str) -> None:
            try:
                verify(mutated)
            except ProfileError as error:
                if expected_text not in str(error):
                    raise ProfileError(
                        f"{label} rejected with an unexpected diagnostic: {error}"
                    ) from error
            else:
                raise ProfileError(f"{label} passes the profile gate")

        reset_mutated()
        replace_once(
            mutated / "source-identity.toml",
            f'driver_tree = "{identity_value}"',
            f'driver_tree = "{ZERO_SHA40}"',
        )
        expect_rejection("all-zero source driver tree", "driver_tree is the all-zero")

        reset_mutated()
        replace_once(
            mutated / "radeon-build-profile.prod.h",
            '#define RADEON_BUILD_DRIVER_TREE "'
            + str(identity_value)
            + '"',
            f'#define RADEON_BUILD_DRIVER_TREE "{ZERO_SHA40}"',
        )
        expect_rejection(
            "production header driver tree mutant",
            "radeon-build-profile.prod.h disagrees on RADEON_BUILD_DRIVER_TREE",
        )

        reset_mutated()
        replace_once(
            mutated / "radeon-build-profile.dev.h",
            '#define RADEON_BUILD_DRIVER_TREE "'
            + str(identity_value)
            + '"',
            f'#define RADEON_BUILD_DRIVER_TREE "{WRONG_SHA40}"',
        )
        expect_rejection(
            "development header driver tree mutant",
            "radeon-build-profile.dev.h disagrees on RADEON_BUILD_DRIVER_TREE",
        )

        reset_mutated()
        replace_once(
            mutated / "radeon-build-profile.prod.toml",
            f'driver_tree = "{identity_value}"',
            f'driver_tree = "{WRONG_SHA40}"',
        )
        expect_rejection(
            "production manifest driver tree mutant",
            "prod build manifest disagrees on driver_tree",
        )

        reset_mutated()
        replace_once(
            mutated / "radeon-build-profile.dev.toml",
            f'driver_tree = "{identity_value}"',
            f'driver_tree = "{WRONG_SHA40}"',
        )
        expect_rejection(
            "development manifest driver tree mutant",
            "dev build manifest disagrees on driver_tree",
        )

        reset_mutated()
        replace_once(
            mutated / "dkms.conf.prod",
            f'PACKAGE_VERSION="{pkgver}"',
            'PACKAGE_VERSION="0.0"',
        )
        expect_rejection(
            "production DKMS version mutant",
            "dkms.conf.prod PACKAGE_VERSION",
        )

        reset_mutated()
        replace_once(
            mutated / "dkms.conf.dev",
            f'PACKAGE_VERSION="{pkgver}"',
            'PACKAGE_VERSION="0.0"',
        )
        expect_rejection(
            "development DKMS version mutant",
            "dkms.conf.dev PACKAGE_VERSION",
        )

    print("radeon package profile calibration: PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-dir", type=Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    package_dir = arguments.package_dir or (
        repository / "packaging/arch/radeon-unified-dkms"
    )
    fixture = (
        repository
        / "tests/fixtures/radeon-profile-invalid-prod-dkms.conf"
    )
    try:
        if arguments.self_test:
            run_self_test(package_dir, fixture)
        else:
            verify(package_dir)
            verify_hazard_stack(
                read_utf8(
                    package_dir.parent
                    / "rs480-reset-hazard-stack/PKGBUILD"
                )
            )
    except ProfileError as error:
        print(f"check_radeon_package_profiles: {error}", file=sys.stderr)
        return 1
    if not arguments.self_test:
        print("radeon deterministic package profiles: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
