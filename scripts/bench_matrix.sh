#!/bin/bash
# bench_matrix.sh - Run benchmarks across commits, client counts, and CPU counts
#
# Usage:
#   ./bench_matrix.sh [options]
#
# Options:
#   -d DURATION    Seconds per workload (default: 180)
#   -c CLIENTS     Comma-separated client counts (default: 64,128)
#   -C CPUS        Comma-separated CPU counts (default: all)
#   -k COMMITS     Comma-separated commit hashes (required)
#   -w WORKLOADS   Comma-separated workloads (default: all)
#   -W WORKTREE    Worktree name template; %c is replaced with commit (default: bench)
#   -M PROTOCOL    pgbench protocol (default: simple)
#   -S SLEEP_MS    Add \sleep of this many ms per iteration (default: 0 = none)
#   -b BUILD_TYPE  release|debug|debug_noassert (default: release)
#   -m MAX         pg_stat_statements.max (default: 5000)
#   -n             Dry-run
#   -h             Help
#
# Examples:
#   ./bench_matrix.sh -k 1f2297b5487,9e80698918e -c 64,128 -C 16 -d 180
#   ./bench_matrix.sh -k 1f2297b5487,4a9b913f2ac -W %c -c 64,256 -C 16,32,64,96,192
#   ./bench_matrix.sh -n -k abc123,def456 -c 64 -C 16

set -e

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
BENCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BENCH_ROOT/bench_config.sh"

DURATION=180
CLIENTS="64,128"
CPUS=""
COMMITS=""
WORKLOADS="all"
WT_TEMPLATE="bench"
PROTOCOL="simple"
SLEEP_MS=0
BUILD_TYPE="release"
PGSS_MAX=5000
DRY_RUN=0

usage() { sed -n '3,/^$/s/^# //p' "$0"; exit 0; }

while getopts "d:c:C:k:w:W:M:S:b:m:nh" opt; do
    case $opt in
        d) DURATION=$OPTARG ;;
        c) CLIENTS=$OPTARG ;;
        C) CPUS=$OPTARG ;;
        k) COMMITS=$OPTARG ;;
        w) WORKLOADS=$OPTARG ;;
        W) WT_TEMPLATE=$OPTARG ;;
        M) PROTOCOL=$OPTARG ;;
        S) SLEEP_MS=$OPTARG ;;
        b) BUILD_TYPE=$OPTARG ;;
        m) PGSS_MAX=$OPTARG ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$COMMITS" ]]; then
    echo "Error: -k COMMITS is required" >&2
    usage
fi

IFS=',' read -ra COMMIT_ARRAY <<< "$COMMITS"
IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENTS"
IFS=',' read -ra CPU_ARRAY <<< "$CPUS"

