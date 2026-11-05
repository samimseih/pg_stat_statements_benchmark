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

The README keeps only an index.  The linked pages have the actual analysis:
throughput, retention, query-text memory, and wait-event diffs.

The 2026-11-04 runs compare PostgreSQL master with pg_stat_statements
v4/no-partition custom cumulative stats kind.

| date | branch | commit | run | results |
| --- | --- | --- | --- | --- |
| 2026-11-04 | [`pgss-bench-v4-no-partition-a1d859`](https://github.com/samimseih/postgres/tree/pgss-bench-v4-no-partition-a1d859) | [`a1d85934da2e`](https://github.com/samimseih/postgres/commit/a1d85934da2ed06ed216615b1d063a23a808f5ac) | EC2 `c7i.large`, 300 seconds per point, clients `1..512` | [analysis](reports/2026-11-04-ec2-c7i-large-pgss-v4-a1d859-300s.md) |
| 2026-11-04 | [`pgss-bench-v4-no-partition-a1d859`](https://github.com/samimseih/postgres/tree/pgss-bench-v4-no-partition-a1d859) | [`a1d85934da2e`](https://github.com/samimseih/postgres/commit/a1d85934da2ed06ed216615b1d063a23a808f5ac) | EC2 `c7i.2xlarge`, 300 seconds per point, clients `1..512` | [analysis](reports/2026-11-04-ec2-c7i-2xlarge-pgss-v4-a1d859-300s.md) |
| 2026-11-04 | [`pgss-bench-v4-no-partition-a1d859`](https://github.com/samimseih/postgres/tree/pgss-bench-v4-no-partition-a1d859) | [`a1d85934da2e`](https://github.com/samimseih/postgres/commit/a1d85934da2ed06ed216615b1d063a23a808f5ac) | EC2 `c7i.4xlarge`, 300 seconds per point, clients `1..512` | [analysis](reports/2026-11-04-ec2-c7i-4xlarge-pgss-v4-a1d859-300s.md) |
| 2026-11-04 | [`pgss-bench-v4-no-partition-a1d859`](https://github.com/samimseih/postgres/tree/pgss-bench-v4-no-partition-a1d859) | [`a1d85934da2e`](https://github.com/samimseih/postgres/commit/a1d85934da2ed06ed216615b1d063a23a808f5ac) | EC2 `c7i.8xlarge`, 300 seconds per point, clients `1..512` | [analysis](reports/2026-11-04-ec2-c7i-8xlarge-pgss-v4-a1d859-300s.md) |
| 2026-11-04 | [`pgss-bench-v4-no-partition-a1d859`](https://github.com/samimseih/postgres/tree/pgss-bench-v4-no-partition-a1d859) | [`a1d85934da2e`](https://github.com/samimseih/postgres/commit/a1d85934da2ed06ed216615b1d063a23a808f5ac) | EC2 `c7i.16xlarge`, 300 seconds per point, clients `1..512` | [analysis](reports/2026-11-04-ec2-c7i-16xlarge-pgss-v4-a1d859-300s.md) |
| 2026-11-04 | [`pgss-bench-v4-no-partition-a1d859`](https://github.com/samimseih/postgres/tree/pgss-bench-v4-no-partition-a1d859) | [`a1d85934da2e`](https://github.com/samimseih/postgres/commit/a1d85934da2ed06ed216615b1d063a23a808f5ac) | EC2 `c7i.24xlarge`, 300 seconds per point, clients `1..512` | [analysis](reports/2026-11-04-ec2-c7i-24xlarge-pgss-v4-a1d859-300s.md) |

Each result page compares the patched build with the PostgreSQL master
baseline from the same EC2 run.  Retention and memory triples in the reports
are sampled `min/avg/max` values; memory values are shown in human-readable
units.

## Requirements

The runner uses PostgreSQL's Meson/Ninja build.  By default
(`BUILD_MODE=archive`) it only reads `PG_WORKTREE`: each commit is exported
with `git archive`, built with `MESON_FLAGS` and installed under
`BENCH_ROOT/pghome` (default `/tmp/pgss_bench_suite`), once per commit and set
of flags.  Clusters are created under `BENCH_ROOT/pgdata` and listen on
`BENCH_PGPORT` (default 55433; an exported `PGPORT` is ignored), so the worktree, its build directories, and any dev
installation, cluster or server are left alone.  Uncommitted changes are not
benchmarked in this mode.

`BUILD_MODE=prebuilt` builds nothing: each commit must already be installed in
`PREFIX/pghome/WORKTREE_NAME-<sha>`, as `BUILD_MODE=worktree` installs commits
with `RUN_ORDER=interleaved`, and `PG_WORKTREE` is only read for commit names.
`BUILD_ONLY=1` stops after building and installing the commits.  The EC2 fleet
setup uses both to build once and ship the installations.

`BUILD_MODE=worktree` instead checks out each commit in `PG_WORKTREE`, which
must be clean, and builds it in `BUILD_DIR` (default
`$PG_WORKTREE/build-release`), installing under `PREFIX`.  The EC2 setup uses
this mode, so that a patch applied to the remote worktree is included.

Before each commit is installed, the runner checks the Meson configuration and
refuses to continue if the build is not suitable for perf testing:

```text
debug=false
optimization != 0
b_ndebug=true
cassert=false
```

The runner recreates the data directory itself after each install.  It does
not use the `~/build` helper.

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

- `hotcold_4000_100m`: 90% of executions choose from 4000 popular query texts,
  10% choose from a large cold/churn keyspace of 100000000 unpopular IDs.
  Duration: 300 seconds.
- `hotcold_4000_1500`: 90% choose from 4000 popular query texts, 10% choose from
  a bounded cold/churn keyspace of 1500 unpopular IDs. Duration: 300 seconds.
- `select_only`: pgbench `-S` after `pgbench -i -s 10`. Duration: 300
  seconds.

The hot/cold workloads use query names like `CTEPOP_123` and `CTEUNPOP_456`
so the analyzer can report retention for popular and unpopular entries.  In
reports, `pop/unpop` means sampled retained hot/popular entries and retained
cold/churn entries.

The default durations can be changed with `HOTCOLD_SECONDS` and
`SELECT_SECONDS`.  Individual workload groups can be disabled with
`RUN_HOTCOLD_4000_100M=0`, `RUN_HOTCOLD_4000_1500=0`, or `RUN_SELECT_ONLY=0`.

pgbench reports its progress every `PROGRESS_SECONDS` (default 2).  The
samples of each point are saved in `progress.tsv`, and
`report_tps_stability.sh` reports their spread (stddev, CV, percentiles) with a
histogram for unstable points, because the final TPS of a point averages over
phases that may differ.  `report_pgss_benchmark.sh` includes this report.

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
`other`, `null_query`, and `empty_query` buckets.  It also records
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

To launch the suite on EC2, see `ec2-setup/README.md`.  That wrapper creates
the AWS resources needed for an SSM-only benchmark instance, bootstraps a
release PostgreSQL build on the instance, runs this benchmark suite there, and
uploads the result tarball and cloud-init log to S3.

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
RUN_HOTCOLD_4000_1500=0 ./run_pgss_benchmark_suite.sh
RUN_ORDER=interleaved ./run_pgss_benchmark_suite.sh
PGSS_SAMPLE_SECONDS=5 ./run_pgss_benchmark_suite.sh
PGSS_QUERY_TEXT_MEMORY=1GB ./run_pgss_benchmark_suite.sh
RESULT_ROOT=/tmp/pgss_results ./run_pgss_benchmark_suite.sh
CPU_LIMIT=2 ./run_pgss_benchmark_suite.sh
CPU_SET=0-3,16-19 ./run_pgss_benchmark_suite.sh
```

`CPU_LIMIT=N` keeps only CPUs `0..N-1` online while measuring, and
`CPU_SET=LIST` the CPUs of a list such as `0-3,16-19`, for example to avoid SMT
siblings; set at most one.  This uses `set_cpus.sh`, which needs root or
passwordless sudo.  Builds run with all CPUs, the suite fails if the online CPUs
do not match, and all CPUs are restored when it exits, including on errors and
interrupts.  By default CPUs are left alone.

By default, `RUN_ORDER=commit_major` builds one commit and runs all selected
points for it before moving to the next commit.  `RUN_ORDER=interleaved` builds
each commit once into a commit-specific install prefix, then runs the workloads
back to back for each number of clients, alternating commits for each point,
with a fresh `initdb` for each point.  The numbers of clients run in ascending
order, or with `CLIENT_ORDER=outside_in` alternate the smallest and largest
left (1, 512, 2, 256, ...), so that both ends of the range have results early.

Defaults:

```sh
PG_WORKTREE=$HOME/pgdev/installations/worktrees/dev
BUILD_MODE=archive
BENCH_ROOT=/tmp/pgss_bench_suite
PREFIX=$BENCH_ROOT              # $HOME/pgdev/installations with BUILD_MODE=worktree
WORKTREE_NAME=dev
BENCH_PGPORT=55433
PGUSER=postgres
PGDATABASE=postgres
```

The build/reset recipe per commit is, with `BUILD_MODE=archive`:

```sh
git -C "$PG_WORKTREE" archive <commit> | tar -x -C <src>
meson setup <build> <src> --prefix=<install> $MESON_FLAGS
ninja -C <build> install
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
max_empty_query_entries  max_other_entries  max_entry_dealloc
min_entry_dsa_size  max_entry_dsa_size
min_qtext_dsa_size  max_qtext_dsa_size
min_qtext_count  max_qtext_count
min_qtext_total_len  max_qtext_total_len
sample_count
avg_entries  avg_pop_entries  avg_unpop_entries
avg_select_entries  avg_empty_query_entries  avg_other_entries
avg_qtext_count  avg_qtext_total_len
min_entries  min_pop_entries  min_unpop_entries
min_select_entries  min_empty_query_entries  min_other_entries
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
used.  The report starts with a short summary, then prints run metadata, a
workload/retention legend, per-workload throughput tables, retention tables,
query-text file and eviction tables, and wait-event summaries.  Retention and
query-text file columns that show three values use `min/avg/max` from the
periodic samples.  The Markdown report prints memory in human-readable units;
`summary.tsv` keeps raw byte counts for scripts.  The report labels the first
commit in `summary.tsv` as `patched` and the second as `baseline`.
`PATCHED_LABEL`, `BASELINE_LABEL`, `PATCHED_URL`, and `BASELINE_URL` can be set
when generating a published report.  The wait-event `cpu/no wait` column is
active backends with no PostgreSQL wait event reported; it is not sampled from
OS CPU counters.

`ec2-setup/analyze_results.sh` writes both `report.md` and `report.html` for
the fetched run.  The HTML report is standalone and convenient for temporary
S3/presigned-URL viewing.
