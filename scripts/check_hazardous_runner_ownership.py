#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Keep hazardous Radeon hardware runners in the evidence repository."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SCANNED_SUFFIXES = {".c", ".py", ".sh", ".yml", ".yaml"}
SCANNED_EXTENSIONLESS = {"PKGBUILD", "radeon-dkms-make", "radeon-profile-dev"}
EXCLUDED_NAMES = {"check_hazardous_runner_ownership.py"}
REFUSAL_SHIMS = {
    "scripts/cpme_derisk_reset_capture.sh": (
        "#!/bin/sh\n"
        "# Refuse a GPU reset capture from the package-authority repository.\n\n"
        "printf '%s\\n' \\\n"
        "    'REFUSED: hazardous hardware runners belong in steinmarder-r300.' \\\n"
        "    'Run make r300-hazard-check in that repository before an authorized probe.' \\\n"
        "    >&2\n"
        "exit 3\n"
    ),
    "scripts/rs480_frontier_attended_probe.sh": (
        "#!/bin/sh\n"
        "# Refuse a frontier register read from the package-authority repository.\n\n"
        "printf '%s\\n' \\\n"
        "    'REFUSED: hazardous hardware runners belong in steinmarder-r300.' \\\n"
        "    'Run make r300-hazard-check in that repository before an authorized probe.' \\\n"
        "    >&2\n"
        "exit 3\n"
    ),
}
HAZARDOUS_INTERFACE_MARKERS = (
    "radeon_" + "gpu_reset",
    "radeon_rs480_" + "frontier_probe",
    "rs480_" + "frontier_index",
    "radeon_rs480_" + "cp_me_ram_inject",
    "radeon_rs480_" + "cp_me_oracle",
    "radeon_rs480_" + "force_clock_read",
    "radeon_rs480_" + "force_clock_3d_read",
    "radeon_rs480_" + "gated_read",
    "radeon_rs480_" + "hazard_read",
    "radeon_rs480_" + "vertex_probe",
    "radeon_rs480_" + "reset_hang_probe",
    "radeon_rs480_" + "rbbm_reset_probe",
    "radeon_rs480_" + "gpu_reset_recover",
    "radeon_rs480_" + "blit_busy_reset",
    "radeon_rs480_" + "pll_write_probe",
    "radeon_rs480_" + "paired_status_census",
    "radeon_rs480_" + "vap_status_census",
    "radeon_rs480_" + "vap_status_burst_census",
    "radeon_rs480_" + "rb3d_dstcache_ctlstat",
    "radeon_rs480_" + "zb_zcache_ctlstat",
)
SHELL_COMMAND_TEXT = re.compile(r"\bsh\s+-c\s+[\"']?\$")


class OwnershipError(Exception):
    """A package-repository source can execute a hazardous operation."""


def scans_path(path: Path) -> bool:
    return (
        path.name not in EXCLUDED_NAMES
        and (path.suffix in SCANNED_SUFFIXES or path.name in SCANNED_EXTENSIONLESS)
    )


def verify_sources(sources: dict[str, str]) -> None:
    findings: list[str] = []
    for relative_path, text in sorted(sources.items()):
        for marker in HAZARDOUS_INTERFACE_MARKERS:
            if marker in text:
                findings.append(f"{relative_path}: hazardous interface {marker}")
        if SHELL_COMMAND_TEXT.search(text) is not None:
            findings.append(f"{relative_path}: shell command text reaches sh -c")
    if findings:
        raise OwnershipError("\n".join(findings))


def verify_refusal_shims(repository: Path, sources: dict[str, str]) -> None:
    for relative_path, expected_text in REFUSAL_SHIMS.items():
        if sources.get(relative_path) != expected_text:
            raise OwnershipError(f"{relative_path}: refusal shim differs")
        mode = (repository / relative_path).stat().st_mode
        if mode & 0o111 == 0:
            raise OwnershipError(f"{relative_path}: refusal shim is not executable")


def tracked_sources(repository: Path) -> dict[str, str]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repository),
            "ls-files",
            "-z",
            ".github",
            "scripts",
            "packaging",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise OwnershipError(f"cannot enumerate tracked sources: {detail}")
    sources: dict[str, str] = {}
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        relative_path = raw_path.decode("utf-8")
        path = repository / relative_path
        if not scans_path(path):
            continue
        if not path.is_file() or path.is_symlink():
            raise OwnershipError(f"{relative_path}: source is absent or indirect")
        sources[relative_path] = path.read_text(encoding="utf-8")
    return sources


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="radeon-hazard-ownership-") as directory:
        fixture = Path(directory)
        good = fixture / "package-check.sh"
        good.write_text("#!/bin/sh\nprintf 'package verification only\\n'\n", encoding="utf-8")
        sources = {good.name: good.read_text(encoding="utf-8")}
        for relative_path, text in REFUSAL_SHIMS.items():
            path = fixture / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            path.chmod(0o755)
            sources[relative_path] = text
        verify_sources(sources)
        verify_refusal_shims(fixture, sources)
        print("PASS known-good: package source and executable refusal shims")

        changed_sources = dict(sources)
        changed_sources["scripts/cpme_derisk_reset_capture.sh"] += "# drift\n"
        try:
            verify_refusal_shims(fixture, changed_sources)
        except OwnershipError:
            print("PASS known-bad: changed refusal shim")
        else:
            raise OwnershipError("self-test accepts a changed refusal shim")

        required_surfaces = (
            Path(".github/workflows/gates.yml"),
            Path("packaging/arch/radeon-unified-dkms/PKGBUILD"),
            Path("packaging/arch/radeon-unified-dkms/radeon-dkms-make"),
            Path("packaging/arch/radeon-unified-dkms/radeon-profile-dev"),
        )
        if not all(scans_path(path) for path in required_surfaces):
            raise OwnershipError("self-test omits an executable source surface")
        print("PASS known-bad: omitted executable source surface")

    bad_sources = {
        "reset.sh": "cat /sys/kernel/debug/dri/0/" + "radeon_gpu_reset\n",
        "frontier.sh": "cat /sys/kernel/debug/dri/0/" + "radeon_rs480_frontier_probe\n",
        "selector.sh": "echo 0 > /sys/module/radeon/parameters/" + "rs480_frontier_index\n",
        "submit.sh": 'sh -c "$SUBMIT_CMD"\n',
    }
    rejected = 2
    for name, text in bad_sources.items():
        try:
            verify_sources({name: text})
        except OwnershipError:
            rejected += 1
            print(f"PASS known-bad: {name}")
        else:
            raise OwnershipError(f"self-test accepts hazardous fixture: {name}")
    print(
        "hazardous runner ownership calibration: "
        f"1 known-good and {rejected} known-bad fixtures"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    try:
        if arguments.self_test:
            run_self_test()
        else:
            sources = tracked_sources(repository)
            verify_sources(sources)
            verify_refusal_shims(repository, sources)
            print(f"hazardous runner ownership: {len(sources)} sources stay package-only")
    except (OSError, UnicodeError, OwnershipError) as error:
        print(f"hazardous runner ownership: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
