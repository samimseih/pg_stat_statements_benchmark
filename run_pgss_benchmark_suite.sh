#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_WORKTREE="${PG_WORKTREE:-$HOME/pgdev/installations/worktrees/dev}"

# BUILD_MODE=archive (default) only reads PG_WORKTREE: each commit is exported
# with git archive, then built and installed under BENCH_ROOT, and its cluster
# runs there on PGPORT.  BUILD_MODE=worktree checks out each commit in
# PG_WORKTREE and builds it in BUILD_DIR, which includes uncommitted changes
# applied there, as the EC2 setup does.  BUILD_MODE=prebuilt builds nothing:
# each commit must already be installed in PREFIX/pghome/WORKTREE_NAME-<sha>,
# as BUILD_MODE=worktree with RUN_ORDER=interleaved installs it, and
# PG_WORKTREE is only read for commit names.  BUILD_ONLY=1 stops after
# building and installing the commits.
BUILD_MODE="${BUILD_MODE:-archive}"
BUILD_ONLY="${BUILD_ONLY:-0}"
BENCH_ROOT="${BENCH_ROOT:-/tmp/pgss_bench_suite}"
MESON_FLAGS="${MESON_FLAGS:--Dbuildtype=release -Doptimization=2 -Ddebug=false -Db_ndebug=true -Dcassert=false -Dtap_tests=disabled -Ddocs=disabled}"
if [[ "$BUILD_MODE" == "archive" ]]; then
  PREFIX="${PREFIX:-$BENCH_ROOT}"
else
  PREFIX="${PREFIX:-$HOME/pgdev/installations}"
fi
WORKTREE_NAME="${WORKTREE_NAME:-dev}"
BUILD_DIR="${BUILD_DIR:-$PG_WORKTREE/build-release}"

PGHOST="${PGHOST:-localhost}"
# Not PGPORT, which a dev environment usually exports for its own server
BENCH_PGPORT="${BENCH_PGPORT:-55433}"
PGPORT="$BENCH_PGPORT"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"

COMMITS=(${COMMITS:-fbef23389f1 3051c223a60})
CLIENTS=(${CLIENTS:-1 2 4 8 16 32 64 128 256})
SELECT_CLIENTS=(${SELECT_CLIENTS:-${CLIENTS[*]}})
MAX_THREADS="${MAX_THREADS:-32}"
CPU_LIMIT="${CPU_LIMIT:-0}"
CPU_SET="${CPU_SET:-}"
CPU_SCRIPT="${CPU_SCRIPT:-$SCRIPT_DIR/set_cpus.sh}"
PROGRESS_SECONDS="${PROGRESS_SECONDS:-10}"
PGSS_SAMPLE_SECONDS="${PGSS_SAMPLE_SECONDS:-5}"
PGSS_SAMPLE_START_DELAY_SECONDS="${PGSS_SAMPLE_START_DELAY_SECONDS:-15}"
RUN_HOTCOLD_4000_100M="${RUN_HOTCOLD_4000_100M:-1}"
RUN_HOTCOLD_4000_1500="${RUN_HOTCOLD_4000_1500:-1}"
RUN_SELECT_ONLY="${RUN_SELECT_ONLY:-1}"
RUN_ORDER="${RUN_ORDER:-commit_major}"

HOTCOLD_SECONDS="${HOTCOLD_SECONDS:-60}"
SELECT_SECONDS="${SELECT_SECONDS:-120}"
SELECT_SCALE="${SELECT_SCALE:-10}"
SELECT_WARMUP_SECONDS="${SELECT_WARMUP_SECONDS:-30}"

PGSS_MAX="${PGSS_MAX:-5000}"
PGSS_QUERY_TEXT_MEMORY="${PGSS_QUERY_TEXT_MEMORY:-}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-300}"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULT_ROOT="${RESULT_ROOT:-$SCRIPT_DIR/results/$RUN_ID}"

PGHOME_BASE="$PREFIX/pghome"
PGDATA_BASE="$PREFIX/pgdata"
PGHOME=""
PGDATA=""
PGBENCH=""

summary="$RESULT_ROOT/summary.tsv"
original_ref=""

declare -a PSQL
declare -a PSQL_AT
declare -A COMMIT_INSTALL_NAME
declare -A COMMIT_SHORT_NAME

die() {
  echo "error: $*" >&2
  exit 1
}

