#!/usr/bin/env bash
# Datapoints of a local benchmark so far, then the run in progress.
# usage: status.sh <name> [<hash>=<label>...]
. "$(dirname "$(readlink -f "$0")")/common.sh"
F=$1_results.txt; shift
$REPO/local/archive.sh
python3 $REPO/report_datapoints.py local $F "$@"
echo
echo "$(grep -c '^inst-' $F) of $(cat ${F%_results.txt}_planned 2>/dev/null || echo '?') runs done"
grep -qs '^done' $F && echo done && exit
r=$(ls -td ab-*/ 2>/dev/null | head -1); r=${r%/}
[ -n "$r" ] && echo "in progress: ${r#ab-}  $(grep -a '^progress' $r/pgbench.log 2>/dev/null | tail -1)"
