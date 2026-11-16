# Ablation of the releases of 9a1e08fa8d4 on c7i.24xlarge and c7i.48xlarge

| | |
|:---:|:---:|
| full | `e9fd4b6` |
| no-idle | `c69851c` |
| no-post-flush | `885eaa2` |
| upstream | `7fc2f04` |
| no pgss | upstream, run without pg_stat_statements loaded |

## How to read the tables

Each point has two tables, one row per build; no pgss is upstream run without
pg_stat_statements loaded.

- **TPS**, and the **speedup over upstream**: 2.0x is twice the TPS of upstream.
- **% of no-pgss**: the TPS of the build as a share of the TPS of no pgss on
  the same instance.
- **CV**: how much TPS varies within the run.
- **TPS trend**: the mean TPS of the last fifth of the run against the first
  fifth; in bold below -5%.
- **top waits**: the most frequent wait events of the active backends, as a
  share of samples, 1% or more; CPU is a backend running, not waiting.
- **allocated avg/max**: entries held by the stats kind, including dropped
  ones not freed yet.
- **recency**: entries of the view by how long ago they were created, on
  average over the run.
- **popular kept**: the fewest of the 4000 popular statements in the view.
- **evictions vs upstream**: eviction passes per transaction, against
  upstream: -27% is 27% fewer.
- **backstop**: share of the run at twice `pg_stat_statements.max`, where new
  statements are not tracked.
- **text / no-text**: size of the query text storage, in the file or in
  shared memory, and the most entries without a text.

Under each point, TPS by fifth of the run for each build, and for the
hotcold workloads the entries of the view by how long ago they were
created.

Workloads: hotcold_100m runs 4000 popular statements and 100 million others;
hotcold_1500 runs 4000 popular statements and 1500 others; hotcold_50k runs
4000 popular statements and 50000 others, shared across the backends; select_only runs
pgbench `-S`; SELECT 1 is `SELECT 1;` with the simple protocol.

## c7i.24xlarge, c7i.48xlarge, 3 min per build

Fleet `pgss-e9fd4b6-180s-20261116T2020Z`.

### c7i.24xlarge, 96 vCPUs

#### c7i.24xlarge · hotcold_100m, 256 clients

*Throughput*

| build | TPS | speedup<br>over<br>upstream | CV | TPS<br>trend | top waits |
|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream | 485.2k | 1.0x | 2.7% | −0.8% | 92% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>4% CPU<br>4% Client:<br>&nbsp;&nbsp;ClientRead |
| full | 1.44M | 3.0x | 0.6% | −1.5% | 80% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>10% CPU<br>9% Client:<br>&nbsp;&nbsp;ClientRead |
| no-idle | 1.43M | 2.9x | 0.2% | +0.0% | 81% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>10% CPU<br>9% Client:<br>&nbsp;&nbsp;ClientRead |
| no-post-flush | 1.43M | 2.9x | 0.2% | −0.2% | 81% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>10% CPU<br>9% Client:<br>&nbsp;&nbsp;ClientRead |

*Eviction*

| build | allocated<br>avg/max | recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m | popular<br>kept | evictions<br>vs<br>upstream | back-<br>stop | text /<br>no-text |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream |  | 881/0/1176/2824/0 | 4000 |  |  | 2.3MB / 0 |
| full | 4969/5129 | 985/0/1176/2824/0 | 4000 | −40% | 0% | 3.0MB / 0 |
| no-idle | 4966/5166 | 983/0/1176/2824/0 | 4000 | −39% | 0% | 3.0MB / 0 |
| no-post-flush | 5046/5208 | 990/0/1176/2824/0 | 4000 | −39% | 0% | 3.0MB / 0 |

TPS over the run, by fifth (change from the first fifth):

