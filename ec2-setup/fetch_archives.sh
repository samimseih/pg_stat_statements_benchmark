#!/usr/bin/env bash
#
# Fetch the results archives of runs from S3 into results/archive/<run id>,
# for report_page.py: the wait events and other per-point files of each run.
# A run stopped before its end has a partial archive instead, which is used
# when there is no full one.  Perf data files are left out.
#
# Usage:
#   ./fetch_archives.sh <run id>...
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

[[ $# -gt 0 ]] || die "usage: $0 <run id>..."

load_config
check_aws_identity

for run_id in "$@"; do
  out="$SCRIPT_DIR/results/archive/$run_id"
  if [[ -d "$out/$run_id" ]]; then
    echo "$run_id: already fetched"
    continue
  fi
  mkdir -p "$out"
  for name in "$run_id.results.tar.gz" "$run_id.partial.tar.gz"; do
    if aws_cmd s3 cp --only-show-errors \
        "s3://$RESULT_BUCKET/$RESULT_PREFIX/$run_id/$name" "$out/archive.tar.gz" 2>/dev/null; then
      tar -xzf "$out/archive.tar.gz" -C "$out" --exclude='*.data' --exclude='perf*'
      rm -f "$out/archive.tar.gz"
      echo "$run_id: $name"
      break
    fi
  done
  [[ -d "$out/$run_id" ]] || echo "$run_id: no archive" >&2
done
