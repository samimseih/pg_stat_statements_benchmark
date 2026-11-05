#!/usr/bin/env bash
#
# Launch the benchmark suite on several instance types in parallel, building
# PostgreSQL once.
#
# The largest instance type (by vCPUs), or BUILDER_INSTANCE_TYPE, builds the
# patch and base commits, uploads the installations to BUILD_SHIP_URI, then
# runs its own benchmark from them.  The other instances download them there
# instead of building, which is slow on small instances.  Both commits are
# resolved here, so that all instances benchmark exactly the same commits.
#
# With REUSE_FLEET_ID, the instances of that earlier fleet run the benchmark,
# started if they are stopped, instead of new instances.  They keep the setup
# and the builds of their earlier runs.
#
# Usage:
#   INSTANCE_TYPES="c7i.large c7i.24xlarge" ./launch_benchmark_fleet.sh
#   REUSE_FLEET_ID=pgss-fleet-... INSTANCE_TYPES="..." ./launch_benchmark_fleet.sh
#
# All other settings are the ones of launch_benchmark_instance.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
check_aws_identity

[[ -n "${INSTANCE_TYPES:-}" ]] || die "INSTANCE_TYPES is not set"
read -r -a types <<<"$INSTANCE_TYPES"

FLEET_ID="${FLEET_ID:-$(date -u +pgss-fleet-%Y%m%dT%H%M%SZ)}"

resolve_ref() {
  local remote="$1" ref="$2" sha

  sha="$(git ls-remote "$remote" "refs/heads/$ref" | cut -f1)"
  [[ -n "$sha" ]] || die "could not resolve $ref in $remote"
  echo "$sha"
}

PATCH_COMMIT="${PATCH_COMMIT:-$(resolve_ref "$PATCH_REMOTE" "$PATCH_REF")}"
BASE_COMMIT="${BASE_COMMIT:-$(resolve_ref "$PG_REMOTE" "$BASE_REF")}"

if [[ -z "${BUILDER_INSTANCE_TYPE:-}" ]]; then
  BUILDER_INSTANCE_TYPE="$(aws_cmd ec2 describe-instance-types \
    --instance-types "${types[@]}" \
    --query 'sort_by(InstanceTypes, &VCpuInfo.DefaultVCpus)[-1].InstanceType' \
    --output text)"
fi
[[ " ${types[*]} " == *" $BUILDER_INSTANCE_TYPE "* ]] ||
  die "builder instance type $BUILDER_INSTANCE_TYPE is not in INSTANCE_TYPES"

# The instance of type $1 of fleet REUSE_FLEET_ID.
reused_instance() {
  local type="$1" instance_id

  instance_id="$(aws_cmd ec2 describe-instances \
    --filters "Name=tag:RunId,Values=$REUSE_FLEET_ID-${type//./-}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  [[ -n "$instance_id" && "$instance_id" != None ]] ||
    die "no $type instance in fleet $REUSE_FLEET_ID"
  echo "$instance_id"
}

declare -A reuse_ids
if [[ -n "${REUSE_FLEET_ID:-}" ]]; then
  for type in "${types[@]}"; do
    reuse_ids[$type]="$(reused_instance "$type")"
  done
fi

BUILD_SHIP_URI="s3://$RESULT_BUCKET/$RESULT_PREFIX/$FLEET_ID/builds.tar.gz"

cat <<EOF
Fleet ID: $FLEET_ID
Patch commit: $PATCH_COMMIT
Base commit: $BASE_COMMIT
Builder: $BUILDER_INSTANCE_TYPE
Builds: $BUILD_SHIP_URI
Reusing: ${REUSE_FLEET_ID:-no}
EOF

for type in "${types[@]}"; do
  role=consumer
  [[ "$type" == "$BUILDER_INSTANCE_TYPE" ]] && role=builder

  echo
  echo "==> Starting $type ($role) ${reuse_ids[$type]:-}"
  env \
    REUSE_INSTANCE_ID="${reuse_ids[$type]:-}" \
    RUN_ID="$FLEET_ID-${type//./-}" \
    INSTANCE_TYPE="$type" \
    BUILD_ROLE="$role" \
    BUILD_SHIP_URI="$BUILD_SHIP_URI" \
    PATCH_COMMIT="$PATCH_COMMIT" \
    BASE_COMMIT="$BASE_COMMIT" \
    "$SCRIPT_DIR/launch_benchmark_instance.sh"
done
