#!/bin/bash
# Build Shepherd.app bundle from the SPM executable
set -euo pipefail

cd "$(dirname "$0")"

echo "Building ShepherdApp..."
swift build -c release 2>&1 | tail -1

BINARY=".build/release/ShepherdApp"
APP_DIR="Shepherd.app"

echo "Creating $APP_DIR bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/Shepherd"

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
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
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

echo "Signing $APP_DIR for local use..."
codesign --force --deep --sign - "$APP_DIR"

echo "✅ $APP_DIR created"
echo "   Launch: open $APP_DIR"
echo "   Or:     $APP_DIR/Contents/MacOS/Shepherd"
