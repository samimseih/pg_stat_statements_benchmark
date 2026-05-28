#!/bin/bash
# perf_annotate.sh - Profile a specific function in running postgres backends
#
# Usage: ./perf_annotate.sh [function] [duration]
# Defaults: pgstat_get_entry_ref, 10s
#
# Run while a workload is active. Records samples then shows
# instruction-level hotspots inside the target function.

set -e

FUNC="${1:-pgstat_get_entry_ref}"
DURATION="${2:-10}"
BENCH_TMPDIR="${BENCH_TMPDIR:-$HOME/Development/benchmarks/tmp}"
mkdir -p "$BENCH_TMPDIR"
PERF_FILE="$BENCH_TMPDIR/pgss_annotate_$(date +%Y%m%d_%H%M%S).data"

# Allow userspace profiling without sudo
sudo sysctl -q kernel.perf_event_paranoid=-1

PIDS=$(pgrep -d, postgres)
if [[ -z "$PIDS" ]]; then
    echo "No postgres processes found"
    exit 1
fi

echo "Recording $DURATION seconds across postgres PIDs..."
perf record -o "$PERF_FILE" -p "$PIDS" -- sleep "$DURATION"

echo ""
echo "=== Annotation: $FUNC ==="
perf annotate -i "$PERF_FILE" "$FUNC"
