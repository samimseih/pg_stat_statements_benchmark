#!/bin/bash
# bench.sh - pg_stat_statements benchmark
#
# Usage:
#   ./bench.sh [options]
#
# Options:
#   -d DURATION    Seconds per workload (default: 30)
#   -c CLIENTS     pgbench clients (default: 64)
#   -j JOBS        pgbench jobs (default: 16)
#   -w WORKLOADS   Comma-separated: select1,churn,multi_stmt,full_5k,full_10k,zipf_5k (default: all)
#   -M PROTOCOL    pgbench protocol: simple|extended|prepared (default: simple)
#   -S SLEEP_MS    Add \sleep of this many ms after each iteration (default: 0 = none)
#   -C CPUS        Number of online CPUs (sets cores via sysfs, restores on exit)
#   -o OUTDIR      Output directory (default: $BENCH_RESULTS_DIR/<timestamp>)
#   -p PORT        PostgreSQL port (default: 5432)
#   -n             Dry-run: print commands and workload files without executing
#   -h             Show this help
#
# Examples:
#   ./bench.sh -d 60 -c 128 -w churn
#   ./bench.sh -d 120 -c 64 -C 8 -w select1,churn
#   ./bench.sh -d 30 -w all -M prepared
#   ./bench.sh -n -d 60 -c 128 -w churn    # dry-run

set -e

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/bench_config.sh"

DURATION=30
CLIENTS=64
JOBS=16
WORKLOADS="select1,churn,multi_stmt"
PROTOCOL="simple"
SLEEP_MS=0
CPUS=""
OUTDIR=""
DRY_RUN=0
PORT=5432
POLL_INTERVAL=5
DB="benchmark"
USER="${PGUSER:-postgres}"

usage() { sed -n '3,/^$/s/^# //p' "$0"; exit 0; }

while getopts ":d:c:j:w:M:S:C:o:p:nh" opt; do
    case $opt in
        d) DURATION=$OPTARG ;;
        c) CLIENTS=$OPTARG ;;
        j) JOBS=$OPTARG ;;
        w) WORKLOADS=$OPTARG ;;
        M) PROTOCOL=$OPTARG ;;
        S) SLEEP_MS=$OPTARG ;;
        C) CPUS=$OPTARG ;;
        o) OUTDIR=$OPTARG ;;
        p) PORT=$OPTARG ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        :) echo "Error: -$OPTARG requires an argument" >&2; usage ;;
        *) echo "Error: unknown option -$OPTARG" >&2; usage ;;
    esac
done

export PGHOST="${PGHOST:-/tmp}"
export PGPORT="$PORT"

# Auto-detect psql/pgbench from the running server
if ! command -v psql >/dev/null 2>&1; then
    _pg_pid=$(head -1 "$PGHOST/.s.PGSQL.$PORT.lock" 2>/dev/null)
    if [[ -n "$_pg_pid" ]]; then
        _pg_bin=$(dirname "$(ps -o args= -p $_pg_pid 2>/dev/null | awk '{print $1}')")
        [[ -n "$_pg_bin" && -x "$_pg_bin/psql" ]] && export PATH="$_pg_bin:$PATH"
    fi
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "Error: psql not found in PATH" >&2
    echo "  Either add PostgreSQL bin directory to PATH or start a server on port $PORT" >&2
    exit 1
fi

if ! command -v pgbench >/dev/null 2>&1; then
    echo "Error: pgbench not found in PATH" >&2
    exit 1
fi

[[ "$WORKLOADS" == "all" ]] && WORKLOADS="select1,churn,multi_stmt,full_5k,full_10k,zipf_5k"
IFS=',' read -ra WL_ARRAY <<< "$WORKLOADS"

# --- Dry-run mode ---