set_pg_paths() {
  local install_name="$1"
  local data_name="${2:-$WORKTREE_NAME}"

  PGHOME="$PGHOME_BASE/$install_name"
  PGDATA="$PGDATA_BASE/$data_name"

  PSQL=("$PGHOME/bin/psql" -X -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
  PSQL_AT=("$PGHOME/bin/psql" -XAt -F $'\t' -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
  PGBENCH="$PGHOME/bin/pgbench"
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

# CPU_LIMIT=N keeps CPUs 0..N-1 online while measuring, and CPU_SET=LIST the
# CPUs of LIST (e.g. 0-3,16-19).  Builds run with all CPUs, and all CPUs are
# restored when the script exits for any reason.
cpu_limited=0

cpu_limit_apply() {
  local spec online expected

  if [[ -n "$CPU_SET" ]]; then
    (( CPU_LIMIT == 0 )) || die "set only one of CPU_LIMIT and CPU_SET"
    spec="$CPU_SET"
  elif (( CPU_LIMIT > 0 )); then
    spec="$CPU_LIMIT"
  else
    return 0
  fi
  [[ -x "$CPU_SCRIPT" ]] || die "CPU_SCRIPT $CPU_SCRIPT is not executable"

  cpu_limited=1
  "$CPU_SCRIPT" "$spec" >/dev/null || die "could not set online CPUs to $spec"
  online="$("$CPU_SCRIPT" --expand "$(cat /sys/devices/system/cpu/online)" | tr '\n' ' ')"
  expected="$("$CPU_SCRIPT" --expand "$spec" | tr '\n' ' ')"
  [[ "$online" == "$expected" ]] ||
    die "expected online CPUs $spec, found $(cat /sys/devices/system/cpu/online)"
  echo "==> Measuring with online CPUs $(cat /sys/devices/system/cpu/online)"
}

cpu_limit_restore() {
  (( cpu_limited )) || return 0

  if ! "$CPU_SCRIPT" >/dev/null; then
    echo "error: could not restore online CPUs; run $CPU_SCRIPT" >&2
    return 1
  fi
  cpu_limited=0
  echo "==> Restored online CPUs ($(cat /sys/devices/system/cpu/online))"
}

cleanup_on_exit() {
  local status=$?

  cpu_limit_restore || status=1
  checkout_original_on_exit
  exit "$status"
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

qtext_file_size() {
  local total=0
  local qtext_file

  shopt -s nullglob
  for qtext_file in "$PGDATA"/pg_stat_tmp/pgss_query_texts.stat \
                    "$PGDATA"/pg_stat_tmp/pgss_query_texts_*.stat; do
    [[ -f "$qtext_file" ]] || continue
    total=$((total + $(wc -c <"$qtext_file")))
  done
  shopt -u nullglob

  echo "$total"
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
  if [[ -n "$PGSS_QUERY_TEXT_MEMORY" &&
        "$(sql_at -c "select count(*) from pg_settings where name = 'pg_stat_statements.query_text_memory';")" == "1" ]]; then
    sql -c "ALTER SYSTEM SET pg_stat_statements.query_text_memory = '$PGSS_QUERY_TEXT_MEMORY';"
    sql -q -c "select pg_reload_conf();" >/dev/null
  fi
  sql -q -c "create extension if not exists pg_stat_statements;" >/dev/null
  reset_pgss
}

verify_release_build() {
  local config

  config="$(meson configure "$BUILD_DIR" 2>/dev/null)"
  echo
  echo "=== Configured build type ($BUILD_DIR) ==="
  echo "$config" | grep -E '^\s+(buildtype|optimization|debug|b_ndebug|cassert)\s'

  echo "$config" | awk '
    $1 == "debug" && $2 != "false" { exit 1 }
    $1 == "optimization" && $2 == "0" { exit 1 }
    $1 == "b_ndebug" && $2 != "true" { exit 1 }
    $1 == "cassert" && $2 != "false" { exit 1 }
  ' || die "$BUILD_DIR is not configured as a release/perf build"
}

configure_build_prefix() {
  meson configure "$BUILD_DIR" --prefix="$PGHOME" >/dev/null
}

recreate_cluster() {
  "$PGHOME/bin/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true
  rm -rf -- "$PGDATA"
  "$PGHOME/bin/initdb" -D "$PGDATA" -U "$PGUSER" --data-checksums
  echo "port = $PGPORT" >>"$PGDATA/postgresql.conf"
  "$PGHOME/bin/pg_ctl" -D "$PGDATA" -l "$PGDATA/logfile" -w start
}

# Build a commit from a git archive export into BENCH_ROOT, once per commit
# and set of build flags.  Sets BUILD_DIR, and the install name for
# set_pg_paths().
archive_build_commit() {
  local commit="$1" sha key dir cc="cc"

  sha="$(git -C "$PG_WORKTREE" rev-parse --verify "$commit^{commit}")"
  key="$(printf '%s %s' "$sha" "$MESON_FLAGS" | sha1sum | cut -c1-12)"
  dir="$BENCH_ROOT/pghome/${sha:0:12}-$key"
  BUILD_DIR="$dir/build"
  ARCHIVE_INSTALL_NAME="${sha:0:12}-$key/install"

  if [[ -f "$dir/.complete" ]]; then
    echo "Using cached build $dir"
    return
  fi

  command -v ccache >/dev/null && cc="ccache cc"
  rm -rf -- "$dir"
  mkdir -p "$dir/src"
  git -C "$PG_WORKTREE" archive "$sha" | tar -x -C "$dir/src"
  # shellcheck disable=SC2086
  CC="$cc" meson setup "$BUILD_DIR" "$dir/src" --prefix="$dir/install" \
    $MESON_FLAGS >"$dir/setup.log" 2>&1 ||
    { tail -n 30 "$dir/setup.log"; die "meson setup failed for $commit"; }
  verify_release_build
  ninja -C "$BUILD_DIR" install >"$dir/build.log" 2>&1 ||
    { grep -E 'error|FAILED' "$dir/build.log" | head -n 30; die "build failed for $commit"; }
  touch "$dir/.complete"
}

capture_commit_settings() {
  local short_commit="$1"

  sql -c "select name, setting from pg_settings where name in ('shared_preload_libraries', 'pg_stat_statements.max', 'pg_stat_statements.query_text_memory', 'max_connections') order by 1;" \
    >"$RESULT_ROOT/$short_commit/settings.out"
}

build_and_start_commit() {
  local commit="$1"

  cpu_limit_restore || die "could not restore online CPUs before building"
  echo
  echo "==> Building $commit"
  if [[ "$BUILD_MODE" == "archive" ]]; then
    archive_build_commit "$commit"
    set_pg_paths "$ARCHIVE_INSTALL_NAME"
  elif [[ "$BUILD_MODE" == "prebuilt" ]]; then
    set_pg_paths "$(prebuilt_install_name "$commit")"
  else
    set_pg_paths "$WORKTREE_NAME"
    git -C "$PG_WORKTREE" checkout -q "$commit"
    configure_build_prefix
    verify_release_build
    ninja -C "$BUILD_DIR" clean
    ninja -C "$BUILD_DIR" install
  fi
  recreate_cluster
  configure_cluster
}

# Install name of a commit built beforehand, failing if it is not installed
prebuilt_install_name() {
  local commit="$1" install_name

  install_name="$WORKTREE_NAME-$(git -C "$PG_WORKTREE" rev-parse --short=12 "$commit^{commit}")"
  [[ -x "$PGHOME_BASE/$install_name/bin/postgres" ]] ||
    die "commit $commit is not installed in $PGHOME_BASE/$install_name"
  echo "$install_name"
}

prepare_commit_install() {
  local commit="$1"
  local short_commit install_name

  echo
  echo "==> Building $commit"
  short_commit="$(git -C "$PG_WORKTREE" rev-parse --short=12 "$commit^{commit}")"
  if [[ "$BUILD_MODE" == "archive" ]]; then
    archive_build_commit "$commit"
    install_name="$ARCHIVE_INSTALL_NAME"
  elif [[ "$BUILD_MODE" == "prebuilt" ]]; then
    install_name="$(prebuilt_install_name "$commit")"
  else
    git -C "$PG_WORKTREE" checkout -q "$commit"
    install_name="$WORKTREE_NAME-$short_commit"
  fi

  COMMIT_SHORT_NAME["$commit"]="$short_commit"
  COMMIT_INSTALL_NAME["$commit"]="$install_name"

  mkdir -p "$RESULT_ROOT/$short_commit"
  git -C "$PG_WORKTREE" log -1 --oneline "$commit" >"$RESULT_ROOT/$short_commit/commit.txt"

  set_pg_paths "$install_name"
  if [[ "$BUILD_MODE" == "worktree" ]]; then
    configure_build_prefix
    verify_release_build
    ninja -C "$BUILD_DIR" clean
    ninja -C "$BUILD_DIR" install
  fi
}

start_prepared_commit() {
  local commit="$1"
  local short_commit="${COMMIT_SHORT_NAME[$commit]}"
  local install_name="${COMMIT_INSTALL_NAME[$commit]}"

  [[ -n "$short_commit" && -n "$install_name" ]] || die "commit $commit has not been prepared"

  set_pg_paths "$install_name"
  recreate_cluster
  configure_cluster
  capture_commit_settings "$short_commit"
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
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      sample_epoch bucket entries calls min_calls max_calls avg_calls \
      entry_dealloc entry_dsa_size qtext_dsa_size qtext_count \
      qtext_total_len
    sleep "$PGSS_SAMPLE_START_DELAY_SECONDS"
    while true; do
      sql_at -c "
        with sample as (
          select extract(epoch from clock_timestamp())::numeric(20,3) as ts
        ),
        info as (
          select to_jsonb(i) as j
          from pg_stat_statements_info as i
        ),
        statements as (
          select case
                   when query is null then 'null_query'
                   when query = '' then 'empty_query'
                   when query like 'WITH CTEPOP_%' then 'pop'
                   when query like 'WITH CTEUNPOP_%' then 'unpop'
                   when lower(query) like 'select abalance from pgbench_accounts%' then 'select_only'
                   else 'other'
                 end as bucket,
                 calls
          from pg_stat_statements(true)
        )
        select sample.ts,
               statements.bucket,
               count(*),
               coalesce(sum(statements.calls), 0),
               coalesce(min(statements.calls), 0),
               coalesce(max(statements.calls), 0),
               coalesce(avg(statements.calls), 0)::numeric(20,2),
               coalesce((info.j->>'entry_dealloc')::bigint,
                        (info.j->>'dealloc')::bigint,
                        0),
               coalesce((info.j->>'entry_dsa_size')::bigint, 0),
               coalesce((info.j->>'qtext_dsa_size')::bigint, 0),
               coalesce((info.j->>'qtext_count')::bigint, 0),
               coalesce((info.j->>'qtext_total_len')::bigint, 0)
        from statements
        cross join sample
        cross join info
        group by sample.ts, statements.bucket, info.j
        order by statements.bucket;"
      sleep "$PGSS_SAMPLE_SECONDS"
    done
  ) >"$outdir/monitor_pgss.tsv" 2>"$outdir/monitor_pgss.err" &
  sampler_pids+=("$!")

  (
    printf "%s\t%s\n" sample_epoch qtext_file_size
    sleep "$PGSS_SAMPLE_START_DELAY_SECONDS"
    while true; do
      printf "%s\t%s\n" "$(date +%s)" "$(qtext_file_size)"
      sleep "$PGSS_SAMPLE_SECONDS"
    done
  ) >"$outdir/monitor_qtext_file.tsv" 2>"$outdir/monitor_qtext_file.err" &
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

extract_monitor_summary() {
  local file="$1"
  local i

  if [[ ! -s "$file" ]]; then
    printf "0"
    for ((i = 1; i < 32; i++)); do
      printf "\t0"
    done
    printf "\n"
    return
  fi

  awk -F $'\t' '
    function zero_summary(i) {
      printf "0"
      for (i = 1; i < 32; i++)
        printf "\t0"
      printf "\n"
    }
    NR == 1 { next }
    NF < 12 { next }
    {
      sample = int($1 + 0)
      bucket = $2
      entries = $3 + 0
      samples[sample] = 1
      totals[sample] += entries
      bucket_entries[sample, bucket] = entries

      if (totals[sample] > max_entries)
        max_entries = totals[sample]
      if (bucket == "pop" && entries > max_pop)
        max_pop = entries
      if (bucket == "unpop" && entries > max_unpop)
        max_unpop = entries
      if (bucket == "select_only" && entries > max_select)
        max_select = entries
      if (bucket == "empty_query" && entries > max_empty_query)
        max_empty_query = entries
      if (bucket == "other" && entries > max_other)
        max_other = entries
      if (($8 + 0) > max_entry_dealloc)
        max_entry_dealloc = $8 + 0

      entry_dsa_size = $9 + 0
      qtext_dsa_size = $10 + 0
      qtext_count = $11 + 0
      qtext_total_len = $12 + 0
      sample_entry_dsa_size[sample] = entry_dsa_size
      sample_qtext_dsa_size[sample] = qtext_dsa_size
      sample_qtext_count[sample] = qtext_count
      sample_qtext_total_len[sample] = qtext_total_len

      if (!seen_memory || entry_dsa_size < min_entry_dsa_size)
        min_entry_dsa_size = entry_dsa_size
      if (!seen_memory || qtext_dsa_size < min_qtext_dsa_size)
        min_qtext_dsa_size = qtext_dsa_size
      if (!seen_memory || qtext_count < min_qtext_count)
        min_qtext_count = qtext_count
      if (!seen_memory || qtext_total_len < min_qtext_total_len)
        min_qtext_total_len = qtext_total_len

      if (entry_dsa_size > max_entry_dsa_size)
        max_entry_dsa_size = entry_dsa_size
      if (qtext_dsa_size > max_qtext_dsa_size)
        max_qtext_dsa_size = qtext_dsa_size
      if (qtext_count > max_qtext_count)
        max_qtext_count = qtext_count
      if (qtext_total_len > max_qtext_total_len)
        max_qtext_total_len = qtext_total_len

      seen_memory = 1
    }
    END {
      for (sample in samples) {
        entries = totals[sample] + 0
        pop = bucket_entries[sample, "pop"] + 0
        unpop = bucket_entries[sample, "unpop"] + 0
        select_only = bucket_entries[sample, "select_only"] + 0
        empty_query = bucket_entries[sample, "empty_query"] + 0
        other = bucket_entries[sample, "other"] + 0

        nsamples++
        sum_entries += entries
        sum_pop += pop
        sum_unpop += unpop
        sum_select += select_only
        sum_empty_query += empty_query
        sum_other += other
        sum_entry_dsa_size += sample_entry_dsa_size[sample]
        sum_qtext_dsa_size += sample_qtext_dsa_size[sample]
        sum_qtext_count += sample_qtext_count[sample]
        sum_qtext_total_len += sample_qtext_total_len[sample]

        if (!seen_sample || entries < min_entries)
          min_entries = entries
        if (!seen_sample || pop < min_pop)
          min_pop = pop
        if (!seen_sample || unpop < min_unpop)
          min_unpop = unpop
        if (!seen_sample || select_only < min_select)
          min_select = select_only
        if (!seen_sample || empty_query < min_empty_query)
          min_empty_query = empty_query
        if (!seen_sample || other < min_other)
          min_other = other

        seen_sample = 1
      }

      if (nsamples == 0) {
        zero_summary()
        exit
      }

      printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d",
             max_entries, max_pop, max_unpop, max_select, max_empty_query,
             max_other, max_entry_dealloc, min_entry_dsa_size,
             max_entry_dsa_size, min_qtext_dsa_size, max_qtext_dsa_size,
             min_qtext_count, max_qtext_count, min_qtext_total_len
      printf "\t%d", max_qtext_total_len
      printf "\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f",
             nsamples, sum_entries / nsamples, sum_pop / nsamples,
             sum_unpop / nsamples, sum_select / nsamples,
             sum_empty_query / nsamples, sum_other / nsamples,
             sum_qtext_count / nsamples,
             sum_qtext_total_len / nsamples
      printf "\t%d\t%d\t%d\t%d\t%d\t%d\t%.0f\t%.0f\n",
             min_entries, min_pop, min_unpop, min_select, min_empty_query,
             min_other, sum_entry_dsa_size / nsamples,
             sum_qtext_dsa_size / nsamples
    }' "$file"
}

capture_final_info() {
  local outdir="$1"
  local qtext_size

  qtext_size="$(qtext_file_size)"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    final_entry_dealloc final_entry_count final_entry_dsa_size \
    final_qtext_dsa_size final_qtext_count final_qtext_total_len \
    final_qtext_file_size \
    >"$outdir/final_info.tsv"

  "${PSQL_AT[@]}" -c "
    with info as (
      select to_jsonb(i) as j
      from pg_stat_statements_info as i
    )
    select coalesce((j->>'entry_dealloc')::bigint,
                    (j->>'dealloc')::bigint,
                    0),
           coalesce((j->>'entry_count')::bigint, 0),
           coalesce((j->>'entry_dsa_size')::bigint, 0),
           coalesce((j->>'qtext_dsa_size')::bigint, 0),
           coalesce((j->>'qtext_count')::bigint, 0),
           coalesce((j->>'qtext_total_len')::bigint, 0),
           $qtext_size::bigint
    from info;" >>"$outdir/final_info.tsv" 2>"$outdir/final_info.err" || true
}

extract_qtext_file_summary() {
  local file="$1"

  if [[ ! -s "$file" ]]; then
    printf "0\t0\t0\t0\n"
    return
  fi

  awk -F $'\t' '
    NR == 1 { next }
    NF < 2 { next }
    {
      size = $2 + 0
      if (!seen || size < min)
        min = size
      if (!seen || size > max)
        max = size
      sum += size
      last = size
      n++
      seen = 1
    }
    END {
      if (!seen)
        print "0\t0\t0\t0"
      else
        printf "%d\t%d\t%.0f\t%d\n", min, max, sum / n, last
    }' "$file"
}

extract_final_info_summary() {
  local file="$1"

  if [[ ! -s "$file" ]]; then
    printf "0\t0\t0\t0\t0\t0\t0\n"
    return
  fi

  awk -F $'\t' '
    NR == 1 {
      for (i = 1; i <= NF; i++)
        col[$i] = i
      next
    }
    NF > 0 {
      printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
             ("final_entry_dealloc" in col) ? $(col["final_entry_dealloc"]) : 0,
             ("final_entry_count" in col) ? $(col["final_entry_count"]) : 0,
             ("final_entry_dsa_size" in col) ? $(col["final_entry_dsa_size"]) : 0,
             ("final_qtext_dsa_size" in col) ? $(col["final_qtext_dsa_size"]) : 0,
             ("final_qtext_count" in col) ? $(col["final_qtext_count"]) : 0,
             ("final_qtext_total_len" in col) ? $(col["final_qtext_total_len"]) : 0,
             ("final_qtext_file_size" in col) ? $(col["final_qtext_file_size"]) : 0
      found = 1
      exit
    }
    END {
      if (!found)
        print "0\t0\t0\t0\t0\t0"
    }' "$file"
}

append_summary() {
  local commit="$1" workload="$2" clients="$3" threads="$4" duration="$5" status="$6" outdir="$7"
  local tps latency failed
  local -a values
  local i
  local max_entries max_pop max_unpop max_select max_empty_query max_other
  local max_entry_dealloc min_entry_dsa_size max_entry_dsa_size
  local min_qtext_dsa_size max_qtext_dsa_size min_qtext_count
  local max_qtext_count min_qtext_total_len max_qtext_total_len
  local sample_count avg_entries avg_pop avg_unpop avg_select
  local avg_empty_query avg_other
  local avg_qtext_count avg_qtext_total_len
  local min_entries min_pop min_unpop min_select min_empty_query min_other
  local avg_entry_dsa_size avg_qtext_dsa_size
  local min_qtext_file_size max_qtext_file_size
  local avg_qtext_file_size last_qtext_file_size
  local final_entry_dealloc final_entry_count final_entry_dsa_size
  local final_qtext_dsa_size final_qtext_count final_qtext_total_len
  local final_qtext_file_size

  tps="$(extract_pgbench_field "$outdir/pgbench.log" tps)"
  latency="$(extract_pgbench_field "$outdir/pgbench.log" latency)"
  failed="$(extract_pgbench_field "$outdir/pgbench.log" failed)"

  IFS=$'\t' read -r max_entries max_pop max_unpop max_select \
    max_empty_query max_other \
    max_entry_dealloc min_entry_dsa_size max_entry_dsa_size \
    min_qtext_dsa_size max_qtext_dsa_size min_qtext_count \
    max_qtext_count min_qtext_total_len max_qtext_total_len \
    sample_count avg_entries avg_pop avg_unpop avg_select \
    avg_empty_query avg_other \
    avg_qtext_count avg_qtext_total_len \
    min_entries min_pop min_unpop min_select min_empty_query min_other \
    avg_entry_dsa_size avg_qtext_dsa_size \
    < <(extract_monitor_summary "$outdir/monitor_pgss.tsv")

  IFS=$'\t' read -r min_qtext_file_size max_qtext_file_size \
    avg_qtext_file_size last_qtext_file_size \
    < <(extract_qtext_file_summary "$outdir/monitor_qtext_file.tsv")

  IFS=$'\t' read -r final_entry_dealloc final_entry_count \
    final_entry_dsa_size final_qtext_dsa_size final_qtext_count \
    final_qtext_total_len final_qtext_file_size \
    < <(extract_final_info_summary "$outdir/final_info.tsv")

  values=(
    "$commit" "$workload" "$clients" "$threads" "$duration" "$status"
    "${tps:-}" "${latency:-}" "${failed:-}"
    "$max_entries" "$max_pop" "$max_unpop" "$max_select"
    "$max_empty_query" "$max_other"
    "$max_entry_dealloc" "$min_entry_dsa_size" "$max_entry_dsa_size"
    "$min_qtext_dsa_size" "$max_qtext_dsa_size"
    "$min_qtext_count" "$max_qtext_count"
    "$min_qtext_total_len" "$max_qtext_total_len"
    "$min_qtext_file_size" "$max_qtext_file_size"
    "$avg_qtext_file_size" "$last_qtext_file_size"
    "$sample_count" "$avg_entries" "$avg_pop" "$avg_unpop"
    "$avg_select" "$avg_empty_query" "$avg_other" "$avg_qtext_count"
    "$avg_qtext_total_len"
    "$min_entries" "$min_pop" "$min_unpop" "$min_select"
    "$min_empty_query" "$min_other"
    "$avg_entry_dsa_size" "$avg_qtext_dsa_size"
    "$final_entry_dealloc" "$final_entry_count" "$final_entry_dsa_size"
    "$final_qtext_dsa_size" "$final_qtext_count" "$final_qtext_total_len"
    "$final_qtext_file_size"
    "$outdir"
  )

  printf "%s" "${values[0]}" >>"$summary"
  for ((i = 1; i < ${#values[@]}; i++)); do
    printf "\t%s" "${values[$i]}" >>"$summary"
  done
  printf "\n" >>"$summary"
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

  capture_final_info "$outdir"
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

run_interleaved_hotcold_ladder() {
  local workload="$1" script="$2"
  local clients commit short_commit

  for clients in "${CLIENTS[@]}"; do
    for commit in "${COMMITS[@]}"; do
      short_commit="${COMMIT_SHORT_NAME[$commit]}"
      start_prepared_commit "$commit"
      echo "==> $short_commit $workload clients=$clients"
      run_pgbench_capture "$short_commit" "$workload" "$clients" "$HOTCOLD_SECONDS" \
        "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -n -M simple \
        -P "$PROGRESS_SECONDS" -f "$script"
    done
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

  for clients in "${SELECT_CLIENTS[@]}"; do
    echo "==> $commit select_only clients=$clients"
    run_pgbench_capture "$commit" select_only "$clients" "$SELECT_SECONDS" \
      "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -n -M prepared \
      -P "$PROGRESS_SECONDS" -S
  done
}

run_interleaved_select_only_ladder() {
  local clients commit short_commit

  for clients in "${SELECT_CLIENTS[@]}"; do
    for commit in "${COMMITS[@]}"; do
      short_commit="${COMMIT_SHORT_NAME[$commit]}"
      start_prepared_commit "$commit"

      echo "==> $short_commit select_only init scale=$SELECT_SCALE"
      "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -i -s "$SELECT_SCALE" "$PGDATABASE" \
        >"$RESULT_ROOT/$short_commit/select_init_c$clients.log" 2>&1

      echo "==> $short_commit select_only warmup ${SELECT_WARMUP_SECONDS}s"
      "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -n -M prepared \
        -c 32 -j 32 -T "$SELECT_WARMUP_SECONDS" -S "$PGDATABASE" \
        >"$RESULT_ROOT/$short_commit/select_warmup_c$clients.log" 2>&1

      echo "==> $short_commit select_only clients=$clients"
      run_pgbench_capture "$short_commit" select_only "$clients" "$SELECT_SECONDS" \
        "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -n -M prepared \
        -P "$PROGRESS_SECONDS" -S
    done
  done
}

run_interleaved() {
  local commit

  for commit in "${COMMITS[@]}"; do
    prepare_commit_install "$commit"
  done
  cpu_limit_apply

  if [[ "$RUN_HOTCOLD_4000_100M" == "1" ]]; then
    run_interleaved_hotcold_ladder hotcold_4000_100m "$SCRIPT_DIR/pgbench_hot_cold_4000_100m.sql"
  fi
  if [[ "$RUN_HOTCOLD_4000_1500" == "1" ]]; then
    run_interleaved_hotcold_ladder hotcold_4000_1500 "$SCRIPT_DIR/pgbench_hot_cold_4000_1500.sql"
  fi
  if [[ "$RUN_SELECT_ONLY" == "1" ]]; then
    run_interleaved_select_only_ladder
  fi
}

run_commit_major() {
  local commit short_commit

  for commit in "${COMMITS[@]}"; do
    build_and_start_commit "$commit"
    short_commit="$(git -C "$PG_WORKTREE" rev-parse --short=12 "$commit^{commit}")"
    mkdir -p "$RESULT_ROOT/$short_commit"
    git -C "$PG_WORKTREE" log -1 --oneline "$commit" >"$RESULT_ROOT/$short_commit/commit.txt"
    capture_commit_settings "$short_commit"
    cpu_limit_apply

    if [[ "$RUN_HOTCOLD_4000_100M" == "1" ]]; then
      run_hotcold_ladder "$short_commit" hotcold_4000_100m "$SCRIPT_DIR/pgbench_hot_cold_4000_100m.sql"
    fi
    if [[ "$RUN_HOTCOLD_4000_1500" == "1" ]]; then
      run_hotcold_ladder "$short_commit" hotcold_4000_1500 "$SCRIPT_DIR/pgbench_hot_cold_4000_1500.sql"
    fi
    if [[ "$RUN_SELECT_ONLY" == "1" ]]; then
      run_select_only_ladder "$short_commit"
    fi
  done
}

main() {
  local -a header
  local i

  case "$RUN_ORDER" in
    commit_major|interleaved)
      ;;
    *)
      die "unsupported RUN_ORDER: $RUN_ORDER"
      ;;
  esac

  case "$BUILD_MODE" in
    archive|prebuilt)
      ;;
    worktree)
      check_worktree_clean
      original_ref="$(git -C "$PG_WORKTREE" symbolic-ref --short -q HEAD || git -C "$PG_WORKTREE" rev-parse HEAD)"
      ;;
    *)
      die "unsupported BUILD_MODE: $BUILD_MODE"
      ;;
  esac
  trap cleanup_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  set_pg_paths "$WORKTREE_NAME"

  if [[ "$BUILD_ONLY" == "1" ]]; then
    for commit in "${COMMITS[@]}"; do
      prepare_commit_install "$commit"
    done
    echo
    echo "Installed: ${COMMIT_INSTALL_NAME[*]}"
    return
  fi

  mkdir -p "$RESULT_ROOT"
  header=(
    commit workload clients threads duration_s status tps latency_avg_ms \
    failed max_entries max_pop_entries max_unpop_entries max_select_entries \
    max_empty_query_entries max_other_entries max_entry_dealloc min_entry_dsa_size \
    max_entry_dsa_size min_qtext_dsa_size max_qtext_dsa_size \
    min_qtext_count max_qtext_count min_qtext_total_len \
    max_qtext_total_len min_qtext_file_size max_qtext_file_size \
    avg_qtext_file_size last_qtext_file_size \
    sample_count avg_entries avg_pop_entries \
    avg_unpop_entries avg_select_entries avg_empty_query_entries avg_other_entries \
    avg_qtext_count avg_qtext_total_len min_entries min_pop_entries \
    min_unpop_entries min_select_entries min_empty_query_entries min_other_entries \
    avg_entry_dsa_size avg_qtext_dsa_size \
    final_entry_dealloc final_entry_count final_entry_dsa_size \
    final_qtext_dsa_size final_qtext_count final_qtext_total_len \
    final_qtext_file_size outdir \
  )
  printf "%s" "${header[0]}" >"$summary"
  for ((i = 1; i < ${#header[@]}; i++)); do
    printf "\t%s" "${header[$i]}" >>"$summary"
  done
  printf "\n" >>"$summary"

  if [[ "$RUN_ORDER" == "interleaved" ]]; then
    run_interleaved
  else
    run_commit_major
  fi

  echo
  echo "Results: $RESULT_ROOT"
  echo "Summary: $summary"
}

main "$@"
