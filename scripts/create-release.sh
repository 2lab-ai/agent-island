#!/bin/bash
# Create a release: notarize, create DMG, sign for Sparkle, upload to GitHub, update website
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="$PROJECT_DIR/releases"
APPCAST_DIR="$RELEASE_DIR/appcast"
APPCAST_XML_PATH="$APPCAST_DIR/appcast.xml"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"

# Website repo for auto-updating appcast
WEBSITE_DIR="${AGENT_ISLAND_WEBSITE:-$PROJECT_DIR/../AgentIsland-website}"
WEBSITE_PUBLIC="$WEBSITE_DIR/public"

APP_PATH="$EXPORT_PATH/Agent Island.app"
APP_NAME="AgentIsland"
KEYCHAIN_PROFILE="AgentIsland"
DEPLOY_NONINTERACTIVE="${DEPLOY_NONINTERACTIVE:-0}"
DEPLOY_SKIP_WEBSITE="${DEPLOY_SKIP_WEBSITE:-0}"

# Load Homebrew environment for non-login shells.
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_github_repo() {
    if [ -n "${AGENT_ISLAND_GITHUB_REPO:-}" ]; then
        echo "$AGENT_ISLAND_GITHUB_REPO"
        return
    fi

    local origin_url repo
    origin_url="$(git -C "$PROJECT_DIR" config --get remote.origin.url 2>/dev/null || true)"
    case "$origin_url" in
        git@github.com:*)
            repo="${origin_url#git@github.com:}"
            ;;
        https://github.com/*)
            repo="${origin_url#https://github.com/}"
            ;;
        http://github.com/*)
            repo="${origin_url#http://github.com/}"
            ;;
        *)
            repo="icedac/agent-island"
            ;;
    esac
    repo="${repo%.git}"
    echo "$repo"
}

GITHUB_REPO="$(resolve_github_repo)"

echo "=== Creating Release ==="
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    echo "Run ./scripts/build.sh first"
    exit 1
fi

# Get version from app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo "Version: $VERSION (build $BUILD)"
echo ""

mkdir -p "$RELEASE_DIR"

# ============================================
# Step 1: Notarize the app
# ============================================
echo "=== Step 1: Notarizing ==="

# Check if keychain profile exists
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
    echo ""
    echo "No keychain profile found. Set up credentials with:"
    echo ""
    echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "      --apple-id \"your@email.com\" \\"
    echo "      --team-id \"2DKS5U9LV4\" \\"
    echo "      --password \"xxxx-xxxx-xxxx-xxxx\""
    echo ""
    echo "Create an app-specific password at: https://appleid.apple.com"
    echo ""
    if is_true "$DEPLOY_NONINTERACTIVE"; then
        SKIP_NOTARIZATION=true
        echo "Non-interactive mode: skipping notarization (no keychain profile)."
        echo "WARNING: Users will see Gatekeeper warnings!"
    else
        read -p "Skip notarization for now? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
        SKIP_NOTARIZATION=true
        echo "WARNING: Skipping notarization. Users will see Gatekeeper warnings!"
    fi
else
    # Create zip for notarization
    ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    echo "Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    echo "Submitting for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    rm "$ZIP_PATH"
    echo "Notarization complete!"
fi

echo ""

# ============================================
# Step 2: Create DMG
# ============================================
echo "=== Step 2: Creating DMG ==="

DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

# Remove existing DMG if present
if [ -f "$DMG_PATH" ]; then
    echo "Removing existing DMG..."
    rm -f "$DMG_PATH"
fi

# Check if create-dmg is available (prettier DMG)
if command -v create-dmg &> /dev/null; then
    echo "Using create-dmg for prettier output..."
    create-dmg \
        --volname "Agent Island" \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "Agent Island.app" 150 200 \
        --app-drop-link 450 200 \
        --hide-extension "Agent Island.app" \
        "$DMG_PATH" \
        "$APP_PATH"
