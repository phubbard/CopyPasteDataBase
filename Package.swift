// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "cpdb",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "cpdb", targets: ["cpdb"]),
        .executable(name: "CpdbApp", targets: ["CpdbApp"]),
        .executable(name: "CpdbiOS", targets: ["CpdbiOS"]),
        .library(name: "CpdbShared", targets: ["CpdbShared"]),
        .library(name: "CpdbCore", targets: ["CpdbCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "cpdb",
            dependencies: [
                "CpdbCore",
                "CpdbShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "CpdbApp",
            dependencies: [
                "CpdbCore",
                "CpdbShared",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            // Info.plist + entitlements + icon assets live under Resources/,
            // but SPM can't actually package a menu-bar app bundle — the
            // Makefile does that. Exclude these so SPM doesn't treat them
            // as Swift sources or untyped resources (which emits a build
            // warning for each file).
            exclude: [
                "Resources/Info.plist",
                "Resources/cpdb.entitlements",
                "Resources/Assets",
            ]
        ),
        // Cross-platform library: pure data, GRDB storage, Vision analysis,
        // FTS5 search, Quick Look item building. iOS + macOS both link this.
        .target(
            name: "CpdbShared",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // macOS-only library: NSPasteboard plumbing, Paste.db import,
        // launchd helpers, daemon lock. Layers on top of CpdbShared.
        .target(
            name: "CpdbCore",
            dependencies: [
                "CpdbShared",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // iOS companion app. Shares CpdbShared with the Mac side
        // (schema, mapper, syncer, blob store all cross-platform).
        // No dependency on CpdbCore because that's macOS-only
        // (NSPasteboard, launchd, AppKit). Building requires Xcode
        // with an iOS destination selected — plain
        // `swift build --product CpdbiOS` builds for the Mac host
        // which won't link because UIKit isn't on the Mac SDK.
        //
        // Code signing: Configure in Xcode with your Apple Developer account.
        // See iOS-SIGNING-SETUP.md for detailed setup instructions.
        // Bundle ID: net.phfactor.cpdb.ios
        // Required capabilities: iCloud (CloudKit), Push Notifications
        .executableTarget(
            name: "CpdbiOS",
            dependencies: [
                "CpdbShared",
            ],
            // Info.plist + entitlements live under Resources/ but are
            // excluded from SPM processing. Xcode will use them during
            // the build when you select an iOS destination.
            exclude: [
                "Resources/Info.plist",
                "Resources/cpdb-ios.entitlements",
            ]
        ),
        .testTarget(
            name: "CpdbCoreTests",
            dependencies: [
                "CpdbCore",
                "CpdbShared",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
            // Note: `swift test` needs a full Xcode toolchain for Testing.framework.
            // Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`,
            // or set it once in your shell. `swift build` works with Command Line Tools alone.
        ),
    ]
)
