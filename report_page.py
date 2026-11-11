#!/usr/bin/env python3
"""A results page in Markdown: every point of every run, data only.

For each point, two tables with one row per build (throughput, then
eviction) and two text histograms: TPS by fifth of the run, and the entries
of the view by how long ago they were created.  Runs of the profile script
(user_data_profile.sh) comparing builds on one instance, such as runs
without pg_stat_statements, get a throughput table each.  Wait events come
from the run archives (ec2-setup/fetch_archives.sh); points without an
archive have none.

usage: report_page.py [--title <title>] [--header <markdown file>]
                      [--archives <dir>] [--label <hash>=<label>]...
                      [--fleet <fleet results dir>]...
                      [--compare <run id>=<title>]...  > page.md
"""
import argparse
import collections
import glob
import os
import re
import statistics

import report_datapoints as rd

WLNAME = {'hc100m': 'hotcold_100m', 'hc1500': 'hotcold_1500', 'sel': 'select_only',
          'trickle': 'trickle_5000', 'select1': 'SELECT 1'}
WLDIR = {'hc100m': 'hotcold_4000_100m', 'hc1500': 'hotcold_4000_1500',
         'sel': 'select_only', 'trickle': 'trickle_5000', 'select1': 'select1'}
WLKEY = {v: k for k, v in WLDIR.items()}
HEAD = ['build', 'TPS', 'speedup<br>over<br>upstream', '% of<br>no-pgss', 'CV', 'TPS<br>trend',
        'allocated<br>avg/max', 'recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m', 'popular<br>kept',
        'evictions<br>vs<br>upstream', 'back-<br>stop', 'text /<br>no-text', 'top waits']
# Each point is split in two tables, narrow enough for a page without scrolling
GROUPS = [('Throughput', [0, 1, 2, 3, 4, 5, 12]), ('Eviction', [0, 6, 7, 8, 9, 10, 11])]
LEGEND = """## How to read the tables

Each point has two tables, one row per build; no pgss is upstream run without
pg_stat_statements loaded.

- **TPS**, and the **speedup over upstream**: 2.0x is twice the TPS of upstream.
- **% of no-pgss**: the TPS of the build as a share of the TPS of no pgss on
  the same instance.
- **CV**: how much TPS varies within the run.
- **TPS trend**: the mean TPS of the last fifth of the run against the first
  fifth; in bold below -5%.
- **top waits**: the most frequent wait events of the active backends, as a
  share of samples, 1% or more; CPU is a backend running, not waiting.
- **allocated avg/max**: entries held by the stats kind, including dropped
  ones not freed yet.
- **recency**: entries of the view by how long ago they were created, on
  average over the run.
- **popular kept**: the fewest of the 4000 popular statements in the view.
- **evictions vs upstream**: eviction passes per transaction, against
  upstream: -27% is 27% fewer.
- **backstop**: share of the run at twice `pg_stat_statements.max`, where new
  statements are not tracked.
- **text / no-text**: size of the query text storage, in the file or in
  shared memory, and the most entries without a text.

Under each point, TPS by fifth of the run for each build, and for the
hotcold workloads the entries of the view by how long ago they were
created.

Workloads: hotcold_100m runs 4000 popular statements and 100 million others;
hotcold_1500 runs 4000 popular statements and 1500 others; select_only runs
pgbench `-S`; SELECT 1 is `SELECT 1;` with the simple protocol.
"""


def waits(path):
    """The wait events of a run, 1% or more of active backend samples."""
    n, tot = collections.Counter(), 0
    try:
        for line in open(path):
            f = line.rstrip('\n').split('\t')
            if len(f) < 4 or not f[3].isdigit():
                continue
            k = 'CPU' if not f[1] else f'{f[1]}:{f[2]}'
            n[k] += int(f[3])
            tot += int(f[3])
    except OSError:
        return ''
    if not tot:
        return ''
    # Long names on two lines, to keep the column narrow
    return '<br>'.join(f'{100 * c / tot:.0f}% ' +
                       (k.replace(':', ':<br>&nbsp;&nbsp;') if len(k) > 16 else k)
                       for k, c in n.most_common(3) if 100 * c / tot >= 1)


