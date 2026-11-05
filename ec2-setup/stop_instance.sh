#!/usr/bin/env bash
#
# Stop a benchmark instance, keeping it for later runs with
# REUSE_INSTANCE_ID or REUSE_FLEET_ID.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
load_latest_state "${1:-}"

aws_cmd ec2 stop-instances --instance-ids "$INSTANCE_ID" --output table
