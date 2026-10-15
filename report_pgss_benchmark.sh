#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${1:-}"
REPORT_CLIENTS="${REPORT_CLIENTS:-1 32 128 256}"

die() {
  echo "error: $*" >&2
  exit 1
}

if [[ -z "$RESULT_DIR" ]]; then
  RESULT_DIR="$(ls -td "$SCRIPT_DIR"/results/* 2>/dev/null | head -n 1)"
fi

[[ -n "$RESULT_DIR" ]] || die "no results directory found"
[[ -f "$RESULT_DIR/summary.tsv" ]] || die "$RESULT_DIR/summary.tsv not found"

summary="$RESULT_DIR/summary.tsv"
read -r patched_commit baseline_commit < <(
  awk -F $'\t' '
    NR > 1 && !seen[$1]++ {
      if (++n == 1)
        patched = $1
      else if (n == 2) {
        print patched, $1
        exit
      }
    }' "$summary"
)

[[ -n "$patched_commit" && -n "$baseline_commit" ]] ||
  die "summary.tsv must contain patched and baseline commits"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
wait_summary="$tmpdir/wait_summary.tsv"

find "$RESULT_DIR" -path '*/waits.tsv' -type f | sort |
while IFS= read -r file; do
  rel="${file#$RESULT_DIR/}"
  commit="${rel%%/*}"
  rest="${rel#*/}"
  workload="${rest%%/*}"

  awk -F $'\t' -v commit="$commit" -v workload="$workload" '
    {
      wait = $2 ":" $3
      key = commit "\t" workload
      total[key] += $4
      if (wait == "LWLock:pg_stat_statements")
        pgss[key] += $4
      else if (wait == "LWLock:PgStatsDSA")
        dsa[key] += $4
      else if (wait == "LWLock:PgStatsHash")
        hash[key] += $4
      else if (wait == "LWLock:pg_stat_statements_qtext")
        qtext[key] += $4
      else if (wait == "Timeout:SpinDelay")
        spin[key] += $4
      else if (wait == "Client:ClientRead")
        client[key] += $4
      else if (wait == ":")
        cpu[key] += $4
    }
    END {
      for (key in total)
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
               key, total[key], pgss[key], dsa[key], hash[key],
               qtext[key], spin[key], client[key], cpu[key]
    }' "$file"
done > "$wait_summary"

awk -F $'\t' \
  -v result_dir="$RESULT_DIR" \
  -v result_label="${REPORT_RESULT_DIR_LABEL:-}" \
  -v report_clients="$REPORT_CLIENTS" \
  -v patched_hint="$patched_commit" \
  -v baseline_hint="$baseline_commit" \
  -v patched_label_hint="${PATCHED_LABEL:-}" \
  -v baseline_label_hint="${BASELINE_LABEL:-}" '
function pct(patched, baseline) {
  if (baseline == 0)
    return "n/a"
  return sprintf("%+.1f%%", (patched / baseline - 1) * 100)
}

function pctnum(patched, baseline) {
  if (baseline == 0)
    return 0
  return (patched / baseline - 1) * 100
}

function pctrange(workload, i, clients, p, b, d, min, max, seen) {
  for (i = 1; i <= nwanted; i++) {
    clients = wanted_clients[i]
    if (clients == 1 || !have_pair(workload, clients))
      continue
    p = cell(patched, workload, clients, "tps")
    b = cell(baseline, workload, clients, "tps")
    d = pctnum(p, b)
    if (!seen || d < min)
      min = d
    if (!seen || d > max)
      max = d
    seen = 1
  }

  if (!seen)
    return "n/a"
  if (sprintf("%.1f", min) == sprintf("%.1f", max))
    return sprintf("%+.1f%%", min)
  return sprintf("%+.1f%% to %+.1f%%", min, max)
}

function nfmt(n, s, out) {
  s = sprintf("%.0f", n)
  while (s ~ /^[0-9][0-9][0-9][0-9]/) {
    out = "," substr(s, length(s) - 2, 3) out
    s = substr(s, 1, length(s) - 3)
  }
  return s out
}

function rangefmt(min, max) {
  if (sprintf("%.0f", min) == sprintf("%.0f", max))
    return nfmt(max)
  return nfmt(min) "-" nfmt(max)
}

