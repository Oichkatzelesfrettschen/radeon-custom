#!/bin/sh
# check_display_oracle_usage: reject graphical.target as a display verdict.
#
# systemctl is-active graphical.target stays active while a parked GPU
# rejects every modeset and the panel is dark, so a verdict script that
# branches on it claims display health from orchestration state. A tracked
# script may report the value on a line that names it "orchestration state";
# any other graphical.target use in a conditional context is rejected.
# Display verdicts come from check_radeon_display_health.sh.
#
# usage: check_display_oracle_usage.sh [--root DIR] [--selftest]
set -u

root=""
selftest=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) root=$2; shift 2 ;;
        --selftest) selftest=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

scan_file() {
    # Exit 1 when the file judges graphical.target; the sanctioned reporting
    # line names it orchestration state.
    awk '
        # An assignment capture (var=$(...)) records the value for reporting;
        # a line naming it orchestration state is the sanctioned report form.
        # Branching on the unit state (if/&&/then) or coupling it to a verdict
        # token claims display health from orchestration state.
        /graphical\.target/ && !/orchestration state/ && !/=\$\(/ {
            if ($0 ~ /if |&&|then|verdict|PASS|ok\(|bad\(/) {
                print FILENAME ":" FNR ": graphical.target used as a verdict: " $0
                bad = 1
            }
        }
        END { exit bad }
    ' "$1"
}

if [ "$selftest" -eq 1 ]; then
    tmp=$(mktemp -d) || exit 2
    trap 'rm -rf "$tmp"' EXIT INT TERM
    fails=0

    cat > "$tmp/good.sh" <<'EOF'
gt=$(systemctl is-active graphical.target 2>/dev/null || true)
echo "  INFO  graphical.target=$gt (orchestration state, not display health)"
EOF
    if scan_file "$tmp/good.sh" >/dev/null; then
        echo "selftest known-good accepted: orchestration-state report"
    else
        echo "selftest known-good REJECTED" >&2; fails=$((fails + 1))
    fi

    cat > "$tmp/bad1.sh" <<'EOF'
if systemctl is-active --quiet graphical.target; then
    echo "  PASS  display healthy"
fi
EOF
    cat > "$tmp/bad2.sh" <<'EOF'
systemctl is-active --quiet graphical.target && ok "display up"
EOF
    for bad in bad1 bad2; do
        if scan_file "$tmp/$bad.sh" >/dev/null; then
            echo "selftest known-bad ACCEPTED: $bad" >&2; fails=$((fails + 1))
        else
            echo "selftest known-bad rejected: $bad"
        fi
    done

    [ "$fails" -eq 0 ] || { echo "selftest: $fails misclassified" >&2; exit 1; }
    echo "selftest: 1 good and 2 bad fixtures classified"
    exit 0
fi

[ -n "$root" ] || root=$(git rev-parse --show-toplevel) || exit 2
bad=0
# The checker's own rule text and fixtures name the rejected pattern, so the
# scan covers every tracked script but this one.
for f in $(git -C "$root" ls-files '*.sh' '*.py'); do
    case "$f" in
        */check_display_oracle_usage.sh) continue ;;
    esac
    scan_file "$root/$f" || bad=1
done
if [ "$bad" -ne 0 ]; then
    echo "check_display_oracle_usage: FAIL"
    exit 1
fi
echo "check_display_oracle_usage: no script judges graphical.target"
exit 0
