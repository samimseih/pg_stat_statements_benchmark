# pg_stat_statements Benchmark & Verification

A/B benchmarking, profiling, and algorithm verification for the pg_stat_statements dshash rewrite.

## Baseline

The `switch_build.sh` script uses a baseline commit hash (`BASELINE` variable)
to toggle between upstream and patched source. This should be set to the parent
of the first commit in the patch series - i.e., the last upstream commit before
your patches begin. When switching to "upstream", the script restores all files
changed by the patch series to their state at that commit. When switching to
"patch", it restores them to HEAD.

Update `BASELINE` in `switch_build.sh` if you rebase the patch series onto a
newer upstream.

## Prerequisites

- `pg_ctl`, `psql`, `pgbench` in PATH
- `PGDATA` set (handled by switch_build.sh)
- `shared_preload_libraries = 'pg_stat_statements'`
- `shared_buffers = '4GB'` recommended
- `sudo` access for perf scripts
- `injection_points` extension for clock-sweep verification

## Quick Start

```bash
# A/B comparison: upstream vs patch
./switch_build.sh upstream release
./run_comparison.sh 30 64 churn

./switch_build.sh patch release
./run_comparison.sh 30 64 churn

# Full matrix
./bench_full_matrix.sh 120 64

# Clock-sweep algorithm verification
./partitioned_clock_sweep/run.sh 128 100 50
```

## Performance Benchmarking

### switch_build.sh

Switch between upstream and patched source, rebuild, and restart the server.

```bash
./switch_build.sh upstream|patch [debug|release|debug_noassert]
```

- `upstream` - reverts source files to HEAD~5 (pre-patch baseline)
- `patch` - restores source files from HEAD (current branch tip)
- Build types:
  - `release` - cassert disabled, optimized (for accurate benchmarks, default)
  - `debug` - cassert enabled (full debugging)
  - `debug_noassert` - symbols for perf/gdb without assert overhead

### run_comparison.sh

Run pgbench workloads with pg_stat_statements monitoring.

```bash
./run_comparison.sh [duration] [clients] [workload]
```

- `duration` - seconds (default: 30)
- `clients` - concurrent connections (default: 64)
- `workload` - `select1`, `churn`, `light_churn`, `multi_stmt`, or `all` (default: all)

Outputs TPS, entry counts, NULL query counts, wait events, and dealloc counts.
Results saved to `/tmp/pgss_bench_<timestamp>.txt`.

Sample output (`./run_comparison.sh 120 64 churn simple`):
```
=== pg_stat_statements benchmark ===
Date: Thu May 29 10:00:00 PDT 2026
Clients: 64, Duration: 120s, Workload: churn, Protocol: simple, CPUs: 10

--- churn ---
  t=20s  entries=5000  nulls=0  hot=998/1000 cold=3842 hot_calls=820400 cold_calls=12050 marker_survived=1/1 tps=45102 waits=[LWLock:pg_stat_statements(28) LWLock:BufferContent(4)]
  t=40s  entries=5000  nulls=0  hot=1000/1000 cold=3840 hot_calls=1650200 cold_calls=24300 marker_survived=2/2 tps=45230 waits=[LWLock:pg_stat_statements(31) LWLock:BufferContent(3)]
  t=60s  entries=5000  nulls=0  hot=1000/1000 cold=3838 hot_calls=2480100 cold_calls=36400 marker_survived=3/3 tps=45150 waits=[LWLock:pg_stat_statements(26)]
  t=80s  entries=5000  nulls=0  hot=1000/1000 cold=3836 hot_calls=3310500 cold_calls=48600 marker_survived=4/4 tps=45300 waits=[LWLock:pg_stat_statements(29)]
  t=100s entries=5000  nulls=0  hot=1000/1000 cold=3835 hot_calls=4140200 cold_calls=60800 marker_survived=5/5 tps=45180 waits=[LWLock:pg_stat_statements(25)]
  t=120s entries=5000  nulls=0  hot=1000/1000 cold=3834 hot_calls=4970100 cold_calls=73000 marker_survived=6/6 tps=45210 waits=[LWLock:pg_stat_statements(27)]
  wait totals (120 samples): LWLock:pg_stat_statements(total=166 avg=1.4/sample) LWLock:BufferContent(total=7 avg=0.1/sample)
  TPS: 45210.52
  FINAL  entries=5000  nulls=0  hot=1000/1000 cold=3834 hot_calls=4970100 cold_calls=73000
  deallocs: 142

=== TPS Summary ===
--- churn: 45210.52

=== DONE ===
```

### bench_full_matrix.sh

Run the full benchmark matrix across builds and build types.

```bash
./bench_full_matrix.sh [duration] [clients] [build_types] [workloads] [protocols]
```

