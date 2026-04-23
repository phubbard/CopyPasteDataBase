# cpdb build & packaging
#
# `swift build` alone handles the CLI. The menu-bar app needs to be wrapped
# into a real .app bundle because SPM can't emit one — these targets do that,
# plus developer signing so Accessibility permission persists across rebuilds.

APP_NAME         = cpdb
APP_BUNDLE_ID    = net.phfactor.cpdb
BUILD_CONFIG    ?= release
BUILD_DIR        = .build
APP_BUNDLE_DIR   = $(BUILD_DIR)/app/$(APP_NAME).app
RELEASE_DIR      = $(BUILD_DIR)/release-artifacts

# Source of truth for the version. Parsed out of Version.swift so every
# Makefile target that cares (release zip filename, verify-version) stays
# consistent without a separate VERSION file to drift against.
VERSION := $(shell sed -nE 's/.*static let marketing = "([^"]+)".*/\1/p' Sources/CpdbShared/Version.swift)
# Build identifier: marketing + git short-sha, e.g. "2.0.0-dev+9e59148".
# Injected into CFBundleVersion and BuildStamp.swift so every deploy has
# an unambiguous id that matches exactly one commit.
GIT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
GIT_DIRTY := $(shell git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null || echo "-dirty")
BUILD_ID := $(VERSION)+$(GIT_SHA)$(GIT_DIRTY)

# Use the full Xcode toolchain for everything in this Makefile. The app target
# depends on KeyboardShortcuts, which uses `#Preview` macros that the Command
# Line Tools toolchain can't expand. `swift build` of the CLI alone still
# works with CLT.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Codesigning identity. Defaults to the user's Apple Development certificate;
# override with `make build-app SIGNING_IDENTITY="..."` for ad-hoc (`-`) or a
# different cert.
SIGNING_IDENTITY ?= Apple Development: Paul HUBBARD (6442857NX6)

# Entitlements file — attaches iCloud + CloudKit + APNs to the signed
# binary. Must be passed to codesign via --entitlements; without this,
# CloudKit requests fail with "Missing application-identifier entitlement".
ENTITLEMENTS     = Sources/CpdbApp/Resources/cpdb.entitlements

# Provisioning profile — must authorise every entitlement in $(ENTITLEMENTS).
# Download from Apple Developer → Profiles after enabling iCloud container
# + Push Notifications on the app id, then drop at the project root.
# Gitignored (*.provisionprofile) so credentials never land in the repo.
PROFILE          = cpdb.provisionprofile

.PHONY: all build build-cli build-app run-app install-app clean test verify-version release version stamp-build

all: build

build: build-cli build-app

version:
	@echo $(VERSION)

# Sanity-check: Version.swift's marketing version must agree with the
# Info.plist's CFBundleShortVersionString (user-facing marketing version).
# CFBundleVersion is a generated build id and isn't compared here — it's
# overwritten inside the bundle by build-app below.
verify-version:
	@set -e; \
	 SHORT=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/CpdbApp/Resources/Info.plist); \
	 if [ "$$SHORT" != "$(VERSION)" ]; then \
	   echo "error: marketing version drift — Version.swift=$(VERSION) plist=$$SHORT"; \
	   exit 1; \
	 fi; \
	 echo "marketing version $(VERSION) (build $(BUILD_ID)) ✓"

# Regenerate Sources/CpdbShared/BuildStamp.swift with the current git sha
# so `CpdbVersion.current` reflects the build. Runs before every swift
# build invocation so there's no way to ship a stale stamp.
stamp-build:
	@scripts/stamp-build.sh

build-cli: stamp-build
	swift build -c $(BUILD_CONFIG) --product cpdb

