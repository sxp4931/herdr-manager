#!/bin/bash
# Build a drag-to-Applications disk image for Shepherd.
#
# Usage: ./build-dmg.sh
#        SKIP_APP_BUILD=1 ./build-dmg.sh   # reuse an existing Shepherd.app
#
# Layout constants live in Resources/dmg/layout.json and must match the
# background generator (Tools/GenerateDMGBackground/main.swift).
set -euo pipefail

cd "$(dirname "$0")"

APP_DIR="${APP_DIR:-Shepherd.app}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/shepherd-dmg.XXXXXX")"
RW_DMG="$(mktemp -d "${TMPDIR:-/tmp}/shepherd-dmg-rw.XXXXXX")/rw.dmg"
LAYOUT="Resources/dmg/layout.json"
BACKGROUND="Resources/dmg/background.png"

cleanup() {
    if [ -n "${MOUNT:-}" ]; then
        hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGING" "$(dirname "$RW_DMG")"
}
trap cleanup EXIT

read_layout() {
    python3 - "$LAYOUT" <<'PY'
import json, sys
layout = json.load(open(sys.argv[1]))
for key in (
    "windowWidth", "windowHeight", "iconSize",
    "appX", "appY", "applicationsX", "applicationsY",
):
    print(f"{key}={layout[key]}")
PY
}

eval "$(read_layout)"

if [ "${SKIP_APP_BUILD:-}" != "1" ] || [ ! -d "$APP_DIR" ]; then
    ./build-app.sh
fi

if [ ! -d "$APP_DIR" ]; then
    echo "error: $APP_DIR is missing" >&2
    exit 1
fi

if [ ! -f "$BACKGROUND" ]; then
    echo "Generating DMG background..."
    swift Tools/GenerateDMGBackground/main.swift
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
VOLNAME="Shepherd ${VERSION}"
FINAL_DMG="Shepherd-${VERSION}.dmg"

echo "Staging ${VOLNAME}..."
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/Shepherd.app"
ln -s /Applications "$STAGING/Applications"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$STAGING/.VolumeIcon.icns"
fi

# An extra 20 MB of slack keeps the RW image writable while Finder
# writes .DS_Store; the compressed final image will be much smaller.
APP_KB="$(du -sk "$STAGING" | awk '{print $1}')"
SIZE_KB=$((APP_KB + 20480))

echo "Creating read-write disk image..."
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOLNAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${SIZE_KB}k" \
    "$RW_DMG" >/dev/null

echo "Mounting..."
# Mount without opening Finder automatically. Volume names contain spaces
# ("Shepherd 0.1.1"), so take everything from /Volumes/ to end of line.
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen -nobrowse "$RW_DMG" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)"
[ -n "$MOUNT" ] || { echo "error: failed to mount $RW_DMG" >&2; exit 1; }

# Copy the background onto the mounted volume so Finder can see it as a
# real file before we assign it. Keep .background visible until after
# the view options are written — hiding it first makes Finder return -10006.
mkdir -p "$MOUNT/.background"
cp "$BACKGROUND" "$MOUNT/.background/background.png"

if [ -f "$MOUNT/.VolumeIcon.icns" ]; then
    SetFile -c icnC "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$MOUNT" 2>/dev/null || true
fi

# Finder stores icon-view options in .DS_Store. Window bounds include the
# title bar (~32pt with the toolbar hidden); the background image fills only
# the content view, so add that chrome or the paper gets cropped and the
# chevron drifts off the icons.
TITLE_BAR_HEIGHT=32
WINDOW_RIGHT=$((200 + windowWidth))
WINDOW_BOTTOM=$((120 + windowHeight + TITLE_BAR_HEIGHT))

echo "Waiting for Finder to see the volume..."
sleep 3

echo "Applying Finder layout..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, $WINDOW_RIGHT, $WINDOW_BOTTOM}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to $iconSize
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:background.png"
        delay 0.5
        set position of item "Shepherd.app" to {$appX, $appY}
        set position of item "Applications" to {$applicationsX, $applicationsY}
        try
            set position of item ".background" to {$WINDOW_RIGHT, 100}
        end try
        close
        open
        delay 1
        set bounds of container window to {200, 120, $WINDOW_RIGHT - 10, $WINDOW_BOTTOM - 10}
        delay 0.5
        set bounds of container window to {200, 120, $WINDOW_RIGHT, $WINDOW_BOTTOM}
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Give Finder a moment to flush .DS_Store before we detach.
for _ in 1 2 3 4 5 6 7 8; do
    [ -f "$MOUNT/.DS_Store" ] && break
    sleep 1
done
sync
sleep 1
SetFile -a V "$MOUNT/.background" 2>/dev/null || chflags hidden "$MOUNT/.background"
SetFile -a V "$MOUNT/.VolumeIcon.icns" 2>/dev/null || chflags hidden "$MOUNT/.VolumeIcon.icns" || true

echo "Detaching..."
hdiutil detach "$MOUNT" -quiet
MOUNT=""

rm -f "$FINAL_DMG"
echo "Compressing $FINAL_DMG..."
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null

# Internet-enable so Safari auto-opens the window (no-op on newer macOS).
hdiutil internet-enable -yes "$FINAL_DMG" >/dev/null 2>&1 || true

DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)".*/\1/')"
IDENTITY="${SIGN_IDENTITY:-$DEV_ID}"
if [ -n "$IDENTITY" ]; then
    echo "Signing $FINAL_DMG with Developer ID: $IDENTITY"
    codesign --force --sign "$IDENTITY" "$FINAL_DMG"
fi

echo "✅ $FINAL_DMG"
echo "   Open: open \"$FINAL_DMG\""
