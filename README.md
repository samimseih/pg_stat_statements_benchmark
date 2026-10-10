# pg_stat_statements benchmark suite

This benchmark compares pg_stat_statements behavior across two PostgreSQL
commits under statement churn and a cache-resident pgbench workload.  It is
intended to measure both throughput and retention: popular statements should
remain visible while unpopular statements churn, and entry/query-text counts
should stay bounded.

The default commit list lives in `run_pgss_benchmark_suite.sh` and can be
overridden with `COMMITS`.

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
- `select_only`: pgbench `-S` after `pgbench -i -s 10`. Duration: 120
  seconds.

The hot/cold workloads use query names like `CTEPOP_123` and `CTEUNPOP_456`
so the analyzer can report retention for popular and unpopular entries.

## What gets captured

For each timed run the script records:

- pgbench output
- `pg_stat_activity` wait events once per second
- a monitoring-like `pg_stat_statements` retention scan once every 5 seconds
- `vmstat`, if available
- `pidstat`, if available
- `iostat`, if available
- final `benchmark_analyze.sql` output

The 5-second retention scan groups statements into `pop`, `unpop`,
`select_only`, `other`, and `null_query` buckets.  It also records
`pg_stat_statements_info` counters when the tested commit exposes them.  This
keeps the run honest about whether the cache is preserving the useful
statements, not just producing good TPS.

The runner also appends one row per run to `summary.tsv`.

## Run

From this directory:

```sh
./run_pgss_benchmark_suite.sh
```

To run it in the background inside `tmux`:

```sh
./start_pgss_benchmark_suite.sh
```

The background runner writes to `suite.tmux.log` and uses the `pgss_bench`
tmux session by default.

Useful overrides:

```sh
COMMITS="patched_commit baseline_commit" ./run_pgss_benchmark_suite.sh
CLIENTS="32 64 128 256" ./run_pgss_benchmark_suite.sh
PGSS_SAMPLE_SECONDS=5 ./run_pgss_benchmark_suite.sh
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
  waits.err
  monitor_pgss.tsv
  monitor_pgss.err
  vmstat.log
  pidstat.log
  iostat.log
  analyze.out
  analyze.err
  server_log_tail.log
```

`summary.tsv` starts with the throughput columns:

```text
commit  workload  clients  threads  duration_s  status  tps  latency_avg_ms  failed
```

It also includes high-water retention columns:

```text
max_entries  max_pop_entries  max_unpop_entries  max_select_entries
max_other_entries  max_entry_dealloc  max_entry_dsa_size
max_qtext_dsa_size  max_qtext_count  max_qtext_total_len  outdir
```

The raw logs are kept so the run can be inspected later without rerunning the
suite.
