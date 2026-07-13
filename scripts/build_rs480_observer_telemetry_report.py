#!/usr/bin/env python3
"""Build a machine-readable RS480 observer/telemetry surface report."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
GENERATED_DIR = REPO_ROOT / "registry/generated"
JSON_PATH = GENERATED_DIR / "rs480_observer_telemetry.json"
TSV_PATH = GENERATED_DIR / "rs480_observer_telemetry.tsv"


@dataclass(frozen=True)
class SurfaceSpec:
    surface_id: str
    lane_state: str
    default_lane: str
    class_name: str
    description: str
    rationale: str
    required_globs: tuple[str, ...]


SURFACES: tuple[SurfaceSpec, ...] = (
    SurfaceSpec(
        surface_id="safe_regs",
        lane_state="present-rs480",
        default_lane="enabled-via-safe-gate",
        class_name="read-only-register-surface",
        description=(
            "RS480 safe register exposure through the DKMS-owned allow-listed "
            "debugfs surface."
        ),
        rationale=(
            "This is the bounded default live register lane for RS480; it is "
            "the positive control that candidate rows must stay outside of."
        ),
        required_globs=(
            "packaging/arch/radeon-unified-dkms/README.md",
            "patches/rs480/*safe-regs*.patch",
        ),
    ),
    SurfaceSpec(
        surface_id="candidate_regs",
        lane_state="present-rs480",
        default_lane="disabled-by-default-candidate-only",
        class_name="block-scoped-candidate-register-surface",
        description=(
            "Split RS480 candidate register debugfs cohorts for config, "
            "GART/MC, and 3D blocks."
        ),
        rationale=(
            "This surface expands reverse-engineering visibility, but the rows "
            "remain outside the safe-regs whitelist until owner-safe "
            "validation exists."
        ),
        required_globs=(
            "src/re/r300/scripts/run_vostro_safe_probe.sh",
            "src/re/r300/scripts/remote/r300-candidate-regs-read",
            "patches/rs480/*candidate-regs*.patch",
        ),
    ),
    SurfaceSpec(
        surface_id="force_pci_reset_safe",
        lane_state="present-rs480",
        default_lane="operator-invoked-recovery",
        class_name="bounded-recovery-surface",
        description=(
            "RS480 bounded PCI reset helper used as a recovery/control path."
        ),
        rationale=(
            "This is a real RS480 control surface, but it is not default "
            "telemetry; it exists to recover or rebaseline the lane safely."
        ),
        required_globs=(
            "src/re/r300/scripts/run_vostro_safe_probe.sh",
            "src/re/r300/scripts/**/*force*pci*reset*safe*",
        ),
    ),
    SurfaceSpec(
        surface_id="perf_query",
        lane_state="palm-only-staged",
        default_lane="not-rs480-default",
        class_name="advanced-telemetry-surface",
        description=(
            "Palm perf-query staging hooks for higher-rate hardware telemetry."
        ),
        rationale=(
            "The staging exists in the Palm lane only; RS480 should classify "
            "it as absent rather than silently imply parity."
        ),
        required_globs=(
            "packaging/debian/radeon-unified-dkms/prep-source.sh",
            "patches/palm/*perf-query*.patch",
        ),
    ),
    SurfaceSpec(
        surface_id="palm_cs_observer",
        lane_state="palm-only-staged",
        default_lane="not-rs480-default",
        class_name="advanced-command-stream-observer",
        description=(
            "Palm command-stream observer with retained event output."
        ),
        rationale=(
            "The Palm observer is a useful design reference, but RS480 does "
            "not yet own an equivalent default observer path."
        ),
        required_globs=(
            "packaging/debian/radeon-unified-dkms/prep-source.sh",
            "patches/palm/**/*palm*observer*.c",
        ),
    ),
)


def resolve_glob(pattern: str) -> list[str]:
    matches = sorted(
        str(path.relative_to(REPO_ROOT))
        for path in REPO_ROOT.glob(pattern)
        if path.is_file()
    )
    if not matches:
        raise SystemExit(f"missing required evidence glob: {pattern}")
    return matches


def build_report() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for spec in SURFACES:
        evidence_paths: list[str] = []
        for pattern in spec.required_globs:
            evidence_paths.extend(resolve_glob(pattern))
        rows.append(
            {
                "surface_id": spec.surface_id,
                "lane_state": spec.lane_state,
                "default_lane": spec.default_lane,
                "class": spec.class_name,
                "description": spec.description,
                "rationale": spec.rationale,
                "evidence_paths": evidence_paths,
            }
        )
    return rows


def write_json(rows: list[dict[str, object]]) -> None:
    payload = {
        "target": "rs480",
        "scope": "observer-telemetry",
        "status": "source-backed",
        "generated_from": "scripts/build_rs480_observer_telemetry_report.py",
        "rows": rows,
    }
    JSON_PATH.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_tsv(rows: list[dict[str, object]]) -> None:
    header = (
        "surface_id\tlane_state\tdefault_lane\tclass\tdescription\trationale\t"
        "evidence_paths\n"
    )
    lines = [header]
    for row in rows:
        lines.append(
            "\t".join(
                [
                    str(row["surface_id"]),
                    str(row["lane_state"]),
                    str(row["default_lane"]),
                    str(row["class"]),
                    str(row["description"]),
                    str(row["rationale"]),
                    ",".join(str(path) for path in row["evidence_paths"]),
                ]
            )
            + "\n"
        )
    TSV_PATH.write_text("".join(lines), encoding="utf-8")


def main() -> None:
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    rows = build_report()
    write_json(rows)
    write_tsv(rows)


if __name__ == "__main__":
    main()
