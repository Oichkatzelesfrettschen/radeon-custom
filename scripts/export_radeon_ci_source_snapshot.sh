#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Terascale Functionalists
# Export an immutable, job-private Git checkout from a shared Radeon source root.

set -eu

usage() {
    cat <<'EOF'
usage: export_radeon_ci_source_snapshot.sh --source-repository DIR --source-commit SHA --destination DIR
       export_radeon_ci_source_snapshot.sh --self-test

Copies one committed source identity into a job-private checkout without
modifying the shared source repository.
EOF
}

die() {
    printf 'export_radeon_ci_source_snapshot: %s\n' "$*" >&2
    exit 2
}

export_snapshot() {
    source_repository=$1
    source_commit=$2
    destination=$3

    [ -d "$source_repository" ] || die "source repository is absent: $source_repository"
    [ -d "$source_repository/.git" ] ||
        [ -f "$source_repository/.git" ] ||
        die "source repository has no Git directory: $source_repository"
    case $source_commit in
        *[!0-9a-f]* | ?????? | ??????? | ???????? | ????????[!0-9a-f]*)
            die "source commit is not a lowercase 40-hex object ID"
            ;;
    esac
    [ "${#source_commit}" -eq 40 ] ||
        die "source commit is not a lowercase 40-hex object ID"
    [ ! -e "$destination" ] || die "destination already exists: $destination"
    git -C "$source_repository" cat-file -e "${source_commit}^{commit}" ||
        die "source commit is absent from the shared source repository"

    git clone --no-local --no-checkout "$source_repository" "$destination"
    git -C "$destination" checkout --detach "$source_commit"
    actual_commit=$(git -C "$destination" rev-parse HEAD)
    [ "$actual_commit" = "$source_commit" ] ||
        die "private source checkout is $actual_commit, expected $source_commit"
    git -C "$destination" diff --quiet ||
        die "private source checkout has uncommitted changes"
}

source_repository=''
source_commit=''
destination=''
self_test=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --source-repository)
            [ "$#" -ge 2 ] || die "--source-repository requires a path"
            source_repository=$2
            shift 2
            ;;
        --source-commit)
            [ "$#" -ge 2 ] || die "--source-commit requires an object ID"
            source_commit=$2
            shift 2
            ;;
        --destination)
            [ "$#" -ge 2 ] || die "--destination requires a path"
            destination=$2
            shift 2
            ;;
        --self-test)
            self_test=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [ "$self_test" -eq 1 ]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT INT TERM
    source_fixture="$work/source"
    git init -q "$source_fixture"
    git -C "$source_fixture" config user.name 'Radeon CI fixture'
    git -C "$source_fixture" config user.email 'radeon-ci-fixture@example.invalid'
    printf 'committed source\n' > "$source_fixture/radeon.c"
    git -C "$source_fixture" add radeon.c
    git -C "$source_fixture" commit -qm 'fixture source'
    fixture_commit=$(git -C "$source_fixture" rev-parse HEAD)
    printf 'uncommitted source\n' > "$source_fixture/radeon.c"
    export_snapshot "$source_fixture" "$fixture_commit" "$work/private"
    [ "$(git -C "$work/private" rev-parse HEAD)" = "$fixture_commit" ] ||
        die "known-good export does not retain the requested commit"
    [ "$(sed -n '1p' "$work/private/radeon.c")" = 'committed source' ] ||
        die "known-good export observes shared worktree content"
    printf 'PASS known-good: private checkout retains the requested committed source\n'

    if ( export_snapshot "$source_fixture" \
        0000000000000000000000000000000000000000 "$work/missing" \
        >/dev/null 2>&1 ); then
        die "known-bad export accepts an absent commit"
    fi
    printf 'PASS known-bad: absent source commit is rejected\n'

    if ( export_snapshot "$source_fixture" "$fixture_commit" "$work/private" \
        >/dev/null 2>&1 ); then
        die "known-bad export accepts an existing destination"
    fi
    printf 'PASS known-bad: existing destination is rejected\n'
    exit 0
fi

[ -n "$source_repository" ] || die "--source-repository is required"
[ -n "$source_commit" ] || die "--source-commit is required"
[ -n "$destination" ] || die "--destination is required"
export_snapshot "$source_repository" "$source_commit" "$destination"
printf 'job-private source checkout: %s at %s\n' "$destination" "$source_commit"
