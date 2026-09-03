#!/bin/bash
# First-launch helper for unsigned (ad-hoc signed) macOS builds.
# Strips Gatekeeper's quarantine flag so Cookbook.app can be opened normally
# from then on. After this has run once, double-click Cookbook.app as usual.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/Cookbook.app"
if [[ ! -d "$APP" ]]; then
  osascript -e "display dialog \"Cookbook.app was not found next to this script. Keep this file next to Cookbook.app (in the disk image, or copy both into the same folder) and try again.\" buttons {\"OK\"} with icon stop"
  exit 1
fi
xattr -cr "$APP" 2>/dev/null || true
open "$APP"
