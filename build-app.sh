#!/bin/bash
# Build Shepherd.app bundle from the SPM executable
set -euo pipefail

cd "$(dirname "$0")"

echo "Building ShepherdApp (universal)..."
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1

# Universal builds land under .build/apple/Products/Release; locate the products.
BINARY="$(find .build/apple/Products -name ShepherdApp -type f 2>/dev/null | head -1)"
MCP_BINARY="$(find .build/apple/Products -name herdr-manager-mcp -type f 2>/dev/null | head -1)"
[ -n "$BINARY" ] || BINARY=".build/release/ShepherdApp"
[ -n "$MCP_BINARY" ] || MCP_BINARY=".build/release/herdr-manager-mcp"
APP_DIR="Shepherd.app"

echo "Creating $APP_DIR bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Helpers"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy the app and its local MCP helper. Keeping the MCP executable inside the
# bundle gives ChatGPT Desktop/Codex a stable command path across clean builds.
cp "$BINARY" "$APP_DIR/Contents/MacOS/Shepherd"
cp "$MCP_BINARY" "$APP_DIR/Contents/Helpers/herdr-manager-mcp"

# Copy app icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Shepherd</string>
    <key>CFBundleDisplayName</key>
    <string>Shepherd</string>
    <key>CFBundleIdentifier</key>
    <string>com.shepherd.app</string>
    <key>CFBundleVersion</key>
    <string>0.1.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.1</string>
    <key>CFBundleExecutable</key>
    <string>Shepherd</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

# Sign with a Developer ID identity (hardened runtime + secure timestamp,
# required for notarization) when one is available; fall back to ad-hoc for
# local-only builds. Override with SIGN_IDENTITY="..." if needed.
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)".*/\1/')"
IDENTITY="${SIGN_IDENTITY:-$DEV_ID}"
if [ -n "$IDENTITY" ]; then
    echo "Signing $APP_DIR with Developer ID: $IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_DIR/Contents/Helpers/herdr-manager-mcp"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_DIR"
else
    echo "Signing $APP_DIR ad-hoc for local use..."
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "✅ $APP_DIR created"
echo "   Launch: open $APP_DIR"
echo "   Or:     $APP_DIR/Contents/MacOS/Shepherd"
echo "   MCP:    $APP_DIR/Contents/Helpers/herdr-manager-mcp"
