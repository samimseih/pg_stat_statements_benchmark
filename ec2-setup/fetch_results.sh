#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

load_config
load_latest_state "${1:-}"

DEST="${DEST:-$SCRIPT_DIR/results/$RUN_ID}"
mkdir -p "$DEST"

aws_cmd s3 sync "$RESULT_S3_URI/" "$DEST/"

echo "Fetched results into $DEST"
