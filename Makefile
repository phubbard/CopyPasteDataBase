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

# Universal binary support. Set UNIVERSAL=1 to produce a single binary
# slicing for both Apple Silicon and Intel — required for any beta
# tester on an Intel Mac. The `release` target turns this on
# automatically; for fast dev iteration `make build-app` /
# `make build-cli` stay host-arch-only by default.
#
# Multi-arch swift-build emits to `.build/apple/Products/$(BUILD_CONFIG)/`
# instead of `.build/$(BUILD_CONFIG)/`, hence the SWIFT_BUILD_OUTPUT_DIR
# computation below — every cp/copy step downstream resolves against
# this so we don't accidentally ship the host-arch slice.
UNIVERSAL ?= 0
ifeq ($(UNIVERSAL),1)
SWIFT_ARCH_FLAGS    = --arch arm64 --arch x86_64
SWIFT_BUILD_OUTPUT  = $(BUILD_DIR)/apple/Products/$(shell echo $(BUILD_CONFIG) | awk '{print toupper(substr($$0,1,1)) tolower(substr($$0,2))}')
else
SWIFT_ARCH_FLAGS    =
SWIFT_BUILD_OUTPUT  = $(BUILD_DIR)/$(BUILD_CONFIG)
endif

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

# Developer ID identity — used by the dmg / notarize / publish targets
# to produce a Gatekeeper-friendly redistributable bundle. Different
# from SIGNING_IDENTITY (which is the dev cert). Override on the
# command line for first-time setup or another team.
DEVELOPER_ID_IDENTITY ?= Developer ID Application: PAUL HUBBARD (NSR65JVW9F)

# notarytool keychain profile name. Must match what was passed to
# `xcrun notarytool store-credentials <name>`. Holds the Apple ID +
# team id + app-specific password used by the notary submission.
NOTARY_PROFILE        ?= cpdb-notary

# Entitlements file — attaches iCloud + CloudKit + APNs to the signed
# binary. Must be passed to codesign via --entitlements; without this,
# CloudKit requests fail with "Missing application-identifier entitlement".
ENTITLEMENTS         = Sources/CpdbApp/Resources/cpdb.entitlements

# Release entitlements — same shape but with aps-environment=production
# and no get-task-allow. Used by the dmg / notarize path because the
# Apple notary rejects development APNs and debug entitlements.
RELEASE_ENTITLEMENTS = Sources/CpdbApp/Resources/cpdb-release.entitlements

# Provisioning profile — must authorise every entitlement in $(ENTITLEMENTS).
# Download from Apple Developer → Profiles after enabling iCloud container
# + Push Notifications on the app id, then drop at the project root.
# Gitignored (*.provisionprofile) so credentials never land in the repo.
PROFILE          = cpdb.provisionprofile

# DMG paths.
DMG_STAGING      = $(BUILD_DIR)/dmg-staging
DMG_FILE         = $(RELEASE_DIR)/cpdb-v$(VERSION).dmg
VOLUME_NAME      = cpdb $(VERSION)

.PHONY: all build build-cli build-app run-app install-app clean test verify-version release version stamp-build dmg notarize-dmg publish sign-release verify-developer-id publish-github bump

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
	# Product name changed from `cpdb` to `cpdb-cli` so it doesn't
	# collide with the iOS app target (also `cpdb`) when the iOS
	# Xcode project consumes this repo as a Local Package. The
	# shipped binary is still named `cpdb` — we rename on copy
	# in `release` / install.
	swift build -c $(BUILD_CONFIG) $(SWIFT_ARCH_FLAGS) --product cpdb-cli

