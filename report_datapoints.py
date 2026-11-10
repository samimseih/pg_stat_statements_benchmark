#!/usr/bin/env python3
"""Datapoints of each benchmark point, every build against upstream.

For each machine, workload and client count, one line per build:

  1. TPS, ratio to upstream, CV of the pgbench progress samples
  2. trend: last fifth of the run against the first fifth, flagged below -5%
  3. entries allocated by the stats kind, avg/max (track_entry_count)
  4. recency: entries of the view by creation age, <1s/1-10s/10s-1min/1-5min/>5min
  5. popular statements kept (min over the run, of 4000)
  6. eviction passes per 1M transactions, and against upstream
  7. backstop: % of the run at 2x pg_stat_statements.max, skipping new statements
  8. query text storage (file or shared memory), entries without a text

usage: report_datapoints.py local <results file>... [<hash>=<label>...]
       report_datapoints.py fleet <fleet results dir> [<hash>=<label>...]
       ... [--markdown <title>]   a Markdown page, to publish under reports/

<hash>=<label> names a patch build, e.g. 7739f4e="texts in memory"; the fleet
does not tell a query text file from query text memory, so name them there.
"""
import collections
import csv
import os
import re
import statistics
import sys

AGES = ('1:<1s', '2:1-10s', '3:10s-1min', '4:1-5min', '5:>5min')
WL = {'hotcold_4000_100m': 'hc100m', 'hotcold_4000_1500': 'hc1500',
      'select_only': 'sel', 'trickle_5000': 'trickle'}


def tsv(path):
    try:
        with open(path) as f:
            return list(csv.DictReader(f, delimiter='\t'))
    except OSError:
        return []


def lines(path):
    try:
        with open(path) as f:
            return [l.split() for l in f if l.strip()]
    except OSError:
        return []


def fleet(d, labels):
    """Points of a fleet: {(machine, workload, clients): {build: point}}."""
    pts = collections.defaultdict(dict)
    for inst in tsv(f'{d}/instances.tsv'):
        t = inst['type']
        machine = f"{t} ({inst['vcpus']} vCPUs)"
        base = inst['base_commit'][:7]
        name = lambda c: 'upstream' if c[:7] == base else labels.get(c[:7], c[:7])
        key = lambda r: (r['commit'][:7], r['workload'], r['clients'])
        kind = {key(r): r for r in tsv(f'{d}/{t}.kind.tsv')}
        age = collections.defaultdict(dict)
        for r in tsv(f'{d}/{t}.age.tsv'):
            age[key(r)][r['created']] = float(r['avg_count'])
        prog = collections.defaultdict(list)
        for r in tsv(f'{d}/{t}.progress.tsv'):
            if r.get('tps'):
                prog[key(r)].append(float(r['tps']))
        for r in tsv(f'{d}/{t}.summary.tsv'):
            if not r.get('tps') or r.get('status', '0') != '0':
                continue
            k, kd = key(r), kind.get(key(r))
            dsa = float(r.get('max_qtext_dsa_size') or 0)
            pts[(machine, WL.get(r['workload'], r['workload']), int(r['clients']))][name(r['commit'])] = {
                'tps': float(r['tps']),
                'progress': prog[k][1:],
                'alloc': (float(kd['avg_allocated']), float(kd['max_allocated'])) if kd else None,
                'backstop': float(kd['at_cap_pct']) if kd else None,
                'age': age.get(k, {}),
                'popular': r.get('min_pop_entries') or '-',
                'dealloc': float(r['final_entry_dealloc'] or 0),
                'secs': float(r['duration_s'] or 0),
                'text': (dsa, 'memory') if dsa else (float(r['max_qtext_file_size'] or 0), None),
                'notext': r.get('max_empty_query_entries') or '-',
            }
    return pts