else
    echo "Using hdiutil (install create-dmg for prettier DMG: brew install create-dmg)"
    DMG_STAGING_DIR="$(mktemp -d "$BUILD_DIR/dmg-staging.XXXXXX")"
    cleanup_dmg_staging() {
        rm -rf "$DMG_STAGING_DIR"
    }
    trap cleanup_dmg_staging EXIT

    ditto "$APP_PATH" "$DMG_STAGING_DIR/Agent Island.app"
    ln -s /Applications "$DMG_STAGING_DIR/Applications"

    hdiutil create -volname "Agent Island" \
        -srcfolder "$DMG_STAGING_DIR" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

echo "DMG created: $DMG_PATH"
echo ""

# ============================================
# Step 3: Notarize the DMG
# ============================================
if [ -z "$SKIP_NOTARIZATION" ]; then
    echo "=== Step 3: Notarizing DMG ==="

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "DMG notarized!"
    echo ""
fi

# ============================================
# Step 4: Sign for Sparkle and generate appcast
# ============================================
echo "=== Step 4: Signing for Sparkle ==="

# Find Sparkle tools
SPARKLE_SIGN=""
GENERATE_APPCAST=""

POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path/sign_update" ]; then
            SPARKLE_SIGN="$path/sign_update"
            GENERATE_APPCAST="$path/generate_appcast"
            break 2
        fi
    done
done

if [ -z "$SPARKLE_SIGN" ]; then
    echo "ERROR: Could not find Sparkle tools."
    echo "Build the project in Xcode first to download Sparkle package."
    exit 1
else
    SIGN_ARGS=()
    APPCAST_ARGS=()

    if [ -f "$KEYS_DIR/eddsa_private_key" ]; then
        SIGN_ARGS=(--ed-key-file "$KEYS_DIR/eddsa_private_key")
        APPCAST_ARGS=(--ed-key-file "$KEYS_DIR/eddsa_private_key")
        echo "Using Sparkle private key file: $KEYS_DIR/eddsa_private_key"
    else
        echo "No private key file found at $KEYS_DIR/eddsa_private_key"
        echo "Trying Sparkle key from macOS Keychain account 'ed25519'..."
    fi

    # Generate signature
    echo "Signing DMG for Sparkle..."
    if ! SIGNATURE=$("$SPARKLE_SIGN" "${SIGN_ARGS[@]}" "$DMG_PATH"); then
        echo "ERROR: Sparkle signing failed."
        echo "Provide $KEYS_DIR/eddsa_private_key or configure Keychain key account 'ed25519'."
        echo "Run ./scripts/generate-keys.sh if needed."
        exit 1
    fi

    echo ""
    echo "Sparkle signature:"
    echo "$SIGNATURE"
    echo ""

    # Generate/update appcast
    echo "Generating appcast..."
    mkdir -p "$APPCAST_DIR"

    # Copy DMG to appcast directory
    cp "$DMG_PATH" "$APPCAST_DIR/"

    # Generate appcast.xml
    if ! "$GENERATE_APPCAST" "${APPCAST_ARGS[@]}" "$APPCAST_DIR"; then
        echo "ERROR: appcast generation failed."
        echo "Provide $KEYS_DIR/eddsa_private_key or configure Keychain key account 'ed25519'."
        echo "Run ./scripts/generate-keys.sh if needed."
        exit 1
    fi

    echo "Appcast generated at: $APPCAST_XML_PATH"
fi

echo ""

# ============================================
# Step 5: Create GitHub Release
# ============================================
echo "=== Step 5: Creating GitHub Release ==="

if ! command -v gh &> /dev/null; then
    echo "WARNING: gh CLI not found. Install with: brew install gh"
    echo "Skipping GitHub release."
