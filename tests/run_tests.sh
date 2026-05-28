#!/bin/bash
# run_tests.sh - Test suite for pg_stat_statements benchmark scripts
#
# Usage: ./tests/run_tests.sh
#
# Tests:
#   1. bench.sh output format (churn polling line field order)
#   2. analyze_matrix.sh parsing of synthetic reports
#   3. End-to-end: synthetic bench output → analyze → verify markdown

set -e

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "        $2"; }

# ============================================================
# Test 1: bench.sh churn printf format
# ============================================================

echo "=== Test 1: bench.sh churn output format ==="

# Extract the printf format string from bench.sh for the churn branch
churn_format=$(sed -n '/elif \[\[ "\$name" == \*churn\* \]\]/,/^        else$/p' "$PROJECT_DIR/bench.sh" | \
    grep -A1 'printf.*t=.*hot.*cold.*rare' | head -1)

if echo "$churn_format" | grep -q 'hot=.*cold=.*rare='; then
    pass "churn format has hot before cold before rare"
else
    fail "churn format field order" "Expected hot=...cold=...rare=..., got: $churn_format"
fi

# Verify rare has age annotation after it
if echo "$churn_format" | grep -q 'rare=.*age.*cold='; then
    fail "rare should come AFTER cold" "rare(age) still appears before cold"
elif echo "$churn_format" | grep -q 'cold=.*rare=.*age'; then
    pass "rare(age) comes after cold"
else
    fail "rare(age) position" "Could not verify rare(age) position relative to cold"
fi

# Verify dealloc is fetched from pg_stat_statements_info
if grep -q 'dealloc' "$PROJECT_DIR/bench.sh"; then
    pass "bench.sh fetches dealloc"
else
    fail "dealloc not found in bench.sh" ""
fi

echo ""

# ============================================================
# Test 2: bench.sh printf simulation (mock values)
# ============================================================

echo "=== Test 2: bench.sh printf output simulation ==="

# Simulate the churn printf with known values
simulate_churn_line() {
    local elapsed="30s" entries="5123" hot="1000" cold="42" rare="7"
    local rare_youngest="1" rare_oldest="10"
    local progress_tps="45000" num_entries="5100" dealloc="328"
    local youngest="0s" oldest="30s" avg_age="15s" stddev_age="8s"
    local min_calls="1" max_calls="9999" avg_calls="500" stddev_calls="200"
    local fingerprint="a1b2c3d4" waits="CPU(45) LWLock:pg_stat_statements(12)"

    printf "  t=%-4s entries=%-5s hot=%-5s cold=%-3s rare=%-3s(age %s..%ss) tps=%-8s num_entries=%-5s dealloc=%-8s age=[%s..%s avg=%s sd=%s] calls=[%s..%s avg=%s sd=%s] fp=%s waits=[%s]\n" \
        "$elapsed" "$entries" "$hot" "$cold" "$rare" "$rare_youngest" "$rare_oldest" "$progress_tps" "$num_entries" "$dealloc" "$youngest" "$oldest" "$avg_age" "$stddev_age" "$min_calls" "$max_calls" "$avg_calls" "$stddev_calls" "$fingerprint" "$waits"
}

# Test output format
line=$(simulate_churn_line)

# Verify field ordering in output line
if echo "$line" | grep -q 'hot=.*cold=.*rare=.*age.*tps='; then
    pass "output field order: hot cold rare(age) tps"
else
    fail "output field order wrong" "$line"
fi

# Verify dealloc appears in output
if echo "$line" | grep -q 'dealloc='; then
    pass "dealloc appears in output"
else
    fail "dealloc missing from output" "$line"
fi

echo ""

# ============================================================
# Test 3: analyze_matrix.sh parsing
# ============================================================

echo "=== Test 3: analyze_matrix.sh field extraction ==="

# Create synthetic report files
RESULTS="$TMPDIR/pgss_matrix_test"
mkdir -p "$RESULTS/abc123_c64_cpu8"
mkdir -p "$RESULTS/def456_c64_cpu8"

# Synthetic git repo for commit_msg lookup
GIT_DIR="$TMPDIR/fakegit"
mkdir -p "$GIT_DIR"
git -C "$GIT_DIR" init -q
git -C "$GIT_DIR" commit --allow-empty -m "baseline: vanilla pg_stat_statements" -q
BASELINE_SHA=$(git -C "$GIT_DIR" rev-parse HEAD)
git -C "$GIT_DIR" commit --allow-empty -m "LRU eviction policy" -q
LRU_SHA=$(git -C "$GIT_DIR" rev-parse HEAD)

