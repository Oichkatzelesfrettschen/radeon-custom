#!/usr/bin/env python3
"""Verify the bounded RS400 GART reader schema and decode contract."""

from __future__ import annotations

import argparse
import ast
import re
from pathlib import Path


EXPECTED_FIELDS = (
    "row_type",
    "start_index",
    "end_index_exclusive",
    "gpu_address",
    "pte_raw",
    "page_dma_address",
    "unsnooped",
    "writeable",
    "readable",
    "backing_class",
    "table_dma",
    "table_bytes",
    "table_entries",
    "kernel_pte_raw",
    "kernel_pte_level",
    "pwt",
    "pcd",
    "pat",
    "pat_index",
    "status",
)


class VerificationError(RuntimeError):
    """Report a violated reader or evidence-schema contract."""


def fail(message: str) -> None:
    raise VerificationError(message)


def c_code_only(source: str) -> str:
    output: list[str] = []
    state = "code"
    index = 0

    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""

        if state == "code":
            if character == "/" and following == "/":
                output.extend((" ", " "))
                state = "line-comment"
                index += 2
                continue
            if character == "/" and following == "*":
                output.extend((" ", " "))
                state = "block-comment"
                index += 2
                continue
            if character == '"':
                output.append(" ")
                state = "string"
                index += 1
                continue
            if character == "'":
                output.append(" ")
                state = "character"
                index += 1
                continue
            output.append(character)
            index += 1
            continue

        if state == "line-comment":
            output.append("\n" if character == "\n" else " ")
            if character == "\n":
                state = "code"
            index += 1
            continue

        if state == "block-comment":
            if character == "*" and following == "/":
                output.extend((" ", " "))
                state = "code"
                index += 2
                continue
            output.append("\n" if character == "\n" else " ")
            index += 1
            continue

        if character == "\\" and following:
            output.append("\n" if character == "\n" else " ")
            output.append("\n" if following == "\n" else " ")
            index += 2
            continue

        delimiter = '"' if state == "string" else "'"
        output.append("\n" if character == "\n" else " ")
        if character == delimiter:
            state = "code"
        index += 1

    return "".join(output)


def c_function(source: str, signature: str) -> str:
    source = c_code_only(source)
    search_offset = 0
    while True:
        start = source.find(signature, search_offset)
        if start < 0:
            fail(f"function definition is missing: {signature}")
        opening_brace = source.find("{", start)
        semicolon = source.find(";", start)
        if opening_brace >= 0 and (semicolon < 0 or opening_brace < semicolon):
            break
        search_offset = start + len(signature)

    depth = 0
    state = "code"
    index = opening_brace
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""

        if state == "line-comment":
            if character == "\n":
                state = "code"
        elif state == "block-comment":
            if character == "*" and following == "/":
                state = "code"
                index += 1
        elif state in ("string", "character"):
            delimiter = '"' if state == "string" else "'"
            if character == "\\":
                index += 1
            elif character == delimiter:
                state = "code"
        elif character == "/" and following == "/":
            state = "line-comment"
            index += 1
        elif character == "/" and following == "*":
            state = "block-comment"
            index += 1
        elif character == '"':
            state = "string"
        elif character == "'":
            state = "character"
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]

        index += 1

    fail(f"function body is unterminated: {signature}")


def require_order(function: str, function_name: str, tokens: tuple[str, ...]) -> None:
    offset = 0
    for token in tokens:
        position = function.find(token, offset)
        if position < 0:
            fail(f"{function_name} does not preserve lock order at: {token}")
        offset = position + len(token)