```
upstream fifth 1   #############                                489.4k
         fifth 2   #############                                485.9k  -0.7%
         fifth 3   #############                                487.1k  -0.5%
         fifth 4   #############                                483.5k  -1.2%
         fifth 5   #############                                485.6k  -0.8%
full     fifth 1   ########################################    1450.3k
         fifth 2   ########################################    1438.2k  -0.8%
         fifth 3   ########################################    1434.9k  -1.1%
         fifth 4   #######################################     1429.2k  -1.5%
         fifth 5   #######################################     1428.5k  -1.5%
no-idle  fifth 1   #######################################     1431.3k
         fifth 2   #######################################     1430.1k  -0.1%
         fifth 3   #######################################     1429.4k  -0.1%
         fifth 4   #######################################     1431.3k  -0.0%
         fifth 5   #######################################     1431.7k  +0.0%
no-post-flush fifth 1 #######################################     1431.7k
         fifth 2   #######################################     1431.0k  -0.0%
         fifth 3   #######################################     1430.2k  -0.1%
         fifth 4   #######################################     1430.2k  -0.1%
         fifth 5   #######################################     1429.4k  -0.2%
```

Entries of the view by how long ago they were created (40 # = 5000):

```
<1s       upstream #######                                  881
          full     ########                                 985
          no-idle  ########                                 983
          no-post-flush ########                                 990
1-10s     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
10s-1min  upstream #########                                1176
          full     #########                                1176
          no-idle  #########                                1176
          no-post-flush #########                                1176
1-5min    upstream #######################                  2824
          full     #######################                  2824
          no-idle  #######################                  2824
          no-post-flush #######################                  2824
>5min     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
```

#### c7i.24xlarge · hotcold_100m, 512 clients

*Throughput*

| build | TPS | speedup<br>over<br>upstream | CV | TPS<br>trend | top waits |
|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream | 446.8k | 1.0x | 4.4% | −2.0% | 95% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>2% CPU<br>2% Client:<br>&nbsp;&nbsp;ClientRead |
| full | 1.42M | 3.2x | 0.8% | −1.0% | 90% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>5% CPU<br>5% Client:<br>&nbsp;&nbsp;ClientRead |
| no-idle | 1.40M | 3.1x | 0.4% | −0.6% | 90% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>5% CPU<br>5% Client:<br>&nbsp;&nbsp;ClientRead |
| no-post-flush | 1.40M | 3.1x | 0.3% | −0.7% | 90% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>5% CPU<br>5% Client:<br>&nbsp;&nbsp;ClientRead |

*Eviction*

| build | allocated<br>avg/max | recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m | popular<br>kept | evictions<br>vs<br>upstream | back-<br>stop | text /<br>no-text |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream |  | 849/0/1176/2824/0 | 4000 |  |  | 2.4MB / 0 |
| full | 5024/5148 | 982/0/1176/2824/0 | 4000 | −40% | 0% | 3.0MB / 0 |
| no-idle | 4964/5088 | 1002/0/1176/2824/0 | 4000 | −39% | 0% | 3.0MB / 0 |
| no-post-flush | 5025/5161 | 995/0/1176/2824/0 | 4000 | −38% | 0% | 3.0MB / 0 |

TPS over the run, by fifth (change from the first fifth):

```
upstream fifth 1   #############                                454.8k
         fifth 2   #############                                448.5k  -1.4%
         fifth 3   ############                                 446.6k  -1.8%
         fifth 4   ############                                 444.6k  -2.2%
         fifth 5   ############                                 445.7k  -2.0%
full     fifth 1   ########################################    1420.4k
         fifth 2   ########################################    1430.5k  +0.7%
         fifth 3   ########################################    1420.3k  -0.0%
         fifth 4   ########################################    1413.2k  -0.5%
         fifth 5   #######################################     1406.9k  -1.0%
no-idle  fifth 1   #######################################     1401.9k
         fifth 2   #######################################     1397.7k  -0.3%
         fifth 3   #######################################     1397.8k  -0.3%
         fifth 4   #######################################     1395.0k  -0.5%
         fifth 5   #######################################     1393.7k  -0.6%
no-post-flush fifth 1 #######################################     1409.9k
         fifth 2   #######################################     1406.3k  -0.3%
         fifth 3   #######################################     1404.4k  -0.4%
         fifth 4   #######################################     1402.9k  -0.5%
         fifth 5   #######################################     1400.4k  -0.7%
```

Entries of the view by how long ago they were created (40 # = 5000):

```
<1s       upstream #######                                  849
          full     ########                                 982
          no-idle  ########                                 1002
          no-post-flush ########                                 995
1-10s     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
10s-1min  upstream #########                                1176
          full     #########                                1176
          no-idle  #########                                1176
          no-post-flush #########                                1176
1-5min    upstream #######################                  2824
          full     #######################                  2824
          no-idle  #######################                  2824
          no-post-flush #######################                  2824
>5min     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
```

#### c7i.24xlarge · hotcold_1500, 256 clients

*Throughput*

| build | TPS | speedup<br>over<br>upstream | CV | TPS<br>trend | top waits |
|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream | 786.8k | 1.0x | 1.4% | +0.1% | 80% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>10% CPU<br>10% Client:<br>&nbsp;&nbsp;ClientRead |
| full | 1.80M | 2.3x | 0.5% | −0.8% | 73% Client:<br>&nbsp;&nbsp;ClientRead<br>25% CPU<br>1% LWLock:<br>&nbsp;&nbsp;pg_stat_statements |
| no-idle | 1.79M | 2.3x | 0.3% | −0.2% | 74% Client:<br>&nbsp;&nbsp;ClientRead<br>25% CPU<br>1% LWLock:<br>&nbsp;&nbsp;pg_stat_statements |
| no-post-flush | 1.80M | 2.3x | 0.4% | −0.4% | 76% Client:<br>&nbsp;&nbsp;ClientRead<br>24% CPU |

*Eviction*

| build | allocated<br>avg/max | recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m | popular<br>kept | evictions<br>vs<br>upstream | back-<br>stop | text /<br>no-text |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream |  | 149/23/1464/3246/0 | 4000 |  |  | 2.4MB / 0 |
| full | 5495/5502 | 286/58/1528/3091/0 | 4000 | −14% | 0% | 3.0MB / 0 |
| no-idle | 5498/5502 | 286/50/1515/3115/0 | 4000 | −14% | 0% | 3.0MB / 0 |
| no-post-flush | 5502/5503 | 282/48/1516/3115/0 | 4000 | −13% | 0% | 3.0MB / 0 |

TPS over the run, by fifth (change from the first fifth):

```
upstream fifth 1   #################                            788.2k
         fifth 2   #################                            786.1k  -0.3%
         fifth 3   #################                            788.9k  +0.1%
         fifth 4   #################                            788.4k  +0.0%
         fifth 5   #################                            789.1k  +0.1%
full     fifth 1   ########################################    1807.1k
         fifth 2   ########################################    1804.6k  -0.1%
         fifth 3   ########################################    1801.4k  -0.3%
         fifth 4   ########################################    1795.4k  -0.6%
         fifth 5   ########################################    1792.9k  -0.8%
no-idle  fifth 1   ########################################    1788.1k
         fifth 2   #######################################     1783.6k  -0.3%
         fifth 3   ########################################    1785.1k  -0.2%
         fifth 4   ########################################    1785.7k  -0.1%
         fifth 5   #######################################     1784.3k  -0.2%
no-post-flush fifth 1 ########################################    1807.6k
         fifth 2   ########################################    1802.6k  -0.3%
         fifth 3   ########################################    1799.8k  -0.4%
         fifth 4   ########################################    1798.7k  -0.5%
         fifth 5   ########################################    1800.7k  -0.4%
```

Entries of the view by how long ago they were created (40 # = 5000):

```
<1s       upstream #                                        149
          full     ##                                       286
          no-idle  ##                                       286
          no-post-flush ##                                       282
1-10s     upstream                                          23
          full                                              58
          no-idle                                           50
          no-post-flush                                          48
10s-1min  upstream ############                             1464
          full     ############                             1528
          no-idle  ############                             1515
          no-post-flush ############                             1516
1-5min    upstream ##########################               3246
          full     #########################                3091
          no-idle  #########################                3115
          no-post-flush #########################                3115
>5min     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
```

#### c7i.24xlarge · hotcold_1500, 512 clients

*Throughput*

| build | TPS | speedup<br>over<br>upstream | CV | TPS<br>trend | top waits |
|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream | 744.4k | 1.0x | 2.2% | +0.3% | 87% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>7% Client:<br>&nbsp;&nbsp;ClientRead<br>5% CPU |
| full | 1.97M | 2.6x | 0.7% | −1.1% | 76% Client:<br>&nbsp;&nbsp;ClientRead<br>16% CPU<br>7% LWLock:<br>&nbsp;&nbsp;pg_stat_statements |
| no-idle | 1.95M | 2.6x | 0.7% | −0.1% | 78% Client:<br>&nbsp;&nbsp;ClientRead<br>17% CPU<br>5% LWLock:<br>&nbsp;&nbsp;pg_stat_statements |
| no-post-flush | 1.97M | 2.6x | 0.7% | −0.1% | 78% Client:<br>&nbsp;&nbsp;ClientRead<br>16% CPU<br>5% LWLock:<br>&nbsp;&nbsp;pg_stat_statements |

*Eviction*

| build | allocated<br>avg/max | recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m | popular<br>kept | evictions<br>vs<br>upstream | back-<br>stop | text /<br>no-text |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream |  | 156/49/1532/3133/0 | 4000 |  |  | 2.4MB / 0 |
| full | 5501/5503 | 366/133/1594/2919/0 | 4000 | −16% | 0% | 3.0MB / 0 |
| no-idle | 5501/5504 | 332/141/1591/2915/0 | 4000 | −15% | 0% | 3.0MB / 0 |
| no-post-flush | 5502/5503 | 318/138/1596/2914/0 | 4000 | −14% | 0% | 3.0MB / 0 |

TPS over the run, by fifth (change from the first fifth):

```
upstream fifth 1   ###############                              744.6k
         fifth 2   ###############                              750.0k  +0.7%
         fifth 3   ###############                              746.1k  +0.2%
         fifth 4   ###############                              743.2k  -0.2%
         fifth 5   ###############                              746.7k  +0.3%
full     fifth 1   ########################################    1983.4k
         fifth 2   ########################################    1981.1k  -0.1%
         fifth 3   ########################################    1968.3k  -0.8%
         fifth 4   ########################################    1961.6k  -1.1%
         fifth 5   ########################################    1961.7k  -1.1%
no-idle  fifth 1   #######################################     1950.6k
         fifth 2   #######################################     1945.1k  -0.3%
         fifth 3   #######################################     1948.5k  -0.1%
         fifth 4   #######################################     1950.6k  -0.0%
         fifth 5   #######################################     1948.4k  -0.1%
no-post-flush fifth 1 ########################################    1967.3k
         fifth 2   ########################################    1969.8k  +0.1%
         fifth 3   ########################################    1970.1k  +0.1%
         fifth 4   ########################################    1966.4k  -0.0%
         fifth 5   ########################################    1964.8k  -0.1%
```

Entries of the view by how long ago they were created (40 # = 5000):

```
<1s       upstream #                                        156
          full     ###                                      366
          no-idle  ###                                      332
          no-post-flush ###                                      318
1-10s     upstream                                          49
          full     #                                        133
          no-idle  #                                        141
          no-post-flush #                                        138
10s-1min  upstream ############                             1532
          full     #############                            1594
          no-idle  #############                            1591
          no-post-flush #############                            1596
1-5min    upstream #########################                3133
          full     #######################                  2919
          no-idle  #######################                  2915
          no-post-flush #######################                  2914
>5min     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
```

### c7i.48xlarge, 192 vCPUs

#### c7i.48xlarge · hotcold_100m, 256 clients

*Throughput*

| build | TPS | speedup<br>over<br>upstream | CV | TPS<br>trend | top waits |
|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream | 250.3k | 1.0x | 4.9% | +1.5% | 94% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>4% Client:<br>&nbsp;&nbsp;ClientRead<br>2% CPU |
| full | 1.28M | 5.1x | 3.0% | +2.0% | 86% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>8% CPU<br>6% Client:<br>&nbsp;&nbsp;ClientRead |
| no-idle | 1.29M | 5.2x | 4.4% | +4.1% | 86% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>8% CPU<br>6% Client:<br>&nbsp;&nbsp;ClientRead |
| no-post-flush | 1.29M | 5.2x | 2.9% | +2.0% | 86% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>7% CPU<br>6% Client:<br>&nbsp;&nbsp;ClientRead |

*Eviction*

| build | allocated<br>avg/max | recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m | popular<br>kept | evictions<br>vs<br>upstream | back-<br>stop | text /<br>no-text |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream |  | 842/0/1176/2824/0 | 4000 |  |  | 2.4MB / 0 |
| full | 5101/5258 | 1049/0/1176/2824/0 | 4000 | −43% | 0% | 3.0MB / 0 |
| no-idle | 5049/5200 | 1023/0/1176/2824/0 | 4000 | −43% | 0% | 3.0MB / 0 |
| no-post-flush | 5082/5241 | 1001/0/1176/2824/0 | 4000 | −43% | 0% | 1.0MB / 0 |

TPS over the run, by fifth (change from the first fifth):

```
upstream fifth 1   ########                                     247.1k
         fifth 2   ########                                     253.9k  +2.8%
         fifth 3   ########                                     252.7k  +2.3%
         fifth 4   ########                                     249.4k  +0.9%
         fifth 5   ########                                     250.7k  +1.5%
full     fifth 1   #######################################     1262.0k
         fifth 2   #######################################     1291.6k  +2.3%
         fifth 3   #######################################     1290.2k  +2.2%
         fifth 4   #######################################     1285.5k  +1.9%
         fifth 5   #######################################     1287.0k  +2.0%
no-idle  fifth 1   ######################################      1257.6k
         fifth 2   ########################################    1310.5k  +4.2%
         fifth 3   ########################################    1305.7k  +3.8%
         fifth 4   ########################################    1303.2k  +3.6%
         fifth 5   ########################################    1309.8k  +4.1%
no-post-flush fifth 1 #######################################     1271.0k
         fifth 2   ########################################    1304.5k  +2.6%
         fifth 3   ########################################    1302.3k  +2.5%
         fifth 4   ########################################    1299.3k  +2.2%
         fifth 5   ########################################    1296.5k  +2.0%
```

Entries of the view by how long ago they were created (40 # = 5000):

```
<1s       upstream #######                                  842
          full     ########                                 1049
          no-idle  ########                                 1023
          no-post-flush ########                                 1001
1-10s     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
10s-1min  upstream #########                                1176
          full     #########                                1176
          no-idle  #########                                1176
          no-post-flush #########                                1176
1-5min    upstream #######################                  2824
          full     #######################                  2824
          no-idle  #######################                  2824
          no-post-flush #######################                  2824
>5min     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
```

#### c7i.48xlarge · hotcold_100m, 512 clients

*Throughput*

| build | TPS | speedup<br>over<br>upstream | CV | TPS<br>trend | top waits |
|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream | 267.1k | 1.0x | 5.6% | +0.0% | 96% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>2% Client:<br>&nbsp;&nbsp;ClientRead<br>2% CPU |
| full | 1.25M | 4.7x | 5.7% | +7.5% | 92% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>4% CPU<br>4% Client:<br>&nbsp;&nbsp;ClientRead |
| no-idle | 1.26M | 4.7x | 5.6% | +6.2% | 92% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>4% CPU<br>4% Client:<br>&nbsp;&nbsp;ClientRead |
| no-post-flush | 1.26M | 4.7x | 4.7% | +5.5% | 92% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>4% CPU<br>4% Client:<br>&nbsp;&nbsp;ClientRead |

*Eviction*

| build | allocated<br>avg/max | recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m | popular<br>kept | evictions<br>vs<br>upstream | back-<br>stop | text /<br>no-text |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream |  | 867/0/1176/2824/0 | 4000 |  |  | 2.4MB / 0 |
| full | 5015/5232 | 1057/0/1176/2824/0 | 4000 | −45% | 0% | 1.0MB / 0 |
| no-idle | 5032/5227 | 1036/0/1176/2824/0 | 4000 | −44% | 0% | 1.0MB / 0 |
| no-post-flush | 5029/5219 | 996/0/1176/2824/0 | 4000 | −43% | 0% | 1.0MB / 0 |

TPS over the run, by fifth (change from the first fifth):

```
upstream fifth 1   ########                                     269.4k
         fifth 2   ########                                     261.0k  -3.1%
         fifth 3   ########                                     269.6k  +0.1%
         fifth 4   ########                                     268.8k  -0.2%
         fifth 5   ########                                     269.4k  +0.0%
full     fifth 1   #####################################       1187.3k
         fifth 2   ########################################    1271.1k  +7.1%
         fifth 3   ########################################    1276.3k  +7.5%
         fifth 4   ########################################    1273.8k  +7.3%
         fifth 5   ########################################    1276.0k  +7.5%
no-idle  fifth 1   ######################################      1204.8k
         fifth 2   ########################################    1272.5k  +5.6%
         fifth 3   ########################################    1279.9k  +6.2%
         fifth 4   ########################################    1283.8k  +6.6%
         fifth 5   ########################################    1280.0k  +6.2%
no-post-flush fifth 1 ######################################      1207.3k
         fifth 2   ########################################    1272.1k  +5.4%
         fifth 3   ########################################    1279.8k  +6.0%
         fifth 4   ########################################    1275.0k  +5.6%
         fifth 5   ########################################    1273.3k  +5.5%
```

Entries of the view by how long ago they were created (40 # = 5000):

```
<1s       upstream #######                                  867
          full     ########                                 1057
          no-idle  ########                                 1036
          no-post-flush ########                                 996
1-10s     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
10s-1min  upstream #########                                1176
          full     #########                                1176
          no-idle  #########                                1176
          no-post-flush #########                                1176
1-5min    upstream #######################                  2824
          full     #######################                  2824
          no-idle  #######################                  2824
          no-post-flush #######################                  2824
>5min     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
```

#### c7i.48xlarge · hotcold_1500, 256 clients

*Throughput*

| build | TPS | speedup<br>over<br>upstream | CV | TPS<br>trend | top waits |
|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream | 605.0k | 1.0x | 2.7% | −0.6% | 86% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>8% CPU<br>6% Client:<br>&nbsp;&nbsp;ClientRead |
| full | 2.15M | 3.6x | 2.2% | −2.8% | 55% Client:<br>&nbsp;&nbsp;ClientRead<br>44% CPU |
| no-idle | 2.24M | 3.7x | 1.1% | −1.1% | 56% Client:<br>&nbsp;&nbsp;ClientRead<br>44% CPU |
| no-post-flush | 2.58M | 4.3x | 0.7% | +0.4% | 58% Client:<br>&nbsp;&nbsp;ClientRead<br>41% CPU |

*Eviction*

| build | allocated<br>avg/max | recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m | popular<br>kept | evictions<br>vs<br>upstream | back-<br>stop | text /<br>no-text |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream |  | 128/19/1453/3261/0 | 4000 |  |  | 2.4MB / 0 |
| full | 5501/5502 | 340/61/1526/3071/0 | 4000 | −22% | 0% | 3.0MB / 0 |
| no-idle | 5500/5503 | 355/67/1533/3056/0 | 4000 | −24% | 0% | 3.0MB / 0 |
| no-post-flush | 5502/5503 | 367/71/1544/3033/0 | 4000 | −25% | 0% | 3.0MB / 0 |

TPS over the run, by fifth (change from the first fifth):

```
upstream fifth 1   #########                                    609.3k
         fifth 2   #########                                    608.8k  -0.1%
         fifth 3   #########                                    606.5k  -0.5%
         fifth 4   #########                                    601.0k  -1.4%
         fifth 5   #########                                    605.6k  -0.6%
full     fifth 1   ##################################          2185.8k
         fifth 2   #################################           2147.6k  -1.7%
         fifth 3   #################################           2139.7k  -2.1%
         fifth 4   #################################           2138.7k  -2.2%
         fifth 5   #################################           2125.5k  -2.8%
no-idle  fifth 1   ###################################         2259.0k
         fifth 2   ###################################         2245.9k  -0.6%
         fifth 3   ###################################         2234.4k  -1.1%
         fifth 4   ###################################         2239.0k  -0.9%
         fifth 5   ###################################         2233.1k  -1.1%
no-post-flush fifth 1 ########################################    2576.3k
         fifth 2   ########################################    2581.6k  +0.2%
         fifth 3   ########################################    2581.9k  +0.2%
         fifth 4   ########################################    2585.7k  +0.4%
         fifth 5   ########################################    2586.1k  +0.4%
```

Entries of the view by how long ago they were created (40 # = 5000):

```
<1s       upstream #                                        128
          full     ###                                      340
          no-idle  ###                                      355
          no-post-flush ###                                      367
1-10s     upstream                                          19
          full                                              61
          no-idle  #                                        67
          no-post-flush #                                        71
10s-1min  upstream ############                             1453
          full     ############                             1526
          no-idle  ############                             1533
          no-post-flush ############                             1544
1-5min    upstream ##########################               3261
          full     #########################                3071
          no-idle  ########################                 3056
          no-post-flush ########################                 3033
>5min     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
```

#### c7i.48xlarge · hotcold_1500, 512 clients

*Throughput*

| build | TPS | speedup<br>over<br>upstream | CV | TPS<br>trend | top waits |
|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream | 613.5k | 1.0x | 3.3% | +3.3% | 93% LWLock:<br>&nbsp;&nbsp;pg_stat_statements<br>3% CPU<br>3% Client:<br>&nbsp;&nbsp;ClientRead |
| full | 2.29M | 3.7x | 2.5% | −2.8% | 73% Client:<br>&nbsp;&nbsp;ClientRead<br>26% CPU<br>2% LWLock:<br>&nbsp;&nbsp;pg_stat_statements |
| no-idle | 2.11M | 3.4x | 3.0% | −4.8% | 72% Client:<br>&nbsp;&nbsp;ClientRead<br>26% CPU<br>1% LWLock:<br>&nbsp;&nbsp;pg_stat_statements |
| no-post-flush | 2.17M | 3.5x | 2.6% | −1.8% | 73% Client:<br>&nbsp;&nbsp;ClientRead<br>26% CPU |

*Eviction*

| build | allocated<br>avg/max | recency<br>&lt;1s/1-10s/10s-1m/<br>1-5m/&gt;5m | popular<br>kept | evictions<br>vs<br>upstream | back-<br>stop | text /<br>no-text |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| upstream |  | 154/32/1480/3210/0 | 4000 |  |  | 2.2MB / 0 |
| full | 5501/5502 | 382/79/1531/3036/0 | 4000 | −23% | 0% | 3.0MB / 0 |
| no-idle | 5501/5502 | 365/78/1541/3032/0 | 4000 | −21% | 0% | 3.0MB / 0 |
| no-post-flush | 5503/5504 | 365/82/1538/3032/0 | 4000 | −20% | 0% | 3.0MB / 0 |

TPS over the run, by fifth (change from the first fifth):

```
upstream fifth 1   ##########                                   600.9k
         fifth 2   ##########                                   613.0k  +2.0%
         fifth 3   ###########                                  621.3k  +3.4%
         fifth 4   ###########                                  619.2k  +3.0%
         fifth 5   ###########                                  620.5k  +3.3%
full     fifth 1   ########################################    2335.9k
         fifth 2   #######################################     2302.7k  -1.4%
         fifth 3   #######################################     2302.1k  -1.4%
         fifth 4   ######################################      2241.7k  -4.0%
         fifth 5   #######################################     2270.6k  -2.8%
no-idle  fifth 1   #####################################       2173.0k
         fifth 2   ####################################        2116.8k  -2.6%
         fifth 3   ####################################        2121.2k  -2.4%
         fifth 4   ####################################        2096.4k  -3.5%
         fifth 5   ###################################         2069.5k  -4.8%
no-post-flush fifth 1 ######################################      2195.9k
         fifth 2   #####################################       2177.3k  -0.8%
         fifth 3   #####################################       2169.2k  -1.2%
         fifth 4   #####################################       2165.1k  -1.4%
         fifth 5   #####################################       2156.3k  -1.8%
```

Entries of the view by how long ago they were created (40 # = 5000):

```
<1s       upstream #                                        154
          full     ###                                      382
          no-idle  ###                                      365
          no-post-flush ###                                      365
1-10s     upstream                                          32
          full     #                                        79
          no-idle  #                                        78
          no-post-flush #                                        82
10s-1min  upstream ############                             1480
          full     ############                             1531
          no-idle  ############                             1541
          no-post-flush ############                             1538
1-5min    upstream ##########################               3210
          full     ########################                 3036
          no-idle  ########################                 3032
          no-post-flush ########################                 3032
>5min     upstream                                          0
          full                                              0
          no-idle                                           0
          no-post-flush                                          0
```

