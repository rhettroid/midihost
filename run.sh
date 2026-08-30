#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CACHE_ROOT="${TMPDIR:-/tmp}/midi-host-cache"

mkdir -p "$CACHE_ROOT/clang" "$CACHE_ROOT/swift"
cd "$PROJECT_DIR"

CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang" \
SWIFT_MODULECACHE_PATH="$CACHE_ROOT/swift" \
swift run
