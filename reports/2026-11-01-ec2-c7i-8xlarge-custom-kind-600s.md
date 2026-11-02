# pg_stat_statements benchmark report

## Summary

- hotcold_4000_100m throughput improved by -1.3% to +24.7% across reported non-single-client points.
- hotcold_4000_1500 throughput improved by +0.9% to +42.3% across reported non-single-client points.
- select_only changed by -1.9% to +1.1% across reported non-single-client points.
- Successful retention samples retained at least 4,000 popular statements at every reported churn point.
- Patched qtext_count high-water from samples/final info was 0 for hotcold_4000_100m and 0 for hotcold_4000_1500.
- Empty-query sampled high-water was 0 for patched and 0 for baseline.
- Baseline churn sampled 195,161 pg_stat_statements LWLock waits; patched sampled 0.
- Patched replacement pgstat/qtext waits under churn totaled 8,075 samples.
- Baseline SpinDelay samples were 8,866 versus 797 for patched.

## Run

| item | value |
| --- | --- |
| result directory | `EC2 c7i.8xlarge run, custom cumulative stats kind, 2026-11-01T2235Z` |
| patched | [`7bc3659ab09c`](https://github.com/samimseih/postgres/commit/7bc3659ab09c6f73201af0409fa17ddf9757aadb) - pg_stat_statements_custom_kind_only_v2 |
| baseline | [`00d33e82bbb0`](https://github.com/postgres/postgres/commit/00d33e82bbb0) - PostgreSQL master |
| hot/cold duration | 600 seconds per point |
| select-only duration | 600 seconds per point |
| report client points | `1 2 4 8 16 32 64 128 256` |
| failed pgbench rows | 0 |

## Workload And Retention Legend

| name | meaning |
| --- | --- |
| `hotcold_4000_100m` | 4,000 stable hot/popular statements plus a large cold/churn keyspace. |
| `hotcold_4000_1500` | 4,000 stable hot/popular statements plus 1,500 cold/churn statements. |
| `pop/unpop` | sampled retained hot/popular entries and cold/churn entries. |

## Throughput

### hotcold_4000_100m

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 32,896 | 32,733 | +0.5% |
| 2 | 63,620 | 64,481 | -1.3% |
| 4 | 122,776 | 124,294 | -1.2% |
| 8 | 229,110 | 229,050 | +0.0% |
| 16 | 384,638 | 385,550 | -0.2% |
| 32 | 660,821 | 529,949 | +24.7% |
| 64 | 652,442 | 561,252 | +16.2% |
| 128 | 604,874 | 554,722 | +9.0% |
| 256 | 539,546 | 535,920 | +0.7% |

### hotcold_4000_1500

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 33,789 | 33,818 | -0.1% |
| 2 | 66,395 | 65,784 | +0.9% |
| 4 | 131,641 | 129,065 | +2.0% |
| 8 | 256,947 | 245,775 | +4.5% |
| 16 | 457,804 | 425,179 | +7.7% |
| 32 | 1,174,828 | 825,331 | +42.3% |
| 64 | 1,056,385 | 805,269 | +31.2% |
| 128 | 980,507 | 779,053 | +25.9% |
| 256 | 926,686 | 685,627 | +35.2% |

### select_only

| clients | patched TPS | baseline TPS | delta |
| ---: | ---: | ---: | ---: |
| 1 | 32,397 | 32,509 | -0.3% |
| 2 | 62,585 | 62,396 | +0.3% |
| 4 | 122,565 | 122,294 | +0.2% |
| 8 | 238,917 | 237,195 | +0.7% |
| 16 | 431,061 | 428,638 | +0.6% |
| 32 | 1,057,333 | 1,052,406 | +0.5% |
| 64 | 959,357 | 952,545 | +0.7% |
| 128 | 800,997 | 816,621 | -1.9% |
| 256 | 724,504 | 716,473 | +1.1% |

## Retention

Values are sampled min/avg/max.

| workload | clients | patched entries min/avg/max | baseline entries min/avg/max | patched pop min/avg/max | baseline pop min/avg/max | patched unpop min/avg/max | baseline unpop min/avg/max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_4000_100m | 1 | 5,250/5,548/5,872 | 4,758/4,863/4,991 | 3,999/4,000/4,000 | 4,000 | 1,249/1,547/1,871 | 758/863/991 |
| hotcold_4000_100m | 2 | 5,251/5,372/5,923 | 4,783/4,889/4,962 | 4,000 | 4,000 | 1,250/1,372/1,922 | 783/888/962 |
| hotcold_4000_100m | 4 | 5,253/5,319/5,878 | 4,761/4,868/4,952 | 4,000 | 4,000 | 1,252/1,318/1,877 | 761/868/952 |
| hotcold_4000_100m | 8 | 5,253/5,328/5,765 | 4,754/4,841/4,963 | 4,000 | 4,000 | 1,252/1,327/1,764 | 754/841/963 |
| hotcold_4000_100m | 16 | 5,250/5,276/5,374 | 4,750/4,854/4,961 | 4,000 | 4,000 | 1,249/1,275/1,373 | 750/854/961 |
| hotcold_4000_100m | 32 | 5,250/5,250/5,251 | 4,753/4,878/4,965 | 3,990/3,999/4,000 | 4,000 | 1,249/1,250/1,260 | 753/878/965 |
| hotcold_4000_100m | 64 | 5,245/5,249/5,250 | 4,750/4,876/4,988 | 3,934/3,993/4,000 | 4,000 | 1,244/1,254/1,314 | 750/876/988 |
| hotcold_4000_100m | 128 | 5,205/5,232/5,266 | 4,763/4,880/4,998 | 3,983/3,998/4,000 | 4,000 | 1,210/1,231/1,251 | 763/880/998 |
| hotcold_4000_100m | 256 | 5,098/5,185/5,235 | 4,752/4,886/4,977 | 3,998/4,000/4,000 | 4,000 | 1,097/1,182/1,231 | 752/886/977 |
| hotcold_4000_1500 | 1 | 5,501/5,502/5,502 | 4,819/4,922/4,998 | 4,000 | 3,997/3,999/4,000 | 1,500 | 822/923/998 |
| hotcold_4000_1500 | 2 | 5,501/5,502/5,502 | 4,753/4,873/4,962 | 4,000 | 4,000 | 1,500 | 753/873/962 |
| hotcold_4000_1500 | 4 | 5,502/5,503/5,503 | 4,770/4,874/4,978 | 4,000 | 3,999/4,000/4,000 | 1,500 | 770/874/977 |
| hotcold_4000_1500 | 8 | 5,502/5,503/5,503 | 4,750/4,874/4,999 | 4,000 | 4,000 | 1,500 | 750/874/999 |
| hotcold_4000_1500 | 16 | 5,502/5,503/5,503 | 4,806/4,878/4,993 | 4,000 | 3,999/4,000/4,000 | 1,500 | 806/878/993 |
| hotcold_4000_1500 | 32 | 5,502/5,503/5,503 | 4,750/4,837/4,998 | 4,000 | 4,000 | 1,500 | 750/837/998 |
| hotcold_4000_1500 | 64 | 5,502/5,503/5,503 | 4,753/4,886/4,974 | 4,000 | 4,000 | 1,500 | 753/886/974 |
| hotcold_4000_1500 | 128 | 5,502/5,503/5,503 | 4,773/4,872/4,991 | 4,000 | 4,000 | 1,500 | 773/872/991 |
| hotcold_4000_1500 | 256 | 5,502/5,503/5,503 | 4,750/4,836/4,955 | 4,000 | 4,000 | 1,500 | 750/836/955 |

## Sampled Query Text And Churn

Query-text, empty-query, and memory values from periodic samples are min/avg/max.
Memory values use human-readable IEC units.

| workload | clients | patched empty query entries | baseline empty query entries | patched qtext count | patched qtext payload min/avg/max | patched qtext file min/avg/max | baseline qtext file min/avg/max | patched qtext DSA min/avg/max | patched entry DSA min/avg/max | patched dealloc | baseline dealloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_4000_100m | 1 | 0 | 0 | 0 | 0 B | 753 KiB/1.92 MiB/4.80 MiB | 541 KiB/1.33 MiB/2.27 MiB | 0 B | 0 B | 3,650 | 7,271 |
| hotcold_4000_100m | 2 | 0 | 0 | 0 | 0 B | 688 KiB/2.19 MiB/9.00 MiB | 502 KiB/1005 KiB/1.73 MiB | 0 B | 0 B | 9,394 | 14,330 |
| hotcold_4000_100m | 4 | 0 | 0 | 0 | 0 B | 1.00 MiB/1.73 MiB/2.36 MiB | 692 KiB/1.34 MiB/2.29 MiB | 0 B | 0 B | 18,243 | 27,570 |
| hotcold_4000_100m | 8 | 0 | 0 | 0 | 0 B | 643 KiB/1.44 MiB/2.31 MiB | 453 KiB/1.48 MiB/2.37 MiB | 0 B | 0 B | 34,407 | 50,884 |
| hotcold_4000_100m | 16 | 0 | 0 | 0 | 0 B | 124 KiB/1.12 MiB/1.71 MiB | 400 KiB/1.42 MiB/2.38 MiB | 0 B | 0 B | 60,631 | 85,577 |
| hotcold_4000_100m | 32 | 0 | 0 | 0 | 0 B | 435 KiB/1.41 MiB/2.23 MiB | 417 KiB/1.32 MiB/2.30 MiB | 0 B | 0 B | 120,777 | 117,666 |
| hotcold_4000_100m | 64 | 0 | 0 | 0 | 0 B | 485 KiB/1.35 MiB/2.05 MiB | 860 KiB/1.61 MiB/2.35 MiB | 0 B | 0 B | 127,646 | 124,648 |
| hotcold_4000_100m | 128 | 0 | 0 | 0 | 0 B | 433 KiB/1.58 MiB/2.38 MiB | 753 KiB/1.37 MiB/2.24 MiB | 0 B | 0 B | 128,998 | 123,205 |
| hotcold_4000_100m | 256 | 0 | 0 | 0 | 0 B | 571 KiB/1.41 MiB/2.07 MiB | 793 KiB/1.83 MiB/2.44 MiB | 0 B | 0 B | 117,937 | 118,973 |
| hotcold_4000_1500 | 1 | 0 | 0 | 0 | 0 B | 458 KiB/459 KiB/459 KiB | 396 KiB/1.25 MiB/2.03 MiB | 0 B | 0 B | 1 | 3,103 |
| hotcold_4000_1500 | 2 | 0 | 0 | 0 | 0 B | 458 KiB/459 KiB/459 KiB | 587 KiB/1.41 MiB/2.26 MiB | 0 B | 0 B | 1 | 6,003 |
| hotcold_4000_1500 | 4 | 0 | 0 | 0 | 0 B | 457 KiB/459 KiB/459 KiB | 378 KiB/1.07 MiB/1.98 MiB | 0 B | 0 B | 1 | 11,789 |
| hotcold_4000_1500 | 8 | 0 | 0 | 0 | 0 B | 457 KiB/459 KiB/459 KiB | 656 KiB/1.50 MiB/2.26 MiB | 0 B | 0 B | 1 | 22,418 |
| hotcold_4000_1500 | 16 | 0 | 0 | 0 | 0 B | 457 KiB/459 KiB/459 KiB | 437 KiB/1.29 MiB/2.31 MiB | 0 B | 0 B | 1 | 38,794 |
| hotcold_4000_1500 | 32 | 0 | 0 | 0 | 0 B | 457 KiB/459 KiB/459 KiB | 609 KiB/1.42 MiB/2.21 MiB | 0 B | 0 B | 1 | 75,327 |
| hotcold_4000_1500 | 64 | 0 | 0 | 0 | 0 B | 457 KiB/459 KiB/459 KiB | 432 KiB/856 KiB/2.23 MiB | 0 B | 0 B | 1 | 73,333 |
| hotcold_4000_1500 | 128 | 0 | 0 | 0 | 0 B | 457 KiB/459 KiB/459 KiB | 645 KiB/1.60 MiB/2.37 MiB | 0 B | 0 B | 1 | 70,681 |
| hotcold_4000_1500 | 256 | 0 | 0 | 0 | 0 B | 457 KiB/459 KiB/459 KiB | 645 KiB/1.43 MiB/2.38 MiB | 0 B | 0 B | 1 | 61,888 |

## Final Gauges

Final values from pg_stat_statements_info, captured after each pgbench run.
These do not require scanning the pg_stat_statements view.

| workload | clients | patched final entries | patched final qtext count | patched final qtext payload | patched final qtext DSA | patched final qtext file | baseline final qtext file | patched final entry DSA | patched final dealloc | baseline final dealloc |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_4000_100m | 1 | 0 | 0 | 0 B | 0 B | 2.27 MiB | 1.38 MiB | 0 B | 3,942 | 7,857 |
| hotcold_4000_100m | 2 | 0 | 0 | 0 B | 0 B | 1.24 MiB | 1.43 MiB | 0 B | 10,144 | 15,485 |
| hotcold_4000_100m | 4 | 0 | 0 | 0 B | 0 B | 609 KiB | 1.19 MiB | 0 B | 19,708 | 29,796 |
| hotcold_4000_100m | 8 | 0 | 0 | 0 B | 0 B | 1.21 MiB | 642 KiB | 0 B | 37,180 | 54,974 |
| hotcold_4000_100m | 16 | 0 | 0 | 0 B | 0 B | 1.36 MiB | 1.44 MiB | 0 B | 65,520 | 92,490 |
| hotcold_4000_100m | 32 | 0 | 0 | 0 B | 0 B | 469 KiB | 1.64 MiB | 0 B | 130,448 | 127,188 |
| hotcold_4000_100m | 64 | 0 | 0 | 0 B | 0 B | 1.57 MiB | 1.70 MiB | 0 B | 137,893 | 134,723 |
| hotcold_4000_100m | 128 | 0 | 0 | 0 B | 0 B | 1.31 MiB | 1.71 MiB | 0 B | 139,585 | 133,142 |
| hotcold_4000_100m | 256 | 0 | 0 | 0 B | 0 B | 2.41 MiB | 1.40 MiB | 0 B | 127,267 | 128,589 |
| hotcold_4000_1500 | 1 | 0 | 0 | 0 B | 0 B | 459 KiB | 1.27 MiB | 0 B | 1 | 3,353 |
| hotcold_4000_1500 | 2 | 0 | 0 | 0 B | 0 B | 459 KiB | 1.34 MiB | 0 B | 1 | 6,486 |
| hotcold_4000_1500 | 4 | 0 | 0 | 0 B | 0 B | 459 KiB | 1.30 MiB | 0 B | 1 | 12,734 |
| hotcold_4000_1500 | 8 | 0 | 0 | 0 B | 0 B | 459 KiB | 2.26 MiB | 0 B | 1 | 24,223 |
| hotcold_4000_1500 | 16 | 0 | 0 | 0 B | 0 B | 459 KiB | 721 KiB | 0 B | 1 | 41,928 |
| hotcold_4000_1500 | 32 | 0 | 0 | 0 B | 0 B | 459 KiB | 1.10 MiB | 0 B | 1 | 81,362 |
| hotcold_4000_1500 | 64 | 0 | 0 | 0 B | 0 B | 459 KiB | 1.31 MiB | 0 B | 1 | 79,254 |
| hotcold_4000_1500 | 128 | 0 | 0 | 0 B | 0 B | 459 KiB | 1.18 MiB | 0 B | 1 | 76,382 |
| hotcold_4000_1500 | 256 | 0 | 0 | 0 B | 0 B | 459 KiB | 2.25 MiB | 0 B | 1 | 66,885 |
| select_only | 1 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 2.33 KiB | 0 B | 0 | 0 |
| select_only | 2 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 2.33 KiB | 0 B | 0 | 0 |
| select_only | 4 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 2.33 KiB | 0 B | 0 | 0 |
| select_only | 8 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 2.54 KiB | 0 B | 0 | 0 |
| select_only | 16 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 2.38 KiB | 0 B | 0 | 0 |
| select_only | 32 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 2.33 KiB | 0 B | 0 | 0 |
| select_only | 64 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 2.33 KiB | 0 B | 0 | 0 |
| select_only | 128 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 3.88 KiB | 0 B | 0 | 0 |
| select_only | 256 | 0 | 0 | 0 B | 0 B | 2.33 KiB | 2.59 KiB | 0 B | 0 | 0 |

## Memory Gauge Averages

Average values from the periodic samples. Memory values use human-readable IEC units.

| workload | clients | avg entries | avg qtext count | avg qtext payload | avg qtext file | avg qtext DSA | avg entry DSA |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_4000_100m | 1 | 5,548 | 0 | 0 B | 1.92 MiB | 0 B | 0 B |
| hotcold_4000_100m | 2 | 5,372 | 0 | 0 B | 2.19 MiB | 0 B | 0 B |
| hotcold_4000_100m | 4 | 5,319 | 0 | 0 B | 1.73 MiB | 0 B | 0 B |
| hotcold_4000_100m | 8 | 5,328 | 0 | 0 B | 1.44 MiB | 0 B | 0 B |
| hotcold_4000_100m | 16 | 5,276 | 0 | 0 B | 1.12 MiB | 0 B | 0 B |
| hotcold_4000_100m | 32 | 5,250 | 0 | 0 B | 1.41 MiB | 0 B | 0 B |
| hotcold_4000_100m | 64 | 5,249 | 0 | 0 B | 1.35 MiB | 0 B | 0 B |
| hotcold_4000_100m | 128 | 5,232 | 0 | 0 B | 1.58 MiB | 0 B | 0 B |
| hotcold_4000_100m | 256 | 5,185 | 0 | 0 B | 1.41 MiB | 0 B | 0 B |
| hotcold_4000_1500 | 1 | 5,502 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| hotcold_4000_1500 | 2 | 5,502 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| hotcold_4000_1500 | 4 | 5,503 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| hotcold_4000_1500 | 8 | 5,503 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| hotcold_4000_1500 | 16 | 5,503 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| hotcold_4000_1500 | 32 | 5,503 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| hotcold_4000_1500 | 64 | 5,503 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| hotcold_4000_1500 | 128 | 5,503 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| hotcold_4000_1500 | 256 | 5,503 | 0 | 0 B | 459 KiB | 0 B | 0 B |
| select_only | 1 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |
| select_only | 2 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |
| select_only | 4 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |
| select_only | 8 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |
| select_only | 16 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |
| select_only | 32 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |
| select_only | 64 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |
| select_only | 128 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |
| select_only | 256 | 6 | 0 | 0 B | 2.19 KiB | 0 B | 0 B |

## Wait Events

| workload | variant | active samples | pgss LWLock | PgStatsDSA | PgStatsHash | qtext LWLock | SpinDelay | ClientRead | cpu/no wait |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hotcold_4000_100m | baseline | 204,499 | 147,261 | 0 | 0 | 0 | 4,445 | 28,178 | 24,615 |
| hotcold_4000_100m | patched | 189,762 | 0 | 6,772 | 1,303 | 0 | 398 | 20,786 | 42,545 |
| hotcold_4000_1500 | baseline | 103,817 | 47,900 | 0 | 0 | 0 | 1,466 | 32,340 | 22,111 |
| hotcold_4000_1500 | patched | 48,571 | 0 | 0 | 0 | 0 | 0 | 28,237 | 20,332 |
| select_only | baseline | 63,150 | 0 | 0 | 0 | 0 | 2,955 | 27,977 | 20,872 |
| select_only | patched | 58,954 | 0 | 0 | 0 | 0 | 399 | 27,866 | 20,023 |

## Wait Event Diffs

Values are patched minus baseline sample counts from the same run.

| workload | event | baseline samples | patched samples | delta | change |
| --- | --- | ---: | ---: | ---: | ---: |
| hotcold_4000_100m | active samples | 204,499 | 189,762 | -14,737 | -7.2% |
| hotcold_4000_100m | pg_stat_statements LWLock | 147,261 | 0 | -147,261 | -100.0% |
| hotcold_4000_100m | PgStatsDSA LWLock | 0 | 6,772 | +6,772 | new |
| hotcold_4000_100m | PgStatsHash LWLock | 0 | 1,303 | +1,303 | new |
| hotcold_4000_100m | SpinDelay | 4,445 | 398 | -4,047 | -91.0% |
| hotcold_4000_100m | ClientRead | 28,178 | 20,786 | -7,392 | -26.2% |
| hotcold_4000_100m | cpu/no wait | 24,615 | 42,545 | +17,930 | +72.8% |
| hotcold_4000_1500 | active samples | 103,817 | 48,571 | -55,246 | -53.2% |
| hotcold_4000_1500 | pg_stat_statements LWLock | 47,900 | 0 | -47,900 | -100.0% |
| hotcold_4000_1500 | SpinDelay | 1,466 | 0 | -1,466 | -100.0% |
| hotcold_4000_1500 | ClientRead | 32,340 | 28,237 | -4,103 | -12.7% |
| hotcold_4000_1500 | cpu/no wait | 22,111 | 20,332 | -1,779 | -8.0% |
| select_only | active samples | 63,150 | 58,954 | -4,196 | -6.6% |
| select_only | SpinDelay | 2,955 | 399 | -2,556 | -86.5% |
| select_only | ClientRead | 27,977 | 27,866 | -111 | -0.4% |
| select_only | cpu/no wait | 20,872 | 20,023 | -849 | -4.1% |

## Notes

- Deallocation counters are eviction-pass counters, matching upstream
  pg_stat_statements_info semantics.
- Query-text and entry DSA columns are sampled current-state gauges;
  summary.tsv reports their sampled min/avg/max. Older commits that do
  not expose them report zero in summary.tsv.
- Empty-query entries are sampled as empty-string query text,
  separately from null query text.
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
