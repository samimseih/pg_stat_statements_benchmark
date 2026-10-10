# pg_stat_statements benchmark suite

This benchmark compares pg_stat_statements behavior across two PostgreSQL
commits under statement churn and a cache-resident pgbench workload.

The default comparison is:

- patched: `fbef23389f1`
- baseline: `3051c223a60`

The runner rebuilds each commit, creates a fresh local cluster, enables
`pg_stat_statements`, and runs the same client-count ladder for each workload.

## Requirements

The runner uses PostgreSQL's Meson/Ninja build and the `~/build` helper from
the public `pg-build` repository:

```text
https://github.com/samimseih/pg-build
```

`~/build` is used to recreate and start a fresh local cluster after each
commit is installed.  The path can be changed with `BUILD_WRAPPER`.

## Workloads

Client counts:

```sh
1 2 4 8 16 32 64 128 256
```

Protocol:

- hot/cold workloads use `-M simple`, because the CTE name changes per
  transaction and must be substituted into the query text.
- `select_only` uses `-M prepared`.

Workloads:

- `hotcold_100m`: 90% of executions choose from 4000 popular query texts,
  10% choose from 100000000 unpopular IDs. Duration: 60 seconds.
- `hotcold_1500`: 90% choose from 4000 popular query texts, 10% choose from
  1500 unpopular IDs. Duration: 60 seconds.
- `select_only`: pgbench `-S` after `pgbench -i -s 100`. Duration: 120
  seconds.

The hot/cold workloads use query names like `CTEPOP_123` and `CTEUNPOP_456`
so the analyzer can report retention for popular and unpopular entries.

## What gets captured

For each timed run the script records:

- pgbench output
- `pg_stat_activity` wait events once per second
- a monitoring-like `pg_stat_statements` scan once every 10 seconds
- `vmstat`, if available
- `pidstat`, if available
- `iostat`, if available
- final `benchmark_analyze.sql` output

The runner also appends one row per run to `summary.tsv`.

## Run

From this directory:

```sh
./run_pgss_benchmark_suite.sh
```

Useful overrides:

```sh
COMMITS="fbef23389f1 3051c223a60" ./run_pgss_benchmark_suite.sh
CLIENTS="32 64 128 256" ./run_pgss_benchmark_suite.sh
RESULT_ROOT=/tmp/pgss_results ./run_pgss_benchmark_suite.sh
```

Defaults assume this local layout:

```sh
PG_WORKTREE=$HOME/pgdev/installations/worktrees/dev
PREFIX=$HOME/pgdev/installations
WORKTREE_NAME=dev
PGPORT=5432
PGUSER=postgres
PGDATABASE=postgres
```

The build/reset recipe per commit is:

```sh
git checkout <commit>
ninja -C build clean
ninja -C build install
~/build --skip-build --worktree-name dev --release
```

After the cluster is recreated, the script sets:

```sql
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
ALTER SYSTEM SET pg_stat_statements.max = 5000;
ALTER SYSTEM SET max_connections = 300;
```

Then it restarts the cluster and creates the extension.

## Results

Results are written under:

```sh
results/<timestamp>/
```

Layout:

```text
summary.tsv
<commit>/<workload>/c<clients>/
  meta.txt
  pgbench.log
  waits.tsv
  monitor_pgss.tsv
  vmstat.log
  pidstat.log
  iostat.log
  analyze.out
```

`summary.tsv` contains the quick comparison columns:

```text
commit  workload  clients  threads  duration_s  status  tps  latency_avg_ms  failed  outdir
```

The raw logs are kept so the run can be inspected later without rerunning the
suite.