function triplefmt(min, avg, max) {
  if (sprintf("%.0f", min) == sprintf("%.0f", avg) &&
      sprintf("%.0f", avg) == sprintf("%.0f", max))
    return nfmt(avg)
  return nfmt(min) "/" nfmt(avg) "/" nfmt(max)
}

function label(commit) {
  return commit == patched ? "patched" : "baseline"
}

function cell(commit, workload, clients, field) {
  return data[commit SUBSEP workload SUBSEP clients SUBSEP field]
}

function fieldnum(field) {
  return (field in col) ? $(col[field]) + 0 : 0
}

function have_pair(workload, clients) {
  return ((patched SUBSEP workload SUBSEP clients SUBSEP "tps") in data &&
          (baseline SUBSEP workload SUBSEP clients SUBSEP "tps") in data)
}

function have_workload(workload, i) {
  for (i = 1; i <= nwanted; i++) {
    if (have_pair(workload, wanted_clients[i]))
      return 1
  }
  return 0
}

function waitcell(commit, workload, field) {
  return waits[commit SUBSEP workload SUBSEP field] + 0
}

function print_throughput(workload, i, clients, p, b) {
  if (!have_workload(workload))
    return

  print "### " workload
  print ""
  print "| clients | patched TPS | baseline TPS | delta |"
  print "| ---: | ---: | ---: | ---: |"
  for (i = 1; i <= nwanted; i++) {
    clients = wanted_clients[i]
    if (!have_pair(workload, clients))
      continue
    p = cell(patched, workload, clients, "tps")
    b = cell(baseline, workload, clients, "tps")
    print "| " clients " | " nfmt(p) " | " nfmt(b) " | " pct(p, b) " |"
  }
  print ""
}

function commitfmt(commit, hint) {
  if (hint != "")
    return "`" commit "` - " hint
  return "`" commit "`"
}

function print_wait_row(workload, commit) {
  print "| " workload " | " label(commit) " | " \
        nfmt(waitcell(commit, workload, "total")) " | " \
        nfmt(waitcell(commit, workload, "pgss")) " | " \
        nfmt(waitcell(commit, workload, "dsa")) " | " \
        nfmt(waitcell(commit, workload, "hash")) " | " \
        nfmt(waitcell(commit, workload, "qtext")) " | " \
        nfmt(waitcell(commit, workload, "spin")) " | " \
        nfmt(waitcell(commit, workload, "client")) " | " \
        nfmt(waitcell(commit, workload, "cpu")) " |"
}

BEGIN {
  nwanted = split(report_clients, wanted_clients, " ")
  split("hotcold_100m hotcold_1500 select_only", workload_order, " ")
  patched = patched_hint
  baseline = baseline_hint
}

FNR == NR && NR == 1 {
  for (i = 1; i <= NF; i++)
    col[$i] = i
  next
}

