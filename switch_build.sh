#!/bin/bash
# switch_build.sh - Manage PostgreSQL benchmark worktrees, builds, and clusters
#
# Modes (each does exactly one thing):
#   switch_build.sh -c <commit> -w <name>              Create worktree
#   switch_build.sh -w <name> --patch <file>           Apply patch to worktree
#   switch_build.sh -w <name> -b <type>               Build (or rebuild)
#   switch_build.sh -w <name> [-m N] [-p PORT]        Start cluster
#   switch_build.sh --remove -w <name>                Tear down everything
set -e

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/bench_config.sh"

SOURCE_DIR="$PG_SOURCE_DIR"

usage() {
    cat <<HELP
Usage:
  $(basename "$0") -c COMMIT -w NAME              Create worktree from commit
  $(basename "$0") -w NAME --patch FILE           Apply a patch file to worktree
  $(basename "$0") -w NAME -b TYPE                Build (or rebuild after edits/patches)
  $(basename "$0") -w NAME [-m N] [-p PORT]       Start cluster
  $(basename "$0") --remove -w NAME               Stop server + remove worktree/install/data

Options:
  -c, --commit COMMIT     Commit/branch to check out
  -w, --worktree NAME     Worktree name (required)
  -b, --build-type TYPE   debug, release, or debug_noassert
      --patch FILE        Patch file to apply (git apply)
  -m, --max MAX           pg_stat_statements.max (default: 5000)
  -p, --port PORT         Server port (default: 5433)
      --recreate-cluster  Remove data dir and re-initdb on start
      --remove            Stop server and remove worktree/install/data
  -h, --help              Show this help

Workflow:
  1. Create:  $(basename "$0") -c a21bd27 -w lru
  2. Patch:   $(basename "$0") -w lru --patch my_fix.patch   (optional)
  3. Build:   $(basename "$0") -w lru -b release
  4. Start:   $(basename "$0") -w lru -m 5000 -p 5433
  5. Remove:  $(basename "$0") --remove -w lru
HELP
}

COMMIT=""
BUILD_TYPE=""
PGSS_MAX=5000
BENCH_PORT=5433
WT_NAME=""
PATCH_FILE=""
REMOVE=false
RECREATE_CLUSTER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --remove) REMOVE=true; shift ;;
        --recreate-cluster) RECREATE_CLUSTER=true; shift ;;
        --patch) PATCH_FILE="$2"; shift 2 ;;
        -c|--commit) COMMIT="$2"; shift 2 ;;
        -b|--build-type) BUILD_TYPE="$2"; shift 2 ;;
        -m|--max) PGSS_MAX="$2"; shift 2 ;;
        -w|--worktree) WT_NAME="$2"; shift 2 ;;
        -p|--port) BENCH_PORT="$2"; shift 2 ;;
        -*) echo "Unknown option: $1"; echo "Try --help"; exit 1 ;;
        *) echo "Unexpected argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$WT_NAME" ]]; then
    echo "Error: -w NAME is required"
    exit 1
fi

BENCH_WORKTREE="$PG_WORKTREES_DIR/$WT_NAME"
BENCH_INSTALL="$PG_INSTALL_DIR/$WT_NAME"
BENCH_PGDATA="$PG_DATA_DIR/$WT_NAME"

# --- Remove ---
if $REMOVE; then
    echo "Stopping server..."
    "$BENCH_INSTALL/bin/pg_ctl" stop -D "$BENCH_PGDATA" -m fast 2>/dev/null || true

    echo "Removing worktree '$WT_NAME'..."
    git -C "$SOURCE_DIR" worktree remove --force "$BENCH_WORKTREE" 2>/dev/null || rm -rf "$BENCH_WORKTREE"
    rm -rf "$BENCH_PGDATA" "$BENCH_INSTALL"

    echo "Done. Worktree '$WT_NAME' removed."
    exit 0
fi

# --- Create worktree ---
if [[ -n "$COMMIT" ]]; then
    REQUESTED=$(git -C "$SOURCE_DIR" rev-parse "$COMMIT" 2>/dev/null || true)
    if [[ -z "$REQUESTED" ]]; then
        echo "Error: cannot resolve commit '$COMMIT'"
        exit 1
    fi

    if [[ -d "$BENCH_WORKTREE" ]]; then
        CURRENT_HEAD=$(git -C "$BENCH_WORKTREE" rev-parse HEAD 2>/dev/null || true)
        if [[ "$CURRENT_HEAD" != "$REQUESTED" ]]; then
            echo "Switching worktree '$WT_NAME' to $COMMIT..."
            git -C "$BENCH_WORKTREE" checkout --detach "$REQUESTED" --quiet
        else
            echo "Worktree '$WT_NAME' already at $COMMIT"
        fi
    else
        echo "Creating worktree '$WT_NAME' at $COMMIT..."
        git -C "$SOURCE_DIR" worktree add "$BENCH_WORKTREE" "$COMMIT" --detach
    fi

    echo "Done. Worktree ready at: $BENCH_WORKTREE"
    exit 0
fi

# --- Patch ---
if [[ -n "$PATCH_FILE" ]]; then
    if [[ ! -d "$BENCH_WORKTREE" ]]; then
        echo "Error: worktree '$WT_NAME' does not exist"
        exit 1
    fi
    if [[ ! -f "$PATCH_FILE" ]]; then
        echo "Error: patch file not found: $PATCH_FILE"
        exit 1
    fi

    echo "Applying patch to worktree '$WT_NAME'..."
    git -C "$BENCH_WORKTREE" apply "$PATCH_FILE"

    echo "Done. Patch applied."
    exit 0
fi

