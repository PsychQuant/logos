.PHONY: help build bundle run install uninstall clean release-signed sign-check tests smoke coverage hosted-tests

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

# #101: stable signing identity for DEV bundles. Ad-hoc (`--sign -`) anchors the
# designated requirement to the CDHash, which changes on every rebuild — so a
# keychain ACL grant (永遠允許 on the claude-credentials read) can never stick and
# the authorization dialog reappears at every launch. Signing with the machine's
# Apple Development certificate anchors the requirement to Team ID + identifier,
# stable across rebuilds: authorize once, never asked again. Machines without the
# cert fall back to ad-hoc (today's behavior) with a visible warning.
DEV_SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $$2}')

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

tests: ## Run swift test
	swift test

coverage: ## Run swift test with coverage + print line % vs the 80% bar (report-only, #25)
	@swift test --enable-code-coverage
	@PROF=$$(find .build -name 'default.profdata' -path '*codecov*' | head -1); \
	 if [ -z "$$PROF" ]; then echo "⚠ could not locate SPM coverage profdata"; exit 0; fi; \
	 BIN=$$(find "$$(dirname "$$(dirname "$$PROF")")" -maxdepth 1 -name '*.xctest' -type d | head -1); \
	 if [ -z "$$BIN" ]; then echo "⚠ could not locate .xctest next to $$PROF"; exit 0; fi; \
	 EXEC="$$BIN/Contents/MacOS/$$(basename "$$BIN" .xctest)"; \
	 if ! PCT=$$(xcrun llvm-cov export -summary-only "$$EXEC" -instr-profile "$$PROF" \
	   -ignore-filename-regex='\.build|Tests/|checkouts' \
	   | python3 -c 'import json,sys; print(round(json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"],2))'); then \
	   echo "⚠ coverage extraction failed (toolchain) — report-only"; exit 0; \
	 fi; \
	 echo "→ Line coverage (Sources/Logos, unit-only): $$PCT% (target 80%, report-only)"; \
	 echo "  note: the unit number undercounts the SwiftUI layer — view bodies run only under 'make hosted-tests'."

hosted-tests: ## Generate xcodeproj + run hosted (renderer+snapshot) + UI tests via xcodebuild (#25/#26)
	@command -v xcodegen >/dev/null || { echo "✗ xcodegen not installed (brew install xcodegen)"; exit 1; }
	xcodegen generate
	xcodebuild test -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
		-destination 'platform=macOS' -allowProvisioningUpdates

build: ## Release build
	swift build -c release

bundle: build ## Build + assemble .app bundle (ad-hoc signed)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp $(RELEASE_BIN) $(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@# #99: embed the SwiftPM-generated resource bundles (SwiftTerm_SwiftTerm.bundle carries the
	@# Metal shaders; Highlightr_Highlightr.bundle the highlight themes). Bundle.module resolves
	@# them via Contents/Resources; without them the only lookup that succeeds is the compiled-in
	@# dev path into this repo's .build, so every installed/distributed app trap-crashes at Metal
	@# adoption the moment that tree is cleaned or absent.
	@cp -R $(BUILD_DIR)/release/*.bundle $(APP_BUNDLE)/Contents/Resources/
	@test -d $(APP_BUNDLE)/Contents/Resources/SwiftTerm_SwiftTerm.bundle || \
		{ echo "✗ SwiftTerm_SwiftTerm.bundle missing from app bundle (Bundle.module would trap at launch)"; exit 1; }
	@echo "APPL????" > $(APP_BUNDLE)/Contents/PkgInfo
	@if [ -n "$(DEV_SIGN_ID)" ]; then \
		codesign --force --deep --sign "$(DEV_SIGN_ID)" $(APP_BUNDLE); \
		echo "✓ Bundle ready at $(APP_BUNDLE) (Apple Development $(DEV_SIGN_ID); keychain grants persist across rebuilds)"; \
	else \
		codesign --force --deep --sign - $(APP_BUNDLE); \
		echo "⚠ No Apple Development identity in keychain — ad-hoc signed; keychain authorization will NOT stick across rebuilds (#101)"; \
		echo "✓ Bundle ready at $(APP_BUNDLE) (ad-hoc, resource bundles embedded)"; \
	fi

run: bundle ## Build + bundle + open
	@open $(APP_BUNDLE)

smoke: bundle ## Build bundle + run headless smoke / E2E (Track A; launches the app, asserts the os.Logger lifecycle trail)
	@echo "→ Running headless smoke (LOGOS_SMOKE=1) against $(APP_BUNDLE)..."
	@LOGOS_SMOKE=1 swift test --filter LogosSmokeTests

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
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
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