else
    if [ ! -f "$APPCAST_XML_PATH" ]; then
        echo "ERROR: appcast missing at $APPCAST_XML_PATH"
        echo "Sparkle appcast is required so Check for Updates can find GitHub releases."
        exit 1
    fi

    GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
    GITHUB_APPCAST_URL="https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"

    # Ensure appcast points to this version's GitHub-hosted DMG.
    sed -i '' "s|url=\"[^\"]*\\.dmg\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$APPCAST_XML_PATH"

    # Check if release already exists
    if gh release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
        echo "Release v$VERSION already exists. Updating..."
        gh release upload "v$VERSION" "$DMG_PATH" "$APPCAST_XML_PATH" --repo "$GITHUB_REPO" --clobber
    else
        echo "Creating release v$VERSION..."
        gh release create "v$VERSION" "$DMG_PATH" "$APPCAST_XML_PATH" \
            --repo "$GITHUB_REPO" \
            --title "Agent Island v$VERSION" \
            --notes "## Agent Island v$VERSION

### Installation
1. Download \`$APP_NAME-$VERSION.dmg\`
2. Open the DMG and drag Agent Island to Applications
3. Launch Agent Island from Applications

### Auto-updates
After installation, Agent Island will automatically check for updates."
    fi

    echo "GitHub release created: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
    echo "Download URL: $GITHUB_DOWNLOAD_URL"
    echo "Sparkle feed URL: $GITHUB_APPCAST_URL"
fi

echo ""

# ============================================
# Step 6: Update website appcast and deploy
# ============================================
echo "=== Step 6: Updating Website ==="

if is_true "$DEPLOY_SKIP_WEBSITE"; then
    echo "Skipping website update (DEPLOY_SKIP_WEBSITE=$DEPLOY_SKIP_WEBSITE)."
elif [ -d "$WEBSITE_PUBLIC" ] && [ -f "$APPCAST_XML_PATH" ]; then
    # Copy appcast to website
    cp "$APPCAST_XML_PATH" "$WEBSITE_PUBLIC/appcast.xml"

    # Update the download URL in appcast to point to GitHub releases
    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        sed -i '' "s|url=\"[^\"]*$APP_NAME-$VERSION.dmg\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$WEBSITE_PUBLIC/appcast.xml"
        echo "Updated appcast.xml with GitHub download URL"
    fi

    # Update src/config.ts with latest version and download URL
    CONFIG_FILE="$WEBSITE_DIR/src/config.ts"
    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        cat > "$CONFIG_FILE" << EOF
// Auto-updated by create-release.sh
export const LATEST_VERSION = "$VERSION";
export const DOWNLOAD_URL = "$GITHUB_DOWNLOAD_URL";
EOF
        echo "Updated src/config.ts with version $VERSION"
    fi

    # Commit and push website changes
    cd "$WEBSITE_DIR"
    if [ -d ".git" ]; then
        git add public/appcast.xml src/config.ts
        if ! git diff --cached --quiet; then
            git commit -m "Update appcast for v$VERSION"
            echo "Committed appcast update"

            if is_true "$DEPLOY_NONINTERACTIVE"; then
                git push
                echo "Website deployed (non-interactive mode)."
            else
                read -p "Push website changes to deploy? (Y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                    git push
                    echo "Website deployed!"
                else
                    echo "Changes committed but not pushed. Run 'git push' in $WEBSITE_DIR to deploy."
                fi
            fi
        else
            echo "No changes to commit"
        fi
    else
        echo "Copied appcast.xml to $WEBSITE_PUBLIC/"
        echo "Note: Website directory is not a git repo"
    fi
    cd "$PROJECT_DIR"
else
    echo "Website directory not found or appcast not generated"
    echo "Skipping website update."
fi

echo ""

echo "=== Release Complete ==="
echo ""
echo "Files created:"
echo "  - DMG: $DMG_PATH"
if [ -f "$APPCAST_XML_PATH" ]; then
    echo "  - Appcast: $APPCAST_XML_PATH"
fi
if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
    echo "  - GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
fi
if [ -f "$WEBSITE_PUBLIC/appcast.xml" ]; then
    echo "  - Website: $WEBSITE_PUBLIC/appcast.xml"
fi
