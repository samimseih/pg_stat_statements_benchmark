#!/bin/bash
# switch_build.sh - Switch between patched and upstream pg_stat_statements
#
# Usage:
#   ./switch_build.sh upstream [debug|release|debug_noassert]
#   ./switch_build.sh patch    [debug|release|debug_noassert]
#
# Defaults to release build. Reconfigures meson only when build type changes.
# Rebuilds and restarts the server after switching.

set -e

MODE="${1:?Usage: $0 upstream|patch [debug|release]}"
BUILD_TYPE="${2:-release}"
REPO_DIR="$HOME/Development/pgdev/installations/worktrees/dev"
BUILD_DIR="$REPO_DIR/build"

export PATH=$HOME/Development/pgdev/installations/pghome/dev/bin:$PATH
export PGDATA=$HOME/Development/pgdev/installations/pgdata/dev

BASELINE="d5e060fdcc3"

case "$MODE" in
    upstream)
        echo "Switching to upstream..."
        # Get the list of files changed between baseline and HEAD
        for f in $(git -C "$REPO_DIR" diff "$BASELINE" HEAD --name-only); do
            if git -C "$REPO_DIR" cat-file -e "$BASELINE:$f" 2>/dev/null; then
                git -C "$REPO_DIR" show "$BASELINE:$f" > "$REPO_DIR/$f"
            else
                rm -f "$REPO_DIR/$f"
            fi
        done
        ;;
    patch)
        echo "Switching to patch..."
        for f in $(git -C "$REPO_DIR" diff "$BASELINE" HEAD --name-only); do
            git -C "$REPO_DIR" checkout HEAD -- "$f"
        done
        ;;
    *)
        echo "Usage: $0 upstream|patch [debug|release]"
        exit 1
        ;;
esac

# Reconfigure meson if build type changed
CURRENT_TYPE=$(meson introspect "$BUILD_DIR" --buildoptions 2>/dev/null | python3 -c "
import json,sys
opts = json.load(sys.stdin)
for o in opts:
    if o['name'] == 'buildtype':
        print(o['value'])
        break
" 2>/dev/null || echo "unknown")

case "$BUILD_TYPE" in
    debug)
        MESON_TYPE="debug"
        EXTRA_OPTS="-Dcassert=true -Db_ndebug=false"
        ;;
    debug_noassert)
        MESON_TYPE="debug"
        EXTRA_OPTS="-Dcassert=false -Db_ndebug=true"
        ;;
    release)
        MESON_TYPE="release"
        EXTRA_OPTS="-Dcassert=false -Db_ndebug=true"
        ;;
    *)
        echo "Invalid build type: $BUILD_TYPE (use debug or release or debug_noassert)"
        exit 1
        ;;
esac

# Apply pgbench extended-nobind patch (needed for benchmarking)
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/patch"
for p in "$PATCH_DIR"/*.patch; do
    git -C "$REPO_DIR" apply --check "$p" 2>/dev/null && git -C "$REPO_DIR" apply "$p"
done

echo "Configuring meson: buildtype=$MESON_TYPE, opts: $EXTRA_OPTS..."
if [[ -f "$BUILD_DIR/build.ninja" ]]; then
    meson configure "$BUILD_DIR" --buildtype="$MESON_TYPE" $EXTRA_OPTS
else
    meson setup "$BUILD_DIR" --reconfigure --prefix="$HOME/Development/pgdev/installations/pghome/dev" --buildtype="$MESON_TYPE" $EXTRA_OPTS
fi

echo "Rebuilding ($MESON_TYPE)..."
ninja -C "$BUILD_DIR" install >/dev/null

echo "Restarting server..."
BENCH_TMPDIR="${BENCH_TMPDIR:-$HOME/Development/benchmarks/tmp}"
mkdir -p "$BENCH_TMPDIR"
pg_ctl restart -l "$BENCH_TMPDIR/pglog.txt" -w 2>&1 | tail -1

echo "Done. Current build: $MODE ($MESON_TYPE)"
