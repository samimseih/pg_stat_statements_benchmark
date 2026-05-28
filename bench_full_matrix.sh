#!/bin/bash
# bench_full_matrix.sh - Full benchmark matrix with per-run analysis and final comparison
#
# Matrix: {upstream, patch} x {build_types} x {workloads} x {protocols}
# Each workload runs for the specified duration. Fresh cluster between each build variation.
# Uses run_comparison.sh for per-run analysis (wait events, deallocs, entry counts).
# Produces a combined summary at the end.
#
# Usage: ./bench_full_matrix.sh [duration] [clients] [build_types] [workloads] [protocols]
# Defaults: 180s, 64 clients, "release debug debug_noassert", "churn light_churn multi_stmt select1", "simple"
# protocols: space-separated list of simple|extended|extended-nobind|prepared
# Examples:
#   ./bench_full_matrix.sh 30 64 release     # quick 30s test, release only
#   ./bench_full_matrix.sh 300 64 debug      # full 5min, debug only
#   ./bench_full_matrix.sh 300 64 "release debug"  # both (default)
#   ./bench_full_matrix.sh 120 64 debug_noassert "churn light_churn"  # specific workloads
#   ./bench_full_matrix.sh 120 64 release churn prepared  # prepared protocol
#   ./bench_full_matrix.sh 120 64 "release debug_noassert" churn "simple extended-nobind"  # multi-protocol

set -e

DURATION="${1:-180}"
CLIENTS="${2:-64}"
JOBS=16
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$HOME/Development/pgdev/installations/worktrees/dev"
INSTALL_DIR="$HOME/Development/pgdev/installations/pghome/dev"
PGDATA="$HOME/Development/pgdev/installations/pgdata/dev"
RESULTS_DIR="$HOME/Development/benchmarks/results/pgss_matrix_$(date +%Y%m%d_%H%M%S)"
FINAL_REPORT="$RESULTS_DIR/final_report.txt"
DB="postgres"
USER=$(whoami)

export PATH="$INSTALL_DIR/bin:$PATH"
export PGDATA

export BENCH_TMPDIR="$HOME/Development/benchmarks/tmp"
rm -rf "$BENCH_TMPDIR"
mkdir -p "$BENCH_TMPDIR"
mkdir -p "$RESULTS_DIR"

BUILDS=(patch upstream)
BUILD_TYPES=(${3:-release debug debug_noassert})
WORKLOADS=(${4:-churn light_churn multi_stmt select1})
PROTOCOLS=(${5:-simple})