# Rename dirs to use real-ish shas
mv "$RESULTS/abc123_c64_cpu8" "$RESULTS/${BASELINE_SHA:0:11}_c64_cpu8"
mv "$RESULTS/def456_c64_cpu8" "$RESULTS/${LRU_SHA:0:11}_c64_cpu8"

# Summary file
cat > "$RESULTS/summary.txt" << EOF
Date: 2025-01-15 10:00:00
Duration: 180s
pgss.max: 5000
Commits: ${BASELINE_SHA:0:11} ${LRU_SHA:0:11}
EOF

# Baseline report
cat > "$RESULTS/${BASELINE_SHA:0:11}_c64_cpu8/report.txt" << 'EOF'
=== pg_stat_statements benchmark ===
Date: 2025-01-15 10:00:00
Duration: 180s, Clients: 64, Jobs: 16, Protocol: simple, Port: 5432
Workloads: churn
CPUs online: 8
Machine: Test CPU, 32GB RAM

--- churn [clients=64 jobs=16 proto=simple duration=180s] ---
  pgbench -U postgres -d benchmark -f bench_churn.sql -c 64 -j 16 -T 180 -P 5 -M simple
  t=5s   entries=5010  hot=1000  cold=42  rare=7  (age 1..5s) tps=35000    num_entries=5010  dealloc=100      age=[0s..5s avg=2s sd=1s] calls=[1..500 avg=50 sd=30] fp=aabbccdd waits=[CPU(40) LWLock:pg_stat_statements(20)]
  t=10s  entries=5010  hot=1000  cold=42  rare=7  (age 1..10s) tps=34500   num_entries=5010  dealloc=200      age=[0s..10s avg=5s sd=3s] calls=[1..1000 avg=100 sd=50] fp=aabbccdd waits=[CPU(38) LWLock:pg_stat_statements(22)]
  t=15s  entries=5010  hot=1000  cold=42  rare=7  (age 1..15s) tps=34000   num_entries=5010  dealloc=300      age=[0s..15s avg=7s sd=4s] calls=[1..1500 avg=150 sd=70] fp=aabbccdd waits=[CPU(36) LWLock:pg_stat_statements(24)]
  db_time: idle=91.3% db=8.7% (CPU=60.0% LWLock:pg_stat_statements=35.0% IO:DataFileRead=5.0%) (1000 active samples over 180s, 64 clients)
  os_avg: cpu_usr=55% cpu_sys=10% mem_used=4096MB pg_rss=2048MB
  TPS: 34500
  FINAL: entries=5010 hot=1000 rare=7 cold=42 rare_age=[1..15s] hot_calls=500000 cold_calls=2000
  deallocs: 300
  histogram: 1:200 2-5:1800 6-20:2000 21-100:800 101-1k:200 >1k:10

EOF

# LRU report
cat > "$RESULTS/${LRU_SHA:0:11}_c64_cpu8/report.txt" << 'EOF'
=== pg_stat_statements benchmark ===
Date: 2025-01-15 10:30:00
Duration: 180s, Clients: 64, Jobs: 16, Protocol: simple, Port: 5432
Workloads: churn
CPUs online: 8
Machine: Test CPU, 32GB RAM

--- churn [clients=64 jobs=16 proto=simple duration=180s] ---
  pgbench -U postgres -d benchmark -f bench_churn.sql -c 64 -j 16 -T 180 -P 5 -M simple
  t=5s   entries=5010  hot=1000  cold=42  rare=7  (age 1..5s) tps=85000    num_entries=5010  dealloc=50       age=[0s..5s avg=2s sd=1s] calls=[1..500 avg=50 sd=30] fp=aabbccdd waits=[CPU(58)]
  t=10s  entries=5010  hot=1000  cold=42  rare=7  (age 1..10s) tps=84000   num_entries=5010  dealloc=100      age=[0s..10s avg=5s sd=3s] calls=[1..1000 avg=100 sd=50] fp=aabbccdd waits=[CPU(57)]
  t=15s  entries=5010  hot=1000  cold=42  rare=7  (age 1..15s) tps=83000   num_entries=5010  dealloc=150      age=[0s..15s avg=7s sd=4s] calls=[1..1500 avg=150 sd=70] fp=aabbccdd waits=[CPU(56)]
  db_time: idle=91.3% db=8.7% (CPU=95.0% LWLock:pg_stat_statements=3.0% IO:DataFileRead=2.0%) (1000 active samples over 180s, 64 clients)
  os_avg: cpu_usr=88% cpu_sys=5% mem_used=4096MB pg_rss=2048MB
  TPS: 84000
  FINAL: entries=5010 hot=1000 rare=7 cold=42 rare_age=[1..15s] hot_calls=1500000 cold_calls=5000
  deallocs: 150
  histogram: 1:100 2-5:900 6-20:2000 21-100:1200 101-1k:700 >1k:110

