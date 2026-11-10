---
name: pgss-benchmark
description: Benchmark pg_stat_statements patch commits against upstream PostgreSQL, locally or on an EC2 fleet, and report the datapoints of each point (TPS ratio, trend, allocated entries, recency, popular kept, eviction passes, backstop, text storage). Use when asked to run, monitor or report a pg_stat_statements benchmark.
---

# pg_stat_statements benchmark

Compare patch commits against upstream under statement churn, and report the
same datapoints for every point, so that results from different people and
machines can be compared.  Results are shared by pasting the report, not
committed to this repository.

## Workloads

- `hc100m` (`hotcold_4000_100m`): 90% of the transactions run one of 4000
  popular statements, 10% one of 100M unpopular ones: constant eviction.
- `hc1500` (`hotcold_4000_1500`): the same, with 1500 unpopular statements:
  the statements fit in `pg_stat_statements.max` (5000) but churn at the edge.
- `sel` (`select_only`): pgbench `-S`, a handful of statements, no eviction:
  the cost of tracking itself.

Every run is a fresh cluster, `pg_stat_statements.max=5000`; the builds of a
point run back to back.

## 1. Agree on the run, before anything starts

Ask the user, then confirm back in one short list:

- **Upstream**: a commit of postgres/postgres (full hash).  Benchmark the
  patches on top of that same commit.
- **Patch commits**: full hashes.  For each, tell how it keeps query texts,
  to label it in the report:
  `git show <commit>:contrib/pg_stat_statements/pg_stat_statements.c | grep -q query_text_memory`
  means texts in shared memory, else texts in a file.
- **Where**: local, or EC2 (instance types).
- **Workloads, clients, seconds per run** (defaults: all three workloads,
  clients 1 2 4 8 16 32 64 128 256 512, 180 s).

For EC2 also give the estimated cost and duration and get an explicit yes:
duration per instance is about `workloads × clients × builds × (secs + 40)`
plus 15 minutes of setup and builds; cost is that times the on-demand price
of each type (check the current price for the region; c7i is about $0.045
per vCPU-hour in us-east-1, so a c7i.48xlarge is about $8.60 an hour).  Do not launch
before the user confirms the list of builds and the cost.

## 2a. Run locally

Needs a PostgreSQL git checkout holding the commits (`PG_SRC`), the build
dependencies of PostgreSQL with Meson and Ninja, and an otherwise idle
machine: anything else running skews the results, so say so in the report if
the machine is shared.  Builds, clusters and results go to `PGSS_WORK`
(default `local/work`, ignored by git).

A plan file has one `<vcpus> <clients> <repeats>` line per point, run in
order; each run is pinned to CPUs `0..vcpus-1`.  For example, on a 32-vCPU
machine:

```
32 1 1
32 32 1
32 256 1
```

Start it detached, as it runs for hours
(`runs = points × repeats × workloads × (1 + patch commits)`, each `SECS`
plus about 30 s):

```sh
export PG_SRC=/path/to/postgres PGSS_WORK=$PWD/local/work
UPSTREAM=<hash> WORKLOADS="hc100m hc1500 sel" SECS=180 \
  setsid nohup local/bench.sh <name> <plan> <patch hash>... \
  > $PGSS_WORK/<name>.log 2>&1 < /dev/null &
```

Progress and the datapoints so far:

```sh
local/status.sh <name> <hash>="texts in memory" <hash>="texts in file"
```

`local/stop.sh` stops the runs and their servers.  A build failure is in
`$PGSS_WORK/bld-<hash>.log`.

## 2b. Run on EC2

Use an AWS account meant for benchmarks, never a production one; if unsure,
ask.  In `ec2-setup/`:

1. `aws.config` (ignored by git, never commit or print it):
   ```sh
   AWS_ACCOUNT_ID=...
   AWS_REGION=...
   AWS_PROFILE=...   # optional
   ```
   Check the credentials: `aws sts get-caller-identity` must show that
   account.  The first launch creates, or reuses, an S3 bucket
   `pgss-benchmark-<account>-<region>`, an IAM role and instance profile for
   SSM and the uploads, and a security group with no ingress rule; the
   instances are reached through SSM only.
2. The instances clone PostgreSQL from `PG_REMOTE`, the patch commits from
   `PATCH_REMOTE`, and this repository from `BENCHMARK_REPO`
   (`benchmark.config`).  Patch commits must be pushed to `PATCH_REMOTE`; a
   change to the suite itself must be pushed to `BENCHMARK_REPO`.