echo "=== pg_stat_statements Full Benchmark Matrix ===" | tee "$FINAL_REPORT"
echo "Date: $(date)" | tee -a "$FINAL_REPORT"
echo "Duration: ${DURATION}s per workload, Clients: $CLIENTS" | tee -a "$FINAL_REPORT"
echo "Protocols: ${PROTOCOLS[*]}" | tee -a "$FINAL_REPORT"
echo "Matrix: ${#BUILDS[@]} builds x ${#BUILD_TYPES[@]} types x ${#WORKLOADS[@]} workloads x ${#PROTOCOLS[@]} protocols = $((${#BUILDS[@]} * ${#BUILD_TYPES[@]} * ${#WORKLOADS[@]} * ${#PROTOCOLS[@]})) tests" | tee -a "$FINAL_REPORT"
echo "Estimated total time: $(( ${#BUILDS[@]} * ${#BUILD_TYPES[@]} * ${#WORKLOADS[@]} * ${#PROTOCOLS[@]} * (DURATION + 30) / 60 )) minutes" | tee -a "$FINAL_REPORT"
echo "" | tee -a "$FINAL_REPORT"
echo "Machine:" | tee -a "$FINAL_REPORT"
echo "  CPUs: $(nproc) ($(lscpu | awk -F: '/Core\(s\) per socket/{gsub(/ /,"",$2); print $2}') cores, $(lscpu | awk -F: '/Thread\(s\) per core/{gsub(/ /,"",$2); print $2}') threads/core, $(lscpu | awk -F: '/Socket\(s\)/{gsub(/ /,"",$2); print $2}') socket)" | tee -a "$FINAL_REPORT"
echo "  CPU model: $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2}')" | tee -a "$FINAL_REPORT"
echo "  RAM: $(free -h | awk '/Mem:/{print $2}')" | tee -a "$FINAL_REPORT"
echo "" | tee -a "$FINAL_REPORT"
echo "Build configurations:" | tee -a "$FINAL_REPORT"
echo "  release:        buildtype=release, cassert=false, ndebug=true" | tee -a "$FINAL_REPORT"
echo "  debug:          buildtype=debug, cassert=true, ndebug=false" | tee -a "$FINAL_REPORT"
echo "  debug_noassert: buildtype=debug, cassert=false, ndebug=true" | tee -a "$FINAL_REPORT"
echo "" | tee -a "$FINAL_REPORT"
echo "Method:" | tee -a "$FINAL_REPORT"
echo "  For each test: pg_stat_statements_reset(), then pgbench (see per-test command below)." | tee -a "$FINAL_REPORT"
echo "  While pgbench is running:" | tee -a "$FINAL_REPORT"
echo "    - sample pg_stat_activity wait events (WHERE state = 'active') every 1s" | tee -a "$FINAL_REPORT"
echo "    - query pg_stat_statements (entries, hot/cold calls) every 20s" | tee -a "$FINAL_REPORT"
echo "      hot_calls = sum(calls) FILTER (WHERE query LIKE '%hot%')" | tee -a "$FINAL_REPORT"
echo "      cold_calls = sum(calls) FILTER (WHERE query NOT LIKE '%hot%' AND query IS NOT NULL)" | tee -a "$FINAL_REPORT"
echo "  After pgbench: final entry count, hot/cold calls, dealloc count from pg_stat_statements_info" | tee -a "$FINAL_REPORT"
echo "" | tee -a "$FINAL_REPORT"

declare -A TPS_RESULTS
declare -A DEALLOC_RESULTS
declare -A WAIT_RESULTS
declare -A ENTRIES_RESULTS
declare -A HOT_ENTRIES_RESULTS
declare -A COLD_ENTRIES_RESULTS
declare -A AVG_HOT_ENTRIES_RESULTS
declare -A AVG_COLD_ENTRIES_RESULTS
declare -A AVG_HOT_CALLS_RESULTS
declare -A AVG_COLD_CALLS_RESULTS
declare -A HOT_CALLS_RESULTS
declare -A COLD_CALLS_RESULTS

recreate_cluster() {
    echo "  Recreating cluster..."
    pkill -9 postgres 2>/dev/null || true
    while pgrep -x postgres >/dev/null 2>&1; do sleep 0.1; done
    rm -rf "$PGDATA"
    initdb -D "$PGDATA" --no-instructions --no-locale >/dev/null 2>&1

    cat >> "$PGDATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_stat_statements'
max_connections = 1000
shared_buffers = 4GB
max_parallel_workers_per_gather = 0
maintenance_work_mem = 2GB
EOF

    pg_ctl start -D "$PGDATA" -l "$RESULTS_DIR/pglog_current.txt" -w >/dev/null 2>&1
    psql -U "$USER" -d "$DB" -Xc "CREATE EXTENSION pg_stat_statements;" >/dev/null 2>&1
}

switch_build() {
    local mode="$1"
    local build_type="$2"

    echo "Switching to: $mode ($build_type)..." | tee -a "$FINAL_REPORT"
    "$SCRIPT_DIR/switch_build.sh" "$mode" "$build_type"
}

extract_tps() {
    local results_file="$1"
    grep '^ *TPS:' "$results_file" | tail -1 | awk '{print $2}' 2>/dev/null
}

extract_deallocs() {
    local results_file="$1"
    grep "deallocs:" "$results_file" | tail -1 | awk '{print $NF}' 2>/dev/null
}

extract_entries() {
    local results_file="$1"
    grep "FINAL" "$results_file" | tail -1 | grep -oP 'entries=\K[0-9]+' 2>/dev/null || true
}

