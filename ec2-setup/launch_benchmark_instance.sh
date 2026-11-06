#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

write_env_var() {
  local name="$1" value="$2"

  printf '%s=%q\n' "$name" "$value"
}

ensure_bucket() {
  if aws_cmd s3api head-bucket --bucket "$RESULT_BUCKET" >/dev/null 2>&1; then
    return
  fi

  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws_cmd s3api create-bucket --bucket "$RESULT_BUCKET" >/dev/null
  else
    aws_cmd s3api create-bucket \
      --bucket "$RESULT_BUCKET" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
}

ensure_instance_profile() {
  local assume_policy role_policy

  assume_policy="$STATE_DIR/assume-role.json"
  role_policy="$STATE_DIR/result-upload-policy.json"

  cat >"$assume_policy" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

  if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://$assume_policy" >/dev/null
  fi

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null || true

  cat >"$role_policy" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::$RESULT_BUCKET",
      "Condition": {"StringLike": {"s3:prefix": ["$RESULT_PREFIX/*"]}}
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::$RESULT_BUCKET/$RESULT_PREFIX/*"
    }
  ]
}
JSON

  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name pgss-benchmark-result-upload \
    --policy-document "file://$role_policy" >/dev/null

  if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
  fi

  if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
      --query "InstanceProfile.Roles[?RoleName=='$ROLE_NAME'].RoleName" \
      --output text | grep -qx "$ROLE_NAME"; then
    aws iam add-role-to-instance-profile \
      --instance-profile-name "$INSTANCE_PROFILE_NAME" \
      --role-name "$ROLE_NAME" >/dev/null
    sleep 15
  fi
}

default_vpc_id() {
  aws_cmd ec2 describe-vpcs \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text
}

route_table_has_egress() {
  local route_table_id="$1" targets

  targets="$(aws_cmd ec2 describe-route-tables \
    --route-table-ids "$route_table_id" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && State=='active'].GatewayId" \
    --output text)"

  [[ "$targets" == *igw-* || "$targets" == *nat-* ]]
}

default_subnet_id() {
  local vpc_id="$1"
  local subnet route_tables main_route_table

  main_route_table="$(aws_cmd ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' \
    --output text)"

  for subnet in $(aws_cmd ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[].SubnetId' \
    --output text); do
    route_tables="$(aws_cmd ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=association.subnet-id,Values=$subnet" \
      --query 'RouteTables[].RouteTableId' \
      --output text)"

    if [[ -z "$route_tables" || "$route_tables" == "None" ]]; then
      route_tables="$main_route_table"
    fi

    for route_table in $route_tables; do
      if route_table_has_egress "$route_table"; then
        echo "$subnet"
        return
      fi
    done
  done
}

ensure_security_group() {
  local vpc_id="$1" group_id

  group_id="$(aws_cmd ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)"

  if [[ -z "$group_id" || "$group_id" == "None" ]]; then
    group_id="$(aws_cmd ec2 create-security-group \
      --vpc-id "$vpc_id" \
      --group-name "$SECURITY_GROUP_NAME" \
      --description "pg_stat_statements benchmark SSM-only access" \
      --query GroupId \
      --output text)"
  fi

  echo "$group_id"
}

render_user_data() {
  local run_id="$1" result_s3_uri="$2" env_file user_data

  env_file="$STATE_DIR/$run_id.env"
  user_data="$STATE_DIR/$run_id.user-data.sh"

  {
    write_env_var RUN_ID "$run_id"
    write_env_var WORK_ROOT /home/ec2-user/pgss-benchmark
    write_env_var PREFIX /home/ec2-user/pgdev/installations
    write_env_var RESULT_ROOT "/home/ec2-user/pgss-benchmark/results/$run_id"
    write_env_var RESULT_S3_URI "$result_s3_uri"
    write_env_var AUTO_SHUTDOWN "$AUTO_SHUTDOWN"
    write_env_var SHUTDOWN_ON_FAILURE "$SHUTDOWN_ON_FAILURE"
    write_env_var PG_REMOTE "$PG_REMOTE"
    write_env_var PATCH_REMOTE "$PATCH_REMOTE"
    write_env_var PATCH_REF "$PATCH_REF"
    write_env_var PATCH_COMMIT "$PATCH_COMMIT"
    write_env_var BASE_REF "$BASE_REF"
    write_env_var BASE_COMMIT "${BASE_COMMIT:-}"
    write_env_var BUILD_ROLE "${BUILD_ROLE:-}"
    write_env_var BUILD_SHIP_URI "${BUILD_SHIP_URI:-}"
    write_env_var BUILD_WAIT_MINUTES "${BUILD_WAIT_MINUTES:-120}"
    write_env_var BENCHMARK_REPO "$BENCHMARK_REPO"
    write_env_var CLIENTS "$CLIENTS"
    write_env_var SELECT_CLIENTS "$SELECT_CLIENTS"
    write_env_var HOTCOLD_100M_CLIENTS "$HOTCOLD_100M_CLIENTS"
    write_env_var HOTCOLD_1500_CLIENTS "$HOTCOLD_1500_CLIENTS"
    write_env_var HOTCOLD_SECONDS "$HOTCOLD_SECONDS"
    write_env_var SELECT_SECONDS "$SELECT_SECONDS"
    write_env_var RUN_HOTCOLD_4000_100M "$RUN_HOTCOLD_4000_100M"
    write_env_var RUN_HOTCOLD_4000_1500 "$RUN_HOTCOLD_4000_1500"
    write_env_var RUN_SELECT_ONLY "$RUN_SELECT_ONLY"
    write_env_var RUN_ORDER "$RUN_ORDER"
    write_env_var CLIENT_ORDER "$CLIENT_ORDER"
    write_env_var PGSS_SAMPLE_SECONDS "$PGSS_SAMPLE_SECONDS"
    write_env_var PGSS_SAMPLE_START_DELAY_SECONDS "$PGSS_SAMPLE_START_DELAY_SECONDS"
    write_env_var PROGRESS_SECONDS "$PROGRESS_SECONDS"
    write_env_var SELECT_SCALE "$SELECT_SCALE"
    write_env_var PGSS_MAX "$PGSS_MAX"
    write_env_var PGSS_QUERY_TEXT_MEMORY "$PGSS_QUERY_TEXT_MEMORY"
    write_env_var MAX_CONNECTIONS "$MAX_CONNECTIONS"
    write_env_var PROFILE_COMMITS "$PROFILE_COMMITS"
    write_env_var PROFILE_CLIENTS "$PROFILE_CLIENTS"
    write_env_var PROFILE_SECONDS "$PROFILE_SECONDS"
    write_env_var PROFILE_WARMUP_SECONDS "$PROFILE_WARMUP_SECONDS"
    write_env_var PROFILE_RECORD_SECONDS "$PROFILE_RECORD_SECONDS"
    write_env_var PROFILE_WORKLOAD "${PROFILE_WORKLOAD:-hotcold_4000_100m}"
  } >"$env_file"

  user_data_template="${USER_DATA_TEMPLATE:-$SCRIPT_DIR/user_data_benchmark.sh}"
  sed "/__PGSS_BENCHMARK_ENV__/{
    r $env_file
    d
  }" "$user_data_template" >"$user_data"

  echo "$user_data"
}

wait_ssm_online() {
  local instance_id="$1" i ping

  for ((i = 0; i < 60; i++)); do
    ping="$(aws_cmd ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
    [[ "$ping" == Online ]] && return
    sleep 10
  done
  die "$instance_id is not online in SSM"
}

# Run a shell command on an instance with SSM, and print its output.
ssm_run() {
  local instance_id="$1" command="$2" command_id params

  params="$(python3 -c 'import json, sys; print(json.dumps({"commands": [sys.argv[1]]}))' "$command")"
  command_id="$(aws_cmd ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "$params" \
    --query Command.CommandId --output text)"
  aws_cmd ssm wait command-executed --command-id "$command_id" --instance-id "$instance_id" || true
  aws_cmd ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
}

# Run the benchmark of run_id on an existing instance, started if stopped,
# instead of launching one.  The bootstrap skips the setup done by an
# earlier run, and the builds installed by it.
reuse_instance() {
  local instance_id="$1" run_id="$2" result_s3_uri="$3" user_data="$4"
  local state type output volumes

  read -r state type < <(aws_cmd ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].[State.Name, InstanceType]' --output text)
  [[ -z "${INSTANCE_TYPE:-}" || "$type" == "$INSTANCE_TYPE" ]] ||
    die "$instance_id is a $type, not a $INSTANCE_TYPE"

  if [[ "$state" == stopping ]]; then
    aws_cmd ec2 wait instance-stopped --instance-ids "$instance_id"
    state=stopped
  fi
  aws_cmd ec2 modify-instance-attribute --instance-id "$instance_id" \
    --instance-initiated-shutdown-behavior "Value=$(shutdown_behavior)"
  case "$state" in
    stopped)
      aws_cmd ec2 start-instances --instance-ids "$instance_id" >/dev/null
      aws_cmd ec2 wait instance-running --instance-ids "$instance_id"
      ;;
    running)
      ;;
    *)
      die "$instance_id is $state"
      ;;
  esac
  wait_ssm_online "$instance_id"

  output="$(ssm_run "$instance_id" \
    "pgrep -f run_pgss_benchmark_suite.sh >/dev/null && echo busy || echo idle")"
  [[ "$output" == *idle* ]] || die "$instance_id is still running a benchmark"

  volumes="$(aws_cmd ec2 describe-volumes \
    --filters "Name=attachment.instance-id,Values=$instance_id" \
    --query 'Volumes[].VolumeId' --output text)"
  # shellcheck disable=SC2086
  aws_cmd ec2 create-tags --resources "$instance_id" $volumes \
    --tags "Key=RunId,Value=$run_id"

  aws_cmd s3 cp --only-show-errors "$user_data" "$result_s3_uri/user-data.sh"
  output="$(ssm_run "$instance_id" \
    "aws s3 cp --only-show-errors '$result_s3_uri/user-data.sh' /root/pgss-user-data.sh && systemd-run --unit 'pgss-benchmark-$run_id' --collect bash /root/pgss-user-data.sh")"
  [[ "$output" == Success* ]] || die "could not start the benchmark on $instance_id: $output"
}

main() {
  local run_id ami_id vpc_id subnet_id security_group_id result_s3_uri user_data
  local instance_id network_json block_device_json

  load_config
  check_aws_identity

  run_id="${RUN_ID:-$(date -u +pgss-%Y%m%dT%H%M%SZ)}"
  result_s3_uri="s3://$RESULT_BUCKET/$RESULT_PREFIX/$run_id"

  ensure_bucket
  ensure_instance_profile

  ami_id="${AMI_ID:-$(aws_cmd ssm get-parameter \
    --name "$AMI_SSM_PARAMETER" \
    --query Parameter.Value \
    --output text)}"

  vpc_id="${VPC_ID:-$(default_vpc_id)}"
  [[ -n "$vpc_id" && "$vpc_id" != "None" ]] || die "no VPC_ID set and no default VPC found"

  subnet_id="${SUBNET_ID:-$(default_subnet_id "$vpc_id")}"
  [[ -n "$subnet_id" && "$subnet_id" != "None" ]] || die "no SUBNET_ID set and no subnet found in $vpc_id"

  security_group_id="${SECURITY_GROUP_ID:-$(ensure_security_group "$vpc_id")}"
  user_data="$(render_user_data "$run_id" "$result_s3_uri")"

  network_json="[{\"DeviceIndex\":0,\"SubnetId\":\"$subnet_id\",\"Groups\":[\"$security_group_id\"],\"AssociatePublicIpAddress\":$ASSOCIATE_PUBLIC_IP}]"
  block_device_json="[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE_GB,\"VolumeType\":\"$VOLUME_TYPE\",\"Iops\":$VOLUME_IOPS,\"Throughput\":$VOLUME_THROUGHPUT,\"DeleteOnTermination\":true}}]"

  if [[ -n "${REUSE_INSTANCE_ID:-}" ]]; then
    instance_id="$REUSE_INSTANCE_ID"
    reuse_instance "$instance_id" "$run_id" "$result_s3_uri" "$user_data"
  else
    instance_id="$(aws_cmd ec2 run-instances \
      --image-id "$ami_id" \
      --instance-type "$INSTANCE_TYPE" \
      --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" \
      --instance-initiated-shutdown-behavior "$(shutdown_behavior)" \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --network-interfaces "$network_json" \
      --block-device-mappings "$block_device_json" \
      --user-data "file://$user_data" \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=pgss-benchmark},{Key=RunId,Value=$run_id},{Key=Project,Value=pg_stat_statements_benchmark}]" \
        "ResourceType=volume,Tags=[{Key=Name,Value=pgss-benchmark},{Key=RunId,Value=$run_id},{Key=Project,Value=pg_stat_statements_benchmark}]" \
      --query 'Instances[0].InstanceId' \
      --output text)"
  fi

  write_latest_state "$run_id" "$instance_id" "$result_s3_uri"

  cat <<EOF
Started pg_stat_statements benchmark.

Run ID: $run_id
Instance ID: $instance_id
Instance type: $INSTANCE_TYPE
Region: $AWS_REGION
Results: $result_s3_uri

Check status:
  $SCRIPT_DIR/live_status.sh $run_id

Fetch results after completion:
  $SCRIPT_DIR/fetch_results.sh $run_id
EOF
}

main "$@"
