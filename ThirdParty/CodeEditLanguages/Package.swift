// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodeEditLanguages",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CodeEditLanguages",
            targets: ["CodeEditLanguages"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ChimeHQ/SwiftTreeSitter.git",
            from: "0.9.0"
        ),
    ],
    targets: [
        .target(
            name: "TreeSitterSQL",
            path: "Sources/TreeSitterSQL",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("tree_sitter")
            ]
        ),
        .target(
            name: "TreeSitterJSON",
            path: "Sources/TreeSitterJSON",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("tree_sitter")
            ]
        ),
        .target(
            name: "CodeEditLanguages",
            dependencies: [
                "SwiftTreeSitter",
                "TreeSitterSQL",
                "TreeSitterJSON",
            ],
            resources: [
                .copy("Resources")
            ]
        ),
    ]
)
