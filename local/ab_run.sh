#!/usr/bin/env bash
# One run: a fresh cluster of <build>, a workload, then the result line.
# usage: ab_run.sh <build> <hc100m|hc100midle|hc100midlenp|hc1500|hc50k|hc80k100m|hc80k1m|sel> <clients> <seconds> <max>
# MINMAX_RESET_SECS=<n>: reset min/max of all entries every n s while measuring
# PROGRESS_SECS=<n>: pgbench progress interval while measuring (default 10)
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
BUILD=$1; MODE=$2; CL=$3; SECS=$4; MAX=$5
INST=$PGSS_WORK/$BUILD; OUT=$PGSS_WORK/ab-$BUILD-$MODE-c$CL; DATA=$OUT/data; PORT=${PGSS_PORT:-55473}
rm -rf $OUT; mkdir -p $OUT
export PATH=$INST/bin:$PATH PGPORT=$PORT PGHOST=/tmp PGDATABASE=postgres PGUSER=postgres
initdb -U postgres -D $DATA >/dev/null 2>&1
printf "port=$PORT\nunix_socket_directories='/tmp'\nlisten_addresses=''\nshared_preload_libraries='pg_stat_statements'\npg_stat_statements.max=$MAX\nmax_connections=600\n" >>$DATA/postgresql.conf
pg_ctl -D $DATA -l $OUT/server.log -w start >/dev/null
trap 'pg_ctl -D $DATA -m fast stop >/dev/null 2>&1' EXIT
psql -qXc 'CREATE EXTENSION pg_stat_statements'
( while sleep 2; do psql -AtXc "SELECT entry_count FROM pg_stat_kind_info WHERE name = 'pg_stat_statements'" 2>/dev/null; done ) > $OUT/entry_count.txt &
SAMP=$!
# Every 5 s: text file size, entries of the view, popular statements kept,
# entries without query text, memory of query texts in shared memory
( while sleep 5; do
    sz=$(stat -c %s $DATA/pg_stat_tmp/pgss_query_texts.stat 2>/dev/null || echo 0)
    v=$(PGOPTIONS='-c pg_stat_statements.track=none' psql -AtXF ' ' -c "SELECT count(*), count(*) FILTER (WHERE query LIKE 'WITH CTEPOP_%'), count(*) FILTER (WHERE query IS NULL) FROM pg_stat_statements" 2>/dev/null)
    # Memory of query texts, for builds keeping them in shared memory
    m=$(psql -AtXc "SELECT query_text_memory FROM pg_stat_statements_info" 2>/dev/null)
    echo "$sz $v ${m:-0} $(date +%s)"
  done ) > $OUT/samples5.txt &
SAMP2=$!
# Every 10 s: view entries by class and creation age (stats_since)
( while sleep 10; do
    PGOPTIONS='-c pg_stat_statements.track=none' psql -AtXF ' ' -c "
      SELECT extract(epoch FROM now())::int,
             CASE WHEN query LIKE 'WITH CTEPOP_%' THEN 'popular'
                  WHEN query LIKE 'WITH CTEUNPOP_%' THEN 'unpopular'
                  ELSE 'other' END,
             CASE WHEN age < interval '1 second' THEN '1:<1s'
                  WHEN age < interval '10 seconds' THEN '2:1-10s'
                  WHEN age < interval '1 minute' THEN '3:10s-1min'
                  WHEN age < interval '5 minutes' THEN '4:1-5min'
                  ELSE '5:>5min' END,
             count(*)
      FROM (SELECT query, clock_timestamp() - stats_since AS age
            FROM pg_stat_statements(true)) s
      GROUP BY 1, 2, 3" 2>/dev/null
  done ) > $OUT/age.txt &
SAMP3=$!
# With MINMAX_RESET_SECS, reset the min/max values of all entries every
# MINMAX_RESET_SECS seconds during the measured phase, as monitoring tools do
start_minmax_resets() {
  RESETS=
  [ -n "${MINMAX_RESET_SECS:-}" ] || return
  ( while sleep $MINMAX_RESET_SECS; do
      PGOPTIONS='-c pg_stat_statements.track=none' psql -AtXc "SELECT pg_stat_statements_reset(0, 0, 0, true)" >/dev/null 2>&1
      date +%s
    done ) > $OUT/minmax_resets.txt &
  RESETS=$!
}
if [ $MODE = sel ]; then
  pgbench -i -s 10 >/dev/null 2>&1
  pgbench -n -M prepared -c 32 -j 32 -T 15 -S >/dev/null 2>&1
  date +%s > $OUT/measured_since
  start_minmax_resets
  pgbench -n -M prepared -P ${PROGRESS_SECS:-10} -c $CL -j 32 -T $SECS -S >$OUT/pgbench.log 2>&1
