#!/bin/bash
# run_full_benchmark.sh - Run the complete benchmark suite hands-off
#
# Runs all workloads with pg_stat_statements.max=5000:
#   select1, churn, slow_churn, within_max
#   churn with 100ms sleep (realistic OLTP pacing)
#
# Builds all worktrees upfront (one per commit) so phase transitions
# only restart the cluster, not rebuild.
#
# Usage:
#   ./run_full_benchmark.sh -k <commit1>,<commit2> [options]
#
# Options:
#   -k COMMITS     Comma-separated commit hashes (required)
#   -c CLIENTS     Comma-separated client counts (default: 64,256)
#   -C CPUS        Comma-separated CPU counts (default: 16,32,64,96)
#   -d DURATION    Seconds per workload (default: 180)
#   -b BUILD_TYPE  release|debug|debug_noassert (default: release)
#   -n             Dry-run
#
# Example:
#   ./run_full_benchmark.sh -k 1f2297b5487,4a9b913f2ac

set -e

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BENCH_DIR/bench_config.sh"
COMMITS=""
CLIENTS="64,256"
CPUS="16,32,64,96"
DURATION=180
BUILD_TYPE="release"
DRY_RUN=""

while getopts "k:c:C:d:b:n" opt; do
    case $opt in
        k) COMMITS=$OPTARG ;;
        c) CLIENTS=$OPTARG ;;
        C) CPUS=$OPTARG ;;
        d) DURATION=$OPTARG ;;
        b) BUILD_TYPE=$OPTARG ;;
        n) DRY_RUN="-n" ;;
        *) echo "Usage: $0 -k <commits> [-c clients] [-C cpus] [-d duration] [-b build] [-n]"; exit 1 ;;
    esac
done

if [[ -z "$COMMITS" ]]; then
    echo "Error: -k COMMITS is required" >&2
    exit 1
fi

IFS=',' read -ra COMMIT_ARRAY <<< "$COMMITS"

echo "=== Full Benchmark Suite ==="
echo "Commits:  $COMMITS"
echo "Clients:  $CLIENTS"
echo "CPUs:     $CPUS"
echo "Duration: ${DURATION}s"
echo ""

# Pre-build all worktrees (one per commit, no cluster yet)
echo ">>> Pre-building worktrees..."
for commit in "${COMMIT_ARRAY[@]}"; do
    if [[ -z "$DRY_RUN" ]]; then
        "$BENCH_DIR/switch_build.sh" -c "$commit" -w "$commit" && "$BENCH_DIR/switch_build.sh" -w "$commit" -b "$BUILD_TYPE"
    else
        echo "  ./switch_build.sh -c $commit -w $commit && ./switch_build.sh -w $commit -b $BUILD_TYPE"
    fi
done
echo ""

COMMON_ARGS="-k $COMMITS -c $CLIENTS -C $CPUS -d $DURATION -b $BUILD_TYPE -W %c $DRY_RUN"

echo ">>> Workloads: select1, churn, slow_churn, within_max (pgss_max=5000)"
echo ""
"$BENCH_DIR/scripts/bench_matrix.sh" $COMMON_ARGS -w select1,churn,slow_churn,within_max -m 5000

echo ""
echo ">>> Workload: churn with 100ms sleep (pgss_max=5000)"
echo ""
"$BENCH_DIR/scripts/bench_matrix.sh" $COMMON_ARGS -w churn -S 100 -m 5000

echo ""
echo "=== All phases complete ==="
echo ""
echo "Generate report with:"
echo "  ./analysis/analyze_matrix.sh $BENCH_RESULTS_DIR/pgss_matrix_*"
