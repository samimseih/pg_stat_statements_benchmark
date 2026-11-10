#!/usr/bin/env bash
# usage: summarize_age.sh <results root of a run>
#
# Print, for each point of a run, the average number of entries of the view
# in each bucket of how long ago they were created (stats_since), from the
# samples of monitor_age.tsv.
set -uo pipefail
root=$1

printf 'commit\tworkload\tclients\tcreated\tavg_count\n'
for f in "$root"/*/*/c*/monitor_age.tsv; do
  [[ -f "$f" ]] || continue
  rel=${f#"$root"/}
  awk -F'\t' -v rel="$rel" '
    BEGIN { split(rel, p, "/"); c = p[1]; w = p[2]; n = substr(p[3], 2) }
    NR > 1 && NF >= 3 {
      # The rows of one sample carry their own clock_timestamp(): rows less
      # than 2 s apart are one sample
      if (!samples || $1 - start >= 2) { start = $1; samples++ }
      sum[$2] += $3
    }
    END {
      for (b in sum)
        printf "%s\t%s\t%s\t%s\t%.0f\n", c, w, n, b, sum[b] / samples
    }' "$f"
done
