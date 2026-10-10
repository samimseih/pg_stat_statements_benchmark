#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_WORKTREE="${PG_WORKTREE:-$HOME/pgdev/installations/worktrees/dev}"
PREFIX="${PREFIX:-$HOME/pgdev/installations}"
WORKTREE_NAME="${WORKTREE_NAME:-dev}"
BUILD_WRAPPER="${BUILD_WRAPPER:-$HOME/build}"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"

COMMITS=(${COMMITS:-fbef23389f1 3051c223a60})
CLIENTS=(${CLIENTS:-1 2 4 8 16 32 64 128 256})
MAX_THREADS="${MAX_THREADS:-32}"
PROGRESS_SECONDS="${PROGRESS_SECONDS:-10}"

HOTCOLD_SECONDS="${HOTCOLD_SECONDS:-60}"
SELECT_SECONDS="${SELECT_SECONDS:-120}"
SELECT_SCALE="${SELECT_SCALE:-10}"
SELECT_WARMUP_SECONDS="${SELECT_WARMUP_SECONDS:-30}"

PGSS_MAX="${PGSS_MAX:-5000}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-300}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_ROOT="${RESULT_ROOT:-$SCRIPT_DIR/results/$RUN_ID}"

PGHOME="$PREFIX/pghome/$WORKTREE_NAME"
PGDATA="$PREFIX/pgdata/$WORKTREE_NAME"

