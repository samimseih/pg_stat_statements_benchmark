#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/state}"

die() {
  echo "error: $*" >&2
  exit 1
}

load_config() {
  [[ -f "$SCRIPT_DIR/aws.config" ]] || die "missing $SCRIPT_DIR/aws.config"

  set -a
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/aws.config"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/benchmark.config"
  set +a

  [[ -n "${AWS_ACCOUNT_ID:-}" ]] || die "AWS_ACCOUNT_ID is not set"
  [[ -n "${AWS_REGION:-}" ]] || die "AWS_REGION is not set"
  mkdir -p "$STATE_DIR"
}

aws_cmd() {
  local args=(--region "$AWS_REGION")

  if [[ -n "${AWS_PROFILE:-}" ]]; then
    args+=(--profile "$AWS_PROFILE")
  fi

  aws "${args[@]}" "$@"
}

check_aws_identity() {
  local account

  account="$(aws_cmd sts get-caller-identity --query Account --output text)"
  [[ "$account" == "$AWS_ACCOUNT_ID" ]] || \
    die "authenticated to account $account, expected AWS_ACCOUNT_ID from aws.config"
}

write_latest_state() {
  local run_id="$1" instance_id="$2" result_s3_uri="$3"

  cat >"$STATE_DIR/$run_id.state.env" <<EOF
RUN_ID=$run_id
INSTANCE_ID=$instance_id
RESULT_S3_URI=$result_s3_uri
AWS_REGION=$AWS_REGION
EOF

  cp "$STATE_DIR/$run_id.state.env" "$STATE_DIR/latest.env"
}

load_latest_state() {
  local run_id="${1:-}"
  local state_file

  if [[ -n "$run_id" ]]; then
    state_file="$STATE_DIR/$run_id.state.env"
  else
    state_file="$STATE_DIR/latest.env"
  fi

  [[ -f "$state_file" ]] || die "missing $state_file"
  # shellcheck source=/dev/null
  . "$state_file"
}