def local_run(d, line, kv):
    """One run of local/ab_run.sh, from its archived sample files."""
    tps = float(line[4])
    prog = [float(m.group(1)) for m in
            re.finditer(r'^progress: \S+ s, ([\d.]+) tps', open_text(f'{d}/pgbench.log'), re.M)]
    ec = [int(x[0]) for x in lines(f'{d}/entry_count.txt') if x[0].isdigit()]
    cap = 2 * int(line[3].split('=')[1])
    since = int((open_text(f'{d}/measured_since') or '0').strip() or 0)
    # Samples from 10 s after the reset, once the popular statements are back
    smp = [x for x in lines(f'{d}/samples5.txt') if len(x) >= 6 and int(x[5]) >= since + 10]
    # The rows of one sample carry their own clock_timestamp(), and may
    # straddle a second: rows less than 2 s apart are one sample
    acc, nsamples, start = collections.Counter(), 0, None
    for t, _, bucket, n in (x for x in lines(f'{d}/age.txt') if len(x) == 4):
        if int(t) > since + 1:
            if start is None or int(t) - start >= 2:
                start = int(t)
                nsamples += 1
            acc[bucket] += int(n)
    mem = max((int(x[4]) for x in smp), default=0)
    return {
        'tps': tps,
        'progress': prog[1:],
        'alloc': (statistics.mean(ec), max(ec)) if ec else None,
        'backstop': 100 * sum(e >= cap for e in ec) / len(ec) if ec else None,
        'age': {b: acc[b] / nsamples for b in AGES} if nsamples else {},
        'popular': str(min(int(x[2]) for x in smp)) if smp else '-',
        'dealloc': float(kv.get('dealloc', 0)),
        'secs': float(kv.get('secs', 0)),
        'text': (mem, 'memory') if mem else (max((int(x[0]) for x in smp), default=0), 'file'),
        'notext': str(max(int(x[3]) for x in smp)) if smp else '-',
    }


def open_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ''


