#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-$PROJECT_DIR/ClaudeIsland.xcodeproj}"
SCHEME="${SCHEME:-ClaudeIsland}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/ClaudeIslandDerivedData-make-up}"

BUNDLE_ID="${BUNDLE_ID:-com.celestial.ClaudeIsland}"
APP_NAME="${APP_NAME:-Claude Island.app}"

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"

echo "==> Building ($CONFIGURATION)"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  echo "ERROR: Built app not found: $BUILT_APP" >&2
  exit 1
fi

resolve_installed_app_path() {
  osascript - "$BUNDLE_ID" <<'APPLESCRIPT'
on run argv
  try
    set bundleId to item 1 of argv
    set appPath to POSIX path of (path to application id bundleId)
    if appPath is missing value then return ""
    return appPath
  on error
    return ""
  end try
end run
APPLESCRIPT
}

quit_app() {
  osascript - "$BUNDLE_ID" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  try
    tell application id (item 1 of argv) to quit
  end try
end run
APPLESCRIPT
}

INSTALLED_APP="$(resolve_installed_app_path | sed -e 's:/*$::')"
if [[ -z "$INSTALLED_APP" ]]; then
  for candidate in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"; do
    if [[ -d "$candidate" ]]; then
      INSTALLED_APP="$candidate"
      break
    fi
  done
fi
if [[ -z "$INSTALLED_APP" ]]; then
  INSTALLED_APP="/Applications/$APP_NAME"
fi

if [[ "$INSTALLED_APP" != *.app ]]; then
  echo "ERROR: Refusing to install to unexpected path: $INSTALLED_APP" >&2
  exit 1
fi

echo "==> Install target: $INSTALLED_APP"

echo "==> Quitting running app (best effort)"
quit_app

for _ in {1..40}; do
  if ! pgrep -x "${APP_NAME%.app}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if pgrep -x "${APP_NAME%.app}" >/dev/null 2>&1; then
  echo "==> App still running; forcing quit"
  killall "${APP_NAME%.app}" >/dev/null 2>&1 || true
  sleep 0.5
fi

echo "==> Installing new build"
TMP_APP="${INSTALLED_APP}.tmp"
rm -rf "$TMP_APP"
ditto "$BUILT_APP" "$TMP_APP"
rm -rf "$INSTALLED_APP"
mkdir -p "$(dirname "$INSTALLED_APP")"
mv "$TMP_APP" "$INSTALLED_APP"

echo "==> Launching"
open "$INSTALLED_APP"

echo "==> Done"

