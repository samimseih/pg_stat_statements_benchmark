#!/bin/bash
# perf_record.sh - Record perf profile of running postgres backends
#
# Usage: ./perf_record.sh [duration]
# Defaults: 10s
#
# Run while a workload is active. Produces:
#   - Top functions report (printed to stdout)
#   - perf.data file for further analysis (perf annotate, perf report, etc.)
#
# For instruction-level profiling of a specific function:
#   ./perf_annotate.sh <function> [duration]

set -e

DURATION="${1:-10}"
BENCH_TMPDIR="${BENCH_TMPDIR:-$HOME/Development/benchmarks/tmp}"
mkdir -p "$BENCH_TMPDIR"
PERF_FILE="$BENCH_TMPDIR/pgss_perf_$(date +%Y%m%d_%H%M%S).data"

# Allow userspace profiling without sudo
sudo sysctl -q kernel.perf_event_paranoid=-1

PIDS=$(pgrep -d, postgres)
if [[ -z "$PIDS" ]]; then
    echo "No postgres processes found"
    exit 1
fi

echo "Recording $DURATION seconds across postgres PIDs..."
perf record -g -o "$PERF_FILE" -p "$PIDS" -- sleep "$DURATION"

echo ""
echo "=== Top functions (>1%) ==="
perf report -i "$PERF_FILE" --no-children --sort=symbol --percent-limit=1 -q 2>/dev/null | head -20

echo ""
echo "Saved: $PERF_FILE"
echo "Next steps:"
echo "  perf report -i $PERF_FILE"
echo "  perf annotate -i $PERF_FILE <function>"
