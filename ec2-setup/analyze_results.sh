#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $0 [results-subdir-or-run-id]

Examples:
  $0
  $0 pgss-2p5h-20261015T122532Z
  $0 results/pgss-2p5h-20261015T122532Z
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  if [[ -d "$1" ]]; then
    dest="$(cd "$1" && pwd)"
    run_id="$(basename "$dest")"
  elif [[ -d "$SCRIPT_DIR/results/$1" ]]; then
    run_id="$1"
    dest="$SCRIPT_DIR/results/$run_id"
  else
    die "could not find results directory or run id: $1"
  fi
else
  [[ -f "$SCRIPT_DIR/state/latest.env" ]] || die "missing state/latest.env; pass a results subdir"
  run_id="$(awk -F= '/^RUN_ID=/ {print $2}' "$SCRIPT_DIR/state/latest.env")"
  [[ -n "$run_id" ]] || die "RUN_ID not found in state/latest.env"
  dest="$SCRIPT_DIR/results/$run_id"
fi

tarball="$dest/$run_id.results.tar.gz"
extract_root="$dest/extracted"
result_dir="$extract_root/$run_id"
report="$dest/report.md"
benchmark_repo="${BENCHMARK_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
report_script="$benchmark_repo/report_pgss_benchmark.sh"

[[ -f "$tarball" ]] || die "missing result tarball: $tarball"
[[ -x "$report_script" ]] || die "missing executable report script: $report_script"

mkdir -p "$extract_root"
if [[ ! -f "$result_dir/summary.tsv" ]]; then
  tar -xzf "$tarball" -C "$extract_root"
fi

[[ -f "$result_dir/summary.tsv" ]] || die "missing summary after extraction: $result_dir/summary.tsv"

"$report_script" "$result_dir" > "$report"

failed_rows="$(
  awk -F $'\t' '
    NR == 1 {
      for (i = 1; i <= NF; i++)
        c[$i] = i
      next
    }
    $c["status"] != 0 || $c["failed"] != 0 {
      n++
    }
    END { print n + 0 }
  ' "$result_dir/summary.tsv"
)"

row_count="$(awk 'END { if (NR > 0) print NR - 1; else print 0 }' "$result_dir/summary.tsv")"

cat <<EOF
Analyzed $run_id

Report:  $report
Summary: $result_dir/summary.tsv
Rows:    $row_count
Failed:  $failed_rows

Open:
  less "$report"
  column -t -s \$'\\t' "$result_dir/summary.tsv" | less -S
EOF
