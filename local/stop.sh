#!/usr/bin/env bash
# Stop the benchmark runs and their servers.
. "$(dirname "$(readlink -f "$0")")/common.sh"
for p in $(pgrep -f '[b]ench\.sh') $(pgrep -f '[a]b_run\.sh'); do kill $p 2>/dev/null; done
pkill -x pgbench; sleep 3
for d in ab-*/data; do [ -f $d/postmaster.pid ] && inst-up/bin/pg_ctl -D $d -m fast stop >/dev/null; done
pgrep -f '[b]ench\.sh|[a]b_run\.sh' >/dev/null && echo "still running" || echo "stopped"
