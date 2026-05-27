.PHONY: help build bundle run install uninstall clean release-signed sign-check tests

APP_NAME        := Logos
BINARY_NAME     := Logos
BUILD_DIR       := .build
RELEASE_BIN     := $(BUILD_DIR)/release/$(BINARY_NAME)
APP_BUNDLE      := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_PATH    := /Applications/$(APP_NAME).app

# Developer ID notarization config (from ~/.claude/CLAUDE.md).
# Override at command line: make release-signed DEVELOPER_ID=...
DEVELOPER_ID    ?= F2523DCF6D02BE99B67C7D27F633119292DA4934
NOTARY_PROFILE  ?= che-mcps-notary

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

tests: ## Run swift test
	swift test

build: ## Release build
	swift build -c release

bundle: build ## Build + assemble .app bundle (ad-hoc signed)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp $(RELEASE_BIN) $(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@echo "APPL????" > $(APP_BUNDLE)/Contents/PkgInfo
	@codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "✓ Bundle ready at $(APP_BUNDLE)"

run: bundle ## Build + bundle + open
	@open $(APP_BUNDLE)

install: bundle ## Build + bundle + install to /Applications (replaces existing)
	@if [ -d "$(INSTALL_PATH)" ]; then \
		echo "Removing existing $(INSTALL_PATH)..."; \
		rm -rf "$(INSTALL_PATH)"; \
	fi
	@cp -R $(APP_BUNDLE) $(INSTALL_PATH)
	@echo "✓ Installed at $(INSTALL_PATH)"
	@echo "  Launch via Spotlight (cmd+space → Logos) or Finder → Applications"

uninstall: ## Remove from /Applications
	@if [ -d "$(INSTALL_PATH)" ]; then \
		rm -rf "$(INSTALL_PATH)"; \
		echo "✓ Removed $(INSTALL_PATH)"; \
	else \
		echo "Not installed."; \
	fi

clean: ## Remove all build artifacts
	rm -rf $(BUILD_DIR)
	@echo "✓ Cleaned"

# --- Signed + notarized for distribution -------------------------------------

release-signed: build ## Build + Developer ID sign + notarize + create .dmg
	@if ! security find-identity -p codesigning -v | grep -q "$(DEVELOPER_ID)"; then \
		echo "✗ Developer ID cert $(DEVELOPER_ID) not found in keychain."; \
		echo "  See ~/.claude/CLAUDE.md → Apple Developer / Notarization Pipeline"; \
		exit 1; \
	fi
	@if ! xcrun notarytool history --keychain-profile $(NOTARY_PROFILE) > /dev/null 2>&1; then \
		echo "✗ Notary profile '$(NOTARY_PROFILE)' missing or stale."; \
		echo "  Run: xcrun notarytool store-credentials $(NOTARY_PROFILE)"; \
		exit 1; \
	fi
	@echo "→ Building signed bundle..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp $(RELEASE_BIN) $(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@echo "APPL????" > $(APP_BUNDLE)/Contents/PkgInfo
	@codesign --force --deep --options runtime \
		--sign "$(DEVELOPER_ID)" \
		--timestamp \
		$(APP_BUNDLE)
	@echo "→ Creating .dmg..."
	@DMG_PATH=$(BUILD_DIR)/$(APP_NAME).dmg && rm -f $$DMG_PATH && \
		hdiutil create -volname "$(APP_NAME)" -srcfolder $(APP_BUNDLE) -ov -format UDZO $$DMG_PATH
	@echo "→ Submitting to Apple notary (takes 1-5 min)..."
	@xcrun notarytool submit $(BUILD_DIR)/$(APP_NAME).dmg \
		--keychain-profile $(NOTARY_PROFILE) \
		--wait
	@echo "→ Stapling notarization ticket..."
	@xcrun stapler staple $(APP_BUNDLE)
	@xcrun stapler staple $(BUILD_DIR)/$(APP_NAME).dmg
	@echo "✓ Done. Distribute: $(BUILD_DIR)/$(APP_NAME).dmg"

sign-check: ## Verify signature on current bundle
	@codesign --verify --verbose $(APP_BUNDLE) 2>&1
	@spctl --assess --type execute --verbose $(APP_BUNDLE) 2>&1 || true
