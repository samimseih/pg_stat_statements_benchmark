# pg_stat_statements benchmark report

## Summary

- hotcold_100m throughput improved by +0.1% to +105.3% across reported non-single-client points.
- select_only changed by -2.9% to +0.7% across reported non-single-client points.
- Successful retention samples retained at least 4,000 popular statements at every reported churn point.
- Patched qtext_count high-water from samples/final info was 5,501 for hotcold_100m.
- Patched entry DSA high-water from samples/final info was 45.2 MiB.
- Baseline churn sampled 409,092 pg_stat_statements LWLock waits; patched sampled 0.
- Patched replacement pgstat/qtext waits under churn totaled 19,571 samples.
- Baseline SpinDelay samples were 18,191 versus 1,560 for patched.

## Run

| item | value |
| --- | --- |
| result directory | `EC2 c7i.8xlarge run pgss-qtext1gb-20261016T195803Z` |
| patched | [`3aed63027a2b`](https://github.com/samimseih/postgres/commit/3aed63027a2b) - pg_stat_statements_v14, query_text_memory=1GB |
| baseline | [`af090508018b`](https://github.com/postgres/postgres/commit/af090508018b) - PostgreSQL master |
| hot/cold duration | 1600 seconds per point |
| select-only duration | 1600 seconds per point |
| report client points | `1 2 4 8 16 32 64 128 256` |
| patched query text memory | `1GB` |
| failed pgbench rows | 0 |

## Throughput

### hotcold_100m

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 32,541 | 33,130 | -1.8% |
| 2 | 63,516 | 63,428 | +0.1% |
| 4 | 126,839 | 122,063 | +3.9% |
| 8 | 240,585 | 221,252 | +8.7% |
| 16 | 431,408 | 371,410 | +16.2% |
| 32 | 1,021,546 | 497,631 | +105.3% |
| 64 | 927,161 | 531,025 | +74.6% |
| 128 | 721,209 | 520,059 | +38.7% |
| 256 | 795,702 | 495,577 | +60.6% |

### select_only

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 31,842 | 31,938 | -0.3% |
| 2 | 61,250 | 61,418 | -0.3% |
| 4 | 122,540 | 121,910 | +0.5% |
| 8 | 235,475 | 236,014 | -0.2% |
| 16 | 424,293 | 423,882 | +0.1% |
| 32 | 1,015,495 | 1,008,832 | +0.7% |
| 64 | 908,487 | 908,612 | -0.0% |
| 128 | 768,358 | 791,416 | -2.9% |
| 256 | 687,547 | 683,365 | +0.6% |

## Retention

Values are sampled min/avg/max.

| workload | clients | patched entries min/avg/max | baseline entries min/avg/max | patched pop min/avg/max | baseline pop min/avg/max | patched unpop min/avg/max | baseline unpop min/avg/max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 4,000/4,535/5,485 | 4,757/4,879/4,992 | 4,000 | 4,000 | 0/534/1,485 | 757/879/992 |
| hotcold_100m | 2 | 4,000/4,273/5,284 | 4,760/4,884/4,998 | 4,000 | 4,000 | 0/273/1,284 | 760/884/998 |
| hotcold_100m | 4 | 4,000/4,174/5,285 | 4,756/4,883/4,991 | 4,000 | 4,000 | 0/174/1,285 | 756/883/991 |
| hotcold_100m | 8 | 4,000/4,122/5,062 | 4,750/4,842/4,988 | 4,000 | 4,000 | 0/122/1,062 | 749/842/988 |
| hotcold_100m | 16 | 4,000/4,059/4,606 | 4,750/4,850/4,953 | 4,000 | 4,000 | 0/59/606 | 750/850/953 |
| hotcold_100m | 32 | 4,000/4,073/4,987 | 4,750/4,871/4,980 | 4,000 | 4,000 | 0/73/987 | 750/871/980 |
| hotcold_100m | 64 | 4,000/4,143/4,940 | 4,751/4,852/4,978 | 4,000 | 4,000 | 0/143/940 | 751/852/978 |
| hotcold_100m | 128 | 4,000/4,123/5,024 | 4,742/4,859/4,983 | 4,000 | 4,000 | 0/123/1,024 | 742/859/983 |
| hotcold_100m | 256 | 4,000/4,110/5,142 | 4,753/4,888/4,998 | 4,000 | 4,000 | 0/110/1,142 | 753/888/998 |

## Sampled Query Text And Churn

Query-text and memory values from periodic samples are min/avg/max.
Memory values use human-readable IEC units.

| workload | clients | patched qtext count | patched qtext payload min/avg/max | patched qtext DSA min/avg/max | patched entry DSA min/avg/max | patched dealloc | baseline dealloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 5,023/5,232/5,489 | 403 KiB/422 KiB/445 KiB | 1.00 MiB | 5.25 MiB | 10,255 | 20,883 |
| hotcold_100m | 2 | 5,029/5,242/5,494 | 404 KiB/423 KiB/446 KiB | 1.00 MiB | 5.25 MiB/6.88 MiB/9.25 MiB | 19,867 | 39,978 |
| hotcold_100m | 4 | 5,040/5,294/5,499 | 405 KiB/428 KiB/446 KiB | 1.00 MiB | 9.25 MiB | 39,045 | 76,940 |
| hotcold_100m | 8 | 5,069/5,299/5,500 | 407 KiB/428 KiB/446 KiB | 1.00 MiB | 21.2 MiB | 71,129 | 139,445 |
| hotcold_100m | 16 | 5,057/5,244/5,500 | 406 KiB/423 KiB/445 KiB | 1.00 MiB | 29.2 MiB | 115,605 | 234,103 |
| hotcold_100m | 32 | 5,206/5,421/5,501 | 420 KiB/438 KiB/446 KiB | 1.00 MiB | 45.2 MiB | 200,568 | 313,649 |
| hotcold_100m | 64 | 5,219/5,429/5,501 | 421 KiB/439 KiB/446 KiB | 1.00 MiB | 45.2 MiB | 154,635 | 334,688 |
| hotcold_100m | 128 | 5,336/5,471/5,501 | 431 KiB/443 KiB/446 KiB | 1.00 MiB | 45.2 MiB | 116,072 | 327,738 |
| hotcold_100m | 256 | 5,270/5,480/5,501 | 426 KiB/444 KiB/446 KiB | 1.00 MiB | 45.2 MiB | 63,458 | 312,274 |

## Final Gauges

Final values from pg_stat_statements_info, captured after each pgbench run.
These do not require scanning the pg_stat_statements view.

| workload | clients | patched final entries | patched final qtext count | patched final qtext payload | patched final qtext DSA | patched final entry DSA | patched final dealloc | baseline final dealloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 5,280 | 5,280 | 426 KiB | 1.00 MiB | 5.25 MiB | 10,412 | 21,202 |
| hotcold_100m | 2 | 5,420 | 5,420 | 438 KiB | 1.00 MiB | 9.25 MiB | 20,178 | 40,601 |
| hotcold_100m | 4 | 5,030 | 5,030 | 403 KiB | 1.00 MiB | 9.25 MiB | 39,648 | 78,121 |
| hotcold_100m | 8 | 5,189 | 5,189 | 417 KiB | 1.00 MiB | 21.2 MiB | 72,238 | 141,589 |
| hotcold_100m | 16 | 5,169 | 5,169 | 415 KiB | 1.00 MiB | 29.2 MiB | 117,398 | 237,732 |
| hotcold_100m | 32 | 5,078 | 5,078 | 407 KiB | 1.00 MiB | 45.2 MiB | 203,580 | 318,518 |
| hotcold_100m | 64 | 5,165 | 5,165 | 415 KiB | 1.00 MiB | 45.2 MiB | 156,963 | 339,853 |
| hotcold_100m | 128 | 5,086 | 5,086 | 408 KiB | 1.00 MiB | 45.2 MiB | 117,816 | 332,851 |
| hotcold_100m | 256 | 5,480 | 5,480 | 444 KiB | 1.00 MiB | 45.2 MiB | 64,383 | 317,091 |
| select_only | 1 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |
| select_only | 2 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |
| select_only | 4 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |
| select_only | 8 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |
| select_only | 16 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |
| select_only | 32 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |
| select_only | 64 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |
| select_only | 128 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |
| select_only | 256 | 7 | 7 | 2.70 KiB | 2.00 MiB | 45.2 MiB | 0 | 0 |

## Memory Gauge Averages

Average values from the periodic samples. Memory values use human-readable IEC units.

| workload | clients | avg entries | avg qtext count | avg qtext payload | avg qtext DSA | avg entry DSA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | 1 | 4,535 | 5,232 | 422 KiB | 1.00 MiB | 5.25 MiB |
| hotcold_100m | 2 | 4,273 | 5,242 | 423 KiB | 1.00 MiB | 6.88 MiB |
| hotcold_100m | 4 | 4,174 | 5,294 | 428 KiB | 1.00 MiB | 9.25 MiB |
| hotcold_100m | 8 | 4,122 | 5,299 | 428 KiB | 1.00 MiB | 21.2 MiB |
| hotcold_100m | 16 | 4,059 | 5,244 | 423 KiB | 1.00 MiB | 29.2 MiB |
| hotcold_100m | 32 | 4,073 | 5,421 | 438 KiB | 1.00 MiB | 45.2 MiB |
| hotcold_100m | 64 | 4,143 | 5,429 | 439 KiB | 1.00 MiB | 45.2 MiB |
| hotcold_100m | 128 | 4,123 | 5,471 | 443 KiB | 1.00 MiB | 45.2 MiB |
| hotcold_100m | 256 | 4,110 | 5,480 | 444 KiB | 1.00 MiB | 45.2 MiB |
| select_only | 1 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |
| select_only | 2 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |
| select_only | 4 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |
| select_only | 8 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |
| select_only | 16 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |
| select_only | 32 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |
| select_only | 64 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |
| select_only | 128 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |
| select_only | 256 | 6 | 6 | 2.28 KiB | 2.00 MiB | 45.2 MiB |

## Wait Events

| workload | variant | active samples | pgss LWLock | PgStatsDSA | PgStatsHash | qtext LWLock | SpinDelay | ClientRead | cpu/no wait |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_100m | baseline | 563,971 | 409,092 | 0 | 0 | 0 | 9,874 | 75,717 | 69,288 |
| hotcold_100m | patched | 153,244 | 0 | 9,532 | 6,733 | 3,306 | 513 | 69,736 | 63,410 |
| select_only | baseline | 163,810 | 0 | 0 | 0 | 0 | 8,317 | 73,831 | 54,395 |
| select_only | patched | 157,407 | 0 | 0 | 0 | 0 | 1,047 | 73,100 | 53,947 |

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
