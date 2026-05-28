# pg_stat_statements Benchmark

A/B test `pg_stat_statements` patches. Point it at two commits, it builds
both, runs pgbench workloads, and reports TPS + lock contention so you can
see whether your change helps or regresses.

## Setup

1. Clone a PostgreSQL source tree somewhere (this is the repo worktrees are created from):
   ```bash
   git clone https://git.postgresql.org/git/postgresql.git ~/pg/source
   ```

2. Configure paths in `bench_config.local.sh` (gitignored):
   ```bash
   PG_SOURCE_DIR="$HOME/pg/source"
   PG_WORKTREES_DIR="$HOME/pg/worktrees"
   PG_INSTALL_DIR="$HOME/pg/install"
   PG_DATA_DIR="$HOME/pg/data"
   BENCH_RESULTS_DIR="$HOME/pg/results"
   ```

3. Prerequisites: `meson`, `ninja`, and (on Linux) `sudo` for CPU hotplug.

## Quick Start

**Compare two commits** (first = baseline, second = patch):

```bash
# Build both, run select1 + churn for 30s each, 64 clients
./scripts/bench_matrix.sh -k <baseline>,<patch> -c 64 -w select1,churn -d 30
```

**Run against an already-running server** (simplest possible use):

```bash
./bench.sh -d 30 -c 64 -w churn -p 5433
```

**Full suite** (select1, churn, slow_churn, within_max across client/CPU counts, ~3.4 hours):

```bash
./examples/run_full_benchmark.sh -k <baseline>,<patch>
```

## Sample Output

```
=== pg_stat_statements benchmark ===
Duration: 30s, Clients: 64, Jobs: 16, Protocol: simple, Port: 5433
Workloads: select1 churn
Machine: Apple M4 Pro, 48GB RAM

--- select1 [clients=64 jobs=16 proto=simple duration=30s] ---
  t=5s   entries=5     tps=93592    dealloc=0        age=[5s..5s avg=5s sd=0s] calls=[476182..476182 avg=476182 sd=0] fp=ea450de1 waits=[CPU(16) ]
  t=11s  entries=6     tps=117667   dealloc=0        age=[11s..11s avg=11s sd=0s] calls=[1066647..1066647 avg=1066647 sd=0] fp=ea450de1 waits=[CPU(15) ]
  t=16s  entries=6     tps=119589   dealloc=0        age=[16s..16s avg=16s sd=0s] calls=[1793274..1793274 avg=1793274 sd=0] fp=ea450de1 waits=[CPU(22) ]
  ...
  db_time: idle=93.0% db=7.0% (CPU=100.0%) (125 active samples over 28s, 64 clients)
  TPS: 118274
  deallocs: 0

--- churn [clients=64 jobs=16 proto=simple duration=30s] ---
  t=5s   entries=5005  hot=1000  cold=4003  tps=75697   dealloc=5        age=[1s..5s avg=5s sd=0s] calls=[1..362 avg=63 sd=122] fp=a7b9cc21 waits=[CPU(42) ]
  t=11s  entries=5009  hot=1000  cold=4008  tps=67670   dealloc=11       age=[1s..11s avg=11s sd=0s] calls=[1..658 avg=118 sd=231] fp=493d971f waits=[CPU(64) ]
  t=16s  entries=4867  hot=1000  cold=3866  tps=66274   dealloc=16       age=[1s..16s avg=12s sd=6s] calls=[1..1017 avg=182 sd=359] fp=fb84859e waits=[CPU(60) ]
  ...
  db_time: idle=82.5% db=17.5% (CPU=98.7% LWLock:pg_stat_statements=1.3%) (313 active samples over 28s, 64 clients)
  TPS: 70494
  FINAL: entries=4506 hot=1000 cold=3500 hot_calls=1686122 cold_calls=13148
  deallocs: 31
  histogram: 1:789 2-5:1849 6-20:861 >1k:1000

=== TPS Summary ===
  select1         118274
  churn           70494
```

### Reading the sampling line

Each line is a snapshot taken every 5 seconds:

| Field | Meaning |
|-------|---------|
| `entries` | Current entry count in pg_stat_statements |
| `hot/cold` | Entries with many vs. few calls (churn workloads) |
| `tps` | Transactions per second (from pgbench progress) |
| `dealloc` | Cumulative eviction cycles |
| `age=[youngest..oldest avg sd]` | Age distribution of entries (seconds since creation) |
| `calls=[min..max avg sd]` | Call count distribution across entries |
| `fp` | 8-char fingerprint of the entry set (changes = entries churned) |
| `waits=[...]` | Wait event samples (what backends are blocked on) |

## How It Works

