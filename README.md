# pg_stat_statements benchmark suite

This benchmark compares pg_stat_statements behavior across two PostgreSQL
commits under statement churn and a cache-resident pgbench workload.  It is
intended to measure both throughput and retention: popular statements should
remain visible while unpopular statements churn, and entry/query-text counts
should stay bounded.

The default commit list lives in `run_pgss_benchmark_suite.sh` and can be
overridden with `COMMITS`.

The runner checks out each commit, installs from a release/perf Meson build,
creates a fresh local cluster, enables `pg_stat_statements`, and runs the
configured client-count ladder for each workload.

## Published Results

| date | run | benchmark | comparison | headline | results |
| --- | --- | --- | --- | --- | --- |
| 2026-10-16 | EC2 `c7i.8xlarge` | `hotcold_100m` churn and `select_only`, clients `1..256`, 1600 seconds per point | `pg_stat_statements_v14` with default `query_text_memory` vs PostgreSQL master | Churn TPS improved by up to +109.9%; `select_only` stayed between -4.3% and +3.9%. Popular retention held at 4000/4000, patched `qtext_count` high-water was 5,501, and baseline sampled 410,946 `pg_stat_statements` LWLock waits while patched sampled 0. | [report](reports/2026-10-16-ec2-c7i-8xlarge.md) |
| 2026-10-17 | EC2 `c7i.8xlarge` | `hotcold_100m` churn and `select_only`, clients `1..256`, 1600 seconds per point | `pg_stat_statements_v14` with `query_text_memory=1GB` vs PostgreSQL master | Churn TPS improved by up to +105.3%; `select_only` stayed between -2.9% and +0.7%. Popular retention held at 4000/4000, patched `qtext_count` high-water was 5,501, and baseline sampled 409,092 `pg_stat_statements` LWLock waits while patched sampled 0. | [report](reports/2026-10-17-ec2-c7i-8xlarge-qtext1gb.md) |

Retention and memory triples in the reports are sampled `min/avg/max` values;
memory values are shown in human-readable units.

## Requirements

The runner uses PostgreSQL's Meson/Ninja build.  By default it expects the
worktree to have a release build directory at:

```sh
$PG_WORKTREE/build-release
```

The build directory can be changed with `BUILD_DIR`.  Before each commit is
installed, the runner checks the Meson configuration and refuses to continue if
the build is not suitable for perf testing:

```text
debug=false
optimization != 0
b_ndebug=true
cassert=false
```

The runner recreates the local data directory itself after each install.  It
does not use the `~/build` helper.

## Workloads

Default client counts:

```sh
1 2 4 8 16 32 64 128 256
```

`CLIENTS` controls the hot/cold workloads.  `SELECT_CLIENTS` controls
`select_only` and defaults to the same list.

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

The default durations can be changed with `HOTCOLD_SECONDS` and
`SELECT_SECONDS`.  Individual workload groups can be disabled with
`RUN_HOTCOLD_100M=0`, `RUN_HOTCOLD_1500=0`, or `RUN_SELECT_ONLY=0`.

## What gets captured

For each timed run the script records:

- pgbench output
- `pg_stat_activity` wait events once per second
- a monitoring-like `pg_stat_statements` retention scan once every 5 seconds
- `vmstat`, if available
- `pidstat`, if available
- `iostat`, if available
- final `benchmark_analyze.sql` output

The retention scan waits briefly after each run starts, then samples every 5
seconds by default.  It groups statements into `pop`, `unpop`, `select_only`,
`other`, and `null_query` buckets.  It also records
`pg_stat_statements_info` counters when the tested commit exposes them.  The
summary reports sampled min/avg/max values for entries, retention buckets,
entry DSA, and query-text storage.  This keeps the run honest about whether the
cache is preserving useful statements, not just producing good TPS.

