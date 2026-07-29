#!/bin/bash
# Build HerdrManager.app bundle from the SPM executable
set -euo pipefail

cd "$(dirname "$0")"

echo "Building HerdrManagerApp..."
swift build -c release 2>&1 | tail -1

BINARY=".build/release/HerdrManagerApp"
APP_DIR="HerdrManager.app"

echo "Creating $APP_DIR bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/HerdrManager"

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>HerdrManager</string>
    <key>CFBundleDisplayName</key>
    <string>Herdr Manager</string>
    <key>CFBundleIdentifier</key>
    <string>com.herdr.manager</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>HerdrManager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "✅ $APP_DIR created"
echo "   Launch: open $APP_DIR"
echo "   Or:     $APP_DIR/Contents/MacOS/HerdrManager"
