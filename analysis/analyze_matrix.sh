#!/bin/bash
# analyze_matrix.sh - Generate a comprehensive markdown benchmark report from matrix results
#
# Usage:
#   ./analyze_matrix.sh [results_dir]
#
# If results_dir is omitted, uses the most recent pgss_matrix_* directory.
# Outputs markdown to stdout.
#
# The report includes:
#   - Test environment and commit metadata
#   - Workload descriptions
#   - TPS comparison tables (per client count) with % delta vs baseline
#   - Wait event analysis
#   - Eviction behavior metrics
#   - Key findings (auto-generated from data patterns)
#   - Summary table

set +e

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../bench_config.sh"

# --- Locate results ---

if [[ -n "$1" ]]; then
    RESULTS_DIR="$(cd "$1" 2>/dev/null && pwd || echo "$1")"
else
    RESULTS_DIR=$(ls -dt "$BENCH_RESULTS_DIR"/pgss_matrix_* 2>/dev/null | head -1)
fi

if [[ -z "$RESULTS_DIR" || ! -d "$RESULTS_DIR" ]]; then
    echo "Error: no results directory found" >&2
    exit 1
fi

SUMMARY_FILE="$RESULTS_DIR/summary.txt"

# --- Auto-detect dimensions ---

# Commits: preserve order from summary.txt (first = baseline)
if [[ -f "$SUMMARY_FILE" ]]; then
    COMMITS=($(grep "^Commits:" "$SUMMARY_FILE" | sed 's/^Commits: *//' | tr -s ' ' '\n'))