def verify_lock_coverage(source: str) -> None:
    teardown = c_function(source, "void rs400_gart_fini(")
    reader = c_function(source, "static int rs400_debugfs_gart_page_table_show(")
    lock = "mutex_lock(&rs400_gart_page_table_lock);"
    unlock = "mutex_unlock(&rs400_gart_page_table_lock);"

    if teardown.count(lock) != 1 or teardown.count(unlock) != 1:
        fail("rs400_gart_fini must contain one balanced GART lifetime lock")
    require_order(
        teardown,
        "rs400_gart_fini",
        (
            lock,
            "radeon_gart_fini(rdev);",
            "rs400_gart_disable(rdev);",
            "radeon_gart_table_ram_free(rdev);",
            unlock,
        ),
    )

    if reader.count(lock) != 1 or reader.count(unlock) != 2:
        fail("GART reader must contain one lock and two bounded unlock paths")
    require_order(
        reader,
        "rs400_debugfs_gart_page_table_show",
        (
            lock,
            "if (!rdev->gart.ready || !rdev->gart.ptr)",
            unlock,
            "return 0;",
            "table = rdev->gart.ptr;",
            "rs400_debugfs_gart_cpu_mapping_emit(m, rdev, 0);",
            "READ_ONCE(table[index])",
            unlock,
        ),
    )


def verify_lock_negative_tests(source: str) -> None:
    lock = "\tmutex_lock(&rs400_gart_page_table_lock);\n"
    unlock = "\tmutex_unlock(&rs400_gart_page_table_lock);\n"
    free = "\tradeon_gart_table_ram_free(rdev);\n"
    table_assignment = "\ttable = rdev->gart.ptr;\n"
    final_return = f"{unlock}\treturn 0;"

    teardown_unlocked_early = source.replace(f"{free}{unlock}", f"{unlock}{free}", 1)
    reader_unlocked_early = source.replace(final_return, "\treturn 0;", 1)
    reader_unlocked_early = reader_unlocked_early.replace(
        table_assignment, f"{table_assignment}{unlock}", 1
    )
    commented_lock = source.replace(lock, f"\t/* {lock.strip()} */\n", 1)
    commented_unlock = source.replace(unlock, f"\t/* {unlock.strip()} */\n", 1)

    if any(
        variant == source
        for variant in (
            teardown_unlocked_early,
            reader_unlocked_early,
            commented_lock,
            commented_unlock,
        )
    ):
        fail("negative lock mutation could not be constructed")

    for name, variant in (
        ("teardown-unlocked-before-free", teardown_unlocked_early),
        ("reader-unlocked-before-reads", reader_unlocked_early),
        ("commented-lock", commented_lock),
        ("commented-unlock", commented_unlock),
    ):
        try:
            verify_lock_coverage(variant)
        except VerificationError:
            continue
        fail(f"negative lock mutation passed: {name}")


def verify_debugfs_registration(source: str) -> None:
    registration = c_function(source, "void radeon_rs480_re_debugfs_register(")
    early_initializer = c_function(
        source, "static void rs400_debugfs_pcie_gart_info_init("
    )
    reader_operations = "rs400_debugfs_gart_page_table_fops"

    if registration.count(reader_operations) != 1:
        fail("DRM primary-minor callback must register the GART reader exactly once")
    if re.search(
        r"debugfs_create_file\s*\([^;]*minor->debugfs_root[^;]*"
        r"rs400_debugfs_gart_page_table_fops\s*\)",
        registration,
        re.DOTALL,
    ) is None:
        fail("GART reader registration must use the assigned primary-minor debugfs root")
    if reader_operations in early_initializer:
        fail("early GART initialization must not register the debugfs reader")


def verify_debugfs_registration_negative_tests(source: str) -> None:
    missing_root = source.replace(
        "minor->debugfs_root, rdev, &rs400_debugfs_gart_page_table_fops",
        "root, rdev, &rs400_debugfs_gart_page_table_fops",
        1,
    )
    early_registration = source.replace(
        "&rs400_debugfs_gart_info_fops);",
        "&rs400_debugfs_gart_info_fops);\n\t(void)&rs400_debugfs_gart_page_table_fops;",
        1,
    )
    if missing_root == source or early_registration == source:
        fail("negative debugfs registration mutation could not be constructed")

    for name, variant in (
        ("missing-primary-minor-root", missing_root),
        ("early-reader-registration", early_registration),
    ):
        try:
            verify_debugfs_registration(variant)
        except VerificationError:
            continue
        fail(f"negative debugfs registration mutation passed: {name}")


