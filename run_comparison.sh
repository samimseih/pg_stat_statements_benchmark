#!/bin/bash
# run_comparison.sh - Benchmark pg_stat_statements (whatever build is active)
#
# Usage: ./run_comparison.sh [duration] [clients] [workload] [protocol]
# Defaults: 30s, 64 clients, all, simple
# workload: all|select1|churn|light_churn|multi_stmt
# protocol: simple|extended|extended-nobind|prepared
#
# Workloads:
#   select1      - SELECT 1, pure overhead measurement
#   churn        - 80% hot / 20% cold (100k unique), eviction stress
#   light_churn  - 99.5% hot / 0.5% cold (10k unique), light eviction
#   multi_stmt   - Multi-statement transaction with 100k unique queries
#
# Use switch_build.sh to swap between upstream and patch before running.
#
# Prerequisites:
#   - pg_ctl, psql, pgbench in PATH
#   - PGDATA set
#   - shared_preload_libraries = 'pg_stat_statements'
#   - shared_buffers = '4GB' recommended

set -e

DURATION="${1:-30}"
CLIENTS="${2:-64}"
WORKLOAD="${3:-all}"
PROTOCOL="${4:-simple}"
JOBS=16
DB="benchmark"
USER=$(whoami)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_TMPDIR="${BENCH_TMPDIR:-$HOME/Development/benchmarks/tmp}"
mkdir -p "$BENCH_TMPDIR"
RESULTS="$BENCH_TMPDIR/pgss_bench_$(date +%Y%m%d_%H%M%S).txt"
POLL_INTERVAL=20

setup_benchmark_db() {
    psql -U $USER -d postgres -Xc "SELECT 1 FROM pg_database WHERE datname = 'benchmark'" | grep -q 1 || \
        psql -U $USER -d postgres -Xc "CREATE DATABASE benchmark;"
    psql -U $USER -d $DB -Xc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>/dev/null
}

echo "=== pg_stat_statements benchmark ===" | tee "$RESULTS"
echo "Date: $(date)" | tee -a "$RESULTS"
echo "Clients: $CLIENTS, Duration: ${DURATION}s, Workload: $WORKLOAD, Protocol: $PROTOCOL" | tee -a "$RESULTS"
if command -v lscpu >/dev/null 2>&1; then
    echo "Machine: $(nproc) CPUs ($(lscpu | awk -F: '/Core\(s\) per socket/{gsub(/ /,"",$2); print $2}') cores, $(lscpu | awk -F: '/Thread\(s\) per core/{gsub(/ /,"",$2); print $2}') threads/core), $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2}'), $(free -h | awk '/Mem:/{print $2}') RAM" | tee -a "$RESULTS"
else
    echo "Machine: $(sysctl -n hw.ncpu) CPUs, $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.memsize | awk '{printf "%.0fGi", $1/1073741824}') RAM" | tee -a "$RESULTS"
fi
echo "" | tee -a "$RESULTS"

