#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_NAME="${SESSION_NAME:-pgss_bench}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/suite.tmux.log}"
SUITE="$SCRIPT_DIR/run_pgss_benchmark_suite.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

command -v tmux >/dev/null || die "tmux is required to start the suite in the background"
[[ -x "$SUITE" ]] || die "$SUITE is not executable"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  die "tmux session '$SESSION_NAME' already exists"
fi

: >"$LOG_FILE"

printf -v command 'exec %q > %q 2>&1' "$SUITE" "$LOG_FILE"
tmux new-session -d -s "$SESSION_NAME" -c "$SCRIPT_DIR" "$command"

cat <<EOF
Started pg_stat_statements benchmark suite in tmux session '$SESSION_NAME'.

Attach:
  tmux attach -t $SESSION_NAME

Follow log:
  tail -f $LOG_FILE

Stop:
  tmux kill-session -t $SESSION_NAME
EOF