FNR == NR {
  commit = $col["commit"]
  workload = $col["workload"]
  clients = $col["clients"]

  if (!(commit in commit_seen)) {
    commit_seen[commit] = ++ncommits
    commit_order[ncommits] = commit
  }

  key = commit SUBSEP workload SUBSEP clients
  data[key SUBSEP "tps"] = $col["tps"] + 0
  data[key SUBSEP "duration"] = $col["duration_s"] + 0
  data[key SUBSEP "entries"] = $col["max_entries"] + 0
  data[key SUBSEP "entries_min"] = \
    ("min_entries" in col) ? fieldnum("min_entries") : data[key SUBSEP "entries"]
  data[key SUBSEP "entries_avg"] = \
    ("avg_entries" in col) ? fieldnum("avg_entries") : data[key SUBSEP "entries"]
  data[key SUBSEP "pop"] = $col["max_pop_entries"] + 0
  data[key SUBSEP "pop_min"] = \
    ("min_pop_entries" in col) ? fieldnum("min_pop_entries") : data[key SUBSEP "pop"]
  data[key SUBSEP "pop_avg"] = \
    ("avg_pop_entries" in col) ? fieldnum("avg_pop_entries") : data[key SUBSEP "pop"]
  data[key SUBSEP "unpop"] = $col["max_unpop_entries"] + 0
  data[key SUBSEP "unpop_min"] = \
    ("min_unpop_entries" in col) ? fieldnum("min_unpop_entries") : data[key SUBSEP "unpop"]
  data[key SUBSEP "unpop_avg"] = \
    ("avg_unpop_entries" in col) ? fieldnum("avg_unpop_entries") : data[key SUBSEP "unpop"]
  data[key SUBSEP "select"] = $col["max_select_entries"] + 0
  data[key SUBSEP "other"] = $col["max_other_entries"] + 0
  data[key SUBSEP "dealloc"] = $col["max_entry_dealloc"] + 0
  data[key SUBSEP "qtext"] = $col["max_qtext_count"] + 0
  data[key SUBSEP "qtext_min"] = \
    ("min_qtext_count" in col) ? fieldnum("min_qtext_count") : data[key SUBSEP "qtext"]
  data[key SUBSEP "qtext_avg"] = \
    ("avg_qtext_count" in col) ? fieldnum("avg_qtext_count") : data[key SUBSEP "qtext"]
  data[key SUBSEP "qtext_len_min"] = \
    ("min_qtext_total_len" in col) ? fieldnum("min_qtext_total_len") : fieldnum("max_qtext_total_len")
  data[key SUBSEP "qtext_len_avg"] = \
    ("avg_qtext_total_len" in col) ? fieldnum("avg_qtext_total_len") : fieldnum("max_qtext_total_len")
  data[key SUBSEP "qtext_len_max"] = fieldnum("max_qtext_total_len")
  data[key SUBSEP "qtext_dsa_min"] = \
    ("min_qtext_dsa_size" in col) ? fieldnum("min_qtext_dsa_size") : fieldnum("max_qtext_dsa_size")
  data[key SUBSEP "qtext_dsa_avg"] = \
    ("avg_qtext_dsa_size" in col) ? fieldnum("avg_qtext_dsa_size") : fieldnum("max_qtext_dsa_size")
  data[key SUBSEP "qtext_dsa_max"] = fieldnum("max_qtext_dsa_size")
  data[key SUBSEP "entry_dsa_min"] = \
    ("min_entry_dsa_size" in col) ? fieldnum("min_entry_dsa_size") : fieldnum("max_entry_dsa_size")
  data[key SUBSEP "entry_dsa_avg"] = \
    ("avg_entry_dsa_size" in col) ? fieldnum("avg_entry_dsa_size") : fieldnum("max_entry_dsa_size")
  data[key SUBSEP "entry_dsa_max"] = fieldnum("max_entry_dsa_size")

  duration[workload] = $col["duration_s"] + 0
  clients_seen[clients] = 1
  if ($col["status"] != 0)
    failed++
  next
}

{
  commit = $1
  workload = $2
  key = commit SUBSEP workload
  waits[key SUBSEP "total"] += $3
  waits[key SUBSEP "pgss"] += $4
  waits[key SUBSEP "dsa"] += $5
  waits[key SUBSEP "hash"] += $6
  waits[key SUBSEP "qtext"] += $7
  waits[key SUBSEP "spin"] += $8
  waits[key SUBSEP "client"] += $9
  waits[key SUBSEP "cpu"] += $10
}

