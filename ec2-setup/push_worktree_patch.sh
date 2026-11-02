#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
usage: push_worktree_patch.sh RUN_ID

Push the current tracked diff from a local PostgreSQL worktree to a running
benchmark EC2 instance and apply it there without creating a commit.

Environment:
  PG_WORKTREE       Local PostgreSQL worktree. Defaults to the current
                    directory when it is a git worktree.
  REMOTE_REPO       Remote PostgreSQL clone path.
                    Default: /home/ec2-user/pgss-benchmark/postgres
  REMOTE_BUILD_DIR  Remote Meson build dir.
                    Default: $REMOTE_REPO/build-release
  REMOTE_REBUILD    If 1, run ninja install after applying the patch.
                    Default: 0
  PRESIGN_EXPIRES   Seconds for temporary artifact download URLs.
                    Default: 3600

The patch is generated with git diff --binary HEAD, so untracked files are not
included. The remote PostgreSQL clone is force-checked-out to the local HEAD
commit before applying the patch.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

quote_word() {
  printf '%q' "$1"
}

write_ssm_commands() {
  local output_file="$1"
  shift

  python3 - "$output_file" "$@" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"commands": sys.argv[2:]}, f)
PY
}

presign_artifact() {
  local s3_uri="$1"

  aws_cmd s3 presign "$s3_uri" --expires-in "${PRESIGN_EXPIRES:-3600}"
}

