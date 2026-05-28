# Source this file to set up environment for the benchmark cluster
#
# Usage: source ./bench_env.sh
#        psql -d benchmark -c "SELECT count(*) FROM pg_stat_statements;"

_BENCH_ENV_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$_BENCH_ENV_DIR/../bench_config.sh"

export PATH="$PG_INSTALL_DIR/bench/bin:$PATH"
export PGDATA="$PG_DATA_DIR/bench"
export PGPORT=5433
export PGUSER=postgres