# --- Build ---
if [[ -n "$BUILD_TYPE" ]]; then
    if [[ ! -d "$BENCH_WORKTREE" ]]; then
        echo "Error: worktree '$WT_NAME' does not exist"
        exit 1
    fi

    BUILD_DIR="$BENCH_WORKTREE/build"

    case "$BUILD_TYPE" in
        debug)          MESON_TYPE="debug";   EXTRA_OPTS="-Dcassert=true -Db_ndebug=false" ;;
        debug_noassert) MESON_TYPE="debug";   EXTRA_OPTS="-Dcassert=false -Db_ndebug=true" ;;
        release)        MESON_TYPE="release"; EXTRA_OPTS="-Dcassert=false -Db_ndebug=true" ;;
        *) echo "Invalid build type: $BUILD_TYPE"; exit 1 ;;
    esac

    if [[ ! -d "$BUILD_DIR" ]]; then
        echo "Configuring ($BUILD_TYPE)..."
        if ! meson setup "$BUILD_DIR" "$BENCH_WORKTREE" \
            --prefix="$BENCH_INSTALL" \
            --buildtype="$MESON_TYPE" $EXTRA_OPTS; then
            echo "Error: meson setup failed"
            exit 1
        fi
    else
        CURRENT_TYPE=$(meson introspect "$BUILD_DIR" --buildoptions 2>/dev/null | \
            awk -F'"' '/"name".*"buildtype"/{getline; print $4}')
        if [[ -n "$CURRENT_TYPE" && "$CURRENT_TYPE" != "$MESON_TYPE" ]]; then
            echo "Reconfiguring ($BUILD_TYPE)..."
            if ! meson configure "$BUILD_DIR" \
                --buildtype="$MESON_TYPE" $EXTRA_OPTS; then
                echo "Error: meson configure failed"
                exit 1
            fi
        fi
    fi

    echo "Building..."
    # Stop server if running (can't overwrite binaries in use)
    "$BENCH_INSTALL/bin/pg_ctl" stop -D "$BENCH_PGDATA" -m fast 2>/dev/null || true
    if ! ninja -C "$BUILD_DIR" install; then
        echo "Error: build failed"
        exit 1
    fi

    # Remove data dir so cluster gets re-initialized on next start
    rm -rf "$BENCH_PGDATA"

    echo "Done. Build installed to: $BENCH_INSTALL"
    exit 0
fi

# --- Start cluster ---
if [[ ! -x "$BENCH_INSTALL/bin/postgres" ]]; then
    echo "Error: no build found for worktree '$WT_NAME'"
    echo "  Expected: $BENCH_INSTALL/bin/postgres"
    echo "  Run: $(basename "$0") -w $WT_NAME -b release"
    exit 1
fi

export PATH="$BENCH_INSTALL/bin:$PATH"

kill_port() {
    local pid
    if [[ "$(uname)" == "Linux" ]]; then
        pid=$(fuser "$BENCH_PORT"/tcp 2>/dev/null || true)
    else
        pid=$(lsof -ti "tcp:$BENCH_PORT" -s tcp:listen 2>/dev/null || true)
    fi
    if [[ -n "$pid" ]]; then
        kill $pid 2>/dev/null || true
        sleep 0.5
    fi
}

pg_ctl stop -D "$BENCH_PGDATA" -m fast 2>/dev/null || true
kill_port

if $RECREATE_CLUSTER && [[ -d "$BENCH_PGDATA" ]]; then
    echo "Removing existing cluster..."
    rm -rf "$BENCH_PGDATA"
fi

if [[ ! -d "$BENCH_PGDATA" ]]; then
    echo "Initializing cluster..."
    initdb -D "$BENCH_PGDATA" -U postgres --no-instructions --no-locale >/dev/null

    {
        echo "port = $BENCH_PORT"
        echo "unix_socket_directories = '/tmp'"
        echo "shared_preload_libraries = 'pg_stat_statements'"
        echo "pg_stat_statements.max = $PGSS_MAX"
        echo "max_connections = 1000"
        echo "shared_buffers = 4GB"
        echo "logging_collector = on"
        echo "log_directory = 'log'"
        echo "log_filename = 'postgresql.log'"
        echo "log_truncate_on_rotation = on"
        echo "log_min_messages = warning"
    } >> "$BENCH_PGDATA/postgresql.conf"
fi

if [[ "$(uname)" == "Linux" ]]; then
    echo $$ | sudo tee /sys/fs/cgroup/cgroup.procs >/dev/null 2>&1 || true
fi

ulimit -c unlimited
pg_ctl start -D "$BENCH_PGDATA" -l "$BENCH_PGDATA/logfile" -w >/dev/null

# Generate env activation script
ENV_SCRIPT="$BENCH_INSTALL/env.sh"
cat > "$ENV_SCRIPT" <<ENVEOF
# Source this to activate the '$WT_NAME' environment:
#   source $ENV_SCRIPT
export PGHOME="$BENCH_INSTALL"
export PGDATA="$BENCH_PGDATA"
export PGPORT=$BENCH_PORT
export PGHOST=/tmp
export PGDATABASE=postgres
export PGUSER=postgres
export PATH="$BENCH_INSTALL/bin:\$PATH"
export LD_LIBRARY_PATH="$BENCH_INSTALL/lib:\$LD_LIBRARY_PATH"
ENVEOF

echo ""
echo "Done. Server running on port $BENCH_PORT"
echo "  Worktree: $WT_NAME"
echo "  Commit:   $(git -C "$BENCH_WORKTREE" log --oneline -1 HEAD)"
echo "  pg_stat_statements.max: $PGSS_MAX"
echo ""
echo "Activate env: source $ENV_SCRIPT"
echo "Run benchmarks with: ./bench.sh -p $BENCH_PORT ..."
echo "Tear down with:      $(basename "$0") --remove -w $WT_NAME"