main() {
  local run_id="${1:-}"
  local pg_worktree patch_dir experiment_id patch_file meta_file diffstat_file
  local names_file remote_script_file commands_file cmd_id instance_state
  local base_commit branch_name patch_sha patch_s3_uri meta_s3_uri script_s3_uri
  local diffstat_s3_uri names_s3_uri experiment_s3_uri remote_repo
  local remote_build_dir remote_experiment_dir remote_rebuild run_cmd
  local patch_url meta_url diffstat_url names_url script_url
  local -a ssm_commands env_args

  if [[ "$run_id" == "-h" || "$run_id" == "--help" ]]; then
    usage
    exit 0
  fi

  [[ -n "$run_id" ]] || die "RUN_ID is required"

  load_config
  load_latest_state "$run_id"
  check_aws_identity

  require_cmd git
  require_cmd sha256sum
  require_cmd python3

  if [[ -n "${PG_WORKTREE:-}" ]]; then
    pg_worktree="$PG_WORKTREE"
  elif git rev-parse --show-toplevel >/dev/null 2>&1; then
    pg_worktree="$(git rev-parse --show-toplevel)"
  else
    die "PG_WORKTREE is required when not run from a git worktree"
  fi

  [[ -d "$pg_worktree/.git" || -f "$pg_worktree/.git" ]] || \
    die "$pg_worktree is not a git worktree"

  base_commit="$(git -C "$pg_worktree" rev-parse HEAD)"
  branch_name="$(git -C "$pg_worktree" branch --show-current || true)"

  if git -C "$pg_worktree" diff --quiet HEAD --; then
    die "no tracked worktree diff relative to HEAD in $pg_worktree"
  fi

  instance_state="$(aws_cmd ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)"
  [[ "$instance_state" == "running" ]] || \
    die "instance $INSTANCE_ID is $instance_state, expected running"

  experiment_id="dirty-$(date -u +%Y%m%dT%H%M%SZ)-${base_commit:0:12}"
  patch_dir="$STATE_DIR/$run_id.dirty-patches/$experiment_id"
  mkdir -p "$patch_dir"

  patch_file="$patch_dir/worktree.patch"
  meta_file="$patch_dir/metadata.env"
  diffstat_file="$patch_dir/diffstat.txt"
  names_file="$patch_dir/name-status.txt"
  remote_script_file="$patch_dir/apply_dirty_patch.sh"
  commands_file="$patch_dir/ssm-commands.json"

  git -C "$pg_worktree" diff --binary HEAD -- >"$patch_file"
  git -C "$pg_worktree" diff --stat HEAD -- >"$diffstat_file"
  git -C "$pg_worktree" diff --name-status HEAD -- >"$names_file"
  patch_sha="$(sha256sum "$patch_file" | awk '{print $1}')"

  cat >"$meta_file" <<EOF
run_id=$RUN_ID
instance_id=$INSTANCE_ID
local_worktree=$pg_worktree
local_branch=$branch_name
base_commit=$base_commit
patch_sha256=$patch_sha
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
remote_rebuild=${REMOTE_REBUILD:-0}
EOF

  cat >"$remote_script_file" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${RUN_ID:?}"
: "${BASE_COMMIT:?}"
: "${PATCH_SHA256:?}"
: "${PATCH_URL:?}"
: "${META_URL:?}"
: "${DIFFSTAT_URL:?}"
: "${NAMES_URL:?}"
: "${EXPERIMENT_S3_URI:?}"
: "${REMOTE_REPO:?}"
: "${REMOTE_BUILD_DIR:?}"
: "${REMOTE_EXPERIMENT_DIR:?}"

REMOTE_REBUILD="${REMOTE_REBUILD:-0}"

fetch_url() {
  local url="$1" dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    python3 - "$url" "$dest" <<'PY'
import sys
import urllib.request

urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PY
  fi
}

finish() {
  local status="$?"

  set +e
  echo "$status" >"$REMOTE_EXPERIMENT_DIR/apply-status.txt"
  if [[ -d "$REMOTE_EXPERIMENT_DIR" ]]; then
    aws s3 cp "$REMOTE_EXPERIMENT_DIR/" "$EXPERIMENT_S3_URI/" \
      --recursive --exclude 'worktree.patch' >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap finish EXIT

mkdir -p "$REMOTE_EXPERIMENT_DIR"
fetch_url "$PATCH_URL" "$REMOTE_EXPERIMENT_DIR/worktree.patch"
fetch_url "$META_URL" "$REMOTE_EXPERIMENT_DIR/metadata.env"
fetch_url "$DIFFSTAT_URL" "$REMOTE_EXPERIMENT_DIR/diffstat.txt"
fetch_url "$NAMES_URL" "$REMOTE_EXPERIMENT_DIR/name-status.txt"

sha256sum "$REMOTE_EXPERIMENT_DIR/worktree.patch" >"$REMOTE_EXPERIMENT_DIR/worktree.patch.sha256"
actual_sha="$(awk '{print $1}' "$REMOTE_EXPERIMENT_DIR/worktree.patch.sha256")"
[[ "$actual_sha" == "$PATCH_SHA256" ]]

git -c safe.directory="$REMOTE_REPO" -C "$REMOTE_REPO" cat-file -e "$BASE_COMMIT^{commit}"
git -c safe.directory="$REMOTE_REPO" -C "$REMOTE_REPO" checkout -q -f "$BASE_COMMIT"
git -c safe.directory="$REMOTE_REPO" -C "$REMOTE_REPO" reset --hard -q "$BASE_COMMIT"

git -c safe.directory="$REMOTE_REPO" -C "$REMOTE_REPO" apply --check "$REMOTE_EXPERIMENT_DIR/worktree.patch"
git -c safe.directory="$REMOTE_REPO" -C "$REMOTE_REPO" apply --whitespace=nowarn "$REMOTE_EXPERIMENT_DIR/worktree.patch"

git -c safe.directory="$REMOTE_REPO" -C "$REMOTE_REPO" diff --stat HEAD -- >"$REMOTE_EXPERIMENT_DIR/remote-diffstat.txt"
git -c safe.directory="$REMOTE_REPO" -C "$REMOTE_REPO" diff --name-status HEAD -- >"$REMOTE_EXPERIMENT_DIR/remote-name-status.txt"
git -c safe.directory="$REMOTE_REPO" -C "$REMOTE_REPO" status --short >"$REMOTE_EXPERIMENT_DIR/remote-status.txt"

if [[ "$REMOTE_REBUILD" == "1" ]]; then
  ninja -C "$REMOTE_BUILD_DIR" install >"$REMOTE_EXPERIMENT_DIR/rebuild.log" 2>&1
fi
EOF

  chmod +x "$remote_script_file"

  experiment_s3_uri="$RESULT_S3_URI/dirty-patches/$experiment_id"
  patch_s3_uri="$experiment_s3_uri/worktree.patch"
  meta_s3_uri="$experiment_s3_uri/metadata.env"
  diffstat_s3_uri="$experiment_s3_uri/diffstat.txt"
  names_s3_uri="$experiment_s3_uri/name-status.txt"
  script_s3_uri="$experiment_s3_uri/apply_dirty_patch.sh"

  aws_cmd s3 cp "$patch_file" "$patch_s3_uri" >/dev/null
  aws_cmd s3 cp "$meta_file" "$meta_s3_uri" >/dev/null
  aws_cmd s3 cp "$diffstat_file" "$diffstat_s3_uri" >/dev/null
  aws_cmd s3 cp "$names_file" "$names_s3_uri" >/dev/null
  aws_cmd s3 cp "$remote_script_file" "$script_s3_uri" >/dev/null

  patch_url="$(presign_artifact "$patch_s3_uri")"
  meta_url="$(presign_artifact "$meta_s3_uri")"
  diffstat_url="$(presign_artifact "$diffstat_s3_uri")"
  names_url="$(presign_artifact "$names_s3_uri")"
  script_url="$(presign_artifact "$script_s3_uri")"

  remote_repo="${REMOTE_REPO:-/home/ec2-user/pgss-benchmark/postgres}"
  remote_build_dir="${REMOTE_BUILD_DIR:-$remote_repo/build-release}"
  remote_experiment_dir="${REMOTE_EXPERIMENT_DIR:-/home/ec2-user/pgss-benchmark/results/$RUN_ID/dirty-patches/$experiment_id}"
  remote_rebuild="${REMOTE_REBUILD:-0}"

  env_args=(
    "RUN_ID=$RUN_ID"
    "BASE_COMMIT=$base_commit"
    "PATCH_SHA256=$patch_sha"
    "PATCH_URL=$patch_url"
    "META_URL=$meta_url"
    "DIFFSTAT_URL=$diffstat_url"
    "NAMES_URL=$names_url"
    "EXPERIMENT_S3_URI=$experiment_s3_uri"
    "REMOTE_REPO=$remote_repo"
    "REMOTE_BUILD_DIR=$remote_build_dir"
    "REMOTE_EXPERIMENT_DIR=$remote_experiment_dir"
    "REMOTE_REBUILD=$remote_rebuild"
    "AWS_DEFAULT_REGION=$AWS_REGION"
  )

  run_cmd="sudo -iu ec2-user env"
  for env_arg in "${env_args[@]}"; do
    run_cmd+=" $(quote_word "$env_arg")"
  done
  run_cmd+=" $(quote_word "$remote_experiment_dir/apply_dirty_patch.sh")"

  ssm_commands=(
    "set -Eeuo pipefail"
    "mkdir -p $(quote_word "$remote_experiment_dir")"
    "if command -v curl >/dev/null 2>&1; then curl -fsSL $(quote_word "$script_url") -o $(quote_word "$remote_experiment_dir/apply_dirty_patch.sh"); else python3 -c 'import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' $(quote_word "$script_url") $(quote_word "$remote_experiment_dir/apply_dirty_patch.sh"); fi"
    "chmod +x $(quote_word "$remote_experiment_dir/apply_dirty_patch.sh")"
    "$run_cmd"
  )

  write_ssm_commands "$commands_file" "${ssm_commands[@]}"

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
    --query '[Status,StandardOutputContent,StandardErrorContent]' \
    --output text

  echo
  echo "Dirty patch experiment: $experiment_id"
  echo "Base commit:            $base_commit"
  echo "Patch sha256:           $patch_sha"
  echo "S3:                     $experiment_s3_uri"
}

main "$@"
