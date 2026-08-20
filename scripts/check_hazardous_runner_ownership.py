#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Keep hazardous Radeon hardware runners in the evidence repository."""

from __future__ import annotations

import argparse
import hashlib
import json
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
RELOCATED_RUNNER_CLOSURES = (
    {
        "legacy_runner": "scripts/rs480_frontier_attended_probe.sh",
        "successor": "src/re/r300/probes/frontier/harness_wb_instrumented.py",
        "bundle": (
            "src/re/r300/results/"
            "cachyos_vostro1000_rs480_frontier_lowtier_probe_20260607T105947Z"
        ),
        "required_bundle_members": (
            "arm_journal.tsv",
            "dmesg_follow.log",
            "heartbeat.log",
            "run_manifest.json",
            "bundle_manifest.json",
            "bundle_hashes.sha256",
        ),
    },
    {
        "legacy_runner": "scripts/cpme_derisk_reset_capture.sh",
        "successor": "src/re/r300/scripts/run_vostro_rs480_reset_recovery_probe.sh",
        "bundle": (
            "src/re/r300/results/"
            "cachyos_vostro1000_rs480_gpu_reset_recovery_ladder_20260707T0240Z"
        ),
        "required_bundle_members": (
            "idle-gated.out",
            "idle-softreset.out",
            "blit-busy-hang.out",
            "run_manifest.json",
            "bundle_manifest.json",
            "bundle_hashes.sha256",
        ),
    },
)
PENDING_RELOCATION_RUNNERS = {
    "scripts/rs480_gui_debug_readdiff.c": (
        "The hardware authority carries neither a successor runner nor a retained "
        "result bundle for the GUI_DEBUG read-differential output contract."
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


def tracked_paths(repository: Path) -> set[str]:
    result = subprocess.run(
        ["git", "-C", str(repository), "ls-files", "-z"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise OwnershipError(f"cannot enumerate evidence repository: {detail}")
    return {
        raw_path.decode("utf-8")
        for raw_path in result.stdout.split(b"\0")
        if raw_path
    }


def read_regular_json(repository: Path, relative_path: str) -> dict[str, object]:
    path = repository / relative_path
    if not path.is_file() or path.is_symlink():
        raise OwnershipError(f"{relative_path}: bundle manifest is absent or indirect")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise OwnershipError(f"{relative_path}: cannot parse bundle manifest: {error}") from error
    if not isinstance(value, dict):
        raise OwnershipError(f"{relative_path}: bundle manifest is not an object")
    return value


def verify_bundle_hashes(repository: Path, bundle: str, tracked: set[str]) -> None:
    ledger_path = f"{bundle}/bundle_hashes.sha256"
    ledger = repository / ledger_path
    if ledger_path not in tracked or not ledger.is_file() or ledger.is_symlink():
        raise OwnershipError(f"{ledger_path}: retained hash ledger is absent or indirect")
    try:
        lines = ledger.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise OwnershipError(f"{ledger_path}: cannot read retained hash ledger: {error}") from error
    if not lines:
        raise OwnershipError(f"{ledger_path}: retained hash ledger is empty")
    for line in lines:
        digest, separator, member = line.partition("  ")
        if not separator or len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
            raise OwnershipError(f"{ledger_path}: malformed digest row: {line}")
        if not member or member.startswith("/") or ".." in member.split("/"):
            raise OwnershipError(f"{ledger_path}: unsafe bundle member: {member}")
        member_path = f"{bundle}/{member}"
        path = repository / member_path
        if not path.is_file() or path.is_symlink():
            raise OwnershipError(f"{member_path}: retained hash member is absent or indirect")
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != digest:
            raise OwnershipError(f"{member_path}: retained hash differs")


def verify_relocation_closure(evidence_repository: Path) -> None:
    tracked = tracked_paths(evidence_repository)
    for closure in RELOCATED_RUNNER_CLOSURES:
        successor = str(closure["successor"])
        bundle = str(closure["bundle"])
        successor_path = evidence_repository / successor
        if successor not in tracked or not successor_path.is_file() or successor_path.is_symlink():
            raise OwnershipError(f"{successor}: successor runner is absent or indirect")
        bundle_manifest_path = f"{bundle}/bundle_manifest.json"
        run_manifest_path = f"{bundle}/run_manifest.json"
        bundle_manifest = read_regular_json(evidence_repository, bundle_manifest_path)
        run_manifest = read_regular_json(evidence_repository, run_manifest_path)
        if bundle_manifest.get("schema") != "steinmarder-bundle-manifest-v1":
            raise OwnershipError(f"{bundle_manifest_path}: unexpected bundle schema")
        if run_manifest.get("schema") != "steinmarder-run-manifest-v1":
            raise OwnershipError(f"{run_manifest_path}: unexpected run schema")
        inventory = bundle_manifest.get("files")
        if not isinstance(inventory, dict):
            raise OwnershipError(f"{bundle_manifest_path}: bundle file inventory is absent")
        for member in closure["required_bundle_members"]:
            member_path = f"{bundle}/{member}"
            path = evidence_repository / member_path
            if not path.is_file() or path.is_symlink():
                raise OwnershipError(f"{member_path}: successor output is absent or indirect")
            if member not in inventory and member not in {
                "bundle_manifest.json",
                "bundle_hashes.sha256",
            }:
                raise OwnershipError(f"{bundle_manifest_path}: output is not inventoried: {member}")
        verify_bundle_hashes(evidence_repository, bundle, tracked)
    print(
        "hazardous runner closure: "
        f"{len(RELOCATED_RUNNER_CLOSURES)} successors and retained bundles verified"
    )


def verify_pending_relocations(repository: Path) -> None:
    for relative_path in PENDING_RELOCATION_RUNNERS:
        path = repository / relative_path
        if not path.is_file() or path.is_symlink():
            raise OwnershipError(
                f"{relative_path}: relocation removed a runner without successor and bundle closure"
            )


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

    with tempfile.TemporaryDirectory(prefix="radeon-hazard-closure-") as directory:
        evidence_repository = Path(directory)
        subprocess.run(["git", "init", "-q", str(evidence_repository)], check=True)
        subprocess.run(
            ["git", "-C", str(evidence_repository), "config", "user.name", "Closure Test"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(evidence_repository), "config", "user.email", "closure@example.invalid"],
            check=True,
        )
        for closure in RELOCATED_RUNNER_CLOSURES:
            successor = evidence_repository / str(closure["successor"])
            successor.parent.mkdir(parents=True, exist_ok=True)
            successor.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            bundle = evidence_repository / str(closure["bundle"])
            bundle.mkdir(parents=True, exist_ok=True)
            inventory: dict[str, str] = {}
            hashed_members: list[Path] = []
            for member in closure["required_bundle_members"]:
                if member == "bundle_hashes.sha256":
                    continue
                path = bundle / member
                if member == "run_manifest.json":
                    path.write_text('{"schema":"steinmarder-run-manifest-v1"}\n', encoding="utf-8")
                elif member == "bundle_manifest.json":
                    continue
                else:
                    path.write_text(f"{member}\n", encoding="utf-8")
                inventory[member] = "fixture output"
                hashed_members.append(path)
            (bundle / "bundle_manifest.json").write_text(
                json.dumps(
                    {
                        "schema": "steinmarder-bundle-manifest-v1",
                        "files": inventory,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            hashed_members.append(bundle / "bundle_manifest.json")
            ledger = "".join(
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
                for path in hashed_members
            )
            (bundle / "bundle_hashes.sha256").write_text(ledger, encoding="utf-8")
        subprocess.run(["git", "-C", str(evidence_repository), "add", "."], check=True)
        subprocess.run(["git", "-C", str(evidence_repository), "commit", "-qm", "fixture evidence"], check=True)
        verify_relocation_closure(evidence_repository)
        print("PASS known-good: successor and retained bundle closure")

        missing_successor = evidence_repository / str(RELOCATED_RUNNER_CLOSURES[0]["successor"])
        missing_successor.unlink()
        try:
            verify_relocation_closure(evidence_repository)
        except OwnershipError:
            print("PASS known-bad: missing successor runner")
        else:
            raise OwnershipError("self-test accepts a missing successor runner")

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
    parser.add_argument("--evidence-repository", type=Path)
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    try:
        if arguments.self_test:
            run_self_test()
        else:
            sources = tracked_sources(repository)
            verify_sources(sources)
            verify_refusal_shims(repository, sources)
            verify_pending_relocations(repository)
            if arguments.evidence_repository is not None:
                verify_relocation_closure(arguments.evidence_repository)
            print(f"hazardous runner ownership: {len(sources)} sources stay package-only")
    except (OSError, UnicodeError, OwnershipError) as error:
        print(f"hazardous runner ownership: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
