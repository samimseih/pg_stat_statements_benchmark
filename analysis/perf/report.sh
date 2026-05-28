#!/bin/bash
# perf/report.sh - Analyze a perf profile
#
# Usage:
#   ./perf/report.sh <perf.data> [options]
#
# Modes:
#   --flat              Top functions by self time (default)
#   --cumulative        Top functions by total time (self + children)
#   --annotate FUNC     Per-instruction cost breakdown inside FUNC
#   --grep PATTERN      Filter flat/cumulative output by symbol pattern
#
# Options:
#   --threshold PCT     Minimum overhead % (default: 0.5)
#   --lines N           Max output lines (default: 60)

set -e

DATAFILE=""
MODE="flat"
FUNCTION=""
GREP=""
THRESHOLD=0.5
LINES=60

usage() {
    cat <<HELP
Usage: $(basename "$0") <perf.data> [options]

Modes:
  --flat              Top functions by self time (default)
  --cumulative        Top functions by total time (self + children)
  --annotate FUNC     Per-instruction cost inside FUNC (source + asm)
  --grep PATTERN      Filter flat/cumulative by symbol regex

Options:
  --threshold PCT     Minimum overhead % (default: 0.5)
  --lines N           Max output lines (default: 60)
  -h, --help          Show this help

Examples:
  ./perf/report.sh perf.data                           # flat profile
  ./perf/report.sh perf.data --grep "pgss|pgstat"      # filter
  ./perf/report.sh perf.data --cumulative              # cumulative
  ./perf/report.sh perf.data --annotate pgss_store     # per-instruction
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --flat) MODE="flat"; shift ;;
        --cumulative) MODE="cumulative"; shift ;;
        --annotate) MODE="annotate"; FUNCTION="$2"; shift 2 ;;
        --grep) GREP="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --lines) LINES="$2"; shift 2 ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *)
            if [[ -z "$DATAFILE" ]]; then
                DATAFILE="$1"; shift
            else
                echo "Unexpected argument: $1"; exit 1
            fi
            ;;
    esac
done

if [[ -z "$DATAFILE" || ! -f "$DATAFILE" ]]; then
    echo "Usage: $(basename "$0") <perf.data> [options]" >&2
    exit 1
fi

case "$MODE" in
    flat)
        echo "=== Flat Profile (self time, threshold >= ${THRESHOLD}%) ==="
        echo ""
        if [[ -n "$GREP" ]]; then
            sudo perf report -i "$DATAFILE" --stdio --no-children -g none \
                --percent-limit "$THRESHOLD" 2>/dev/null \
                | grep -iE "Overhead|Command|--------|$GREP" | head -n "$LINES"
        else
            sudo perf report -i "$DATAFILE" --stdio --no-children -g none \
                --percent-limit "$THRESHOLD" 2>/dev/null | head -n "$((LINES + 10))"
        fi
        ;;

    cumulative)
        echo "=== Cumulative Profile (self + children, threshold >= ${THRESHOLD}%) ==="
        echo ""
        if [[ -n "$GREP" ]]; then
            sudo perf report -i "$DATAFILE" --stdio --children -g none \
                --percent-limit "$THRESHOLD" 2>/dev/null \
                | grep -iE "Children|Command|--------|$GREP" | head -n "$LINES"
        else
            sudo perf report -i "$DATAFILE" --stdio --children -g none \
                --percent-limit "$THRESHOLD" 2>/dev/null | head -n "$((LINES + 10))"
        fi
        ;;

    annotate)
        if [[ -z "$FUNCTION" ]]; then
            echo "ERROR: --annotate requires a function name" >&2
            exit 1
        fi
        echo "=== Annotation: $FUNCTION (top instructions by cost) ==="
        echo ""
        # Show source-annotated hot instructions
        sudo perf annotate -i "$DATAFILE" --stdio --symbol="$FUNCTION" 2>/dev/null \
            | grep -E "^\s+[0-9]+\.[0-9]+\s+:" | sort -rn | head -n "$LINES"
        echo ""
        echo "--- Source context for hottest instruction ---"
        echo ""
        # Get the top instruction's percentage and show context
        TOP_PCT=$(sudo perf annotate -i "$DATAFILE" --stdio --symbol="$FUNCTION" 2>/dev/null \
            | grep -E "^\s+[0-9]+\.[0-9]+\s+:" | sort -rn | head -1 | awk '{print $1}')
        if [[ -n "$TOP_PCT" ]]; then
            sudo perf annotate -i "$DATAFILE" --stdio --symbol="$FUNCTION" 2>/dev/null \
                | grep -B15 "$TOP_PCT" | tail -20
        fi
        ;;
esac
