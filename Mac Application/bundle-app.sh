#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

EXEC=""
if [ $# -ge 1 ] && [ -n "$1" ]; then
    EXEC="$1"
elif [ -f "$SCRIPT_DIR/.build/debug/Zraw2DNG" ]; then
    EXEC="$SCRIPT_DIR/.build/debug/Zraw2DNG"
elif [ -f "$SCRIPT_DIR/.build/release/Zraw2DNG" ]; then
    EXEC="$SCRIPT_DIR/.build/release/Zraw2DNG"
else
    echo "Error: Zraw2DNG executable not found"
    echo "Build first with: swift build"
    exit 1
fi

BUNDLE_DIR="$SCRIPT_DIR/Zraw2DNG.app"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$EXEC" "$BUNDLE_DIR/Contents/MacOS/Zraw2DNG"

# Bundle libcrypto.3.dylib (needed by libzraw) and set @rpath
LIB_CRYPTO="/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"
if [ -f "$LIB_CRYPTO" ]; then
    mkdir -p "$BUNDLE_DIR/Contents/Frameworks"
    cp "$LIB_CRYPTO" "$BUNDLE_DIR/Contents/Frameworks/libcrypto.3.dylib"
    chmod 644 "$BUNDLE_DIR/Contents/Frameworks/libcrypto.3.dylib"
    install_name_tool -id @rpath/libcrypto.3.dylib "$BUNDLE_DIR/Contents/Frameworks/libcrypto.3.dylib"
    install_name_tool -change "$LIB_CRYPTO" @rpath/libcrypto.3.dylib "$BUNDLE_DIR/Contents/MacOS/Zraw2DNG"
    install_name_tool -add_rpath @loader_path/../Frameworks "$BUNDLE_DIR/Contents/MacOS/Zraw2DNG"
fi

ICON="$SCRIPT_DIR/Zraw2DNG.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
fi

PLIST="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>CFBundleExecutable</key>
    <string>Zraw2DNG</string>
    <key>CFBundleIdentifier</key>
    <string>com.storyboardcreativity.Zraw2DNG</string>
    <key>CFBundleName</key>
    <string>Zraw2DNG</string>
    <key>CFBundleVersion</key>
    <string>1.0.4</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.4</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>"
echo "$PLIST" > "$BUNDLE_DIR/Contents/Info.plist"

# Strip quarantine/Spotlight extended attributes and ad-hoc sign the bundle
xattr -cr "$BUNDLE_DIR"
if [ -d "$BUNDLE_DIR/Contents/Frameworks" ]; then
    codesign --force --sign - "$BUNDLE_DIR/Contents/Frameworks/libcrypto.3.dylib"
fi
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "Created: $BUNDLE_DIR"
