#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
load_latest_state

CONNECT_USER="${CONNECT_USER:-ec2-user}"

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: session-manager-plugin is not on PATH.

Install the AWS Session Manager plugin, or use aws ssm send-command for
non-interactive checks.
EOF
  exit 1
fi

if [[ "$CONNECT_USER" == "ssm-user" ]]; then
  aws_cmd ssm start-session --target "$INSTANCE_ID"
else
  if [[ ! "$CONNECT_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    die "invalid CONNECT_USER: $CONNECT_USER"
  fi

  aws_cmd ssm start-session \
    --target "$INSTANCE_ID" \
    --document-name AWS-StartInteractiveCommand \
    --parameters "{\"command\":[\"sudo -iu $CONNECT_USER\"]}"
fi
