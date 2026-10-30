#!/usr/bin/env bash
set -Eeuo pipefail

exec > >(tee -a /var/log/pgss-benchmark.log) 2>&1

echo "pgss profile bootstrap started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

status=0
uploaded=0

finish() {
  status="$?"
  set +e

  echo "pgss profile bootstrap finished with status $status at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -n "${RESULT_S3_URI:-}" ]]; then
    mkdir -p /tmp/pgss-upload

    if [[ -d "${RESULT_ROOT:-}" ]]; then
      tar -C "$(dirname "$RESULT_ROOT")" -czf "/tmp/pgss-upload/${RUN_ID}.results.tar.gz" "$(basename "$RESULT_ROOT")"
      aws s3 cp "/tmp/pgss-upload/${RUN_ID}.results.tar.gz" "$RESULT_S3_URI/${RUN_ID}.results.tar.gz" && uploaded=1
    fi

    cp /var/log/pgss-benchmark.log "/tmp/pgss-upload/${RUN_ID}.cloud-init.log"
    aws s3 cp "/tmp/pgss-upload/${RUN_ID}.cloud-init.log" "$RESULT_S3_URI/${RUN_ID}.cloud-init.log" || true
  fi

  if [[ "${AUTO_TERMINATE:-0}" == "1" ]]; then
    if [[ "$status" == "0" && "$uploaded" == "1" ]]; then
      echo "profile succeeded and uploaded; shutting down for termination"
      shutdown -h now
    elif [[ "${TERMINATE_ON_FAILURE:-0}" == "1" ]]; then
      echo "profile failed but TERMINATE_ON_FAILURE=1; shutting down for termination"
      shutdown -h now
    else
      echo "leaving instance running for inspection"
    fi
  fi

  exit "$status"
}
trap finish EXIT

cat >/etc/pgss-benchmark.env <<'EOF'
__PGSS_BENCHMARK_ENV__
EOF

set -a
# shellcheck source=/dev/null
. /etc/pgss-benchmark.env
set +a

dnf -y update
dnf -y install \
  bison \
  diffutils \
  flex \
  gcc \
  gcc-c++ \
  git \
  gzip \
  awscli \
  libuuid-devel \
  libxml2-devel \
  libxslt-devel \
  meson \
  ninja-build \
  openssl-devel \
  perl \
  perl-IPC-Run \
  procps-ng \
  python3 \
  readline-devel \
  sysstat \
  tar \
  tmux \
  util-linux \
  which \
  zlib-devel

dnf -y install perf || dnf -y install kernel-tools || true
sysctl -w kernel.perf_event_paranoid=-1 || true
sysctl -w kernel.kptr_restrict=0 || true

runuser -l ec2-user -c "mkdir -p '$WORK_ROOT' '$PREFIX' '$RESULT_ROOT'"

runuser -l ec2-user -c "
  set -Eeuo pipefail
  cd '$WORK_ROOT'
  git clone '$PG_REMOTE' postgres
  cd postgres
  git remote add samimseih '$PATCH_REMOTE'
  git fetch origin '$BASE_REF:refs/remotes/origin/$BASE_REF'
  git fetch samimseih '$PATCH_REF:refs/remotes/samimseih/$PATCH_REF'
  meson setup build-release \
    --prefix='$PREFIX/pghome/dev' \
    --buildtype=release \
    -Db_ndebug=true \
    -Dcassert=false
  cd '$WORK_ROOT'
  git clone '$BENCHMARK_REPO' pg_stat_statements_benchmark
"

cat >"$WORK_ROOT/profile_pgss.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PG_WORKTREE="${PG_WORKTREE:?}"
BENCHMARK_DIR="${BENCHMARK_DIR:?}"
PREFIX="${PREFIX:?}"
RESULT_ROOT="${RESULT_ROOT:?}"
PROFILE_COMMITS="${PROFILE_COMMITS:?}"
PROFILE_CLIENTS="${PROFILE_CLIENTS:?}"
PROFILE_SECONDS="${PROFILE_SECONDS:-150}"
PROFILE_WARMUP_SECONDS="${PROFILE_WARMUP_SECONDS:-20}"
PROFILE_RECORD_SECONDS="${PROFILE_RECORD_SECONDS:-90}"
PGSS_MAX="${PGSS_MAX:-5000}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-300}"