- `duration` - seconds per workload (default: 180)
- `clients` - concurrent connections (default: 64)
- `build_types` - `release`, `debug`, `debug_noassert`, or combinations (default: `"release debug"`)
- `workloads` - `churn`, `light_churn`, `multi_stmt`, `select1`, or combinations (default: `"churn"`)
- `protocols` - `simple`, `extended`, `extended-nobind`, `prepared`, or combinations (default: `"simple"`)

Runs all workloads for each combination of {upstream, patch} x {build_types} x {protocols}.
Produces a combined summary with TPS deltas.

Sample final report (`./bench_full_matrix.sh 120 64 release churn simple`):
```
=== pg_stat_statements Full Benchmark Matrix ===
Date: Thu May 29 03:27:45 PDT 2026
Duration: 120s per workload, Clients: 64
Protocols: simple
Matrix: 2 builds x 1 types x 1 workloads x 1 protocols = 2 tests
Estimated total time: 5 minutes

Machine:
  CPUs: 16 (8 cores, 2 threads/core, 1 socket)
  CPU model: Intel(R) Xeon(R) CPU E5-2680 v2 @ 2.80GHz
  RAM: 29Gi

Build configurations:
  release:        buildtype=release, cassert=false, ndebug=true
  debug:          buildtype=debug, cassert=true, ndebug=false
  debug_noassert: buildtype=debug, cassert=false, ndebug=true

Method:
  For each test: pg_stat_statements_reset(), then pgbench (see per-test command below).
  While pgbench is running:
    - sample pg_stat_activity wait events (WHERE state = 'active') every 1s
    - query pg_stat_statements (entries, hot/cold calls) every 20s
      hot_calls = sum(calls) FILTER (WHERE query LIKE '%hot%')
      cold_calls = sum(calls) FILTER (WHERE query NOT LIKE '%hot%' AND query IS NOT NULL)
  After pgbench: final entry count, hot/cold calls, dealloc count from pg_stat_statements_info

================================================================
=== patch_release ===
================================================================

--- patch_release / churn (simple) ---
  => TPS: 45230.12
  => FINAL  entries=5000  nulls=0  hot=1000/1000 cold=3834 hot_calls=4970100 cold_calls=73000

================================================================
=== upstream_release ===
================================================================

--- upstream_release / churn (simple) ---
  => TPS: 43100.88
  => FINAL  entries=5000  nulls=0  hot=1000/1000 cold=3840 hot_calls=4820000 cold_calls=71200


================================================================
                    COMBINED RESULTS SUMMARY                     
================================================================

=== churn (release) ===
  pgbench -f bench_churn.sql -c 64 -j 16 -T 120 -M simple
+--------------+--------------+--------------+----------+
|              | patch        | upstream     | delta    |
+--------------+--------------+--------------+----------+
| TPS          |       45,230 |       43,101 |    +4.9% |
| entries      |         5000 |         5000 |          |
| hot_entries  |         1000 |          998 |          |
| cold_entries |        3,834 |        3,840 |          |
| hot_calls    |    4,970,100 |    4,820,000 |          |
| cold_calls   |       73,000 |       71,200 |          |
| deallocs     |          142 |          350 |          |
| top_wait     | LWLock:pg... | LWLock:pg... |          |
+--------------+--------------+--------------+----------+

Results directory: /Users/simseih/Development/benchmarks/results/pgss_matrix_20260529_032745
Individual run details: /Users/simseih/Development/benchmarks/results/pgss_matrix_20260529_032745/<config>_<workload>_<protocol>_full.txt
=== DONE ===
```

### Workloads

| File | Description |
|------|-------------|
| `bench_select1.sql` | `SELECT 1` - pure overhead measurement |
| `bench_churn.sql` | 80% hot / 20% cold (100k unique) - eviction stress |
| `bench_light_churn.sql` | 99.5% hot / 0.5% cold (10k unique) - light eviction |
| `bench_multi_stmt.sql` | Multi-statement transaction with 100k unique queries |

## Profiling

### perf_record.sh

Record a perf profile of running postgres backends and print top functions.

```bash
./perf_record.sh [duration]
```

Records for `duration` seconds (default: 10). Run in a separate terminal while a
workload is active. Prints top functions (>1% overhead) and saves `perf.data`.

### perf_annotate.sh

Profile a specific function at instruction level.

```bash
./perf_annotate.sh [function] [duration]
```

- `function` - symbol to annotate (default: `pgstat_get_entry_ref`)
- `duration` - seconds to record (default: 10)

Shows per-instruction cycle percentages. Useful for identifying cache misses and hot loops.

### perf_offcpu.sh

Off-CPU profiling for contention analysis.

