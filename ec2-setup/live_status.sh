#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
load_latest_state "${1:-}"

run_env="$STATE_DIR/$RUN_ID.env"
if [[ -f "$run_env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$run_env"
  set +a
fi

count_words() {
  local value="${1:-}"

  if [[ -z "$value" ]]; then
    echo 0
    return
  fi

  # shellcheck disable=SC2086
  set -- $value
  echo "$#"
}

commit_count="${COMMIT_COUNT:-2}"
expected_points=0
if [[ "${RUN_HOTCOLD_4000_100M:-0}" == "1" ]]; then
  expected_points=$((expected_points + commit_count * $(count_words "${CLIENTS:-}")))
fi
if [[ "${RUN_HOTCOLD_4000_1500:-0}" == "1" ]]; then
  expected_points=$((expected_points + commit_count * $(count_words "${CLIENTS:-}")))
fi
if [[ "${RUN_SELECT_ONLY:-0}" == "1" ]]; then
  expected_points=$((expected_points + commit_count * $(count_words "${SELECT_CLIENTS:-}")))
fi

summary="/home/ec2-user/pgss-benchmark/results/$RUN_ID/summary.tsv"
log_file="/var/log/pgss-benchmark.log"

instance_info="$(aws_cmd ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,InstanceType,LaunchTime,PrivateIpAddress,PublicIpAddress]' \
  --output text)"
read -r state instance_type launch_time private_ip public_ip <<<"$instance_info"

echo "Run:        $RUN_ID"
echo "Instance:   $INSTANCE_ID ($instance_type, $state)"
echo "Started:    $launch_time"
echo "Address:    private=$private_ip public=$public_ip"
echo "Results:    $RESULT_S3_URI"

if [[ "$state" != "running" ]]; then
  echo
  echo "Instance is $state. Use ./fetch_results.sh and ./analyze_results.sh after the final tarball is uploaded."
  exit 0
fi

echo
commands_file="$(mktemp)"
trap 'rm -f "$commands_file"' EXIT
cat >"$commands_file" <<JSON
{
  "commands": [
    "summary='$summary'",
    "log_file='$log_file'",
    "repo='/home/ec2-user/pgss-benchmark/postgres'",
    "patch_ref='${PATCH_COMMIT:-samimseih/${PATCH_REF:-pg_stat_statements_v14}}'",
    "base_ref='origin/${BASE_REF:-master}'",
    "expected_points='$expected_points'",
    "verbose='${LIVE_VERBOSE:-0}'",
    "patch_commit=\$(git -c safe.directory=\"\$repo\" -C \"\$repo\" rev-parse --short=12 \"\$patch_ref\" 2>/dev/null || true)",
    "base_commit=\$(git -c safe.directory=\"\$repo\" -C \"\$repo\" rev-parse --short=12 \"\$base_ref\" 2>/dev/null || true)",
    "patch_title=\$(git -c safe.directory=\"\$repo\" -C \"\$repo\" log -1 --format=%s \"\$patch_ref\" 2>/dev/null || true)",
    "base_title=\$(git -c safe.directory=\"\$repo\" -C \"\$repo\" log -1 --format=%s \"\$base_ref\" 2>/dev/null || true)",
    "current=\$(grep '^==>' \"\$log_file\" 2>/dev/null | tail -1 | sed 's/^==> //')",
    "current_commit=\${current%% *}",
    "current_label=''",
    "if [ -n \"\$current_commit\" ] && [ \"\$current_commit\" = \"\$patch_commit\" ]; then current_label='patch'; elif [ -n \"\$current_commit\" ] && [ \"\$current_commit\" = \"\$base_commit\" ]; then current_label='upstream'; fi",
    "if [ -n \"\$current_label\" ]; then current=\"\$current_label \$current\"; fi",
    "if [ -s \"\$summary\" ]; then rows=\$(wc -l < \"\$summary\"); rows=\$((rows - 1)); if [ \"\$rows\" -lt 0 ]; then rows=0; fi; failed=\$(awk -F '\\\\t' 'NR > 1 && (\$6 != 0 || \$9 != 0) { failed++ } END { print failed+0 }' \"\$summary\"); else rows=0; failed=0; fi",
    "echo \"Progress:   \$rows/\$expected_points benchmark points complete\"",
    "echo \"Current:    \${current:-starting or between commands}\"",
    "echo \"Failures:   \$failed\"",
    "echo \"Builds:\"",
    "if [ -n \"\$patch_commit\" ]; then printf '  %-9s %s  %s\\\\n' 'patch:' \"\$patch_commit\" \"\$patch_title\"; fi",
    "if [ -n \"\$base_commit\" ]; then printf '  %-9s %s  %s\\\\n' 'upstream:' \"\$base_commit\" \"\$base_title\"; fi",
    "echo",
    "echo 'Completed points:'",
    "if [ -s \"\$summary\" ] && [ \"\$rows\" -gt 0 ]; then awk -F '\\\\t' -v patch=\"\$patch_commit\" -v base=\"\$base_commit\" 'function bytes(v, n, u, i) { if (v == \"\" || v == \"NA\") return \"n/a\"; n = v + 0; split(\"B KiB MiB GiB TiB\", u, \" \"); for (i = 1; n >= 1024 && i < 5; i++) n /= 1024; if (i == 1) return sprintf(\"%.0f %s\", n, u[i]); if (n < 10) return sprintf(\"%.1f %s\", n, u[i]); return sprintf(\"%.0f %s\", n, u[i]) } NR == 1 { for (i = 1; i <= NF; i++) col[\$i] = i; next } { commit = substr(\$col[\"commit\"], 1, 12); build = (commit == patch ? \"patch\" : (commit == base ? \"upstream\" : \"?\")); printf \"  %s %s c%s: %.0f TPS, status=%s failed=%s, avg_entries=%.0f, max_entries=%s, qtext_file_avg=%s, qtext_file_max=%s, qtext_file_final=%s\\\\n\", build, \$col[\"workload\"], \$col[\"clients\"], \$col[\"tps\"], \$col[\"status\"], \$col[\"failed\"], \$col[\"avg_entries\"], \$col[\"max_entries\"], bytes(\$col[\"avg_qtext_file_size\"]), bytes(\$col[\"max_qtext_file_size\"]), bytes(\$col[\"final_qtext_file_size\"]) }' \"\$summary\"; else echo '  no completed points yet'; fi",
    "if [ \"\$verbose\" = 1 ]; then echo; echo 'Active processes:'; pgrep -af 'meson|ninja|pgbench|run_pgss|git checkout' || true; echo; echo 'Benchmark log tail:'; tail -40 \"\$log_file\" || true; fi"
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