PSQL=("$PGHOME/bin/psql" -X -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
PSQL_AT=("$PGHOME/bin/psql" -XAt -F $'\t' -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
PGBENCH="$PGHOME/bin/pgbench"

summary="$RESULT_ROOT/summary.tsv"
original_ref=""

die() {
  echo "error: $*" >&2
  exit 1
}

threads_for_clients() {
  local clients="$1"
  if (( clients < MAX_THREADS )); then
    echo "$clients"
  else
    echo "$MAX_THREADS"
  fi
}

checkout_original_on_exit() {
  if [[ -n "$original_ref" && "${RESTORE_GIT:-1}" == "1" ]]; then
    git -C "$PG_WORKTREE" checkout -q "$original_ref" || true
  fi
}

check_worktree_clean() {
  git -C "$PG_WORKTREE" diff --quiet || die "$PG_WORKTREE has unstaged changes"
  git -C "$PG_WORKTREE" diff --cached --quiet || die "$PG_WORKTREE has staged changes"
}

sql() {
  "${PSQL[@]}" "$@"
}

sql_at() {
  "${PSQL_AT[@]}" "$@"
}

reset_pgss() {
  sql -q -c "select pg_stat_statements_reset();" >/dev/null
}

configure_cluster() {
  sql <<SQL
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
ALTER SYSTEM SET pg_stat_statements.max = '$PGSS_MAX';
ALTER SYSTEM SET max_connections = '$MAX_CONNECTIONS';
SQL

  "$PGHOME/bin/pg_ctl" -D "$PGDATA" -m fast -w -l "$PGDATA/logfile" restart
  sql -q -c "create extension if not exists pg_stat_statements;" >/dev/null
  reset_pgss
}

build_and_start_commit() {
  local commit="$1"

  echo
  echo "==> Building $commit"
  git -C "$PG_WORKTREE" checkout -q "$commit"
  ninja -C "$PG_WORKTREE/build" clean
  ninja -C "$PG_WORKTREE/build" install
  "$BUILD_WRAPPER" --skip-build --worktree-name "$WORKTREE_NAME" --release
  configure_cluster
}

start_samplers() {
  local outdir="$1"
  sampler_pids=()

  if command -v vmstat >/dev/null 2>&1; then
    vmstat 1 >"$outdir/vmstat.log" 2>&1 &
    sampler_pids+=("$!")
  fi

  if command -v pidstat >/dev/null 2>&1; then
    pidstat -durh -p ALL 1 >"$outdir/pidstat.log" 2>&1 &
    sampler_pids+=("$!")
  fi

  if command -v iostat >/dev/null 2>&1; then
    iostat -xz 1 >"$outdir/iostat.log" 2>&1 &
    sampler_pids+=("$!")
  fi

  (
    while true; do
      sql_at -c "
        select extract(epoch from clock_timestamp())::numeric(20,3),
               coalesce(wait_event_type, ''),
               coalesce(wait_event, ''),
               count(*)
        from pg_stat_activity
        where datname = current_database()
          and state = 'active'
          and pid <> pg_backend_pid()
        group by 1, 2, 3
        order by 4 desc, 2, 3;"
      sleep 1
    done
  ) >"$outdir/waits.tsv" 2>"$outdir/waits.err" &
  sampler_pids+=("$!")

  (
    while true; do
      sql_at -c "
        select extract(epoch from clock_timestamp())::numeric(20,3),
               count(*),
               coalesce(sum(calls), 0),
               count(*) filter (where query is null),
               coalesce(max(calls), 0)
        from pg_stat_statements;"
      sleep 10
    done
  ) >"$outdir/monitor_pgss.tsv" 2>"$outdir/monitor_pgss.err" &
  sampler_pids+=("$!")
}

stop_samplers() {
  if ((${#sampler_pids[@]})); then
    kill "${sampler_pids[@]}" 2>/dev/null || true
    wait "${sampler_pids[@]}" 2>/dev/null || true
  fi
}

extract_pgbench_field() {
  local file="$1"
  local field="$2"

  case "$field" in
    tps)
      awk '/^tps =/ {v=$3} END {print v}' "$file"
      ;;
    latency)
      awk '/^latency average =/ {v=$4} END {print v}' "$file"
      ;;
    failed)
      awk -F: '/number of failed transactions/ {
        gsub(/^[ \t]+/, "", $2);
        split($2, a, " ");
        v=a[1]
      } END {print v+0}' "$file"
      ;;
  esac
}

append_summary() {
  local commit="$1" workload="$2" clients="$3" threads="$4" duration="$5" status="$6" outdir="$7"
  local tps latency failed

  tps="$(extract_pgbench_field "$outdir/pgbench.log" tps)"
  latency="$(extract_pgbench_field "$outdir/pgbench.log" latency)"
  failed="$(extract_pgbench_field "$outdir/pgbench.log" failed)"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$commit" "$workload" "$clients" "$threads" "$duration" "$status" \
    "${tps:-}" "${latency:-}" "${failed:-}" "$outdir" >>"$summary"
}

run_pgbench_capture() {
  local commit="$1" workload="$2" clients="$3" duration="$4"
  shift 4
  local threads outdir status

  threads="$(threads_for_clients "$clients")"
  outdir="$RESULT_ROOT/$commit/$workload/c$clients"
  mkdir -p "$outdir"

  {
    echo "commit=$commit"
    echo "workload=$workload"
    echo "clients=$clients"
    echo "threads=$threads"
    echo "duration=$duration"
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$outdir/meta.txt"

  reset_pgss
  start_samplers "$outdir"
  set +e
  "$@" -c "$clients" -j "$threads" -T "$duration" "$PGDATABASE" >"$outdir/pgbench.log" 2>&1
  status="$?"
  set -e
  stop_samplers

  sql -f "$SCRIPT_DIR/benchmark_analyze.sql" >"$outdir/analyze.out" 2>"$outdir/analyze.err" || true
  tail -n 200 "$PGDATA/logfile" >"$outdir/server_log_tail.log" 2>/dev/null || true
  append_summary "$commit" "$workload" "$clients" "$threads" "$duration" "$status" "$outdir"

  if [[ "$status" != "0" ]]; then
    echo "pgbench failed for $commit $workload c$clients; see $outdir/pgbench.log" >&2
  fi
}

run_hotcold_ladder() {
  local commit="$1" workload="$2" script="$3"
  local clients

  for clients in "${CLIENTS[@]}"; do
    echo "==> $commit $workload clients=$clients"
    run_pgbench_capture "$commit" "$workload" "$clients" "$HOTCOLD_SECONDS" \
      "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -n -M simple \
      -P "$PROGRESS_SECONDS" -f "$script"
  done
}

run_select_only_ladder() {
  local commit="$1"
  local clients

  echo "==> $commit select_only init scale=$SELECT_SCALE"
  "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -i -s "$SELECT_SCALE" "$PGDATABASE" \
    >"$RESULT_ROOT/$commit/select_init.log" 2>&1

  echo "==> $commit select_only warmup ${SELECT_WARMUP_SECONDS}s"
  "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -n -M prepared \
    -c 32 -j 32 -T "$SELECT_WARMUP_SECONDS" -S "$PGDATABASE" \
    >"$RESULT_ROOT/$commit/select_warmup.log" 2>&1

  for clients in "${CLIENTS[@]}"; do
    echo "==> $commit select_only clients=$clients"
    run_pgbench_capture "$commit" select_only "$clients" "$SELECT_SECONDS" \
      "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -n -M prepared \
      -P "$PROGRESS_SECONDS" -S
  done
}

main() {
  check_worktree_clean
  original_ref="$(git -C "$PG_WORKTREE" symbolic-ref --short -q HEAD || git -C "$PG_WORKTREE" rev-parse HEAD)"
  trap checkout_original_on_exit EXIT

  mkdir -p "$RESULT_ROOT"
  printf "commit\tworkload\tclients\tthreads\tduration_s\tstatus\ttps\tlatency_avg_ms\tfailed\toutdir\n" >"$summary"

  for commit in "${COMMITS[@]}"; do
    build_and_start_commit "$commit"
    short_commit="$(git -C "$PG_WORKTREE" rev-parse --short=12 HEAD)"
    mkdir -p "$RESULT_ROOT/$short_commit"
    git -C "$PG_WORKTREE" log -1 --oneline >"$RESULT_ROOT/$short_commit/commit.txt"
    sql -c "select name, setting from pg_settings where name in ('shared_preload_libraries', 'pg_stat_statements.max', 'max_connections') order by 1;" \
      >"$RESULT_ROOT/$short_commit/settings.out"

    run_hotcold_ladder "$short_commit" hotcold_100m "$SCRIPT_DIR/pgbench_hot_cold_100m.sql"
    run_hotcold_ladder "$short_commit" hotcold_1500 "$SCRIPT_DIR/pgbench_hot_cold_1500.sql"
    run_select_only_ladder "$short_commit"
  done

  echo
  echo "Results: $RESULT_ROOT"
  echo "Summary: $summary"
}

main "$@"
