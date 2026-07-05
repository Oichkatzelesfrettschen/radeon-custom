#!/usr/bin/env python3
"""Generate or verify RS480 debugfs register arrays from TSV policy."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RegisterRow:
    offset: int
    name: str
    cohort: str
    access: str
    source: str
    notes: str


ROW_RE = re.compile(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"\s*\}')
ROW_WITH_ACCESS_RE = re.compile(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"\s*,\s*([01])\s*\}')
COHORT_RE = re.compile(r"(?:^|[ ;,])cohort=([A-Za-z0-9_-]+)")
CANDIDATE_COHORT_PREFIXES = (
    (("CONFIG_",), "config"),
    (("MC_", "AGP_", "NB_"), "gart_mc"),
    (("CRTC", "FP_", "FP2_", "LVDS_", "DAC_", "GPIO_", "DISP_"), "display"),
    (("RBBM_",), "rbbm"),
    (("RB3D_",), "rb3d"),
    (("ZB_",), "zb"),
    (("SC_",), "sc"),
    (("VAP_", "R300_VAP_"), "vap"),
    (("GB_",), "gb"),
    (("GA_", "R300_GA_", "R500_GA_"), "ga"),
    (("SU_",), "su"),
)


def die(message: str) -> None:
    print(f"generate_rs480_debugfs_fragments: {message}", file=sys.stderr)
    raise SystemExit(1)


def infer_candidate_cohort(name: str, notes: str) -> str:
    match = COHORT_RE.search(notes)
    if match:
        return match.group(1).replace("-", "_")
    if "GART" in name:
        return "gart_mc"
    for prefixes, cohort in CANDIDATE_COHORT_PREFIXES:
        if name.startswith(prefixes):
            return cohort
    return "misc"


def infer_safe_cohort(name: str, notes: str) -> str:
    match = COHORT_RE.search(notes)
    if match:
        return match.group(1).replace("-", "_")
    if name.startswith(("CRTC", "FP_", "FP2_", "LVDS_", "DAC_", "GPIO_", "DISP_")):
        return "display"
    if name.startswith("RBBM_"):
        return "rbbm"
    if name.startswith(("CONFIG_", "MC_", "AGP_", "NB_")):
        return "memory_config"
    if name.startswith("BIOS_"):
        return "bios_scratch"
    if name in {"ADAPTER_ID", "COMMAND", "STATUS", "CACHE_LINE", "CAPABILITIES_ID"}:
        return "identity"
    return "safe"


def read_tsv(path: Path, *, candidate: bool) -> list[RegisterRow]:
    rows: list[RegisterRow] = []
    with path.open("r", encoding="utf-8") as stream:
        for line_number, raw_line in enumerate(stream, 1):
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 2:
                die(f"{path}:{line_number}: expected offset and name columns")
            try:
                offset = int(fields[0], 16)
            except ValueError:
                die(f"{path}:{line_number}: invalid hex offset {fields[0]!r}")
            name = fields[1]
            access = "mmio"
            source = fields[2] if len(fields) > 2 else ""
            notes_index = 3
            if candidate:
                if len(fields) <= 2:
                    die(
                        f"{path}:{line_number}: candidate row must include "
                        "an explicit 'mmio' or 'mc' access column"
                    )
                if fields[2] not in {"mmio", "mc"}:
                    die(
                        f"{path}:{line_number}: candidate access column must be "
                        f"'mmio' or 'mc', got {fields[2]!r}"
                    )
                access = fields[2]
                source = fields[3] if len(fields) > 3 else ""
                notes_index = 4
            notes = fields[notes_index] if len(fields) > notes_index else ""
            cohort = (
                infer_candidate_cohort(name, notes) if candidate else infer_safe_cohort(name, notes)
            )
            rows.append(
                RegisterRow(
                    offset=offset,
                    name=name,
                    cohort=cohort,
                    access=access,
                    source=source,
                    notes=notes,
                )
            )
    if not rows:
        die(f"{path}: no register rows found")
    return rows


def extract_patch_rows(
    path: Path, *, include_access: bool = False, added_only: bool = False
) -> list[RegisterRow]:
    rows: list[RegisterRow] = []
    row_re = ROW_WITH_ACCESS_RE if include_access else ROW_RE
    with path.open("r", encoding="utf-8") as stream:
        for raw_line in stream:
            if added_only and not raw_line.startswith("+"):
                continue
            line = raw_line[1:] if added_only and raw_line.startswith("+") else raw_line
            match = row_re.search(line)
            if not match:
                continue
            if include_access and match.group(3) is None:
                die(f"{path}: candidate patch row is missing the access flag")
            rows.append(
                RegisterRow(
                    offset=int(match.group(1), 16),
                    name=match.group(2),
                    cohort="patch",
                    access="mc" if include_access and match.group(3) == "1" else "mmio",
                    source="",
                    notes="",
                )
            )
    if not rows:
        die(f"{path}: no C array rows found")
    return rows


def extract_candidate_patch_rows(
    candidate_patch: Path, candidate_extra_patches: list[Path]
) -> list[RegisterRow]:
    rows = extract_patch_rows(candidate_patch, include_access=True)
    for candidate_extra_patch in candidate_extra_patches:
        rows.extend(
            extract_patch_rows(
                candidate_extra_patch,
                include_access=True,
                added_only=True,
            )
        )
    return rows


def compare_rows(label: str, expected: list[RegisterRow], actual: list[RegisterRow]) -> None:
    expected_pairs = [(row.offset, row.name, row.access) for row in expected]
    actual_pairs = [(row.offset, row.name, row.access) for row in actual]
    if expected_pairs == actual_pairs:
        print(f"{label}: ok ({len(expected_pairs)} rows)")
        return

    print(f"{label}: row mismatch", file=sys.stderr)
    max_rows = max(len(expected_pairs), len(actual_pairs))
    for index in range(max_rows):
        expected_row = expected_pairs[index] if index < len(expected_pairs) else None
        actual_row = actual_pairs[index] if index < len(actual_pairs) else None
        if expected_row == actual_row:
            continue
        print(
            f"  row {index + 1}: expected {expected_row!r}, saw {actual_row!r}",
            file=sys.stderr,
        )
    raise SystemExit(1)


def format_array(
    struct_name: str, array_name: str, rows: list[RegisterRow], *, include_access: bool
) -> str:
    lines = [f"static const struct {struct_name} {array_name}[] = {{"]
    for row in rows:
        if include_access:
            lines.append(
                f'\t{{ 0x{row.offset:04x}, "{row.name}", {1 if row.access == "mc" else 0} }},'
            )
        else:
            lines.append(f'\t{{ 0x{row.offset:04x}, "{row.name}" }},')
    lines.append("};")
    lines.append("")
    return "\n".join(lines)


def write_fragments(
    output_dir: Path, safe_rows: list[RegisterRow], candidate_rows: list[RegisterRow]
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    fragments = {
        "rs480_safe_reg_list.inc": format_array(
            "rs480_safe_reg",
            "rs480_safe_reg_list",
            safe_rows,
            include_access=False,
        ),
    }
    cohorts = sorted({row.cohort for row in candidate_rows})
    for cohort in cohorts:
        cohort_rows = [row for row in candidate_rows if row.cohort == cohort]
        fragments[f"rs480_candidate_{cohort}_reg_list.inc"] = format_array(
            "rs480_candidate_reg",
            f"rs480_candidate_{cohort}_reg_list",
            cohort_rows,
            include_access=True,
        )
    for filename, contents in fragments.items():
        (output_dir / filename).write_text(contents, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate RS480/RS482/RS485 debugfs register C fragments from TSV "
            "policy, or verify retained patches against the TSVs."
        )
    )
    parser.add_argument("--safe-tsv", required=True, type=Path)
    parser.add_argument("--candidate-tsv", required=True, type=Path)
    parser.add_argument("--safe-patch", type=Path)
    parser.add_argument("--safe-extra-patch", action="append", default=[], type=Path)
    parser.add_argument("--candidate-patch", type=Path)
    parser.add_argument("--candidate-extra-patch", action="append", default=[], type=Path)
    parser.add_argument("--candidate-skip-cohort", action="append", default=[])
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="write fragment files into this directory; existing files are overwritten",
    )
    parser.add_argument(
        "--check-patches",
        action="store_true",
        help="compare retained patch arrays with the TSV-derived arrays",
    )
    args = parser.parse_args()

    safe_rows = read_tsv(args.safe_tsv, candidate=False)
    candidate_rows = read_tsv(args.candidate_tsv, candidate=True)

    if args.output_dir:
        write_fragments(args.output_dir, safe_rows, candidate_rows)

    if args.check_patches:
        if not args.safe_patch or not args.candidate_patch:
            die("--check-patches requires --safe-patch and --candidate-patch")
        safe_patch_rows = extract_patch_rows(args.safe_patch, include_access=False)
        for safe_extra_patch in args.safe_extra_patch:
            safe_patch_rows.extend(
                extract_patch_rows(
                    safe_extra_patch,
                    include_access=False,
                    added_only=True,
                )
            )
        compare_rows("safe-regs patch", safe_rows, safe_patch_rows)
        skipped_candidate_cohorts = set(args.candidate_skip_cohort)
        candidate_expected_rows = [
            row for row in candidate_rows if row.cohort not in skipped_candidate_cohorts
        ]
        candidate_patch_rows = extract_candidate_patch_rows(
            args.candidate_patch, args.candidate_extra_patch
        )
        compare_rows("candidate-regs patch", candidate_expected_rows, candidate_patch_rows)
        skipped_count = len(candidate_rows) - len(candidate_expected_rows)
        if skipped_count:
            print(
                "candidate-regs patch: skipped "
                f"{skipped_count} rows in design-only cohorts "
                f"{','.join(sorted(skipped_candidate_cohorts))}"
            )

    if not args.output_dir and not args.check_patches:
        print(
            format_array(
                "rs480_safe_reg",
                "rs480_safe_reg_list",
                safe_rows,
                include_access=False,
            )
        )
        cohorts = sorted({row.cohort for row in candidate_rows})
        for cohort in cohorts:
            print(
                format_array(
                    "rs480_candidate_reg",
                    f"rs480_candidate_{cohort}_reg_list",
                    [row for row in candidate_rows if row.cohort == cohort],
                    include_access=True,
                )
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
