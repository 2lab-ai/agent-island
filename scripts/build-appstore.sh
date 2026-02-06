#!/bin/bash
# Build Agent Island for Mac App Store submission
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build-appstore"
ARCHIVE_PATH="$BUILD_DIR/AgentIsland.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

echo "=== Building Agent Island for App Store ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Build and archive with App Store signing
echo "Archiving for App Store..."
xcodebuild archive \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    ENABLE_APP_SANDBOX=YES \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_ENTITLEMENTS=ClaudeIsland/Resources/AgentIsland-AppStore.entitlements \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE' \
    | xcpretty || xcodebuild archive \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    ENABLE_APP_SANDBOX=YES \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_ENTITLEMENTS=ClaudeIsland/Resources/AgentIsland-AppStore.entitlements \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APPSTORE'

# Create ExportOptions.plist for App Store
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

# Export the archive
echo ""
echo "Exporting for App Store..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | xcpretty || xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

echo ""
echo "=== App Store Build Complete ==="
echo ""
echo "Exported to: $EXPORT_PATH/"
echo ""

# Validate the build
echo "=== Validating ==="
if command -v xcrun &> /dev/null; then
    PKG_PATH=$(find "$EXPORT_PATH" -name "*.pkg" -o -name "*.ipa" | head -1)
    if [ -n "$PKG_PATH" ]; then
        echo "Validating $PKG_PATH..."
        xcrun altool --validate-app -f "$PKG_PATH" -t macos --output-format xml 2>&1 || true
        echo ""
        echo "To upload to App Store Connect:"
        echo "  xcrun altool --upload-app -f \"$PKG_PATH\" -t macos"
        echo ""
        echo "Or use Transporter.app to upload the package."
    else
        echo "No .pkg found. Open the archive in Xcode Organizer to upload:"
        echo "  open \"$ARCHIVE_PATH\""
    fi
fi

echo ""
echo "=== Next Steps ==="
echo "1. Log in to App Store Connect (https://appstoreconnect.apple.com)"
echo "2. Select 'Agent Island' app"
echo "3. Upload the build via Xcode Organizer or Transporter"
echo "4. Add screenshots and metadata"
echo "5. Submit for review"
