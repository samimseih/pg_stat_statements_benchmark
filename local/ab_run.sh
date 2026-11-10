#!/usr/bin/env bash
# One run: a fresh cluster of <build>, a workload, then the result line.
# usage: ab_run.sh <build> <hc100m|hc1500|sel> <clients> <seconds> <max>
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
if [ $MODE = sel ]; then
  pgbench -i -s 10 >/dev/null 2>&1
  pgbench -n -M prepared -c 32 -j 32 -T 15 -S >/dev/null 2>&1
  date +%s > $OUT/measured_since
  pgbench -n -M prepared -P 10 -c $CL -j 32 -T $SECS -S >$OUT/pgbench.log 2>&1
else
  SQL=$REPO/pgbench_hot_cold_4000_1500.sql
  [ $MODE = hc100m ] && SQL=$REPO/pgbench_hot_cold_4000_100m.sql
  pgbench -n -M simple -c $CL -j 32 -T 20 -f $SQL >/dev/null 2>&1
  psql -qXc 'SELECT pg_stat_statements_reset()' >/dev/null
  date +%s > $OUT/measured_since
  pgbench -n -M simple -P 10 -c $CL -j 32 -T $SECS -f $SQL >$OUT/pgbench.log 2>&1
fi
kill $SAMP $SAMP2 $SAMP3 2>/dev/null
EC=$(awk -v cap=$((2*MAX)) 'NF {if ($1>m) m=$1; s+=$1; n++; if ($1>=cap) c++} END {if (n) printf "max=%d avg=%.0f backstop=%.0f%%", m, s/n, 100*c/n; else print "n/a"}' $OUT/entry_count.txt)
# Samples of the measured phase, from 10 s after the reset, when the view
# holds the popular statements again
S5=$(awk -v since=$(($(cat $OUT/measured_since) + 10)) 'NF>=6 && $6 >= since {if ($1>tm) tm=$1; tl=$1; vs+=$2; vn++; if (pm=="" || $3<pm) pm=$3} END {if (vn) printf "textMB_max=%.2f textMB_final=%.2f view_avg=%.0f popular_min=%d", tm/1048576, tl/1048576, vs/vn, pm; else print "n/a"}' $OUT/samples5.txt)
echo "$BUILD $MODE c$CL max=$MAX $(grep ^tps $OUT/pgbench.log | awk '{print $3}') dealloc=$(psql -AtXc 'SELECT dealloc FROM pg_stat_statements_info') entry_count[$EC] $S5"
