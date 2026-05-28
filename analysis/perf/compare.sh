#!/bin/bash
# perf/compare.sh - Side-by-side comparison of two perf profiles
#
# Usage:
#   ./perf/compare.sh <baseline.data> <patch.data> [options]
#
# Options:
#   --threshold PCT    Minimum overhead to show (default: 0.5)
#   --grep PATTERN     Filter symbols (case-insensitive)

set -e

THRESHOLD=0.5
GREP=""

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <baseline.data> <patch.data> [--threshold PCT] [--grep PATTERN]" >&2
    exit 1
fi

BASELINE="$1"; shift
PATCH="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --grep) GREP="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

for f in "$BASELINE" "$PATCH"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: $f not found" >&2
        exit 1
    fi
done

extract() {
    sudo perf report -i "$1" --stdio --no-children -g none --percent-limit "$THRESHOLD" 2>/dev/null \
        | awk '/^ *[0-9]/ {
            pct=$1; gsub(/%/,"",pct)
            # Symbol is the last field
            sym=$NF
            print pct, sym
        }'
}

echo "=== Profile Comparison (threshold >= ${THRESHOLD}%) ==="
echo ""
printf "%-45s %9s %9s %9s\n" "Symbol" "Baseline" "Patch" "Delta"
printf "%-45s %9s %9s %9s\n" "------" "--------" "-----" "-----"

TMPB=$(mktemp); TMPP=$(mktemp)
trap "rm -f $TMPB $TMPP" EXIT

extract "$BASELINE" > "$TMPB"
extract "$PATCH" > "$TMPP"

awk -v grep_pat="$GREP" '
    NR==FNR { base[$2] = $1; next }
    { patch[$2] = $1 }
    END {
        for (s in base) if (!(s in patch)) patch[s] = 0
        for (s in patch) if (!(s in base)) base[s] = 0
        for (s in base) {
            if (grep_pat != "" && tolower(s) !~ tolower(grep_pat)) continue
            b = base[s]+0; p = patch[s]+0
            d = p - b
            m = (b > p) ? b : p
            printf "%8.2f %8.2f %+8.2f %s\n", b, p, d, s
        }
    }
' "$TMPB" "$TMPP" | sort -k1 -rn | while read b p d sym; do
    printf "%-45s %8.2f%% %8.2f%% %+8.2f%%\n" "$sym" "$b" "$p" "$d"
done
