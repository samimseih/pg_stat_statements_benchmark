#!/usr/bin/env bash
#
# Fetch the current results of all instances of a fleet, running or done,
# into results/fleet/<fleet id>, for report_datapoints.py.
#
# For each instance type, this saves summary.tsv and progress.tsv as
# <type>.summary.tsv and <type>.progress.tsv, from the instance through SSM
# and S3 while it runs, or from its results archive once done, and adds a
# row to instances.tsv: type, vCPUs, state, run id and commits.  It also
# saves <type>.kind.tsv, the entries allocated by the stats kind of each
# point, see summarize_kind.sh.
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
  local instance_id="$1" run_id="$2" type="$3" uri params command_id root kind_script age_script trickle_script

  uri="s3://$RESULT_BUCKET/$RESULT_PREFIX/$run_id/live"
  root="/home/ec2-user/pgss-benchmark/results/$run_id"
  kind_script="$(base64 -w0 "$SCRIPT_DIR/summarize_kind.sh")"
  age_script="$(base64 -w0 "$SCRIPT_DIR/summarize_age.sh")"
  trickle_script="$(base64 -w0 "$SCRIPT_DIR/summarize_trickle.sh")"
  params="$(python3 -c 'import json, sys; print(json.dumps({"commands": [sys.argv[1]]}))' \
    "echo $kind_script | base64 -d >/tmp/summarize_kind.sh; bash /tmp/summarize_kind.sh $root >$root/kind.tsv; echo $age_script | base64 -d >/tmp/summarize_age.sh; bash /tmp/summarize_age.sh $root >$root/age.tsv; echo $trickle_script | base64 -d >/tmp/summarize_trickle.sh; bash /tmp/summarize_trickle.sh $root >$root/trickle.tsv; for f in summary.tsv progress.tsv kind.tsv age.tsv trickle.tsv; do [ -f $root/\$f ] && aws s3 cp --only-show-errors $root/\$f $uri/\$f; done; true")"
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
  aws_cmd s3 cp --only-show-errors "$uri/kind.tsv" "$out/$type.kind.tsv" ||
    : >"$out/$type.kind.tsv"
  aws_cmd s3 cp --only-show-errors "$uri/age.tsv" "$out/$type.age.tsv" ||
    : >"$out/$type.age.tsv"
  aws_cmd s3 cp --only-show-errors "$uri/trickle.tsv" "$out/$type.trickle.tsv" ||
    : >"$out/$type.trickle.tsv"
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
  tar -xzf "$tmp/results.tar.gz" -C "$tmp" --wildcards "$run_id/*/monitor_kind.tsv" "$run_id/*/monitor_age.tsv" "$run_id/*/monitor_trickle.tsv" 2>/dev/null
  bash "$SCRIPT_DIR/summarize_kind.sh" "$tmp/$run_id" >"$out/$type.kind.tsv"
  bash "$SCRIPT_DIR/summarize_age.sh" "$tmp/$run_id" >"$out/$type.age.tsv"
  bash "$SCRIPT_DIR/summarize_trickle.sh" "$tmp/$run_id" >"$out/$type.trickle.tsv"
  rm -rf "$tmp"
}

printf 'type\tvcpus\tstate\trun_id\tpatch_commit\tbase_commit\tworkloads\tclients\tselect_clients\thotcold_100m_clients\thotcold_1500_clients\textra_commits\n' \
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
      # Keep what an earlier fetch got from an instance terminated since
      for f in summary progress kind age trickle; do
        [[ -f "$out/$type.$f.tsv" ]] || : >"$out/$type.$f.tsv"
      done
    fi

    vcpus="$(aws_cmd ec2 describe-instance-types --instance-types "$type" \
      --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text)"
    workloads=""
    [[ "${RUN_HOTCOLD_4000_100M:-1}" == 1 ]] && workloads+="hotcold_4000_100m "
    [[ "${RUN_HOTCOLD_4000_1500:-1}" == 1 ]] && workloads+="hotcold_4000_1500 "
    [[ "${RUN_SELECT_ONLY:-1}" == 1 ]] && workloads+="select_only "
    [[ "${RUN_TRICKLE_5000:-0}" == 1 ]] && workloads+="trickle_5000"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$type" "$vcpus" "$state" "$run_id" \
      "$PATCH_COMMIT" "$BASE_COMMIT" "$workloads" "$CLIENTS" "$SELECT_CLIENTS" \
      "${HOTCOLD_100M_CLIENTS:-$CLIENTS}" "${HOTCOLD_1500_CLIENTS:-$CLIENTS}" "${EXTRA_COMMITS:-}"
  ) >>"$out/instances.tsv.new"
done
mv "$out/instances.tsv.new" "$out/instances.tsv"

echo "$out"
