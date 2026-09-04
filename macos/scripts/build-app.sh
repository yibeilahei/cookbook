#!/bin/bash
# Build Cookbook.app (SwiftUI + optional frozen Python backend) and a .dmg.
# Run from anywhere. Usage:
#
#   macos/scripts/build-app.sh
#
# Expects packaging/dist/backend-server/ if you want the backend bundled
# (freeze it first with PyInstaller; see README). Dev runs don't need that:
# `cd macos && swift run` will spawn `.venv/bin/python3 -m backend.server`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACOS="$ROOT/macos"
DIST="${COOKBOOK_DIST:-$ROOT/packaging/dist}"
APP_NAME="Cookbook"
APP="$DIST/${APP_NAME}.app"

ohai() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

ohai "Building SwiftUI frontend…"
cd "$MACOS"
swift build -c release --product Cookbook
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/Cookbook"
[ -x "$BINARY" ] || { echo "swift build did not produce $BINARY" >&2; exit 1; }

ohai "Assembling ${APP_NAME}.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/${APP_NAME}"
cp "$MACOS/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM resource bundle (strings.json). Name is <target>_<module>.bundle.
BUNDLE_NAME="Cookbook_Cookbook.bundle"
if [ -d "$BIN_DIR/$BUNDLE_NAME" ]; then
  cp -R "$BIN_DIR/$BUNDLE_NAME" "$APP/Contents/Resources/$BUNDLE_NAME"
fi

BACKEND_SRC="$DIST/backend-server"
if [ -d "$BACKEND_SRC" ]; then
  ohai "Bundling Python backend…"
  mkdir -p "$APP/Contents/Resources/backend"
  ditto "$BACKEND_SRC" "$APP/Contents/Resources/backend"
else
  echo "note: $BACKEND_SRC not found; the app will look for a repo-local Python backend at runtime." >&2
fi

ohai "Ad-hoc signing…"
codesign --deep --force --sign - "$APP"

DMG="$DIST/${APP_NAME}.dmg"
ohai "Creating $(basename "$DMG")…"
STAGE="$DIST/dmg-root"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

ohai "Built $APP"
ohai "Built $DMG"