After each pgbench run, the runner also captures `pg_stat_statements_info`
into `final_info.tsv` before running any expensive full-view analysis.  Those
final gauges still work when `pg_stat_statements` has too many rows for the
view scan to materialize.

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
SELECT_CLIENTS="1 2 4 8 16 32 64 128 256" ./run_pgss_benchmark_suite.sh
HOTCOLD_SECONDS=300 SELECT_SECONDS=300 ./run_pgss_benchmark_suite.sh
RUN_HOTCOLD_1500=0 ./run_pgss_benchmark_suite.sh
PGSS_SAMPLE_SECONDS=5 ./run_pgss_benchmark_suite.sh
PGSS_QUERY_TEXT_MEMORY=1GB ./run_pgss_benchmark_suite.sh
RESULT_ROOT=/tmp/pgss_results ./run_pgss_benchmark_suite.sh
```

Defaults assume this local layout:

```sh
PG_WORKTREE=$HOME/pgdev/installations/worktrees/dev
PREFIX=$HOME/pgdev/installations
WORKTREE_NAME=dev
BUILD_DIR=$PG_WORKTREE/build-release
PGPORT=5432
PGUSER=postgres
PGDATABASE=postgres
```

The build/reset recipe per commit is:

```sh
git checkout <commit>
meson configure "$BUILD_DIR"   # verify release/perf settings
ninja -C "$BUILD_DIR" clean
ninja -C "$BUILD_DIR" install
rm -rf "$PGDATA"
initdb -D "$PGDATA" -U "$PGUSER" --data-checksums
pg_ctl -D "$PGDATA" -l "$PGDATA/logfile" -w start
```

After the cluster is recreated, the script sets:

```sql
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
ALTER SYSTEM SET pg_stat_statements.max = 5000;
ALTER SYSTEM SET max_connections = 300;
```

Set `PGSS_QUERY_TEXT_MEMORY` to also set
`pg_stat_statements.query_text_memory` for patches that expose that GUC.

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
  final_info.tsv
  final_info.err
  analyze.out
  analyze.err
  server_log_tail.log
```

`summary.tsv` starts with the throughput columns:

```text
commit  workload  clients  threads  duration_s  status  tps  latency_avg_ms  failed
```

It also includes retention, churn, and storage columns:

```text
max_entries  max_pop_entries  max_unpop_entries  max_select_entries
max_other_entries  max_entry_dealloc
min_entry_dsa_size  max_entry_dsa_size
min_qtext_dsa_size  max_qtext_dsa_size
min_qtext_count  max_qtext_count
min_qtext_total_len  max_qtext_total_len
sample_count
avg_entries  avg_pop_entries  avg_unpop_entries
avg_select_entries  avg_other_entries
avg_qtext_count  avg_qtext_total_len
min_entries  min_pop_entries  min_unpop_entries
min_select_entries  min_other_entries
avg_entry_dsa_size  avg_qtext_dsa_size
final_entry_dealloc  final_entry_count  final_entry_dsa_size
final_qtext_dsa_size  final_qtext_count  final_qtext_total_len
outdir
```

The raw logs are kept so the run can be inspected later without rerunning the
suite.

## Report

Generate a Markdown report from a completed result directory:

```sh
./report_pgss_benchmark.sh results/<timestamp> > report.md
```

If no result directory is passed, the newest `results/<timestamp>` directory is
used.  The report starts with a short summary, then prints run metadata,
per-workload throughput tables, retention tables, query-text/churn counters,
memory gauges, and wait-event summaries.  Retention and memory columns that
show three values use `min/avg/max` from the periodic samples.  The Markdown
report prints memory in human-readable units; `summary.tsv` keeps raw byte
counts for scripts.  The report labels the first commit in `summary.tsv` as
`patched` and the second as `baseline`.  `PATCHED_LABEL`, `BASELINE_LABEL`,
`PATCHED_URL`, and `BASELINE_URL` can be set when generating a published
report.  Reports include a final-gauges table from `pg_stat_statements_info`;
that table is preferred for end-of-run memory and entry counts because it does
not scan the full `pg_stat_statements` view.  The wait-event `cpu/no wait`
column is active backends with no PostgreSQL wait event reported; it is not
sampled from OS CPU counters.