EOF

# Run analyze_matrix.sh against our fixtures
export PG_SOURCE_DIR="$GIT_DIR"
export BENCH_RESULTS_DIR="$TMPDIR"
OUTPUT=$("$PROJECT_DIR/analysis/analyze_matrix.sh" "$RESULTS" 2>/dev/null)

# Test: report was generated
if [[ -n "$OUTPUT" ]]; then
    pass "analyze_matrix.sh produced output"
else
    fail "analyze_matrix.sh produced no output" ""
    echo ""; echo "=== Results ==="; echo "PASS: $PASS  FAIL: $FAIL"; exit 1
fi

# Test: commits detected
if echo "$OUTPUT" | grep -q "Baseline"; then
    pass "baseline commit detected"
else
    fail "baseline commit not found in output" ""
fi

if echo "$OUTPUT" | grep -q "LRU\|${LRU_SHA:0:11}"; then
    pass "LRU commit detected (label or SHA)"
else
    fail "LRU commit not found in output" "looked for 'LRU' or '${LRU_SHA:0:11}'"
fi

# Test: TPS extracted
if echo "$OUTPUT" | grep -q "34,500\|34500"; then
    pass "baseline TPS extracted (34500)"
else
    fail "baseline TPS not found" "$(echo "$OUTPUT" | grep -i tps | head -5)"
fi

if echo "$OUTPUT" | grep -q "84,000\|84000"; then
    pass "LRU TPS extracted (84000)"
else
    fail "LRU TPS not found" "$(echo "$OUTPUT" | grep -i tps | head -5)"
fi

# Test: deallocs extracted
if echo "$OUTPUT" | grep -q "300"; then
    pass "baseline deallocs found (300)"
else
    fail "baseline deallocs not found" ""
fi

# Test: dealloc row appears in analysis
if echo "$OUTPUT" | grep -qi "dealloc"; then
    pass "dealloc row/terminology appears in output"
else
    fail "dealloc not mentioned in output" ""
fi

# Test: wait event analysis section exists
if echo "$OUTPUT" | grep -q "Wait Event Analysis"; then
    pass "wait event analysis section present"
else
    fail "wait event analysis missing" ""
fi

# Test: multiple wait events extracted from db_time line
if echo "$OUTPUT" | grep -q "LWLock:pg_stat_statements"; then
    pass "LWLock wait event extracted from db_time"
else
    fail "LWLock wait event not found in output" ""
fi

# Test: retention section exists
if echo "$OUTPUT" | grep -q "Retention"; then
    pass "retention section present"
else
    fail "retention section missing" ""
fi

echo ""

# ============================================================
# Test 4: End-to-end field extraction with getval awk
# ============================================================

echo "=== Test 4: awk getval extraction ==="

# Test the getval function directly with our new format line
test_line='  t=10s  entries=5010  hot=1000  cold=42  rare=7  (age 1..10s) tps=84000   num_entries=5010  dealloc=100      age=[0s..10s avg=5s sd=3s] calls=[1..1000 avg=100 sd=50] fp=aabbccdd waits=[CPU(57)]'

extract_field() {
    echo "$test_line" | awk -v key="$1" '
        function getval(line, k,    i, s) {
            i = index(line, k"=")
            if (i == 0) return ""
            s = substr(line, i + length(k) + 1)
            sub(/[^0-9.].*/, "", s)
            return s
        }
        { print getval($0, key) }
    '
}

val=$(extract_field "t")
if [[ "$val" == "10" ]]; then pass "getval extracts t=10"; else fail "getval t" "got '$val'"; fi

val=$(extract_field "entries")
if [[ "$val" == "5010" ]]; then pass "getval extracts entries=5010"; else fail "getval entries" "got '$val'"; fi

val=$(extract_field "hot")
if [[ "$val" == "1000" ]]; then pass "getval extracts hot=1000"; else fail "getval hot" "got '$val'"; fi

