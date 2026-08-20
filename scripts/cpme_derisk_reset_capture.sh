#!/bin/sh
# Refuse a GPU reset capture from the package-authority repository.

printf '%s\n' \
    'REFUSED: hazardous hardware runners belong in steinmarder-r300.' \
    'Run make r300-hazard-check in that repository before an authorized probe.' \
    >&2
exit 3
