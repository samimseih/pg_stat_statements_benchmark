#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
load_latest_state

aws_cmd ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{InstanceId:InstanceId,State:State.Name,Type:InstanceType,LaunchTime:LaunchTime,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress}' \
  --output table

echo
aws_cmd ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].{PingStatus:PingStatus,AgentVersion:AgentVersion,PlatformName:PlatformName,PlatformVersion:PlatformVersion}' \
  --output table || true

echo
echo "Results: $RESULT_S3_URI"
