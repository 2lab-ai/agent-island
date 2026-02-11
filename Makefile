.PHONY: up deploy install install-cauth setup-tools bump-version

APP_NAME ?= Agent Island.app
BUNDLE_ID ?= ai.2lab.AgentIsalnd
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
	@killall "Agent Island" >/dev/null 2>&1 || true
	@sleep 1
	rm -rf "$(INSTALL_PATH).tmp"
	ditto "$(BUILT_APP)" "$(INSTALL_PATH).tmp"
	rm -rf "$(INSTALL_PATH)"
	mkdir -p "$(INSTALL_DIR)"
	mv "$(INSTALL_PATH).tmp" "$(INSTALL_PATH)"
	open "$(INSTALL_PATH)"

deploy:
	bash scripts/bump-marketing-version.sh
	bash scripts/build.sh
	DEPLOY_NONINTERACTIVE=1 DEPLOY_SKIP_WEBSITE=1 bash scripts/create-release.sh

install: install-cauth

install-cauth:
	bash scripts/install-cauth.sh

bump-version:
	bash scripts/bump-marketing-version.sh

setup-tools:
	bash scripts/ensure-tools.sh "$(TOOLS_MODE)"

up: TOOLS_MODE=up
up: setup-tools

deploy: TOOLS_MODE=deploy
deploy: setup-tools
