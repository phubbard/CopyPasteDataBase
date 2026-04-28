// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "cpdb",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // The macOS CLI is named `cpdb-cli` at the package level to
        // avoid colliding with the iOS app target (also `cpdb`) when
        // the iOS Xcode project consumes this repo as a Local Package.
        // The shipped binary is still `cpdb` — the Makefile renames it
        // during install (see `install-cli`).
        .executable(name: "cpdb-cli", targets: ["cpdb-cli"]),
        .executable(name: "CpdbApp", targets: ["CpdbApp"]),
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
            name: "cpdb-cli",
            dependencies: [
                "CpdbCore",
                "CpdbShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            // Sources still live at Sources/cpdb — only the target/
            // product names changed. Keeping the path explicit lets
            // us rename without a directory move.
            path: "Sources/cpdb"
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
                "Resources/cpdb-release.entitlements",
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
        // The iOS companion app lives at iOS/cpdb/cpdb.xcodeproj
        // and depends on this package via Xcode's Local Package
        // feature (importing CpdbShared directly). Not defined as
        // an SPM target here because iOS apps need Xcode's full
        // build pipeline (Info.plist, asset catalog, entitlements,
        // code signing), which SPM's executableTarget doesn't
        // provide. Sources live under iOS/cpdb/cpdb/ — that's the
        // single source of truth.
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