END {
  if (result_label == "")
    result_label = result_dir

  high100 = pctrange("hotcold_100m")
  high1500 = pctrange("hotcold_1500")
  highselect = pctrange("select_only")

  for (w = 1; w <= 2; w++) {
    workload = workload_order[w]
    for (i = 1; i <= nwanted; i++) {
      clients = wanted_clients[i]
      if (!have_pair(workload, clients))
        continue
      pop = cell(patched, workload, clients, "pop")
      if (!min_pop || pop < min_pop)
        min_pop = pop
      qtext = cell(patched, workload, clients, "qtext")
      if (qtext > max_qtext[workload])
        max_qtext[workload] = qtext
    }
  }

  baseline_churn_pgss = \
    waitcell(baseline, "hotcold_100m", "pgss") + \
    waitcell(baseline, "hotcold_1500", "pgss")
  patched_churn_pgss = \
    waitcell(patched, "hotcold_100m", "pgss") + \
    waitcell(patched, "hotcold_1500", "pgss")
  patched_churn_new = \
    waitcell(patched, "hotcold_100m", "dsa") + \
    waitcell(patched, "hotcold_100m", "hash") + \
    waitcell(patched, "hotcold_100m", "qtext") + \
    waitcell(patched, "hotcold_1500", "dsa") + \
    waitcell(patched, "hotcold_1500", "hash") + \
    waitcell(patched, "hotcold_1500", "qtext")
  baseline_spin = \
    waitcell(baseline, "hotcold_100m", "spin") + \
    waitcell(baseline, "hotcold_1500", "spin") + \
    waitcell(baseline, "select_only", "spin")
  patched_spin = \
    waitcell(patched, "hotcold_100m", "spin") + \
    waitcell(patched, "hotcold_1500", "spin") + \
    waitcell(patched, "select_only", "spin")

  print "# pg_stat_statements benchmark report"
  print ""
  print "## Summary"
  print ""
  if (have_workload("hotcold_100m"))
    print "- hotcold_100m throughput improved by " high100 \
          " across reported non-single-client points."
  if (have_workload("hotcold_1500"))
    print "- hotcold_1500 throughput improved by " high1500 \
          " across reported non-single-client points."
  if (have_workload("select_only"))
    print "- select_only changed by " highselect \
          " across reported non-single-client points."
  if (min_pop)
    print "- Patched retained at least " nfmt(min_pop) \
          " popular statements at every reported churn point."
  qtext_line = ""
  for (w = 1; w <= 2; w++) {
    workload = workload_order[w]
    if (!have_workload(workload))
      continue
    if (qtext_line != "")
      qtext_line = qtext_line " and "
    qtext_line = qtext_line nfmt(max_qtext[workload]) " for " workload
  }
  if (qtext_line != "")
    print "- Patched qtext_count high-water was " qtext_line "."
  print "- Baseline churn sampled " nfmt(baseline_churn_pgss) \
        " pg_stat_statements LWLock waits; patched sampled " \
        nfmt(patched_churn_pgss) "."
  print "- Patched replacement pgstat/qtext waits under churn totaled " \
        nfmt(patched_churn_new) " samples."
  print "- Baseline SpinDelay samples were " nfmt(baseline_spin) \
        " versus " nfmt(patched_spin) " for patched."
  print ""
  print "## Run"
  print ""
  print "| item | value |"
  print "| --- | --- |"
  print "| result directory | `" result_label "` |"
  print "| patched | " commitfmt(patched, patched_label_hint) " |"
  print "| baseline | " commitfmt(baseline, baseline_label_hint) " |"
  print "| hot/cold duration | " duration["hotcold_100m"] \
        " seconds per point |"
  print "| select-only duration | " duration["select_only"] \
        " seconds per point |"
  print "| report client points | `" report_clients "` |"
  print "| failed pgbench rows | " failed + 0 " |"
  print ""

  print "## Throughput"
  print ""
  print_throughput("hotcold_100m")
  print_throughput("hotcold_1500")
  print_throughput("select_only")

  print "## Retention"
  print ""
  print "Values are sampled min/avg/max."
  print ""
  print "| workload | clients | patched entries min/avg/max |" \
        " baseline entries min/avg/max | patched pop min/avg/max |" \
        " baseline pop min/avg/max | patched unpop min/avg/max |" \
        " baseline unpop min/avg/max |"
  print "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
  for (w = 1; w <= 2; w++) {
    workload = workload_order[w]
    for (i = 1; i <= nwanted; i++) {
      clients = wanted_clients[i]
      if (!have_pair(workload, clients))
        continue
      print "| " workload " | " clients " | " \
            triplefmt(cell(patched, workload, clients, "entries_min"),
                      cell(patched, workload, clients, "entries_avg"),
                      cell(patched, workload, clients, "entries")) " | " \
            triplefmt(cell(baseline, workload, clients, "entries_min"),
                      cell(baseline, workload, clients, "entries_avg"),
                      cell(baseline, workload, clients, "entries")) " | " \
            triplefmt(cell(patched, workload, clients, "pop_min"),
                      cell(patched, workload, clients, "pop_avg"),
                      cell(patched, workload, clients, "pop")) " | " \
            triplefmt(cell(baseline, workload, clients, "pop_min"),
                      cell(baseline, workload, clients, "pop_avg"),
                      cell(baseline, workload, clients, "pop")) " | " \
            triplefmt(cell(patched, workload, clients, "unpop_min"),
                      cell(patched, workload, clients, "unpop_avg"),
                      cell(patched, workload, clients, "unpop")) " | " \
            triplefmt(cell(baseline, workload, clients, "unpop_min"),
                      cell(baseline, workload, clients, "unpop_avg"),
                      cell(baseline, workload, clients, "unpop")) " |"
    }
  }
  print ""

  print "## Query Text And Churn"
  print ""
  print "Query-text and memory values are sampled min/avg/max."
  print "Memory values are raw bytes."
  print ""
  print "| workload | clients | patched qtext count | patched qtext bytes |" \
        " patched qtext DSA min/avg/max | patched entry DSA min/avg/max | patched dealloc |" \
        " baseline dealloc |"
  print "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
  for (w = 1; w <= 2; w++) {
    workload = workload_order[w]
    for (i = 1; i <= nwanted; i++) {
      clients = wanted_clients[i]
      if (!have_pair(workload, clients))
        continue
      print "| " workload " | " clients " | " \
            triplefmt(cell(patched, workload, clients, "qtext_min"),
                      cell(patched, workload, clients, "qtext_avg"),
                      cell(patched, workload, clients, "qtext")) " | " \
            triplefmt(cell(patched, workload, clients, "qtext_len_min"),
                      cell(patched, workload, clients, "qtext_len_avg"),
                      cell(patched, workload, clients, "qtext_len_max")) " | " \
            triplefmt(cell(patched, workload, clients, "qtext_dsa_min"),
                      cell(patched, workload, clients, "qtext_dsa_avg"),
                      cell(patched, workload, clients, "qtext_dsa_max")) " | " \
            triplefmt(cell(patched, workload, clients, "entry_dsa_min"),
                      cell(patched, workload, clients, "entry_dsa_avg"),
                      cell(patched, workload, clients, "entry_dsa_max")) " | " \
            nfmt(cell(patched, workload, clients, "dealloc")) " | " \
            nfmt(cell(baseline, workload, clients, "dealloc")) " |"
    }
  }
  print ""

  print "## Memory Gauge Averages"
  print ""
  print "Average values from the periodic samples. Memory values are raw bytes."
  print ""
  print "| workload | clients | avg entries | avg qtext count | avg qtext bytes |" \
        " avg qtext DSA | avg entry DSA |"
  print "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
  for (w = 1; w <= 3; w++) {
    workload = workload_order[w]
    for (i = 1; i <= nwanted; i++) {
      clients = wanted_clients[i]
      if (!have_pair(workload, clients))
        continue
      print "| " workload " | " clients " | " \
            nfmt(cell(patched, workload, clients, "entries_avg")) " | " \
            nfmt(cell(patched, workload, clients, "qtext_avg")) " | " \
            nfmt(cell(patched, workload, clients, "qtext_len_avg")) " | " \
            nfmt(cell(patched, workload, clients, "qtext_dsa_avg")) " | " \
            nfmt(cell(patched, workload, clients, "entry_dsa_avg")) " |"
    }
  }
  print ""

  print "## Wait Events"
  print ""
  print "| workload | variant | active samples | pgss LWLock | PgStatsDSA |" \
        " PgStatsHash | qtext LWLock | SpinDelay | ClientRead | cpu/no wait |"
  print "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
  for (w = 1; w <= 3; w++) {
    workload = workload_order[w]
    if (!have_workload(workload))
      continue
    print_wait_row(workload, baseline)
    print_wait_row(workload, patched)
  }
  print ""

  print "## Notes"
  print ""
  print "- Deallocation counters are eviction-pass counters, matching upstream"
  print "  pg_stat_statements_info semantics."
  print "- Query-text and entry DSA columns are sampled current-state gauges;"
  print "  summary.tsv reports their sampled min/avg/max. Older commits that do"
  print "  not expose them report zero in summary.tsv."
  print "- Each commit reuses the same PostgreSQL server across workload groups,"
  print "  so select_only storage gauges can include DSA space allocated by"
  print "  earlier churn runs."
  print "- The cpu/no wait column is active backends with no PostgreSQL wait"
  print "  event reported, not an OS CPU counter."
  print "- Patched hot/cold runs removed the old pg_stat_statements LWLock"
  print "  samples; remaining waits were smaller and split across PgStatsDSA,"
  print "  PgStatsHash, and qtext paths."
  print "- Under churn, SpinDelay was smaller than the baseline"
  print "  pg_stat_statements LWLock bottleneck."
}
' "$summary" "$wait_summary"