PGHOME="$PREFIX/pghome/dev"
PGDATA="$PREFIX/pgdata/dev"
BUILD_DIR="$PG_WORKTREE/build-release"
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGDATABASE=postgres

PSQL=("$PGHOME/bin/psql" -X -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
PSQL_AT=("$PGHOME/bin/psql" -XAt -F $'\t' -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE")
PGBENCH="$PGHOME/bin/pgbench"

threads_for_clients() {
  local clients="$1"

  if ((clients < 32)); then
    echo "$clients"
  else
    echo 32
  fi
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

recreate_cluster() {
  "$PGHOME/bin/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true
  rm -rf -- "$PGDATA"
  "$PGHOME/bin/initdb" -D "$PGDATA" -U "$PGUSER" --data-checksums
  "$PGHOME/bin/pg_ctl" -D "$PGDATA" -l "$PGDATA/logfile" -w start
}

build_commit() {
  local commit="$1"

  echo "==> Building $commit"
  git -C "$PG_WORKTREE" checkout -q "$commit"
  meson configure "$BUILD_DIR" | grep -E '^\s+(buildtype|optimization|debug|b_ndebug|cassert)\s' || true
  ninja -C "$BUILD_DIR" clean
  ninja -C "$BUILD_DIR" install
  recreate_cluster
  configure_cluster
}

start_wait_sampler() {
  local outdir="$1"

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
  wait_sampler_pid="$!"
}

stop_wait_sampler() {
  if [[ -n "${wait_sampler_pid:-}" ]]; then
    kill "$wait_sampler_pid" 2>/dev/null || true
    wait "$wait_sampler_pid" 2>/dev/null || true
    wait_sampler_pid=""
  fi
}

capture_pgss() {
  local outdir="$1"

  sql_at -c "
    select count(*), coalesce(sum(calls), 0)
    from pg_stat_statements(true);" >"$outdir/pgss_count.tsv" 2>"$outdir/pgss_count.err" || true

  sql -c "select * from pg_stat_statements_info;" >"$outdir/pgss_info.out" 2>"$outdir/pgss_info.err" || true
  sql -c "
    select left(query, 80) as query, calls, total_exec_time, mean_exec_time
    from pg_stat_statements(true)
    order by total_exec_time desc
    limit 20;" >"$outdir/top_statements.out" 2>"$outdir/top_statements.err" || true
}

extract_tps() {
  awk '/^tps =/ {v=$3} END {print v+0}' "$1"
}

extract_failed() {
  awk -F: '/number of failed transactions/ {
    gsub(/^[ \t]+/, "", $2);
    split($2, a, " ");
    v = a[1]
  } END {print v+0}' "$1"
}

summarize_waits() {
  local waits="$1"

  awk -F $'\t' '
    NF >= 4 {
      key = ($2 == "" && $3 == "") ? "cpu/no wait" : $2 ":" $3
      counts[key] += $4
    }
    END {
      for (key in counts)
        printf "%s\t%d\n", key, counts[key]
    }' "$waits" | sort -k2,2nr
}

run_point() {
  local label="$1" commit="$2" clients="$3"
  local short_commit threads outdir pgbench_pid status

  short_commit="$(git -C "$PG_WORKTREE" rev-parse --short=12 HEAD)"
  threads="$(threads_for_clients "$clients")"
  outdir="$RESULT_ROOT/$label-$short_commit/hotcold_100m/c$clients"
  mkdir -p "$outdir"

  {
    echo "label=$label"
    echo "commit=$commit"
    echo "short_commit=$short_commit"
    echo "clients=$clients"
    echo "threads=$threads"
    echo "duration=$PROFILE_SECONDS"
    echo "warmup=$PROFILE_WARMUP_SECONDS"
    echo "record_seconds=$PROFILE_RECORD_SECONDS"
    echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$outdir/meta.txt"

  reset_pgss
  start_wait_sampler "$outdir"

  set +e
  "$PGBENCH" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -n -M simple \
    -P 10 -f "$BENCHMARK_DIR/pgbench_hot_cold_100m.sql" \
    -c "$clients" -j "$threads" -T "$PROFILE_SECONDS" "$PGDATABASE" \
    >"$outdir/pgbench.log" 2>&1 &
  pgbench_pid="$!"

  sleep "$PROFILE_WARMUP_SECONDS"
  if command -v perf >/dev/null 2>&1; then
    perf record -F 99 -g -a -o "$outdir/perf.data" -- sleep "$PROFILE_RECORD_SECONDS" \
      >"$outdir/perf_record.out" 2>"$outdir/perf_record.err"
    perf report -i "$outdir/perf.data" --stdio --no-children \
      --sort comm,dso,symbol >"$outdir/perf_report_flat.txt" 2>"$outdir/perf_report_flat.err"
    perf report -i "$outdir/perf.data" --stdio --children \
      --sort comm,dso,symbol >"$outdir/perf_report_children.txt" 2>"$outdir/perf_report_children.err"
  else
    echo "perf not installed" >"$outdir/perf_record.err"
  fi

  wait "$pgbench_pid"
  status="$?"
  set -e

  stop_wait_sampler
  capture_pgss "$outdir"
  summarize_waits "$outdir/waits.tsv" >"$outdir/wait_summary.tsv"
  tail -n 200 "$PGDATA/logfile" >"$outdir/server_log_tail.log" 2>/dev/null || true

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$label" "$short_commit" "$clients" "$status" \
    "$(extract_tps "$outdir/pgbench.log")" \
    "$(extract_failed "$outdir/pgbench.log")" \
    "$outdir" >>"$RESULT_ROOT/profile_summary.tsv"

  if [[ "$status" != "0" ]]; then
    echo "pgbench failed for $label $short_commit c$clients; see $outdir/pgbench.log" >&2
  fi
}

main() {
  local -a commit_specs clients
  local spec label commit clients_value

  printf "label\tcommit\tclients\tstatus\ttps\tfailed\toutdir\n" >"$RESULT_ROOT/profile_summary.tsv"

  # shellcheck disable=SC2206
  commit_specs=($PROFILE_COMMITS)
  # shellcheck disable=SC2206
  clients=($PROFILE_CLIENTS)

  for spec in "${commit_specs[@]}"; do
    label="${spec%%=*}"
    commit="${spec#*=}"
    build_commit "$commit"

    for clients_value in "${clients[@]}"; do
      echo "==> Profiling $label $commit clients=$clients_value"
      run_point "$label" "$commit" "$clients_value"
    done
  done
}

main "$@"
EOF

chown ec2-user:ec2-user "$WORK_ROOT/profile_pgss.sh"
chmod +x "$WORK_ROOT/profile_pgss.sh"

runuser -l ec2-user -c "
  set -Eeuo pipefail
  env \
    PG_WORKTREE='$WORK_ROOT/postgres' \
    BENCHMARK_DIR='$WORK_ROOT/pg_stat_statements_benchmark' \
    PREFIX='$PREFIX' \
    RESULT_ROOT='$RESULT_ROOT' \
    PROFILE_COMMITS='${PROFILE_COMMITS:-patch=${PATCH_COMMIT:-samimseih/$PATCH_REF} upstream=origin/$BASE_REF}' \
    PROFILE_CLIENTS='$PROFILE_CLIENTS' \
    PROFILE_SECONDS='$PROFILE_SECONDS' \
    PROFILE_WARMUP_SECONDS='$PROFILE_WARMUP_SECONDS' \
    PROFILE_RECORD_SECONDS='$PROFILE_RECORD_SECONDS' \
    PGSS_MAX='$PGSS_MAX' \
    MAX_CONNECTIONS='$MAX_CONNECTIONS' \
    '$WORK_ROOT/profile_pgss.sh'
"