extract_hot_entries() {
    local results_file="$1"
    grep "FINAL" "$results_file" | tail -1 | grep -oP 'hot=\K[0-9]+' 2>/dev/null || true
}

extract_cold_entries() {
    local results_file="$1"
    grep "FINAL" "$results_file" | tail -1 | grep -oP 'cold=\K[0-9]+' 2>/dev/null || true
}

extract_avg_hot_entries() {
    local results_file="$1"
    grep "AVG" "$results_file" | tail -1 | grep -oP 'hot_entries=\K[0-9]+' 2>/dev/null || true
}

extract_avg_cold_entries() {
    local results_file="$1"
    grep "AVG" "$results_file" | tail -1 | grep -oP 'cold_entries=\K[0-9]+' 2>/dev/null || true
}

extract_avg_hot_calls() {
    local results_file="$1"
    grep "AVG" "$results_file" | tail -1 | grep -oP 'hot_calls=\K[0-9]+' 2>/dev/null || true
}

extract_avg_cold_calls() {
    local results_file="$1"
    grep "AVG" "$results_file" | tail -1 | grep -oP 'cold_calls=\K[0-9]+' 2>/dev/null || true
}

extract_hot_calls() {
    local results_file="$1"
    grep "FINAL" "$results_file" | tail -1 | grep -oP 'hot_calls=\K[0-9]+' 2>/dev/null || true
}

extract_cold_calls() {
    local results_file="$1"
    grep "FINAL" "$results_file" | tail -1 | grep -oP 'cold_calls=\K[0-9]+' 2>/dev/null || true
}

extract_top_wait() {
    local results_file="$1"
    local line result
    line=$(grep "wait totals" "$results_file" | tail -1 | sed 's/.*samples): //' || true)
    result=$(echo "$line" | grep -oE '[A-Za-z]+:[A-Za-z_]+:\(total=[0-9]+' | head -1 | \
        sed 's/:(total=/ (/' | sed 's/$/)/' || true)
    echo "${result:-none}"
}

# Main loop
for build_type in "${BUILD_TYPES[@]}"; do
    for build in "${BUILDS[@]}"; do
        label="${build}_${build_type}"
        echo "" | tee -a "$FINAL_REPORT"
        echo "================================================================" | tee -a "$FINAL_REPORT"
        echo "=== $label ===" | tee -a "$FINAL_REPORT"
        echo "================================================================" | tee -a "$FINAL_REPORT"

        switch_build "$build" "$build_type"
        recreate_cluster

        for protocol in "${PROTOCOLS[@]}"; do
            for workload in "${WORKLOADS[@]}"; do
                key="${label}/${protocol}/${workload}"
                echo "" | tee -a "$FINAL_REPORT"
                echo "--- $label / $workload ($protocol) ---" | tee -a "$FINAL_REPORT"

                # run_comparison.sh outputs to $BENCH_TMPDIR/pgss_bench_*.txt
                rm -f $BENCH_TMPDIR/pgss_bench_*.txt
                "$SCRIPT_DIR/run_comparison.sh" "$DURATION" "$CLIENTS" "$workload" "$protocol" 2>&1 | tee "$RESULTS_DIR/${label}_${workload}_${protocol}_full.txt"

                # Find the results file run_comparison.sh created
                local_results=$(ls -t $BENCH_TMPDIR/pgss_bench_*.txt 2>/dev/null | head -1)
                if [[ -n "$local_results" ]]; then
                    cp "$local_results" "$RESULTS_DIR/${label}_${workload}_${protocol}.txt"
                    TPS_RESULTS["$key"]=$(extract_tps "$local_results")
                    DEALLOC_RESULTS["$key"]=$(extract_deallocs "$local_results")
                    WAIT_RESULTS["$key"]=$(extract_top_wait "$local_results")
                    ENTRIES_RESULTS["$key"]=$(extract_entries "$local_results")
                    HOT_ENTRIES_RESULTS["$key"]=$(extract_hot_entries "$local_results")
                    COLD_ENTRIES_RESULTS["$key"]=$(extract_cold_entries "$local_results")
                    AVG_HOT_ENTRIES_RESULTS["$key"]=$(extract_avg_hot_entries "$local_results")
                    AVG_COLD_ENTRIES_RESULTS["$key"]=$(extract_avg_cold_entries "$local_results")
                    HOT_CALLS_RESULTS["$key"]=$(extract_hot_calls "$local_results")
                    COLD_CALLS_RESULTS["$key"]=$(extract_cold_calls "$local_results")
                    AVG_HOT_CALLS_RESULTS["$key"]=$(extract_avg_hot_calls "$local_results")
                    AVG_COLD_CALLS_RESULTS["$key"]=$(extract_avg_cold_calls "$local_results")
                fi

                echo "  => TPS: ${TPS_RESULTS[$key]:-N/A}" | tee -a "$FINAL_REPORT"
                final_line=$(grep "FINAL" "$local_results" 2>/dev/null | tail -1)
                if [[ -n "$final_line" ]]; then
                    echo "  => ${final_line## }" | tee -a "$FINAL_REPORT"
                fi
            done
        done

        pkill -9 postgres 2>/dev/null || true
        while pgrep -x postgres >/dev/null 2>&1; do sleep 0.1; done
    done
