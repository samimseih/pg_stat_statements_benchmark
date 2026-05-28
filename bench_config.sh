# bench_config.sh - Central configuration for all benchmark scripts
#
# Override any of these by exporting the variable before sourcing,
# or by creating a bench_config.local.sh alongside this file.
#
# Scripts pass a worktree name; paths are derived from base directories:
#   worktree dir  → $PG_WORKTREES_DIR/<name>
#   install dir   → $PG_INSTALL_DIR/<name>
#   data dir      → $PG_DATA_DIR/<name>

BENCH_CONFIG_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PG_SOURCE_DIR="${PG_SOURCE_DIR:-$HOME/pg/source}"
PG_WORKTREES_DIR="${PG_WORKTREES_DIR:-$HOME/pg/worktrees}"
PG_INSTALL_DIR="${PG_INSTALL_DIR:-$HOME/pg/install}"
PG_DATA_DIR="${PG_DATA_DIR:-$HOME/pg/data}"
BENCH_RESULTS_DIR="${BENCH_RESULTS_DIR:-$HOME/pg/results}"

# Source local overrides if present
if [[ -f "$BENCH_CONFIG_DIR/bench_config.local.sh" ]]; then
    source "$BENCH_CONFIG_DIR/bench_config.local.sh"
fi