build-app: verify-version stamp-build
	swift build -c $(BUILD_CONFIG) --product CpdbApp
	rm -rf $(APP_BUNDLE_DIR)
	mkdir -p $(APP_BUNDLE_DIR)/Contents/MacOS
	mkdir -p $(APP_BUNDLE_DIR)/Contents/Resources
	cp $(BUILD_DIR)/$(BUILD_CONFIG)/CpdbApp $(APP_BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	# App icon. Generated from SF Symbols via `scripts/make-icon.swift`.
	# CFBundleIconFile in Info.plist names "AppIcon" (no extension); the
	# resource must live at Contents/Resources/AppIcon.icns.
	@if [ -f Sources/CpdbApp/Resources/Assets/AppIcon.icns ]; then \
	    cp Sources/CpdbApp/Resources/Assets/AppIcon.icns $(APP_BUNDLE_DIR)/Contents/Resources/AppIcon.icns; \
	else \
	    echo "warning: AppIcon.icns not found; run scripts/make-icon.swift first"; \
	fi
	# SPM-generated resource bundles — each Swift Package that declares
	# resources produces a `<Package>_<Target>.bundle` at build time.
	# `Bundle.module` inside the package looks for these next to the
	# main binary. On a second-Mac install (no .build tree) the fallback
	# search path is gone; missing bundle → fatal assertion at the first
	# `Bundle.module` access (killed axiom + thor when Preferences opened
	# and KeyboardShortcuts.Recorder initialized).
	@for b in $(BUILD_DIR)/$(BUILD_CONFIG)/*.bundle; do \
	    if [ -d "$$b" ]; then \
	        cp -R "$$b" $(APP_BUNDLE_DIR)/Contents/Resources/; \
	        echo "  bundled $$(basename $$b)"; \
	    fi; \
	done
	# The `cpdb` CLI is NOT shipped inside the app bundle. AMFI rejects
	# nested bare binaries that claim restricted entitlements (iCloud,
	# APNs) with "No matching profile found" — profile inheritance only
	# covers the CFBundleExecutable, not other binaries in MacOS/.
	# Packaging the CLI as its own sub-bundle would need a second Apple
	# app ID + profile. For now, use the menu bar "Sync Now" / "Pull Now"
	# commands, or build the CLI locally from .build/release/cpdb.
	cp Sources/CpdbApp/Resources/Info.plist $(APP_BUNDLE_DIR)/Contents/Info.plist
	# Overwrite CFBundleVersion in the bundled copy with the build id so
	# the About window and `mdls` both show exactly which commit was
	# built. Marketing version (CFBundleShortVersionString) stays as is.
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_ID)" $(APP_BUNDLE_DIR)/Contents/Info.plist
	# Embed the provisioning profile so macOS Launch Services will accept
	# our developer-namespace entitlements (icloud-container-identifiers,
	# aps-environment). The file must be named exactly
	# `embedded.provisionprofile` inside Contents/; codesign + launchd both
	# look it up by that name.
	@test -f $(PROFILE) || (echo "error: $(PROFILE) not found — download from Apple Developer and drop at project root" && exit 1)
	cp $(PROFILE) $(APP_BUNDLE_DIR)/Contents/embedded.provisionprofile
	codesign --force --sign "$(SIGNING_IDENTITY)" \
	         --entitlements $(ENTITLEMENTS) \
	         --timestamp=none --options runtime $(APP_BUNDLE_DIR)
	@echo
	@echo "Built $(APP_BUNDLE_DIR) (v$(VERSION))"
	@codesign -dv $(APP_BUNDLE_DIR) 2>&1 | sed 's/^/  /'

run-app: build-app
	open $(APP_BUNDLE_DIR)

install-app: build-app
	# Quit any running copy so we can replace it cleanly.
	-osascript -e 'tell application "$(APP_NAME)" to quit' 2>/dev/null
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE_DIR) /Applications/$(APP_NAME).app
	@echo "Installed /Applications/$(APP_NAME).app"
	@echo "Launch with: open -a $(APP_NAME)"

# Package a release artefact: signed .app bundle zipped alongside the CLI
# binary. Preserves symlinks/codesign via `ditto -c -k --keepParent` — the
# only macOS-blessed way to zip an .app without breaking its signature.
release: verify-version build-cli build-app
	rm -rf $(RELEASE_DIR)
	mkdir -p $(RELEASE_DIR)
	/usr/bin/ditto -c -k --keepParent $(APP_BUNDLE_DIR) $(RELEASE_DIR)/cpdb-v$(VERSION).app.zip
	cp $(BUILD_DIR)/$(BUILD_CONFIG)/cpdb $(RELEASE_DIR)/cpdb
	cd $(RELEASE_DIR) && shasum -a 256 cpdb-v$(VERSION).app.zip cpdb > SHA256SUMS
	@echo
	@echo "Release artefacts in $(RELEASE_DIR):"
	@ls -la $(RELEASE_DIR)

clean:
	swift package clean
	rm -rf $(BUILD_DIR)/app $(RELEASE_DIR)

test:
	swift test