```
examples/run_full_benchmark.sh       # orchestrates everything
  |-- switch_build.sh -c .. -w ..   # create worktree
  |-- switch_build.sh -w .. -b ..   # build
  |-- scripts/bench_matrix.sh        # iterates commits x clients x CPUs
  |     |-- switch_build.sh -w ..   # start cluster for this commit
  |     +-- bench.sh                 # run pgbench + poll stats
  +-- (repeat for each pgss.max setting)

analysis/analyze_matrix.sh           # generate markdown report from results
analysis/perf/                       # CPU profiling (record, report, compare)
```

## Configuration

`bench_config.sh` defines base directories. Scripts append the worktree name:

| Variable | Default | Resulting path |
|----------|---------|----------------|
| `PG_SOURCE_DIR` | `~/pg/source` | (as-is) |
| `PG_WORKTREES_DIR` | `~/pg/worktrees` | `~/pg/worktrees/<name>` |
| `PG_INSTALL_DIR` | `~/pg/install` | `~/pg/install/<name>` |
| `PG_DATA_DIR` | `~/pg/data` | `~/pg/data/<name>` |
| `BENCH_RESULTS_DIR` | `~/pg/results` | `~/pg/results/pgss_<timestamp>` |

Override via `bench_config.local.sh` (gitignored) or environment variables.

## Scripts Reference

### bench.sh

Run workloads against a server. The core script everything else calls.

```
./bench.sh -d 30 -c 64 -w churn -p 5433
  -d DURATION    Seconds per workload (default: 30)
  -c CLIENTS     pgbench clients (default: 64)
  -w WORKLOADS   Comma-separated (default: select1,churn,slow_churn,within_max)
  -M PROTOCOL    simple|extended|prepared (default: simple)
  -S SLEEP_MS    Add \sleep per iteration (default: 0 = none)
  -C CPUS        Set online CPU count (Linux, restores on exit)
  -p PORT        PostgreSQL port (default: 5432)
  -n             Dry-run
```

### switch_build.sh

Manage worktrees, builds, and clusters as separate steps:

```
./switch_build.sh -c <commit> -w <name>              # create worktree
./switch_build.sh -w <name> --patch <file>           # apply patch to worktree
./switch_build.sh -w <name> -b release               # build (or rebuild)
./switch_build.sh -w <name> [-m 5000] [-p 5433]     # start cluster
./switch_build.sh -w <name> --recreate-cluster       # re-initdb and start
./switch_build.sh --remove -w <name>                 # tear down
```

Typical workflow:
```bash
./switch_build.sh -c a21bd27 -w lru                  # 1. create worktree
./switch_build.sh -w lru --patch my_fix.patch        # 2. apply patch (optional)
./switch_build.sh -w lru -b release                  # 3. build
./switch_build.sh -w lru -m 5000 -p 5433            # 4. start cluster
source ~/pg/install/lru/env.sh                       # 5. activate environment
./switch_build.sh --remove -w lru                    # 6. tear down
```

Use `--recreate-cluster` when switching to a build that changed GUCs (e.g.
`pg_stat_statements.max` → `pg_stat_statements.stats_size`) and you need a
fresh `postgresql.conf`.

Starting a cluster generates an `env.sh` script that sets `PATH`, `PGDATA`,
`PGPORT`, `PGHOST`, `PGDATABASE`, `PGUSER`, and `LD_LIBRARY_PATH` so that
`psql`, `pg_ctl`, etc. work without extra flags.

### scripts/bench_matrix.sh

Run benchmarks across a matrix of commits, client counts, and CPU counts.

```
./scripts/bench_matrix.sh -k <commits> -c 64,256 -C 16,96 -w churn -d 180
```

### analysis/analyze_matrix.sh

Generate a markdown report comparing commits from matrix results.

```
./analysis/analyze_matrix.sh ~/pg/results/pgss_matrix_*
```

## Workloads

| Name | What it tests |
|------|---------------|
| `select1` | Pure overhead, no eviction, measures baseline cost |
| `churn` | 80% hot / 20% cold queries, heavy eviction stress |
| `within_max` | 4500 distinct queries in transactions, stays under pgss_max |
| `slow_churn` | 1 new query every ~5s, tests near-capacity admission |

Use `-S 100` with any workload to add a 100ms think time per iteration (realistic OLTP pacing).

## Perf Profiling

Record CPU profiles during benchmarks and compare across commits:

```bash
# Record while a benchmark is running
./analysis/perf/record.sh -p 5433 -w lfu -d 10

# View top functions
./analysis/perf/report.sh ~/tmp/perf_lfu_*.data

# Compare baseline vs patch
./analysis/perf/compare.sh ~/tmp/perf_baseline_*.data ~/tmp/perf_lfu_*.data
```

## Running Against an Existing Cluster

If you have a running PostgreSQL (not built from source), use `bench.sh` directly:

```bash
./bench.sh -d 60 -c 64 -w churn -p 5432
```

Requirements: `pg_stat_statements` in `shared_preload_libraries`, the extension
created in the target database, and sufficient `max_connections`.
