# pg_stat_statements benchmark report

## Summary

- hotcold_100m throughput improved by +0.4% to +96.8% across reported non-single-client points.
- select_only changed by -6.1% to +0.9% across reported non-single-client points.
- Successful retention samples retained at least 4,000 popular statements at every reported churn point.
- Patched qtext_count high-water from samples/final info was 0 for hotcold_100m.
- Patched entry DSA high-water from samples/final info was 43.2 MiB.
- Baseline churn sampled 160,002 pg_stat_statements LWLock waits; patched sampled 0.
- Patched replacement pgstat/qtext waits under churn totaled 4,395 samples.
- Baseline SpinDelay samples were 8,812 versus 701 for patched.

## Run

| item | value |
| --- | --- |
| result directory | `EC2 c7i.8xlarge run pgss-customstats-600s-master-20261021T1045Z` |
| patched | [`c0f1ee3f8fb4`](https://github.com/samimseih/postgres/commit/c0f1ee3f8fb46b6c370251201e9d8cf3f030fe4b) - custom pgstat entries |
| baseline | [`6b9f40d49ae3`](https://github.com/postgres/postgres/commit/6b9f40d49ae3) - PostgreSQL master |
| hot/cold duration | 600 seconds per point |
| select-only duration | 600 seconds per point |
| report client points | `1 2 4 8 16 32 64 128 256` |
| failed pgbench rows | 0 |

## Throughput

### hotcold_100m

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 32,098 | 32,482 | -1.2% |
| 2 | 61,992 | 61,731 | +0.4% |
| 4 | 124,539 | 120,712 | +3.2% |
| 8 | 237,769 | 219,381 | +8.4% |
| 16 | 425,893 | 371,307 | +14.7% |
| 32 | 999,808 | 507,952 | +96.8% |
| 64 | 873,377 | 539,279 | +62.0% |
| 128 | 688,046 | 522,891 | +31.6% |
| 256 | 680,919 | 486,347 | +40.0% |

### select_only

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 30,756 | 30,752 | +0.0% |
| 2 | 59,607 | 59,834 | -0.4% |
| 4 | 119,401 | 118,873 | +0.4% |
| 8 | 233,087 | 232,655 | +0.2% |
| 16 | 423,318 | 419,809 | +0.8% |
| 32 | 1,013,177 | 1,004,617 | +0.9% |
| 64 | 901,501 | 910,138 | -0.9% |
| 128 | 769,113 | 819,386 | -6.1% |
| 256 | 687,540 | 681,412 | +0.9% |

## Retention

Values are sampled min/avg/max.

| workload | clients | patched entries min/avg/max | baseline entries min/avg/max | patched pop min/avg/max | baseline pop min/avg/max | patched unpop min/avg/max | baseline unpop min/avg/max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 4,618/4,940/5,229 | 4,796/4,887/4,977 | 4,000 | 4,000 | 617/939/1,228 | 796/887/977 |
| hotcold_100m | 2 | 4,269/4,793/5,416 | 4,772/4,845/4,893 | 4,000 | 4,000 | 269/793/1,416 | 772/845/893 |
| hotcold_100m | 4 | 4,000/4,476/5,189 | 4,764/4,908/4,991 | 4,000 | 4,000 | 0/476/1,189 | 764/908/991 |
| hotcold_100m | 8 | 4,000/4,298/4,951 | 4,763/4,860/4,974 | 4,000 | 4,000 | 0/298/951 | 763/860/974 |
| hotcold_100m | 16 | 4,000/4,267/4,968 | 4,772/4,842/4,961 | 4,000 | 4,000 | 0/267/968 | 772/842/961 |
| hotcold_100m | 32 | 4,000/4,280/5,160 | 4,807/4,892/4,984 | 4,000 | 4,000 | 0/280/1,160 | 807/892/984 |
| hotcold_100m | 64 | 4,000/4,373/5,077 | 4,752/4,884/4,994 | 4,000 | 4,000 | 0/373/1,077 | 752/884/994 |
| hotcold_100m | 128 | 4,072/4,295/4,725 | 4,793/4,861/4,974 | 4,000 | 4,000 | 72/295/725 | 793/861/974 |
| hotcold_100m | 256 | 4,000/4,082/4,319 | 4,747/4,861/4,990 | 4,000 | 4,000 | 0/82/319 | 747/861/990 |

## Sampled Query Text And Churn

Query-text and memory values from periodic samples are min/avg/max.
Memory values use human-readable IEC units.

| workload | clients | patched qtext count | patched qtext payload min/avg/max | patched qtext DSA min/avg/max | patched entry DSA min/avg/max | patched dealloc | baseline dealloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 0 | 0 B | 0 B | 5.25 MiB | 3,562 | 7,208 |
| hotcold_100m | 2 | 0 | 0 B | 0 B | 5.25 MiB | 6,819 | 13,701 |
| hotcold_100m | 4 | 0 | 0 B | 0 B | 9.25 MiB | 13,411 | 26,809 |
| hotcold_100m | 8 | 0 | 0 B | 0 B | 19.2 MiB | 24,502 | 48,757 |
| hotcold_100m | 16 | 0 | 0 B | 0 B | 23.2 MiB/24.1 MiB/27.2 MiB | 39,901 | 82,448 |
| hotcold_100m | 32 | 0 | 0 B | 0 B | 43.2 MiB | 67,571 | 112,789 |
| hotcold_100m | 64 | 0 | 0 B | 0 B | 37.2 MiB | 55,613 | 119,795 |
| hotcold_100m | 128 | 0 | 0 B | 0 B | 29.2 MiB | 46,618 | 116,122 |
| hotcold_100m | 256 | 0 | 0 B | 0 B | 29.2 MiB | 22,408 | 108,001 |

## Final Gauges

Final values from pg_stat_statements_info, captured after each pgbench run.
These do not require scanning the pg_stat_statements view.

| workload | clients | patched final entries | patched final qtext count | patched final qtext payload | patched final qtext DSA | patched final entry DSA | patched final dealloc | baseline final dealloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 5,165 | 0 | 0 B | 0 B | 5.25 MiB | 3,851 | 7,795 |
| hotcold_100m | 2 | 5,037 | 0 | 0 B | 0 B | 5.25 MiB | 7,367 | 14,808 |
| hotcold_100m | 4 | 5,187 | 0 | 0 B | 0 B | 9.25 MiB | 14,508 | 28,964 |
| hotcold_100m | 8 | 5,131 | 0 | 0 B | 0 B | 19.2 MiB | 26,468 | 52,654 |
| hotcold_100m | 16 | 5,266 | 0 | 0 B | 0 B | 27.2 MiB | 43,122 | 89,125 |
| hotcold_100m | 32 | 5,002 | 0 | 0 B | 0 B | 43.2 MiB | 72,959 | 121,901 |
| hotcold_100m | 64 | 5,203 | 0 | 0 B | 0 B | 37.2 MiB | 60,286 | 129,397 |
| hotcold_100m | 128 | 5,033 | 0 | 0 B | 0 B | 29.2 MiB | 50,377 | 125,519 |
| hotcold_100m | 256 | 5,100 | 0 | 0 B | 0 B | 29.2 MiB | 24,192 | 116,700 |
| select_only | 1 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |
| select_only | 2 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |
| select_only | 4 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |
| select_only | 8 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |
| select_only | 16 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |
| select_only | 32 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |
| select_only | 64 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |
| select_only | 128 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |
| select_only | 256 | 7 | 0 | 0 B | 0 B | 13.2 MiB | 0 | 0 |

## Memory Gauge Averages

Average values from the periodic samples. Memory values use human-readable IEC units.

| workload | clients | avg entries | avg qtext count | avg qtext payload | avg qtext DSA | avg entry DSA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 4,940 | 0 | 0 B | 0 B | 5.25 MiB |
| hotcold_100m | 2 | 4,793 | 0 | 0 B | 0 B | 5.25 MiB |
| hotcold_100m | 4 | 4,476 | 0 | 0 B | 0 B | 9.25 MiB |
| hotcold_100m | 8 | 4,298 | 0 | 0 B | 0 B | 19.2 MiB |
| hotcold_100m | 16 | 4,267 | 0 | 0 B | 0 B | 24.1 MiB |
| hotcold_100m | 32 | 4,280 | 0 | 0 B | 0 B | 43.2 MiB |
| hotcold_100m | 64 | 4,373 | 0 | 0 B | 0 B | 37.2 MiB |
| hotcold_100m | 128 | 4,295 | 0 | 0 B | 0 B | 29.2 MiB |
| hotcold_100m | 256 | 4,082 | 0 | 0 B | 0 B | 29.2 MiB |
| select_only | 1 | 6 | 0 | 0 B | 0 B | 13.2 MiB |
| select_only | 2 | 6 | 0 | 0 B | 0 B | 13.2 MiB |
| select_only | 4 | 6 | 0 | 0 B | 0 B | 13.2 MiB |
| select_only | 8 | 6 | 0 | 0 B | 0 B | 13.2 MiB |
| select_only | 16 | 6 | 0 | 0 B | 0 B | 13.2 MiB |
| select_only | 32 | 6 | 0 | 0 B | 0 B | 13.2 MiB |
| select_only | 64 | 6 | 0 | 0 B | 0 B | 13.2 MiB |
| select_only | 128 | 6 | 0 | 0 B | 0 B | 13.2 MiB |
| select_only | 256 | 6 | 0 | 0 B | 0 B | 13.2 MiB |

## Wait Events

| workload | variant | active samples | pgss LWLock | PgStatsDSA | PgStatsHash | qtext LWLock | SpinDelay | ClientRead | cpu/no wait |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | baseline | 215,997 | 160,002 | 0 | 0 | 0 | 3,286 | 27,844 | 24,865 |
| hotcold_100m | patched | 106,195 | 0 | 3,636 | 759 | 0 | 213 | 25,215 | 72,661 |
| select_only | baseline | 65,059 | 0 | 0 | 0 | 0 | 5,526 | 28,329 | 20,627 |
| select_only | patched | 59,366 | 0 | 0 | 0 | 0 | 488 | 26,342 | 20,466 |

## Wait Event Diffs

Values are patched minus baseline sample counts from the same run.

| workload | event | baseline samples | patched samples | delta | change |
| --- | --- | ---: | ---: | ---: | ---: |
| hotcold_100m | active samples | 215,997 | 106,195 | -109,802 | -50.8% |
| hotcold_100m | pg_stat_statements LWLock | 160,002 | 0 | -160,002 | -100.0% |
| hotcold_100m | PgStatsDSA LWLock | 0 | 3,636 | +3,636 | new |
| hotcold_100m | PgStatsHash LWLock | 0 | 759 | +759 | new |
| hotcold_100m | SpinDelay | 3,286 | 213 | -3,073 | -93.5% |
| hotcold_100m | ClientRead | 27,844 | 25,215 | -2,629 | -9.4% |
| hotcold_100m | cpu/no wait | 24,865 | 72,661 | +47,796 | +192.2% |
| select_only | active samples | 65,059 | 59,366 | -5,693 | -8.8% |
| select_only | SpinDelay | 5,526 | 488 | -5,038 | -91.2% |
| select_only | ClientRead | 28,329 | 26,342 | -1,987 | -7.0% |
| select_only | cpu/no wait | 20,627 | 20,466 | -161 | -0.8% |

## Notes

- Deallocation counters are eviction-pass counters, matching upstream
  pg_stat_statements_info semantics.
- Query-text and entry DSA columns are sampled current-state gauges;
  summary.tsv reports their sampled min/avg/max. Older commits that do
  not expose them report zero in summary.tsv.
- The Markdown report prints memory with IEC units; summary.tsv keeps
  raw byte counts for scripts.
- Final gauges come from pg_stat_statements_info after each pgbench run;
  they avoid scanning the full view, so they still work when churn
  creates too many rows for pg_stat_statements to materialize.
- Each commit reuses the same PostgreSQL server across workload groups,
  so select_only storage gauges can include DSA space allocated by
  earlier churn runs.
- The cpu/no wait column is active backends with no PostgreSQL wait
  event reported, not an OS CPU counter.
- Patched hot/cold runs removed the old pg_stat_statements LWLock
  samples; remaining waits were smaller and split across PgStatsDSA,
  PgStatsHash, and qtext paths.
- Under churn, SpinDelay was smaller than the baseline
  pg_stat_statements LWLock bottleneck.