if (( DRY_RUN )); then
    echo "=== Dry-run: pg_stat_statements benchmark ==="
    echo ""
    echo "Configuration:"
    echo "  Duration:  ${DURATION}s"
    echo "  Clients:   $CLIENTS"
    echo "  Jobs:      $JOBS"
    echo "  Protocol:  $PROTOCOL"
    echo "  Port:      $PORT"
    echo "  Workloads: ${WL_ARRAY[*]}"
    [[ -n "$CPUS" ]] && echo "  CPUs:      $CPUS (will disable others via sysfs)"
    echo ""

    if [[ -n "$CPUS" ]]; then
        echo "--- CPU setup ---"
        if [[ "$(uname)" == "Darwin" ]]; then
            echo "  (CPU hotplug not supported on macOS — will be skipped)"
        else
            echo "  for i in \$(seq $CPUS \$((total_cpus - 1))); do"
            echo "    echo 0 | sudo tee /sys/devices/system/cpu/cpu\${i}/online"
            echo "  done"
        fi
        echo ""
    fi

    echo "--- Server setup ---"
    echo "  psql -c \"CREATE DATABASE $DB;\""
    echo "  psql -d $DB -c \"CREATE EXTENSION IF NOT EXISTS pg_stat_statements;\""
    echo ""

    for wl in "${WL_ARRAY[@]}"; do
        local_sql="$SCRIPT_DIR/sql/bench_${wl}.sql"
        echo "--- Workload: $wl ---"
        echo ""
        echo "  psql -d $DB -c \"SELECT pg_stat_statements_reset();\""
        echo ""
        echo "  pgbench -U $USER -d $DB -f bench_${wl}.sql \\"
        echo "    -c $CLIENTS -j $JOBS -T $DURATION -P $POLL_INTERVAL -M $PROTOCOL"
        echo ""
        if [[ -f "$local_sql" ]]; then
            echo "  -- bench_${wl}.sql:"
            sed 's/^/  /' "$local_sql"
        fi
        echo ""
        echo "  -- polling query (every ${POLL_INTERVAL}s while pgbench runs):"
        echo "  SELECT count(*),"
        echo "         count(*) FILTER (WHERE query LIKE '%hot%') AS hot,"
        echo "         count(*) FILTER (WHERE query LIKE '%slow_churn%'),
                       count(*) FILTER (WHERE query NOT LIKE '%hot%' AND query NOT LIKE '%slow_churn%' AND query NOT LIKE '%pg_stat%' AND query NOT LIKE '%marker%' AND query IS NOT NULL),
                       (SELECT min(extract(epoch from now() - stats_since))::int FROM pg_stat_statements WHERE query LIKE '%slow_churn%'),
                       (SELECT max(extract(epoch from now() - stats_since))::int FROM pg_stat_statements WHERE query LIKE '%slow_churn%') AS cold"
        echo "  FROM pg_stat_statements;"
        echo ""
        echo "  SELECT coalesce(wait_event_type || ':' || wait_event, 'CPU')"
        echo "  FROM pg_stat_activity"
        echo "  WHERE state = 'active' AND wait_event IS NOT NULL;"
        echo ""
    done

    echo "--- Final stats per workload ---"
    echo "  SELECT count(*), sum(calls) ... FROM pg_stat_statements;"
    echo "  SELECT dealloc FROM pg_stat_statements_info;"
    echo ""
    exit 0
fi

# --- Live mode ---

OUTDIR="${OUTDIR:-$BENCH_RESULTS_DIR/pgss_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/report.txt"

# --- CPU management ---

cpu_total() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sysctl -n hw.ncpu
    else
        nproc --all
    fi
}

cpu_set() {
    local target=$1
    local total=$(cpu_total)
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "WARNING: CPU hotplug not supported on macOS, ignoring -C $target" >&2
        return
    fi
    if (( target < 1 || target > total )); then
        echo "Error: CPUs must be between 1 and $total" >&2
        exit 1
    fi
    echo "Setting online CPUs to $target / $total"
    for ((i = 1; i < total; i++)); do
        local state=$( (( i < target )) && echo 1 || echo 0 )
        echo "$state" | sudo tee "/sys/devices/system/cpu/cpu${i}/online" >/dev/null
    done
}

cpu_restore() {
    if [[ "$(uname)" == "Darwin" ]]; then
        return
    fi
    local total=$(cpu_total)
    echo "Restoring all $total CPUs online"
    for ((i = 1; i < total; i++)); do
        echo 1 | sudo tee "/sys/devices/system/cpu/cpu${i}/online" >/dev/null 2>&1 || true
    done
}

if [[ -n "$CPUS" ]]; then
    cpu_set "$CPUS"
    trap cpu_restore EXIT
fi

# --- Setup ---

