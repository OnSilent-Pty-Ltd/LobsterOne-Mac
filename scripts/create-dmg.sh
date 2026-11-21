#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: create-dmg.sh <app-path> <version> <output-dir>}"
VERSION="${2:?Usage: create-dmg.sh <app-path> <version> <output-dir>}"
OUTPUT_DIR="${3:-.}"
DMG_NAME="LobsterOne-${VERSION}"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}.dmg"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BG_IMG="${SCRIPT_DIR}/../installer-assets/dmg-background.png"

# DMG window dimensions — must match background image
WIN_WIDTH=660
WIN_HEIGHT=440
# Icon positions — must match background image layout
APP_ICON_X=155
APP_ICON_Y=195
APPS_ICON_X=505
APPS_ICON_Y=195
ICON_SIZE=110

STAGING_DIR=$(mktemp -d)
TEMP_DMG=$(mktemp -d)/temp.dmg

echo "Creating DMG: ${DMG_NAME} from ${APP_PATH}"

# --- Prepare staging content ---
# Preserve the signed app bundle exactly as exported. Sparkle.framework contains
# symlinks and nested signed helpers that are fragile if copied naïvely.
ditto "$APP_PATH" "$STAGING_DIR/LobsterOne.app"
ln -s /Applications "$STAGING_DIR/Applications"

# Copy background image into a hidden folder (Finder reads it from inside the volume)
mkdir -p "$STAGING_DIR/.background"
cp "$BG_IMG" "$STAGING_DIR/.background/dmg-background.png"

# --- Create read-write DMG (auto-sized from srcfolder) ---
hdiutil create \
  -volname "LobsterOne" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$TEMP_DMG"

# --- Mount and style with AppleScript ---
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | \
  grep '/Volumes/' | sed 's/.*\/Volumes/\/Volumes/')

echo "Mounted at: $MOUNT_DIR"

# Give Finder a moment to index the volume
sleep 2

echo "Applying DMG window layout..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "LobsterOne"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, $((100 + WIN_WIDTH)), $((100 + WIN_HEIGHT))}

        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to ${ICON_SIZE}
        set background picture of viewOptions to file ".background:dmg-background.png"

        -- Position icons to match background art
        set position of item "LobsterOne.app" of container window to {${APP_ICON_X}, ${APP_ICON_Y}}
        set position of item "Applications" of container window to {${APPS_ICON_X}, ${APPS_ICON_Y}}

        close
        open

        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# Ensure .DS_Store is flushed
sync

# --- Detach ---
hdiutil detach "$MOUNT_DIR" -quiet

# --- Convert to compressed read-only DMG ---
hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$DMG_PATH"

# --- Cleanup ---
rm -rf "$STAGING_DIR" "$(dirname "$TEMP_DMG")"

echo "DMG created at: $DMG_PATH"
