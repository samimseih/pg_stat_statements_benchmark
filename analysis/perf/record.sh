#!/bin/bash
# perf/record.sh - Record a perf profile on active PostgreSQL backends
#
# Usage:
#   ./perf/record.sh [-p PORT] [-w WORKTREE] [-n NUM] [-d DURATION] [-o OUTPUT]
#
# Records with DWARF call graphs for accurate caller/callee attribution.
# Requires a pgbench load running against the target port.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../bench_config.sh"

PORT=5433
WT_NAME=""
NUM=5
DURATION=10
OUTPUT=""
FREQ=997

usage() {
    cat <<HELP
Usage: $(basename "$0") [-p PORT] [-w WORKTREE] [-n NUM] [-d DURATION] [-o OUTPUT]

Options:
  -p PORT       PostgreSQL port (default: 5433)
  -w WORKTREE   Worktree name to find psql (default: auto-detect from port)
  -n NUM        Number of backends to sample (default: 5)
  -d DURATION   Seconds to record (default: 10)
  -o OUTPUT     Output file (default: ~/tmp/perf_<worktree>_<timestamp>.data)
  -F FREQ       Sampling frequency in Hz (default: 997)
  -h            Show this help

Examples:
  ./perf/record.sh -p 5433 -w lfu
  ./perf/record.sh -p 5433 -w baseline -d 20
  ./perf/record.sh -p 5433 -w lfu -n 8 -F 4999
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) PORT="$2"; shift 2 ;;
        -w) WT_NAME="$2"; shift 2 ;;
        -n) NUM="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -o) OUTPUT="$2"; shift 2 ;;
        -F) FREQ="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Find psql
if [[ -n "$WT_NAME" ]]; then
    PSQL="$PG_INSTALL_DIR/$WT_NAME/bin/psql"
else
    PSQL=$(command -v psql 2>/dev/null || echo "")
fi

if [[ ! -x "$PSQL" ]]; then
    echo "ERROR: psql not found. Use -w to specify worktree name." >&2
    exit 1
fi

[[ -z "$OUTPUT" ]] && OUTPUT="$HOME/tmp/perf_${WT_NAME:-port${PORT}}_$(date +%Y%m%d_%H%M%S).data"
mkdir -p "$(dirname "$OUTPUT")"

PIDS=$("$PSQL" -U postgres -p "$PORT" -d benchmark -XAtc \
    "SELECT string_agg(pid::text, ',')
     FROM (SELECT pid FROM pg_stat_activity
           WHERE state = 'active' AND pid != pg_backend_pid()
           LIMIT $NUM) t;" 2>/dev/null)

if [[ -z "$PIDS" ]]; then
    echo "ERROR: No active backends found on port $PORT" >&2
    echo "       Start a pgbench load first." >&2
    exit 1
fi

echo "Recording ${DURATION}s @ ${FREQ}Hz on PIDs: $PIDS"
echo "Output: $OUTPUT"

sudo perf record --call-graph dwarf,16384 -F "$FREQ" -p "$PIDS" -o "$OUTPUT" -- sleep "$DURATION"

echo ""
echo "Done. Analyze with:"
echo "  ./perf/report.sh $OUTPUT"
echo "  ./perf/report.sh $OUTPUT --function pgss_store"
