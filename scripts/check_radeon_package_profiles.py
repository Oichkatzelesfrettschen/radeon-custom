#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
"""Verify the deterministic Radeon package profile inputs."""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path


class ProfileError(Exception):
    """A package profile input violates the split-package contract."""


def read_ascii(path: Path) -> str:
    try:
        return path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise ProfileError(f"cannot read {path}: {error}") from error


def read_toml(path: Path) -> dict[str, object]:
    try:
        return tomllib.loads(read_ascii(path))
    except tomllib.TOMLDecodeError as error:
        raise ProfileError(f"invalid TOML in {path}: {error}") from error


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
    match = pattern.search(read_ascii(path))
    if match is None:
        raise ProfileError(f"{path.name} omits {macro}")
    return match.group(1)


def option_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, line in enumerate(read_ascii(path).splitlines(), start=1):
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
    text = read_ascii(path)
    assignments = re.findall(r"RADEON_BUILD_PROFILE=([^ ]+)", text)
    if assignments != [expected]:
        raise ProfileError(
            f"{path.name} build profile is {assignments}, expected {[expected]}"
        )
    forbidden = ("PATCH[", "patch -p", "git apply")
    for token in forbidden:
        if token in text:
            raise ProfileError(f"{path.name} contains source mutation token {token}")


def verify(package_dir: Path, prod_config: Path | None = None) -> None:
    pkgbuild_path = package_dir / "PKGBUILD"
    pkgbuild = read_ascii(pkgbuild_path)
    identity = read_toml(package_dir / "source-identity.toml")
    pkgver = shell_scalar(pkgbuild, "pkgver")
    pkgrel = shell_integer(pkgbuild, "pkgrel")

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
    require_make_profile(package_dir / "dkms.conf.dev", "mutate-dev")

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
    for dep in depends:
        name = re.split(r"[<>=]", dep, maxsplit=1)[0]
        if name in ("radeon-unified-dkms", "radeon-unified-dkms-dev"):
            raise ProfileError(
                f"hazard-stack depends on literal module package {name}; "
                "the prod<->dev swap removes it -- depend on the shared "
                "radeon-unified capability"
            )
    if not any(dep.startswith("radeon-unified") for dep in depends):
        raise ProfileError(
            "hazard-stack lacks a radeon-unified capability dependency"
        )


def run_self_test(package_dir: Path, fixture: Path) -> None:
    verify(package_dir)
    try:
        verify(package_dir, prod_config=fixture)
    except ProfileError:
        pass
    else:
        raise ProfileError("negative production fixture passes")
    hazard_dir = package_dir.parent / "rs480-reset-hazard-stack"
    verify_hazard_stack(read_ascii(hazard_dir / "PKGBUILD"))
    known_bad = (
        "depends=('radeon-unified-dkms' 'sp5100-tco-ioapic-dkms>=0.4-4')\n"
    )
    try:
        verify_hazard_stack(known_bad)
    except ProfileError:
        pass
    else:
        raise ProfileError("literal module dependency fixture passes")
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
                read_ascii(
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