done

# Final combined summary
echo "" | tee -a "$FINAL_REPORT"
echo "" | tee -a "$FINAL_REPORT"
echo "================================================================" | tee -a "$FINAL_REPORT"
echo "                    COMBINED RESULTS SUMMARY                     " | tee -a "$FINAL_REPORT"
echo "================================================================" | tee -a "$FINAL_REPORT"

fmt_num() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

for build_type in "${BUILD_TYPES[@]}"; do
    for protocol in "${PROTOCOLS[@]}"; do
        for workload in "${WORKLOADS[@]}"; do
            p_key="patch_${build_type}/${protocol}/${workload}"
            u_key="upstream_${build_type}/${protocol}/${workload}"
            p_tps="${TPS_RESULTS[$p_key]}"
            u_tps="${TPS_RESULTS[$u_key]}"
            p_dealloc="${DEALLOC_RESULTS[$p_key]:-0}"
            u_dealloc="${DEALLOC_RESULTS[$u_key]:-0}"
            p_wait="${WAIT_RESULTS[$p_key]:-none}"
            u_wait="${WAIT_RESULTS[$u_key]:-none}"
            p_entries="${ENTRIES_RESULTS[$p_key]:-N/A}"
            u_entries="${ENTRIES_RESULTS[$u_key]:-N/A}"
            p_hot_ent="${HOT_ENTRIES_RESULTS[$p_key]:-N/A}"
            u_hot_ent="${HOT_ENTRIES_RESULTS[$u_key]:-N/A}"
            p_cold_ent="${COLD_ENTRIES_RESULTS[$p_key]:-N/A}"
            u_cold_ent="${COLD_ENTRIES_RESULTS[$u_key]:-N/A}"
            p_avg_hot_ent="${AVG_HOT_ENTRIES_RESULTS[$p_key]:-N/A}"
            u_avg_hot_ent="${AVG_HOT_ENTRIES_RESULTS[$u_key]:-N/A}"
            p_avg_cold_ent="${AVG_COLD_ENTRIES_RESULTS[$p_key]:-N/A}"
            u_avg_cold_ent="${AVG_COLD_ENTRIES_RESULTS[$u_key]:-N/A}"
            p_hot="${HOT_CALLS_RESULTS[$p_key]:-N/A}"
            u_hot="${HOT_CALLS_RESULTS[$u_key]:-N/A}"
            p_cold="${COLD_CALLS_RESULTS[$p_key]:-N/A}"
            u_cold="${COLD_CALLS_RESULTS[$u_key]:-N/A}"
            p_avg_hot="${AVG_HOT_CALLS_RESULTS[$p_key]:-N/A}"
            u_avg_hot="${AVG_HOT_CALLS_RESULTS[$u_key]:-N/A}"
            p_avg_cold="${AVG_COLD_CALLS_RESULTS[$p_key]:-N/A}"
            u_avg_cold="${AVG_COLD_CALLS_RESULTS[$u_key]:-N/A}"

            # Skip if no data
            [[ -z "$p_tps" && -z "$u_tps" ]] && continue

            # Compute TPS delta
            delta="N/A"
            if [[ -n "$p_tps" && -n "$u_tps" && "$u_tps" != "0" ]]; then
                delta=$(echo "scale=1; ($p_tps - $u_tps) * 100 / $u_tps" | bc 2>/dev/null)
                delta=$(printf "%+.1f%%" "$delta" 2>/dev/null || echo "N/A")
            fi

            # Format numbers with commas
            p_tps_f=$(printf "%'.0f" "$p_tps" 2>/dev/null || echo "${p_tps:-N/A}")
            u_tps_f=$(printf "%'.0f" "$u_tps" 2>/dev/null || echo "${u_tps:-N/A}")
            p_dealloc_f=$(fmt_num "$p_dealloc")
            u_dealloc_f=$(fmt_num "$u_dealloc")
            p_entries_f="${p_entries}"
            u_entries_f="${u_entries}"
            p_hot_ent_f=$([[ "$p_hot_ent" != "N/A" ]] && fmt_num "$p_hot_ent" || echo "N/A")
            u_hot_ent_f=$([[ "$u_hot_ent" != "N/A" ]] && fmt_num "$u_hot_ent" || echo "N/A")
            p_cold_ent_f=$([[ "$p_cold_ent" != "N/A" ]] && fmt_num "$p_cold_ent" || echo "N/A")
            u_cold_ent_f=$([[ "$u_cold_ent" != "N/A" ]] && fmt_num "$u_cold_ent" || echo "N/A")
            p_avg_hot_ent_f=$([[ "$p_avg_hot_ent" != "N/A" ]] && fmt_num "$p_avg_hot_ent" || echo "N/A")
            u_avg_hot_ent_f=$([[ "$u_avg_hot_ent" != "N/A" ]] && fmt_num "$u_avg_hot_ent" || echo "N/A")
            p_avg_cold_ent_f=$([[ "$p_avg_cold_ent" != "N/A" ]] && fmt_num "$p_avg_cold_ent" || echo "N/A")
            u_avg_cold_ent_f=$([[ "$u_avg_cold_ent" != "N/A" ]] && fmt_num "$u_avg_cold_ent" || echo "N/A")
            p_hot_f=$([[ "$p_hot" != "N/A" ]] && fmt_num "$p_hot" || echo "N/A")
            u_hot_f=$([[ "$u_hot" != "N/A" ]] && fmt_num "$u_hot" || echo "N/A")
            p_cold_f=$([[ "$p_cold" != "N/A" ]] && fmt_num "$p_cold" || echo "N/A")
            u_cold_f=$([[ "$u_cold" != "N/A" ]] && fmt_num "$u_cold" || echo "N/A")
            p_avg_hot_f=$([[ "$p_avg_hot" != "N/A" ]] && fmt_num "$p_avg_hot" || echo "N/A")
            u_avg_hot_f=$([[ "$u_avg_hot" != "N/A" ]] && fmt_num "$u_avg_hot" || echo "N/A")
            p_avg_cold_f=$([[ "$p_avg_cold" != "N/A" ]] && fmt_num "$p_avg_cold" || echo "N/A")
            u_avg_cold_f=$([[ "$u_avg_cold" != "N/A" ]] && fmt_num "$u_avg_cold" || echo "N/A")

            # Determine column widths dynamically based on content
            col1=13
            col2=${#p_tps_f}; (( ${#p_entries_f} > col2 )) && col2=${#p_entries_f}
            (( ${#p_hot_ent_f} > col2 )) && col2=${#p_hot_ent_f}
            (( ${#p_cold_ent_f} > col2 )) && col2=${#p_cold_ent_f}
            (( ${#p_hot_f} > col2 )) && col2=${#p_hot_f}
            (( ${#p_cold_f} > col2 )) && col2=${#p_cold_f}
            (( ${#p_dealloc_f} > col2 )) && col2=${#p_dealloc_f}
            (( ${#p_wait} > col2 )) && col2=${#p_wait}
            (( col2 < 12 )) && col2=12

            col3=${#u_tps_f}; (( ${#u_entries_f} > col3 )) && col3=${#u_entries_f}
            (( ${#u_hot_ent_f} > col3 )) && col3=${#u_hot_ent_f}
            (( ${#u_cold_ent_f} > col3 )) && col3=${#u_cold_ent_f}
            (( ${#u_hot_f} > col3 )) && col3=${#u_hot_f}
            (( ${#u_cold_f} > col3 )) && col3=${#u_cold_f}
            (( ${#u_dealloc_f} > col3 )) && col3=${#u_dealloc_f}
            (( ${#u_wait} > col3 )) && col3=${#u_wait}
            (( col3 < 12 )) && col3=12

            col4=${#delta}; (( col4 < 8 )) && col4=8

            hrule1=$(printf '%*s' $col1 '' | tr ' ' '-')
            hrule2=$(printf '%*s' $col2 '' | tr ' ' '-')
            hrule3=$(printf '%*s' $col3 '' | tr ' ' '-')
            hrule4=$(printf '%*s' $col4 '' | tr ' ' '-')

            # Include protocol in heading only when multiple protocols
            if [[ ${#PROTOCOLS[@]} -gt 1 ]]; then
                heading="${workload} (${build_type}, ${protocol})"
            else
                heading="${workload} (${build_type})"
            fi

            echo "" | tee -a "$FINAL_REPORT"
            echo "=== ${heading} ===" | tee -a "$FINAL_REPORT"
            echo "  pgbench -f bench_${workload}.sql -c $CLIENTS -j $JOBS -T $DURATION -M $protocol" | tee -a "$FINAL_REPORT"
            printf "+-%s-+-%s-+-%s-+-%s-+\n" "$hrule1" "$hrule2" "$hrule3" "$hrule4" | tee -a "$FINAL_REPORT"
            printf "| %-${col1}s | %-${col2}s | %-${col3}s | %-${col4}s |\n" \
                "" "patch" "upstream" "delta" | tee -a "$FINAL_REPORT"
            printf "+-%s-+-%s-+-%s-+-%s-+\n" "$hrule1" "$hrule2" "$hrule3" "$hrule4" | tee -a "$FINAL_REPORT"
            printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                "TPS" "$p_tps_f" "$u_tps_f" "$delta" | tee -a "$FINAL_REPORT"
            printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                "entries" "$p_entries_f" "$u_entries_f" "" | tee -a "$FINAL_REPORT"
            if [[ "$p_hot_ent_f" != "N/A" || "$u_hot_ent_f" != "N/A" ]]; then
                printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                    "hot_ent(avg)" "$p_avg_hot_ent_f" "$u_avg_hot_ent_f" "" | tee -a "$FINAL_REPORT"
                printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                    "cold_ent(avg)" "$p_avg_cold_ent_f" "$u_avg_cold_ent_f" "" | tee -a "$FINAL_REPORT"
                printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                    "hot_cal(avg)" "$p_avg_hot_f" "$u_avg_hot_f" "" | tee -a "$FINAL_REPORT"
                printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                    "cold_cal(avg)" "$p_avg_cold_f" "$u_avg_cold_f" "" | tee -a "$FINAL_REPORT"
            fi
            printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                "deallocs" "$p_dealloc_f" "$u_dealloc_f" "" | tee -a "$FINAL_REPORT"
            printf "| %-${col1}s | %-${col2}s | %-${col3}s | %${col4}s |\n" \
                "top_wait" "$p_wait" "$u_wait" "" | tee -a "$FINAL_REPORT"
            printf "+-%s-+-%s-+-%s-+-%s-+\n" "$hrule1" "$hrule2" "$hrule3" "$hrule4" | tee -a "$FINAL_REPORT"
        done
    done
done

echo "" | tee -a "$FINAL_REPORT"
echo "Results directory: $RESULTS_DIR" | tee -a "$FINAL_REPORT"
echo "Individual run details: ${RESULTS_DIR}/<config>_<workload>_<protocol>_full.txt" | tee -a "$FINAL_REPORT"
echo "=== DONE ===" | tee -a "$FINAL_REPORT"
