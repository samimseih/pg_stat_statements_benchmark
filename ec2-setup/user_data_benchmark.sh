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

  if [[ "${AUTO_TERMINATE:-0}" == "1" ]]; then
    if [[ "$status" == "0" && "$uploaded" == "1" ]]; then
      echo "benchmark succeeded and uploaded; shutting down for termination"
      shutdown -h now
    elif [[ "${TERMINATE_ON_FAILURE:-0}" == "1" ]]; then
      echo "benchmark failed but TERMINATE_ON_FAILURE=1; shutting down for termination"
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

runuser -l ec2-user -c "mkdir -p '$WORK_ROOT' '$PREFIX'"

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

runuser -l ec2-user -c "
  set -Eeuo pipefail
  cd '$WORK_ROOT/pg_stat_statements_benchmark'
  env \
    PG_WORKTREE='$WORK_ROOT/postgres' \
    PREFIX='$PREFIX' \
    WORKTREE_NAME=dev \
    BUILD_DIR='$WORK_ROOT/postgres/build-release' \
    COMMITS='${PATCH_COMMIT:-samimseih/$PATCH_REF} origin/$BASE_REF' \
    CLIENTS='$CLIENTS' \
    SELECT_CLIENTS='$SELECT_CLIENTS' \
    HOTCOLD_SECONDS='$HOTCOLD_SECONDS' \
    SELECT_SECONDS='$SELECT_SECONDS' \
    RUN_HOTCOLD_4000_100M='$RUN_HOTCOLD_4000_100M' \
    RUN_HOTCOLD_4000_1500='$RUN_HOTCOLD_4000_1500' \
    RUN_SELECT_ONLY='$RUN_SELECT_ONLY' \
    RUN_ORDER='$RUN_ORDER' \
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
