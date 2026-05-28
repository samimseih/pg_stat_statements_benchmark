#!/bin/bash
# regen_report.sh - Regenerate final_report.txt from existing benchmark data
# Usage: ./regen_report.sh /tmp/pgss_matrix_20260528_032745

set -e

RESULTS_DIR="${1:?Usage: $0 <results_dir>}"
FINAL_REPORT="$RESULTS_DIR/final_report.txt"

if [[ ! -d "$RESULTS_DIR" ]]; then
    echo "Error: $RESULTS_DIR not found"
    exit 1
fi

BUILD_TYPES=(release debug debug_noassert)
WORKLOADS=(churn light_churn multi_stmt select1)
BUILDS=(patch upstream)

# Auto-detect protocols from result filenames
# Files are named: <build>_<build_type>_<workload>_<protocol>_full.txt
PROTOCOLS=()
for f in "$RESULTS_DIR"/*_full.txt; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f" _full.txt)
    # Strip build_buildtype prefix and workload to get protocol
    for build in "${BUILDS[@]}"; do
        for bt in "${BUILD_TYPES[@]}"; do
            for wl in "${WORKLOADS[@]}"; do
                prefix="${build}_${bt}_${wl}_"
                if [[ "$base" == ${prefix}* ]]; then
                    proto="${base#$prefix}"
                    if [[ -n "$proto" ]]; then
                        PROTOCOLS+=("$proto")
                    fi
                fi
            done
        done
    done
done
# Deduplicate and sort; fall back to detecting from old-style filenames
if [[ ${#PROTOCOLS[@]} -gt 0 ]]; then
    PROTOCOLS=($(printf '%s\n' "${PROTOCOLS[@]}" | sort -u))
else
    # Legacy: files without protocol in name, detect from content
    PROTOCOLS=($(grep -h 'Protocol:' "$RESULTS_DIR"/*_full.txt 2>/dev/null | grep -oP 'Protocol: \K[^,]+' | sort -u || echo "simple"))
fi

declare -A TPS_RESULTS DEALLOC_RESULTS WAIT_RESULTS ENTRIES_RESULTS
declare -A HOT_ENTRIES_RESULTS COLD_ENTRIES_RESULTS AVG_HOT_ENTRIES_RESULTS AVG_COLD_ENTRIES_RESULTS
declare -A HOT_CALLS_RESULTS COLD_CALLS_RESULTS AVG_HOT_CALLS_RESULTS AVG_COLD_CALLS_RESULTS

extract_tps() { grep '^ *TPS:' "$1" | tail -1 | awk '{print $2}' 2>/dev/null; }
extract_deallocs() { grep "deallocs:" "$1" | tail -1 | awk '{print $NF}' 2>/dev/null; }
extract_entries() { grep "FINAL" "$1" | tail -1 | grep -oP 'entries=\K[0-9]+' 2>/dev/null || true; }
extract_hot_entries() { grep "FINAL" "$1" | tail -1 | grep -oP 'hot=\K[0-9]+' 2>/dev/null || true; }
extract_cold_entries() { grep "FINAL" "$1" | tail -1 | grep -oP 'cold=\K[0-9]+' 2>/dev/null || true; }
extract_avg_hot_entries() { grep "AVG" "$1" | tail -1 | grep -oP 'hot_entries=\K[0-9]+' 2>/dev/null || true; }
extract_avg_cold_entries() { grep "AVG" "$1" | tail -1 | grep -oP 'cold_entries=\K[0-9]+' 2>/dev/null || true; }
extract_hot_calls() { grep "FINAL" "$1" | tail -1 | grep -oP 'hot_calls=\K[0-9]+' 2>/dev/null || true; }
extract_cold_calls() { grep "FINAL" "$1" | tail -1 | grep -oP 'cold_calls=\K[0-9]+' 2>/dev/null || true; }
extract_avg_hot_calls() { grep "AVG" "$1" | tail -1 | grep -oP 'hot_calls=\K[0-9]+' 2>/dev/null || true; }
extract_avg_cold_calls() { grep "AVG" "$1" | tail -1 | grep -oP 'cold_calls=\K[0-9]+' 2>/dev/null || true; }
extract_top_wait() {
    local line result
    line=$(grep "wait totals" "$1" | tail -1 | sed 's/.*samples): //' || true)
    result=$(echo "$line" | grep -oE '[A-Za-z]+:[A-Za-z_]+:\(total=[0-9]+' | head -1 | \
        sed 's/:(total=/ (/' | sed 's/$/)/' || true)
    echo "${result:-none}"
}

fmt_num() { printf "%'d" "$1" 2>/dev/null || echo "$1"; }

# Parse all existing result files
for build_type in "${BUILD_TYPES[@]}"; do
    for build in "${BUILDS[@]}"; do
        label="${build}_${build_type}"
        for protocol in "${PROTOCOLS[@]}"; do
            for workload in "${WORKLOADS[@]}"; do
                # Try new naming first, fall back to legacy
                f="$RESULTS_DIR/${label}_${workload}_${protocol}_full.txt"
                if [[ ! -f "$f" ]]; then
                    f="$RESULTS_DIR/${label}_${workload}_full.txt"
                fi
                [[ -f "$f" ]] || continue
                key="${label}/${protocol}/${workload}"
                TPS_RESULTS["$key"]=$(extract_tps "$f")
                DEALLOC_RESULTS["$key"]=$(extract_deallocs "$f")
                WAIT_RESULTS["$key"]=$(extract_top_wait "$f")
                ENTRIES_RESULTS["$key"]=$(extract_entries "$f")
                HOT_ENTRIES_RESULTS["$key"]=$(extract_hot_entries "$f")
                COLD_ENTRIES_RESULTS["$key"]=$(extract_cold_entries "$f")
                AVG_HOT_ENTRIES_RESULTS["$key"]=$(extract_avg_hot_entries "$f")
                AVG_COLD_ENTRIES_RESULTS["$key"]=$(extract_avg_cold_entries "$f")
                HOT_CALLS_RESULTS["$key"]=$(extract_hot_calls "$f")
                COLD_CALLS_RESULTS["$key"]=$(extract_cold_calls "$f")
                AVG_HOT_CALLS_RESULTS["$key"]=$(extract_avg_hot_calls "$f")
                AVG_COLD_CALLS_RESULTS["$key"]=$(extract_avg_cold_calls "$f")
            done
        done
    done
done

# Extract run parameters from result files
RUN_HEADER=$(grep -h 'Clients:' "$RESULTS_DIR"/*_full.txt 2>/dev/null | head -1)
RUN_CLIENTS=$(echo "$RUN_HEADER" | grep -oP 'Clients: \K[0-9]+' || echo "64")
RUN_DURATION=$(echo "$RUN_HEADER" | grep -oP 'Duration: \K[0-9]+' || echo "300")
RUN_JOBS=16

# Regenerate report
{
echo "=== pg_stat_statements Full Benchmark Matrix ==="
echo "$(head -2 "$FINAL_REPORT" | grep 'Date:' || echo 'Date: unknown')"
echo "Protocols: ${PROTOCOLS[*]}"
echo "Regenerated: $(date)"
echo ""
echo "Build configurations:"
echo "  release:        buildtype=release, cassert=false, ndebug=true"
echo "  debug:          buildtype=debug, cassert=true, ndebug=false"
echo "  debug_noassert: buildtype=debug, cassert=false, ndebug=true"
echo ""
echo "Method:"
echo "  For each test: pg_stat_statements_reset(), then pgbench (see per-test command below)."
echo "  While pgbench is running:"
echo "    - sample pg_stat_activity wait events (WHERE state = 'active') every 1s"
echo "    - query pg_stat_statements (entries, hot/cold calls) every 20s"
echo "      hot_calls = sum(calls) FILTER (WHERE query LIKE '%hot%')"
echo "      cold_calls = sum(calls) FILTER (WHERE query NOT LIKE '%hot%' AND query IS NOT NULL)"
echo "  After pgbench: final entry count, hot/cold calls, dealloc count from pg_stat_statements_info"
echo ""
echo "================================================================"
echo "                    COMBINED RESULTS SUMMARY                     "
echo "================================================================"

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

            [[ -z "$p_tps" && -z "$u_tps" ]] && continue

            delta="N/A"
            if [[ -n "$p_tps" && -n "$u_tps" && "$u_tps" != "0" ]]; then
                delta=$(echo "scale=1; ($p_tps - $u_tps) * 100 / $u_tps" | bc 2>/dev/null)
                delta=$(printf "%+.1f%%" "$delta" 2>/dev/null || echo "N/A")
            fi

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

            # Dynamic column widths
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

            echo ""
            echo "=== ${heading} ==="
            echo "  pgbench -f bench_${workload}.sql -c $RUN_CLIENTS -j $RUN_JOBS -T $RUN_DURATION -M $protocol"
            printf "+-%s-+-%s-+-%s-+-%s-+\n" "$hrule1" "$hrule2" "$hrule3" "$hrule4"
            printf "| %-${col1}s | %-${col2}s | %-${col3}s | %-${col4}s |\n" \
                "" "patch" "upstream" "delta"
            printf "+-%s-+-%s-+-%s-+-%s-+\n" "$hrule1" "$hrule2" "$hrule3" "$hrule4"
            printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                "TPS" "$p_tps_f" "$u_tps_f" "$delta"
            printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                "entries" "$p_entries_f" "$u_entries_f" ""
            if [[ "$p_hot_ent_f" != "N/A" || "$u_hot_ent_f" != "N/A" ]]; then
                printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                    "hot_ent(avg)" "$p_avg_hot_ent_f" "$u_avg_hot_ent_f" ""
                printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                    "cold_ent(avg)" "$p_avg_cold_ent_f" "$u_avg_cold_ent_f" ""
                printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                    "hot_cal(avg)" "$p_avg_hot_f" "$u_avg_hot_f" ""
                printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                    "cold_cal(avg)" "$p_avg_cold_f" "$u_avg_cold_f" ""
            fi
            printf "| %-${col1}s | %${col2}s | %${col3}s | %${col4}s |\n" \
                "deallocs" "$p_dealloc_f" "$u_dealloc_f" ""
            printf "| %-${col1}s | %-${col2}s | %-${col3}s | %${col4}s |\n" \
                "top_wait" "$p_wait" "$u_wait" ""
            printf "+-%s-+-%s-+-%s-+-%s-+\n" "$hrule1" "$hrule2" "$hrule3" "$hrule4"
        done
    done
done

echo ""
echo "Results directory: $RESULTS_DIR"
echo "Individual run details: ${RESULTS_DIR}/<config>_<workload>_<protocol>_full.txt"
echo "=== DONE ==="
} > "${RESULTS_DIR}/final_report_fixed.txt"

echo "Regenerated report: ${RESULTS_DIR}/final_report_fixed.txt"
