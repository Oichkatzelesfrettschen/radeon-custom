#!/usr/bin/env python3
"""Build RS482 register observation records and validation summaries."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_rs480_debugfs_fragments import RegisterRow, read_tsv


OBSERVED_ROW_RE = re.compile(
    r"^([A-Z0-9_]+)\s+\((0x[0-9a-fA-F]{4})\)\s+=\s+(0x[0-9a-fA-F]{8})$"
)


def die(message: str) -> None:
    print(f"build_rs482_register_validation_registry: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def load_manifest_text(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    with path.open("r", encoding="utf-8") as stream:
        for raw_line in stream:
            line = raw_line.rstrip("\n")
            key, sep, value = line.partition("=")
            if sep:
                values[key] = value
    return values


def load_tsv_map(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    with path.open("r", encoding="utf-8") as stream:
        for raw_line in stream:
            line = raw_line.rstrip("\n")
            if not line:
                continue
            key, sep, value = line.partition("\t")
            if sep:
                values[key] = value
    return values


def parse_bool(value: str) -> bool | None:
    if value in {"", "none"}:
        return None
    if value in {"0", "1"}:
        return value == "1"
    die(f"expected boolean 0/1/none, got {value!r}")


def parse_int(value: str) -> int | None:
    if value in {"", "none"}:
        return None
    try:
        return int(value)
    except ValueError:
        die(f"expected integer or none, got {value!r}")


def verdict_for(mode: str, classification: str) -> str:
    if mode == "safe-regs-once" and classification == "safe_regs_clean":
        return "safe_live_read_clean"
    if mode == "candidate-regs-once" and classification == "candidate_regs_clean":
        return "candidate_live_read_clean"
    return classification or "unknown"


def surface_for(mode: str) -> str:
    if mode == "safe-regs-once":
        return "safe"
    if mode == "candidate-regs-once":
        return "candidate"
    return "inventory"


def build_policy_map(
    safe_tsv: Path, candidate_tsv: Path
) -> dict[tuple[str, int, str], RegisterRow]:
    policy: dict[tuple[str, int, str], RegisterRow] = {}
    for row in read_tsv(safe_tsv, candidate=False):
        policy[("safe", row.offset, row.name)] = row
    for row in read_tsv(candidate_tsv, candidate=True):
        policy[("candidate", row.offset, row.name)] = row
    return policy


def iter_stdout_observations(
    bundle_dir: Path,
    metadata: dict[str, Any],
    policy: dict[tuple[str, int, str], RegisterRow],
) -> list[dict[str, Any]]:
    mode = metadata["mode"]
    surface = surface_for(mode)
    if surface not in {"safe", "candidate"}:
        return []

    stdout_name = "safe_regs.stdout" if surface == "safe" else "candidate_regs.stdout"
    stdout_path = bundle_dir / stdout_name
    if not stdout_path.exists():
        return []

    observations: list[dict[str, Any]] = []
    current_path: str | None = None
    in_regs = False

    with stdout_path.open("r", encoding="utf-8") as stream:
        for raw_line in stream:
            line = raw_line.rstrip("\n")
            if surface == "safe":
                if line.startswith("safe_regs_path="):
                    current_path = line.split("=", 1)[1]
                    in_regs = False
                    continue
                if line == "== safe regs ==":
                    in_regs = True
                    continue
            else:
                if line.startswith("candidate_regs_path="):
                    current_path = line.split("=", 1)[1]
                    in_regs = False
                    continue
                if line == "== candidate regs ==":
                    in_regs = True
                    continue

            if line.startswith("boot_id_after=") or line.startswith("== dmesg after =="):
                in_regs = False
                continue

            if not in_regs:
                continue

            match = OBSERVED_ROW_RE.match(line)
            if not match:
                continue

            name = match.group(1)
            offset = int(match.group(2), 16)
            value_hex = match.group(3).lower()
            policy_row = policy.get((surface, offset, name))
            if policy_row is None:
                policy_row = RegisterRow(
                    offset=offset,
                    name=name,
                    cohort="unknown",
                    access="mmio",
                    source="",
                    notes="",
                )

            observations.append(
                {
                    "schema": "steinmarder-rs482-register-observation-v1",
                    "bundle_id": metadata["bundle_id"],
                    "host": metadata["host"],
                    "timestamp_utc": metadata["timestamp_utc"],
                    "mode": mode,
                    "surface": surface,
                    "register_path": current_path,
                    "cohort": policy_row.cohort,
                    "access": policy_row.access,
                    "offset": offset,
                    "offset_hex": f"0x{offset:04x}",
                    "name": name,
                    "value": int(value_hex, 16),
                    "value_hex": value_hex,
                    "boot_id_before": metadata["boot_id_before"],
                    "boot_id_after": metadata["boot_id_after"],
                    "boot_id_stable": metadata["boot_id_stable"],
                    "hazard_count": metadata["hazard_count"],
                    "hazard_grep_clean": metadata["hazard_grep_clean"],
                    "classification": metadata["classification"],
                    "verdict": verdict_for(mode, metadata["classification"]),
                    "source_codes": getattr(policy_row, "source", ""),
                    "policy_notes": getattr(policy_row, "notes", ""),
                    "observed_from": str(stdout_path.relative_to(bundle_dir)),
                }
            )

    return observations


def read_existing_observations(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as stream:
        for raw_line in stream:
            line = raw_line.strip()
            if line:
                records.append(json.loads(line))
    return records


def bundle_metadata(bundle_dir: Path) -> dict[str, Any]:
    run_manifest_path = bundle_dir / "run_manifest.json"
    manifest_text_path = bundle_dir / "manifest.txt"
    run_status_path = bundle_dir / "run_status.tsv"
    if not run_status_path.exists():
        return {}

    run_manifest = load_json(run_manifest_path) if run_manifest_path.exists() else {}
    manifest_text = load_manifest_text(manifest_text_path)
    run_status = load_tsv_map(run_status_path)
    return {
        "bundle_id": run_manifest.get("run_id", bundle_dir.name),
        "host": run_manifest.get("host", manifest_text.get("host", "unknown")),
        "timestamp_utc": run_manifest.get(
            "timestamp_utc", manifest_text.get("timestamp_utc", "")
        ),
        "mode": run_manifest.get("mode", manifest_text.get("mode", "inventory")),
        "boot_id_before": run_status.get("boot_id_before", "none") or None,
        "boot_id_after": run_status.get("boot_id_after", "none") or None,
        "boot_id_stable": parse_bool(run_status.get("boot_id_stable", "none")),
        "hazard_count": parse_int(run_status.get("hazard_match_count", "none")),
        "hazard_grep_clean": parse_bool(run_status.get("hazard_grep_clean", "none")),
        "classification": run_status.get("classification", "unknown"),
    }


def load_bundle_observations(
    bundle_dir: Path,
    policy: dict[tuple[str, int, str], RegisterRow],
) -> list[dict[str, Any]]:
    metadata = bundle_metadata(bundle_dir)
    if not metadata:
        return []
    existing = bundle_dir / "register_observations.jsonl"
    if existing.exists():
        return read_existing_observations(existing)
    return iter_stdout_observations(bundle_dir, metadata, policy)


def collect_observations(
    *,
    bundle_dir: Path | None,
    result_root: Path | None,
    policy: dict[tuple[str, int, str], RegisterRow],
) -> list[dict[str, Any]]:
    if bundle_dir is not None:
        bundle_dirs = [bundle_dir]
    elif result_root is not None:
        bundle_dirs = sorted(path for path in result_root.iterdir() if path.is_dir())
    else:
        die("expected --bundle-dir or --result-root")

    observations: list[dict[str, Any]] = []
    for current_bundle_dir in bundle_dirs:
        observations.extend(load_bundle_observations(current_bundle_dir, policy))
    observations.sort(
        key=lambda item: (
            item["bundle_id"],
            item["surface"],
            item["cohort"],
            item["offset"],
            item["name"],
            item.get("register_path") or "",
        )
    )
    return observations


def write_jsonl(records: list[dict[str, Any]], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as stream:
        for record in records:
            stream.write(json.dumps(record, sort_keys=True))
            stream.write("\n")


def write_summary(records: list[dict[str, Any]], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    grouped: dict[tuple[str, str, str, int, str], dict[str, Any]] = {}

    for record in records:
        key = (
            record["surface"],
            record["cohort"],
            record["access"],
            record["offset"],
            record["name"],
        )
        current = grouped.get(key)
        if current is None:
            current = {
                "source_codes": record["source_codes"],
                "read_count": 0,
                "bundle_ids": set(),
                "register_paths": set(),
                "total_hazard_count": 0,
                "latest_timestamp_utc": "",
                "latest_bundle_id": "",
                "latest_boot_id": "",
                "latest_classification": "",
                "latest_verdict": "",
            }
            grouped[key] = current
        current["read_count"] += 1
        current["bundle_ids"].add(record["bundle_id"])
        if record.get("register_path"):
            current["register_paths"].add(record["register_path"])
        if isinstance(record["hazard_count"], int):
            current["total_hazard_count"] += record["hazard_count"]
        if record["timestamp_utc"] >= current["latest_timestamp_utc"]:
            current["latest_timestamp_utc"] = record["timestamp_utc"]
            current["latest_bundle_id"] = record["bundle_id"]
            current["latest_boot_id"] = record["boot_id_after"] or ""
            current["latest_classification"] = record["classification"]
            current["latest_verdict"] = record["verdict"]

    with path.open("w", encoding="utf-8") as stream:
        stream.write(
            "\t".join(
                [
                    "surface",
                    "cohort",
                    "access",
                    "offset_hex",
                    "name",
                    "source_codes",
                    "read_count",
                    "bundle_count",
                    "total_hazard_count",
                    "latest_bundle_id",
                    "latest_boot_id",
                    "latest_classification",
                    "latest_verdict",
                    "register_paths",
                ]
            )
        )
        stream.write("\n")
        for key in sorted(grouped):
            surface, cohort, access, offset, name = key
            current = grouped[key]
            stream.write(
                "\t".join(
                    [
                        surface,
                        cohort,
                        access,
                        f"0x{offset:04x}",
                        name,
                        current["source_codes"],
                        str(current["read_count"]),
                        str(len(current["bundle_ids"])),
                        str(current["total_hazard_count"]),
                        current["latest_bundle_id"],
                        str(current["latest_boot_id"]),
                        current["latest_classification"],
                        current["latest_verdict"],
                        "|".join(sorted(current["register_paths"])),
                    ]
                )
            )
            stream.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Build RS482 register observation records from retained safe/candidate "
            "bundles, and optionally aggregate them into a validation summary."
        )
    )
    parser.add_argument("--safe-tsv", required=True, type=Path)
    parser.add_argument("--candidate-tsv", required=True, type=Path)
    parser.add_argument("--bundle-dir", type=Path)
    parser.add_argument("--result-root", type=Path)
    parser.add_argument("--records-out", type=Path)
    parser.add_argument("--summary-out", type=Path)
    args = parser.parse_args()

    if args.bundle_dir is None and args.result_root is None:
        die("expected --bundle-dir or --result-root")

    policy = build_policy_map(args.safe_tsv, args.candidate_tsv)
    observations = collect_observations(
        bundle_dir=args.bundle_dir,
        result_root=args.result_root,
        policy=policy,
    )

    if args.records_out:
        write_jsonl(observations, args.records_out)
    if args.summary_out:
        write_summary(observations, args.summary_out)
    if not args.records_out and not args.summary_out:
        for observation in observations:
            print(json.dumps(observation, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
