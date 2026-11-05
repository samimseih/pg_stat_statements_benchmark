#!/usr/bin/env bash
#
# Report the stability of the TPS of each benchmark point, from the pgbench
# progress samples.  The final TPS of a point is its average over the whole
# run, which hides a run alternating between fast and slow phases.
#
# Usage:
#   ./report_tps_stability.sh [results-dir | progress.tsv]
#
# Samples come from progress.tsv, written by run_pgss_benchmark_suite.sh, or
# from the pgbench.log files of the points for older results directories.
#
# Settings:
#   TPS_SKIP_SAMPLES   leading samples of each point ignored, as warmup (1)
#   TPS_MIN_SAMPLES    fewer samples than this leave the statistics empty (5)
#   TPS_CV_BUCKETS     points with a CV at or above this percentage get a
#                      bucket histogram (5)
#   TPS_FORMAT         "markdown" (default), or "tsv" for one row per point
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${1:-$(ls -td "$SCRIPT_DIR"/results/* 2>/dev/null | head -n 1)}"
TPS_SKIP_SAMPLES="${TPS_SKIP_SAMPLES:-1}"
TPS_MIN_SAMPLES="${TPS_MIN_SAMPLES:-5}"
TPS_CV_BUCKETS="${TPS_CV_BUCKETS:-5}"
TPS_FORMAT="${TPS_FORMAT:-markdown}"

die() {
  echo "error: $*" >&2
  exit 1
}

# Print the progress samples of the pgbench.log files of a results
# directory, in the format of progress.tsv.
extract_progress() {
  local dir="$1" f commit workload cdir rest

  printf 'commit\tworkload\tclients\tt\ttps\tlat_ms\tlat_stddev_ms\tfailed\n'
  (cd "$dir" && find . -path './*/*/c*/pgbench.log' | sort) |
    while read -r f; do
      IFS=/ read -r _ commit workload cdir rest <<<"$f"
      awk -v c="$commit" -v w="$workload" -v n="${cdir#c}" -f <(progress_awk) \
        "$dir/$f"
    done
}

progress_awk() {
  cat <<'EOF'
/^progress: / {
  gsub(/,/, "")
  # progress: 10.0 s 22130.4 tps lat 0.045 ms stddev 0.032 0 failed
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", c, w, n, $2, $4, $7, $10, \
    ($12 == "failed" ? $11 : 0)
}
EOF
}

if [[ -d "$SOURCE" ]]; then
  if [[ -s "$SOURCE/progress.tsv" ]]; then
    input() { cat "$SOURCE/progress.tsv"; }
  else
    input() { extract_progress "$SOURCE"; }
  fi
elif [[ -f "$SOURCE" ]]; then
  input() { cat "$SOURCE"; }
else
  die "no results directory or progress.tsv: ${SOURCE:-none}"
fi

# Order points by commit, workload and number of clients, keeping the
# samples of each point in time order.
input | { IFS= read -r header; printf '%s\n' "$header"; sort -t $'\t' -s -k1,1 -k2,2 -k3,3n -k4,4n; } |
  awk -F '\t' \
  -v skip="$TPS_SKIP_SAMPLES" -v min_n="$TPS_MIN_SAMPLES" \
  -v cv_buckets="$TPS_CV_BUCKETS" -v format="$TPS_FORMAT" '
function isort(a, n, i, j, v) {
  for (i = 2; i <= n; i++) {
    v = a[i]
    for (j = i - 1; j >= 1 && a[j] > v; j--)
      a[j + 1] = a[j]
    a[j + 1] = v
  }
}

# Nearest-rank percentile of the sorted array a of n values.
function pctl(a, n, p, r) {
  r = int(p / 100 * n + 0.999999)
  if (r < 1)
    r = 1
  return a[r]
}

function kfmt(v) {
  if (v >= 1000)
    return sprintf("%.1fk", v / 1000)
  return sprintf("%.0f", v)
}

NR == 1 {
  for (i = 1; i <= NF; i++)
    col[$i] = i
  next
}

{
  k = $col["commit"] SUBSEP $col["workload"] SUBSEP $col["clients"]
  if (++seen[k] <= skip)
    next
  if (!(k in n))
    order[++npoints] = k
  v[k, ++n[k]] = $col["tps"]
}

END {
  bucket_lo[1] = 0;   bucket_label[1] = "<50%"
  bucket_lo[2] = 50;  bucket_label[2] = "50-80%"
  bucket_lo[3] = 80;  bucket_label[3] = "80-95%"
  bucket_lo[4] = 95;  bucket_label[4] = "95-105%"
  bucket_lo[5] = 105; bucket_label[5] = "105-120%"
  bucket_lo[6] = 120; bucket_label[6] = ">=120%"
  nbuckets = 6

  if (format == "tsv")
    print "commit\tworkload\tclients\tsamples\tmean\tstddev\tcv_pct\tmin\tp5\tp50\tp95\tmax\tbuckets"
  else {
    print "## TPS Stability"
    print ""
    print "Statistics of the pgbench progress samples of each point, without"
    print "its first " skip " sample(s).  CV is stddev / mean."
    print ""
    print "| commit | workload | clients | samples | mean | stddev | CV | min | p5 | p50 | p95 | max |"
    print "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
  }

  for (p = 1; p <= npoints; p++) {
    k = order[p]
    split(k, kk, SUBSEP)
    m = n[k]
    delete a
    sum = 0
    for (i = 1; i <= m; i++) {
      a[i] = v[k, i] + 0
      sum += a[i]
    }
    if (m < min_n) {
      if (format == "tsv")
        print kk[1] "\t" kk[2] "\t" kk[3] "\t" m "\t\t\t\t\t\t\t\t\t"
      else
        print "| " kk[1] " | " kk[2] " | " kk[3] " | " m " | - | - | - | - | - | - | - | - |"
      continue
    }
    isort(a, m)
    mean = sum / m
    ss = 0
    for (i = 1; i <= m; i++)
      ss += (a[i] - mean) ^ 2
    sd = m > 1 ? sqrt(ss / (m - 1)) : 0
    cv = mean > 0 ? 100 * sd / mean : 0
    med = pctl(a, m, 50)

    # Histogram of the samples relative to the median.
    for (b = 1; b <= nbuckets; b++)
      cnt[b] = 0
    for (i = 1; i <= m; i++) {
      rel = med > 0 ? 100 * a[i] / med : 100
      for (b = nbuckets; b > 1 && rel < bucket_lo[b]; b--)
        ;
      cnt[b]++
    }
    hist = ""
    for (b = 1; b <= nbuckets; b++)
      hist = hist (b > 1 ? " " : "") cnt[b]

    if (format == "tsv") {
      printf "%s\t%s\t%s\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%s\n",
        kk[1], kk[2], kk[3], m, mean, sd, cv, a[1], pctl(a, m, 5), med,
        pctl(a, m, 95), a[m], hist
      continue
    }
    printf "| %s | %s | %s | %d | %s | %s | %.1f%% | %s | %s | %s | %s | %s |\n",
      kk[1], kk[2], kk[3], m, kfmt(mean), kfmt(sd), cv, kfmt(a[1]),
      kfmt(pctl(a, m, 5)), kfmt(med), kfmt(pctl(a, m, 95)), kfmt(a[m])
    if (cv >= cv_buckets) {
      unstable[++nunstable] = "| " kk[1] " | " kk[2] " | " kk[3] " | " \
        sprintf("%.1f%%", cv) " |"
      unstable_hist[nunstable] = hist
    }
  }

  if (format == "tsv")
    exit
  print ""
  if (nunstable == 0) {
    print "No point has a CV of " cv_buckets "% or more."
    exit
  }
  print "### Unstable Points"
  print ""
  print "Points with a CV of " cv_buckets "% or more: number of samples by TPS"
  printf "relative to the median of the point ("
  for (b = 1; b <= nbuckets; b++)
    printf "%s%s", (b > 1 ? ", " : ""), bucket_label[b]
  print ")."
  print ""
  printf "| commit | workload | clients | CV |"
  for (b = 1; b <= nbuckets; b++)
    printf " %s |", bucket_label[b]
  print ""
  printf "| --- | --- | ---: | ---: |"
  for (b = 1; b <= nbuckets; b++)
    printf " ---: |"
  print ""
  for (i = 1; i <= nunstable; i++) {
    split(unstable_hist[i], h, " ")
    printf "%s", unstable[i]
    for (b = 1; b <= nbuckets; b++)
      printf " %s |", h[b]
    print ""
  }
}'
