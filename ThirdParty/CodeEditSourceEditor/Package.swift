// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodeEditSourceEditor",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CodeEditSourceEditor",
            targets: ["CodeEditSourceEditor"]
        ),
    ],
    dependencies: [
        .package(path: "../CodeEditLanguages"),
        .package(path: "../CodeEditTextView"),
        .package(path: "../CodeEditSymbols"),
        .package(
            url: "https://github.com/ChimeHQ/TextFormation",
            from: "0.8.2"
        ),
    ],
    targets: [
        .target(
            name: "CodeEditSourceEditor",
            dependencies: [
                "CodeEditLanguages",
                "CodeEditTextView",
                "CodeEditSymbols",
                "TextFormation",
            ]
        ),
    ]
)
