#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
load_latest_state "${1:-}"

aws_cmd ec2 terminate-instances --instance-ids "$INSTANCE_ID" --output table
