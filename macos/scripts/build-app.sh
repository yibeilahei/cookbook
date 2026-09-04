#!/bin/bash
# Build Cookbook.app and a .dmg. Run from anywhere:
#
#   macos/scripts/build-app.sh
#
# The app calls Calibre's ebook-convert directly and packs .xtch in Swift.
# Calibre is a runtime dependency, not bundled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACOS="$ROOT/macos"
DIST="${COOKBOOK_DIST:-$ROOT/dist}"
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
