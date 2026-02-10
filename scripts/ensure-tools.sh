#!/bin/bash
# Ensure required local tools are installed for make targets.
set -euo pipefail

MODE="${1:-deploy}"

load_brew_shellenv() {
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        return
    fi
    if [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

ensure_brew() {
    load_brew_shellenv
    if command -v brew >/dev/null 2>&1; then
        return
    fi

    echo "Homebrew not found. Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    load_brew_shellenv
    if ! command -v brew >/dev/null 2>&1; then
        echo "ERROR: Homebrew install failed."
        echo "Please install Homebrew manually: https://brew.sh"
        exit 1
    fi
}

ensure_formula() {
    local formula="$1"
    local command_name="${2:-$1}"

    if command -v "$command_name" >/dev/null 2>&1; then
        echo "Tool already installed: $command_name"
        return
    fi

    echo "Installing tool: $formula"
    brew install "$formula"

    load_brew_shellenv
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: '$command_name' is still missing after installing '$formula'."
        exit 1
    fi
}

ensure_xcpretty() {
    local gem_user_bin
    gem_user_bin="$(ruby -r rubygems -e 'print Gem.user_dir')/bin"
    if [ -d "$gem_user_bin" ]; then
        export PATH="$gem_user_bin:$PATH"
    fi

    if command -v xcpretty >/dev/null 2>&1; then
        echo "Tool already installed: xcpretty"
        return
    fi

    if ! command -v gem >/dev/null 2>&1; then
        echo "ERROR: RubyGems (gem) is required to install xcpretty."
        exit 1
    fi

    echo "Installing tool: xcpretty (gem)"
    gem install --user-install xcpretty --no-document

    if ! command -v xcpretty >/dev/null 2>&1; then
        echo "ERROR: xcpretty is still missing after gem install."
        echo "Add Ruby gem bin to PATH: $gem_user_bin"
        exit 1
    fi
}

main() {
    case "$MODE" in
        up)
            ensure_xcpretty
            ;;
        deploy)
            ensure_xcpretty
            ensure_brew
            ensure_formula create-dmg create-dmg
            ensure_formula gh gh
            ;;
        *)
            echo "Usage: $0 [up|deploy]"
            exit 1
            ;;
    esac
}

main
