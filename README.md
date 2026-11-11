# pg_stat_statements benchmark

Benchmarks pg_stat_statements patch commits against upstream PostgreSQL under
statement churn, locally or on an EC2 fleet, and reports the same datapoints
for every point: TPS ratio and stability, trend, entries allocated, recency of
the entries, popular statements kept, eviction passes, time at the backstop, and
query text storage.

## With Claude Code

The `pgss-benchmark` skill (`.claude/skills/pgss-benchmark/SKILL.md`) runs the
whole thing: it agrees on the commits, machines and cost with you, starts the
runs, monitors them, and reports.  Clone the repository, start Claude Code in
it, and ask, for example:

> Benchmark commits A and B against upstream C on c7i.8xlarge and
> c7i.48xlarge.

> Benchmark commit A against upstream C locally, 32 vCPUs, 1, 32 and 256
> clients.

It writes the results as a Markdown page with every point of every run; the
published ones are listed below.

## Published results

| date | patches | machines | results |
| --- | --- | --- | --- |
| 2026-11-11 | 0003 `5a0d289` (texts in file), 0004 `7739f4e` (texts in memory), on upstream `ee7cfb9` (now `2231a2e` and `bf75591` on [pg_stat_statements_custom_kind_dsa_qtext](https://github.com/samimseih/postgres/tree/pg_stat_statements_custom_kind_dsa_qtext)), and core without pg_stat_statements | c7i.large, 2xlarge, 8xlarge, 24xlarge, 48xlarge; 5 min per point, 1 to 512 clients; long runs of 20 and 45 min | [results](reports/2026-11-11-results.md) |

## Claude Skill

What the skill runs, which can also be run directly:

- Workloads: `pgbench_hot_cold_4000_100m.sql`, `pgbench_hot_cold_4000_1500.sql`
  (4000 popular statements, 90% of the transactions, against 100M or 1500
  unpopular ones) and pgbench `-S`.
- Local: `local/bench.sh` builds the commits of a PostgreSQL checkout
  (`PG_SRC`) with Meson and runs a plan file; `local/status.sh` reports.
- EC2: `ec2-setup/launch_fleet.sh` launches one instance per type, each
  running `run_pgss_benchmark_suite.sh` and uploading its results to S3;
  `ec2-setup/fetch_fleet_status.sh` fetches them.  See `ec2-setup/README.md`.
- Report: `report_datapoints.py local <results>` or
  `report_datapoints.py fleet ec2-setup/results/fleet/<fleet>` while runs
  go; `report_page.py` for the results page of finished runs, after
  `ec2-setup/fetch_archives.sh` fetches their archives.
