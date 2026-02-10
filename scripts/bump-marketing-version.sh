#!/bin/bash
# Increment MARKETING_VERSION patch and CURRENT_PROJECT_VERSION build number
# in the Xcode project file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PBXPROJ_PATH="${PBXPROJ_PATH:-$PROJECT_DIR/ClaudeIsland.xcodeproj/project.pbxproj}"
DRY_RUN="${DRY_RUN:-0}"

if [ ! -f "$PBXPROJ_PATH" ]; then
    echo "ERROR: project file not found: $PBXPROJ_PATH" >&2
    exit 1
fi

CURRENT_VERSION="$(
    awk '
        match($0, /MARKETING_VERSION = [0-9]+(\.[0-9]+){0,2};/) {
            value = $0
            sub(/^.*MARKETING_VERSION = /, "", value)
            sub(/;.*$/, "", value)
            print value
            exit
        }
    ' "$PBXPROJ_PATH"
)"

if [ -z "$CURRENT_VERSION" ]; then
    echo "ERROR: MARKETING_VERSION not found in $PBXPROJ_PATH" >&2
    exit 1
fi

CURRENT_BUILD="$(
    awk '
        match($0, /CURRENT_PROJECT_VERSION = [0-9]+;/) {
            value = $0
            sub(/^.*CURRENT_PROJECT_VERSION = /, "", value)
            sub(/;.*$/, "", value)
            print value
            exit
        }
    ' "$PBXPROJ_PATH"
)"

if [ -z "$CURRENT_BUILD" ]; then
    echo "ERROR: CURRENT_PROJECT_VERSION not found in $PBXPROJ_PATH" >&2
    exit 1
fi

if ! [[ "$CURRENT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "ERROR: unsupported MARKETING_VERSION format: $CURRENT_VERSION" >&2
    echo "Expected numeric version like 1.2 or 1.2.3" >&2
    exit 1
fi

if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unsupported CURRENT_PROJECT_VERSION format: $CURRENT_BUILD" >&2
    echo "Expected integer build number like 3" >&2
    exit 1
fi

IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
major="${major:-0}"
minor="${minor:-0}"
patch="${patch:-0}"

if [ -z "$minor" ]; then
    minor=0
fi
if [ -z "$patch" ]; then
    patch=0
fi

if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid numeric version parts in $CURRENT_VERSION" >&2
    exit 1
fi

NEXT_PATCH=$((patch + 1))
NEXT_VERSION="$major.$minor.$NEXT_PATCH"
NEXT_BUILD=$((CURRENT_BUILD + 1))

if [ "$DRY_RUN" = "1" ]; then
    echo "Current MARKETING_VERSION: $CURRENT_VERSION"
    echo "Next MARKETING_VERSION: $NEXT_VERSION"
    echo "Current CURRENT_PROJECT_VERSION: $CURRENT_BUILD"
    echo "Next CURRENT_PROJECT_VERSION: $NEXT_BUILD"
    exit 0
fi

TMP_FILE="$(mktemp "$PROJECT_DIR/.tmp.pbxproj.XXXXXX")"
cleanup_tmp() {
    rm -f "$TMP_FILE"
}
trap cleanup_tmp EXIT

awk -v next_marketing="$NEXT_VERSION" -v next_build="$NEXT_BUILD" '
    BEGIN {
        replaced_marketing = 0
        replaced_build = 0
    }
    {
        if ($0 ~ /MARKETING_VERSION = [0-9]+(\.[0-9]+){0,2};/) {
            sub(/MARKETING_VERSION = [0-9]+(\.[0-9]+){0,2};/, "MARKETING_VERSION = " next_marketing ";")
            replaced_marketing++
        }
        if ($0 ~ /CURRENT_PROJECT_VERSION = [0-9]+;/) {
            sub(/CURRENT_PROJECT_VERSION = [0-9]+;/, "CURRENT_PROJECT_VERSION = " next_build ";")
            replaced_build++
        }
        print
    }
    END {
        if (replaced_marketing == 0 || replaced_build == 0) {
            exit 2
        }
    }
' "$PBXPROJ_PATH" > "$TMP_FILE" || {
    status=$?
    if [ "$status" -eq 2 ]; then
        echo "ERROR: version replacement failed in $PBXPROJ_PATH" >&2
    fi
    exit "$status"
}

mv "$TMP_FILE" "$PBXPROJ_PATH"
trap - EXIT
cleanup_tmp

echo "Bumped MARKETING_VERSION: $CURRENT_VERSION -> $NEXT_VERSION"
echo "Bumped CURRENT_PROJECT_VERSION: $CURRENT_BUILD -> $NEXT_BUILD"
