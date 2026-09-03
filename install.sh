#!/bin/bash
# Installs the latest Cookbook release into ~/Applications and opens it.
# curl does not set Gatekeeper's quarantine flag, so this avoids the
# "Apple could not verify..." block that a browser-downloaded .app/.command
# hits. Usage (paste in Terminal):
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/yibeilahei/cookbook/main/install.sh)"
#
# macOS ships Bash 3.2 — keep this file compatible with it.
set -euo pipefail

REPO="yibeilahei/cookbook"
APP_NAME="Cookbook"

ohai()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
abort() { printf "\033[1;31mError:\033[0m %s\n" "$*" >&2; exit 1; }

if [ "$(uname -s)" != "Darwin" ]; then
  abort "This installer is for macOS. On Windows, paste: powershell -NoProfile -ExecutionPolicy Bypass -Command \"irm https://raw.githubusercontent.com/${REPO}/main/install.ps1 | iex\""
fi

need() { command -v "$1" >/dev/null 2>&1 || abort "missing required command: $1"; }
need curl
need hdiutil
need ditto
need xattr

ARCH="$(uname -m)"
DEST_DIR="${HOME}/Applications"
DEST="${DEST_DIR}/${APP_NAME}.app"

ohai "Finding the latest Cookbook release…"
JSON="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: cookbook-install" \
  "https://api.github.com/repos/${REPO}/releases/latest")" || abort "could not reach GitHub"

if printf '%s' "$JSON" | grep -q '"message": "Not Found"'; then
  abort "no GitHub release yet. Push a v*.*.* tag, or run from source (see README)."
fi

DMG_URLS="$(printf '%s' "$JSON" | grep -o 'https://github.com/[^"]*\.dmg' || true)"
[ -n "$DMG_URLS" ] || abort "latest release has no .dmg. See https://github.com/${REPO}/releases/latest"

URL=""
while IFS= read -r candidate; do
  [ -z "$candidate" ] && continue
  case "$ARCH" in
    arm64)
      printf '%s' "$candidate" | grep -q arm64 && URL="$candidate" && break
      ;;
    x86_64)
      printf '%s' "$candidate" | grep -qE 'x64|x86_64' && URL="$candidate" && break
      ;;
  esac
done <<EOF
$DMG_URLS
EOF
if [ -z "$URL" ]; then
  URL="$(printf '%s\n' "$DMG_URLS" | sed -n '1p')"
fi
[ -n "$URL" ] || abort "could not pick a .dmg from the latest release"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cookbook-install.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "${MOUNT:-}" ]; then
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

DMG="${TMP}/Cookbook.dmg"
ohai "Downloading $(basename "$URL")…"
curl -fL --progress-bar -o "$DMG" "$URL" || abort "download failed"
xattr -cr "$DMG" 2>/dev/null || true

ohai "Installing to ${DEST}…"
MOUNT="$(hdiutil attach -nobrowse -noverify "$DMG" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | sed -n '$p')"
[ -n "$MOUNT" ] && [ -d "$MOUNT" ] || abort "could not mount the disk image"

APP="$(find "$MOUNT" -maxdepth 1 -name "*.app" -type d | sed -n '1p')"
[ -n "$APP" ] || abort "Cookbook.app not found inside the disk image"

mkdir -p "$DEST_DIR"
if [ -d "$DEST" ]; then
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    abort "${APP_NAME} is running. Quit it and paste the install command again."
  fi
  rm -rf "$DEST"
fi
ditto "$APP" "$DEST"
xattr -cr "$DEST"

ohai "Launching ${APP_NAME}…"
open "$DEST"

printf "\nInstalled to %s\nDouble-click it from there next time, or drag it to /Applications.\n" "$DEST"
