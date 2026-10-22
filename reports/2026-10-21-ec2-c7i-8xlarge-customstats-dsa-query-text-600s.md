# pg_stat_statements benchmark report

## Summary

- hotcold_100m throughput improved by +4.0% to +104.4% across reported non-single-client points.
- select_only changed by -3.0% to +0.7% across reported non-single-client points.
- Successful retention samples retained at least 4,000 popular statements at every reported churn point.
- Patched qtext_count high-water from samples/final info was 5,523 for hotcold_100m.
- Patched entry DSA high-water from samples/final info was 43.2 MiB.
- Baseline churn sampled 148,857 pg_stat_statements LWLock waits; patched sampled 0.
- Patched replacement pgstat/qtext waits under churn totaled 7,415 samples.
- Baseline SpinDelay samples were 9,049 versus 873 for patched.

## Run

| item | value |
| --- | --- |
| result directory | `EC2 c7i.8xlarge run, customstats + DSA query text, 2026-10-21T1045Z` |
| patched | [`1d8654a01fcc`](https://github.com/samimseih/postgres/commit/1d8654a01fcca998adff5f318b52d6b8ee3e3214) - customstats + DSA query text |
| baseline | [`6b9f40d49ae3`](https://github.com/postgres/postgres/commit/6b9f40d49ae3) - PostgreSQL master |
| hot/cold duration | 600 seconds per point |
| select-only duration | 600 seconds per point |
| report client points | `1 2 4 8 16 32 64 128 256` |
| failed pgbench rows | 0 |

## Throughput

### hotcold_100m

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 33,278 | 32,210 | +3.3% |
| 2 | 65,315 | 62,820 | +4.0% |
| 4 | 127,369 | 121,698 | +4.7% |
| 8 | 243,481 | 217,441 | +12.0% |
| 16 | 428,139 | 365,666 | +17.1% |
| 32 | 1,023,364 | 500,666 | +104.4% |
| 64 | 923,901 | 536,638 | +72.2% |
| 128 | 728,773 | 526,677 | +38.4% |
| 256 | 783,020 | 494,291 | +58.4% |

### select_only

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 31,906 | 31,405 | +1.6% |
| 2 | 61,441 | 61,001 | +0.7% |
| 4 | 120,974 | 122,095 | -0.9% |
| 8 | 235,483 | 234,332 | +0.5% |
| 16 | 421,856 | 420,457 | +0.3% |
| 32 | 1,021,316 | 1,014,386 | +0.7% |
| 64 | 912,255 | 913,906 | -0.2% |
| 128 | 768,084 | 792,023 | -3.0% |
| 256 | 688,628 | 684,201 | +0.6% |

## Retention

Values are sampled min/avg/max.

| workload | clients | patched entries min/avg/max | baseline entries min/avg/max | patched pop min/avg/max | baseline pop min/avg/max | patched unpop min/avg/max | baseline unpop min/avg/max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 4,826/5,038/5,351 | 4,771/4,864/4,996 | 4,000 | 4,000 | 826/1,038/1,350 | 771/864/996 |
| hotcold_100m | 2 | 4,281/4,740/5,329 | 4,759/4,836/4,911 | 4,000 | 4,000 | 281/740/1,329 | 759/836/911 |
| hotcold_100m | 4 | 4,000/4,401/5,240 | 4,758/4,875/4,991 | 4,000 | 4,000 | 0/401/1,240 | 758/875/991 |
| hotcold_100m | 8 | 4,000/4,304/5,229 | 4,769/4,863/4,968 | 4,000 | 4,000 | 0/304/1,229 | 769/863/968 |
| hotcold_100m | 16 | 4,000/4,207/4,971 | 4,773/4,864/4,984 | 4,000 | 4,000 | 0/207/971 | 773/864/984 |
| hotcold_100m | 32 | 4,000/4,220/5,056 | 4,753/4,900/4,991 | 4,000 | 4,000 | 0/220/1,056 | 753/900/991 |
| hotcold_100m | 64 | 4,000/4,340/5,187 | 4,752/4,855/4,971 | 4,000 | 4,000 | 0/340/1,187 | 752/855/970 |
| hotcold_100m | 128 | 4,000/4,326/4,994 | 4,756/4,871/4,983 | 4,000 | 4,000 | 0/326/994 | 756/871/983 |
| hotcold_100m | 256 | 4,000/4,181/4,738 | 4,742/4,846/4,962 | 4,000 | 4,000 | 0/181/738 | 742/846/962 |

## Sampled Query Text And Churn

Query-text and memory values from periodic samples are min/avg/max.
Memory values use human-readable IEC units.

| workload | clients | patched qtext count | patched qtext payload min/avg/max | patched qtext DSA min/avg/max | patched entry DSA min/avg/max | patched dealloc | baseline dealloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 5,086/5,311/5,496 | 409 KiB/429 KiB/446 KiB | 1.00 MiB | 5.25 MiB | 3,690 | 7,158 |
| hotcold_100m | 2 | 5,014/5,228/5,449 | 403 KiB/422 KiB/442 KiB | 1.00 MiB | 5.25 MiB | 7,205 | 13,933 |
| hotcold_100m | 4 | 5,020/5,185/5,362 | 403 KiB/418 KiB/434 KiB | 1.00 MiB | 9.25 MiB | 13,821 | 26,983 |
| hotcold_100m | 8 | 5,022/5,252/5,454 | 403 KiB/424 KiB/442 KiB | 1.00 MiB | 19.2 MiB | 25,358 | 48,274 |
| hotcold_100m | 16 | 5,047/5,310/5,500 | 405 KiB/429 KiB/446 KiB | 1.00 MiB | 23.2 MiB/24.1 MiB/27.2 MiB | 40,679 | 81,198 |
| hotcold_100m | 32 | 5,252/5,417/5,505 | 424 KiB/438 KiB/447 KiB | 1.00 MiB | 43.2 MiB | 70,533 | 111,115 |
| hotcold_100m | 64 | 5,236/5,419/5,516 | 422 KiB/438 KiB/446 KiB | 1.00 MiB | 31.2 MiB/31.4 MiB/33.2 MiB | 56,162 | 119,174 |
| hotcold_100m | 128 | 5,320/5,458/5,523 | 430 KiB/442 KiB/447 KiB | 1.00 MiB | 25.2 MiB/25.4 MiB/27.2 MiB | 43,115 | 116,978 |
| hotcold_100m | 256 | 5,250/5,475/5,510 | 424 KiB/443 KiB/447 KiB | 1.00 MiB | 21.2 MiB | 25,576 | 109,778 |

## Final Gauges

Final values from pg_stat_statements_info, captured after each pgbench run.
These do not require scanning the pg_stat_statements view.

| workload | clients | patched final entries | patched final qtext count | patched final qtext payload | patched final qtext DSA | patched final entry DSA | patched final dealloc | baseline final dealloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 5,240 | 5,240 | 422 KiB | 1.00 MiB | 5.25 MiB | 3,990 | 7,735 |
| hotcold_100m | 2 | 5,437 | 5,437 | 440 KiB | 1.00 MiB | 5.25 MiB | 7,782 | 15,063 |
| hotcold_100m | 4 | 5,461 | 5,461 | 442 KiB | 1.00 MiB | 9.25 MiB | 14,927 | 29,208 |
| hotcold_100m | 8 | 5,473 | 5,473 | 443 KiB | 1.00 MiB | 19.2 MiB | 27,403 | 52,173 |
| hotcold_100m | 16 | 5,296 | 5,296 | 427 KiB | 1.00 MiB | 23.2 MiB | 43,980 | 87,776 |
| hotcold_100m | 32 | 5,002 | 5,002 | 400 KiB | 1.00 MiB | 43.2 MiB | 76,243 | 120,093 |
| hotcold_100m | 64 | 5,342 | 5,342 | 431 KiB | 1.00 MiB | 31.2 MiB | 60,720 | 128,790 |
| hotcold_100m | 128 | 5,264 | 5,264 | 424 KiB | 1.00 MiB | 25.2 MiB | 46,556 | 126,424 |
| hotcold_100m | 256 | 5,130 | 5,130 | 412 KiB | 1.00 MiB | 21.2 MiB | 27,555 | 118,596 |
| select_only | 1 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |
| select_only | 2 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |
| select_only | 4 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |
| select_only | 8 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |
| select_only | 16 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |
| select_only | 32 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |
| select_only | 64 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |
| select_only | 128 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |
| select_only | 256 | 7 | 7 | 2.70 KiB | 2.00 MiB | 21.2 MiB | 0 | 0 |

## Memory Gauge Averages

Average values from the periodic samples. Memory values use human-readable IEC units.

| workload | clients | avg entries | avg qtext count | avg qtext payload | avg qtext DSA | avg entry DSA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 5,038 | 5,311 | 429 KiB | 1.00 MiB | 5.25 MiB |
| hotcold_100m | 2 | 4,740 | 5,228 | 422 KiB | 1.00 MiB | 5.25 MiB |
| hotcold_100m | 4 | 4,401 | 5,185 | 418 KiB | 1.00 MiB | 9.25 MiB |
| hotcold_100m | 8 | 4,304 | 5,252 | 424 KiB | 1.00 MiB | 19.2 MiB |
| hotcold_100m | 16 | 4,207 | 5,310 | 429 KiB | 1.00 MiB | 24.1 MiB |
| hotcold_100m | 32 | 4,220 | 5,417 | 438 KiB | 1.00 MiB | 43.2 MiB |
| hotcold_100m | 64 | 4,340 | 5,419 | 438 KiB | 1.00 MiB | 31.4 MiB |
| hotcold_100m | 128 | 4,326 | 5,458 | 442 KiB | 1.00 MiB | 25.4 MiB |
| hotcold_100m | 256 | 4,181 | 5,475 | 443 KiB | 1.00 MiB | 21.2 MiB |
| select_only | 1 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |
| select_only | 2 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |
| select_only | 4 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |
| select_only | 8 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |
| select_only | 16 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |
| select_only | 32 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |
| select_only | 64 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |
| select_only | 128 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |
| select_only | 256 | 6 | 6 | 2.28 KiB | 2.00 MiB | 21.2 MiB |

## Wait Events

| workload | variant | active samples | pgss LWLock | PgStatsDSA | PgStatsHash | qtext LWLock | SpinDelay | ClientRead | cpu/no wait |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | baseline | 207,057 | 148,857 | 0 | 0 | 0 | 3,793 | 27,958 | 26,449 |
| hotcold_100m | patched | 57,217 | 0 | 3,813 | 2,527 | 1,075 | 417 | 26,374 | 23,006 |
| select_only | baseline | 63,568 | 0 | 0 | 0 | 0 | 5,256 | 28,544 | 20,194 |
| select_only | patched | 57,996 | 0 | 0 | 0 | 0 | 456 | 26,356 | 20,193 |

## Wait Event Diffs

Values are patched minus baseline sample counts from the same run.

| workload | event | baseline samples | patched samples | delta | change |
| --- | --- | ---: | ---: | ---: | ---: |
| hotcold_100m | active samples | 207,057 | 57,217 | -149,840 | -72.4% |
| hotcold_100m | pg_stat_statements LWLock | 148,857 | 0 | -148,857 | -100.0% |
| hotcold_100m | PgStatsDSA LWLock | 0 | 3,813 | +3,813 | new |
| hotcold_100m | PgStatsHash LWLock | 0 | 2,527 | +2,527 | new |
| hotcold_100m | query-text LWLock | 0 | 1,075 | +1,075 | new |
| hotcold_100m | SpinDelay | 3,793 | 417 | -3,376 | -89.0% |
| hotcold_100m | ClientRead | 27,958 | 26,374 | -1,584 | -5.7% |
| hotcold_100m | cpu/no wait | 26,449 | 23,006 | -3,443 | -13.0% |
| select_only | active samples | 63,568 | 57,996 | -5,572 | -8.8% |
| select_only | SpinDelay | 5,256 | 456 | -4,800 | -91.3% |
| select_only | ClientRead | 28,544 | 26,356 | -2,188 | -7.7% |
| select_only | cpu/no wait | 20,194 | 20,193 | -1 | -0.0% |

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