```bash
./perf_offcpu.sh [duration]
```

## Clock-Sweep Algorithm Verification

The `partitioned_clock_sweep/` directory contains injection-point-based tests that
observe the eviction algorithm's behavior in real time. Uses PostgreSQL's injection
point infrastructure to trace entry lifecycle: birth, decay (refcount aging), and
death (eviction with final call count).

### What it verifies

- Hot queries (high refcount) survive sweep passes - they decay but don't die
- Cold queries (low refcount) are evicted quickly
- Eviction is proportional: refcount earned through usage = protection from eviction
- Under concurrent load, the partitioned sweep doesn't starve or over-evict

### partitioned_clock_sweep/run.sh

```bash
./partitioned_clock_sweep/run.sh [clients] [txns] [rate]
```

- `clients` - concurrent connections for pgbench phase (default: 128)
- `txns` - transactions per client (default: 100)
- `rate` - TPS limit, 0 = unlimited (default: 0). Lower rate = more time for hot
  queries to accumulate hits between sweeps

Runs two phases:
1. **Single-backend** - plain SQL, traces lifecycle via psql NOTICE output
2. **Multi-backend** - pgbench with 128 clients, traces via server log

Reports births, decays, deaths, decay refcount stats (min/avg/max), and a
histogram showing the distribution of refcounts at decay time.

Sample output:
```
  Entries created: 547
  Decays: 1293
  Decay refcount (min/avg/max): 1 / 4.5 / 10
  Decay refcount histogram:
    refcount= 1:   312 |████████████████████████████████████████
    refcount= 2:    87 |███████████
    refcount= 3:    45 |█████
    refcount= 8:    98 |████████████
    refcount= 9:   201 |█████████████████████████
    refcount=10:   550 |██████████████████████████████████████████████████
  Evictions: 362
```

A bimodal distribution (peaks at 1 and 10) indicates good separation - hot queries
stay protected at high refcount while cold ones die quickly at refcount=1.

### Test scripts

| File | Purpose |
|------|---------|
| `eviction_lifecycle.sql` | Single-backend: fill → heat → trickle, all NOTICEs to stderr |
| `eviction_setup.sql` | Multi-backend setup: fill, heat, attach injection points |
| `eviction_pgbench.sql` | pgbench script: 80% hot re-execution / 20% new trickle |
| `eviction_teardown.sql` | Detach injection points |

### Interpreting results

- **Decay refcount avg** - higher = hot entries well-protected, sweeps grinding through them
- **Evictions at refcount=1** - cold entries dying fast (algorithm discriminating well)
- **Evictions at refcount>1** - working set under pressure (may need higher max)
- **calls=0 at death** - entry never executed (or stats not yet flushed), expected for trickle entries

## Required Patches

The `patch/` directory contains patches that must be applied to the PostgreSQL
source tree for certain benchmark features to work.

| Patch | Purpose | Required by |
|-------|---------|-------------|
| `v1-0001-introduce-extended-nobind-mode.patch` | Adds `extended-nobind` query mode to pgbench - sends queries via extended protocol (`PQsendQueryParams`) with 0 parameters and variables inlined into the SQL text. This produces unique query strings on the wire (no parameter binding), which generates distinct pg_stat_statements entries per constant value - essential for testing eviction under realistic extended-protocol churn. | `run_comparison.sh` with `protocol=extended-nobind` |
| `v1-0001-pgss-eviction-injection-points.patch` | Adds three injection points to pg_stat_statements (`pgss-eviction-created`, `pgss-eviction-decay`, `pgss-eviction-evicted`) that trace entry lifecycle during the clock-sweep. Also simplifies initial refcount to always start at 1. | `partitioned_clock_sweep/` tests |

Apply from the PostgreSQL source tree:

```bash
# For extended-nobind benchmarks
git apply /path/to/patch/v1-0001-introduce-extended-nobind-mode.patch

# For clock-sweep verification
git apply /path/to/patch/v1-0001-pgss-eviction-injection-points.patch
```

## Typical Workflow

1. Run upstream baseline:
   ```bash
   ./switch_build.sh upstream release
   ./run_comparison.sh 30 64 all
   ```

2. Run patch:
   ```bash
   ./switch_build.sh patch release
   ./run_comparison.sh 30 64 all
   ```

3. Full matrix comparison:
   ```bash
   ./bench_full_matrix.sh 120 64
   ```

4. Profile if regression found:
   ```bash
   ./switch_build.sh patch debug_noassert
   ./run_comparison.sh 30 64 churn   # terminal 1
   ./perf_annotate.sh entry_dealloc 10  # terminal 2
   ```

5. Verify eviction behavior:
   ```bash
   ./partitioned_clock_sweep/run.sh 128 100 50
   ```
