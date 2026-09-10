// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "QueryCraftFeature",
    platforms: [.macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "QueryCraftFeature",
            type: .dynamic,
            targets: ["QueryCraftFeature"]
        ),
    ],
    dependencies: [
        .package(
            path: "../ThirdParty/CodeEditLanguages"
        ),
        .package(
            path: "../ThirdParty/CodeEditSourceEditor"
        ),
        .package(
            path: "../ThirdParty/CodeEditTextView"
        ),
        .package(
            url: "https://github.com/ChimeHQ/SwiftTreeSitter.git",
            from: "0.25.0"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            .upToNextMajor(from: "7.0.0")
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            .upToNextMajor(from: "2.9.0")
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "QueryCraftFeature",
            dependencies: [
                .product(
                    name: "CodeEditLanguages",
                    package: "CodeEditLanguages"
                ),
                .product(
                    name: "CodeEditSourceEditor",
                    package: "CodeEditSourceEditor"
                ),
                .product(
                    name: "CodeEditTextView",
                    package: "CodeEditTextView"
                ),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(
                    name: "SwiftTreeSitter",
                    package: "SwiftTreeSitter"
                ),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(
                    ["-enable-testing"],
                    .when(configuration: .debug)
                ),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "QueryCraftFeatureTests",
            dependencies: [
                "QueryCraftFeature",
                .product(
                    name: "CodeEditLanguages",
                    package: "CodeEditLanguages"
                ),
                .product(
                    name: "CodeEditSourceEditor",
                    package: "CodeEditSourceEditor"
                ),
                .product(
                    name: "CodeEditTextView",
                    package: "CodeEditTextView"
                ),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
