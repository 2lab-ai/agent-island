#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CAUTH_DIR="$ROOT_DIR/cauth"
BIN_SRC="$CAUTH_DIR/target/release/cauth"

if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo is not installed or not in PATH." >&2
  echo "Install Rust toolchain first, then run make install again." >&2
  exit 1
fi

echo "Building cauth (release)..."
cargo build --manifest-path "$CAUTH_DIR/Cargo.toml" --release

if [ ! -x "$BIN_SRC" ]; then
  echo "ERROR: build completed but binary not found at $BIN_SRC" >&2
  exit 1
fi

TARGET_DIR="${CAUTH_INSTALL_DIR:-}"
if [ -z "$TARGET_DIR" ]; then
  for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.cargo/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then
      TARGET_DIR="$candidate"
      break
    fi
  done
fi

if [ -z "$TARGET_DIR" ]; then
  TARGET_DIR="$HOME/.local/bin"
fi

mkdir -p "$TARGET_DIR"
if [ ! -w "$TARGET_DIR" ]; then
  echo "ERROR: install dir is not writable: $TARGET_DIR" >&2
  echo "Set CAUTH_INSTALL_DIR to a writable directory and retry." >&2
  exit 1
fi

install -m 0755 "$BIN_SRC" "$TARGET_DIR/cauth"
echo "Installed: $TARGET_DIR/cauth"

case ":$PATH:" in
  *":$TARGET_DIR:"*)
    echo "PATH check: OK ($TARGET_DIR is already in PATH)"
    ;;
  *)
    echo "PATH check: $TARGET_DIR is not in PATH."
    echo "Add it with:"
    echo "  export PATH=\"$TARGET_DIR:\$PATH\""
    ;;
esac

if command -v cauth >/dev/null 2>&1; then
  echo "Resolved cauth: $(command -v cauth)"
  echo "Smoke test:"
  cauth help >/dev/null
  echo "cauth help: OK"
else
  echo "cauth not found in current PATH yet."
fi
