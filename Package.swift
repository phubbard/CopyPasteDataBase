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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "CpdbApp",
            dependencies: [
                "CpdbCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            // Info.plist lives under Resources/, but SPM can't actually write
            // it into a bundle. The Makefile copies it into cpdb.app/Contents/
            // at build time. Exclude here so SPM doesn't treat it as a Swift
            // source or try to process it as a resource.
            exclude: ["Resources/Info.plist"]
        ),
        .target(
            name: "CpdbCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "CpdbCoreTests",
            dependencies: [
                "CpdbCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
            // Note: `swift test` needs a full Xcode toolchain for Testing.framework.
            // Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`,
            // or set it once in your shell. `swift build` works with Command Line Tools alone.
        ),
    ]
)