def local(files, labels):
    """Points of local runs; of repeats, the run with the median TPS."""
    reps = collections.defaultdict(lambda: collections.defaultdict(list))
    for fn in files:
        tag = os.path.basename(fn).replace('_results.txt', '')
        work = os.path.dirname(os.path.abspath(fn))
        env = dict(x.split('=', 1) for x in open_text(f'{work}/{tag}_env').split() if '=' in x)
        for line in lines(fn):
            if not line[0].startswith('inst-') or len(line) < 5:
                continue
            kv = dict(re.findall(r'(\w+)=([\d.]+)', ' '.join(line[5:])))
            b, w, c = line[0], line[1], int(line[2][1:])
            v, r = kv.get('vcpus', env.get('vcpus', '?')), kv.get('rep')
            d = f"{work}/archive/{tag}/{b}-{w}-c{c}-v{v}" + (f"-r{r}" if r else '')
            if not os.path.isdir(d):
                d = f'{work}/ab-{b}-{w}-c{c}'
            name = 'upstream' if b == 'inst-up' else labels.get(b[5:12], b[5:12])
            machine = f"{env.get('model', tag).replace('_', ' ')} ({v} vCPUs)"
            reps[(machine, w, c)][name].append(local_run(d, line, kv))
    pts = collections.defaultdict(dict)
    for k, builds in reps.items():
        for name, runs in builds.items():
            runs.sort(key=lambda p: p['tps'])
            pts[k][name] = runs[(len(runs) - 1) // 2]
    return pts


def datapoints(p, up, w):
    """The datapoints of build p at a point, against upstream up."""
    s = p['progress']
    q = max(len(s) // 5, 1)
    p1m = lambda x: x['dealloc'] / (x['tps'] * x['secs']) * 1e6 if x['secs'] else 0
    size, where = p['text']
    return {
        'tps': f"{p['tps'] / 1000:.1f}k",
        'ratio': f"{p['tps'] / up['tps']:.2f}x",
        'cv': f"{100 * statistics.pstdev(s) / statistics.mean(s):.1f}%" if len(s) > 2 else '-',
        'trend_v': 100 * (statistics.mean(s[-q:]) / statistics.mean(s[:q]) - 1) if len(s) >= 10 else 0,
        'alloc': f"{p['alloc'][0]:.0f}/{p['alloc'][1]:.0f}" if p['alloc'] else '-',
        'age': '/'.join(f"{p['age'].get(b, 0):.0f}" for b in AGES),
        'popular': p['popular'] if w != 'sel' else '-',
        'passes': f"{p1m(p):.0f}",
        'vs': f"{p1m(p) / p1m(up):.2f}x" if p1m(up) else '-',
        'backstop': f"{p['backstop']:.0f}%" if p['backstop'] is not None else '-',
        'text': f"{size / 1048576:.2f}MB" + (f" ({where})" if where else ''),
        'notext': p['notext'],
    }


def points(pts):
    """The points with upstream and a patch, ordered, with their builds."""
    vcpus = lambda m: int(re.search(r'\((\d+) vCPUs\)', m).group(1))
    for k in sorted(pts, key=lambda k: (vcpus(k[0]), k[0], k[1], k[2])):
        builds = pts[k]
        if 'upstream' in builds and len(builds) > 1:
            yield k, ['upstream'] + sorted(b for b in builds if b != 'upstream')


def report(pts):
    out = []
    for k, names in points(pts):
        machine, w, c = k
        builds = pts[k]
        out.append(f"{machine} {w} {c} client{'s' if c > 1 else ''}")
        nw = max(len(n) for n in names)
        for name in names:
            d = datapoints(builds[name], builds['upstream'], w)
            flag = '  <-- DEGRADING' if d['trend_v'] < -5 else ''
            out.append(
                f"  {name:{nw}} {d['tps']:>9} {d['ratio']:>6} cv {d['cv']:>5}"
                f" trend {d['trend_v']:+5.1f}%{flag} | alloc {d['alloc']:>11}"
                f" | age {d['age']} | popular {d['popular']}"
                f" | passes/1M {d['passes']:>4} ({d['vs']} up) | backstop {d['backstop']}"
                f" | text {d['text']}, no-text {d['notext']}")
    print('\n'.join(out) if out else 'no point with upstream and a patch yet')


LEGEND = """\
1. **TPS**, its ratio to upstream, and the CV of the pgbench progress samples.
2. **TPS trend**: whether the TPS holds over the run: the mean TPS of the
   last fifth of the run against the mean TPS of its first fifth.  Near 0%,
   the TPS is sustained; negative, the TPS falls as the run goes on, and
   below -5% the point is flagged **degrading**: a longer run would look
   worse.  See TPS over the run below.
3. **alloc**: entries allocated by the stats kind, avg/max
   (`track_entry_count`), including dropped entries not freed yet.
4. **age**: entries of the view by how long ago they were created
   (`stats_since`), averaged over the run, as
   `<1s/1-10s/10s-1min/1-5min/>5min`; see the histograms below.  Under
   churn, the youngest buckets hold the statements that come and go, the
   oldest the ones kept.
5. **popular**: the fewest of the 4000 popular statements in the view.
6. **passes/1M**: eviction passes per million transactions, and against
   upstream.
7. **backstop**: share of the run at twice `pg_stat_statements.max`, where new
   statements are not tracked.
8. **text**: largest size of the query text storage; **no-text**: most
   entries without a query text.
"""


def markdown(pts, title, meta):
    """The report as a Markdown page: settings, summary, every point."""
    out = [f"# {title}", "",
           "Produced by the `pgss-benchmark` Claude Code skill of this "
           "repository (`report_datapoints.py --markdown`).", "",
           "| | |", "|---|---|"]
    out += [f"| {k} | {v} |" for k, v in meta]
    out += ["", "## Datapoints", "", LEGEND, "## Summary", "",
            "TPS of each patch build against upstream, and its TPS trend: the mean",
            "TPS of the last fifth of the run against the first fifth (0% is",
            "sustained, negative is falling as the run goes on).", ""]
    for w in ('hc100m', 'hc1500', 'sel', 'trickle'):
        ks = [(k, n) for k, n in points(pts) if k[1] == w]
        if not ks:
            continue
        patches = [n for n in ks[0][1] if n != 'upstream']
        out += [f"### {w}", "",
                "| machine | clients | " + " | ".join(f"{n} | TPS trend" for n in patches) + " |",
                "|---|--:|" + "--:|--:|" * len(patches)]
        for k, names in ks:
            cells = []
            for n in patches:
                if n in pts[k]:
                    d = datapoints(pts[k][n], pts[k]['upstream'], w)
                    t = f"{d['trend_v']:+.1f}%" + (" **degrading**" if d['trend_v'] < -5 else '')
                    cells += [d['ratio'], t]
                else:
                    cells += ['', '']
            out.append(f"| {k[0]} | {k[2]} | " + " | ".join(cells) + " |")
        out.append("")
    out += ["## Every point", ""]
    cols = ['tps', 'ratio', 'cv', 'TPS trend', 'alloc', 'age', 'popular',
            'passes/1M', 'vs up', 'backstop', 'text', 'no-text']
    for k, names in points(pts):
        machine, w, c = k
        out += [f"### {machine}, {w}, {c} client{'s' if c > 1 else ''}", "",
                "| build | " + " | ".join(cols) + " |",
                "|---|" + "--:|" * len(cols)]
        for n in names:
            d = datapoints(pts[k][n], pts[k]['upstream'], w)
            out.append(f"| {n} | " + " | ".join([
                d['tps'], d['ratio'], d['cv'], f"{d['trend_v']:+.1f}%", d['alloc'],
                d['age'], d['popular'], d['passes'], d['vs'], d['backstop'],
                d['text'], d['notext']]) + " |")
        out.append("")
    out += trends(pts)
    out += histograms(pts)
    print('\n'.join(out))


def fifths(s):
    """Mean TPS of each fifth of a run: the first and last fifths as the TPS
    trend uses them, the rest of the run split in three between them."""
    if len(s) < 10:
        return []
    q = max(len(s) // 5, 1)
    mid = s[q:len(s) - q]
    cut = [len(mid) * i // 3 for i in range(4)]
    parts = [s[:q]] + [mid[cut[i]:cut[i + 1]] for i in range(3)] + [s[-q:]]
    return [statistics.mean(x) for x in parts if x]


def trends(pts):
    """TPS of each fifth of the run, per build, against its first fifth."""
    out = ["## TPS over the run", "",
           "Mean TPS of each fifth of the run, and its change from the first",
           "fifth; the change of the last fifth is the TPS trend.  One bar per",
           "fifth, 40 characters for the highest TPS of the point.", ""]
    for k, builds in points(pts):
        machine, w, c = k
        f = {b: fifths(pts[k][b]['progress']) for b in builds}
        top = max((x for v in f.values() for x in v), default=0)
        if not top:
            continue
        nw = max(len(b) for b in builds)
        out += [f"### {machine}, {w}, {c} client{'s' if c > 1 else ''}", "", "```"]
        for b in builds:
            for i, x in enumerate(f[b]):
                bar = '#' * round(40 * x / top)
                d = '' if i == 0 else f"  {100 * (x / f[b][0] - 1):+5.1f}%"
                note = ''
                if i == len(f[b]) - 1:
                    note = '  TPS trend' + ('  DEGRADING' if 100 * (x / f[b][0] - 1) < -5 else '')
                out.append(f"{b if i == 0 else '':{nw}}  fifth {i + 1}  {bar:40} {x / 1000:8.1f}k{d}{note}")
        out += ["```", ""]
    return out


def histograms(pts):
    """Entries of the view by creation age, one bar per build and bucket."""
    names = {'1:<1s': '<1s', '2:1-10s': '1-10s', '3:10s-1min': '10s-1min',
             '4:1-5min': '1-5min', '5:>5min': '>5min'}
    out = ["## Entries retained by recency", "",
           "Entries of the view by how long ago they were created, averaged",
           "over the run; one bar per build, 40 characters for 5000 entries.", ""]
    for k, builds in points(pts):
        machine, w, c = k
        if w == 'sel' or not any(pts[k][b]['age'] for b in builds):
            continue
        nw = max(len(b) for b in builds)
        out += [f"### {machine}, {w}, {c} client{'s' if c > 1 else ''}", "", "```"]
        for bk in AGES:
            for i, b in enumerate(builds):
                n = pts[k][b]['age'].get(bk, 0)
                bar = '#' * round(40 * n / 5000)
                out.append(f"{names[bk] if i == 0 else '':9} {b:{nw}} {bar} {n:.0f}")
        out += ["```", ""]
    return out


def fleet_meta(d, labels):
    """Settings of a fleet, from its instances.tsv."""
    insts = tsv(f'{d}/instances.tsv')
    if not insts:
        return []
    i = insts[0]
    secs = {r['duration_s'] for t in insts for r in tsv(f"{d}/{t['type']}.summary.tsv")
            if r.get('duration_s')}
    patches = [c for c in [i['patch_commit']] + i.get('extra_commits', '').split() if c]
    states = {t['state'] for t in insts}
    return ([('upstream', f"`{i['base_commit']}`")] +
            sorted((labels.get(c[:7], c[:7]), f"`{c}`") for c in patches) +
            [('machines', ', '.join(f"{t['type']} ({t['vcpus']} vCPUs)" for t in
                                    sorted(insts, key=lambda t: int(t['vcpus']))))] +
            [('workloads', i['workloads'].strip()), ('clients', i['clients']),
             ('seconds per run', ', '.join(sorted(s.split('.')[0] for s in secs)) or '-'),
             ('status', 'in progress, results so far' if states - {'done', 'terminated'}
              else 'done')])


if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] not in ('local', 'fleet'):
        sys.exit(__doc__)
    argv = sys.argv[2:]
    title = None
    if '--markdown' in argv:
        i = argv.index('--markdown')
        title = argv[i + 1] if i + 1 < len(argv) else 'pg_stat_statements benchmark'
        del argv[i:i + 2]
    args = [a for a in argv if '=' not in a]
    labels = {k[:7]: v for k, v in (a.split('=', 1) for a in argv if '=' in a)}
    pts = fleet(args[0], labels) if sys.argv[1] == 'fleet' else local(args, labels)
    if title is None:
        report(pts)
    else:
        meta = fleet_meta(args[0], labels) if sys.argv[1] == 'fleet' else []
        markdown(pts, title, meta)
