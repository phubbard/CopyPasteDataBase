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

# Use the full Xcode toolchain for everything in this Makefile. The app target
# depends on KeyboardShortcuts, which uses `#Preview` macros that the Command
# Line Tools toolchain can't expand. `swift build` of the CLI alone still
# works with CLT.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Codesigning identity. Defaults to the user's Apple Development certificate;
# override with `make build-app SIGNING_IDENTITY="..."` for ad-hoc (`-`) or a
# different cert.
SIGNING_IDENTITY ?= Apple Development: Paul HUBBARD (6442857NX6)

.PHONY: all build build-cli build-app run-app install-app clean test

all: build

build: build-cli build-app

build-cli:
	swift build -c $(BUILD_CONFIG) --product cpdb

build-app:
	swift build -c $(BUILD_CONFIG) --product CpdbApp
	rm -rf $(APP_BUNDLE_DIR)
	mkdir -p $(APP_BUNDLE_DIR)/Contents/MacOS
	mkdir -p $(APP_BUNDLE_DIR)/Contents/Resources
	cp $(BUILD_DIR)/$(BUILD_CONFIG)/CpdbApp $(APP_BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	cp Sources/CpdbApp/Resources/Info.plist $(APP_BUNDLE_DIR)/Contents/Info.plist
	codesign --force --sign "$(SIGNING_IDENTITY)" --timestamp=none --options runtime $(APP_BUNDLE_DIR)
	@echo
	@echo "Built $(APP_BUNDLE_DIR)"
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

clean:
	swift package clean
	rm -rf $(BUILD_DIR)/app

test:
	swift test