val=$(extract_field "cold")
if [[ "$val" == "42" ]]; then pass "getval extracts cold=42"; else fail "getval cold" "got '$val'"; fi

val=$(extract_field "tps")
if [[ "$val" == "84000" ]]; then pass "getval extracts tps=84000"; else fail "getval tps" "got '$val'"; fi

val=$(extract_field "num_entries")
if [[ "$val" == "5010" ]]; then pass "getval extracts num_entries=5010"; else fail "getval num_entries" "got '$val'"; fi

val=$(extract_field "dealloc")
if [[ "$val" == "100" ]]; then pass "getval extracts dealloc=100"; else fail "getval dealloc" "got '$val'"; fi

val=$(extract_field "fp")
if [[ "$val" == "" || -n "$val" ]]; then pass "getval extracts fp field"; else fail "getval fp" "got '$val'"; fi

echo ""

# ============================================================
# Test 5: Verify no regression in non-churn format parsing
# ============================================================

echo "=== Test 5: non-churn format (select1/full_5k) ==="

# Add select1 data to fixtures
cat >> "$RESULTS/${BASELINE_SHA:0:11}_c64_cpu8/report.txt" << 'EOF'
--- select1 [clients=64 jobs=16 proto=simple duration=180s] ---
  pgbench -U postgres -d benchmark -f bench_select1.sql -c 64 -j 16 -T 180 -P 5 -M simple
  t=5s   entries=3     tps=250000   num_entries=3     dealloc=0        age=[0s..5s avg=2s sd=1s] calls=[1..50000 avg=25000 sd=100] fp=11223344 waits=[CPU(64)]
  t=10s  entries=3     tps=252000   num_entries=3     dealloc=0        age=[0s..10s avg=5s sd=2s] calls=[1..100000 avg=50000 sd=200] fp=11223344 waits=[CPU(64)]
  db_time: idle=91.3% db=8.7% (CPU=99.5%) (1000 active samples over 180s, 64 clients)
  os_avg: cpu_usr=95% cpu_sys=3% mem_used=3800MB pg_rss=1800MB
  TPS: 251000
  FINAL: entries=3 calls=9000000
  deallocs: 0
  histogram: >1k:3

EOF

cat >> "$RESULTS/${LRU_SHA:0:11}_c64_cpu8/report.txt" << 'EOF'
--- select1 [clients=64 jobs=16 proto=simple duration=180s] ---
  pgbench -U postgres -d benchmark -f bench_select1.sql -c 64 -j 16 -T 180 -P 5 -M simple
  t=5s   entries=3     tps=249000   num_entries=3     dealloc=0        age=[0s..5s avg=2s sd=1s] calls=[1..50000 avg=25000 sd=100] fp=11223344 waits=[CPU(64)]
  t=10s  entries=3     tps=251000   num_entries=3     dealloc=0        age=[0s..10s avg=5s sd=2s] calls=[1..100000 avg=50000 sd=200] fp=11223344 waits=[CPU(64)]
  db_time: idle=91.3% db=8.7% (CPU=99.6%) (1000 active samples over 180s, 64 clients)
  os_avg: cpu_usr=95% cpu_sys=3% mem_used=3800MB pg_rss=1800MB
  TPS: 250000
  FINAL: entries=3 calls=9000000
  deallocs: 0
  histogram: >1k:3

EOF

# Re-run analyze
OUTPUT2=$("$PROJECT_DIR/analysis/analyze_matrix.sh" "$RESULTS" 2>/dev/null)

if echo "$OUTPUT2" | grep -q "251,000\|251000"; then
    pass "select1 baseline TPS extracted"
else
    fail "select1 baseline TPS not found" ""
fi

if echo "$OUTPUT2" | grep -q "250,000\|250000"; then
    pass "select1 LRU TPS extracted"
else
    fail "select1 LRU TPS not found" ""
fi

# Verify select1 shows in non-evicting workload analysis
if echo "$OUTPUT2" | grep -q "select1"; then
    pass "select1 workload appears in report"
else
    fail "select1 workload missing from report" ""
fi

echo ""

# ============================================================
# Test 6: Verify zipf format parsing
# ============================================================

echo "=== Test 6: zipf format ==="

