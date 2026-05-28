#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENTS=${1:-128}
TXNS=${2:-100}
RATE=${3:-0}  # 0 = unlimited, otherwise TPS limit
LOG_DIR="$SCRIPT_DIR/results"

mkdir -p "$LOG_DIR"

echo "=== Eviction lifecycle test ==="
echo "Date: $(date)"
echo ""
echo "Build:"
echo "  Version: $(psql -Atc 'SELECT version()' 2>/dev/null)"
echo "  Build type: $(psql -Atc "SELECT setting FROM pg_settings WHERE name = 'debug_assertions'" 2>/dev/null | awk '{print ($1=="on") ? "debug (cassert)" : "release"}')"
echo ""
echo "Settings:"
echo "  pg_stat_statements.max: $(psql -Atc "SHOW pg_stat_statements.max" 2>/dev/null)"
echo "  pg_stat_statements.track: $(psql -Atc "SHOW pg_stat_statements.track" 2>/dev/null)"
echo "  shared_buffers: $(psql -Atc "SHOW shared_buffers" 2>/dev/null)"
echo ""
echo "pgbench:"
echo "  Clients: $CLIENTS"
echo "  Transactions/client: $TXNS"
echo "  Rate limit: $([ "$RATE" -gt 0 ] 2>/dev/null && echo "${RATE} TPS" || echo "unlimited")"
echo ""

# Reset state
psql -c "SELECT pg_stat_statements_reset()" >/dev/null 2>&1
psql -c "SELECT injection_points_detach('pgss-eviction-created')" >/dev/null 2>&1 || true
psql -c "SELECT injection_points_detach('pgss-eviction-decay')" >/dev/null 2>&1 || true
psql -c "SELECT injection_points_detach('pgss-eviction-evicted')" >/dev/null 2>&1 || true

# Single-backend test
echo "--- Single-backend test (plain SQL) ---"
psql -f "$SCRIPT_DIR/eviction_lifecycle.sql" 2> "$LOG_DIR/single_notices.log" >/dev/null
echo "Single-backend notices: $LOG_DIR/single_notices.log"
echo "  Entries created: $(grep -c 'eviction-created' "$LOG_DIR/single_notices.log" 2>/dev/null || echo 0)"
echo "  Evictions: $(grep -c 'eviction-evicted' "$LOG_DIR/single_notices.log" 2>/dev/null || echo 0)"
echo "  Decays with calls>0: $(grep 'eviction-decay' "$LOG_DIR/single_notices.log" | grep -v 'calls=0' | wc -l | tr -d ' ')"
echo "  Decay refcount (min/avg/max): $(grep 'eviction-decay' "$LOG_DIR/single_notices.log" | sed 's/.*refcount=\([0-9]*\).*/\1/' | awk 'BEGIN{min=999;max=0;s=0;n=0} {s+=$1;n++;if($1<min)min=$1;if($1>max)max=$1} END{if(n>0)printf "%d / %.1f / %d", min, s/n, max; else print "n/a"}')"
echo "  Decay refcount histogram:"
grep 'eviction-decay' "$LOG_DIR/single_notices.log" | sed 's/.*refcount=\([0-9]*\).*/\1/' | sort -n | uniq -c | awk 'NR==1{max=$1} {if($1>max)max=$1} {data[NR]=$0; cnt[NR]=$1; ref[NR]=$2} END{for(i=1;i<=NR;i++){bar=""; len=int(cnt[i]*40/max); for(j=0;j<len;j++)bar=bar"█"; printf "    refcount=%2d: %5d |%s\n", ref[i], cnt[i], bar}}'
echo "  Deallocations: $(psql -Atc "SELECT dealloc FROM pg_stat_statements_info" 2>/dev/null || echo 'n/a')"
echo ""

# Multi-backend test
echo "--- Multi-backend test (pgbench, $CLIENTS clients) ---"

# Lower log_min_messages so NOTICEs from all backends appear in server log
PGDATA="${PGDATA:-$(psql -Atc 'SHOW data_directory')}"
psql -c "ALTER SYSTEM SET log_min_messages = 'notice'" >/dev/null 2>&1
psql -c "SELECT pg_reload_conf()" >/dev/null 2>&1

# Force a new log file so we only capture our run
psql -c "SELECT pg_rotate_logfile()" >/dev/null 2>&1
sleep 1
LOGFILE=$(ls -t "$PGDATA"/log/*.log 2>/dev/null | head -1)

psql -f "$SCRIPT_DIR/eviction_setup.sql" >/dev/null 2>&1
RATE_FLAG=""
if [ "$RATE" -gt 0 ] 2>/dev/null; then
    RATE_FLAG="-R $RATE"
fi
pgbench -n -c "$CLIENTS" -t "$TXNS" $RATE_FLAG -f "$SCRIPT_DIR/eviction_pgbench.sql" > "$LOG_DIR/pgbench_output.log" 2>&1
psql -f "$SCRIPT_DIR/eviction_teardown.sql" >/dev/null 2>&1

# Restore default
psql -c "ALTER SYSTEM RESET log_min_messages" >/dev/null 2>&1
psql -c "SELECT pg_reload_conf()" >/dev/null 2>&1

if [ -n "$LOGFILE" ]; then
    grep "injection point pgss-eviction" "$LOGFILE" > "$LOG_DIR/server_notices.log" 2>/dev/null || true
    echo "Server log notices: $LOG_DIR/server_notices.log"
    echo "  Entries created: $(grep -c 'eviction-created' "$LOG_DIR/server_notices.log" 2>/dev/null || echo 0)"
    echo "  Decays: $(grep -c 'eviction-decay' "$LOG_DIR/server_notices.log" 2>/dev/null || echo 0)"
    echo "  Decay refcount (min/avg/max): $(grep 'eviction-decay' "$LOG_DIR/server_notices.log" | sed 's/.*refcount=\([0-9]*\).*/\1/' | awk 'BEGIN{min=999;max=0;s=0;n=0} {s+=$1;n++;if($1<min)min=$1;if($1>max)max=$1} END{if(n>0)printf "%d / %.1f / %d", min, s/n, max; else print "n/a"}')"
    echo "  Decay refcount histogram:"
    grep 'eviction-decay' "$LOG_DIR/server_notices.log" | sed 's/.*refcount=\([0-9]*\).*/\1/' | sort -n | uniq -c | awk 'NR==1{max=$1} {if($1>max)max=$1} {data[NR]=$0; cnt[NR]=$1; ref[NR]=$2} END{for(i=1;i<=NR;i++){bar=""; len=int(cnt[i]*40/max); for(j=0;j<len;j++)bar=bar"█"; printf "    refcount=%2d: %5d |%s\n", ref[i], cnt[i], bar}}'
    echo "  Evictions: $(grep -c 'eviction-evicted' "$LOG_DIR/server_notices.log" 2>/dev/null || echo 0)"
    echo "  Deallocations: $(psql -Atc "SELECT dealloc FROM pg_stat_statements_info" 2>/dev/null || echo 'n/a')"
else
    echo "WARNING: Could not find server log in $PGDATA/log/"
    echo "Check your logging_collector and log_directory settings."
fi

echo ""
echo "=== Done. Results in $LOG_DIR/ ==="
