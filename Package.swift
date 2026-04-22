// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "cpdb",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "cpdb", targets: ["cpdb"]),
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
            // Info.plist lives under Resources/, but SPM can't actually write
            // it into a bundle. The Makefile copies it into cpdb.app/Contents/
            // at build time. Exclude here so SPM doesn't treat it as a Swift
            // source or try to process it as a resource.
            exclude: ["Resources/Info.plist"]
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
