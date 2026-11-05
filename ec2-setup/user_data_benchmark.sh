#!/usr/bin/env bash
set -Eeuo pipefail

exec > >(tee -a /var/log/pgss-benchmark.log) 2>&1

echo "pgss benchmark bootstrap started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

status=0
uploaded=0

finish() {
  status="$?"
  set +e

  echo "pgss benchmark bootstrap finished with status $status at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -n "${RESULT_S3_URI:-}" ]]; then
    mkdir -p /tmp/pgss-upload

    if [[ -d "${RESULT_ROOT:-}" ]]; then
      tar -C "$(dirname "$RESULT_ROOT")" -czf "/tmp/pgss-upload/${RUN_ID}.results.tar.gz" "$(basename "$RESULT_ROOT")"
      aws s3 cp "/tmp/pgss-upload/${RUN_ID}.results.tar.gz" "$RESULT_S3_URI/${RUN_ID}.results.tar.gz" && uploaded=1
    fi

    cp /var/log/pgss-benchmark.log "/tmp/pgss-upload/${RUN_ID}.cloud-init.log"
    aws s3 cp "/tmp/pgss-upload/${RUN_ID}.cloud-init.log" "$RESULT_S3_URI/${RUN_ID}.cloud-init.log" || true
  fi

  if [[ "${AUTO_SHUTDOWN:-none}" != none ]]; then
    if [[ "$status" == "0" && "$uploaded" == "1" ]]; then
      echo "benchmark succeeded and uploaded; shutting down to $AUTO_SHUTDOWN"
      shutdown -h now
    elif [[ "${SHUTDOWN_ON_FAILURE:-0}" == "1" ]]; then
      echo "benchmark failed but SHUTDOWN_ON_FAILURE=1; shutting down to $AUTO_SHUTDOWN"
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

# A reused instance, see REUSE_INSTANCE_ID, was set up by its first run.
SETUP_DONE=/var/lib/pgss-benchmark-setup-done
if [[ -e "$SETUP_DONE" ]]; then
  echo "reusing instance set up at $(cat "$SETUP_DONE")"
else
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
fi

runuser -l ec2-user -c "mkdir -p '$WORK_ROOT' '$PREFIX'"

# Stop a server left by an interrupted run.
for pid_file in "$PREFIX"/pgdata/*/postmaster.pid; do
  [[ -e "$pid_file" ]] || continue
  pgdata="$(dirname "$pid_file")"
  for pg_ctl in "$PREFIX"/pghome/*/bin/pg_ctl; do
    runuser -l ec2-user -c "'$pg_ctl' -D '$pgdata' stop -m fast" && break
  done
done

runuser -l ec2-user -c "
  set -Eeuo pipefail
  cd '$WORK_ROOT'
  if [[ ! -d postgres ]]; then
    git clone '$PG_REMOTE' postgres
    git -C postgres remote add samimseih '$PATCH_REMOTE'
  fi
  cd postgres
  git fetch origin '+$BASE_REF:refs/remotes/origin/$BASE_REF'
  git fetch samimseih '+$PATCH_REF:refs/remotes/samimseih/$PATCH_REF'
  # The commits to benchmark may be on no fetched branch
  if [[ -n '${PATCH_COMMIT:-}' ]] && ! git cat-file -e '${PATCH_COMMIT:-}^{commit}' 2>/dev/null; then
    git fetch samimseih '${PATCH_COMMIT:-}'
  fi
  if [[ -n '${BASE_COMMIT:-}' ]] && ! git cat-file -e '${BASE_COMMIT:-}^{commit}' 2>/dev/null; then
    git fetch origin '${BASE_COMMIT:-}'
  fi
  if [[ '$BUILD_ROLE' != consumer && ! -d build-release ]]; then
    meson setup build-release \
      --prefix='$PREFIX/pghome/dev' \
      --buildtype=release \
      -Db_ndebug=true \
      -Dcassert=false
  fi
  cd '$WORK_ROOT'
  if [[ -d pg_stat_statements_benchmark ]]; then
    git -C pg_stat_statements_benchmark fetch origin
    git -C pg_stat_statements_benchmark reset --hard origin/HEAD
  else
    git clone '$BENCHMARK_REPO' pg_stat_statements_benchmark
  fi
"
date -u +%Y-%m-%dT%H:%M:%SZ >"$SETUP_DONE"

COMMITS="${PATCH_COMMIT:-samimseih/$PATCH_REF} ${BASE_COMMIT:-origin/$BASE_REF}"
SUITE_BUILD_MODE=worktree

# Whether all commits are installed already, by an earlier run.
commits_installed() {
  local commit short

  for commit in $COMMITS; do
    short="$(runuser -l ec2-user -c "git -C '$WORK_ROOT/postgres' rev-parse --short=12 '$commit^{commit}'")" ||
      return 1
    [[ -x "$PREFIX/pghome/dev-$short/bin/postgres" ]] || return 1
  done
}

# With BUILD_ROLE=builder, build the commits once and ship them to the other
# instances of the fleet through BUILD_SHIP_URI; with BUILD_ROLE=consumer,
# wait for them there instead of building.
if [[ "$BUILD_ROLE" == builder ]] && commits_installed; then
  echo "commits already installed; shipping them without building"
  runuser -l ec2-user -c "tar -C '$PREFIX/pghome' -czf /tmp/pgss-builds.tar.gz \$(cd '$PREFIX/pghome' && ls -d dev-*)"
  aws s3 cp /tmp/pgss-builds.tar.gz "$BUILD_SHIP_URI"
  SUITE_BUILD_MODE=prebuilt
elif [[ "$BUILD_ROLE" == builder ]]; then
  runuser -l ec2-user -c "
    set -Eeuo pipefail
    cd '$WORK_ROOT/pg_stat_statements_benchmark'
    env \
      PG_WORKTREE='$WORK_ROOT/postgres' \
      BUILD_MODE=worktree \
      BUILD_ONLY=1 \
      RUN_ORDER=interleaved \
      PREFIX='$PREFIX' \
      WORKTREE_NAME=dev \
      BUILD_DIR='$WORK_ROOT/postgres/build-release' \
      COMMITS='$COMMITS' \
      RESULT_ROOT='$RESULT_ROOT' \
      ./run_pgss_benchmark_suite.sh
    tar -C '$PREFIX/pghome' -czf /tmp/pgss-builds.tar.gz \$(cd '$PREFIX/pghome' && ls -d dev-*)
  "
  aws s3 cp /tmp/pgss-builds.tar.gz "$BUILD_SHIP_URI"
  SUITE_BUILD_MODE=prebuilt
elif [[ "$BUILD_ROLE" == consumer ]] && commits_installed; then
  echo "commits already installed"
  SUITE_BUILD_MODE=prebuilt
elif [[ "$BUILD_ROLE" == consumer ]]; then
  echo "waiting up to $BUILD_WAIT_MINUTES minutes for $BUILD_SHIP_URI"
  for ((i = 0; i < BUILD_WAIT_MINUTES * 2; i++)); do
    aws s3 cp "$BUILD_SHIP_URI" /tmp/pgss-builds.tar.gz >/dev/null 2>&1 && break
    sleep 30
  done
  [[ -s /tmp/pgss-builds.tar.gz ]] || { echo "builds not shipped in time"; exit 1; }
  runuser -l ec2-user -c "mkdir -p '$PREFIX/pghome' && tar -C '$PREFIX/pghome' -xzf /tmp/pgss-builds.tar.gz"
  SUITE_BUILD_MODE=prebuilt
fi

runuser -l ec2-user -c "
  set -Eeuo pipefail
  cd '$WORK_ROOT/pg_stat_statements_benchmark'
  env \
    PG_WORKTREE='$WORK_ROOT/postgres' \
    BUILD_MODE='$SUITE_BUILD_MODE' \
    PREFIX='$PREFIX' \
    WORKTREE_NAME=dev \
    BUILD_DIR='$WORK_ROOT/postgres/build-release' \
    COMMITS='$COMMITS' \
    CLIENTS='$CLIENTS' \
    SELECT_CLIENTS='$SELECT_CLIENTS' \
    HOTCOLD_SECONDS='$HOTCOLD_SECONDS' \
    SELECT_SECONDS='$SELECT_SECONDS' \
    RUN_HOTCOLD_4000_100M='$RUN_HOTCOLD_4000_100M' \
    RUN_HOTCOLD_4000_1500='$RUN_HOTCOLD_4000_1500' \
    RUN_SELECT_ONLY='$RUN_SELECT_ONLY' \
    RUN_ORDER='$RUN_ORDER' \
    CLIENT_ORDER='$CLIENT_ORDER' \
    PGSS_SAMPLE_SECONDS='$PGSS_SAMPLE_SECONDS' \
    PGSS_SAMPLE_START_DELAY_SECONDS='$PGSS_SAMPLE_START_DELAY_SECONDS' \
    PROGRESS_SECONDS='$PROGRESS_SECONDS' \
    SELECT_SCALE='$SELECT_SCALE' \
    PGSS_MAX='$PGSS_MAX' \
    PGSS_QUERY_TEXT_MEMORY='$PGSS_QUERY_TEXT_MEMORY' \
    MAX_CONNECTIONS='$MAX_CONNECTIONS' \
    RESULT_ROOT='$RESULT_ROOT' \
    ./run_pgss_benchmark_suite.sh
"
