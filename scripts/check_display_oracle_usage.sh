#!/bin/sh
# check_display_oracle_usage: reject graphical.target as a display verdict.
#
# systemctl is-active graphical.target stays active while a parked GPU
# rejects every modeset and the panel is dark, so a script that branches on
# it claims display health from orchestration state. The rule is declarative
# rather than pattern-guessing: a line naming graphical.target carries the
# words "orchestration state", and a line naming it inside a conditional
# (if, elif, then, while, until, &&, ||) is rejected whatever else it says.
# The conditional test runs first, so annotating a branch buys nothing.
# Display verdicts come from check_radeon_display_health.sh.
#
# usage: check_display_oracle_usage.sh [--root DIR] [--self-test]
set -u

root=""
selftest=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) root=$2; shift 2 ;;
        --self-test) selftest=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

scan_file() {
    # Exit 1 when the file branches on graphical.target or names it without
    # the orchestration-state annotation.
    awk '
        /graphical\.target/ {
            if ($0 ~ /(^|[^[:alnum:]_])(if|elif|then|while|until)([^[:alnum:]_]|$)/ ||
                $0 ~ /&&/ || $0 ~ /\|\|/) {
                print FILENAME ":" FNR ": graphical.target in a conditional: " $0
                bad = 1
                next
            }
            if (tolower($0) !~ /orchestration state/) {
                print FILENAME ":" FNR \
                    ": graphical.target without the orchestration-state annotation: " $0
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
gt=$(systemctl is-active graphical.target 2>/dev/null)  # orchestration state
echo "  INFO  graphical.target=$gt (orchestration state, not display health)"
EOF
    if scan_file "$tmp/good.sh" >/dev/null; then
        echo "selftest known-good accepted: orchestration-state report"
    else
        echo "selftest known-good REJECTED" >&2; fails=$((fails + 1))
    fi

    # branch on the unit, short-circuit, capture inside the condition, split
    # condition across lines, and a branch carrying the annotation as cover.
    cat > "$tmp/bad1.sh" <<'EOF'
if systemctl is-active --quiet graphical.target; then
    echo "  PASS  display healthy"
fi
EOF
    cat > "$tmp/bad2.sh" <<'EOF'
systemctl is-active --quiet graphical.target && ok "display up"
EOF
    cat > "$tmp/bad3.sh" <<'EOF'
if gt=$(systemctl is-active --quiet graphical.target); then
    echo "  PASS  display healthy"
fi
EOF
    cat > "$tmp/bad4.sh" <<'EOF'
gt=$(systemctl is-active graphical.target)
[ "$gt" = active ] && echo "  PASS  display healthy"
EOF
    cat > "$tmp/bad5.sh" <<'EOF'
if systemctl is-active --quiet graphical.target; then  # orchestration state
    echo "  PASS  display healthy"
fi
EOF
    for bad in bad1 bad2 bad3 bad4 bad5; do
        if scan_file "$tmp/$bad.sh" >/dev/null; then
            echo "selftest known-bad ACCEPTED: $bad" >&2; fails=$((fails + 1))
        else
            echo "selftest known-bad rejected: $bad"
        fi
    done

    [ "$fails" -eq 0 ] || { echo "selftest: $fails misclassified" >&2; exit 1; }
    echo "selftest: 1 good and 5 bad fixtures classified"
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
