#!/bin/sh
# check_display_oracle_usage: reject graphical.target as a display verdict.
#
# systemctl is-active graphical.target stays active while a parked GPU
# rejects every modeset and the panel is dark, so a script that branches on
# it claims display health from orchestration state. The rule is declarative
# rather than pattern-guessing: a line naming graphical.target carries the
# words "orchestration state". Assignments and conditionals remain outside
# the reporting boundary even when they carry that annotation.
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
    # Exit 1 unless graphical.target appears in a pure policy comment or a
    # direct annotated INFO report. Assignments, captures, conditionals, and
    # multiline continuations fail closed at their source line.
    awk '
        function pure_comment(line) {
            return line ~ /^[[:space:]]*#/
        }

        function info_report(line, python) {
            if (tolower(line) !~ /orchestration state/ ||
                toupper(line) !~ /(^|[^[:alnum:]_])INFO([^[:alnum:]_]|$)/ ||
                line ~ /[;&|]/ || line ~ /\$\{[^}]*:=/ ||
                line ~ /\$\(\([^)]*=/ ||
                line ~ /(^|[^.[:alnum:]_])[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/)
                return 0
            if (python)
                return line !~ /:=/ &&
                    line ~ /^[[:space:]]*(print|logging\.[A-Za-z_][A-Za-z0-9_]*|logger\.[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(/
            if (line ~ /^[[:space:]]*printf[[:space:]]+-[^[:space:]]*v([[:space:]]|$)/)
                return 0
            return line ~ /^[[:space:]]*(echo|printf)([[:space:]]|$)/
        }

        /graphical\.target/ {
            python_file = FILENAME ~ /\.py$/
            if (pure_comment($0)) {
                if (tolower($0) !~ /orchestration state/) {
                    print FILENAME ":" FNR \
                        ": graphical.target comment lacks the orchestration-state annotation: " $0
                    bad = 1
                }
                next
            }
            if (info_report($0, python_file))
                next
            print FILENAME ":" FNR \
                ": graphical.target must be a pure annotated comment or INFO report: " $0
            bad = 1
        }
        END { exit bad }
    ' "$1"
}

if [ "$selftest" -eq 1 ]; then
    tmp=$(mktemp -d) || exit 2
    trap 'rm -rf "$tmp"' EXIT INT TERM
    fails=0
    good_count=0
    bad_count=0

    cat > "$tmp/good-shell.sh" <<'EOF'
echo "  INFO  graphical.target=$(systemctl is-active graphical.target 2>/dev/null) (orchestration state, not display health)"
EOF
    if scan_file "$tmp/good-shell.sh" >/dev/null; then
        echo "selftest known-good accepted: direct shell report"
        good_count=$((good_count + 1))
    else
        echo "selftest known-good REJECTED: direct shell report" >&2
        fails=$((fails + 1))
    fi

    cat > "$tmp/good-python.py" <<'EOF'
print("  INFO  graphical.target=%s (orchestration state, not display health)" % subprocess.check_output(["systemctl", "is-active", "graphical.target"]))
EOF
    if scan_file "$tmp/good-python.py" >/dev/null; then
        echo "selftest known-good accepted: direct Python report"
        good_count=$((good_count + 1))
    else
        echo "selftest known-good REJECTED: direct Python report" >&2
        fails=$((fails + 1))
    fi

    cat > "$tmp/good-comment.sh" <<'EOF'
# graphical.target carries orchestration state, not display health.
EOF
    if scan_file "$tmp/good-comment.sh" >/dev/null; then
        echo "selftest known-good accepted: annotated policy comment"
        good_count=$((good_count + 1))
    else
        echo "selftest known-good REJECTED: annotated policy comment" >&2
        fails=$((fails + 1))
    fi

    cat > "$tmp/bad1.sh" <<'EOF'
gt=$(systemctl is-active graphical.target)  # orchestration state
EOF
    cat > "$tmp/bad2.sh" <<'EOF'
local gt=$(systemctl is-active graphical.target)  # orchestration state
EOF
    cat > "$tmp/bad3.sh" <<'EOF'
export gt=$(systemctl is-active graphical.target)  # orchestration state
EOF
    cat > "$tmp/bad4.sh" <<'EOF'
readonly gt=$(systemctl is-active graphical.target)  # orchestration state
EOF
    cat > "$tmp/bad5.sh" <<'EOF'
gt=`systemctl is-active graphical.target`  # orchestration state
EOF
    cat > "$tmp/bad6.sh" <<'EOF'
gt[0]=$(systemctl is-active graphical.target)  # orchestration state
EOF
    cat > "$tmp/bad7.sh" <<'EOF'
prefix=1 gt=$(systemctl is-active graphical.target)  # orchestration state
EOF
    cat > "$tmp/bad8.sh" <<'EOF'
gt=$(systemctl is-active graphical.target)  # orchestration state
if [ "$gt" = active ]; then
    echo "  PASS  display healthy"
fi
EOF
    cat > "$tmp/bad9.py" <<'EOF'
gt = subprocess.check_output(["systemctl", "is-active", "graphical.target"])  # orchestration state
EOF
    cat > "$tmp/bad10.py" <<'EOF'
gt = (
    "graphical.target"  # orchestration state
)
EOF
    cat > "$tmp/bad11.py" <<'EOF'
gt: str = "graphical.target"  # orchestration state
EOF
    cat > "$tmp/bad12.py" <<'EOF'
result = (gt := "graphical.target")  # orchestration state
EOF
    cat > "$tmp/bad13.py" <<'EOF'
gt, state = ("graphical.target", "active")  # orchestration state
EOF
    cat > "$tmp/bad14.sh" <<'EOF'
if systemctl is-active --quiet graphical.target; then  # orchestration state
    echo "  PASS  display healthy"
fi
EOF
    cat > "$tmp/bad15.sh" <<'EOF'
systemctl is-active --quiet graphical.target && echo "  PASS  display healthy"  # orchestration state
EOF
    cat > "$tmp/bad16.sh" <<'EOF'
gt=$(\
    systemctl is-active graphical.target
)  # orchestration state
EOF
    cat > "$tmp/bad17.sh" <<'EOF'
printf -v gt "  INFO  graphical.target=active (orchestration state, not display health)"
EOF
    cat > "$tmp/bad18.sh" <<'EOF'
echo "  INFO  graphical.target=${gt:=$(systemctl is-active graphical.target)} (orchestration state, not display health)"
EOF
    cat > "$tmp/bad19.sh" <<'EOF'
echo "  INFO  graphical.target=$((gt=1)) (orchestration state, not display health)"
EOF
    cat > "$tmp/bad20.py" <<'EOF'
print("  INFO  graphical.target=%s (orchestration state, not display health)" % (gt := "active"))
EOF
    for bad in bad1 bad2 bad3 bad4 bad5 bad6 bad7 bad8 bad9 bad10 bad11 bad12 bad13 bad14 bad15 bad16 bad17 bad18 bad19 bad20; do
        bad_count=$((bad_count + 1))
        case "$bad" in
            bad9|bad10|bad11|bad12|bad13|bad20) fixture="$tmp/$bad.py" ;;
            *) fixture="$tmp/$bad.sh" ;;
        esac
        if scan_file "$fixture" >/dev/null; then
            echo "selftest known-bad ACCEPTED: $bad" >&2
            fails=$((fails + 1))
        else
            echo "selftest known-bad rejected: $bad"
        fi
    done

    [ "$fails" -eq 0 ] || { echo "selftest: $fails misclassified" >&2; exit 1; }
    echo "selftest: $good_count good and $bad_count bad fixtures classified"
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