def c_string_value(expression: str) -> str:
    tokens = re.findall(r'"(?:\\.|[^"\\])*"', expression)
    return "".join(ast.literal_eval(token) for token in tokens)


def tsv_formats(source: str) -> list[str]:
    start = source.index("static void rs400_debugfs_gart_cpu_mapping_emit")
    end = source.index("DEFINE_SHOW_ATTRIBUTE(rs400_debugfs_gart_page_table)")
    reader = source[start:end]
    calls = re.finditer(
        r"seq_(?:printf|puts)\s*\(\s*m\s*,(.*?)\);", reader, re.DOTALL
    )
    return [value for call in calls if "\t" in (value := c_string_value(call.group(1)))]


def decode_page_dma_address(entry: int) -> int:
    return (entry & 0xFFFFF000) | ((entry & 0x00000FF0) << 28)


def encode_page_dma_address(address: int, flags: int) -> int:
    return (address & 0xFFFFF000) | (((address >> 32) & 0xFF) << 4) | flags


def verify_dma_round_trips() -> None:
    for upper in range(256):
        for low_page in (0, 1, 0x12345, 0xFFFFF):
            address = (upper << 32) | (low_page << 12)
            for flags in (0, 1, 4, 8, 13):
                entry = encode_page_dma_address(address, flags)
                if decode_page_dma_address(entry) != address:
                    fail(f"DMA round trip fails for 0x{address:010x} flags={flags}")


def verify_source(path: Path) -> None:
    source = path.read_text(encoding="ascii")
    formats = tsv_formats(source)
    if not formats:
        fail("no TSV output calls found")

    expected_tabs = len(EXPECTED_FIELDS) - 1
    for index, value in enumerate(formats, start=1):
        if value.count("\t") != expected_tabs:
            fail(
                f"TSV format {index} has {value.count(chr(9)) + 1} fields; "
                f"expected {len(EXPECTED_FIELDS)}"
            )

    header = next((value for value in formats if value.startswith("row_type\t")), None)
    if header is None or tuple(header.rstrip("\n").split("\t")) != EXPECTED_FIELDS:
        fail("header does not match the canonical 20-field schema")

    required = (
        "#define RS400_GART_PAGE_TABLE_ENTRY_LIMIT 64",
        "__le32 *table;",
        "static DEFINE_MUTEX(rs400_gart_page_table_lock);",
        "mutex_lock(&rs400_gart_page_table_lock);",
        "mutex_unlock(&rs400_gart_page_table_lock);",
        "level == PG_LEVEL_4K",
        "raw & _PAGE_PAT",
        "level == PG_LEVEL_2M || level == PG_LEVEL_1G",
        "raw & _PAGE_PAT_LARGE",
        "page_dma_address",
        "non-dummy-backing",
        'debugfs_create_file("radeon_rs480_gart_page_table", 0400',
    )
    for token in required:
        if token not in source:
            fail(f"required source contract is missing: {token}")

    verify_lock_coverage(source)
    verify_lock_negative_tests(source)
    verify_debugfs_registration(source)
    verify_debugfs_registration_negative_tests(source)

    forbidden = ("shadow_raw", "shadow_match", "pages_entry[index]", "mapped-backing")
    for token in forbidden:
        if token in source[source.index("#define RS400_GART_PAGE_TABLE_ENTRY_LIMIT 64") :]:
            fail(f"unstable or overclaimed field remains: {token}")

    verify_dma_round_trips()
    print(
        "RS400 GART reader schema: "
        f"{len(formats)} output paths, {len(EXPECTED_FIELDS)} fields, DMA round trips pass"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="fully patched radeon/rs400.c")
    args = parser.parse_args()
    try:
        verify_source(args.source)
    except VerificationError as error:
        raise SystemExit(f"verify_rs400_gart_reader_schema: {error}") from None


if __name__ == "__main__":
    main()