def stats_of(s):
    if len(s) < 10:
        return '', 0
    q = max(len(s) // 5, 1)
    cv = 100 * statistics.pstdev(s) / statistics.mean(s)
    return f'{cv:.1f}%', 100 * (statistics.mean(s[-q:]) / statistics.mean(s[:q]) - 1)


def trend(tr):
    t = f'{tr:+.1f}%'.replace('-', '−')
    return f'**{t}**' if tr < -5 else t


def ktps(x):
    return f'{x / 1000:,.1f}k' if x < 1e6 else f'{x / 1e6:,.2f}M'


def vs(ratio):
    return f'−{100 * (1 - ratio):.0f}%' if ratio < 1 else f'+{100 * (ratio - 1):.0f}%'


def table(head, rows):
    used = [i for i in range(len(head)) if i == 0 or any(r[i] for r in rows)]
    if len(used) <= 1:
        return []
    return (['| ' + ' | '.join(head[i] for i in used) + ' |', '|' + ':---:|' * len(used)] +
            ['| ' + ' | '.join(str(r[i]) for i in used) + ' |' for r in rows])


def block(title, rows):
    out = [f'#### {title}', '']
    for name, idx in GROUPS:
        t = table([HEAD[i] for i in idx], [[r[i] for i in idx] for r in rows])
        if t:
            out += [f'*{name}*', ''] + t + ['']
    return out


def charts(point, names, wl):
    """TPS by fifth of the run, and entries by recency, for one point."""
    out, tps = [], []
    for n in names:
        f = rd.fifths(point[n]['progress'])
        for i, x in enumerate(f):
            d = '' if i == 0 else f' {100 * (x / f[0] - 1):+5.1f}%'
            tps.append((f'{n if i == 0 else "":8} fifth {i + 1}', x, d))
    if tps:
        top = max(v for _, v, _ in tps)
        out += ['TPS over the run, by fifth (change from the first fifth):', '', '```']
        out += [f'{l:18} {"#" * round(40 * v / top):40} {v / 1000:9.1f}k{d}' for l, v, d in tps]
        out += ['```', '']
    if wl not in ('sel', 'select1'):
        lab = dict(zip(rd.AGES, ('<1s', '1-10s', '10s-1min', '1-5min', '>5min')))
        rows = [(f'{lab[b] if i == 0 else "":9} {n:8}', point[n]['age'].get(b, 0))
                for b in rd.AGES for i, n in enumerate(names)]
        if any(v for _, v in rows):
            out += ['Entries of the view by how long ago they were created (40 # = 5000):',
                    '', '```']
            out += [f'{l} {"#" * round(40 * v / 5000):40} {v:.0f}' for l, v in rows]
            out += ['```', '']
    return out


def instances(fleet):
    return rd.tsv(f'{fleet}/instances.tsv')


def fleet_section(fleet, labels, archives):
    pts = rd.fleet(fleet, labels)
    insts = instances(fleet)
    secs = {r['duration_s'] for i in insts for r in rd.tsv(f"{fleet}/{i['type']}.summary.tsv")
            if r.get('duration_s')}
    length = ', '.join(f'{int(float(s)) // 60} min' for s in sorted(secs, key=float))
    types = ', '.join(i['type'] for i in sorted(insts, key=lambda i: int(i['vcpus'])))
    out = [f'## {types}, {length} per build', '', f'Fleet `{os.path.basename(fleet)}`.', '']
    vcpus = lambda m: int(re.search(r'\((\d+) vCPUs\)', m).group(1))
    cur = None
    for key in sorted(pts, key=lambda x: (vcpus(x[0]), x[1], x[2])):
        b = pts[key]
        if 'upstream' not in b:
            continue
        inst = key[0].split()[0]
        info = next(i for i in insts if i['type'] == inst)
        commits = {'upstream': info['base_commit'], labels.get(info['patch_commit'][:7],
                   info['patch_commit'][:7]): info['patch_commit']}
        for c in (info.get('extra_commits') or '').split():
            commits[labels.get(c[:7], c[:7])] = c
        if inst != cur:
            cur = inst
            out += [f'### {inst}, {vcpus(key[0])} vCPUs', '']
        names = ['upstream'] + sorted(n for n in b if n != 'upstream')
        rows, up = [], b['upstream']
        for n in names:
            p, d = b[n], rd.datapoints(b[n], up, key[1])
            cv, tr = stats_of(p['progress'])
            hit = glob.glob(f"{archives}/{info['run_id']}/{info['run_id']}/"
                            f"{commits.get(n, '')[:12]}*/{WLDIR[key[1]]}/c{key[2]}/waits.tsv")
            size, where = p['text']
            churn = key[1] not in ('sel',)
            rows.append([n, ktps(p['tps']), f"{p['tps'] / up['tps']:.1f}x", '', cv, trend(tr),
                         d['alloc'] if n != 'upstream' else '', d['age'] if churn else '',
                         d['popular'] if churn else '',
                         vs(float(d['vs'][:-1])) if n != 'upstream' and d['vs'] != '-' else '',
                         d['backstop'] if n != 'upstream' else '',
                         f"{size / 1048576:.1f}MB{'<br>' + where if where else ''} / {d['notext']}",
                         waits(hit[0]) if hit else ''])
        cl = f"{key[2]} client{'s' if key[2] > 1 else ''}"
        out += block(f'{inst} · {WLNAME.get(key[1], key[1])}, {cl}', rows)
        out += charts(b, names, key[1])
    return out


def compare_section(run, title, labels, archives):
    """The builds of a profile run, one throughput table per point."""
    root = f'{archives}/{run}/{run}'
    points = collections.defaultdict(dict)
    for d in sorted(glob.glob(f'{root}/*/*/c*')):
        build, wl, cl = d.split('/')[-3:]
        label, commit = build.rsplit('-', 1)
        name = ('no pgss' if label.endswith('-nopgss') else 'upstream' if label == 'upstream'
                else labels.get(commit[:7], label))
        log = open(f'{d}/pgbench.log').read()
        m = re.search(r'^tps = ([\d.]+)', log, re.M)
        if not m:
            continue
        s = [float(x) for x in re.findall(r'^progress: \S+ s, ([\d.]+) tps', log, re.M)][1:]
        dealloc = re.search(r'^\s*(\d+)\s*\|', open(f'{d}/pgss_info.out').read(), re.M) \
            if os.path.exists(f'{d}/pgss_info.out') else None
        points[(wl, int(cl[1:]))][name] = {'tps': float(m.group(1)), 'progress': s,
                                           'waits': waits(f'{d}/waits.tsv'),
                                           'dealloc': int(dealloc.group(1)) if dealloc else None}
    out = []
    for (wl, cl), b in sorted(points.items()):
        up, core = b.get('upstream'), b.get('no pgss')
        rows = []
        for n in ['upstream'] + sorted(x for x in b if x not in ('upstream', 'no pgss')) + ['no pgss']:
            if n not in b:
                continue
            p = b[n]
            cv, tr = stats_of(p['progress'])
            ev = ''
            if up and n not in ('upstream', 'no pgss') and p['dealloc'] and up['dealloc']:
                ev = vs((p['dealloc'] / p['tps']) / (up['dealloc'] / up['tps']))
            rows.append([n, ktps(p['tps']),
                         f"{p['tps'] / up['tps']:.1f}x" if up and n != 'no pgss' else '',
                         f"{100 * p['tps'] / core['tps']:.0f}%" if core else '',
                         cv, trend(tr), '', '', '', ev, '', '', p['waits']])
        out += block(f"{title} · {WLNAME.get(WLKEY.get(wl, wl), wl)}, {cl} clients", rows)
    return out


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument('--title', default='pg_stat_statements benchmark')
    ap.add_argument('--header')
    ap.add_argument('--archives', default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                       'ec2-setup', 'results', 'archive'))
    ap.add_argument('--label', action='append', default=[])
    ap.add_argument('--fleet', action='append', default=[])
    ap.add_argument('--compare', action='append', default=[])
    a = ap.parse_args()
    labels = {k[:7]: v for k, v in (x.split('=', 1) for x in a.label)}
    out = [f'# {a.title}', '']
    if a.fleet:
        i = instances(a.fleet[0])[0]
        commits = [('upstream', i['base_commit'])] + [
            (labels.get(c[:7], c[:7]), c) for c in [i['patch_commit']] + i['extra_commits'].split()]
        out += ['| | |', '|:---:|:---:|'] + [f'| {n} | `{c[:7]}` |' for n, c in sorted(commits)]
        out += ['| no pgss | upstream, run without pg_stat_statements loaded |', '']
    if a.header:
        out += [open(a.header).read().rstrip(), '']
    out += [LEGEND]
    for f in a.fleet:
        out += fleet_section(f.rstrip('/'), labels, a.archives)
    if a.compare:
        out += ['## Builds back to back on one instance, with and without pg_stat_statements', '']
        for c in a.compare:
            run, title = c.split('=', 1) if '=' in c else (c, c)
            out += compare_section(run, title, labels, a.archives)
    print('\n'.join(out))


if __name__ == '__main__':
    main()
