#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
load_latest_state "${1:-}"

PG_PROGRESS_LINES="${PG_PROGRESS_LINES:-80}"
REMOTE_RESULT_ROOT="/home/ec2-user/pgss-benchmark/results/$RUN_ID"

commands_file="$(mktemp)"
trap 'rm -f "$commands_file"' EXIT

cat >"$commands_file" <<JSON
{
  "commands": [
    "set -eu",
    "root='$REMOTE_RESULT_ROOT'",
    "lines='$PG_PROGRESS_LINES'",
    "if ! [[ \"\$lines\" =~ ^[0-9]+\$ ]]; then lines=80; fi",
    "file=\$(find \"\$root\" -path '*/pgbench.log' -type f -printf '%T@ %p\\\\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)",
    "if [ -z \"\$file\" ]; then echo 'no pgbench.log yet'; exit 0; fi",
    "echo \"Run:  $RUN_ID\"",
    "echo \"File: \$file\"",
    "echo",
    "tail -n \"\$lines\" \"\$file\""
  ]
}
JSON

cmd_id="$(aws_cmd ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "file://$commands_file" \
  --query 'Command.CommandId' \
  --output text)"

aws_cmd ssm wait command-executed \
  --command-id "$cmd_id" \
  --instance-id "$INSTANCE_ID" || true

aws_cmd ssm get-command-invocation \
  --command-id "$cmd_id" \
  --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' \
  --output text
