#!/usr/bin/env bash
# Build a git ref of PG_SRC into inst-<short hash>, without touching the
# checkout, and print the install name.
# usage: build.sh <ref>
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/common.sh"
[ -n "${PG_SRC:-}" ] || { echo "PG_SRC is not set" >&2; exit 1; }
H=$(git -C "$PG_SRC" rev-parse --short=7 "$1^{commit}")
I=inst-$H
if [ ! -x $I/bin/postgres ]; then
  rm -rf src-$H bld-$H; mkdir src-$H
  git -C "$PG_SRC" archive $H | tar -x -C src-$H
  meson setup bld-$H src-$H --buildtype=release -Dprefix=$PWD/$I > bld-$H.log 2>&1 &&
    nice ninja -C bld-$H install >> bld-$H.log 2>&1 ||
    { echo "build of $1 failed, see $PWD/bld-$H.log" >&2; exit 1; }
  rm -rf src-$H bld-$H
fi
echo $I