build-app: verify-version stamp-build
	swift build -c $(BUILD_CONFIG) $(SWIFT_ARCH_FLAGS) --product CpdbApp
	rm -rf $(APP_BUNDLE_DIR)
	mkdir -p $(APP_BUNDLE_DIR)/Contents/MacOS
	mkdir -p $(APP_BUNDLE_DIR)/Contents/Resources
	cp $(SWIFT_BUILD_OUTPUT)/CpdbApp $(APP_BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	# App icon. Generated from SF Symbols via `scripts/make-icon.swift`.
	# CFBundleIconFile in Info.plist names "AppIcon" (no extension); the
	# resource must live at Contents/Resources/AppIcon.icns.
	@if [ -f Sources/CpdbApp/Resources/Assets/AppIcon.icns ]; then \
	    cp Sources/CpdbApp/Resources/Assets/AppIcon.icns $(APP_BUNDLE_DIR)/Contents/Resources/AppIcon.icns; \
	else \
	    echo "warning: AppIcon.icns not found; run scripts/make-icon.swift first"; \
	fi
	# SPM-generated resource bundles. Two-step:
	#   1. Real bundle lives in Contents/Resources/<name>.bundle — that
	#      location keeps codesign happy (the outer .app signature
	#      enumerates files in Contents/ only; top-level siblings of
	#      Contents/ break "code has no resources but signature indicates
	#      they must be present").
	#   2. A relative symlink at the .app top level points at the real
	#      bundle. SPM's generated `Bundle.module` accessor looks for
	#      `Bundle.main.bundleURL.appendingPathComponent(name + ".bundle")`
	#      which for an .app is `/Applications/cpdb.app/<name>.bundle` —
	#      a symlink there is enough to resolve the lookup.
	# Also patch the SPM-stub Info.plist with CFBundleIdentifier +
	# CFBundlePackageType so macOS Bundle(url:) accepts it.
	@for b in $(SWIFT_BUILD_OUTPUT)/*.bundle; do \
	    if [ -d "$$b" ]; then \
	        name=$$(basename "$$b" .bundle); \
	        bundleName=$$(basename "$$b"); \
	        dest=$(APP_BUNDLE_DIR)/Contents/Resources/$$bundleName; \
	        cp -R "$$b" $(APP_BUNDLE_DIR)/Contents/Resources/; \
	        /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string net.phfactor.cpdb.$$name" "$$dest/Info.plist" 2>/dev/null || \
	            /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.phfactor.cpdb.$$name" "$$dest/Info.plist"; \
	        /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" "$$dest/Info.plist" 2>/dev/null || true; \
	        /usr/libexec/PlistBuddy -c "Add :CFBundleName string $$name" "$$dest/Info.plist" 2>/dev/null || true; \
	        /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$$dest/Info.plist" 2>/dev/null || true; \
	        /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "$$dest/Info.plist" 2>/dev/null || true; \
	        /usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$$dest/Info.plist" 2>/dev/null || true; \
	        echo "  bundled $$bundleName"; \
	    fi; \
	done
	# The `cpdb` CLI is NOT shipped inside the app bundle. AMFI rejects
	# nested bare binaries that claim restricted entitlements (iCloud,
	# APNs) with "No matching profile found" — profile inheritance only
	# covers the CFBundleExecutable, not other binaries in MacOS/.
	# Packaging the CLI as its own sub-bundle would need a second Apple
	# app ID + profile. For now, use the menu bar "Sync Now" / "Pull Now"
	# commands, or build the CLI locally from .build/release/cpdb-cli.
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
	# Sign nested SPM resource bundles BEFORE the outer app. Hardened
	# runtime won't load unsigned nested bundles inside a signed app —
	# the main binary fails `Bundle.module` lookup with a fatal
	# assertion when KeyboardShortcuts (or any other resource-bearing
	# package) tries to read its bundle. No --entitlements on these;
	# resource bundles don't claim capabilities.
	@for b in $(APP_BUNDLE_DIR)/*.bundle; do \
	    if [ -d "$$b" ]; then \
	        codesign --force --sign "$(SIGNING_IDENTITY)" --timestamp=none "$$b"; \
	    fi; \
	done
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
#
# Forces UNIVERSAL=1 so the released artefacts run on both Apple Silicon
# and Intel — required for the Intel-Mac beta tester. We re-invoke make
# rather than just setting UNIVERSAL inline so the dependent targets
# (build-cli, build-app) pick the new arch flags up cleanly.
release: verify-version
	$(MAKE) UNIVERSAL=1 build-cli build-app
	rm -rf $(RELEASE_DIR)
	mkdir -p $(RELEASE_DIR)
	/usr/bin/ditto -c -k --keepParent $(APP_BUNDLE_DIR) $(RELEASE_DIR)/cpdb-v$(VERSION).app.zip
	cp $(BUILD_DIR)/apple/Products/Release/cpdb-cli $(RELEASE_DIR)/cpdb
	cd $(RELEASE_DIR) && shasum -a 256 cpdb-v$(VERSION).app.zip cpdb > SHA256SUMS
	@echo
	@echo "Architectures (must show both arm64 + x86_64):"
	@lipo -archs $(RELEASE_DIR)/cpdb
	@lipo -archs $(APP_BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	@echo
	@echo "Release artefacts in $(RELEASE_DIR):"
	@ls -la $(RELEASE_DIR)

# ---------------------------------------------------------------------------
# DMG / notarization pipeline
#
# Three steps to a Gatekeeper-friendly redistributable .dmg:
#   1. sign-release  — re-sign the existing .app with Developer ID + hardened
#                       runtime + release entitlements (no get-task-allow,
#                       aps-environment=production).
#   2. dmg           — produce a pretty drag-to-Applications .dmg via
#                       create-dmg (homebrew). Sign the .dmg too.
#   3. notarize-dmg  — submit to Apple's notary service, wait for the result,
#                       staple the ticket onto the .dmg.
#
# `make publish` chains all three plus the universal release build itself.
#
# One-time prereqs (won't be repeated by these targets):
#   • Developer ID Application cert in login keychain. Verify with
#     `security find-identity -v -p codesigning | grep "Developer ID"`.
#   • create-dmg installed: `brew install create-dmg`.
#   • Notary credentials stored once:
#       xcrun notarytool store-credentials cpdb-notary \
#           --apple-id pfh@phfactor.net --team-id NSR65JVW9F \
#           --password <app-specific-pw-from-appleid.apple.com>
#     The profile name must match $(NOTARY_PROFILE) above.
#
# `make verify-developer-id` runs the prereq sanity checks without doing
# any signing — useful for diagnosing first-time setup.
# ---------------------------------------------------------------------------

verify-developer-id:
	@echo "Checking Developer ID identity…"
	@security find-identity -v -p codesigning | grep -q "$(DEVELOPER_ID_IDENTITY)" \
	    || { echo "error: identity not found in keychain: $(DEVELOPER_ID_IDENTITY)"; \
	         echo "       run security find-identity -v -p codesigning to see what's there"; exit 1; }
	@echo "  ✓ $(DEVELOPER_ID_IDENTITY)"
	@echo "Checking notary credentials…"
	@xcrun notarytool history --keychain-profile $(NOTARY_PROFILE) >/dev/null 2>&1 \
	    || { echo "error: notarytool profile '$(NOTARY_PROFILE)' not configured"; \
	         echo "       run: xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"; \
	         echo "                --apple-id <your-apple-id> --team-id NSR65JVW9F \\"; \
	         echo "                --password <app-specific-password>"; exit 1; }
	@echo "  ✓ notarytool profile $(NOTARY_PROFILE)"
	@echo "Checking create-dmg…"
	@command -v create-dmg >/dev/null 2>&1 \
	    || { echo "error: create-dmg not found. install with: brew install create-dmg"; exit 1; }
	@echo "  ✓ create-dmg $$(create-dmg --version 2>&1 | head -1)"

# Re-sign the .app at $(APP_BUNDLE_DIR) with Developer ID + hardened
# runtime + release entitlements. Idempotent: replacing an existing
# Apple-Development signature with Developer ID is fine.
#
# --options=runtime activates hardened runtime, required by notary.
# --timestamp adds a secure timestamp from Apple's TSA, required so
#   the signature stays valid after the cert expires.
# Sub-bundles (KeyboardShortcuts, GRDB resource bundles) need their
# own --deep signature pass first — `--deep` on the outer call does
# the depth-first walk for us.
sign-release: verify-developer-id
	@echo "Re-signing $(APP_BUNDLE_DIR) with Developer ID…"
	@codesign --force --deep --sign "$(DEVELOPER_ID_IDENTITY)" \
	    --options=runtime --timestamp \
	    --entitlements $(RELEASE_ENTITLEMENTS) \
	    $(APP_BUNDLE_DIR)
	@echo "Verifying signature…"
	@codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE_DIR) 2>&1 | tail -3
	@spctl --assess --type execute --verbose=2 $(APP_BUNDLE_DIR) 2>&1 | tail -3 \
	    || echo "  (spctl rejection is normal pre-notarization — Gatekeeper accepts after staple)"

# Build a drag-to-install .dmg from the signed .app. Stages the bundle
# + an /Applications symlink into a tmp dir so create-dmg has a clean
# room to lay out icons. Output is also signed, since notary rejects
# unsigned containers.
dmg: sign-release
	@echo "Staging $(DMG_STAGING)…"
	@rm -rf $(DMG_STAGING)
	@mkdir -p $(DMG_STAGING)
	@cp -R $(APP_BUNDLE_DIR) $(DMG_STAGING)/
	@mkdir -p $(RELEASE_DIR)
	@rm -f $(DMG_FILE)
	@echo "Building $(DMG_FILE)…"
	@create-dmg \
	    --volname "$(VOLUME_NAME)" \
	    --window-size 540 380 \
	    --icon-size 96 \
	    --icon "cpdb.app" 140 200 \
	    --app-drop-link 400 200 \
	    --hdiutil-quiet \
	    --no-internet-enable \
	    "$(DMG_FILE)" "$(DMG_STAGING)/cpdb.app" \
	    || { echo "create-dmg failed (exit $$?)"; exit 1; }
	@echo "Signing $(DMG_FILE)…"
	@codesign --force --sign "$(DEVELOPER_ID_IDENTITY)" --timestamp $(DMG_FILE)
	@codesign --verify --verbose=1 $(DMG_FILE) 2>&1 | tail -2
	@echo
	@ls -la $(DMG_FILE)

# Submit the .dmg to Apple's notary service and staple the ticket on
# success. `--wait` blocks for up to ~30 min while the notary runs.
# After stapling, the .dmg launches without Gatekeeper warnings on any
# Mac, even offline.
notarize-dmg: dmg
	@echo "Submitting $(DMG_FILE) to Apple notary (this may take 1-30 min)…"
	@xcrun notarytool submit $(DMG_FILE) --keychain-profile $(NOTARY_PROFILE) --wait
	@echo "Stapling ticket onto $(DMG_FILE)…"
	@xcrun stapler staple $(DMG_FILE)
	@xcrun stapler validate $(DMG_FILE)
	@echo
	@echo "✓ $(DMG_FILE) signed, notarized, stapled"
	@shasum -a 256 $(DMG_FILE)

# End-to-end: build universal release artefacts, then DMG + notarize.
# This is what you run before tagging a public release.
publish: release notarize-dmg
	@echo
	@echo "Publish complete. Artefacts in $(RELEASE_DIR):"
	@ls -la $(RELEASE_DIR)

# Bump the marketing version everywhere it lives. Usage:
#   make bump VERSION=2.5.8
# Updates Version.swift, the Mac Info.plist, and the iOS Xcode project.
# Verifies the resulting tree builds (verify-version) before exiting.
bump:
	@if [ -z "$(BUMP_TO)" ] && [ -z "$(VERSION_NEW)" ]; then \
	    echo "usage: make bump VERSION_NEW=X.Y.Z (current is $(VERSION))"; exit 2; \
	fi
	@new="$${VERSION_NEW:-$(BUMP_TO)}"; \
	    cur="$(VERSION)"; \
	    if [ "$$new" = "$$cur" ]; then \
	        echo "already at $$new"; exit 0; \
	    fi; \
	    echo "bumping $$cur → $$new"; \
	    sed -i.bak -E "s/static let marketing = \"[^\"]+\"/static let marketing = \"$$new\"/" Sources/CpdbShared/Version.swift && rm Sources/CpdbShared/Version.swift.bak; \
	    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$new" Sources/CpdbApp/Resources/Info.plist; \
	    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$new" Sources/CpdbApp/Resources/Info.plist; \
	    if [ -f iOS/cpdb/cpdb.xcodeproj/project.pbxproj ]; then \
	        sed -i.bak -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $$new;/g" iOS/cpdb/cpdb.xcodeproj/project.pbxproj && \
	            rm iOS/cpdb/cpdb.xcodeproj/project.pbxproj.bak; \
	        cur_build=$$(grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+;' iOS/cpdb/cpdb.xcodeproj/project.pbxproj | head -1 | grep -oE '[0-9]+'); \
	        next_build=$$((cur_build + 1)); \
	        sed -i.bak -E "s/CURRENT_PROJECT_VERSION = $$cur_build;/CURRENT_PROJECT_VERSION = $$next_build;/g" iOS/cpdb/cpdb.xcodeproj/project.pbxproj && \
	            rm iOS/cpdb/cpdb.xcodeproj/project.pbxproj.bak; \
	        echo "  iOS CURRENT_PROJECT_VERSION $$cur_build → $$next_build"; \
	    fi
	@$(MAKE) verify-version

# Push the current main + a vX.Y.Z tag to GitHub, then create or
# update the release with auto-generated notes and the artefacts in
# .build/release-artifacts/. Idempotent: re-running uploads/replaces
# assets without recreating the release.
#
# Prerequisites (the target enforces all four):
#   • Working tree clean.
#   • Version.swift's marketing version matches Info.plist.
#   • Branch is main and up to date with origin.
#   • .build/release-artifacts/ has fresh artefacts (run `make publish`).
#
# Typical release flow:
#   make bump VERSION_NEW=2.5.8
#   git commit -am "v2.5.8: <changelog>"
#   make publish
#   make publish-github
publish-github: verify-version
	@echo "Checking working tree…"
	@dirty=$$(git status --porcelain | grep -v ' Sources/CpdbShared/BuildStamp.swift$$' || true); \
	    if [ -n "$$dirty" ]; then \
	        echo "error: working tree has uncommitted changes — commit or stash first"; \
	        echo "$$dirty"; exit 1; \
	    fi
	@echo "  ✓ clean (BuildStamp.swift drift ignored — auto-stamped each build)"
	@echo "Checking branch…"
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	    if [ "$$branch" != "main" ]; then \
	        echo "error: not on main (currently on $$branch)"; exit 1; \
	    fi
	@echo "  ✓ main"
	@echo "Checking artefacts in $(RELEASE_DIR)…"
	@if [ ! -f $(RELEASE_DIR)/cpdb-v$(VERSION).dmg ]; then \
	    echo "error: $(RELEASE_DIR)/cpdb-v$(VERSION).dmg not found — run \`make publish\` first"; \
	    exit 1; \
	fi
	@echo "  ✓ DMG present"
	@echo "Pushing main…"
	@git push origin main
	@echo "Tagging v$(VERSION)…"
	@if git rev-parse "v$(VERSION)" >/dev/null 2>&1; then \
	    echo "  tag v$(VERSION) already exists, skipping create"; \
	else \
	    git tag -a "v$(VERSION)" -m "v$(VERSION)" && git push origin "v$(VERSION)"; \
	fi
	@echo "Generating release notes…"
	@prev_tag=$$(git describe --tags --abbrev=0 "v$(VERSION)^" 2>/dev/null || echo ""); \
	    if [ -n "$$prev_tag" ]; then \
	        echo "  range: $$prev_tag..v$(VERSION)"; \
	        notes=$$(git log "$$prev_tag..v$(VERSION)" --pretty=format:"- %s" --no-merges); \
	    else \
	        echo "  range: (initial release — full log)"; \
	        notes=$$(git log "v$(VERSION)" --pretty=format:"- %s" --no-merges); \
	    fi; \
	    body=$$(printf "## Changes\n\n%s\n\n## Artefacts\n\n- \`cpdb-v$(VERSION).dmg\` — signed, notarized, drag-to-Applications installer (universal arm64+x86_64)\n- \`cpdb-v$(VERSION).app.zip\` — same .app bundle, ditto-zipped (preserves codesign)\n- \`cpdb\` — universal CLI binary\n- \`SHA256SUMS\` — integrity\n\nCommit: $$(git rev-parse --short v$(VERSION))" "$$notes"); \
	    echo "$$body" > $(RELEASE_DIR)/.release-notes.md; \
	    cat $(RELEASE_DIR)/.release-notes.md
	@echo
	@echo "Refreshing SHA256SUMS to cover all artefacts…"
	@cd $(RELEASE_DIR) && shasum -a 256 cpdb-v$(VERSION).app.zip cpdb cpdb-v$(VERSION).dmg > SHA256SUMS
	@echo "Creating / updating GitHub release…"
	@if gh release view "v$(VERSION)" >/dev/null 2>&1; then \
	    echo "  release v$(VERSION) exists — updating notes and uploading assets"; \
	    gh release edit "v$(VERSION)" --notes-file $(RELEASE_DIR)/.release-notes.md; \
	    gh release upload "v$(VERSION)" \
	        $(RELEASE_DIR)/cpdb-v$(VERSION).dmg \
	        $(RELEASE_DIR)/cpdb-v$(VERSION).app.zip \
	        $(RELEASE_DIR)/cpdb \
	        $(RELEASE_DIR)/SHA256SUMS \
	        --clobber; \
	else \
	    gh release create "v$(VERSION)" \
	        --title "v$(VERSION)" \
	        --notes-file $(RELEASE_DIR)/.release-notes.md \
	        $(RELEASE_DIR)/cpdb-v$(VERSION).dmg \
	        $(RELEASE_DIR)/cpdb-v$(VERSION).app.zip \
	        $(RELEASE_DIR)/cpdb \
	        $(RELEASE_DIR)/SHA256SUMS; \
	fi
	@echo
	@echo "✓ https://github.com/phubbard/CopyPasteDataBase/releases/tag/v$(VERSION)"

clean:
	swift package clean
	rm -rf $(BUILD_DIR)/app $(RELEASE_DIR) $(DMG_STAGING)

test:
	swift test