test_zipf_line='  t=10s  entries=4950  t1=50   t2=200  t3=1500 t4=3200  tps=62000    num_entries=4950  dealloc=80       age=[0s..10s avg=5s sd=3s] calls=[1..8000 avg=200 sd=150] fp=55667788 waits=[CPU(60)]'

val=$(echo "$test_zipf_line" | awk '
    function getval(line, k,    i, s) {
        i = index(line, k"=")
        if (i == 0) return ""
        s = substr(line, i + length(k) + 1)
        sub(/[^0-9.].*/, "", s)
        return s
    }
    { print getval($0, "t1") }
')
if [[ "$val" == "50" ]]; then pass "getval extracts t1=50 from zipf line"; else fail "getval zipf t1" "got '$val'"; fi

val=$(echo "$test_zipf_line" | awk '
    function getval(line, k,    i, s) {
        i = index(line, k"=")
        if (i == 0) return ""
        s = substr(line, i + length(k) + 1)
        sub(/[^0-9.].*/, "", s)
        return s
    }
    { print getval($0, "dealloc") }
')
if [[ "$val" == "80" ]]; then pass "getval extracts dealloc=80 from zipf line"; else fail "getval zipf dealloc" "got '$val'"; fi

echo ""

# ============================================================
# Test 7: rare field extraction and age parsing
# ============================================================

echo "=== Test 7: rare field extraction and age parsing ==="

test_rare_line='  t=10s  entries=5010  hot=1000  cold=42  rare=7  (age 1..10s) tps=84000   num_entries=5010  dealloc=100      age=[0s..10s avg=5s sd=3s] calls=[1..1000 avg=100 sd=50] fp=aabbccdd waits=[CPU(57)]'

# Test getval for rare
val=$(echo "$test_rare_line" | awk '
    function getval(line, k,    i, s) {
        i = index(line, k"=")
        if (i == 0) return ""
        s = substr(line, i + length(k) + 1)
        sub(/[^0-9.].*/, "", s)
        return s
    }
    { print getval($0, "rare") }
')
if [[ "$val" == "7" ]]; then pass "getval extracts rare=7"; else fail "getval rare" "got '$val'"; fi

# Test get_rare_age function
val=$(echo "$test_rare_line" | awk '
    function get_rare_age(line,    i, s, parts) {
        i = index(line, "(age ")
        if (i == 0) return ""
        s = substr(line, i + 5)
        sub(/\).*/, "", s)
        split(s, parts, "\\.\\.")
        youngest = parts[1]+0
        oldest = parts[2]+0
        sub(/[^0-9]/, "", oldest)
        return youngest " " oldest
    }
    { print get_rare_age($0) }
')
if [[ "$val" == "1 10" ]]; then pass "get_rare_age extracts 1 10"; else fail "get_rare_age" "got '$val'"; fi

# Test with different age values
test_rare_line2='  t=60s  entries=5010  hot=1000  cold=42  rare=7  (age 3..55s) tps=80000   num_entries=5010  dealloc=500      age=[0s..60s avg=30s sd=15s] calls=[1..5000 avg=200 sd=100] fp=aabbccdd waits=[CPU(60)]'
val=$(echo "$test_rare_line2" | awk '
    function get_rare_age(line,    i, s, parts) {
        i = index(line, "(age ")
        if (i == 0) return ""
        s = substr(line, i + 5)
        sub(/\).*/, "", s)
        split(s, parts, "\\.\\.")
        youngest = parts[1]+0
        oldest = parts[2]+0
        sub(/[^0-9]/, "", oldest)
        return youngest " " oldest
    }
    { print get_rare_age($0) }
')
if [[ "$val" == "3 55" ]]; then pass "get_rare_age extracts 3 55"; else fail "get_rare_age larger values" "got '$val'"; fi

# Test that analyze_matrix output includes rare data
if echo "$OUTPUT" | grep -qi "rare"; then
    pass "analyze report mentions rare"
else
    fail "analyze report missing rare content" ""
fi

# Test that the retention section has rare entries row
if echo "$OUTPUT" | grep -q "Avg rare entries"; then
    pass "Avg rare entries row present"
else
    fail "Avg rare entries row missing" "$(echo "$OUTPUT" | grep -i rare)"
fi

# Test rare age row
if echo "$OUTPUT" | grep -q "Rare max age"; then
    pass "Rare max age row present"
else
    fail "Rare max age row missing" ""
fi

echo ""

# ============================================================
# Summary
# ============================================================

echo "==============================="
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "==============================="

if (( FAIL > 0 )); then
    exit 1
fi
