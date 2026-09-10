#!/bin/bash
# Build Cookbook.app and a .dmg. Run from anywhere:
#
#   macos/scripts/build-app.sh
#
# Produces a universal (arm64 + x86_64) binary so GitHub Releases run on
# Intel Macs as well as Apple Silicon. Cross-compiles from the host.
#
# EPUB/HTML/TXT/Kindle → PDF uses WebKit. Other ebook formats call Calibre's
# ebook-convert. PDF → .xtch is packed in Swift. Calibre is optional.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACOS="$ROOT/macos"
DIST="${COOKBOOK_DIST:-$ROOT/dist}"
APP_NAME="Cookbook"
APP="$DIST/${APP_NAME}.app"
ARCHS=(arm64 x86_64)

ohai() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

ohai "Building SwiftUI frontend (${ARCHS[*]})…"
cd "$MACOS"
BINS=()
BIN_DIR=""
for arch in "${ARCHS[@]}"; do
  ohai "swift build ($arch)…"
  swift build -c release --arch "$arch" --product Cookbook
  dir="$(swift build -c release --arch "$arch" --show-bin-path)"
  bin="$dir/Cookbook"
  [ -x "$bin" ] || { echo "swift build did not produce $bin" >&2; exit 1; }
  BINS+=("$bin")
  [ -n "$BIN_DIR" ] || BIN_DIR="$dir"
done

ohai "Assembling ${APP_NAME}.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/${APP_NAME}"
chmod +x "$APP/Contents/MacOS/${APP_NAME}"
SLICES="$(lipo -archs "$APP/Contents/MacOS/${APP_NAME}")"
ohai "Binary architectures: $SLICES"
for arch in "${ARCHS[@]}"; do
  echo "$SLICES" | grep -qw "$arch" || {
    echo "missing $arch slice in $APP/Contents/MacOS/${APP_NAME}" >&2
    exit 1
  }
done
cp "$MACOS/Info.plist" "$APP/Contents/Info.plist"

# UI strings: copy the file into Contents/Resources so Bundle.main can load it.
# Do not rely on SwiftPM's Bundle.module — that accessor looks for
# Cookbook.app/Cookbook_Cookbook.bundle and crashes the packaged app.
STRINGS="$BIN_DIR/Cookbook_Cookbook.bundle/strings.json"
if [ ! -f "$STRINGS" ]; then
  STRINGS="$MACOS/Sources/Cookbook/Resources/strings.json"
fi
cp "$STRINGS" "$APP/Contents/Resources/strings.json"

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
