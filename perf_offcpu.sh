#!/bin/bash
# perf_offcpu.sh - Profile off-CPU time, context switches, and scheduler latency
#
# Usage: ./perf_offcpu.sh [duration]
# Default: 10s
#
# Run in a separate terminal while a workload is active.
#
# Produces three analyses:
#   1. Context switch stacks (where switches happen)
#   2. Scheduler latency (who waited longest)
#   3. Off-CPU stacks via sched:sched_switch (where time is spent blocked)
#
# Optional: if offcputime-bpfcc is available, also generates off-CPU flame graph input.

set -e

DURATION="${1:-10}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BENCH_TMPDIR="${BENCH_TMPDIR:-$HOME/Development/benchmarks/tmp}"
mkdir -p "$BENCH_TMPDIR"
OUTDIR="$BENCH_TMPDIR/pgss_offcpu_${TIMESTAMP}"
mkdir -p "$OUTDIR"

# Allow userspace profiling without sudo
sudo sysctl -q kernel.perf_event_paranoid=-1

PIDS=$(pgrep -d, postgres)
if [[ -z "$PIDS" ]]; then
    echo "No postgres processes found"
    exit 1
fi

echo "Profiling postgres PIDs for ${DURATION}s..."
echo "Output directory: $OUTDIR"
echo ""

# --- 1. Context switch counts (quick summary) ---
echo "=== 1/3: Context switch stats ==="
perf stat -e context-switches,cpu-migrations,cache-misses \
    -p "$PIDS" -- sleep "$DURATION" 2>&1 | tee "$OUTDIR/cs_stats.txt"
echo ""

# --- 2. Context switch stacks (where switches happen) ---
echo "=== 2/3: Context switch stacks ==="
perf record -e context-switches -g --call-graph dwarf \
    -o "$OUTDIR/cs_stacks.data" -p "$PIDS" -- sleep "$DURATION"
echo "Top context-switch call paths:"
perf report -i "$OUTDIR/cs_stacks.data" --no-children \
    --sort=symbol --percent-limit=2 -q 2>/dev/null | head -20 | tee "$OUTDIR/cs_top.txt"
echo ""

# --- 3. Scheduler latency (who waited longest) ---
echo "=== 3/3: Scheduler latency ==="
sudo perf sched record -o "$OUTDIR/sched.data" -p "$PIDS" -- sleep "$DURATION"
echo ""
echo "-- Latency by task (top 20) --"
sudo perf sched latency -i "$OUTDIR/sched.data" --sort max 2>/dev/null | head -25 | tee "$OUTDIR/sched_latency.txt"
echo ""

# --- Bonus: BCC offcputime if available ---
if command -v offcputime-bpfcc &>/dev/null; then
    echo "=== Bonus: BCC off-CPU stacks ==="
    sudo offcputime-bpfcc -df -p "$(pgrep -d, postgres)" --min-block-time 5 "$DURATION" \
        > "$OUTDIR/offcpu.stacks" 2>/dev/null
    echo "Off-CPU stacks saved to $OUTDIR/offcpu.stacks"
    if command -v flamegraph.pl &>/dev/null; then
        flamegraph.pl --color=io --title="Off-CPU: postgres" \
            < "$OUTDIR/offcpu.stacks" > "$OUTDIR/offcpu.svg"
        echo "Flame graph: $OUTDIR/offcpu.svg"
    else
        echo "Install flamegraph.pl to generate SVG: https://github.com/brendangregg/FlameGraph"
    fi
    echo ""
fi

echo "=== Summary ==="
echo "All output in: $OUTDIR/"
ls -1 "$OUTDIR/"
echo ""
echo "Next steps:"
echo "  perf report -i $OUTDIR/cs_stacks.data   # browse context-switch stacks"
echo "  sudo perf sched timehist -i $OUTDIR/sched.data  # timeline view"
