#!/usr/bin/env bash
# usage: summarize_trickle.sh <results root of a run>
#
# Print, for each trickle_5000 point of a run, how many new statements were
# introduced, the share of them the view showed on average and at the end,
# and their average age at the end, from monitor_trickle.tsv.
set -uo pipefail
root=$1

printf 'commit\tworkload\tclients\tintroduced\tavg_kept_pct\tfinal_kept_pct\tfinal_avg_age_s\n'
for f in "$root"/*/trickle_5000/c*/monitor_trickle.tsv; do
  [[ -f "$f" ]] || continue
  rel=${f#"$root"/}
  awk -F'\t' -v rel="$rel" '
    BEGIN { split(rel, p, "/"); c = p[1]; w = p[2]; n = substr(p[3], 2) }
    NR > 1 && $2 > 0 && $3 != "" {
      sum += 100 * $3 / $2; k++
      intro = $2; last = 100 * $3 / $2; age = $4
    }
    END {
      if (k)
        printf "%s\t%s\t%s\t%d\t%.0f\t%.0f\t%s\n", c, w, n, intro, sum / k, last, age
    }' "$f"
done