if ! psql -U $USER -d postgres -Xc "SELECT 1" >/dev/null 2>&1; then
    echo "Error: cannot connect to PostgreSQL on port $PORT" >&2
    echo "  Host: $PGHOST" >&2
    echo "  User: $USER" >&2
    echo "  Start a server first, or use switch_build.sh to create one." >&2
    exit 1
fi

# Ensure max_connections is sufficient for requested clients
CURRENT_MAX_CONN=$(psql -U $USER -d postgres -XAtc "SHOW max_connections;" 2>/dev/null)
NEEDED_CONN=$((CLIENTS + 10))
if [[ -n "$CURRENT_MAX_CONN" ]] && (( NEEDED_CONN > CURRENT_MAX_CONN )); then
    echo "Raising max_connections from $CURRENT_MAX_CONN to $NEEDED_CONN (restart required)..."
    _pgdata=$(psql -U $USER -d postgres -XAtc "SHOW data_directory;" 2>/dev/null)
    _pgbin=$(dirname "$(command -v psql)")
    psql -U $USER -d postgres -Xc "ALTER SYSTEM SET max_connections = $NEEDED_CONN;" >/dev/null
    "$_pgbin/pg_ctl" -D "$_pgdata" -w restart -l "$_pgdata/logfile" >/dev/null 2>&1
    echo "Server restarted with max_connections=$NEEDED_CONN"
fi

if ! psql -U $USER -d postgres -Xc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1; then
    echo "Creating database '$DB'..."
    if ! psql -U $USER -d postgres -Xc "CREATE DATABASE $DB;"; then
        echo "Error: failed to create database '$DB'" >&2
        exit 1
    fi
fi

if ! psql -U $USER -d $DB -Xc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"; then
    echo "Error: failed to create pg_stat_statements extension" >&2
    echo "  Is pg_stat_statements in shared_preload_libraries?" >&2
    exit 1
fi


# --- Header ---

if [[ -f "$REPORT" ]]; then
    echo "" | tee -a "$REPORT"
else
    {
        echo "=== pg_stat_statements benchmark ==="
        echo "Date: $(date)"
        sleep_info=""
        (( SLEEP_MS > 0 )) && sleep_info=", Sleep: ${SLEEP_MS}ms"
        echo "Duration: ${DURATION}s, Clients: $CLIENTS, Jobs: $JOBS, Protocol: $PROTOCOL, Port: $PORT${sleep_info}"
        echo "Workloads: ${WL_ARRAY[*]}"
        echo "CPUs online: $(cpu_total)"
        if [[ "$(uname)" == "Darwin" ]]; then
            echo "Machine: $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 ))GB RAM"
        else
            echo "Machine: $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2}'), $(free -h | awk '/Mem:/{print $2}') RAM"
        fi
        echo ""
    } | tee "$REPORT"
fi

# --- Per-workload runner ---

