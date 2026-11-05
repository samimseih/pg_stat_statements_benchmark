#!/usr/bin/env python3
"""Report the results of a fleet fetched by fetch_fleet_status.sh.

Prints the progress of each instance, then one markdown table comparing the
patch and the base for each workload, number of clients and instance type,
smallest instance first, then the TPS histograms of the points whose TPS
varies by a CV of TPS_CV_BUCKETS percent or more.  The TPS spread of each
point comes from its pgbench progress samples, see report_tps_stability.sh,
which computes it.

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

    rows, hists = [], []
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
                (f"{p['min_entries']}/{p['avg_entries']}/{p['max_entries']}"
                 if p else "-"),
                (f"{b['min_entries']}/{b['avg_entries']}/{b['max_entries']}"
                 if b else "-"),
                pair(p, b, lambda r: r["min_pop_entries"]),
                pair(p, b, lambda r: f"{float(r['max_qtext_file_size']) / 1048576:.2f}"),
                pair(p, b, lambda r: r["failed"]),
            ]) + " |"))
            if any(s and float(s["cv_pct"]) >= CV_BUCKETS for s in (sp, sb)):
                for order, (name, s) in enumerate((("patch", sp), ("base", sb))):
                    if s:
                        hists.append(((w, c, rank, order), "| " + " | ".join(
                            [w, str(c), t, name, s["samples"],
                             f"{float(s['cv_pct']):.1f}%"]
                            + s["buckets"].split()) + " |"))
    print()

    print("| Workload | Clients | Instance | TPS patch / base | Performance ratio "
          "| TPS stddev p / b | TPS CV p / b | Sample TPS min-max p / b "
          "| Entries min/avg/max, patch | Entries min/avg/max, base "
          "| Popular kept (min) p / b | Text file max MB p / b | Failed p / b |")
    print("|---" * 13 + "|")
    for _, line in sorted(rows):
        print(line)
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


main()
