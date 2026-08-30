#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CACHE_ROOT="${TMPDIR:-/tmp}/midi-host-cache"
BIN_PATH="$PROJECT_DIR/.build/arm64-apple-macosx/release"
APP_PATH="$PROJECT_DIR/MIDIHost.app"

mkdir -p "$CACHE_ROOT/clang" "$CACHE_ROOT/swift"
cd "$PROJECT_DIR"

CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang" \
SWIFT_MODULECACHE_PATH="$CACHE_ROOT/swift" \
swift build -c release

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/MIDIHost" "$APP_PATH/Contents/MacOS/MIDIHost"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/MIDIHost.icns" "$APP_PATH/Contents/Resources/MIDIHost.icns"
chmod +x "$APP_PATH/Contents/MacOS/MIDIHost"

# Ad-hoc signing is sufficient for personal use on this Mac.
codesign --force --deep --sign - "$APP_PATH"

echo "Created $APP_PATH"