run_workload() {
    local name=$1
    local sql_file="$SCRIPT_DIR/sql/bench_${name}.sql"

    if [[ ! -f "$sql_file" ]]; then
        echo "WARNING: $sql_file not found, skipping" | tee -a "$REPORT"
        return
    fi

    # Append think-time sleep if requested
    if (( SLEEP_MS > 0 )); then
        local tmp_sql="$OUTDIR/${name}_bench.sql"
        cp "$sql_file" "$tmp_sql"
        echo "\\sleep $SLEEP_MS ms" >> "$tmp_sql"
        sql_file="$tmp_sql"
    fi

    psql -U $USER -d $DB -Xc "SELECT pg_stat_statements_reset();" >/dev/null 2>&1

    local cpu_info=""
    [[ -n "$CPUS" ]] && cpu_info=" cpus=$CPUS"
    echo "--- $name [clients=$CLIENTS jobs=$JOBS proto=$PROTOCOL duration=${DURATION}s${cpu_info}] ---" | tee -a "$REPORT"
    local cmd="pgbench -U $USER -d $DB -f $sql_file -c $CLIENTS -j $JOBS -T $DURATION -P $POLL_INTERVAL -M $PROTOCOL"
    echo "  $cmd" | tee -a "$REPORT"

    # Run pgbench in background
    $cmd > "$OUTDIR/${name}_pgbench.txt" 2>&1 &
    local PID=$!

    # Background: sample wait events every 1 second
    local WAIT_LOG="$OUTDIR/${name}_waits.log"
    local WAIT_INTERVAL="$OUTDIR/${name}_waits_interval.log"
    > "$WAIT_LOG"
    > "$WAIT_INTERVAL"
    (
        while kill -0 $PID 2>/dev/null; do
            psql -U $USER -d $DB -XAtF"|" -c "
                SELECT coalesce(wait_event_type || ':' || wait_event, 'CPU')
                FROM pg_stat_activity
                WHERE state = 'active' AND pid != pg_backend_pid()
                  AND (wait_event_type IS NULL OR wait_event_type != 'Client');" 2>/dev/null | tee -a "$WAIT_LOG" >> "$WAIT_INTERVAL"
            echo "---" >> "$WAIT_LOG"
            sleep 1
        done
    ) &
    local WAIT_PID=$!

    # Background: sample OS resource usage every POLL_INTERVAL seconds
    local OS_LOG="$OUTDIR/${name}_os.log"
    > "$OS_LOG"
    (
        while kill -0 $PID 2>/dev/null; do
            ts=$(date +%s)
            if [[ "$(uname)" == "Darwin" ]]; then
                # CPU: parse top -l 2 (second sample is the 1s delta)
                read cpu_usr cpu_sys cpu_idle <<< $(top -l 2 -n 0 -s 1 2>/dev/null | awk '/^CPU usage:/{usr=$3; sys=$5; idle=$7} END{gsub(/%/,"",usr); gsub(/%/,"",sys); gsub(/%/,"",idle); printf "%.0f %.0f %.0f", usr, sys, idle}')
                # Memory: parse PhysMem line from top
                read mem_used_mb mem_total_mb <<< $(top -l 1 -n 0 -s 0 2>/dev/null | awk '/^PhysMem:/{
                    used=$2; unused=$6
                    gsub(/[^0-9.]/,"",used); gsub(/[^0-9.]/,"",unused)
                    # Detect G vs M in original string
                    if ($2 ~ /G/) used=used*1024
                    if ($6 ~ /G/) unused=unused*1024
                    printf "%.0f %.0f", used, used+unused
                }')
                # RSS of postgres processes
                pg_rss_mb=$(ps -o rss= -p $(pgrep -x postgres 2>/dev/null) 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')
            else
                # CPU: idle percentage from /proc/stat (delta over 1s)
                read cpu1_user cpu1_nice cpu1_sys cpu1_idle cpu1_rest <<< $(awk '/^cpu / {print $2, $3, $4, $5, $6+$7+$8+$9+$10}' /proc/stat)
                sleep 1
                read cpu2_user cpu2_nice cpu2_sys cpu2_idle cpu2_rest <<< $(awk '/^cpu / {print $2, $3, $4, $5, $6+$7+$8+$9+$10}' /proc/stat)
                total=$(( (cpu2_user - cpu1_user) + (cpu2_nice - cpu1_nice) + (cpu2_sys - cpu1_sys) + (cpu2_idle - cpu1_idle) + (cpu2_rest - cpu1_rest) ))
                if (( total > 0 )); then
                    cpu_usr=$(( (cpu2_user - cpu1_user) * 100 / total ))
                    cpu_sys=$(( (cpu2_sys - cpu1_sys) * 100 / total ))
                    cpu_idle=$(( (cpu2_idle - cpu1_idle) * 100 / total ))
                else
                    cpu_usr=0; cpu_sys=0; cpu_idle=100
                fi
                # Memory: from /proc/meminfo
                read mem_total mem_avail <<< $(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
                mem_used_mb=$(( (mem_total - mem_avail) / 1024 ))
                mem_total_mb=$(( mem_total / 1024 ))
                # RSS of postgres processes
                pg_rss_mb=$(ps -C postgres -o rss= 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')
            fi
            echo "${ts} cpu_usr=${cpu_usr:-0}% cpu_sys=${cpu_sys:-0}% cpu_idle=${cpu_idle:-100}% mem_used=${mem_used_mb:-0}MB/${mem_total_mb:-0}MB pg_rss=${pg_rss_mb:-0}MB" >> "$OS_LOG"
            sleep $((POLL_INTERVAL - 1))
        done
    ) &
    local OS_PID=$!

    # Poll entry counts + TPS every POLL_INTERVAL
    local start_time=$(date +%s)
    while kill -0 $PID 2>/dev/null; do
        sleep $POLL_INTERVAL
        local elapsed=$(( $(date +%s) - start_time ))

        local waits=$(sort "$WAIT_INTERVAL" 2>/dev/null | grep -v "^$" | uniq -c | sort -rn | head -3 | awk '{printf "%s(%d) ", $2, $1}')
        > "$WAIT_INTERVAL"

        local progress_tps=$(grep '^progress:' "$OUTDIR/${name}_pgbench.txt" 2>/dev/null | tail -1 | awk '{print $4}')

        local dealloc=$(psql -U $USER -d $DB -XAtc "
            SELECT dealloc FROM pg_stat_statements_info;" 2>/dev/null)
        local num_entries=$(psql -U $USER -d $DB -XAtc "
            SELECT entry_count FROM pg_stat_kind_info
            WHERE name = 'pg_stat_statements';" 2>/dev/null)

        # Entry churn stats (all workloads)
        local churn_stats=$(psql -U $USER -d $DB -XAtF"|" -c "
            SELECT min(calls), max(calls),
                   round(avg(calls))::int, coalesce(round(stddev(calls))::int, 0),
                   extract(epoch from min(now() - stats_since))::int,
                   extract(epoch from max(now() - stats_since))::int,
                   extract(epoch from avg(now() - stats_since))::int,
                   coalesce(round(stddev(extract(epoch from now() - stats_since)))::int, 0),
                   left(md5(string_agg(queryid::text || userid::text || dbid::text || toplevel::text, ',' ORDER BY queryid)), 8)
            FROM pg_stat_statements
            WHERE query NOT LIKE '%pg_stat%' AND query IS NOT NULL;" 2>/dev/null)
        local min_calls=$(echo "$churn_stats" | cut -d'|' -f1)
        local max_calls=$(echo "$churn_stats" | cut -d'|' -f2)
        local avg_calls=$(echo "$churn_stats" | cut -d'|' -f3)
        local stddev_calls=$(echo "$churn_stats" | cut -d'|' -f4)
        local youngest=$(echo "$churn_stats" | cut -d'|' -f5)
        local oldest=$(echo "$churn_stats" | cut -d'|' -f6)
        local avg_age=$(echo "$churn_stats" | cut -d'|' -f7)
        local stddev_age=$(echo "$churn_stats" | cut -d'|' -f8)
        local fingerprint=$(echo "$churn_stats" | cut -d'|' -f9)

        if [[ "$name" == zipf_* ]]; then
            local stats=$(psql -U $USER -d $DB -XAtF"|" -c "
                SELECT count(*),
                       count(*) FILTER (WHERE query LIKE '%t1_%'),
                       count(*) FILTER (WHERE query LIKE '%t2_%'),
                       count(*) FILTER (WHERE query LIKE '%t3_%'),
                       count(*) FILTER (WHERE query LIKE '%t4_%')
                FROM pg_stat_statements WHERE query LIKE 'WITH%';" 2>/dev/null)
            local entries=$(echo "$stats" | cut -d'|' -f1)
            local t1=$(echo "$stats" | cut -d'|' -f2)
            local t2=$(echo "$stats" | cut -d'|' -f3)
            local t3=$(echo "$stats" | cut -d'|' -f4)
            local t4=$(echo "$stats" | cut -d'|' -f5)
            if [[ -n "$entries" ]]; then
                    printf "  t=%-4s entries=%-5s t1=%-4s t2=%-4s t3=%-4s t4=%-5s tps=%-8s num_entries=%-5s dealloc=%-8s age=[%s..%s avg=%s sd=%s] calls=[%s..%s avg=%s sd=%s] fp=%s waits=[%s]\n" \
                        "${elapsed}s" "$entries" "$t1" "$t2" "$t3" "$t4" "${progress_tps:-...}" "${num_entries:-?}" "${dealloc:-?}" "${youngest:-?}s" "${oldest:-?}s" "${avg_age:-?}s" "${stddev_age:-?}s" "${min_calls:-?}" "${max_calls:-?}" "${avg_calls:-?}" "${stddev_calls:-?}" "${fingerprint:-?}" "${waits:-none}" | tee -a "$REPORT"
            fi
        elif [[ "$name" == *churn* ]]; then
            local stats=$(psql -U $USER -d $DB -XAtF"|" -c "
                SELECT count(*),
                       count(*) FILTER (WHERE query LIKE '%hot%'),
                       count(*) FILTER (WHERE query LIKE '%slow_churn%'),
                       count(*) FILTER (WHERE query NOT LIKE '%hot%' AND query NOT LIKE '%slow_churn%' AND query NOT LIKE '%pg_stat%' AND query NOT LIKE '%marker%' AND query IS NOT NULL),
                       (SELECT min(extract(epoch from now() - stats_since))::int FROM pg_stat_statements WHERE query LIKE '%slow_churn%'),
                       (SELECT max(extract(epoch from now() - stats_since))::int FROM pg_stat_statements WHERE query LIKE '%slow_churn%')
                FROM pg_stat_statements;" 2>/dev/null)
            local entries=$(echo "$stats" | cut -d'|' -f1)
            local hot=$(echo "$stats" | cut -d'|' -f2)
            local rare=$(echo "$stats" | cut -d"|" -f3)
            local cold=$(echo "$stats" | cut -d"|" -f4)
            local rare_youngest=$(echo "$stats" | cut -d"|" -f5)
            local rare_oldest=$(echo "$stats" | cut -d"|" -f6)
            if [[ -n "$entries" ]]; then
                    printf "  t=%-4s entries=%-5s hot=%-5s cold=%-3s rare=%-3s(age %s..%ss) tps=%-8s num_entries=%-5s dealloc=%-8s age=[%s..%s avg=%s sd=%s] calls=[%s..%s avg=%s sd=%s] fp=%s waits=[%s]\n" \
                        "${elapsed}s" "$entries" "$hot" "$cold" "$rare" "${rare_youngest:-?}" "${rare_oldest:-?}" "${progress_tps:-...}" "${num_entries:-?}" "${dealloc:-?}" "${youngest:-?}s" "${oldest:-?}s" "${avg_age:-?}s" "${stddev_age:-?}s" "${min_calls:-?}" "${max_calls:-?}" "${avg_calls:-?}" "${stddev_calls:-?}" "${fingerprint:-?}" "${waits:-none}" | tee -a "$REPORT"
            fi
        else
            local stats=$(psql -U $USER -d $DB -XAtF"|" -c "
                SELECT count(*) FROM pg_stat_statements;" 2>/dev/null)
            local entries="$stats"
            if [[ -n "$entries" ]]; then
                    printf "  t=%-4s entries=%-5s tps=%-8s num_entries=%-5s dealloc=%-8s age=[%s..%s avg=%s sd=%s] calls=[%s..%s avg=%s sd=%s] fp=%s waits=[%s]\n" \
                        "${elapsed}s" "$entries" "${progress_tps:-...}" "${num_entries:-?}" "${dealloc:-?}" "${youngest:-?}s" "${oldest:-?}s" "${avg_age:-?}s" "${stddev_age:-?}s" "${min_calls:-?}" "${max_calls:-?}" "${avg_calls:-?}" "${stddev_calls:-?}" "${fingerprint:-?}" "${waits:-none}" | tee -a "$REPORT"
            fi
        fi


    done

    # Clean up samplers
    kill $WAIT_PID 2>/dev/null || true
    kill $OS_PID 2>/dev/null || true
    wait $WAIT_PID 2>/dev/null || true
    wait $OS_PID 2>/dev/null || true
    wait $PID 2>/dev/null
    local pgbench_rc=$?
    if [[ $pgbench_rc -ne 0 ]]; then
        echo "  pgbench failed (exit $pgbench_rc):" | tee -a "$REPORT"
        sed 's/^/    /' "$OUTDIR/${name}_pgbench.txt" | tail -20 | tee -a "$REPORT"
    fi

    # Compute wait event summary from cumulative log
    local total_samples=$(grep -cE "^-+$" "$WAIT_LOG" 2>/dev/null; true)
    local total_active=$(grep -cvE "^$|^-+$" "$WAIT_LOG" 2>/dev/null; true)
    local on_cpu=$(grep -c "^CPU$" "$WAIT_LOG" 2>/dev/null; true)
    : "${total_samples:=0}" "${total_active:=0}" "${on_cpu:=0}"
    local total_waits=$((total_active - on_cpu))
    local total_possible=$((total_samples * CLIENTS))
    if (( total_possible > 0 )); then
        local idle_pct=$(echo "scale=1; ($total_possible - $total_active) * 100 / $total_possible" | bc 2>/dev/null)
    else
        local idle_pct="0"
    fi
    if (( total_active > 0 )); then
        local cpu_pct=$(echo "scale=1; $on_cpu * 100 / $total_active" | bc 2>/dev/null)
        local top_waits=$(grep -vE "^$|^-+$|^CPU$" "$WAIT_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | \
            awk -v ta="$total_active" '{pct=($1*100)/ta; printf "%s=%.1f%% ", $2, pct}')
        local db_pct=$(echo "scale=1; $total_active * 100 / $total_possible" | bc 2>/dev/null)
        echo "  db_time: idle=${idle_pct}% db=${db_pct}% (CPU=${cpu_pct}% ${top_waits}) (${total_active} active samples over ${total_samples}s, ${CLIENTS} clients)" | tee -a "$REPORT"
    else
        echo "  db_time: idle=100% (no active backends sampled over ${total_samples}s, ${CLIENTS} clients)" | tee -a "$REPORT"
    fi

    # OS resource summary (POSIX awk compatible — no GNU match() capture groups)
    if [[ -s "$OS_LOG" ]]; then
        local os_summary=$(awk '
            /cpu_usr/ {
                n++
                split($0, fields, " ")
                for (i in fields) {
                    f = fields[i]
                    if (f ~ /^cpu_usr=/) { sub(/^cpu_usr=/, "", f); sub(/%$/, "", f); usr_sum += f }
                    if (f ~ /^cpu_sys=/) { sub(/^cpu_sys=/, "", f); sub(/%$/, "", f); sys_sum += f }
                    if (f ~ /^mem_used=/) { sub(/^mem_used=/, "", f); sub(/MB.*/, "", f); mem_sum += f }
                    if (f ~ /^pg_rss=/) { sub(/^pg_rss=/, "", f); sub(/MB$/, "", f); rss_sum += f }
                }
            }
            END {
                if (n > 0) printf "cpu_usr=%.0f%% cpu_sys=%.0f%% mem_used=%.0fMB pg_rss=%.0fMB",
                    usr_sum/n, sys_sum/n, mem_sum/n, rss_sum/n
            }
        ' "$OS_LOG")
        if [[ -n "$os_summary" ]]; then
            echo "  os_avg: $os_summary" | tee -a "$REPORT"
        fi
    fi

    # Wait for stats to flush
    sleep 2

    # Final results
    local tps=$(grep '^tps = ' "$OUTDIR/${name}_pgbench.txt" | awk '{print $3}')
    local deallocs=$(psql -U $USER -d $DB -XAtF"|" -c "SELECT dealloc FROM pg_stat_statements_info;" 2>/dev/null)
    local histogram=$(psql -U $USER -d $DB -XAt -c "
        SELECT string_agg(bucket || ':' || cnt, ' ' ORDER BY bucket) FROM (
            SELECT CASE
                WHEN calls = 1 THEN '1'
                WHEN calls <= 5 THEN '2-5'
                WHEN calls <= 20 THEN '6-20'
                WHEN calls <= 100 THEN '21-100'
                WHEN calls <= 1000 THEN '101-1k'
                ELSE '>1k'
            END as bucket, count(*) as cnt
            FROM pg_stat_statements WHERE query LIKE 'WITH%'
            GROUP BY 1
        ) t;" 2>/dev/null)

    # Save postgres log for this workload
    local pgdata=$(psql -U $USER -d $DB -XAtc "SHOW data_directory;" 2>/dev/null)
    if [[ -n "$pgdata" ]]; then
        for logfile in "$pgdata/logfile" "$pgdata"/log/$(ls -t "$pgdata"/log/ 2>/dev/null | head -1); do
            if [[ -f "$logfile" ]]; then
                cp "$logfile" "$OUTDIR/${name}_pglog.txt" 2>/dev/null
                break
            fi
        done
    fi

    if [[ "$name" == zipf_* ]]; then
        local final=$(psql -U $USER -d $DB -XAtF"|" -c "
            SELECT count(*),
                   count(*) FILTER (WHERE query LIKE '%t1_%'),
                   count(*) FILTER (WHERE query LIKE '%t2_%'),
                   count(*) FILTER (WHERE query LIKE '%t3_%'),
                   count(*) FILTER (WHERE query LIKE '%t4_%'),
                   coalesce(sum(calls) FILTER (WHERE query LIKE '%t1_%'), 0),
                   coalesce(sum(calls) FILTER (WHERE query LIKE '%t2_%'), 0),
                   coalesce(sum(calls) FILTER (WHERE query LIKE '%t3_%'), 0),
                   coalesce(sum(calls) FILTER (WHERE query LIKE '%t4_%'), 0)
            FROM pg_stat_statements WHERE query LIKE 'WITH%';" 2>/dev/null)
        {
            echo "  TPS: ${tps:-N/A}"
            echo "  FINAL: entries=$(echo $final | cut -d'|' -f1) t1=$(echo $final | cut -d'|' -f2) t2=$(echo $final | cut -d'|' -f3) t3=$(echo $final | cut -d'|' -f4) t4=$(echo $final | cut -d'|' -f5) t1_calls=$(echo $final | cut -d'|' -f6) t2_calls=$(echo $final | cut -d'|' -f7) t3_calls=$(echo $final | cut -d'|' -f8) t4_calls=$(echo $final | cut -d'|' -f9)"
            echo "  deallocs: ${deallocs:-0}"
            echo "  histogram: ${histogram:-N/A}"
            echo ""
        } | tee -a "$REPORT"
    elif [[ "$name" == *churn* ]]; then
        local final=$(psql -U $USER -d $DB -XAtF"|" -c "
            SELECT count(*),
                   count(*) FILTER (WHERE query LIKE '%hot%'),
                   count(*) FILTER (WHERE query LIKE '%slow_churn%'),
                       count(*) FILTER (WHERE query NOT LIKE '%hot%' AND query NOT LIKE '%slow_churn%' AND query NOT LIKE '%pg_stat%' AND query NOT LIKE '%marker%' AND query IS NOT NULL),
                       (SELECT min(extract(epoch from now() - stats_since))::int FROM pg_stat_statements WHERE query LIKE '%slow_churn%'),
                       (SELECT max(extract(epoch from now() - stats_since))::int FROM pg_stat_statements WHERE query LIKE '%slow_churn%'),
                   coalesce(sum(calls) FILTER (WHERE query LIKE '%hot%'), 0),
                   coalesce(sum(calls) FILTER (WHERE query NOT LIKE '%hot%' AND query NOT LIKE '%pg_stat%' AND query NOT LIKE '%marker%' AND query IS NOT NULL), 0)
            FROM pg_stat_statements;" 2>/dev/null)
        {
            echo "  TPS: ${tps:-N/A}"
            echo "  FINAL: entries=$(echo $final | cut -d"|" -f1) hot=$(echo $final | cut -d"|" -f2) rare=$(echo $final | cut -d"|" -f3) cold=$(echo $final | cut -d"|" -f4) rare_age=[$(echo $final | cut -d"|" -f5)..$(echo $final | cut -d"|" -f6)s] hot_calls=$(echo $final | cut -d"|" -f7) cold_calls=$(echo $final | cut -d"|" -f8)"
            echo "  deallocs: ${deallocs:-0}"
            echo "  histogram: ${histogram:-N/A}"
            echo ""
        } | tee -a "$REPORT"
    else
        local final=$(psql -U $USER -d $DB -XAtF"|" -c "
            SELECT count(*),
                   coalesce(sum(calls), 0)
            FROM pg_stat_statements WHERE query LIKE 'WITH%';" 2>/dev/null)
        {
            echo "  TPS: ${tps:-N/A}"
            echo "  FINAL: entries=$(echo $final | cut -d'|' -f1) calls=$(echo $final | cut -d'|' -f2)"
            echo "  deallocs: ${deallocs:-0}"
            echo "  histogram: ${histogram:-N/A}"
            echo ""
        } | tee -a "$REPORT"
    fi
}

# --- Run ---

for wl in "${WL_ARRAY[@]}"; do
    run_workload "$wl"
done

# --- Summary ---

{
    echo "=== TPS Summary ==="
    for wl in "${WL_ARRAY[@]}"; do
        tps=$(grep '^tps = ' "$OUTDIR/${wl}_pgbench.txt" 2>/dev/null | awk '{print $3}')
        printf "  %-15s %s\n" "$wl" "${tps:-N/A}"
    done
    echo ""
    echo "Results: $OUTDIR"
} | tee -a "$REPORT"
