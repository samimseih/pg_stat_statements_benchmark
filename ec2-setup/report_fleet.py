#!/usr/bin/env python3
"""Report the results of a fleet fetched by fetch_fleet_status.sh.

Prints the progress of each instance, then one markdown table comparing the
patch and the base for each workload, number of clients and instance type,
smallest instance first, then the TPS histograms of the points whose TPS
varies by a CV of TPS_CV_BUCKETS percent or more.  The TPS spread and trend
of each point come from its pgbench progress samples, see
report_tps_stability.sh, which computes them, and the points with a trend
other than steady get their TPS over time.

usage: report_fleet.py <fleet id | fleet results dir>
"""
import csv
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STABILITY = os.path.join(SCRIPT_DIR, "..", "report_tps_stability.sh")
BUCKETS = ["<50%", "50-80%", "80-95%", "95-105%", "105-120%", ">=120%"]
CV_BUCKETS = float(os.environ.get("TPS_CV_BUCKETS", "5"))

# Explanations printed under the tables, as markdown blockquotes.
NOTE_PROGRESS = """\
**How to read this:** points done counts the finished patch and base runs of
each instance, out of all its workloads and numbers of clients.  State is
done once the results archive is uploaded."""

NOTE_MAIN = """\
**How to read this:** each cell shows the patch value, then the base value.
- **Performance ratio:** patch TPS / base TPS; above 1.00 the patch is
  faster.  Trust ratios more when the CVs of both builds are low.
- **TPS stddev, CV, sample min-max:** spread of the pgbench progress samples
  of the point, one every PROGRESS_SECONDS, without the first.  CV is stddev
  / mean: under 2% is a steady run, 5% or more gets a histogram below.  A CV
  high for both builds is noise of the instance; higher for the patch only
  is the patch.  Min-max shows short stalls and bursts.
- **TPS trend:** how TPS changes over the run, see the TPS over time table.
  Steady is good; degrading is a sustained decline, or a drop not recovered
  from, and needs attention; dip recovered is a hiccup.
- **Entries min/avg/max:** sampled number of pg_stat_statements entries;
  the max may slightly exceed pg_stat_statements.max with the patch.
- **Popular kept (min):** fewest of the 4000 popular statements present in
  a sample; 4000 means eviction never removed a popular one.  n/a for
  select_only, which runs few statements.
- **Text file max MB:** largest size of the query text file.
- **Failed:** pgbench transactions that failed."""

NOTE_PROFILE = """\
**How to read this:** the run of each point is cut into equal time segments,
in time order (1 minute each for 5-minute points), with their mean TPS.
- **degrading:** the last segment is TPS_DRIFT_PCT (5%) or more below the
  first, and TPS mostly goes down along the way, which includes a drop not
  recovered from.  The serious case.
- **declined:** as low at the end, without a sustained decline.
- **dip recovered:** a segment fell that much, but the last one is back
  within it of the first: a hiccup.
- **improving, rose:** the same upward."""

NOTE_HISTOGRAM = """\
**How to read this:** each progress sample is compared with the median TPS
of its point, and counted in a bucket: <50% is a severe stall, 50-80% and
80-95% are slower samples, 95-105% is the normal band, 105-120% and >=120%
are faster bursts.
- **Healthy:** almost all samples in 95-105%.
- **Stalls:** counts in <50% or 50-80%, hidden by the average TPS.
- **Two speeds:** counts piled in two separate buckets, a run alternating
  between a fast and a slow phase.
- **Instance noise:** the same spread for patch and base.

Buckets are relative to the median, so they compare across TPS levels; they
do not show when samples happened, which the trend does."""


def note(text):
    print()
    for line in text.splitlines():
        print(f"> {line}" if line else ">")


