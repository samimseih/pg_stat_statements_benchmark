#!/usr/bin/env bash
# usage: summarize_kind.sh <results root of a run>
#
# Print, for each point of a run, the min, average, max and last number of
# entries allocated by the pg_stat_statements stats kind (entry_count of
# pg_stat_kind_info, sampled in monitor_kind.tsv), which includes removed
# entries not freed yet.  Points without samples, such as upstream ones, are
# left out.  at_cap is the percentage of samples at or above twice
# pg_stat_statements.max (PGSS_MAX, 5000 by default), where the patch does not
# track new statements.
set -uo pipefail
root=$1
cap=$(( 2 * ${PGSS_MAX:-5000} ))

printf 'commit\tworkload\tclients\tmin_allocated\tavg_allocated\tmax_allocated\tlast_allocated\tat_cap_pct\n'
for f in "$root"/*/*/c*/monitor_kind.tsv; do
  [[ -f "$f" ]] || continue
  rel=${f#"$root"/}
  awk -F'\t' -v rel="$rel" -v cap="$cap" '
    BEGIN { split(rel, p, "/"); c = p[1]; w = p[2]; n = substr(p[3], 2) }
    NR > 1 && $2 != "" {
      if (!k || $2 < mn) mn = $2
      if ($2 > mx) mx = $2
      sum += $2; k++; last = $2
      if ($2 >= cap) atcap++
    }
    END {
      if (k)
        printf "%s\t%s\t%s\t%d\t%.0f\t%d\t%d\t%.0f\n", c, w, n, mn, sum / k, mx, last, 100 * atcap / k
    }' "$f"
done