# Default to no CPU manipulation
[[ ${#CPU_ARRAY[@]} -eq 0 || -z "${CPU_ARRAY[0]}" ]] && CPU_ARRAY=("")

TOTAL_RUNS=$(( ${#COMMIT_ARRAY[@]} * ${#CLIENT_ARRAY[@]} * ${#CPU_ARRAY[@]} ))
NUM_WORKLOADS=4
[[ "$WORKLOADS" != "all" ]] && NUM_WORKLOADS=$(echo "$WORKLOADS" | tr "," "\n" | wc -l)
EST_MINUTES=$(( TOTAL_RUNS * NUM_WORKLOADS * (DURATION + 10) / 60 ))

# Resolve worktree name for a commit (%c -> commit hash)
wt_name_for() {
    echo "${WT_TEMPLATE//%c/$1}"
}

if (( DRY_RUN )); then
    echo "=== Dry-run: Benchmark Matrix ==="
    echo ""
    echo "Commits:   ${COMMIT_ARRAY[*]}"
    echo "Clients:   ${CLIENT_ARRAY[*]}"
    echo "CPUs:      ${CPU_ARRAY[*]:-all}"
    echo "Workloads: $WORKLOADS"
    echo "Worktree:  $WT_TEMPLATE"
    echo "Duration:  ${DURATION}s per workload"
    echo "Build:     $BUILD_TYPE"
    echo "Protocol:  $PROTOCOL"
    echo "pgss.max:  $PGSS_MAX"
    echo "Total:     $TOTAL_RUNS runs (~${EST_MINUTES} minutes)"
    echo ""
    for commit in "${COMMIT_ARRAY[@]}"; do
        wt=$(wt_name_for "$commit")
        echo "  ./switch_build.sh -c $commit -w $wt && ./switch_build.sh -w $wt -b $BUILD_TYPE && ./switch_build.sh -w $wt -m $PGSS_MAX"
        for cpus in "${CPU_ARRAY[@]}"; do
            for c in "${CLIENT_ARRAY[@]}"; do
                cpu_flag=""
                [[ -n "$cpus" ]] && cpu_flag=" -C $cpus"
                echo "  ./bench.sh -d $DURATION -c $c -w $WORKLOADS -M $PROTOCOL${cpu_flag}"
            done
        done
        echo ""
    done
    exit 0
fi

RESULTS_DIR="$BENCH_RESULTS_DIR/pgss_matrix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"
SUMMARY="$RESULTS_DIR/summary.txt"

{
    echo "=== Benchmark Matrix ==="
    echo "Date:      $(date)"
    echo "Commits:   ${COMMIT_ARRAY[*]}"
    echo "Clients:   ${CLIENT_ARRAY[*]}"
    echo "CPUs:      ${CPU_ARRAY[*]:-all}"
    echo "Workloads: $WORKLOADS"
    echo "Worktree:  $WT_TEMPLATE"
    echo "Duration:  ${DURATION}s"
    echo "Build:     $BUILD_TYPE"
    echo "Protocol:  $PROTOCOL"
    echo "pgss.max:  $PGSS_MAX"
    echo "Total:     $TOTAL_RUNS runs (~${EST_MINUTES} minutes)"
    echo ""
} | tee "$SUMMARY"

for commit in "${COMMIT_ARRAY[@]}"; do
    wt=$(wt_name_for "$commit")
    INSTALL_DIR="$PG_INSTALL_DIR/$wt"

    echo "================================================================" | tee -a "$SUMMARY"
    echo "=== Commit: $commit (pgss.max=$PGSS_MAX) ===" | tee -a "$SUMMARY"
    echo "================================================================" | tee -a "$SUMMARY"

    # Create worktree (or switch to commit if it already exists)
    "$BENCH_ROOT/switch_build.sh" -c "$commit" -w "$wt" 2>&1 | tee -a "$SUMMARY"
    # Build
    "$BENCH_ROOT/switch_build.sh" -w "$wt" -b "$BUILD_TYPE" 2>&1 | tee -a "$SUMMARY"
    # Start cluster
    "$BENCH_ROOT/switch_build.sh" -w "$wt" -m "$PGSS_MAX" 2>&1 | tee -a "$SUMMARY"
    echo "" | tee -a "$SUMMARY"

    for cpus in "${CPU_ARRAY[@]}"; do
        for c in "${CLIENT_ARRAY[@]}"; do
            cpu_label=""
            cpu_flag=""
            if [[ -n "$cpus" ]]; then
                cpu_label="_cpu${cpus}"
                cpu_flag="-C $cpus"
            fi
            label="${commit}_c${c}${cpu_label}"

            echo "--- $label ---" | tee -a "$SUMMARY"

            sleep_flag=""
            (( SLEEP_MS > 0 )) && sleep_flag="-S $SLEEP_MS"

            PATH="$INSTALL_DIR/bin:$PATH" \
            "$BENCH_ROOT/bench.sh" -d "$DURATION" -c "$c" -w "$WORKLOADS" \
                -M "$PROTOCOL" -p 5433 $cpu_flag $sleep_flag \
                -o "$RESULTS_DIR/$label" 2>&1 | tee "$RESULTS_DIR/${label}_full.txt"

            # Extract TPS to summary
            if [[ -f "$RESULTS_DIR/$label/report.txt" ]]; then
                grep "^  TPS:\|^---" "$RESULTS_DIR/$label/report.txt" | tee -a "$SUMMARY"
            fi
            echo "" | tee -a "$SUMMARY"
        done
    done
done

echo "================================================================" | tee -a "$SUMMARY"
echo "Finished: $(date)" | tee -a "$SUMMARY"
echo "Results: $RESULTS_DIR" | tee -a "$SUMMARY"
