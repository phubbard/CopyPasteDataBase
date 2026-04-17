# cpdb build & packaging
#
# `swift build` alone handles the CLI. The menu-bar app needs to be wrapped
# into a real .app bundle because SPM can't emit one — these targets do that,
# plus developer signing so Accessibility permission persists across rebuilds.

APP_NAME         = cpdb
APP_BUNDLE_ID    = local.cpdb.app
BUILD_CONFIG    ?= release
BUILD_DIR        = .build
APP_BUNDLE_DIR   = $(BUILD_DIR)/app/$(APP_NAME).app
RELEASE_DIR      = $(BUILD_DIR)/release-artifacts

# Source of truth for the version. Parsed out of Version.swift so every
# Makefile target that cares (release zip filename, verify-version) stays
# consistent without a separate VERSION file to drift against.
VERSION := $(shell sed -nE 's/.*static let current = "([^"]+)".*/\1/p' Sources/CpdbCore/Version.swift)

# Use the full Xcode toolchain for everything in this Makefile. The app target
# depends on KeyboardShortcuts, which uses `#Preview` macros that the Command
# Line Tools toolchain can't expand. `swift build` of the CLI alone still
# works with CLT.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Codesigning identity. Defaults to the user's Apple Development certificate;
# override with `make build-app SIGNING_IDENTITY="..."` for ad-hoc (`-`) or a
# different cert.
SIGNING_IDENTITY ?= Apple Development: Paul HUBBARD (6442857NX6)

.PHONY: all build build-cli build-app run-app install-app clean test verify-version release version

all: build

build: build-cli build-app

version:
	@echo $(VERSION)

# Sanity-check: Version.swift, Info.plist CFBundleShortVersionString, and
# CFBundleVersion must all agree. Runs as a dependency of build-app and
# release so we never ship mismatched versions.
verify-version:
	@set -e; \
	 SHORT=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/CpdbApp/Resources/Info.plist); \
	 BUILD=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Sources/CpdbApp/Resources/Info.plist); \
	 if [ "$$SHORT" != "$(VERSION)" ] || [ "$$BUILD" != "$(VERSION)" ]; then \
	   echo "error: version drift — Version.swift=$(VERSION) plist short=$$SHORT build=$$BUILD"; \
	   exit 1; \
	 fi; \
	 echo "version $(VERSION) ✓"

build-cli:
	swift build -c $(BUILD_CONFIG) --product cpdb

build-app: verify-version
	swift build -c $(BUILD_CONFIG) --product CpdbApp
	rm -rf $(APP_BUNDLE_DIR)
	mkdir -p $(APP_BUNDLE_DIR)/Contents/MacOS
	mkdir -p $(APP_BUNDLE_DIR)/Contents/Resources
	cp $(BUILD_DIR)/$(BUILD_CONFIG)/CpdbApp $(APP_BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	cp Sources/CpdbApp/Resources/Info.plist $(APP_BUNDLE_DIR)/Contents/Info.plist
	codesign --force --sign "$(SIGNING_IDENTITY)" --timestamp=none --options runtime $(APP_BUNDLE_DIR)
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
