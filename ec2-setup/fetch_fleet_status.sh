#!/usr/bin/env bash
#
# Fetch the current results of all instances of a fleet, running or done,
# into results/fleet/<fleet id>, for report_fleet.py.
#
# For each instance type, this saves summary.tsv and progress.tsv as
# <type>.summary.tsv and <type>.progress.tsv, from the instance through SSM
# and S3 while it runs, or from its results archive once done, and adds a
# row to instances.tsv: type, vCPUs, state, run id and commits.
#
# Usage:
#   ./fetch_fleet_status.sh <fleet id>
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

FLEET_ID="${1:-}"
[[ -n "$FLEET_ID" ]] || die "usage: $0 <fleet id>"

load_config
check_aws_identity

out="$SCRIPT_DIR/results/fleet/$FLEET_ID"
mkdir -p "$out"

# Copy the summary and progress of a running instance to S3 with SSM, and
# fetch them from there, because SSM truncates the output of commands.
fetch_running() {
  local instance_id="$1" run_id="$2" type="$3" uri params command_id root

  uri="s3://$RESULT_BUCKET/$RESULT_PREFIX/$run_id/live"
  root="/home/ec2-user/pgss-benchmark/results/$run_id"
  params="$(python3 -c 'import json, sys; print(json.dumps({"commands": [sys.argv[1]]}))' \
    "for f in summary.tsv progress.tsv; do [ -f $root/\$f ] && aws s3 cp --only-show-errors $root/\$f $uri/\$f; done; true")"
  command_id="$(aws_cmd ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "$params" \
    --query Command.CommandId --output text)"
  aws_cmd ssm wait command-executed --command-id "$command_id" --instance-id "$instance_id" ||
    echo "warning: could not copy the results of $type" >&2
  aws_cmd s3 cp --only-show-errors "$uri/summary.tsv" "$out/$type.summary.tsv" ||
    : >"$out/$type.summary.tsv"
  aws_cmd s3 cp --only-show-errors "$uri/progress.tsv" "$out/$type.progress.tsv" ||
    : >"$out/$type.progress.tsv"
}

# Fetch the summary and progress of a finished run from its results archive.
fetch_done() {
  local run_id="$1" type="$2" archive tmp

  archive="s3://$RESULT_BUCKET/$RESULT_PREFIX/$run_id/$run_id.results.tar.gz"
  tmp="$(mktemp -d)"
  # The archive does not exist until the run is done.
  aws_cmd s3 cp --only-show-errors "$archive" "$tmp/results.tar.gz" 2>/dev/null || {
    rm -rf "$tmp"
    return 1
  }
  tar -xzf "$tmp/results.tar.gz" -C "$tmp" "$run_id/summary.tsv" "$run_id/progress.tsv" \
    2>/dev/null || tar -xzf "$tmp/results.tar.gz" -C "$tmp" "$run_id/summary.tsv"
  cp "$tmp/$run_id/summary.tsv" "$out/$type.summary.tsv"
  if [[ -f "$tmp/$run_id/progress.tsv" ]]; then
    cp "$tmp/$run_id/progress.tsv" "$out/$type.progress.tsv"
  else
    : >"$out/$type.progress.tsv"
  fi
  rm -rf "$tmp"
}

printf 'type\tvcpus\tstate\trun_id\tpatch_commit\tbase_commit\tworkloads\tclients\tselect_clients\n' \
  >"$out/instances.tsv.new"

for env_file in "$STATE_DIR/$FLEET_ID"-*.env; do
  [[ -f "$env_file" && "$env_file" != *.state.env ]] || continue
  (
    set -a
    # shellcheck source=/dev/null
    . "$env_file"
    set +a
    run_id="$RUN_ID"

    read -r instance_id state < <(aws_cmd ec2 describe-instances \
      --filters "Name=tag:RunId,Values=$run_id" \
      --query 'Reservations[0].Instances[0].[InstanceId, State.Name]' \
      --output text)
    # The instance type, from the run id: <fleet id>-c7i-large is c7i.large.
    type="$(echo "${run_id#"$FLEET_ID"-}" | sed 's/-/./')"
    # Without an instance, it was terminated or moved on to a later run.
    [[ -n "$instance_id" && "$instance_id" != None ]] || state=gone

    if fetch_done "$run_id" "$type"; then
      state=done
    elif [[ "$state" == running ]]; then
      fetch_running "$instance_id" "$run_id" "$type"
    else
      : >"$out/$type.summary.tsv"
      : >"$out/$type.progress.tsv"
    fi

    vcpus="$(aws_cmd ec2 describe-instance-types --instance-types "$type" \
      --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text)"
    workloads=""
    [[ "${RUN_HOTCOLD_4000_100M:-1}" == 1 ]] && workloads+="hotcold_4000_100m "
    [[ "${RUN_HOTCOLD_4000_1500:-1}" == 1 ]] && workloads+="hotcold_4000_1500 "
    [[ "${RUN_SELECT_ONLY:-1}" == 1 ]] && workloads+="select_only"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$type" "$vcpus" "$state" "$run_id" \
      "$PATCH_COMMIT" "$BASE_COMMIT" "$workloads" "$CLIENTS" "$SELECT_CLIENTS"
  ) >>"$out/instances.tsv.new"
done
mv "$out/instances.tsv.new" "$out/instances.tsv"

echo "$out"