def read_tsv(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def stability(progress):
    """The TPS spread of each point of a progress.tsv, by (commit, workload,
    clients)."""
    if not os.path.exists(progress) or os.path.getsize(progress) == 0:
        return {}
    env = dict(os.environ, TPS_FORMAT="tsv")
    out = subprocess.run(["bash", STABILITY, progress], env=env, check=True,
                         capture_output=True, text=True).stdout
    rows = csv.DictReader(out.splitlines(), delimiter="\t")
    return {(r["commit"], r["workload"], int(r["clients"])): r
            for r in rows if r["mean"]}


def k(x):
    return f"{float(x) / 1000:.1f}k"


def trend(s):
    if s["trend"] == "steady":
        return "steady"
    return f"{s['trend']} {float(s['drift_pct']):+.1f}%"


def pair(p, b, fmt):
    return f"{fmt(p) if p else '-'} / {fmt(b) if b else '-'}"


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    d = arg if os.path.isdir(arg) else os.path.join(SCRIPT_DIR, "results",
                                                    "fleet", arg)
    instances = sorted(read_tsv(os.path.join(d, "instances.tsv")),
                       key=lambda r: int(r["vcpus"]))
    if not instances:
        sys.exit(f"error: no instances.tsv in {d}, run fetch_fleet_status.sh")

    rows, hists, profiles = [], [], []
    print("| Instance | vCPUs | State | Points done |")
    print("|---|---:|---|---:|")
    for rank, inst in enumerate(instances):
        t = inst["type"]
        patch, base = inst["patch_commit"][:12], inst["base_commit"][:12]
        workloads = inst["workloads"].split()
        expected = 2 * sum(len((inst["select_clients"] if w == "select_only"
                                else inst["clients"]).split())
                           for w in workloads)
        summ = {(r["commit"], r["workload"], int(r["clients"])): r
                for r in read_tsv(os.path.join(d, f"{t}.summary.tsv"))
                if r.get("tps")}
        print(f"| {t} | {inst['vcpus']} | {inst['state']} "
              f"| {len(summ)} / {expected} |")
        st = stability(os.path.join(d, f"{t}.progress.tsv"))

        for w, c in sorted({(w, c) for (_, w, c) in summ}):
            p, b = summ.get((patch, w, c)), summ.get((base, w, c))
            sp, sb = st.get((patch, w, c)), st.get((base, w, c))
            ratio = (f"{float(p['tps']) / float(b['tps']):.2f}"
                     if p and b and float(b["tps"]) > 0 else "-")
            rows.append(((w, c, rank), "| " + " | ".join([
                w, str(c), t,
                pair(p, b, lambda r: k(r["tps"])),
                ratio,
                pair(sp, sb, lambda s: k(s["stddev"])),
                pair(sp, sb, lambda s: f"{float(s['cv_pct']):.1f}%"),
                pair(sp, sb, lambda s: f"{k(s['min'])}-{k(s['max'])}"),
                pair(sp, sb, trend),
                (f"{p['min_entries']}/{p['avg_entries']}/{p['max_entries']}"
                 if p else "-"),
                (f"{b['min_entries']}/{b['avg_entries']}/{b['max_entries']}"
                 if b else "-"),
                ("n/a" if w == "select_only"
                 else pair(p, b, lambda r: r["min_pop_entries"])),
                pair(p, b, lambda r: f"{float(r['max_qtext_file_size']) / 1048576:.2f}"),
                pair(p, b, lambda r: r["failed"]),
            ]) + " |"))
            if any(s and s["trend"] != "steady" for s in (sp, sb)):
                for order, (name, s) in enumerate((("patch", sp), ("base", sb))):
                    if s:
                        profiles.append(((w, c, rank, order), "| " + " | ".join(
                            [w, str(c), t, name, trend(s)]
                            + [k(x) for x in s["segments"].split()]) + " |"))
            if any(s and float(s["cv_pct"]) >= CV_BUCKETS for s in (sp, sb)):
                for order, (name, s) in enumerate((("patch", sp), ("base", sb))):
                    if s:
                        hists.append(((w, c, rank, order), "| " + " | ".join(
                            [w, str(c), t, name, s["samples"],
                             f"{float(s['cv_pct']):.1f}%"]
                            + s["buckets"].split()) + " |"))
    note(NOTE_PROGRESS)
    print()

    print("| Workload | Clients | Instance | TPS patch / base | Performance ratio "
          "| TPS stddev patch / base | TPS CV patch / base | Sample TPS min-max patch / base "
          "| TPS trend patch / base "
          "| Entries min/avg/max, patch | Entries min/avg/max, base "
          "| Popular kept (min) patch / base | Text file max MB patch / base | Failed patch / base |")
    print("|---" * 14 + "|")
    for _, line in sorted(rows):
        print(line)
    note(NOTE_MAIN)
    print()

    if profiles:
        print("TPS over time of the points with a trend other than steady: "
              "mean TPS of each equal time segment, in time order.  Degrading "
              "is a sustained decline, or a drop not recovered from; dip "
              "recovered is a hiccup.")
        print()
        nseg = len(profiles[0][1].split("|")) - 7
        print("| Workload | Clients | Instance | Build | Trend | "
              + " | ".join(str(g + 1) for g in range(nseg)) + " |")
        print("|---" * (5 + nseg) + "|")
        for _, line in sorted(profiles):
            print(line)
        note(NOTE_PROFILE)
    else:
        print("All points are steady over time.")
    print()

    if not hists:
        print(f"No point has a TPS CV of {CV_BUCKETS:g}% or more.")
        return
    print(f"TPS histograms of the points with a CV of {CV_BUCKETS:g}% or more: "
          "number of progress samples by TPS relative to the median of the "
          "point.")
    print()
    print("| Workload | Clients | Instance | Build | Samples | CV | "
          + " | ".join(BUCKETS) + " |")
    print("|---" * (6 + len(BUCKETS)) + "|")
    for _, line in sorted(hists):
        print(line)
    note(NOTE_HISTOGRAM)


main()
