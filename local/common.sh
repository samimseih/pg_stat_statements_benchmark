# Settings of the local benchmark scripts, sourced by each of them.
#   PG_SRC     a PostgreSQL git checkout holding the refs to benchmark
#   PGSS_WORK  builds, runs and results (default: local/work of this repo)
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PGSS_WORK=${PGSS_WORK:-$REPO/local/work}
mkdir -p "$PGSS_WORK"
cd "$PGSS_WORK" || exit 1
