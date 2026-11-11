#!/bin/bash
# Installs the built saver into ~/Library/Screen Savers and restarts the host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/Evolving.saver"
DEST_DIR="$HOME/Library/Screen Savers"
DEST="$DEST_DIR/Evolving.saver"

if [[ ! -d "$SRC" ]]; then
  echo "No build found at $SRC — run Scripts/build.sh first." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# Drop the cached copy so System Settings picks up the new build.
killall ScreenSaverEngine 2>/dev/null || true
defaults delete com.apple.screensaver.Evolving 2>/dev/null || true

APP_SRC="$ROOT/build/Evolving Companion.app"
APP_DIR="$HOME/Applications"
APP_DEST="$APP_DIR/Evolving Companion.app"

if [[ -d "$APP_SRC" ]]; then
  mkdir -p "$APP_DIR"
  rm -rf "$APP_DEST"
  cp -R "$APP_SRC" "$APP_DEST"
  echo "Installed: $APP_DEST"
fi

PLAYER_SRC="$ROOT/build/Evolving Player.app"
PLAYER_DEST="$APP_DIR/Evolving Player.app"
if [[ -d "$PLAYER_SRC" ]]; then
  mkdir -p "$APP_DIR"
  rm -rf "$PLAYER_DEST"
  cp -R "$PLAYER_SRC" "$PLAYER_DEST"
  echo "Installed: $PLAYER_DEST"
fi

TIMELINE_SRC="$ROOT/build/Evolving Timeline.app"
TIMELINE_DEST="$APP_DIR/Evolving Timeline.app"
if [[ -d "$TIMELINE_SRC" ]]; then
  mkdir -p "$APP_DIR"
  rm -rf "$TIMELINE_DEST"
  cp -R "$TIMELINE_SRC" "$TIMELINE_DEST"
  echo "Installed: $TIMELINE_DEST"
fi

echo
echo "Installed: $DEST"
echo
echo "Open System Settings → Screen Saver and pick “Evolving”."
echo "If it does not appear, quit System Settings completely and reopen it."