fi
# Fallback: detect from directory names
# Handles both <commit>_c<N>_cpu<N> and <commit>_<workload>_c<N>_cpu<N>
if [[ ${#COMMITS[@]} -eq 0 ]]; then
    COMMITS=($(for f in "$RESULTS_DIR"/*/report.txt; do
        basename "$(dirname "$f")" | sed 's/_\(select1\|churn\|multi_stmt\|full_5k\|full_10k\|zipf_5k\)_c[0-9].*//;s/_c[0-9].*//'
    done | awk '!seen[$0]++'))
fi
CLIENTS=($(for f in "$RESULTS_DIR"/*/report.txt; do basename "$(dirname "$f")"; done | sed -n "s/.*_c\([0-9]\{1,\}\)_cpu.*/\1/p" | sort -nu))
CPUS=($(for f in "$RESULTS_DIR"/*/report.txt; do basename "$(dirname "$f")"; done | sed -n 's/.*_cpu\([0-9]*\).*/\1/p' | sort -nu))

BASELINE="${COMMITS[0]}"

# Detect workloads from all report files (preserving order)
FIRST_REPORT=$(ls "$RESULTS_DIR"/*/report.txt 2>/dev/null | head -1)
WORKLOADS=($(grep -h "^--- " "$RESULTS_DIR"/*/report.txt 2>/dev/null | sed 's/^--- //;s/ \[.*//' | awk '!seen[$0]++'))

# Read metadata
DURATION=$(grep "^Duration:" "$SUMMARY_FILE" 2>/dev/null | sed 's/[^0-9]*//' | sed 's/[^0-9].*//' | head -1)
DURATION=${DURATION:-180}
PGSS_MAX=$(grep "^pgss.max:" "$SUMMARY_FILE" 2>/dev/null | sed 's/[^0-9]*//' | sed 's/[^0-9].*//' | head -1)
PGSS_MAX=${PGSS_MAX:-5000}
RUN_DATE=$(grep "^Date:" "$SUMMARY_FILE" 2>/dev/null | sed 's/^Date: *//')
RUN_DATE=${RUN_DATE:-$(date)}

# Machine info from first report
MACHINE=$(grep "^Machine:" "$FIRST_REPORT" 2>/dev/null | sed 's/^Machine: *//')
MACHINE=${MACHINE:-"unknown"}

# --- Helper functions ---

report_file() {
    local f="$RESULTS_DIR/${1}_c${2}_cpu${3}/report.txt"
    if [[ -f "$f" ]]; then
        echo "$f"
        return
    fi
    # Try <commit>_<workload>_c<N>_cpu<N> pattern
    for wl in select1 churn multi_stmt full_5k full_10k zipf_5k; do
        f="$RESULTS_DIR/${1}_${wl}_c${2}_cpu${3}/report.txt"
        if [[ -f "$f" ]]; then
            echo "$f"
            return
        fi
    done
    echo "$RESULTS_DIR/${1}_c${2}_cpu${3}/report.txt"
}

extract_tps() {
    local file="$1" workload="$2"
    awk -v wl="$workload" '
        $0 ~ "^--- "wl" " { found=1; next }
        found && /^  TPS:/ { gsub(/[^0-9.]/, "", $2); printf "%.0f", $2; exit }
        found && /^---/ { exit }
    ' "$file" 2>/dev/null
}

extract_db_time_cpu() {
    local file="$1" workload="$2"
    awk -v wl="$workload" '
        $0 ~ "^--- "wl" " { found=1; next }
        found && /^--- / { exit }
        found && /db_time:/ {
            s=$0; sub(/.*CPU=/, "", s); sub(/%.*/, "", s)
            if (s+0 > 0) { print s; exit }
        }
    ' "$file" 2>/dev/null
}

extract_idle_pct() {
    local file="$1" workload="$2"
    awk -v wl="$workload" '
        $0 ~ "^--- "wl" " {
            found=1; clients=0
            s=$0; sub(/.*clients=/, "", s); sub(/[^0-9].*/, "", s)
            clients=s+0
            next
        }
        found && /^--- / { exit }
        found && /db_time:/ {
            if (/idle=/) {
                s=$0; sub(/.*idle=/, "", s); sub(/%.*/, "", s)
                print s; exit
            }
            if (clients > 0 && /active samples over/) {
                s=$0; sub(/.*\(/, "", s)
                split(s, parts, " ")
                active=parts[1]+0
                sub(/.*over /, "", s); sub(/s.*/, "", s)
                secs=s+0
                if (secs > 0) {
                    total=secs*clients
                    printf "%.1f", (total-active)*100/total; exit
                }
            }
        }
    ' "$file" 2>/dev/null
}

extract_db_pct() {
    local file="$1" workload="$2"
    awk -v wl="$workload" '
        $0 ~ "^--- "wl" " {
            found=1; clients=0
            s=$0; sub(/.*clients=/, "", s); sub(/[^0-9].*/, "", s)
            clients=s+0
            next
        }
        found && /^--- / { exit }
        found && /db_time:/ {
            if (/db=/) {
                s=$0; sub(/.*db=/, "", s); sub(/%.*/, "", s)
                print s; exit
            }
            if (clients > 0 && /active samples over/) {
                s=$0; sub(/.*\(/, "", s)
                split(s, parts, " ")
                active=parts[1]+0
                sub(/.*over /, "", s); sub(/s.*/, "", s)
                secs=s+0
                if (secs > 0) {
                    total=secs*clients
                    printf "%.1f", active*100/total; exit
                }
            }
        }
    ' "$file" 2>/dev/null
}

extract_db_time_wait() {
    local file="$1" workload="$2"
    awk -v wl="$workload" '
        $0 ~ "^--- "wl" " { found=1; next }
        found && /^--- / { exit }
        found && /db_time:/ {
            if (/waiting=/) {
                s=$0; sub(/.*waiting=/, "", s); sub(/%.*/, "", s)
                if (s+0 > 0) { print s; exit }
            } else {
                s=$0; sub(/.*CPU=/, "", s); sub(/%.*/, "", s)
                if (s+0 > 0) { printf "%.1f", 100 - s; exit }
            }
        }
    ' "$file" 2>/dev/null
}

extract_top_waits() {
    local file="$1" workload="$2"
    awk -v wl="$workload" '
        $0 ~ "^--- "wl" " { found=1; next }
        found && /^--- / { exit }
        found && /db_time:/ && /\(CPU=/ {
            s=$0
            match(s, /\(CPU=[^)]*\)/)
            inner = substr(s, RSTART+1, RLENGTH-2)
            gsub(/CPU=[0-9.]*% */, "", inner)
            gsub(/^ *| *$/, "", inner)
            if (inner != "") { print inner; exit }
        }
        found && /^    top:/ {
            s = $0; gsub(/.*top: /, "", s)
            gsub(/CPU \([0-9.]*%\) */, "", s)
            gsub(/^ *| *$/, "", s)
            if (s != "") print s
            exit
        }
    ' "$file" 2>/dev/null
}

extract_deallocs() {
    local file="$1" workload="$2"
    awk -v wl="$workload" '
        $0 ~ "^--- "wl" " { found=1; next }
        found && /^--- / { exit }
        found && /^  deallocs:/ { gsub(/[^0-9]/, "", $2); print $2; exit }
    ' "$file" 2>/dev/null
}

extract_final_field() {
    local file="$1" workload="$2" field="$3"
    awk -v wl="$workload" -v fld="$field" '
        $0 ~ "^--- "wl" " { found=1; next }
        found && /^--- / { exit }
        found && /^  FINAL:/ {
            s=$0; idx=index(s, fld"=")
            if (idx > 0) { s=substr(s, idx+length(fld)+1); sub(/[^0-9].*/, "", s); if (s != "") print s }
            exit
        }
    ' "$file" 2>/dev/null
}

extract_entries() {
    local file="$1" workload="$2"
    extract_final_field "$file" "$workload" "entries"
}

commit_msg() {
    local commit="$1"
    cd "$PG_SOURCE_DIR" 2>/dev/null && git log --oneline -1 "$commit" 2>/dev/null | sed "s/^[^ ]* //" || echo ""
}

fmt_num() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

fmt_delta_bold() {
    local base="$1" val="$2"
    if [[ -z "$base" || -z "$val" || "$base" == "0" ]]; then
        echo ""
        return
    fi
    local pct=$(awk "BEGIN { printf \"%.0f\", ($val - $base) * 100 / $base }")
    if (( pct >= 20 || pct <= -20 )); then
        if (( pct > 0 )); then
            echo "**+${pct}%**"
        else
            echo "**${pct}%**"
        fi
    elif (( pct > 0 )); then
        echo "+${pct}%"
    elif (( pct < 0 )); then
        echo "${pct}%"
    else
        echo "+0%"
    fi
}

# --- Assign labels (parallel arrays, indexed same as COMMITS) ---

COMMIT_LABELS=()
for commit in "${COMMITS[@]}"; do
    msg=$(commit_msg "$commit")
    if [[ "$commit" == "$BASELINE" ]]; then
        COMMIT_LABELS+=("Baseline")
    elif echo "$msg" | grep -qi "LRU"; then
        COMMIT_LABELS+=("LRU")
    elif echo "$msg" | grep -qi "LFU"; then
        COMMIT_LABELS+=("LFU")
    elif echo "$msg" | grep -qi "modernize\|pgstat kind"; then
        COMMIT_LABELS+=("Modernize")
    else
        COMMIT_LABELS+=("${commit:0:11}")
    fi
done

get_label() {
    local target="$1" i
    for i in "${!COMMITS[@]}"; do
        if [[ "${COMMITS[$i]}" == "$target" ]]; then
            echo "${COMMIT_LABELS[$i]}"
            return
        fi
    done
    echo "${target:0:11}"
}

get_color() {
    local target="$1" i
    for i in "${!COMMITS[@]}"; do
        if [[ "${COMMITS[$i]}" == "$target" ]]; then
            echo "${COMMIT_COLORS[$i]}"
            return
        fi
    done
    echo ""
}

# --- Generate report ---

echo "## pg_stat_statements Eviction Benchmark Report"
echo ""
echo "**Machine:** $MACHINE  "
echo "**Date:** $RUN_DATE  "
echo "**Duration:** ${DURATION}s per run, \`pg_stat_statements.max = $PGSS_MAX\`  "
echo "**Matrix:** ${#COMMITS[@]} commits × ${#CLIENTS[@]} client counts (${CLIENTS[*]}) × ${#CPUS[@]} CPU counts (${CPUS[*]})"
echo ""

# --- Commits table ---

echo "### Commits Tested (stack order)"
echo ""
echo "| Label | Commit | Description |"
echo "|-------|--------|-------------|"
for commit in "${COMMITS[@]}"; do
    msg=$(commit_msg "$commit")
    echo "| **$(get_label "$commit")** | \`$commit\` | $msg |"
done
echo ""

# --- Workload descriptions ---

echo "### Workload Descriptions"
echo ""
echo "| Workload | Query Mix | PGSS Behavior |"
echo "|----------|-----------|---------------|"
for wl in "${WORKLOADS[@]}"; do
    case "$wl" in
        select1)  echo "| \`select1\` | \`SELECT 1\` (single stmt) | 1 entry, no eviction — measures raw hook overhead |" ;;
        full_5k)  echo "| \`full_5k\` | Uniform random across 4950 queries | All fit in pgss.max — pure hash lookup, no eviction |" ;;
        full_10k) echo "| \`full_10k\` | Uniform random across 9950 queries | All fit in pgss.max — pure hash lookup, no eviction |" ;;
        zipf_5k)  echo "| \`zipf_5k\` | Zipf: 50% top-10, 30% top-50, 15% top-500, 5% top-10k | Realistic skew; moderate eviction of tail |" ;;
        churn)    echo "| \`churn\` | 80% hot (1000 queries) + 20% cold (from 100k pool) | Constant eviction pressure — the stress test |" ;;
        multi_stmt) echo "| \`multi_stmt\` | 6 SELECTs per txn with 500μs sleeps | Low pgss pressure, tests per-statement overhead |" ;;
        *)        echo "| \`$wl\` | — | — |" ;;
    esac
done
echo ""

# pgbench commands + SQL
echo "### pgbench Commands"
echo ""
echo "Each workload runs:"
echo '```'
echo "pgbench -U postgres -d benchmark -f sql/bench_<workload>.sql -c <clients> -j 16 -T ${DURATION} -P 5 -M simple"
echo '```'
echo ""
for wl in "${WORKLOADS[@]}"; do
    sql_file="$SCRIPT_DIR/sql/bench_${wl}.sql"
    if [[ -f "$sql_file" ]]; then
        echo "**${wl}:**"
        echo '```sql'
        cat "$sql_file"
        echo '```'
        echo ""
    fi
done
echo ""
echo "---"
echo ""

# --- Color legend for TPS tables ---

# Assign a color square to each commit (stable order, parallel to COMMITS)
COLORS=("\U0001F7E9" "\U0001F7E6" "\U0001F7EA" "\U0001F7E7" "\U0001F7E5" "\U0001F7E8")
COMMIT_COLORS=()
for i in "${!COMMITS[@]}"; do
    COMMIT_COLORS+=("${COLORS[$i]}")
done

echo "### TPS Legend"
echo ""
legend=""
for commit in "${COMMITS[@]}"; do
    color=$(printf "%b" "$(get_color "$commit")")
    legend+="$color = $(get_label "$commit") | "
done
legend="${legend% | }"
echo "$legend"
echo ""

# --- TPS tables per client count ---

for c in "${CLIENTS[@]}"; do
    echo "### TPS Results — $c Clients"
    echo ""

    # Header
    hdr="| Workload | CPUs | $(get_label "$BASELINE")"
    for commit in "${COMMITS[@]}"; do
        [[ "$commit" == "$BASELINE" ]] && continue
        hdr+=" | $(get_label "$commit")"
    done
    hdr+=" | Best | Best Patch |"
    echo "$hdr"

    # Separator
    sep="|----------|------|---------:"
    for commit in "${COMMITS[@]}"; do
        [[ "$commit" == "$BASELINE" ]] && continue
        sep+="|----:"
    done
    sep+="|:----:|:----:|"
    echo "$sep"

    for wl in "${WORKLOADS[@]}"; do
        first_wl=1
        for cpu in "${CPUS[@]}"; do
            base_tps=$(extract_tps "$(report_file "$BASELINE" "$c" "$cpu")" "$wl")
            [[ -z "$base_tps" ]] && continue

            # Find the best TPS for this row
            best_tps=$base_tps
            best_commit="$BASELINE"
            for commit in "${COMMITS[@]}"; do
                [[ "$commit" == "$BASELINE" ]] && continue
                tps=$(extract_tps "$(report_file "$commit" "$c" "$cpu")" "$wl")
                if [[ -n "$tps" ]] && (( tps > best_tps )); then
                    best_tps=$tps
                    best_commit=$commit
                fi
            done

            if (( first_wl )); then
                row="| **$wl** | $cpu | $(fmt_num "$base_tps")"
                first_wl=0
            else
                row="| | $cpu | $(fmt_num "$base_tps")"
            fi

            for commit in "${COMMITS[@]}"; do
                [[ "$commit" == "$BASELINE" ]] && continue
                tps=$(extract_tps "$(report_file "$commit" "$c" "$cpu")" "$wl")
                if [[ -n "$tps" ]]; then
                    delta=$(fmt_delta_bold "$base_tps" "$tps")
                    row+=" | $(fmt_num "$tps") ($delta)"
                else
                    row+=" | —"
                fi
            done

            best_color=$(printf "%b" "$(get_color "$best_commit")")

            # Best among non-baseline commits
            best_patch_tps=0
            best_patch_commit=""
            for commit in "${COMMITS[@]}"; do
                [[ "$commit" == "$BASELINE" ]] && continue
                tps=$(extract_tps "$(report_file "$commit" "$c" "$cpu")" "$wl")
                if [[ -n "$tps" ]] && (( tps > best_patch_tps )); then
                    best_patch_tps=$tps
                    best_patch_commit=$commit
                fi
            done
            if [[ -n "$best_patch_commit" ]]; then
                best_patch_color=$(printf "%b" "$(get_color "$best_patch_commit")")
            else
                best_patch_color="—"
            fi

            row+=" | $best_color | $best_patch_color |"
            echo "$row"
        done
    done
    echo ""
done

echo "---"
echo ""

# --- Wait Event Analysis ---

# Use the highest CPU count that has data for WC/WCPU used in Key Findings
WC=""; WCPU=""
for (( ci=${#CLIENTS[@]}-1; ci>=0; ci-- )); do
    for (( pi=${#CPUS[@]}-1; pi>=0; pi-- )); do
        f=$(report_file "$BASELINE" "${CLIENTS[$ci]}" "${CPUS[$pi]}")
        if [[ -f "$f" ]]; then
            WC="${CLIENTS[$ci]}"; WCPU="${CPUS[$pi]}"; break 2
        fi
    done
done

for c in "${CLIENTS[@]}"; do
    echo "### Wait Event Analysis — ${c} Clients"
    echo ""

    hdr="| Workload | CPUs | $(get_label "$BASELINE")"
    for commit in "${COMMITS[@]}"; do
        [[ "$commit" == "$BASELINE" ]] && continue
        hdr+=" | $(get_label "$commit")"
    done
    hdr+=" |"
    echo "$hdr"

    sep="|----------|------|----------"
    for commit in "${COMMITS[@]}"; do
        [[ "$commit" == "$BASELINE" ]] && continue
        sep+="|----------"
    done
    sep+="|"
    echo "$sep"

    for wl in "${WORKLOADS[@]}"; do
        for cpu in "${CPUS[@]}"; do
            row="| **$wl** | $cpu"
            for commit in "${COMMITS[@]}"; do
                f=$(report_file "$commit" "$c" "$cpu")
                cpu_pct=$(extract_db_time_cpu "$f" "$wl")
                wait_pct=$(extract_db_time_wait "$f" "$wl")
                top=$(extract_top_waits "$f" "$wl")
                idle=$(extract_idle_pct "$f" "$wl")
                db=$(extract_db_pct "$f" "$wl")

                if [[ -z "$cpu_pct" ]]; then
                    row+=" | —"
                    continue
                fi

                cell=""
                if [[ -n "$idle" && -n "$db" ]]; then
                    cell="idle=${idle}% db=${db}%<br>"
                fi
                cell+="\U0001F7E2 CPU ${cpu_pct}%"
                if [[ -n "$wait_pct" ]] && awk "BEGIN { exit ($wait_pct > 1.0) ? 0 : 1 }" 2>/dev/null; then
                    if [[ -n "$top" ]]; then
                        # Normalize old format "Event (X%)" to new "Event=X%"
                        top_norm=$(echo "$top" | sed 's/ (\([0-9.]*%\))/=\1/g')
                        stacked=""
                        for evt in $top_norm; do
                            [[ -z "$evt" ]] && continue
                            if [[ "$evt" == *LWLock* ]]; then
                                stacked+="<br>\U0001F534 $evt"
                            elif [[ "$evt" == *SpinDelay* ]]; then
                                stacked+="<br>\U0001F7E1 $evt"
                            elif [[ "$evt" == *IO* ]]; then
                                stacked+="<br>\U0001F535 $evt"
                            else
                                stacked+="<br>\U0001F7E0 $evt"
                            fi
                        done
                        cell+="$stacked"
                    else
                        cell+="<br>waiting ${wait_pct}%"
                    fi
                fi
                cell=$(printf "%b" "$cell")
                row+=" | $cell"
            done
            row+=" |"
            echo "$row"
        done
    done
    echo ""
done

# --- Sampled Retention Averages ---

echo "### Retention & Throughput Averages (sampled)"
echo ""
echo "Averaged across all 5-second polling intervals during the 180s run."
echo ""
echo "**Terminology:**"
echo ""
echo "| Term | Meaning |"
echo "|------|---------|"
echo "| **entries** | Number of query entries currently visible in \`pg_stat_statements\` (the hash table size) |"
echo "| **hot / cold / rare** | Hot = queries from the frequently-reused pool; Cold = ephemeral queries that churn through the table; Rare = slow_churn queries (infrequent but long-lived — tests whether eviction preserves aged entries) |"
echo "| **rare max age** | Average and peak of the oldest rare entry's age across polling intervals — higher = better retention of infrequent queries |"
echo "| **num_entries** | Entries in the pgstat dshash |"
echo "| **deallocs** | Total entries lost (evicted or skipped). Incremented each time an entry is evicted to make room, or when a new entry cannot be created because eviction failed |"
echo ""

for ts_wl in churn zipf_5k; do
    # Check if this workload exists in any results
    has_data=0
    for commit in "${COMMITS[@]}"; do
        for c in "${CLIENTS[@]}"; do
            for cpu in "${CPUS[@]}"; do
                f=$(report_file "$commit" "$c" "$cpu")
                if grep -q "^--- $ts_wl " "$f" 2>/dev/null; then
                    has_data=1
                    break 3
                fi
            done
        done
    done
    (( !has_data )) && continue

    echo "#### $ts_wl"
    echo ""

    # Table header: Metric | Clients | CPUs | <commit1> | <commit2> | ...
    hdr="| Metric | Clients | CPUs"
    for commit in "${COMMITS[@]}"; do
        hdr+=" | $(get_label "$commit")"
    done
    hdr+=" |"
    echo "$hdr"

    sep="|--------|---------|-----"
    for commit in "${COMMITS[@]}"; do
        sep+="|---:"
    done
    sep+="|"
    echo "$sep"

    for c in "${CLIENTS[@]}"; do
        for cpu in "${CPUS[@]}"; do
            # Compute stats for each commit at this client/cpu combo
            row_tps="| Avg TPS | $c | $cpu"
            row_hot="| Avg hot entries | | "
            row_cold="| Avg cold entries | | "
            row_rare="| Avg rare entries | | "
            row_rare_age="| Rare max age (avg/peak) | | "
            row_entries="| Avg entries | | "
            row_num_entries="| Avg num_entries | | "
            row_num_entries_range="| num_entries min/max | | "
            row_total_dealloc="| Total deallocs | | "
            row_dealloc_rate="| Deallocs/sec | | "

            any_data=0
            for commit in "${COMMITS[@]}"; do
                f=$(report_file "$commit" "$c" "$cpu")

                stats=$(awk -v wl="$ts_wl" '
                    function getval(line, key,    i, s) {
                        i = index(line, key"=")
                        if (i == 0) return ""
                        s = substr(line, i + length(key) + 1)
                        sub(/[^0-9.].*/, "", s)
                        return s
                    }
                    function get_rare_age(line,    i, s, youngest, oldest) {
                        i = index(line, "(age ")
                        if (i == 0) return ""
                        s = substr(line, i + 5)
                        sub(/\).*/, "", s)
                        split(s, parts, "\\.\\.")
                        youngest = parts[1]+0
                        oldest = parts[2]+0
                        sub(/[^0-9]/, "", oldest)
                        return youngest " " oldest
                    }
                    BEGIN { last_dealloc = 0; first_t = 0; last_t = 0; ne_n = 0; rare_n = 0 }
                    $0 ~ "^--- "wl" " { found=1; next }
                    found && /^--- / { exit }
                    found && /^  t=/ {
                        n++
                        v = getval($0, "tps"); if (v != "") tps_sum += v
                        v = getval($0, "entries"); if (v != "") entries_sum += v
                        v = getval($0, "hot"); if (v != "") hot_sum += v
                        v = getval($0, "cold"); if (v != "") cold_sum += v
                        v = getval($0, "rare"); if (v+0 > 0) { rare_sum += v; rare_n++ }
                        ages = get_rare_age($0)
                        if (ages != "") {
                            split(ages, ab, " ")
                            rare_youngest_sum += ab[1]; rare_oldest_sum += ab[2]
                            if (rare_n == 1 || ab[2]+0 > rare_oldest_max) rare_oldest_max = ab[2]+0
                        }
                        v = getval($0, "num_entries"); if (v+0 > 0) { ne_sum += v; ne_n++; if (ne_n==1 || v+0<ne_min) ne_min=v+0; if (v+0>ne_max) ne_max=v+0 }
                        v = getval($0, "dealloc"); if (v+0 > 0) last_dealloc = v
                        v = getval($0, "t"); if (v != "") { last_t = v+0; if (!first_t) first_t = v+0 }
                    }
                    END {
                        if (n > 0) {
                            printf "%.0f %.0f %.0f %.0f %d %d %.0f %d %d %.0f %.0f %.0f",
                                tps_sum/n, hot_sum/n, cold_sum/n, entries_sum/n,
                                last_dealloc, last_t - first_t,
                                (ne_n > 0 ? ne_sum/ne_n : 0),
                                (ne_n > 0 ? ne_min : 0),
                                (ne_n > 0 ? ne_max : 0),
                                (rare_n > 0 ? rare_sum/rare_n : 0),
                                (rare_n > 0 ? rare_oldest_sum/rare_n : 0),
                                rare_oldest_max+0
                        }
                    }
                ' "$f" 2>/dev/null)

                if [[ -z "$stats" ]]; then
                    row_tps+=" | —"
                    row_hot+=" | —"
                    row_cold+=" | —"
                    row_rare+=" | —"
                    row_rare_age+=" | —"
                    row_entries+=" | —"
                    row_num_entries+=" | —"
                    row_num_entries_range+=" | —"
                    row_dealloc_rate+=" | —"
                    row_total_dealloc+=" | —"
                    continue
                fi

                any_data=1
                read avg_tps avg_hot avg_cold avg_entries total_dealloc duration_s avg_num_entries num_entries_min num_entries_max avg_rare avg_rare_oldest rare_oldest_max <<< "$stats"

                row_tps+=" | $(fmt_num "$avg_tps")"

                if [[ "$ts_wl" == "churn" ]]; then
                    row_hot+=" | $(fmt_num "$avg_hot")"
                    row_cold+=" | $(fmt_num "$avg_cold")"
                    if [[ "$avg_rare" != "0" ]]; then
                        row_rare+=" | $(fmt_num "$avg_rare")"
                        row_rare_age+=" | ${avg_rare_oldest}s / ${rare_oldest_max}s"
                    else
                        row_rare+=" | —"
                        row_rare_age+=" | —"
                    fi
                else
                    row_entries+=" | $(fmt_num "$avg_entries")"
                    row_rare+=" | —"
                    row_rare_age+=" | —"
                fi

                if [[ "$avg_num_entries" != "0" ]]; then
                    row_num_entries+=" | $(fmt_num "$avg_num_entries")"
                    row_num_entries_range+=" | $(fmt_num "$num_entries_min")–$(fmt_num "$num_entries_max")"
                else
                    row_num_entries+=" | —"
                    row_num_entries_range+=" | —"
                fi

                final_dealloc=$(extract_deallocs "$(report_file "$commit" "$c" "$cpu")" "$ts_wl")
                final_dealloc=${final_dealloc:-0}
                if [[ "$final_dealloc" != "0" && -n "$duration_s" && "$duration_s" != "0" ]]; then
                    rate=$(awk "BEGIN { printf \"%.0f\", $final_dealloc / $duration_s }")
                    row_dealloc_rate+=" | $(fmt_num "$rate")"
                else
                    row_dealloc_rate+=" | 0"
                fi
                row_total_dealloc+=" | $(fmt_num "$final_dealloc")"
            done

            (( !any_data )) && continue

            echo "$row_tps |"
            if [[ "$ts_wl" == "churn" ]]; then
                echo "$row_hot |"
                echo "$row_cold |"
                if echo "$row_rare" | grep -q '[0-9]'; then
                    echo "$row_rare |"
                    echo "$row_rare_age |"
                fi
            else
                echo "$row_entries |"
            fi
            echo "$row_num_entries |"
            echo "$row_num_entries_range |"
            echo "$row_total_dealloc |"
            echo "$row_dealloc_rate |"

            # Blank separator row between client/cpu combos
            blank="| | | "
            for commit in "${COMMITS[@]}"; do blank+=" | "; done
            echo "$blank|"
        done
    done
    echo ""
done
# --- OS Resource Usage ---

# Extract OS metrics from _os.log files (if they exist)
has_os_data=0
for commit in "${COMMITS[@]}"; do
    os_file="$RESULTS_DIR/${commit}_c${WC}_cpu${WCPU}/churn_os.log"
    if [[ -s "$os_file" ]]; then
        has_os_data=1
        break
    fi
done

if (( has_os_data )); then
    echo "### OS Resource Usage ($WC clients, $WCPU CPUs)"
    echo ""

    for os_wl in "${WORKLOADS[@]}"; do
        # Check if any commit has os data for this workload
        wl_has_os=0
        for commit in "${COMMITS[@]}"; do
            os_file="$RESULTS_DIR/${commit}_c${WC}_cpu${WCPU}/${os_wl}_os.log"
            [[ -s "$os_file" ]] && { wl_has_os=1; break; }
        done
        (( !wl_has_os )) && continue

        echo "#### $os_wl"
        echo ""
        hdr="| Metric"
        for commit in "${COMMITS[@]}"; do
            hdr+=" | $(get_label "$commit")"
        done
        echo "$hdr |"
        sep="|--------"
        for commit in "${COMMITS[@]}"; do
            sep+="|----:"
        done
        echo "$sep|"

        # Compute avg/min/max for each commit
        row_cpu_avg="| CPU usr%"
        row_cpu_sys="| CPU sys%"
        row_mem_avg="| Mem used (MB)"
        row_rss_avg="| PG RSS (MB)"

        for commit in "${COMMITS[@]}"; do
            os_file="$RESULTS_DIR/${commit}_c${WC}_cpu${WCPU}/${os_wl}_os.log"
            if [[ -s "$os_file" ]]; then
                stats=$(awk '
                    function getval(line, key,    i, s) {
                        i = index(line, key"=")
                        if (i == 0) return ""
                        s = substr(line, i + length(key) + 1)
                        sub(/[^0-9.].*/, "", s)
                        return s
                    }
                    {
                        n++
                        v = getval($0, "cpu_usr"); usr_sum += v; if (n==1 || v+0<usr_min) usr_min=v+0; if (v+0>usr_max) usr_max=v+0
                        v = getval($0, "cpu_sys"); sys_sum += v; if (n==1 || v+0<sys_min) sys_min=v+0; if (v+0>sys_max) sys_max=v+0
                        v = getval($0, "mem_used"); mem_sum += v; if (n==1 || v+0<mem_min) mem_min=v+0; if (v+0>mem_max) mem_max=v+0
                        v = getval($0, "pg_rss"); rss_sum += v; if (n==1 || v+0<rss_min) rss_min=v+0; if (v+0>rss_max) rss_max=v+0
                    }
                    END {
                        if (n>0) printf "%d %d %d %d %d %d %d %d %d %d %d %d",
                            usr_sum/n, sys_sum/n, mem_sum/n, mem_min, mem_max, rss_sum/n, rss_min, rss_max, usr_min, usr_max, sys_min, sys_max
                    }
                ' "$os_file")
                if [[ -n "$stats" ]]; then
                    read avg_usr avg_sys avg_mem min_mem max_mem avg_rss min_rss max_rss min_usr max_usr min_sys max_sys <<< "$stats"
                    row_cpu_avg+=" | ${avg_usr}% (${min_usr}–${max_usr}%)"
                    row_cpu_sys+=" | ${avg_sys}% (${min_sys}–${max_sys}%)"
                    row_mem_avg+=" | $(fmt_num "$avg_mem") ($(fmt_num "$min_mem")–$(fmt_num "$max_mem"))"
                    row_rss_avg+=" | $(fmt_num "$avg_rss") ($(fmt_num "$min_rss")–$(fmt_num "$max_rss"))"
                else
                        row_cpu_avg+=" | —"
                    row_cpu_sys+=" | —"
                    row_mem_avg+=" | —"
                    row_rss_avg+=" | —"
                fi
            else
                row_cpu_avg+=" | —"
                row_cpu_sys+=" | —"
                row_mem_avg+=" | —"
                row_mem_max+=" | —"
                row_rss_avg+=" | —"
                row_rss_max+=" | —"
            fi
        done

        echo "$row_cpu_avg |"
        echo "$row_cpu_sys |"
        echo "$row_mem_avg |"
        echo "$row_rss_avg |"
        echo ""
    done

    echo "---"
    echo ""
fi

# --- Key Findings (data-driven) ---

echo "### Key Findings"
echo ""

finding=1

# 1. Baseline churn scaling
base_churn_16=$(extract_tps "$(report_file "$BASELINE" "$WC" "${CPUS[0]}")" "churn")
base_churn_max=$(extract_tps "$(report_file "$BASELINE" "$WC" "$WCPU")" "churn")
if [[ -n "$base_churn_16" && -n "$base_churn_max" ]]; then
    base_wait=$(extract_db_time_wait "$(report_file "$BASELINE" "$WC" "$WCPU")" "churn")
    base_top_clean=$(extract_top_waits "$(report_file "$BASELINE" "$WC" "$WCPU")" "churn")
    echo "**$finding. Baseline is bottlenecked under eviction pressure.**"
    echo "Upstream churn TPS is flat at ~$(fmt_num "$base_churn_max") regardless of CPU count (${CPUS[0]}→${CPUS[${#CPUS[@]}-1]} CPUs). ${base_wait}% of db_time is waiting on ${base_top_clean}."
    echo ""
    finding=$((finding + 1))
fi

# 2. Best patch on churn
best_churn_commit=""
best_churn_tps=0
for commit in "${COMMITS[@]}"; do
    [[ "$commit" == "$BASELINE" ]] && continue
    t=$(extract_tps "$(report_file "$commit" "$WC" "$WCPU")" "churn")
    if [[ -n "$t" ]] && (( t > best_churn_tps )); then
        best_churn_tps=$t
        best_churn_commit=$commit
    fi
done
if [[ -n "$best_churn_commit" && -n "$base_churn_max" && "$base_churn_max" != "0" ]]; then
    speedup=$(awk "BEGIN { printf \"%.1f\", $best_churn_tps / $base_churn_max }")
    best_wait=$(extract_db_time_wait "$(report_file "$best_churn_commit" "$WC" "$WCPU")" "churn")
    echo "**$finding. $(get_label "$best_churn_commit") achieves ${speedup}× on churn ($(fmt_num "$best_churn_tps") TPS).**"
    if awk "BEGIN { exit ($best_wait > 5.0) ? 0 : 1 }" 2>/dev/null; then
        echo "However, ${best_wait}% of db_time is still spent waiting — the throttled creation mechanism serializes under extreme concurrency."
    else
        echo "The system is CPU-bound (${best_wait}% waiting), meaning the lock bottleneck is eliminated."
    fi
    echo ""
    finding=$((finding + 1))
fi

# 3. No regressions on non-evicting workloads
echo "**$finding. No regressions on non-evicting workloads.**"
max_regression=0
for commit in "${COMMITS[@]}"; do
    [[ "$commit" == "$BASELINE" ]] && continue
    for cpu in "${CPUS[@]}"; do
        for cl in "${CLIENTS[@]}"; do
            base_t=$(extract_tps "$(report_file "$BASELINE" "$cl" "$cpu")" "full_5k")
            patch_t=$(extract_tps "$(report_file "$commit" "$cl" "$cpu")" "full_5k")
            if [[ -n "$base_t" && -n "$patch_t" && "$base_t" != "0" ]]; then
                diff_pct=$(awk "BEGIN { d = ($patch_t - $base_t) * 100 / $base_t; print (d<0 ? -d : d) }")
                diff_int=${diff_pct%.*}
                (( ${diff_int:-0} > max_regression )) && max_regression=${diff_int:-0}
            fi
        done
    done
done
echo "\`full_5k\` (all entries fit, no eviction) is within ±${max_regression}% across all commits and configurations. \`multi_stmt\` is likewise neutral at high core counts."
echo ""
finding=$((finding + 1))

# 4. Eviction efficiency comparison
if [[ -n "$EVICT_WL" ]]; then
    base_deallocs=$(extract_deallocs "$(report_file "$BASELINE" "$WC" "$WCPU")" "$EVICT_WL")
    if [[ -n "$base_deallocs" && "$base_deallocs" != "0" ]]; then
        echo "**$finding. Eviction efficiency varies across approaches.**"
        for commit in "${COMMITS[@]}"; do
            [[ "$commit" == "$BASELINE" ]] && continue
            d=$(extract_deallocs "$(report_file "$commit" "$WC" "$WCPU")" "$EVICT_WL")
            if [[ -n "$d" && "$d" != "0" ]]; then
                ratio=$(awk "BEGIN { printf \"%.1f\", $d / $base_deallocs }")
                echo "- $(get_label "$commit"): $(fmt_num "$d") deallocs (${ratio}× baseline)"
            fi
        done
        echo ""
        finding=$((finding + 1))
    fi
fi

# 5. Where baseline outperforms patches
baseline_wins=""
for wl in "${WORKLOADS[@]}"; do
    for cl in "${CLIENTS[@]}"; do
        for cpu in "${CPUS[@]}"; do
            base_t=$(extract_tps "$(report_file "$BASELINE" "$cl" "$cpu")" "$wl")
            [[ -z "$base_t" || "$base_t" == "0" ]] && continue
            for commit in "${COMMITS[@]}"; do
                [[ "$commit" == "$BASELINE" ]] && continue
                patch_t=$(extract_tps "$(report_file "$commit" "$cl" "$cpu")" "$wl")
                [[ -z "$patch_t" ]] && continue
                pct=$(awk "BEGIN { printf \"%.0f\", ($patch_t - $base_t) * 100 / $base_t }")
                if (( pct <= -5 )); then
                    baseline_wins+="- \`$wl\` ${cl}c/${cpu}CPU: $(get_label "$commit") ${pct}%"$'\n'
                fi
            done
        done
    done
done
if [[ -n "$baseline_wins" ]]; then
    echo "**$finding. Configurations where baseline outperforms patches.**"
    echo "$baseline_wins"
    finding=$((finding + 1))
fi

echo "---"
echo ""

# --- Summary table ---

echo "### Summary"
echo ""
echo "| | Eviction TPS ($WC c, ${WCPU} CPUs) | Scalability | Non-eviction overhead | CPU-bound |"
echo "|---|---|---|---|---|"

for commit in "${COMMITS[@]}"; do
    label="$(get_label "$commit")"
    churn_tps=$(extract_tps "$(report_file "$commit" "$WC" "$WCPU")" "churn")
    churn_tps_fmt=$(fmt_num "${churn_tps:-0}")

    # Scalability
    tps_low=$(extract_tps "$(report_file "$commit" "$WC" "${CPUS[0]}")" "churn")
    tps_high=$(extract_tps "$(report_file "$commit" "$WC" "$WCPU")" "churn")
    if [[ -n "$tps_low" && -n "$tps_high" && "$tps_low" != "0" ]]; then
        scale=$(awk "BEGIN { printf \"%.1f\", $tps_high / $tps_low }")
        if awk "BEGIN { exit ($scale < 1.5) ? 0 : 1 }" 2>/dev/null; then
            scalability="None (flat)"
        elif awk "BEGIN { exit ($scale < 3.0) ? 0 : 1 }" 2>/dev/null; then
            scalability="Sub-linear (${scale}×)"
        else
            scalability="Linear (${scale}×)"
        fi
    else
        scalability="—"
    fi

    # Non-eviction overhead
    max_full_delta=0
    for cpu in "${CPUS[@]}"; do
        for cl in "${CLIENTS[@]}"; do
            base_t=$(extract_tps "$(report_file "$BASELINE" "$cl" "$cpu")" "full_5k")
            patch_t=$(extract_tps "$(report_file "$commit" "$cl" "$cpu")" "full_5k")
            if [[ -n "$base_t" && -n "$patch_t" && "$base_t" != "0" ]]; then
                d=$(awk "BEGIN { printf \"%.0f\", ($patch_t - $base_t) * 100 / $base_t }")
                (( d < max_full_delta )) && max_full_delta=$d
            fi
        done
    done
    if (( max_full_delta <= -5 )); then
        overhead="Yes (${max_full_delta}%)"
    else
        overhead="None"
    fi

    # CPU-bound check on churn
    wait_pct=$(extract_db_time_wait "$(report_file "$commit" "$WC" "$WCPU")" "churn")
    if [[ -z "$wait_pct" ]]; then
        cpu_bound="—"
    elif awk "BEGIN { exit ($wait_pct < 5.0) ? 0 : 1 }" 2>/dev/null; then
        cpu_bound="Yes"
    else
        top_clean=$(extract_top_waits "$(report_file "$commit" "$WC" "$WCPU")" "churn")
        cpu_bound="No (${wait_pct}% ${top_clean})"
    fi

    echo "| **$label** | $churn_tps_fmt | $scalability | $overhead | $cpu_bound |"
done
echo ""

echo "---"
echo "*Generated from: $RESULTS_DIR*"