poll_stats() {
    local label="$1"
    local bench_pid="$2"
    local polls=$((DURATION / POLL_INTERVAL))
    local start_time=$(date +%s)
    rm -f "$BENCH_TMPDIR/pgss_waits_accum.log" "$BENCH_TMPDIR/pgss_waits_total.log" "$BENCH_TMPDIR/pgss_waits_interval.log"
    rm -f "$BENCH_TMPDIR/pgss_hot_entries.log" "$BENCH_TMPDIR/pgss_cold_entries.log"
    rm -f "$BENCH_TMPDIR/pgss_hot_calls.log" "$BENCH_TMPDIR/pgss_cold_calls.log"

    # Background: sample pg_stat_activity every 1 second
    (
        while kill -0 $bench_pid 2>/dev/null; do
            psql -U $USER -d $DB -XAtF"|" -c "
                SELECT wait_event_type, wait_event
                FROM pg_stat_activity
                WHERE state = 'active' AND pid != pg_backend_pid()
                  AND wait_event IS NOT NULL AND wait_event_type != 'Client';" 2>/dev/null >> "$BENCH_TMPDIR/pgss_waits_accum.log"
            sleep 1
        done
    ) &
    local WAIT_SAMPLER_PID=$!

    for i in $(seq 1 $polls); do
        sleep $POLL_INTERVAL

        if ! kill -0 $bench_pid 2>/dev/null; then
            break
        fi

        local elapsed=$(( $(date +%s) - start_time ))
        local row=$(psql -U $USER -d $DB -XAtF"|" -c "
            SELECT count(*),
                   count(*) FILTER (WHERE query IS NULL),
                   count(*) FILTER (WHERE query LIKE '%hot%'),
                   count(*) FILTER (WHERE query NOT LIKE '%hot%' AND query NOT LIKE '%pg_stat%' AND query NOT LIKE '%marker%' AND query IS NOT NULL),
                   coalesce(sum(calls) FILTER (WHERE query LIKE '%hot%'), 0),
                   coalesce(sum(calls) FILTER (WHERE query NOT LIKE '%hot%' AND query NOT LIKE '%pg_stat%' AND query NOT LIKE '%marker%' AND query IS NOT NULL), 0)
            FROM pg_stat_statements;" 2>/dev/null)
        # Rotate: grab current samples, clear for next interval
        cp "$BENCH_TMPDIR/pgss_waits_accum.log" "$BENCH_TMPDIR/pgss_waits_interval.log" 2>/dev/null || true
        > "$BENCH_TMPDIR/pgss_waits_accum.log"
        local waits=$(sort "$BENCH_TMPDIR/pgss_waits_interval.log" 2>/dev/null | grep -v "^$" | uniq -c | sort -rn | head -3 | awk '{printf "%s:%s(%d) ", $2, $3, $1}' | sed 's/|/:/g')
        cat "$BENCH_TMPDIR/pgss_waits_interval.log" >> "$BENCH_TMPDIR/pgss_waits_total.log" 2>/dev/null
        local retention_str=""
        local marker_str=""
        if [[ "$label" == "churn" || "$label" == "light_churn" ]]; then
            echo "$(echo $row | cut -d'|' -f3)" >> "$BENCH_TMPDIR/pgss_hot_entries.log"
            echo "$(echo $row | cut -d'|' -f4)" >> "$BENCH_TMPDIR/pgss_cold_entries.log"
            echo "$(echo $row | cut -d'|' -f5)" >> "$BENCH_TMPDIR/pgss_hot_calls.log"
            echo "$(echo $row | cut -d'|' -f6)" >> "$BENCH_TMPDIR/pgss_cold_calls.log"
            retention_str=" hot=$(echo $row | cut -d'|' -f3)/1000 cold=$(echo $row | cut -d'|' -f4) hot_calls=$(echo $row | cut -d'|' -f5) cold_calls=$(echo $row | cut -d'|' -f6)"

            # Inject marker for this poll cycle
            psql -U $USER -d $DB -Xc "SELECT /* marker_${i} */ 1;" >/dev/null 2>&1

            # Check which previous markers survived
            local survived=$(psql -U $USER -d $DB -XAt -c "
                SELECT string_agg(
                    regexp_replace(query, '.*marker_([0-9]+).*', '\1'),
                    ',' ORDER BY regexp_replace(query, '.*marker_([0-9]+).*', '\1')::int
                )
                FROM pg_stat_statements
                WHERE query LIKE '%marker_%' AND query NOT LIKE '%pg_stat%';" 2>/dev/null)
            local total_markers=$i
            local surviving_count=$(echo "$survived" | tr ',' '\n' | { grep -c '[0-9]' || true; } 2>/dev/null)
            surviving_count=${surviving_count:-0}
            local evicted_markers=$((total_markers - surviving_count))
            marker_str=" marker_survived=${surviving_count}/${total_markers}"
        fi
        printf "  t=%-4s entries=%-5s nulls=%-2s" "${elapsed}s" "$(echo $row | cut -d'|' -f1)" "$(echo $row | cut -d'|' -f2)" | tee -a "$RESULTS"
        if [[ -n "$retention_str" ]]; then
            printf "%s" "$retention_str" | tee -a "$RESULTS"
        fi
        if [[ -n "$marker_str" ]]; then
            printf "%s" "$marker_str" | tee -a "$RESULTS"
        fi
        local progress_tps=$(grep '^progress:' "$BENCH_TMPDIR/pgbench_last.txt" 2>/dev/null | tail -1 | awk '{print $4}')
        printf " tps=%s waits=[%s]\n" "${progress_tps:-N/A}" "${waits:-none}" | tee -a "$RESULTS"
    done

    # Stop the background wait sampler
    kill $WAIT_SAMPLER_PID 2>/dev/null || true
    wait $WAIT_SAMPLER_PID 2>/dev/null || true

    # Flush any remaining samples
    cat "$BENCH_TMPDIR/pgss_waits_accum.log" >> "$BENCH_TMPDIR/pgss_waits_total.log" 2>/dev/null

    # Final wait event summary
    local total_samples=$(grep -c '|' "$BENCH_TMPDIR/pgss_waits_total.log" 2>/dev/null || echo 0)
    echo "  wait totals ($total_samples samples): $(sort "$BENCH_TMPDIR/pgss_waits_total.log" 2>/dev/null | grep -v "^$" | uniq -c | sort -rn | head -5 | awk -v ts="$total_samples" '{printf "%s:%s(total=%d avg=%.1f/sample) ", $2, $3, $1, $1/ts}' | sed 's/|/:/g')" | tee -a "$RESULTS"
}

run_bench() {
    local label="$1"
    local workload="$2"

    psql -U $USER -d $DB -Xc "SELECT pg_stat_statements_reset();" >/dev/null 2>&1
    echo "" | tee -a "$RESULTS"
    echo "--- $label ---" | tee -a "$RESULTS"

    local pgbench_cmd
    if [[ -n "$workload" ]]; then
        pgbench_cmd="pgbench -U $USER -d $DB -f $workload -c $CLIENTS -j $JOBS -T $DURATION -P $POLL_INTERVAL -M $PROTOCOL"
    else
        pgbench_cmd="pgbench -U $USER -d $DB -c $CLIENTS -j $JOBS -T $DURATION -P $POLL_INTERVAL -M $PROTOCOL"
    fi
    echo "  cmd: $pgbench_cmd" | tee -a "$RESULTS"
    $pgbench_cmd > "$BENCH_TMPDIR/pgbench_last.txt" 2>&1 &
    local BENCH_PID=$!

    poll_stats "$label" "$BENCH_PID"

    wait $BENCH_PID 2>/dev/null

    local final_tps=$(grep '^tps = ' "$BENCH_TMPDIR/pgbench_last.txt" | awk '{print $3}')
    echo "  TPS: ${final_tps:-N/A}" | tee -a "$RESULTS"

    # Final sample after connections drain (pending counts now flushed)
    local final_row=$(psql -U $USER -d $DB -XAtF"|" -c "
        SELECT count(*),
               count(*) FILTER (WHERE query IS NULL),
               count(*) FILTER (WHERE query LIKE '%hot%'),
               count(*) FILTER (WHERE query NOT LIKE '%hot%' AND query NOT LIKE '%pg_stat%' AND query NOT LIKE '%marker%' AND query IS NOT NULL),
               coalesce(sum(calls) FILTER (WHERE query LIKE '%hot%'), 0),
               coalesce(sum(calls) FILTER (WHERE query NOT LIKE '%hot%' AND query NOT LIKE '%pg_stat%' AND query NOT LIKE '%marker%' AND query IS NOT NULL), 0)
        FROM pg_stat_statements;" 2>/dev/null)
    if [[ "$label" == "churn" || "$label" == "light_churn" ]]; then
        printf "  FINAL  entries=%-5s nulls=%-2s hot=%s/1000 cold=%s hot_calls=%s cold_calls=%s\n" \
            "$(echo "$final_row" | cut -d'|' -f1)" \
            "$(echo "$final_row" | cut -d'|' -f2)" \
            "$(echo "$final_row" | cut -d'|' -f3)" \
            "$(echo "$final_row" | cut -d'|' -f4)" \
            "$(echo "$final_row" | cut -d'|' -f5)" \
            "$(echo "$final_row" | cut -d'|' -f6)" | tee -a "$RESULTS"

        # Compute averages from polling samples
        if [[ -s "$BENCH_TMPDIR/pgss_hot_entries.log" ]]; then
            local avg_hot_ent=$(awk '{s+=$1} END {printf "%.0f", s/NR}' "$BENCH_TMPDIR/pgss_hot_entries.log")
            local avg_cold_ent=$(awk '{s+=$1} END {printf "%.0f", s/NR}' "$BENCH_TMPDIR/pgss_cold_entries.log")
            local avg_hot_calls=$(awk '{s+=$1} END {printf "%.0f", s/NR}' "$BENCH_TMPDIR/pgss_hot_calls.log")
            local avg_cold_calls=$(awk '{s+=$1} END {printf "%.0f", s/NR}' "$BENCH_TMPDIR/pgss_cold_calls.log")
            echo "  AVG    hot_entries=$avg_hot_ent cold_entries=$avg_cold_ent hot_calls=$avg_hot_calls cold_calls=$avg_cold_calls" | tee -a "$RESULTS"
        fi
    else
        printf "  FINAL  entries=%-5s nulls=%-2s\n" \
            "$(echo "$final_row" | cut -d'|' -f1)" \
            "$(echo "$final_row" | cut -d'|' -f2)" | tee -a "$RESULTS"
    fi

    # Dealloc info
    local info=$(psql -U $USER -d $DB -XAtF"|" -c "SELECT dealloc FROM pg_stat_statements_info;" 2>/dev/null)
    if [[ -n "$info" ]]; then
        echo "  deallocs: $info" | tee -a "$RESULTS"
    fi

}

# Ensure server is running
pg_ctl status >/dev/null 2>&1 || pg_ctl start -l "$BENCH_TMPDIR/pglog.txt" -w 2>&1 | tail -1

# Setup benchmark database, tables, and generated workload files
setup_benchmark_db

if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "multi_stmt" ]]; then
    run_bench "multi_stmt" "$SCRIPT_DIR/bench_multi_stmt.sql"
fi
if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "churn" ]]; then
    run_bench "churn" "$SCRIPT_DIR/bench_churn.sql"
fi
if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "light_churn" ]]; then
    run_bench "light_churn" "$SCRIPT_DIR/bench_light_churn.sql"
fi
if [[ "$WORKLOAD" == "all" || "$WORKLOAD" == "select1" ]]; then
    run_bench "select1" "$SCRIPT_DIR/bench_select1.sql"
fi

echo "" | tee -a "$RESULTS"
echo "=== TPS Summary ===" | tee -a "$RESULTS"
grep -B1 "TPS:" "$RESULTS" | grep -E "^---|TPS:" | sed 'N;s/\n/ /' | sed 's/--- //' | sed 's/  TPS: /: /' | tee -a "$RESULTS"

echo "" | tee -a "$RESULTS"
echo "=== DONE ===" | tee -a "$RESULTS"
echo "Results saved to: $RESULTS"