else
  SQL=$REPO/pgbench_hot_cold_4000_1500.sql
  [ $MODE = hc100m ] && SQL=$REPO/pgbench_hot_cold_4000_100m.sql
  [ $MODE = hc50k ] && SQL=$REPO/pgbench_hot_cold_4000_50k.sql
  # 80000 popular statements, for pg_stat_statements.max=100000
  [ $MODE = hc80k100m ] && SQL=$REPO/pgbench_hot_cold_80k_100m.sql
  [ $MODE = hc80k1m ] && SQL=$REPO/pgbench_hot_cold_80k_1m.sql
  # hc100midle: hc100m, plus IDLE_SESSIONS sessions holding references to
  # entries another backend created: before the churn, one session creates
  # IDLE_SESSIONS * IDLE_STMTS entries, then each idle session runs
  # IDLE_STMTS of them and stays idle, connected, for the rest of the run
  # hc100midlenp: the same, the idle sessions only PREPARE the statements,
  # with track_utility off: references with nothing pending
  [ $MODE = hc100midle ] && SQL=$REPO/pgbench_hot_cold_4000_100m.sql
  [ $MODE = hc100midlenp ] && SQL=$REPO/pgbench_hot_cold_4000_100m.sql
  pgbench -n -M simple -c $CL -j 32 -T 20 -f $SQL >/dev/null 2>&1
  psql -qXc 'SELECT pg_stat_statements_reset()' >/dev/null
  date +%s > $OUT/measured_since
  IDLE_PIDS=
  if [ $MODE = hc100midle ] || [ $MODE = hc100midlenp ]; then
    NS=${IDLE_SESSIONS:-20}; NQ=${IDLE_STMTS:-200}
    for s in $(seq 1 $NS); do for i in $(seq 1 $NQ); do
      echo "WITH CTEIDLE_${s}_$i AS MATERIALIZED (SELECT 1 AS v) SELECT v FROM CTEIDLE_${s}_$i;"
    done; done | psql -qXAt >/dev/null 2>>$OUT/idle.err
    rm -f $OUT/idle_ready_*
    for s in $(seq 1 $NS); do
      ( [ $MODE = hc100midlenp ] && echo "SET pg_stat_statements.track_utility = off;"
        for i in $(seq 1 $NQ); do
          q="WITH CTEIDLE_${s}_$i AS MATERIALIZED (SELECT 1 AS v) SELECT v FROM CTEIDLE_${s}_$i"
          if [ $MODE = hc100midlenp ]; then echo "PREPARE p$i AS $q;"; else echo "$q;"; fi
        done
        echo "\\! touch $OUT/idle_ready_$s"
        exec sleep $((SECS + 60)) ) | psql -qXAt >/dev/null 2>>$OUT/idle.err &
      IDLE_PIDS="$IDLE_PIDS $!"
    done
    for t in $(seq 1 60); do [ $(ls $OUT/idle_ready_* 2>/dev/null | wc -l) -ge $NS ] && break; sleep 0.5; done
    # The idle entries before the churn, for the record
    psql -AtXc "SELECT count(*) FROM pg_stat_statements WHERE query LIKE 'WITH CTEIDLE_%'" > $OUT/idle_entries 2>&1
  fi
  start_minmax_resets
  pgbench -n -M simple -P ${PROGRESS_SECS:-10} -c $CL -j 32 -T $SECS -f $SQL >$OUT/pgbench.log 2>&1
  # End the idle sessions: their sleep ends, psql reads end of file
  [ -n "$IDLE_PIDS" ] && pkill -f "^sleep $((SECS + 60))$" 2>/dev/null
fi
kill $SAMP $SAMP2 $SAMP3 $RESETS 2>/dev/null
EC=$(awk -v cap=$((2*MAX)) 'NF {if ($1>m) m=$1; s+=$1; n++; if ($1>=cap) c++} END {if (n) printf "max=%d avg=%.0f backstop=%.0f%%", m, s/n, 100*c/n; else print "n/a"}' $OUT/entry_count.txt)
# Samples of the measured phase, from 10 s after the reset, when the view
# holds the popular statements again
S5=$(awk -v since=$(($(cat $OUT/measured_since) + 10)) 'NF>=6 && $6 >= since {if ($1>tm) tm=$1; tl=$1; vs+=$2; vn++; if (pm=="" || $3<pm) pm=$3} END {if (vn) printf "textMB_max=%.2f textMB_final=%.2f view_avg=%.0f popular_min=%d", tm/1048576, tl/1048576, vs/vn, pm; else print "n/a"}' $OUT/samples5.txt)
echo "$BUILD $MODE c$CL max=$MAX $(grep ^tps $OUT/pgbench.log | awk '{print $3}') dealloc=$(psql -AtXc 'SELECT dealloc FROM pg_stat_statements_info') entry_count[$EC] $S5"
