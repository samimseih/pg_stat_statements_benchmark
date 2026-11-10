#!/usr/bin/env bash
# Benchmark git refs against upstream (UPSTREAM, a ref of PG_SRC), following a
# plan file of "<vcpus> <clients> <repeats>" lines, in order.  Each run is
# pinned to CPUs 0..vcpus-1 (server, pgbench and samplers); the builds of a
# point run back to back, repeat after repeat.
#
# usage: UPSTREAM=<ref> [WORKLOADS="hc100m hc1500 sel"] [SECS=180] \
#          bench.sh <name> <plan file> <ref>...
# Run it detached:
#   setsid nohup local/bench.sh ... > $PGSS_WORK/<name>.log 2>&1 < /dev/null &
# Results: $PGSS_WORK/<name>_results.txt, see report_datapoints.py.
PLAN=$(readlink -f "$2")
. "$(dirname "$(readlink -f "$0")")/common.sh"
L=$REPO/local
NAME=$1; shift 2
SECS=${SECS:-180}
WORKLOADS=${WORKLOADS:-hc100m}
[ -n "${UPSTREAM:-}" ] || { echo "UPSTREAM is not set" >&2; exit 1; }
ln -sfn "$($L/build.sh "$UPSTREAM")" inst-up || exit 1
BUILDS=inst-up
for ref in "$@"; do BUILDS="$BUILDS $($L/build.sh $ref)" || exit 1; done
nb=$(wc -w <<< "$BUILDS")
nw=$(wc -w <<< "$WORKLOADS")
awk -v nb=$((nb * nw)) 'NF == 3 && $1 !~ /^#/ {n += $3 * nb} END {print n}' "$PLAN" > ${NAME}_planned
# The machine the runs are on
printf "vcpus=%s cpus=%s model=%s\n" "$(nproc)" "$(taskset -pc $$ | sed 's/.*: //')" \
  "$(lscpu | sed -n 's/^Model name: *//p' | tr ' ' _)" > ${NAME}_env
: > ${NAME}_results.txt
grep -v '^#' "$PLAN" | while read -r v cl reps; do
  [ -n "$reps" ] || continue
  for r in $(seq 1 $reps); do
    for b in $BUILDS; do
      for wl in $WORKLOADS; do
        line=$(taskset -c 0-$((v - 1)) $L/ab_run.sh $b $wl $cl $SECS 5000)
        echo "$line vcpus=$v rep=$r secs=$SECS" >> ${NAME}_results.txt
        $L/archive.sh
      done
    done
  done
done
echo done >> ${NAME}_results.txt
