.PHONY: up

APP_NAME ?= Claude Island.app
BUNDLE_ID ?= com.celestial.ClaudeIsland
PROJECT ?= ClaudeIsland.xcodeproj
SCHEME ?= ClaudeIsland
CONFIGURATION ?= Release
DERIVED_DATA ?= /tmp/ClaudeIslandDerivedData-make-up
INSTALL_DIR ?= /Applications
INSTALL_PATH ?= $(INSTALL_DIR)/$(APP_NAME)
BUILT_APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME)

up:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -derivedDataPath "$(DERIVED_DATA)" build
	@if [ ! -d "$(BUILT_APP)" ]; then echo "ERROR: built app not found: $(BUILT_APP)" >&2; exit 1; fi
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@killall "Claude Island" >/dev/null 2>&1 || true
	@sleep 1
	rm -rf "$(INSTALL_PATH).tmp"
	ditto "$(BUILT_APP)" "$(INSTALL_PATH).tmp"
	rm -rf "$(INSTALL_PATH)"
	mkdir -p "$(INSTALL_DIR)"
	mv "$(INSTALL_PATH).tmp" "$(INSTALL_PATH)"
	open "$(INSTALL_PATH)"