3. Launch, detached:
   ```sh
   BASE=<upstream hash> PATCH=<hash> EXTRA="<hashes>" \
     TYPES="c7i.8xlarge c7i.24xlarge" SECS=180 \
     setsid nohup ./launch_fleet.sh > state/launch.log 2>&1 < /dev/null &
   ```
   The fleet name is in `state/current_fleet`, its instances in
   `state/<fleet>.instances`.  Instances terminate themselves when done or
   failed; the launcher relaunches one that ends without results, twice at
   most.
4. Every 10 to 30 minutes, fetch and report:
   ```sh
   ./fetch_fleet_status.sh <fleet>
   python3 ../report_datapoints.py fleet results/fleet/<fleet> \
     <hash>="texts in memory" <hash>="texts in file"
   ```
   Label the patch builds: the fleet cannot tell a text file from text
   memory, and the text size column means either.
5. When the launcher log says all types finished, check that every instance
   in `state/<fleet>.instances` is terminated:
   `aws ec2 describe-instances --instance-ids <ids> --query 'Reservations[].Instances[].[InstanceId,State.Name]'`.
   Only ever stop or terminate instances listed there, and only those of
   this fleet; tell the user about any instance still running.

## 3. Report

`report_datapoints.py` prints one line per build and point:

```
AMD EPYC 9R14 (32 vCPUs) hc100m 256 clients
  upstream          210.0k  1.00x cv  0.5% trend  +0.7% | alloc           - | age 877/364/1818/1818/0 | popular 4000 | passes/1M  400 (1.00x up) | backstop - | text 2.41MB (file), no-text 0
  texts in file     202.3k  0.96x cv  0.5% trend  -0.4% | alloc   4806/5026 | age 899/364/1818/1818/0 | popular 4000 | passes/1M  371 (0.93x up) | backstop 0% | text 2.42MB (file), no-text 0
  texts in memory   638.2k  3.04x cv  1.8% trend  -3.8% | alloc   4919/5226 | age 963/333/1612/1722/0 | popular 4000 | passes/1M  296 (0.74x up) | backstop 0% | text 1.01MB (memory), no-text 0
```

1. **TPS**, ratio to upstream, and the CV of the progress samples.
2. **TPS trend**: whether the TPS holds over the run, the mean TPS of the
   last fifth of the run against the mean TPS of its first fifth.  Near 0%
   is sustained; negative means the TPS falls as the run goes on, and below
   -5% is flagged `DEGRADING`: a longer run would look worse.  Always say
   "TPS trend" and what it compares, not just "trend".
3. **alloc avg/max**: entries allocated by the stats kind
   (`pg_stat_kind_info.entry_count`), including dropped entries not yet
   freed.  It should stay near `pg_stat_statements.max`.
4. **age**: entries of the view by creation age, `<1s/1-10s/10s-1min/1-5min/>5min`.
   Mostly young entries means the view churns.
5. **popular**: the fewest of the 4000 popular statements in the view
   during the run.  Below 4000, eviction is removing statements that matter.
6. **passes/1M**: eviction passes per million transactions, and against
   upstream.  Well above upstream means the eviction runs too often.
7. **backstop**: the share of the run at twice `pg_stat_statements.max`, where
   new statements are not tracked.  Should be 0%.
8. **text**: the largest size of the query text storage, and the most
   entries without a query text.

Lead with the points where a build is slower than upstream, degrading,
loses popular statements, or reaches the backstop; then the overall picture per
machine and workload.  Compare builds only within a point, and only between
runs of the same machine.

## Publishing the results

Once the run is done (or earlier, if the user asks, marked in progress),
write the page and add it to the table of `README.md`, under "Published
results":

```sh
python3 report_datapoints.py fleet ec2-setup/results/fleet/<fleet> \
  <hash>="<label>" ... --markdown "<title>" > reports/<date>-<name>.md
```

The page has the settings, the datapoints explained, a summary of the
ratios and TPS trends, every datapoint of every point, the TPS of each
fifth of the run behind each TPS trend, and histograms of
the entries retained by recency.  (`local <results file>` for a local run; then add the machine, its vCPUs
and CPU model, and the seconds per run to the page's settings table by
hand.)  Only the page and the README change: never commit `aws.config`,
`state/`, `results/` or `local/work/`.  Before committing, check the diff
for account IDs, AWS profile names, host names and instance IDs, and show
the user the page; push only when the user says so.  Then the link to the
page, with a few lines on what it shows, is what goes in the thread.
